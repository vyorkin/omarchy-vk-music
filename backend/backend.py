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
import requests
import signal
import socket
import subprocess
import sys
import threading
import time
import traceback
from dataclasses import asdict, replace
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))

from audio_cache import AudioCache, CacheError, cleanup_stray_temp
from vk_api import (
    WEB_APP_ID,
    WEB_USER_AGENT,
    Person,
    Playlist,
    Track,
    VkApiError,
    VkClient,
    VkHaltError,
    classify,
    safe_error_text,
)
from vk_auth import (
    VkAuthError,
    account_list,
    active_account_id,
    active_record,
    fetch_browser_cookies,
    needs_refresh,
    parse_cookies,
    refresh_web_record,
    remove_account as remove_stored_account,
    request_mobile_token,
    request_sms_code,
    save_account,
    save_mobile_token,
    save_web_token,
    request_web_token,
    set_active_account,
    summarize_record,
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
# Covers for desktop notifications: `notify-send` wants a file, not a URL.
COVER_DIR = CACHE_DIR / "covers"

MPV = "/usr/bin/mpv"
NOTIFY_SEND = "/usr/bin/notify-send"
MPV_PID_FILE = RUNTIME_DIR / "omarchy-vk-music-mpv.pid"
IPC_MAX_BYTES = 8 * 1024 * 1024
DEFAULT_PREFERENCES: dict[str, Any] = {
    "cacheEnabled": True,
    "cacheLimitMb": 256,
    "defaultSource": "section:all",
    # Downloading the next queue track while the current one plays: the same
    # file would be fetched when its turn comes, so it costs no extra traffic,
    # only a track of lead time.
    "prefetchEnabled": True,
    # What comes back after a restart, one piece at a time: the queue, where it
    # was, and how loud. Playback itself never resumes on its own.
    "restoreQueue": True,
    "restorePosition": True,
    "restoreVolume": True,
    # The bar row. These live here rather than in shell.json so the popup can
    # change them; a shell.json entry still wins when present.
    "showArtwork": True,
    "showTitle": True,
    "showArtist": True,
    "showControls": True,
    "showProgress": True,
    "showTime": False,
    "showLike": False,
    "coverShape": "rounded",
    "labelWidth": 180,
    "longTitleMode": "scroll",
    # The scrolling label: how long each end rests before the text moves, and how
    # fast it moves (pixels a second). Both are the user's taste, not ours.
    "marqueePauseMs": 1600,
    "marqueeSpeed": 70,
    # How playlists are drawn: as a gallery of covers or as rows. One setting for
    # every list of playlists, since they are the same thing in different places.
    "playlistView": "list",
    # "off" or "all": a desktop notification when the track changes on its own.
    "notifications": "off",
    # Which popup to open: "compact" (the small one) or "extended".
    "popupView": "compact",
    # The interface language. English is the default; the widget translates its own
    # strings and leaves the rest of the daemon's messages to the fallback.
    "language": "en",
}

# Values a preference may take, for the ones that are not simple booleans. A
# wrong value from the CLI would otherwise sit in the settings forever.
PREFERENCE_ENUMS: dict[str, tuple[str, ...]] = {
    "coverShape": ("square", "rounded", "circle"),
    "longTitleMode": ("truncate", "scroll"),
    "notifications": ("off", "all"),
    "popupView": ("compact", "extended"),
    "language": ("en", "de", "es", "fr", "ja", "zh", "uk", "ru"),
    "playlistView": ("list", "grid"),
}

# Preferences that existed before and what they mean now.
LEGACY_PREFERENCES = {
    "showText": ("showTitle", "showArtist"),
    "restoreOnStart": ("restoreQueue", "restorePosition", "restoreVolume"),
}

# How long a track must be playing before its successor is fetched. Short
# enough to be ready, long enough that flipping through tracks fetches nothing.
PREFETCH_DELAY_S = 4.0

# How many committed searches the popup offers back. Kept small: this is a
# convenience, not a log.
SEARCH_HISTORY_LIMIT = 8

# How many people the popup remembers, and how long a friend list is trusted.
# Both keep the plugin from asking VK the same question twice.
PEOPLE_HISTORY_LIMIT = 8
FRIENDS_TTL = 600.0

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


# Sliders send whatever the hand did; these keep the value inside the range the
# UI draws, so a stored preference is always something the panel can show.
PREFERENCE_RANGES: dict[str, tuple[int, int]] = {
    "cacheLimitMb": (64, 1024),
    "labelWidth": (80, 400),
    "marqueePauseMs": (0, 6000),
    "marqueeSpeed": (10, 300),
}


def coerce_preference(key: str, value: Any) -> Any:
    """Keep a preference the type it is supposed to be.

    The CLI sends strings for everything, and a value the UI does not expect
    (a string where a boolean belongs, a word that is not in the list) would sit
    in the settings and quietly break whatever reads it.
    """
    default = DEFAULT_PREFERENCES[key]
    allowed = PREFERENCE_ENUMS.get(key)
    if isinstance(default, bool):
        if isinstance(value, str):
            return value.strip().lower() in ("1", "true", "yes", "on")
        return bool(value)
    if isinstance(default, int):
        try:
            number = int(value)
        except (TypeError, ValueError):
            return default
        low, high = PREFERENCE_RANGES.get(key, (None, None))
        if low is not None:
            number = max(low, min(high, number))
        return number
    if allowed is not None:
        text = str(value)
        return text if text in allowed else default
    return str(value)


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

    # Fields that belong to one VK account rather than to the installation: the
    # queue somebody built, what they liked, what they searched, who they opened
    # and where they were in it. Preferences and volume stay global, because
    # they are about the panel and the speakers, not about the account.
    ACCOUNT_STATE_KEYS = (
        "source",
        "queue",
        "likedCopies",
        "searchHistory",
        "recentPeople",
        "index",
        "position",
        "trackKey",
    )

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
        # Set while a live station plays: a name, a logo and a stream URL, with
        # no queue behind it, no duration and nothing to seek in.
        self.radio: dict[str, Any] | None = None
        # The last track a notification was sent for, so a reload or a seek does
        # not repeat it.
        self._notified_key = ""
        # Where the time went for the track being started: filled as the start
        # proceeds and printed once per start. A "playback takes a few seconds"
        # report cannot otherwise be told apart from a slow download.
        self._trace: dict[str, float] = {}
        self._download_cancel = threading.Event()
        self._prefetch_thread: threading.Thread | None = None
        self._prefetch_key = ""
        self._prefetch_cancel = threading.Event()
        self._prefetch_timer: threading.Timer | None = None
        # One lock for the API: the prefetch thread resolves the next track's URL
        # while the command thread may be doing anything else with the client.
        self._api_lock = threading.Lock()
        self._ignore_events_until = 0.0
        self._ignore_pause_until = 0.0
        self.playing_from_cache = False
        self.liked_copies: dict[str, str] = {}
        # Recent queries, most recent first. It lives here because the state file
        # is here; the widget only reads it out of `status`.
        self.search_history: list[str] = []
        # People whose playlists were opened, most recent first: VK's own
        # bookmarks API is gone, so this is what stands in for «закладки».
        self.recent_people: list[dict[str, Any]] = []
        self._friends_cache: tuple[float, list[Person]] | None = None
        # Buffering progress, as the interface needs it: `percent` is None while
        # the length is unknown (a stream that is not being cached), which is what
        # tells the widget to draw an indeterminate indicator instead of a bar.
        self.buffering = False
        self.buffer_seconds = 0.0
        self.buffer_total = 0
        self.buffer_percent: int | None = None
        self._mpris: MprisBridge | None = None
        self._load_state()

    # -- persistence -------------------------------------------------------

    def _load_state(self) -> None:
        try:
            stored = json.loads(STATE_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            stored = {}
        self._state_doc = stored if isinstance(stored, Mapping) else {}
        stored_preferences = dict(self._state_doc.get("preferences") or {})
        for old, replacements in LEGACY_PREFERENCES.items():
            if old in stored_preferences:
                value = bool(stored_preferences.pop(old))
                for replacement in replacements:
                    stored_preferences.setdefault(replacement, value)
        for key, value in stored_preferences.items():
            if key in DEFAULT_PREFERENCES:
                self.preferences[key] = coerce_preference(key, value)
        self.cache.limit_bytes = max(
            0, int(self.preferences.get("cacheLimitMb", 256)) * 1024 * 1024
        )
        if self.preferences.get("restoreVolume", True):
            self.volume = int(self._state_doc.get("volume", self.volume) or self.volume)
        self.shuffle = bool(self._state_doc.get("shuffle", False))
        self.repeat = str(self._state_doc.get("repeat", "off"))
        self._apply_account_state(active_account_id(), legacy=self._state_doc)

    def _apply_account_state(
        self, account_id: Any, legacy: Mapping[str, Any] | None = None
    ) -> None:
        """Reset everything one account owns, then restore that account's slice."""
        document = legacy if legacy is not None else (self._state_doc or {})
        bucket: Mapping[str, Any] = {}
        accounts = document.get("accounts")
        if isinstance(accounts, Mapping):
            found = accounts.get(str(account_id)) if account_id is not None else None
            bucket = found if isinstance(found, Mapping) else {}
        else:
            # A state file from before accounts existed: everything at the top
            # belongs to the one account that was signed in then.
            if account_id is not None:
                bucket = document
        self.source = {"kind": "", "id": "", "title": ""}
        self.queue = []
        self.index = -1
        self.position = 0
        self.duration = 0
        self.liked_copies = {}
        self.search_history = []
        self.recent_people = []
        self.source = dict(bucket.get("source") or self.source)
        restored = (
            [track_from_state(item) for item in bucket.get("queue") or []]
            if self.preferences.get("restoreQueue", True)
            else []
        )
        self.queue = restored
        self.liked_copies = {
            str(key): str(value)
            for key, value in (bucket.get("likedCopies") or {}).items()
        }
        self.search_history = [
            str(item) for item in (bucket.get("searchHistory") or []) if str(item).strip()
        ][:SEARCH_HISTORY_LIMIT]
        self.recent_people = [
            dict(item)
            for item in (bucket.get("recentPeople") or [])
            if isinstance(item, Mapping) and item.get("id")
        ][:PEOPLE_HISTORY_LIMIT]
        self.index = int(bucket.get("index", -1)) if restored else -1
        self.position = int(bucket.get("position", 0) or 0) if self.preferences.get(
            "restorePosition", True
        ) else 0
        # The queue and the position are restored so the bar shows what was
        # playing, but playback does not resume on its own: music starting by
        # itself at login is not something a user asked for.
        restored_track = self.current_track()
        if restored_track:
            self.duration = restored_track.duration
        self.position = min(self.position, self.duration) if self.duration else self.position

    def _account_bucket(self) -> dict[str, Any]:
        bucket: dict[str, Any] = {
            "source": self.source,
            "queue": [track_to_state(track) for track in self.queue],
            "likedCopies": self.liked_copies,
            "searchHistory": self.search_history,
            "recentPeople": self.recent_people,
            "index": self.index,
            "position": self.position,
        }
        track = self.current_track()
        if track:
            bucket["trackKey"] = track.key
        return bucket

    def save_state(self) -> None:
        with self.lock:
            document = dict(self._state_doc or {})
            document["preferences"] = self.preferences
            document["volume"] = self.volume
            document["shuffle"] = self.shuffle
            document["repeat"] = self.repeat
            account_id = self.account_id()
            if account_id is not None:
                accounts = dict(document.get("accounts") or {})
                accounts[str(account_id)] = self._account_bucket()
                document["accounts"] = accounts
            # The flat fields belonged to the one account that existed before
            # accounts did; the store is the account slice now.
            for key in self.ACCOUNT_STATE_KEYS:
                document.pop(key, None)
            self._state_doc = document
        try:
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            os.chmod(CONFIG_DIR, 0o700)
            tmp = STATE_FILE.with_suffix(".tmp")
            tmp.write_text(json.dumps(document, ensure_ascii=False), encoding="utf-8")
            os.chmod(tmp, 0o600)
            os.replace(tmp, STATE_FILE)
        except OSError as exc:
            log(f"cannot save state: {exc}")

    def account_id(self) -> Any:
        if not self.record:
            return None
        return self.record.get("user_id")

    # -- session -----------------------------------------------------------

    def authenticate(self, record: Mapping[str, Any]) -> None:
        self.record = dict(record)
        self.client = VkClient(
            self.record["access_token"],
            user_agent=str(self.record.get("user_agent") or WEB_USER_AGENT),
            client_id=str(self.record.get("client_id") or WEB_APP_ID),
            device_id=self.record.get("device_id"),
        )

    def describe_account(self, record: Mapping[str, Any]) -> dict[str, Any]:
        """Ask VK who a token belongs to, for the account list.

        The web token endpoint usually names the user; a mobile token does not
        always. The name and the portrait are what make a list of accounts
        readable, so they are fetched once, right after signing in, and stored
        beside the token. A failure here must not fail the sign-in.
        """
        try:
            client = VkClient(
                str(record.get("access_token") or ""),
                user_agent=str(record.get("user_agent") or WEB_USER_AGENT),
                client_id=str(record.get("client_id") or WEB_APP_ID),
                device_id=record.get("device_id"),
            )
            items = client.call("users.get", fields="photo_200")
        except Exception as exc:  # noqa: BLE001 - a missing name is not a failed sign-in
            log(f"could not read the account profile: {safe_error_text(exc)}")
            return {}
        if not isinstance(items, list) or not items or not isinstance(items[0], Mapping):
            return {}
        item = items[0]
        name = " ".join(
            part
            for part in (item.get("first_name"), item.get("last_name"))
            if isinstance(part, str) and part
        )
        return {
            "user_id": item.get("id", record.get("user_id")),
            "name": name,
            "photo": str(item.get("photo_200") or item.get("photo_100") or ""),
        }

    def ensure_profile(self) -> None:
        """Fill in a name and a portrait for an account stored without them.

        A migrated single-account store has no profile: it was written before
        the account list existed, and the token file is gone. One call fills it
        in, and the account row stops saying «Аккаунт 12345».
        """
        with self.lock:
            record = self.record
            if not record or record.get("name"):
                return
            profile = self.describe_account(record)
            if not profile.get("name"):
                return
            merged = dict(record)
            merged.update(profile)
            save_account(merged, make_active=False)
            self.record = merged

    def load_session(self) -> bool:
        """Load the stored token, refreshing a web token that is near expiry."""
        record = self.record or active_record()
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

    def sign_in(self) -> None:
        """Adopt a fresh token, forgetting what the old session said.

        A halt writes its reason into both `error` and `notice`, and `notice` is
        the popup header's third line: without this, a successful sign-in leaves
        «Сессия VK отклонена» on screen until the next track start replaces it.

        A sign-in is also the moment an account becomes active, so the queue and
        the likes of that account are loaded here: leaving the previous account's
        queue on screen would name tracks this session cannot play.
        """
        with self.lock:
            # Adding an account is also switching to it: the old stream URL and
            # the old queue belong to a session that is no longer used.
            self._halt_playback(keep_position=True)
            self.save_state()
            self.record = None
            self.client = None
            self.load_session()
            self._apply_account_state(self.account_id())
            self.unplayable.clear()
            self._friends_cache = None
            self.error = ""
            self.notice = ""
            self.save_state()
            self._publish_mpris()

    def _reset_session(self) -> None:
        """Forget live session state without touching the stored history."""
        self.record = None
        self.client = None
        self.radio = None
        self.unplayable.clear()
        self._friends_cache = None
        self.error = ""
        self.notice = ""
        self._notified_key = ""

    def switch_account(self, user_id: Any) -> dict[str, Any]:
        """Make another stored account active, keeping both queues on disk.

        Playback stops: the resolved stream URL belongs to the old session and a
        queue of somebody else's tracks is not this account's queue. The new
        account's own queue comes back where it was, paused.
        """
        with self.lock:
            target = set_active_account(user_id)
            # Save the outgoing account under its own id before the record changes.
            self._halt_playback(keep_position=True)
            self.save_state()
            self._reset_session()
            self.authenticate(target)
            self._apply_account_state(target.get("user_id"))
            self.save_state()
            self._publish_mpris()
            return dict(target)

    def remove_account(self, user_id: Any) -> dict[str, Any] | None:
        """Forget an account, its queue and its likes.

        Removing the active account stops playback and hands the session to the
        next stored account, if there is one; otherwise the panel goes back to
        the sign-in screen.
        """
        with self.lock:
            active = self.account_id()
            is_active = active is not None and str(active) == str(user_id)
            if is_active:
                self._halt_playback(keep_position=True)
                self.save_state()
            remaining = remove_stored_account(user_id)
            document = self._state_doc or {}
            accounts = dict(document.get("accounts") or {})
            accounts.pop(str(user_id), None)
            document["accounts"] = accounts
            self._state_doc = document
            if is_active:
                self._reset_session()
                if remaining:
                    self.authenticate(remaining)
                    self._apply_account_state(remaining.get("user_id"))
                else:
                    self._apply_account_state(None)
                self.save_state()
                self._publish_mpris()
            return remaining

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
            with self._api_lock:
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

    def playlist_search(self, query: str, offset: int | None = None) -> dict[str, Any]:
        """Search other people's playlists by name."""
        if not str(query).strip():
            return {"query": "", "playlists": [], "total": 0}
        playlists, total = self.api(
            lambda: self.client.search_playlists(str(query), offset=offset or 0)
        )
        return {
            "query": query,
            "playlists": [playlist.to_dict() for playlist in playlists],
            "total": total,
        }

    def friends_list(self) -> list[Person]:
        """The friend list, trusted for ten minutes: it changes slowly."""
        now = time.monotonic()
        if self._friends_cache and now - self._friends_cache[0] < FRIENDS_TTL:
            return self._friends_cache[1]
        people = self.api(lambda: self.client.friends())
        self._friends_cache = (now, list(people))
        return list(people)

    def person(self, query: str) -> dict[str, Any]:
        """Open somebody's playlists: a friend, a stranger, a link, an id.

        The friend list already knows its own people, so a name that matches one is
        answered from there; everything else goes to `users.get`, which resolves
        screen names as happily as it does ids.
        """
        reference = parse_person_reference(query)
        if not reference:
            raise VkApiError(0, "пустая ссылка", method="person")
        person: Person | None = None
        for candidate in self.friends_list():
            if reference.casefold() in {candidate.screen_name.casefold(), str(candidate.id)}:
                person = candidate
                break
        if person is None:
            found = self.api(lambda: self.client.users(reference))
            if not found:
                raise VkApiError(0, f"человек не найден: {query}", method="person")
            person = found[0]
        playlists = self.api(lambda: self.client.audio_playlists(person.id, count=100))
        self.remember_person(person)
        return {
            "person": person.to_dict(),
            "playlists": [playlist.to_dict() for playlist in playlists],
        }

    def remember_person(self, person: Person) -> None:
        """Keep the last few people whose playlists were opened."""
        with self.lock:
            entry = person.to_dict()
            self.recent_people = [
                item for item in self.recent_people if int(item.get("id", 0)) != person.id
            ]
            self.recent_people.insert(0, entry)
            del self.recent_people[PEOPLE_HISTORY_LIMIT:]
            self.save_state()

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
            self._cancel_prefetch()
            self.radio = None
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
        self.position = 0.0
        self.playing = False
        self.paused = False
        # The previous file keeps sounding until the new one is loaded, which is a whole
        # download away. Pause it now, and reset the position so the bar's slider starts
        # from the beginning instead of showing the old track's progress.
        try:
            # No `alive()` check: the command itself raises when mpv is not up yet, and
            # that is the only failure worth ignoring here.
            self.mpv.command("set_property", "pause", True)
        except Exception:
            pass
        self._cancel_prefetch()
        self.radio = None
        self._trace = {"start": time.monotonic()}
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
        self._trace["resolved"] = time.monotonic()
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

    def play_radio(self, station: Mapping[str, Any]) -> None:
        """Play a live station: a stream URL, a name and a logo, nothing else.

        The stream is endless and not ours, so it is never cached, never queued
        and never seeked: the player plays the URL as it comes and the station
        stands in for the track in the bar and over MPRIS.
        """
        with self.lock:
            self._cancel_prefetch()
            self._download_cancel.set()
            url = str(station.get("stream_url", ""))
            if not url:
                self.error = "у станции нет ссылки на поток"
                return
            self.radio = {
                "id": int(station.get("id", 0) or 0),
                "name": str(station.get("name", "")),
                "logo": str(station.get("logo_url", "")),
            }
            self.position = 0
            self.duration = 0
            self.buffer_total = 0
            self.error = ""
            self.notice = ""
            self.loading = True
            self.playing = False
            self.paused = False
            self._publish_mpris()
            self._play_url(url)

    def _schedule_prefetch(self) -> None:
        """Fetch the next track once the current one has been playing a while.

        The delay matters: skipping through a playlist should not download a
        file per skipped track.
        """
        self._cancel_prefetch()
        if not self.preferences.get("prefetchEnabled", True):
            return
        timer = threading.Timer(PREFETCH_DELAY_S, self._maybe_prefetch)
        timer.daemon = True
        self._prefetch_timer = timer
        timer.start()

    def _cancel_prefetch(self) -> None:
        """Drop a pending or running prefetch; the queue moved elsewhere."""
        if self._prefetch_timer is not None:
            self._prefetch_timer.cancel()
            self._prefetch_timer = None
        self._prefetch_cancel.set()
        self._prefetch_cancel = threading.Event()

    def _maybe_prefetch(self) -> None:
        if not self.preferences.get("prefetchEnabled", True):
            return
        if not self.preferences.get("cacheEnabled", True) or self.cache.limit_bytes <= 0:
            return
        track = self._next_playable()
        if track is None or self.cache.get(track.key):
            return
        if self._prefetch_thread and self._prefetch_thread.is_alive():
            return
        cancel = self._prefetch_cancel
        self._prefetch_key = track.key
        self._prefetch_thread = threading.Thread(
            target=self._prefetch_worker, args=(track, cancel), daemon=True,
            name="vk-music-prefetch",
        )
        self._prefetch_thread.start()

    def _next_playable(self) -> Track | None:
        with self.lock:
            for index in range(self.index + 1, len(self.queue)):
                candidate = self.queue[index]
                if candidate.key not in self.unplayable:
                    return candidate
        return None

    def _prefetch_worker(self, track: Track, cancel: threading.Event) -> None:
        try:
            url = self.resolve_url(track)
        except (VkApiError, VkHaltError) as exc:
            log(f"prefetch skipped for {track.key}: {classify(exc)}")
            return
        if cancel.is_set() or not url:
            return
        try:
            path = self.cache.download(url, track.key)
        except CacheError as exc:
            log(f"prefetch failed for {track.key}: {exc}")
            return
        if not cancel.is_set():
            log(f"prefetched {track.label} ({path.stat().st_size // 1024} KiB)")

    def _start_download(self, track: Track, url: str) -> None:
        # The previous download has to be told to stand down, not just replaced:
        # the worker checks its own event when the file is ready, and an orphaned
        # event never fires, so a slow download used to finish and play itself
        # over the track the user had chosen in the meantime.
        cancel = threading.Event()
        self._download_cancel.set()
        self._download_cancel = cancel
        with self.lock:
            self.buffering = True
            self.buffer_seconds = 0.0
            self.buffer_total = track.duration
            self.buffer_percent = 0

        def report(seconds: float) -> None:
            if cancel.is_set():
                return
            percent = int(100 * seconds / track.duration) if track.duration > 0 else 0
            # ffmpeg reaches the end of the audio well before it finishes writing
            # the file, so a running download never reports 100: otherwise the
            # frame sits visibly full for the last stretch of every track.
            percent = max(0, min(99, percent))
            if percent >= (self.buffer_percent or 0):
                self.buffer_seconds = seconds
                self.buffer_percent = percent

        def worker() -> None:
            try:
                path = self.cache.download(url, track.key, on_progress=report)
                self._trace["downloaded"] = time.monotonic()
            except CacheError as exc:
                log(f"cache failed for {track.key}: {exc}")
                with self.lock:
                    if not cancel.is_set():
                        self.loading = False
                        self.buffering = False
                        self._mark_unplayable(track, str(exc))
                return
            with self.lock:
                if cancel.is_set():
                    return
                self.loading = False
                self.buffering = False
                self._play_file(path)

        self._download_thread = threading.Thread(target=worker, daemon=True)
        self._download_thread.start()

    def _play_file(self, path: Path) -> None:
        self._begin_load()
        self.buffering = False
        self.buffer_percent = 100
        try:
            self.mpv.ensure()
            self.mpv.command("loadfile", str(path), "replace")
            self.mpv.command("set_property", "volume", self.volume)
            # mpv keeps its `pause` property across `loadfile`, so a track started
            # while the player was paused loaded paused and stayed silent, while
            # this side believed it was playing and only the second press of play
            # made a sound. Starting a track means playing it.
            self.mpv.command("set_property", "pause", False)
        except (MpvError, OSError) as exc:
            self.error = f"mpv: {safe_error_text(exc)}"
            self.loading = False
            self.playing = False
        self.playing_from_cache = True
        self._publish_mpris()

    def _play_url(self, url: str) -> None:
        self._begin_load()
        # No cache means no length to compare against: the indicator stays
        # indeterminate until mpv says the file is loaded.
        self.buffering = True
        self.buffer_percent = None
        try:
            self.mpv.ensure()
            self.mpv.command("loadfile", url, "replace")
            self.mpv.command("set_property", "volume", self.volume)
            self.mpv.command("set_property", "pause", False)
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
        self.buffer_seconds = 0.0
        self._ignore_events_until = time.monotonic() + 1.0

    def _mark_unplayable(self, track: Track, reason: str) -> None:
        self.unplayable.add(track.key)
        # The reason is ffmpeg's own text, newlines and all, and the notice is a
        # single line in the panel's header: one line here keeps it from
        # stretching that row.
        self.notice = f"Пропущен трек «{track.label}»: {' '.join(str(reason).split())}"
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

    def remove_from_queue(self, index: int) -> None:
        """Drop one entry from the queue.

        Removing the track that is playing stops playback and leaves the index on
        the entry that took its place: playing on while the list says otherwise
        would make every later action act on the wrong track.
        """
        with self.lock:
            if not (0 <= index < len(self.queue)):
                return
            if index == self.index:
                del self.queue[index]
                self.stop()
                self.index = min(self.index, len(self.queue) - 1)
            else:
                del self.queue[index]
                if index < self.index:
                    self.index -= 1
            self.save_state()

    def enqueue(self, tracks: Sequence[Track]) -> None:
        """Put tracks at the end of the queue, leaving what plays alone.

        Until now the queue was whatever the last command made it, so looking
        something up cost you the list you were listening to.
        """
        with self.lock:
            if not tracks:
                return
            self.queue.extend(tracks)
            self.save_state()

    def insert_next(self, tracks: Sequence[Track]) -> None:
        """Put tracks right after the current one: the next «next» plays them."""
        with self.lock:
            if not tracks:
                return
            if self.index < 0 or not self.queue:
                # Nothing is playing yet, so the tracks simply become the queue.
                self.queue = list(tracks)
                self.index = -1
            else:
                self.queue[self.index + 1:self.index + 1] = list(tracks)
            self.save_state()

    def remember_search(self, query: str) -> None:
        """Keep the last few committed searches, most recent first."""
        text = " ".join(str(query).split())
        if len(text) < 2:
            return
        with self.lock:
            lowered = text.casefold()
            self.search_history = [
                item for item in self.search_history if item.casefold() != lowered
            ]
            self.search_history.insert(0, text)
            del self.search_history[SEARCH_HISTORY_LIMIT:]
            self.save_state()

    def clear_queue(self) -> None:
        """Empty the queue and stop: the popup's "clear" action."""
        with self.lock:
            self.stop()
            self.queue = []
            self.index = -1
            self.position = 0
            self.duration = 0
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
            # A press of any transport control means the skipped-track notice has
            # been read: it describes one moment in the past, and keeping it in
            # the header forever makes the panel look broken after everything
            # started working again.
            self.notice = ""
            if self.loading:
                # Nothing is playing yet, and starting the track again here would
                # throw away the download in progress: a press of play during the
                # wait is not an instruction to fetch the file a second time.
                return
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

    def _halt_playback(self, *, keep_position: bool) -> None:
        """Stop mpv and the state around it, without deciding about the queue.

        `keep_position` is for an account switch: the outgoing account's place
        in its queue is worth keeping in its own slice of the state file, while
        a plain «stop» means the bar should show the track from zero.
        """
        self._cancel_prefetch()
        self.radio = None
        self._download_cancel.set()
        try:
            self.mpv.command("stop")
        except (MpvError, OSError):
            pass
        self.playing = False
        self.paused = False
        self.loading = False
        self.buffering = False
        self.buffer_percent = None
        if not keep_position:
            self.position = 0
        self.notice = ""
        self._publish_mpris()

    def stop(self) -> None:
        with self.lock:
            self._halt_playback(keep_position=False)
            self.save_state()

    def seek(self, position: int) -> None:
        with self.lock:
            if self.radio:
                # A live stream has no timeline to move along.
                return
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

    def set_liked(self, key: str, liked: bool) -> None:
        """Reflect a like in the queue, so the widget needs no second request."""
        with self.lock:
            self.queue = [
                replace(track, is_liked=liked) if track.key == key else track
                for track in self.queue
            ]

    def remember_like_copy(self, key: str, copy_key: str) -> None:
        """Remember which ids VK gave the track in the user's own list.

        Liking a track from someone else's playlist creates a copy with new ids,
        and removing it later needs those ids, not the original ones.
        """
        with self.lock:
            if copy_key:
                self.liked_copies[key] = copy_key
            else:
                self.liked_copies.pop(key, None)
            self.save_state()

    def derive_like_target(self, key: str) -> str:
        with self.lock:
            return self.liked_copies.get(key, key)

    def set_preferences(self, values: Mapping[str, Any]) -> None:
        with self.lock:
            for key, value in values.items():
                if key not in DEFAULT_PREFERENCES:
                    continue
                self.preferences[key] = coerce_preference(key, value)
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
                self._trace["loaded"] = time.monotonic()
                self._log_start_trace()
                self._notify_track()
                self.loading = False
                self.buffering = False
                self.playing = True
                self.paused = False
                self.position = 0
                # The track that was skipped is behind us and something is
                # sounding: the notice that reported the skip is spent.
                self.notice = ""
                self._publish_mpris()
                self._schedule_prefetch()
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

    def _notify_track(self) -> None:
        """One notification per track, when the user asked for them.

        Sent from here rather than from the widget: the track changes on its own
        as often as it is changed, and the popup is usually closed when that
        happens.
        """
        if self.preferences.get("notifications") != "all":
            return
        radio = self.radio
        track = self.current_track()
        if radio:
            key = f"radio{radio.get('id', 0)}"
            title = str(radio.get("name", ""))
            body = "Радио · в эфире"
            cover = str(radio.get("logo", ""))
        elif track:
            key = track.key
            title = track.title
            body = track.artist
            cover = track.thumb
        else:
            return
        if key == self._notified_key:
            return
        self._notified_key = key
        command = [NOTIFY_SEND, "--app-name=vk music"]
        icon = self._cover_file(key, cover)
        if icon:
            command.append(f"--icon={icon}")
        command += [title, body]
        try:
            subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as exc:
            log(f"notification failed: {exc}")

    def _cover_file(self, key: str, url: str) -> str:
        """The cover as a local file for `notify-send`, downloaded once.

        A notification wants a file, and VK hands out a URL. The image is fetched
        from the same CDN the widget already loads it from, and cached by track.
        """
        if not url:
            return ""
        directory = COVER_DIR
        path = directory / f"{key}.jpg"
        try:
            if path.is_file() and path.stat().st_size > 0:
                return str(path)
            directory.mkdir(parents=True, exist_ok=True)
            response = requests.get(url, timeout=10)
            if response.status_code != 200 or not response.content:
                return ""
            temp = path.with_suffix(".part")
            temp.write_bytes(response.content)
            # VK hands out 1200x1200 covers: half a megabyte for a notification
            # thumbnail, and one file per track that is ever played. A notification
            # draws it at a hundred pixels, so it is scaled down once, here.
            if len(response.content) > 150 * 1024 and not self._shrink_cover(temp, path):
                os.replace(temp, path)
            else:
                temp.unlink(missing_ok=True)
        except (OSError, requests.RequestException) as exc:
            log(f"cover for notification failed: {safe_error_text(exc)}")
            return ""
        return str(path)

    def _shrink_cover(self, source: Path, target: Path) -> bool:
        """Scale a cover down with ffmpeg, the same tool the cache already uses."""
        # The format is named explicitly: ffmpeg picks it from the extension, and
        # a cached cover has no meaningful one of its own.
        command = [
            "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(source), "-vf", "scale=192:-1",
            "-frames:v", "1", "-f", "image2", "-c:v", "mjpeg", "-q:v", "4",
            str(target),
        ]
        try:
            completed = subprocess.run(command, capture_output=True, timeout=20)
        except (OSError, subprocess.TimeoutExpired) as exc:
            log(f"cover scale failed: {exc}")
            return False
        return completed.returncode == 0 and target.is_file() and target.stat().st_size > 0

    def _log_start_trace(self) -> None:
        """Print where the time of one track start went, in one line."""
        trace = self._trace
        self._trace = {}
        start = trace.get("start")
        if start is None:
            return
        parts = []
        for name, label in (("resolved", "resolve"), ("downloaded", "download")):
            at = trace.get(name)
            if at is not None:
                parts.append(f"{label} {at - start:.2f} s")
        loaded = trace.get("loaded")
        if loaded is not None:
            parts.append(f"total {loaded - start:.2f} s")
        if parts:
            log("track start: " + ", ".join(parts))

    def _publish_mpris(self, seeked: bool = False) -> None:
        if self._mpris:
            self._mpris.publish(seeked)

    def mpris_state(self) -> dict[str, Any]:
        track = self.current_track()
        with self.lock:
            radio = self.radio
            if radio:
                return {
                    "playing": self.playing and not self.paused,
                    "paused": self.paused,
                    "position": 0,
                    "duration": 0,
                    "volume": self.volume,
                    "title": radio.get("name", ""),
                    "artist": "Радио",
                    "artists": [{"name": "Радио"}],
                    "artUrl": radio.get("logo", ""),
                    "trackId": f"radio{radio.get('id', 0)}",
                    # Nothing to move through or along: the stream decides.
                    "hasQueue": False,
                    "shuffle": self.shuffle,
                    "repeat": self.repeat,
                }
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
                "buffer": {
                    "active": self.buffering,
                    "percent": self.buffer_percent,
                    "seconds": round(self.buffer_seconds, 1),
                    "total": self.buffer_total,
                },
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
                "radio": dict(self.radio) if self.radio else {},
                # A station stands in for the track: while it plays there is no
                # current track to report, only the station and its stream.
                "track": None if self.radio else (track_to_state(track) if track else None),
                "next": track_to_state(self.queue[self.index + 1])
                if 0 <= self.index + 1 < len(self.queue)
                else None,
                "preferences": self.preferences,
                "history": list(self.search_history),
                "people": list(self.recent_people),
                "cache": self.cache.stats(),
                "session": session_summary(self.record),
            }


def parse_person_reference(text: str) -> str:
    """What to hand to `users.get` for a pasted link, screen name or id.

    Accepts what a person actually copies out of a browser: a profile link
    (`https://vk.com/id213706100`, `vk.com/durov`), an `@name`, a bare screen name
    or a number, and a playlist link — for which the owner id is what matters,
    since the playlist itself is opened from the person's list.
    """
    value = str(text or "").strip()
    if not value:
        return ""
    value = value.split("?")[0].split("#")[0].rstrip("/")
    if "//" in value:
        value = value.split("//", 1)[1]
        value = value.split("/", 1)[1] if "/" in value else ""
    # A playlist link in either of the shapes VK hands out.
    for marker in ("music/playlist/", "audio_playlist"):
        if marker in value:
            tail = value.split(marker, 1)[1]
            owner = tail.replace("%2F", "_").replace("%2f", "_").split("_")[0]
            return owner.lstrip("-") or ""
    if "/" in value:
        value = value.rstrip("/").split("/")[-1]
    value = value.lstrip("@").strip()
    if value.startswith("id") and value[2:].isdigit():
        return value[2:]
    return value


def session_summary(record: Mapping[str, Any] | None) -> dict[str, Any]:
    if not record:
        return {
            "mode": "",
            "user_id": None,
            "name": "",
            "photo": "",
            "active": False,
            "has_cookies": False,
            "expires_in": 0,
        }
    summary = summarize_record(record, active=True)
    summary["user_id"] = summary.pop("id")
    return summary


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


def _mpris_segment(value: object) -> str:
    """A D-Bus object path segment holds letters, digits and underscores only.

    VK's track keys start with a minus sign for anything a community owns, and one minus
    was enough to make every publish raise SignatureBodyMismatchError — which killed the
    whole MPRIS interface and, with it, every client that asks a player to pause itself.
    """
    clean = "".join(ch if (ch.isalnum() or ch == "_") else "_" for ch in str(value or ""))
    return clean or "none"


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
            def Seeked(self, position: "x") -> "x":
                # dbus-next builds a signal's body from this return value, so a
                # bare `...` made every emit raise SignatureBodyMismatchError and
                # no consumer ever saw a Seeked.
                return position

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
                    "mpris:trackid": Variant("o", f"/org/mpris/MediaPlayer2/track/{_mpris_segment(state['trackId'])}"),
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
        # (stations, expires at) — the station list changes rarely.
        self._radio_cache: tuple[list[dict[str, Any]] | None, float] = (None, 0.0)
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
        # Who the token belongs to decides which account record is written, so
        # the profile is asked for before the save, not after it.
        profile = self.player.describe_account(
            {
                "access_token": token.access_token,
                "user_id": token.user_id,
                "user_agent": WEB_USER_AGENT,
                "client_id": WEB_APP_ID,
            }
        )
        record = save_web_token(token, parsed, profile=profile)
        log(f"signed in account {record.get('user_id')} with a web token")
        return self._account_signed_in()

    def _account_signed_in(self) -> dict[str, Any]:
        self._radio_cache = (None, 0.0)
        self.mobile_auth = {}
        self.player.sign_in()
        return {
            "done": True,
            "session": session_summary(self.player.record),
            "accounts": account_list(),
            "status": self.player.status(),
        }

    def cmd_auth_mobile_start(self, login: str = "", password: str = "", client: str = "vk-android") -> dict[str, Any]:
        """First step of the fallback path; the password never leaves memory."""
        if not login or not password:
            raise VkAuthError("login and password are required")
        # A fresh attempt replaces whatever was pending: an old login must not
        # be resumed with a code meant for the new one.
        self.mobile_auth = {}
        mobile = MOBILE_CLIENTS.get(client) or MOBILE_CLIENTS["vk-android"]
        payload = request_mobile_token(mobile, login, password)
        if payload.get("access_token"):
            profile = self.player.describe_account(
                {
                    "access_token": str(payload["access_token"]),
                    "user_id": payload.get("user_id"),
                    "user_agent": mobile.user_agent,
                    "client_id": mobile.client_id,
                }
            )
            save_mobile_token(mobile, payload, profile=profile)
            return self._account_signed_in()
        self.mobile_auth = {
            "login": login,
            "password": password,
            "client": client,
            # A pending password is forgotten after a quarter of an hour even
            # if the panel never comes back to finish the login.
            "at": time.time(),
        }
        return self._mobile_step_result(payload, mobile)

    def cmd_auth_mobile_step(self, code: str = "", successToken: str = "") -> dict[str, Any]:
        pending = self.mobile_auth
        if not pending:
            raise VkAuthError("no login in progress")
        if time.time() - float(pending.get("at", 0) or 0) > 900:
            self.mobile_auth = {}
            raise VkAuthError("the login timed out; start it again")
        mobile = MOBILE_CLIENTS.get(pending["client"]) or MOBILE_CLIENTS["vk-android"]
        payload = request_mobile_token(
            mobile,
            pending["login"],
            pending["password"],
            code=code or None,
            success_token=successToken or None,
        )
        if payload.get("access_token"):
            profile = self.player.describe_account(
                {
                    "access_token": str(payload["access_token"]),
                    "user_id": payload.get("user_id"),
                    "user_agent": mobile.user_agent,
                    "client_id": mobile.client_id,
                }
            )
            save_mobile_token(mobile, payload, profile=profile)
            return self._account_signed_in()
        return self._mobile_step_result(payload, mobile)

    def cmd_auth_mobile_cancel(self) -> dict[str, Any]:
        """Forget a pending login: the panel closed the form."""
        self.mobile_auth = {}
        return {"cancelled": True}

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
        """Sign out of the active account only; other accounts stay stored."""
        active = active_account_id()
        if active is not None:
            self.player.remove_account(active)
        else:
            self.player._reset_session()
        self._radio_cache = (None, 0.0)
        self.mobile_auth = {}
        log(f"signed out of account {active}")
        return {
            "signedOut": self.player.record is None,
            "accounts": account_list(),
            "status": self.player.status(),
        }

    # -- accounts ----------------------------------------------------------

    def cmd_accounts(self) -> dict[str, Any]:
        return {"active": self.player.account_id(), "accounts": account_list()}

    def cmd_account_switch(self, user_id: int | str = 0) -> dict[str, Any]:
        if user_id in (None, "", 0, "0"):
            raise VkAuthError("an account id is required")
        self.player.switch_account(user_id)
        self._radio_cache = (None, 0.0)
        self.mobile_auth = {}
        log(f"switched to account {user_id}")
        return {
            "active": self.player.account_id(),
            "accounts": account_list(),
            "session": session_summary(self.player.record),
            "status": self.player.status(),
        }

    def cmd_account_remove(self, user_id: int | str = 0) -> dict[str, Any]:
        if user_id in (None, "", 0, "0"):
            raise VkAuthError("an account id is required")
        self.player.remove_account(user_id)
        self._radio_cache = (None, 0.0)
        self.mobile_auth = {}
        log(f"removed account {user_id}")
        return {
            "active": self.player.account_id(),
            "accounts": account_list(),
            "signedOut": self.player.record is None,
            "status": self.player.status(),
        }

    # -- sources -----------------------------------------------------------

    def cmd_sections(self) -> list[dict[str, Any]]:
        return self.player.sections()

    def cmd_home(self) -> dict[str, Any]:
        return self.player.home()

    def cmd_section(self, id: str, startFrom: str | None = None) -> dict[str, Any]:
        return self.player.section_items(id, startFrom)

    def cmd_search(
        self, query: str = "", offset: int | None = None, remember: bool = False
    ) -> dict[str, Any]:
        if not query.strip():
            return {"query": "", "tracks": []}
        if remember:
            # Only a committed search is worth remembering. The search-as-you-type
            # path would otherwise keep every prefix of every word.
            self.player.remember_search(query)
        return self.player.search_items(query, offset)

    def cmd_playlist_search(self, query: str = "", offset: int | None = None) -> dict[str, Any]:
        return self.player.playlist_search(query, offset)

    def cmd_friends(self) -> list[dict[str, Any]]:
        """Everyone on the friend list, plus the people opened recently."""
        people = self.player.friends_list()
        return [person.to_dict() for person in people]

    def cmd_person(self, query: str = "") -> dict[str, Any]:
        """Somebody's playlists, by link, screen name, id or friend's name."""
        return self.player.person(query)

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

    RADIO_CACHE_SECONDS = 600

    def cmd_radio(self) -> list[dict[str, Any]]:
        """The live stations. Cached: the list barely changes and VK is asked
        for it only when a browse view is opened."""
        now = time.monotonic()
        cached, expires = self._radio_cache
        if cached is not None and now < expires:
            return cached
        client = self.player.client
        if client is None:
            raise VkApiError(0, "not signed in", method="radio")
        stations = self.player.api(lambda: client.radio_stations())
        payload = [asdict(station) for station in stations]
        self._radio_cache = (payload, now + self.RADIO_CACHE_SECONDS)
        return payload

    def cmd_play_radio(self, id: int = 0) -> dict[str, Any]:
        station = next(
            (item for item in self.cmd_radio() if int(item.get("id", 0)) == int(id)), None
        )
        if station is None:
            raise VkApiError(0, f"unknown radio station: {id}", method="play_radio")
        self.player.play_radio(station)
        return self.player.status()

    def cmd_play_keys(
        self, keys: Sequence[str], index: int = 0, title: str = ""
    ) -> dict[str, Any]:
        """Queue exactly the tracks whose keys are named.

        The widget shows search results and therefore already knows their keys,
        which makes a second search unnecessary: one `audio.getById` answers
        instead, and the queue is the list the user was looking at rather than
        whatever a repeated search happens to return. VK resolves the URLs at
        play time from these same keys, so storing them costs nothing.
        """
        tracks = self._tracks_by_keys(keys, "play_keys")
        self.player.play(
            list(tracks),
            index=index,
            source={"kind": "search", "id": "", "title": title or "Поиск"},
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

    def _tracks_by_keys(self, keys: Sequence[str], method: str) -> list[Track]:
        """Turn track keys into tracks: one `audio.getById` for the whole batch."""
        wanted = [str(key) for key in keys if str(key).strip()]
        if not wanted:
            raise VkApiError(0, "no track keys given", method=method)
        client = self.player.client
        if client is None:
            raise VkApiError(0, "not signed in", method=method)
        tracks = self.player.api(lambda: client.audio_get_by_keys(wanted[:100]))
        if not tracks:
            raise VkApiError(0, "VK returned nothing for those keys", method=method)
        return list(tracks)

    def cmd_playlist_tracks(
        self, ownerId: int, playlistId: int, accessKey: str = "", title: str = ""
    ) -> dict[str, Any]:
        """What a playlist holds, without starting it.

        A click on a playlist should open it rather than replace what is playing:
        the tracks are needed either way, so the popup asks for them and plays the
        one that is chosen instead.
        """
        tracks = self.player.api(  # type: ignore[union-attr]
            lambda: self.player.client.audio_playlist_tracks(
                int(ownerId), int(playlistId), access_key=str(accessKey)
            )
        )
        return {
            "title": title,
            "tracks": [track_to_state(track) for track in tracks],
        }

    def cmd_queue_add(self, keys: Sequence[str]) -> dict[str, Any]:
        """Append tracks to the queue; what is playing keeps playing."""
        self.player.enqueue(self._tracks_by_keys(keys, "queue_add"))
        return self.player.status()

    def cmd_queue_next(self, keys: Sequence[str]) -> dict[str, Any]:
        """Play these right after the current track."""
        self.player.insert_next(self._tracks_by_keys(keys, "queue_next"))
        return self.player.status()

    def cmd_queue_remove(self, index: int = 0) -> dict[str, Any]:
        self.player.remove_from_queue(int(index))
        return self.player.status()

    def cmd_queue_clear(self) -> dict[str, Any]:
        self.player.clear_queue()
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
            # Covers are cache too, just for notifications.
            for cover in sorted(COVER_DIR.glob("*.jpg")) if COVER_DIR.is_dir() else []:
                try:
                    cover.unlink()
                    removed += 1
                except OSError:
                    pass
            return {"removed": removed, **self.player.cache.stats()}
        if action == "cleanup":
            return {"removed": cleanup_stray_temp(AUDIO_CACHE_DIR), **self.player.cache.stats()}
        return self.player.cache.stats()

    def cmd_like(self, key: str = "", liked: bool = True) -> dict[str, Any]:
        """Like or unlike a track.

        In VK music "liked" and "in my music" are the same list: `audio.add`
        copies the track into the user's own audio and `audio.delete` removes it.
        A track taken from someone else's playlist gets new ids on the way in,
        and those are what a later removal needs.
        """
        if not key:
            raise VkApiError(0, "track key is required", method="like")
        if liked:
            owner_id, _, audio_id = key.partition("_")
            result = self.player.api(
                lambda: self.player.client.add(int(owner_id), int(audio_id))  # type: ignore[union-attr]
            )
            copy_key = ""
            for item in result:
                if not isinstance(item, Mapping):
                    continue
                new_owner = item.get("new_owner_id", item.get("owner_id"))
                new_audio = item.get("new_audio_id", item.get("id"))
                if new_owner is not None and new_audio is not None:
                    copy_key = f"{int(new_owner)}_{int(new_audio)}"
                    break
            self.player.remember_like_copy(key, copy_key if copy_key != key else "")
        else:
            target = self.player.derive_like_target(key)
            owner_id, _, audio_id = target.partition("_")
            self.player.api(
                lambda: self.player.client.delete(int(owner_id), int(audio_id))  # type: ignore[union-attr]
            )
            self.player.remember_like_copy(key, "")
        self.player.set_liked(key, liked)
        return {"liked": liked, "key": key, "status": self.player.status()}

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
        self.player.ensure_profile()
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
