"""Disk cache for finished tracks.

VK hands out stream URLs that are short-lived and bound to the requesting
address, and it serves most tracks as HLS with AES-128 segments. That makes
"play the URL and cache in the background" fragile: a long track can outlive
its URL. So a track is resolved once, downloaded whole, and played from disk.
Replays and seeks then cost nothing and never touch the network.

The cache is not an offline library: there is no promise that a track stays
available, and eviction is aggressive by design.

Layout:

    <root>/tracks/<owner>_<id>.<ext>   the finished file
    <root>/index.json                  size and last-use per file
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path

DEFAULT_LIMIT_BYTES = 256 * 1024 * 1024
DOWNLOAD_TIMEOUT = 300
# Written next to the finished file so a crash mid-download leaves no
# half-file that looks playable.
TMP_SUFFIX = ".part"


class CacheError(RuntimeError):
    """Downloading or storing a track failed."""


@dataclass(frozen=True)
class CacheEntry:
    key: str
    path: Path
    size: int
    used_at: float

    def to_dict(self) -> dict[str, object]:
        return {"key": self.key, "size": self.size, "used_at": int(self.used_at)}


class AudioCache:
    def __init__(self, root: Path, limit_bytes: int = DEFAULT_LIMIT_BYTES) -> None:
        self.root = Path(root)
        self.tracks_dir = self.root / "tracks"
        self.index_path = self.root / "index.json"
        self.limit_bytes = max(int(limit_bytes), 0)
        self._lock = threading.Lock()
        self._index: dict[str, dict[str, object]] = {}
        # Downloads in flight, by track key. Prefetching the next track and
        # starting it can overlap, and two ffmpeg runs for one file would fight
        # over the same target; the second caller waits for the first instead.
        self._inflight: dict[str, threading.Event] = {}
        self.tracks_dir.mkdir(parents=True, exist_ok=True)
        self._load_index()

    # -- lookups -----------------------------------------------------------

    def get(self, key: str) -> Path | None:
        """Return the cached file for a track, refreshing its last-use time."""
        with self._lock:
            record = self._index.get(key)
            if not record:
                return None
            path = self.tracks_dir / str(record.get("file", ""))
            if not path.is_file():
                self._index.pop(key, None)
                self._save_index()
                return None
            record["used_at"] = time.time()
            self._save_index()
            return path

    def contains(self, key: str) -> bool:
        return self.get(key) is not None

    def stats(self) -> dict[str, object]:
        with self._lock:
            return {
                "enabled": self.limit_bytes > 0,
                "limit_bytes": self.limit_bytes,
                "bytes": sum(int(r.get("size", 0)) for r in self._index.values()),
                "files": len(self._index),
            }

    # -- writing -----------------------------------------------------------

    def download(self, url: str, key: str) -> Path:
        """Fetch a whole track into the cache and return its path.

        Safe to call twice for the same track: the second caller waits for the
        download already running instead of starting its own.
        """
        if not url:
            raise CacheError("track has no stream url")
        if self.limit_bytes <= 0:
            raise CacheError("cache is disabled")

        cached = self.get(key)
        if cached:
            return cached

        with self._lock:
            waiter = self._inflight.get(key)
            owner = waiter is None
            if owner:
                waiter = threading.Event()
                self._inflight[key] = waiter
        if not owner:
            waiter.wait(timeout=DOWNLOAD_TIMEOUT + 30)
            cached = self.get(key)
            if cached:
                return cached
            raise CacheError("a parallel download did not produce the file")
        try:
            return self._download_fresh(url, key)
        finally:
            with self._lock:
                self._inflight.pop(key, None)
            waiter.set()

    def _download_fresh(self, url: str, key: str) -> Path:
        final = self.tracks_dir / f"{_safe(key)}.mp3"
        tmp = final.with_suffix(final.suffix + TMP_SUFFIX)
        tmp.parent.mkdir(parents=True, exist_ok=True)

        last_error = ""
        for codec_args in (["-c:a", "copy"], ["-c:a", "libmp3lame", "-q:a", "2"]):
            command = [
                "ffmpeg",
                "-nostdin",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                url,
                "-vn",
                *codec_args,
                "-f",
                "mp3",
                str(tmp),
            ]
            try:
                completed = subprocess.run(
                    command, capture_output=True, text=True, timeout=DOWNLOAD_TIMEOUT
                )
            except subprocess.TimeoutExpired as exc:
                last_error = f"download timed out after {DOWNLOAD_TIMEOUT}s"
                tmp.unlink(missing_ok=True)
                raise CacheError(last_error) from exc
            if completed.returncode == 0 and tmp.is_file() and tmp.stat().st_size > 0:
                break
            last_error = (completed.stderr or "").strip()[-300:] or "ffmpeg failed"
            tmp.unlink(missing_ok=True)
        else:
            raise CacheError(f"could not download the track: {last_error}")

        os.replace(tmp, final)
        size = final.stat().st_size
        with self._lock:
            self._index[key] = {
                "file": final.name,
                "size": size,
                "used_at": time.time(),
            }
            self._save_index()
            self._evict_locked()
        return final

    def remove(self, key: str) -> bool:
        with self._lock:
            record = self._index.pop(key, None)
            if not record:
                return False
            (self.tracks_dir / str(record.get("file", ""))).unlink(missing_ok=True)
            self._save_index()
            return True

    def clear(self) -> int:
        """Drop every cached file. Returns how many were removed."""
        with self._lock:
            removed = len(self._index)
            for record in self._index.values():
                (self.tracks_dir / str(record.get("file", ""))).unlink(missing_ok=True)
            self._index.clear()
            self._save_index()
        for stray in self.tracks_dir.glob(f"*{TMP_SUFFIX}"):
            stray.unlink(missing_ok=True)
        return removed

    # -- internals ---------------------------------------------------------

    def _evict_locked(self) -> None:
        """Drop least recently used files until the cap is respected."""
        if self.limit_bytes <= 0:
            return
        total = sum(int(r.get("size", 0)) for r in self._index.values())
        if total <= self.limit_bytes:
            return
        for key, record in sorted(
            self._index.items(), key=lambda item: float(item[1].get("used_at", 0))
        ):
            if total <= self.limit_bytes:
                break
            (self.tracks_dir / str(record.get("file", ""))).unlink(missing_ok=True)
            total -= int(record.get("size", 0))
            self._index.pop(key, None)
        self._save_index()

    def _load_index(self) -> None:
        try:
            raw = json.loads(self.index_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            raw = {}
        self._index = raw if isinstance(raw, dict) else {}

    def _save_index(self) -> None:
        try:
            tmp = self.index_path.with_suffix(".tmp")
            tmp.write_text(
                json.dumps(self._index, ensure_ascii=False, separators=(",", ":")),
                encoding="utf-8",
            )
            os.replace(tmp, self.index_path)
        except OSError:
            # A cache index that cannot be written is not worth failing a
            # playback over: the files stay usable, only eviction order is lost.
            pass


def _safe(key: str) -> str:
    return "".join(ch if ch.isalnum() or ch in "._-" else "_" for ch in key)[:120]


def free_bytes(path: Path) -> int:
    try:
        return shutil.disk_usage(path).free
    except OSError:
        return 0


def cleanup_stray_temp(root: Path) -> int:
    """Remove half-written downloads left by a crash."""
    removed = 0
    for stray in Path(root).glob(f"**/*{TMP_SUFFIX}"):
        stray.unlink(missing_ok=True)
        removed += 1
    return removed
