"""omarchy-vk-music backend.

A long-lived user service that owns everything the QML widget must not: the VK
session, the API client with its pacing and halting rules, the download cache,
one `mpv` process, and the MPRIS identity that makes the media keys work.

QML never speaks VK. It runs `bin/omarchy-vk-music <command>` and reads one line
of JSON back; the CLI forwards the command to this service over a Unix socket
at `$XDG_RUNTIME_DIR/omarchy-vk-music.sock`.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import asdict
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))

from audio_cache import AudioCache, CacheError, cleanup_stray_temp
from vk_api import (
    WEB_APP_ID,
    WEB_USER_AGENT,
    Track,
    VkApiError,
    VkClient,
    VkHaltError,
    classify,
    safe_error_text,
)
from vk_auth import (
    COOKIE_NAMES,
    TOKEN_FILE,
    VkAuthError,
    fetch_browser_cookies,
    load_record,
    needs_refresh,
    mobile_authorize,
    parse_cookies,
    refresh_web_record,
    request_mobile_token,
    request_sms_code,
    save_mobile_token,
    save_web_token,
    request_web_token,
    MOBILE_CLIENTS,
)

RUNTIME_DIR = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"))
SOCKET_PATH = RUNTIME_DIR / "omarchy-vk-music.sock"
MPV_SOCKET = RUNTIME_DIR / "omarchy-vk-music-mpv.sock"
CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / (
    "omarchy-vk-music"
)
STATE_FILE = CONFIG_DIR / "state.json"
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / (
    "omarchy-vk-music"
)
AUDIO_CACHE_DIR = CACHE_DIR / "audio"

MPV = "/usr/bin/mpv"
MPV_PID_FILE = RUNTIME_DIR / "omarchy-vk-music-mpv.pid"
IPC_MAX_BYTES = 8 * 1024 * 1024
DEFAULT_PREFERENCES: dict[str, Any] = {
    "cacheEnabled": True,
    "cacheLimitMb": 256,
    "restoreOnStart": True,
    "defaultSource": "section:all",
}

# Errors that mean "stop and tell the user", mapped to the message the bar shows.
HALT_MESSAGES = {
    5: "Сессия VK отклонена. Нужен повторный вход.",
    9: "VK включил ограничение на запросы. Плагин остановлен.",
    14: "VK требует капчу. Плагин остановлен.",
}


def log(message: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {message}", file=sys.stderr, flush=True)


# ---------------------------------------------------------------- tracks ----


def track_to_state(track: Track) -> dict[str, Any]:
    """A track without its stream URL: URLs expire, so they are never stored."""
    return {
        "key": track.key,
        "owner_id": track.owner_id,
        "audio_id": track.audio_id,
        "title": track.title,
        "artist": track.artist,
        "duration": track.duration,
        "thumb": track.thumb,
        "access_key": track.access_key,
        "has_lyrics": track.has_lyrics,
        "is_liked": track.is_liked,
    }


def track_from_state(data: Mapping[str, Any]) -> Track:
    owner_id = int(data.get("owner_id", 0))
    audio_id = int(data.get("audio_id", 0))
    return Track(
        key=str(data.get("key") or f"{owner_id}_{audio_id}"),
        owner_id=owner_id,
        audio_id=audio_id,
        title=str(data.get("title", "")),
        artist=str(data.get("artist", "")),
        duration=int(data.get("duration", 0) or 0),
        thumb=str(data.get("thumb", "")),
        access_key=str(data.get("access_key", "")),
        has_lyrics=bool(data.get("has_lyrics")),
        is_liked=bool(data.get("is_liked")),
    )


# ------------------------------------------------------------------- mpv ----


class MpvError(RuntimeError):
    pass


class Mpv:
    """One long-lived mpv process, driven over its JSON IPC socket.

    Two sockets are used: one for commands (request and response) and one for
    the property observations and events, so a slow event consumer can never
    stall a command.
    """

    def __init__(self, socket_path: Path, on_event: Callable[[str, Any], None]) -> None:
        self.socket_path = Path(socket_path)
        self.on_event = on_event
        self.process: subprocess.Popen | None = None
        self._command_lock = threading.Lock()
        self._request_id = 0
        self._event_thread: threading.Thread | None = None
        self._stop = threading.Event()

    def ensure(self) -> None:
        if (
            self.process
            and self.process.poll() is None
            and self.socket_path.exists()
        ):
            self._ensure_events()
            return
        # A service restart leaves the previous mpv orphaned: it holds the
        # socket, keeps playing, and would fight the new one. Its pid is kept on
        # disk for exactly this reason.
        self._kill_stale()
        self.socket_path.unlink(missing_ok=True)
        self.process = subprocess.Popen(
            [
                MPV,
                "--no-config",
                "--idle=yes",
                "--no-video",
                "--audio-display=no",
                "--force-window=no",
                "--really-quiet",
                "--cache=yes",
                "--demuxer-readahead-secs=20",
                f"--input-ipc-server={self.socket_path}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.socket_path.exists():
                try:
                    self.command("get_property", "idle-active")
                    break
                except MpvError:
                    pass
            time.sleep(0.05)
        else:
            raise MpvError("mpv did not start")
        if self.process and self.process.pid:
            try:
                MPV_PID_FILE.write_text(str(self.process.pid), encoding="utf-8")
            except OSError:
                pass
        self._ensure_events()

    def _kill_stale(self) -> None:
        """Terminate an mpv left behind by a previous service run."""
        try:
            pid = int(MPV_PID_FILE.read_text(encoding="utf-8").strip())
        except (OSError, ValueError):
            return
        try:
            command = Path(f"/proc/{pid}/cmdline").read_bytes().decode(errors="replace")
        except OSError:
            MPV_PID_FILE.unlink(missing_ok=True)
            return
        if str(self.socket_path) not in command:
            MPV_PID_FILE.unlink(missing_ok=True)
            return
        log(f"stopping a leftover mpv (pid {pid})")
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if not Path(f"/proc/{pid}").exists():
                break
            time.sleep(0.05)
        else:
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        MPV_PID_FILE.unlink(missing_ok=True)

    def _connect(self) -> socket.socket:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(10)
        connection.connect(str(self.socket_path))
        return connection

    def command(self, *args: Any) -> Any:
        with self._command_lock:
            self._request_id += 1
            request_id = self._request_id
            payload = json.dumps({"command": list(args), "request_id": request_id})
            with self._connect() as connection:
                connection.sendall(payload.encode() + b"\n")
                buffer = b""
                while len(buffer) < IPC_MAX_BYTES:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        if not line.strip():
                            continue
                        try:
                            message = json.loads(line)
                        except json.JSONDecodeError:
                            continue
                        if message.get("request_id") != request_id:
                            continue
                        if message.get("error") != "success":
                            raise MpvError(str(message.get("error")))
                        return message.get("data")
            raise MpvError("mpv closed the connection")

    def _ensure_events(self) -> None:
        if self._event_thread and self._event_thread.is_alive():
            return
        self._stop.clear()
        self._event_thread = threading.Thread(target=self._read_events, daemon=True)
        self._event_thread.start()

    def _read_events(self) -> None:
        try:
            connection = self._connect()
        except OSError as exc:
            log(f"mpv events: cannot connect ({exc})")
            return
        with connection:
            for name, ident in (
                ("time-pos", 1),
                ("duration", 2),
                ("pause", 3),
                ("eof-reached", 4),
                ("volume", 5),
                ("idle-active", 6),
            ):
                try:
                    connection.sendall(
                        json.dumps(
                            {"command": ["observe_property", ident, name]}
                        ).encode()
                        + b"\n"
                    )
                except OSError:
                    return
            buffer = b""
            while not self._stop.is_set():
                try:
                    chunk = connection.recv(65536)
                except OSError:
                    break
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if not line.strip():
                        continue
                    try:
                        message = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    event = message.get("event")
                    if event == "property-change":
                        self.on_event(str(message.get("name", "")), message.get("data"))
                    elif event == "end-file":
                        # `reason` is the only thing that separates a finished
                        # track from the end of the previous file caused by our
                        # own `loadfile`.
                        self.on_event("end-file", message.get("reason"))
                    elif event in ("file-loaded", "start-file"):
                        self.on_event(event, None)

    def stop(self) -> None:
        self._stop.set()
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.socket_path.unlink(missing_ok=True)
        try:
            if MPV_PID_FILE.read_text(encoding="utf-8").strip() == str(
                self.process.pid if self.process else ""
            ):
                MPV_PID_FILE.unlink(missing_ok=True)
        except OSError:
            pass


# ----------------------------------------------------------------- player ----


class Player:
    """Queue, playback state, and the bridge to mpv.

    Playback is download-then-play when the cache is on: the URL is resolved,
    the whole track is fetched, and mpv plays the local file. With the cache
    off, mpv streams the HLS URL directly.
    """

    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.mpv = Mpv(MPV_SOCKET, self._mpv_event)
        self.record: dict[str, Any] | None = None
        self.client: VkClient | None = None
        self.cache = AudioCache(AUDIO_CACHE_DIR, DEFAULT_PREFERENCES["cacheLimitMb"] * 1024 * 1024)
        self.preferences = dict(DEFAULT_PREFERENCES)
        self.queue: list[Track] = []
        self.index = -1
        self.shuffle = False
        self.repeat = "off"  # off | all | one
        self.volume = 70
        self.position = 0
        self.duration = 0
        self.playing = False
        self.paused = False
        self.loading = False
        self.error = ""
        self.notice = ""
        self.unplayable: set[str] = set()
        self.source: dict[str, str] = {"kind": "", "id": "", "title": ""}
        self._download_thread: threading.Thread | None = None
        self._download_cancel = threading.Event()
        self._ignore_events_until = 0.0
        self._ignore_pause_until = 0.0
        self.playing_from_cache = False
        self._mpris: MprisBridge | None = None
        self._load_state()

    # -- persistence -------------------------------------------------------

    def _load_state(self) -> None:
        try:
            stored = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        self.preferences.update(stored.get("preferences") or {})
        self.cache.limit_bytes = max(
            0, int(self.preferences.get("cacheLimitMb", 256)) * 1024 * 1024
        )
        self.volume = int(stored.get("volume", self.volume) or self.volume)
        self.shuffle = bool(stored.get("shuffle", False))
        self.repeat = str(stored.get("repeat", "off"))
        self.source = stored.get("source") or self.source
        restored = [track_from_state(item) for item in stored.get("queue") or []]
        self.queue = restored
        self.index = int(stored.get("index", -1))
        self.position = int(stored.get("position", 0) or 0)
        # The queue and the position are restored so the bar shows what was
        # playing, but playback does not resume on its own: music starting by
        # itself at login is not something a user asked for.
        restored_track = self.current_track()
        if restored_track:
            self.duration = restored_track.duration
        self.position = min(self.position, self.duration) if self.duration else self.position

    def save_state(self) -> None:
        with self.lock:
            payload = {
                "preferences": self.preferences,
                "volume": self.volume,
                "shuffle": self.shuffle,
                "repeat": self.repeat,
                "source": self.source,
                "queue": [track_to_state(track) for track in self.queue],
                "index": self.index,
                "position": self.position,
            }
            track = self.current_track()
            if track:
                payload["trackKey"] = track.key
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            os.chmod(CONFIG_DIR, 0o700)
            tmp = STATE_FILE.with_suffix(".tmp")
            tmp.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            os.chmod(tmp, 0o600)
            os.replace(tmp, STATE_FILE)
        except OSError as exc:
            log(f"cannot save state: {exc}")

    # -- session -----------------------------------------------------------

    def authenticate(self, record: Mapping[str, Any]) -> None:
        self.record = dict(record)
        self.client = VkClient(
            self.record["access_token"],
            user_agent=str(self.record.get("user_agent") or WEB_USER_AGENT),
            client_id=str(self.record.get("client_id") or WEB_APP_ID),
            device_id=self.record.get("device_id"),
        )

    def load_session(self) -> bool:
        """Load the stored token, refreshing a web token that is near expiry."""
        record = self.record or load_record()
        if record is None:
            return False
        if record.get("mode") == "web" and needs_refresh(record):
            try:
                record = refresh_web_record(record)
                log("web token refreshed")
            except VkAuthError as exc:
                log(f"token refresh failed: {exc}")
        self.authenticate(record)
        return True

    @property
    def authenticated(self) -> bool:
        return self.client is not None and not self.client.halted

    def halted_reason(self) -> str:
        if self.client and self.client.halted:
            return self.client.halted_reason
        return ""

    def api(self, function: Callable[[], Any]) -> Any:
        """Run one API call, translating failures into state the UI can show."""
        if not self.load_session():
            raise VkApiError(0, "not signed in", method="session")
        assert self.client is not None
        try:
            return function()
        except VkHaltError as exc:
            message = HALT_MESSAGES.get(exc.code) or f"VK: {classify(exc)}"
            self.error = message
            self.notice = message
            if self.client:
                self.client.halt(classify(exc))
            log(f"halted: {message} ({exc.message})")
            raise
        except VkApiError as exc:
            self.error = f"VK: {classify(exc)}"
            log(f"api error: {classify(exc)} — {exc.message}")
            raise

    # -- sources -----------------------------------------------------------

    def sections(self) -> list[dict[str, Any]]:
        sections = self.api(lambda: self.client.sections())  # type: ignore[union-attr]
        return [asdict(section) for section in sections]

    def home(self) -> dict[str, Any]:
        user_id = int((self.record or {}).get("user_id") or 0)
        sections, audios, playlists, default = self.api(
            lambda: self.client.catalog_home(owner_id=user_id or None)  # type: ignore[union-attr]
        )
        return {
            "sections": [asdict(section) for section in sections],
            "default": default,
            "recent": [track_to_state(track) for track in audios],
            "playlists": [asdict(playlist) for playlist in playlists],
        }

    def section_items(self, section_id: str, offset: str | None = None) -> dict[str, Any]:
        resolved = self._resolve_section_id(section_id)
        blocks = self.api(lambda: self.client.section(resolved, start_from=offset))  # type: ignore[union-attr]
        return {
            "id": resolved,
            "title": blocks.title,
            "next": blocks.next_offset,
            "tracks": [track_to_state(track) for track in blocks.audios],
            "playlists": [asdict(playlist) for playlist in blocks.playlists],
        }

    def _resolve_section_id(self, reference: str) -> str:
        """Accept either an opaque section id or a friendly slug.

        VK's section ids are long opaque strings, while the same sections are
        also addressable by the slug in their url (`?section=all`). Callers
        should be able to say `all` and get "Моя музыка" without knowing the id,
        so a slug is looked up in `catalog.getAudio` once.
        """
        if not reference:
            reference = "all"
        if reference.startswith("PU") or reference.isdigit():
            return reference
        for section in self.api(lambda: self.client.sections()):  # type: ignore[union-attr]
            if section.url.endswith(f"section={reference}") or section.id == reference:
                return section.id
        raise VkApiError(0, f"unknown section: {reference}", method="catalog.getAudio")

    def search_items(self, query: str, offset: int | None = None) -> dict[str, Any]:
        tracks = self.api(lambda: self.client.search(query, offset=offset))  # type: ignore[union-attr]
        return {"query": query, "tracks": [track_to_state(track) for track in tracks]}

    def resolve_url(self, track: Track) -> str:
        """Always ask for the URL at play time: stored URLs are short-lived."""
        fresh = self.api(lambda: self.client.audio_get_by_keys([track.key]))  # type: ignore[union-attr]
        for candidate in fresh:
            if candidate.url:
                return candidate.url
        return ""

    # -- playback ----------------------------------------------------------

    def current_track(self) -> Track | None:
        if 0 <= self.index < len(self.queue):
            return self.queue[self.index]
        return None

    def play(self, tracks: Sequence[Track], *, index: int = 0, source: Mapping[str, str] | None = None) -> None:
        with self.lock:
            self.queue = list(tracks)
            self.index = max(0, min(index, len(self.queue) - 1)) if self.queue else -1
            self.unplayable.clear()
            if source:
                self.source = dict(source)
            self._download_cancel.set()
            if not self.queue:
                self.error = "Список пуст"
                return
            self._start_current()

    def _start_current(self) -> None:
        track = self.current_track()
        if track is None:
            self.playing = False
            return
        self.position = 0
        self.duration = track.duration
        self.error = ""
        # `playing` is not set optimistically: mpv's `file-loaded` event is what
        # says the track really started. Until then the track is loading, which
        # is also what stops the `pause` event mpv emits during a file switch
        # from blinking the bar icon.
        self.loading = True
        self.playing = False
        self.paused = False
        self._publish_mpris()
        try:
            url = self.resolve_url(track)
        except (VkApiError, VkHaltError):
            self.playing = False
            self._publish_mpris()
            return
        if not url:
            self._mark_unplayable(track, "нет ссылки на поток")
            return
        if self.preferences.get("cacheEnabled", True) and self.cache.limit_bytes > 0:
            cached = self.cache.get(track.key)
            if cached:
                self._play_file(cached)
                return
            self.loading = True
            self._publish_mpris()
            self._start_download(track, url)
            return
        self._play_url(url)

    def _start_download(self, track: Track, url: str) -> None:
        cancel = threading.Event()
        self._download_cancel = cancel

        def worker() -> None:
            try:
                path = self.cache.download(url, track.key)
            except CacheError as exc:
                log(f"cache failed for {track.key}: {exc}")
                with self.lock:
                    if not cancel.is_set():
                        self.loading = False
                        self._mark_unplayable(track, str(exc))
                return
            with self.lock:
                if cancel.is_set():
                    return
                self.loading = False
                self._play_file(path)

        self._download_thread = threading.Thread(target=worker, daemon=True)
        self._download_thread.start()

    def _play_file(self, path: Path) -> None:
        self._begin_load()
        try:
            self.mpv.ensure()
            self.mpv.command("loadfile", str(path), "replace")
            self.mpv.command("set_property", "volume", self.volume)
        except (MpvError, OSError) as exc:
            self.error = f"mpv: {safe_error_text(exc)}"
            self.loading = False
            self.playing = False
        self.playing_from_cache = True
        self._publish_mpris()

    def _play_url(self, url: str) -> None:
        self._begin_load()
        try:
            self.mpv.ensure()
            self.mpv.command("loadfile", url, "replace")
            self.mpv.command("set_property", "volume", self.volume)
        except (MpvError, OSError) as exc:
            self.error = f"mpv: {safe_error_text(exc)}"
            self.loading = False
            self.playing = False
        # Seeking a remote HLS stream means refetching and decrypting segments,
        # so the widget only seeks freely while the track is a local file.
        self.playing_from_cache = False
        self._publish_mpris()

    def _begin_load(self) -> None:
        """Mark a file switch, so events from the previous file are ignored."""
        self.position = 0
        self.paused = False
        self.loading = True
        self._ignore_events_until = time.monotonic() + 1.0

    def _mark_unplayable(self, track: Track, reason: str) -> None:
        self.unplayable.add(track.key)
        self.notice = f"Пропущен трек «{track.label}»: {reason}"
        log(self.notice)
        self.next(automatic=True)

    def next(self, *, automatic: bool = False) -> None:
        with self.lock:
            if not self.queue:
                return
            if automatic and self.repeat == "one":
                self._start_current()
                return
            candidates = [
                i for i, track in enumerate(self.queue) if track.key not in self.unplayable
            ]
            after = [i for i in candidates if i > self.index]
            if after:
                self.index = after[0]
            elif self.repeat == "all":
                self.index = candidates[0] if candidates else self.index
            else:
                self.playing = False
                self.paused = False
                self._publish_mpris()
                self.save_state()
                return
            self._start_current()
            self.save_state()

    def play_from(self, index: int) -> None:
        """Jump to a queue entry, used by the popup's track list."""
        with self.lock:
            if not self.queue:
                return
            if 0 <= index < len(self.queue):
                self.index = index
            self._start_current()
            self.save_state()

    def previous(self) -> None:
        with self.lock:
            if self.position > 5:
                self.seek(0)
                return
            if self.index > 0:
                self.index -= 1
            self._start_current()
            self.save_state()

    def toggle_pause(self) -> None:
        with self.lock:
            if not self.playing:
                if self.current_track():
                    self._start_current()
                return
            try:
                self.mpv.ensure()
                self.mpv.command("cycle", "pause")
            except (MpvError, OSError) as exc:
                self.error = f"mpv: {exc}"
            self.paused = not self.paused
            self._publish_mpris()

    def stop(self) -> None:
        with self.lock:
            self._download_cancel.set()
            try:
                self.mpv.command("stop")
            except (MpvError, OSError):
                pass
            self.playing = False
            self.paused = False
            self.position = 0
            self._publish_mpris()
            self.save_state()

    def seek(self, position: int) -> None:
        with self.lock:
            position = max(0, int(position))
            try:
                self.mpv.ensure()
                self.mpv.command("set_property", "time-pos", position)
            except (MpvError, OSError) as exc:
                self.error = f"mpv: {safe_error_text(exc)}"
            self.position = position
            # mpv briefly reports `pause` while it re-seeks; without this window
            # the bar icon blinks on every drag of the slider.
            self._ignore_pause_until = time.monotonic() + 0.5
            self._publish_mpris(seeked=True)

    def set_volume(self, volume: int, *, persist: bool = True) -> None:
        with self.lock:
            self.volume = max(0, min(100, int(volume)))
            try:
                self.mpv.ensure()
                self.mpv.command("set_property", "volume", self.volume)
            except (MpvError, OSError) as exc:
                self.error = f"mpv: {safe_error_text(exc)}"
            self._publish_mpris()
            if persist:
                self.save_state()

    def set_shuffle(self, enabled: bool) -> None:
        with self.lock:
            self.shuffle = bool(enabled)
            self.save_state()

    def set_repeat(self, mode: str) -> None:
        with self.lock:
            self.repeat = mode if mode in ("off", "all", "one") else "off"
            self.save_state()

    def set_preferences(self, values: Mapping[str, Any]) -> None:
        with self.lock:
            for key, value in values.items():
                if key in DEFAULT_PREFERENCES:
                    self.preferences[key] = value
            if "cacheLimitMb" in values:
                self.cache.limit_bytes = max(0, int(self.preferences["cacheLimitMb"]) * 1024 * 1024)
            self.save_state()

    # -- mpv events --------------------------------------------------------

    def _mpv_event(self, name: str, data: Any) -> None:
        """Translate mpv events into playback state.

        The subtlety here is `end-file`: mpv emits it both when a track ends
        naturally (`reason == "eof"`) and when the file is replaced by our own
        `loadfile`, which used to reset the state on every track change. Only
        an `eof` advances the queue; the rest is ignored.
        """
        with self.lock:
            if name == "file-loaded":
                self.loading = False
                self.playing = True
                self.paused = False
                self.position = 0
                self._publish_mpris()
                return
            if name == "end-file":
                if data == "eof":
                    self.next(automatic=True)
                elif data == "error":
                    track = self.current_track()
                    if track:
                        self._mark_unplayable(track, "mpv не смог открыть поток")
                elif data in ("stop", "quit"):
                    self.playing = False
                    self.paused = False
                    self._publish_mpris()
                return
            # Property changes from before a file switch arrive after the
            # switch; they would drag the position back to the old track.
            if time.monotonic() < self._ignore_events_until:
                return
            if name == "time-pos" and isinstance(data, (int, float)):
                self.position = int(data)
            elif name == "duration" and isinstance(data, (int, float)):
                self.duration = int(data)
            elif name == "pause" and isinstance(data, bool):
                if data and (self.loading or time.monotonic() < self._ignore_pause_until):
                    return
                self.paused = data
                self._publish_mpris()
            elif name == "volume" and isinstance(data, (int, float)):
                self.volume = int(data)

    # -- MPRIS -------------------------------------------------------------

    def attach_mpris(self) -> None:
        self._mpris = MprisBridge(self)
        self._mpris.start()

    def _publish_mpris(self, seeked: bool = False) -> None:
        if self._mpris:
            self._mpris.publish(seeked)

    def mpris_state(self) -> dict[str, Any]:
        track = self.current_track()
        with self.lock:
            return {
                "playing": self.playing and not self.paused,
                "paused": self.paused,
                "position": self.position,
                "duration": self.duration,
                "volume": self.volume,
                "title": track.title if track else "",
                "artist": track.artist if track else "",
                "artists": [{"name": track.artist}] if track else [],
                "artUrl": track.thumb if track else "",
                "trackId": track.key if track else "",
                "hasQueue": bool(self.queue),
                "shuffle": self.shuffle,
                "repeat": self.repeat,
            }

    # -- snapshots ---------------------------------------------------------

    def status(self) -> dict[str, Any]:
        track = self.current_track()
        with self.lock:
            return {
                "authenticated": self.authenticated,
                "halted": self.halted_reason(),
                "loading": self.loading,
                "playing": self.playing,
                "paused": self.paused,
                "position": self.position,
                "duration": self.duration,
                "volume": self.volume,
                "shuffle": self.shuffle,
                "repeat": self.repeat,
                "error": self.error,
                "notice": self.notice,
                "source": self.source,
                "index": self.index,
                "queueLength": len(self.queue),
                "unplayable": sorted(self.unplayable),
                "streaming": not self.playing_from_cache,
                "track": track_to_state(track) if track else None,
                "next": track_to_state(self.queue[self.index + 1])
                if 0 <= self.index + 1 < len(self.queue)
                else None,
                "preferences": self.preferences,
                "cache": self.cache.stats(),
                "session": session_summary(self.record),
            }


