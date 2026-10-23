#!/usr/bin/env python3
"""Live probe of the VK audio API for omarchy-vk-music.

Answers, against the real API, the questions the design depends on: does this
token reach the audio methods, does the catalog work, what does a stream look
like, and can ffmpeg and mpv open it. The report never contains the token, the
full user id, or query strings from stream URLs.

    python3 tools/spike.py --token-file ~/.config/omarchy-vk-music/accounts.json
    python3 tools/spike.py --token-file ... --play
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))

import requests  # noqa: E402

from vk_api import (  # noqa: E402
    API_BASE,
    API_BASE_FALLBACK,
    API_VERSION,
    WEB_APP_ID,
    WEB_USER_AGENT,
    Track,
    VkApiError,
    VkClient,
    VkHaltError,
    classify,
    redact_url,
)

MAX_TEXT = 48


def mask_id(value: Any) -> str:
    text = str(value)
    if len(text) <= 2:
        return "*" * len(text)
    return "*" * (len(text) - 2) + text[-2:]


def short(text: str, limit: int = MAX_TEXT) -> str:
    text = re.sub(r"\s+", " ", str(text)).strip()
    return text if len(text) <= limit else text[: limit - 1] + "…"


class Report:
    """Collects check results so one failure never stops the run."""

    def __init__(self) -> None:
        self.checks: list[dict[str, Any]] = []

    def run(self, name: str, function: Callable[[], Any]) -> Any:
        print(f"— {name}", flush=True)
        try:
            detail = function()
        except VkHaltError as exc:
            entry = {
                "check": name,
                "status": "halted",
                "code": exc.code,
                "reason": classify(exc),
                "message": short(exc.message, 120),
                "method": exc.method,
            }
        except VkApiError as exc:
            entry = {
                "check": name,
                "status": "vk_error",
                "code": exc.code,
                "reason": classify(exc),
                "message": short(exc.message, 120),
                "method": exc.method,
                "captcha": bool(exc.captcha_sid),
            }
        except Exception as exc:  # noqa: BLE001 - a probe reports, never raises
            entry = {"check": name, "status": "failure", "message": short(repr(exc), 200)}
        else:
            entry = {"check": name, "status": "ok", "detail": detail}
        self.checks.append(entry)
        marker = {"ok": "ok", "vk_error": "vk error", "halted": "HALT", "failure": "FAIL"}[
            entry["status"]
        ]
        print(f"  {marker}: {json.dumps(entry.get('detail', entry), ensure_ascii=False)}")
        return entry.get("detail")

    def as_dict(self) -> dict[str, Any]:
        failed = [c for c in self.checks if c["status"] != "ok"]
        halted = [c for c in self.checks if c["status"] == "halted"]
        return {
            "checks": self.checks,
            "summary": {
                "total": len(self.checks),
                "ok": len(self.checks) - len(failed),
                "failed": len(failed),
                "halted": len(halted),
            },
        }


def probe_stream(track: Track) -> dict[str, Any]:
    """Fetch the first bytes of a stream and describe what VK is serving."""
    result: dict[str, Any] = {"kind": track.stream_kind, "url": redact_url(track.url)}
    if not track.url:
        return result

    with requests.get(track.url, stream=True, timeout=20) as response:
        result["http_status"] = response.status_code
        result["content_type"] = response.headers.get("Content-Type", "")
        result["content_length"] = response.headers.get("Content-Length", "")
        head = response.raw.read(4096, decode_content=False) or b""
    result["first_bytes"] = head[:16].hex()
    result["looks_like_playlist"] = head.lstrip().startswith(b"#EXTM3U")

    if result["looks_like_playlist"]:
        text = head.decode("utf-8", errors="replace")
        keys = re.findall(r"#EXT-X-KEY:([^\n]*)", text)
        result["hls"] = {
            "key_tags": [short(k, 120) for k in keys],
            "variant_count": len(re.findall(r"#EXT-X-STREAM-INF:([^\n]*)", text)),
            "encrypted": bool(keys) and "METHOD=NONE" not in " ".join(keys),
        }
        key_url = _first_key_url(text, track.url)
        if key_url:
            try:
                with requests.get(key_url, timeout=20) as key_response:
                    body = key_response.content
                result["hls"]["key_http_status"] = key_response.status_code
                result["hls"]["key_bytes"] = len(body)
            except Exception as exc:  # noqa: BLE001
                result["hls"]["key_error"] = short(repr(exc), 120)
    return result


def _first_key_url(playlist: str, base_url: str) -> str:
    from urllib.parse import urljoin

    match = re.search(r'#EXT-X-KEY:[^\n]*URI="([^"]+)"', playlist)
    return urljoin(base_url, match.group(1)) if match else ""


def probe_ffprobe(track: Track, seconds: float = 8.0) -> dict[str, Any]:
    """Ask ffmpeg to decode the stream, which is what mpv will do."""
    if not track.url:
        return {"status": "no_url"}
    command = [
        "ffprobe",
        "-v",
        "error",
        "-read_intervals",
        f"%+{seconds}",
        "-show_entries",
        "stream=codec_name,codec_type,sample_rate,channels:format=format_name,duration",
        "-of",
        "json",
        track.url,
    ]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    if completed.returncode != 0:
        return {"status": "error", "stderr": short(completed.stderr.strip(), 300)}
    try:
        payload = json.loads(completed.stdout or "{}")
    except json.JSONDecodeError:
        return {"status": "unparsable", "stdout": short(completed.stdout, 200)}
    audio = next(
        (s for s in (payload.get("streams") or []) if s.get("codec_type") == "audio"), {}
    )
    fmt = payload.get("format") or {}
    return {
        "status": "ok",
        "format": fmt.get("format_name", ""),
        "duration": fmt.get("duration", ""),
        "codec": audio.get("codec_name", ""),
        "sample_rate": audio.get("sample_rate", ""),
        "channels": audio.get("channels", ""),
    }


def probe_mpv(track: Track, seconds: float = 6.0) -> dict[str, Any]:
    """Play a few seconds with the same mpv invocation the plugin will use."""
    if not track.url:
        return {"status": "no_url"}
    command = [
        "mpv",
        "--no-config",
        "--no-video",
        "--audio-display=no",
        "--force-window=no",
        "--really-quiet",
        f"--length={seconds}",
        track.url,
    ]
    try:
        completed = subprocess.run(command, capture_output=True, text=True, timeout=seconds + 30)
    except subprocess.TimeoutExpired:
        return {"status": "timeout"}
    return {
        "status": "ok" if completed.returncode == 0 else "error",
        "returncode": completed.returncode,
        "stderr": short(completed.stderr.strip(), 300),
    }


def tracks_detail(tracks: list[Track]) -> dict[str, Any]:
    kinds: dict[str, int] = {}
    for track in tracks:
        kinds[track.stream_kind] = kinds.get(track.stream_kind, 0) + 1
    return {
        "count": len(tracks),
        "stream_kinds": kinds,
        "with_thumb": sum(1 for t in tracks if t.thumb),
        "with_lyrics": sum(1 for t in tracks if t.has_lyrics),
        "liked": sum(1 for t in tracks if t.is_liked),
        "sample": [
            {
                "label": short(t.label),
                "duration": t.duration,
                "key": f"{mask_id(t.owner_id)}_{mask_id(t.audio_id)}",
                "kind": t.stream_kind,
            }
            for t in tracks[:5]
        ],
    }


def build_checks(
    client: VkClient,
    report: Report,
    *,
    play: bool = False,
    legacy: bool = True,
    limit: int = 10,
) -> None:
    me = report.run("users.get", client.me)
    user_id = int((me or {}).get("id", 0))

    catalog = report.run(
        "catalog.getAudio (sections)",
        lambda: [s.__dict__ for s in client.sections()],
    )
    if catalog:
        first_section = str(catalog[0]["id"])
        report.run(
            f"catalog.getSection {short(first_section, 24)}",
            lambda: client.section(first_section).to_dict(),
        )
    home = report.run(
        "catalog.getAudio (need_blocks)",
        lambda: _home_detail(client, user_id),
    )
    report.run(
        "audio.search",
        lambda: tracks_detail(client.search("radiohead")),
    )
    report.run(
        "audio.getSearchSuggestions",
        lambda: client.search_suggestions("radio"),
    )

    if legacy:
        report.run("audio.getCount", lambda: {"count": client.audio_count(user_id)})
        legacy_tracks = report.run(
            "audio.get",
            lambda: tracks_detail(client.audio_get(user_id, count=limit)),
        )
    else:
        legacy_tracks = None

    candidates: list[Track] = []
    if legacy_tracks:
        candidates = client.audio_get(user_id, count=limit)
    if not candidates and isinstance(home, dict):
        candidates = [Track.from_item(item) for item in home.pop("_tracks", [])]

    streamable = next((t for t in candidates if t.url), None)
    if streamable is None:
        report.run("stream probe", lambda: {"status": "no track had a url"})
        return
    report.run("stream probe", lambda: probe_stream(streamable))
    report.run("ffprobe decode", lambda: probe_ffprobe(streamable))
    if play:
        report.run("mpv playback", lambda: probe_mpv(streamable))


def _home_detail(client: VkClient, user_id: int) -> dict[str, Any]:
    sections, audios, playlists, default = client.catalog_home(owner_id=user_id)
    return {
        "sections": [s.__dict__ for s in sections[:6]],
        "default_section": default,
        "recent_audios": len(audios),
        "playlists": len(playlists),
        "playlist_titles": [short(p.title) for p in playlists[:5]],
        "_tracks": [t.to_dict() for t in audios[:5]],
    }


def load_record(path: str) -> dict[str, Any]:
    raw = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    if "accounts" in raw:
        active = raw.get("active")
        record = (raw.get("accounts") or {}).get(str(active))
        if not isinstance(record, dict):
            raise SystemExit("the account store has no active account")
        return record
    if "access_token" not in raw:
        raise SystemExit("token record has no access_token")
    return raw


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--token-file",
        default=str(Path.home() / ".config" / "omarchy-vk-music" / "accounts.json"),
        help="account store or a token record written by tools/auth_spike.py",
    )
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--play", action="store_true", help="also decode a few seconds with mpv")
    parser.add_argument("--json", help="write the full report to this path")
    parser.add_argument("--version", default=API_VERSION)
    parser.add_argument("--api-base", default=API_BASE)
    parser.add_argument("--no-legacy", action="store_true", help="skip the old audio.* checks")
    args = parser.parse_args()

    record = load_record(args.token_file)
    client = VkClient(
        record["access_token"],
        user_agent=record.get("user_agent") or WEB_USER_AGENT,
        client_id=str(record.get("client_id") or WEB_APP_ID),
        device_id=record.get("device_id"),
        version=args.version,
        api_base=args.api_base,
    )
    print(f"mode: {record.get('mode', 'unknown')}")
    print(f"user agent: {short(client.user_agent, 40)}")
    print(f"api: {client.api_base} v{client.version} client_id {client.client_id}")

    report = Report()
    build_checks(client, report, play=args.play, legacy=not args.no_legacy, limit=args.limit)
    payload = report.as_dict()

    if args.json:
        Path(args.json).expanduser().write_text(
            json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        print(f"report written to {args.json}")

    summary = payload["summary"]
    print(f"\n{summary['ok']}/{summary['total']} checks passed")
    if summary["halted"]:
        print("halted: fix the cause before any further request")
        return 2
    return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