def session_summary(record: Mapping[str, Any] | None) -> dict[str, Any]:
    if not record:
        return {"mode": "", "user_id": None, "has_cookies": False, "expires_in": 0}
    expires = int(record.get("expires", 0) or 0)
    return {
        "mode": str(record.get("mode", "")),
        "user_id": record.get("user_id"),
        "has_cookies": all((record.get("cookies") or {}).get(name) for name in COOKIE_NAMES),
        "expires_in": max(0, expires - int(time.time())) if expires else 0,
    }


# ---------------------------------------------------------------- MPRIS -----


def _import_dbus() -> Any:
    from dbus_next import Variant  # noqa: F401
    from dbus_next.aio import MessageBus
    from dbus_next.constants import PropertyAccess
    from dbus_next.service import (
        ServiceInterface,
        dbus_property,
        method,
        signal as dbus_signal,
    )

    return MessageBus, PropertyAccess, ServiceInterface, dbus_property, method, dbus_signal, Variant


class MprisBridge:
    """Exports `org.mpris.MediaPlayer2` on a private asyncio loop."""

    def __init__(self, player: Player) -> None:
        self.player = player
        self.loop: Any = None
        self.interface: Any = None

    def start(self) -> None:
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self) -> None:
        import asyncio

        self.loop = asyncio.new_event_loop()
        asyncio.set_event_loop(self.loop)
        try:
            self.loop.run_until_complete(self._setup())
        except Exception as exc:  # noqa: BLE001 - MPRIS is optional
            log(f"MPRIS unavailable: {exc}\n{traceback.format_exc()}")
            return
        self.loop.run_forever()

    async def _setup(self) -> None:
        import asyncio

        (
            MessageBus,
            PropertyAccess,
            ServiceInterface,
            dbus_property,
            method,
            dbus_signal,
            Variant,
        ) = _import_dbus()
        player = self.player

        class Root(ServiceInterface):
            def __init__(self) -> None:
                super().__init__("org.mpris.MediaPlayer2")

            @method()
            def Raise(self):
                return None

            @method()
            def Quit(self):
                return None

            @dbus_property(access=PropertyAccess.READ)
            def CanQuit(self) -> "b":
                return False

            @dbus_property(access=PropertyAccess.READ)
            def CanRaise(self) -> "b":
                return False

            @dbus_property(access=PropertyAccess.READ)
            def HasTrackList(self) -> "b":
                return False

            @dbus_property(access=PropertyAccess.READ)
            def Identity(self) -> "s":
                return "VK Music"

            @dbus_property(access=PropertyAccess.READ)
            def DesktopEntry(self) -> "s":
                return ""

            @dbus_property(access=PropertyAccess.READ)
            def SupportedUriSchemes(self) -> "as":
                return []

            @dbus_property(access=PropertyAccess.READ)
            def SupportedMimeTypes(self) -> "as":
                return []

        class PlayerInterface(ServiceInterface):
            def __init__(self) -> None:
                super().__init__("org.mpris.MediaPlayer2.Player")
                self.last: dict[str, Any] = {}

            def state(self) -> dict[str, Any]:
                return player.mpris_state()

            @method()
            def Next(self):
                player.next()

            @method()
            def Previous(self):
                player.previous()

            @method()
            def Pause(self):
                if player.mpris_state()["playing"]:
                    player.toggle_pause()

            @method()
            def PlayPause(self):
                player.toggle_pause()

            @method()
            def Stop(self):
                player.stop()

            @method()
            def Play(self):
                if not player.mpris_state()["playing"]:
                    player.toggle_pause()

            @method()
            def Seek(self, offset: "x"):
                state = player.mpris_state()
                player.seek(int(state["position"]) + int(offset) // 1_000_000)

            @method()
            def SetPosition(self, track_id: "o", position: "x"):
                player.seek(int(position) // 1_000_000)

            @method()
            def OpenUri(self, uri: "s"):
                return None

            @dbus_signal()
            def Seeked(self, position: "x") -> "x":  # type: ignore[empty-body]
                ...

            @dbus_property(access=PropertyAccess.READ)
            def PlaybackStatus(self) -> "s":
                state = self.state()
                if state["playing"]:
                    return "Playing"
                return "Paused" if state["paused"] else "Stopped"

            @dbus_property(access=PropertyAccess.READWRITE)
            def LoopStatus(self) -> "s":
                return {"one": "Track", "all": "Playlist"}.get(self.state()["repeat"], "None")

            @LoopStatus.setter
            def LoopStatus(self, value: "s") -> None:
                player.set_repeat({"Track": "one", "Playlist": "all"}.get(value, "off"))

            @dbus_property(access=PropertyAccess.READWRITE)
            def Shuffle(self) -> "b":
                return bool(self.state()["shuffle"])

            @Shuffle.setter
            def Shuffle(self, value: "b") -> None:
                player.set_shuffle(bool(value))

            @dbus_property(access=PropertyAccess.READ)
            def Rate(self) -> "d":
                return 1.0

            @dbus_property(access=PropertyAccess.READWRITE)
            def Volume(self) -> "d":
                return float(self.state()["volume"]) / 100.0

            @Volume.setter
            def Volume(self, value: "d") -> None:
                player.set_volume(round(float(value) * 100))

            @dbus_property(access=PropertyAccess.READ)
            def Position(self) -> "x":
                return int(self.state()["position"]) * 1_000_000

            @dbus_property(access=PropertyAccess.READ)
            def MinimumRate(self) -> "d":
                return 1.0

            @dbus_property(access=PropertyAccess.READ)
            def MaximumRate(self) -> "d":
                return 1.0

            @dbus_property(access=PropertyAccess.READ)
            def CanGoNext(self) -> "b":
                return bool(self.state()["hasQueue"])

            @dbus_property(access=PropertyAccess.READ)
            def CanGoPrevious(self) -> "b":
                return bool(self.state()["hasQueue"])

            @dbus_property(access=PropertyAccess.READ)
            def CanPlay(self) -> "b":
                return bool(self.state()["hasQueue"])

            @dbus_property(access=PropertyAccess.READ)
            def CanPause(self) -> "b":
                return bool(self.state()["hasQueue"])

            @dbus_property(access=PropertyAccess.READ)
            def CanSeek(self) -> "b":
                return bool(self.state()["hasQueue"])

            @dbus_property(access=PropertyAccess.READ)
            def CanControl(self) -> "b":
                return True

            @dbus_property(access=PropertyAccess.READ)
            def Metadata(self) -> "a{sv}":  # type: ignore
                state = self.state()
                metadata: dict[str, Any] = {
                    "mpris:trackid": Variant("o", f"/org/mpris/MediaPlayer2/track/{state['trackId'] or 'none'}"),
                    "xesam:title": Variant("s", state["title"]),
                    "xesam:artist": Variant(
                        "as", [a["name"] for a in state["artists"] if a.get("name")]
                    ),
                    "mpris:length": Variant("x", int(state["duration"]) * 1_000_000),
                }
                if state["artUrl"]:
                    metadata["mpris:artUrl"] = Variant("s", state["artUrl"])
                return metadata

            def publish(self, seeked: bool = False) -> None:
                properties = {
                    "PlaybackStatus": self.PlaybackStatus,
                    "LoopStatus": self.LoopStatus,
                    "Shuffle": self.Shuffle,
                    "Metadata": self.Metadata,
                    "Volume": self.Volume,
                    "CanGoNext": self.CanGoNext,
                    "CanGoPrevious": self.CanGoPrevious,
                    "CanPlay": self.CanPlay,
                    "CanPause": self.CanPause,
                    "CanSeek": self.CanSeek,
                }
                changed = {k: v for k, v in properties.items() if self.last.get(k) != v}
                self.last = properties
                if changed:
                    self.emit_properties_changed(changed)
                if seeked:
                    self.Seeked(self.Position)

        bus = await MessageBus().connect()
        bus.export("/org/mpris/MediaPlayer2", Root())
        self.interface = PlayerInterface()
        bus.export("/org/mpris/MediaPlayer2", self.interface)
        await bus.request_name("org.mpris.MediaPlayer2.omarchy_vk_music")
        self.interface.publish()
        log("MPRIS exported as org.mpris.MediaPlayer2.omarchy_vk_music")
        await asyncio.Event().wait()

    def publish(self, seeked: bool = False) -> None:
        if self.loop and self.interface:
            self.loop.call_soon_threadsafe(self.interface.publish, seeked)


# ---------------------------------------------------------------- server ----


class Backend:
    """Command dispatch. Every command returns a JSON-serialisable dict."""

    def __init__(self) -> None:
        self.player = Player()
        self.server_socket: socket.socket | None = None
        self.mobile_auth: dict[str, Any] = {}
        # Counts every request the service answered. A bar widget polling on a
        # timer keeps this rising even when nothing seems to happen, which is
        # the quickest way to tell a live widget from a dead one.
        self.served = 0

    # -- commands ----------------------------------------------------------

    def handle(self, request: Mapping[str, Any]) -> dict[str, Any]:
        command = str(request.get("command", "status"))
        self.served += 1
        handler = getattr(self, f"cmd_{command}", None)
        if handler is None:
            return error_payload("unknown_command", f"unknown command: {command}")
        params = {k: v for k, v in request.items() if k != "command"}
        try:
            result = handler(**params)
        except TypeError as exc:
            return error_payload("bad_request", str(exc))
        except VkHaltError as exc:
            return error_payload("halted", self.player.error or classify(exc))
        except VkApiError as exc:
            return error_payload("vk_error", f"{classify(exc)}: {exc.message}")
        except VkAuthError as exc:
            return error_payload("auth_error", str(exc))
        except CacheError as exc:
            return error_payload("cache_error", str(exc))
        except MpvError as exc:
            return error_payload("mpv_error", str(exc))
        except Exception as exc:  # noqa: BLE001 - the UI must get an answer
            log(f"command {command} failed: {exc!r}")
            return error_payload("internal_error", repr(exc))
        return {"ok": True, "data": result}

    # -- session -----------------------------------------------------------

    def cmd_status(self) -> dict[str, Any]:
        data = self.player.status()
        data["served"] = self.served
        return data

    def cmd_session(self) -> dict[str, Any]:
        return session_summary(self.player.record)

    def cmd_auth_web(self, cookies: str | None = None, fromBrowser: bool = True) -> dict[str, Any]:
        if cookies:
            parsed = parse_cookies(cookies)
        elif fromBrowser:
            parsed = fetch_browser_cookies()
        else:
            raise VkAuthError("no cookies given")
        token = request_web_token(parsed)
        save_web_token(token, parsed)
        self.player.record = None
        self.player.load_session()
        self.player.error = ""
        log("signed in with a web token")
        return session_summary(self.player.record)

    def cmd_auth_mobile_start(self, login: str = "", password: str = "", client: str = "vk-android") -> dict[str, Any]:
        """First step of the fallback path; the password never leaves memory."""
        if not login or not password:
            raise VkAuthError("login and password are required")
        mobile = MOBILE_CLIENTS.get(client) or MOBILE_CLIENTS["vk-android"]
        payload = request_mobile_token(mobile, login, password)
        if payload.get("access_token"):
            save_mobile_token(mobile, payload)
            self.mobile_auth = {}
            self.player.record = None
            self.player.load_session()
            return {"done": True, "session": session_summary(self.player.record)}
        self.mobile_auth = {
            "login": login,
            "password": password,
            "client": client,
        }
        return self._mobile_step_result(payload, mobile)

    def cmd_auth_mobile_step(self, code: str = "", successToken: str = "") -> dict[str, Any]:
        pending = self.mobile_auth
        if not pending:
            raise VkAuthError("no login in progress")
        mobile = MOBILE_CLIENTS.get(pending["client"]) or MOBILE_CLIENTS["vk-android"]
        payload = request_mobile_token(
            mobile,
            pending["login"],
            pending["password"],
            code=code or None,
            success_token=successToken or None,
        )
        if payload.get("access_token"):
            save_mobile_token(mobile, payload)
            self.mobile_auth = {}
            self.player.record = None
            self.player.load_session()
            return {"done": True, "session": session_summary(self.player.record)}
        return self._mobile_step_result(payload, mobile)

    def _mobile_step_result(self, payload: Mapping[str, Any], mobile: Any) -> dict[str, Any]:
        error = str(payload.get("error", ""))
        if error == "need_validation":
            sid = str(payload.get("validation_sid", ""))
            try:
                request_sms_code(mobile, sid)
            except Exception as exc:  # noqa: BLE001
                log(f"could not request an SMS code: {exc}")
            return {
                "done": False,
                "step": "code",
                "validationType": str(payload.get("validation_type", "")),
                "phoneMask": str(payload.get("phone_mask", "")),
            }
        if error == "need_captcha":
            return {
                "done": False,
                "step": "captcha",
                "redirectUri": str(payload.get("redirect_uri", "")),
            }
        raise VkAuthError(str(payload.get("error_description") or error or payload))

    def cmd_logout(self) -> dict[str, Any]:
        TOKEN_FILE.unlink(missing_ok=True)
        self.player.record = None
        self.player.client = None
        self.player.error = ""
        log("signed out")
        return {"signedOut": True}

    # -- sources -----------------------------------------------------------

    def cmd_sections(self) -> list[dict[str, Any]]:
        return self.player.sections()

    def cmd_home(self) -> dict[str, Any]:
        return self.player.home()

    def cmd_section(self, id: str, startFrom: str | None = None) -> dict[str, Any]:
        return self.player.section_items(id, startFrom)

    def cmd_search(self, query: str = "", offset: int | None = None) -> dict[str, Any]:
        if not query.strip():
            return {"query": "", "tracks": []}
        return self.player.search_items(query, offset)

    def cmd_suggestions(self, query: str = "") -> list[str]:
        if not query.strip():
            return []
        return self.player.api(lambda: self.player.client.search_suggestions(query))  # type: ignore[union-attr]

    # -- playback ----------------------------------------------------------

    def _tracks_from_state(self, tracks: Sequence[Mapping[str, Any]]) -> list[Track]:
        return [track_from_state(item) for item in tracks]

    def cmd_play_tracks(
        self,
        tracks: Sequence[Mapping[str, Any]],
        index: int = 0,
        kind: str = "",
        id: str = "",
        title: str = "",
    ) -> dict[str, Any]:
        self.player.play(
            self._tracks_from_state(tracks),
            index=index,
            source={"kind": kind, "id": id, "title": title},
        )
        return self.player.status()

    def cmd_play_section(self, id: str, index: int = 0, title: str = "") -> dict[str, Any]:
        items = self.player.section_items(id)
        self.player.play(
            self._tracks_from_state(items["tracks"]),
            index=index,
            source={"kind": "section", "id": id, "title": title or items["title"]},
        )
        return self.player.status()

    def cmd_play_search(self, query: str, index: int = 0) -> dict[str, Any]:
        items = self.player.search_items(query)
        self.player.play(
            self._tracks_from_state(items["tracks"]),
            index=index,
            source={"kind": "search", "id": query, "title": f"Поиск: {query}"},
        )
        return self.player.status()

    def cmd_play_playlist(
        self, ownerId: int, playlistId: int, accessKey: str = "", title: str = ""
    ) -> dict[str, Any]:
        """Queue a playlist.

        VK exposes playlists two ways: as a catalog section (a `catalog.getAudio`
        block, which is where the user's own playlists arrive) and through the
        legacy `audio.get` with `album_id`. Both are tried, in that order,
        because the section form is what the web player itself uses.
        """
        tracks: list[Track] = []
        section_id = str(accessKey or "")
        if section_id:
            try:
                blocks = self.player.api(lambda: self.player.client.section(section_id))  # type: ignore[union-attr]
                tracks = list(blocks.audios)
            except (VkApiError, VkHaltError) as exc:
                log(f"playlist as a section failed, falling back: {exc}")
        if not tracks:
            tracks = list(
                self.player.api(  # type: ignore[union-attr]
                    lambda: self.player.client.audio_playlist_tracks(
                        int(ownerId), int(playlistId), access_key=str(accessKey)
                    )
                )
            )
        self.player.play(
            tracks,
            source={"kind": "playlist", "id": f"{ownerId}_{playlistId}", "title": title},
        )
        return self.player.status()

    def cmd_next(self) -> dict[str, Any]:
        self.player.next()
        return self.player.status()

    def cmd_jump(self, index: int = 0) -> dict[str, Any]:
        """Play the queue entry at `index`, so the popup's list is clickable."""
        self.player.play_from(int(index))
        return self.player.status()

    def cmd_previous(self) -> dict[str, Any]:
        self.player.previous()
        return self.player.status()

    def cmd_pause(self) -> dict[str, Any]:
        self.player.toggle_pause()
        return self.player.status()

    def cmd_stop(self) -> dict[str, Any]:
        self.player.stop()
        return self.player.status()

    def cmd_seek(self, value: int | float = 0) -> dict[str, Any]:
        self.player.seek(int(float(value)))
        return self.player.status()

    def cmd_volume(
        self, value: int | float | None = None, delta: int | None = None, live: bool = False
    ) -> dict[str, Any]:
        """Set or nudge the volume.

        `live` marks a step from a slider drag: mpv is told straight away, but
        the playback state is not written to disk until the drag ends, because
        a drag can produce twenty of these per second.
        """
        current = self.player.volume
        target = int(current + delta) if delta is not None else int(value or 0)
        self.player.set_volume(target, persist=not live)
        return self.player.status()

    def cmd_shuffle(self, enabled: bool | None = None) -> dict[str, Any]:
        self.player.set_shuffle(bool(enabled) if enabled is not None else not self.player.shuffle)
        return self.player.status()

    def cmd_repeat(self, mode: str = "off") -> dict[str, Any]:
        self.player.set_repeat(mode)
        return self.player.status()

    def cmd_queue(self) -> list[dict[str, Any]]:
        return [track_to_state(track) for track in self.player.queue]

    # -- preferences and cache ---------------------------------------------

    def cmd_preferences(self, **values: Any) -> dict[str, Any]:
        settings = values.pop("set", None)
        if isinstance(settings, Mapping):
            self.player.set_preferences(settings)
        elif values:
            self.player.set_preferences(values)
        return self.player.preferences

    def cmd_cache(self, action: str = "stats") -> dict[str, Any]:
        if action == "clear":
            removed = self.player.cache.clear()
            return {"removed": removed, **self.player.cache.stats()}
        if action == "cleanup":
            return {"removed": cleanup_stray_temp(AUDIO_CACHE_DIR), **self.player.cache.stats()}
        return self.player.cache.stats()

    def cmd_like(self, key: str = "", liked: bool = True) -> dict[str, Any]:
        if not key:
            raise VkApiError(0, "track key is required", method="like")
        owner_id, _, audio_id = key.partition("_")
        if liked:
            result = self.player.api(
                lambda: self.player.client.add(int(owner_id), int(audio_id))  # type: ignore[union-attr]
            )
            return {"liked": True, "result": result}
        result = self.player.api(
            lambda: self.player.client.delete(int(owner_id), int(audio_id))  # type: ignore[union-attr]
        )
        return {"liked": False, "result": result}

    def cmd_lyrics(self, key: str = "") -> dict[str, Any]:
        if not key:
            raise VkApiError(0, "track key is required", method="lyrics")
        owner_id, _, audio_id = key.partition("_")
        track = Track(
            key=key,
            owner_id=int(owner_id or 0),
            audio_id=int(audio_id or 0),
            title="",
            artist="",
            duration=0,
        )
        return self.player.api(lambda: self.player.client.audio_lyrics(track))  # type: ignore[union-attr]

    # -- lifecycle ---------------------------------------------------------

    def start(self) -> None:
        self.player.load_session()
        self.player.attach_mpris()
        self.server_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        RUNTIME_DIR.mkdir(parents=True, exist_ok=True)
        SOCKET_PATH.unlink(missing_ok=True)
        self.server_socket.bind(str(SOCKET_PATH))
        os.chmod(SOCKET_PATH, 0o600)
        self.server_socket.listen(16)
        log(f"listening on {SOCKET_PATH}")
        cleanup_stray_temp(AUDIO_CACHE_DIR)
        while True:
            try:
                connection, _ = self.server_socket.accept()
            except OSError:
                break
            threading.Thread(
                target=self._serve, args=(connection,), daemon=True
            ).start()

    def _serve(self, connection: socket.socket) -> None:
        with connection:
            buffer = b""
            while len(buffer) < IPC_MAX_BYTES:
                chunk = connection.recv(65536)
                if not chunk:
                    break
                buffer += chunk
                if b"\n" not in buffer:
                    continue
                line, _, _ = buffer.partition(b"\n")
                try:
                    request = json.loads(line or b"{}")
                except json.JSONDecodeError:
                    response = error_payload("bad_json", "request is not JSON")
                else:
                    response = self.handle(request)
                try:
                    connection.sendall(json.dumps(response, ensure_ascii=False).encode() + b"\n")
                except OSError:
                    break
                return


def error_payload(code: str, message: str) -> dict[str, Any]:
    return {"ok": False, "error": {"code": code, "message": message}}


def main() -> int:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    AUDIO_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    backend = Backend()

    def shutdown(signum: int, _frame: Any) -> None:
        log(f"signal {signum}: stopping")
        backend.player.stop()
        raise SystemExit(0)

    for signal_name in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signal_name, shutdown)

    try:
        backend.start()
    except KeyboardInterrupt:
        pass
    finally:
        backend.player.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
