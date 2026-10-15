#!/usr/bin/env python3
"""Command-line client for the local VK Music service (fallback path).

`omarchy-vk-music`, the shell script next to this file, is what the widget
normally runs: it speaks to the daemon through `nc -U` in about 0.4 ms, while
starting Python costs about 15 ms, which is visible when a slider is dragged.
This file still exists because it can do what a shell script should not: read a
password with `getpass`, walk the interactive login steps, and act as the whole
client when neither `nc` nor `socat` is installed.

Every command is a thin request over the Unix socket and prints one line of
JSON. Nothing here talks to VK directly, and no command prints the access token
or the session cookies.

    omarchy-vk-music status
    omarchy-vk-music home
    omarchy-vk-music play section all
    omarchy-vk-music search radiohead --play
    omarchy-vk-music next
    omarchy-vk-music auth web
"""

from __future__ import annotations

import json
import os
import socket
import sys
from pathlib import Path

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SOCKET_PATH = Path(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")) / (
    "omarchy-vk-music.sock"
)


def request(payload: dict) -> dict:
    if not SOCKET_PATH.exists():
        return {
            "ok": False,
            "error": {
                "code": "backend_down",
                "message": "Сервис VK Music не запущен: systemctl --user start omarchy-vk-music",
            },
        }
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.settimeout(120)
    try:
        connection.connect(str(SOCKET_PATH))
        connection.sendall(json.dumps(payload, ensure_ascii=False).encode() + b"\n")
        buffer = b""
        while b"\n" not in buffer and len(buffer) < MAX_RESPONSE_BYTES:
            chunk = connection.recv(65536)
            if not chunk:
                break
            buffer += chunk
    except OSError as exc:
        return {"ok": False, "error": {"code": "ipc_error", "message": str(exc)}}
    finally:
        connection.close()
    line, _, _ = buffer.partition(b"\n")
    try:
        return json.loads(line or b"{}")
    except json.JSONDecodeError:
        return {"ok": False, "error": {"code": "bad_response", "message": "сервис ответил не JSON"}}


def parse_argv(argv: list[str]) -> dict:
    """Map a command line onto the service protocol.

    Kept as an explicit switch rather than argparse: the protocol is small, and
    several commands take a free-form query that must not be split or escaped.
    """
    if not argv:
        return {"command": "status"}
    head, rest = argv[0], argv[1:]
    flags = {item for item in rest if item.startswith("--")}
    words = [item for item in rest if not item.startswith("--")]
    play_after = "--play" in flags

    if head == "play":
        if not words:
            return {"command": "pause"}
        kind, args = words[0], words[1:]
        if kind == "section":
            payload = {"command": "play_section", "id": args[0] if args else "all"}
            if len(args) > 1 and args[1].isdigit():
                payload["index"] = int(args[1])
            if "--title" in flags:
                index = argv.index("--title")
                payload["title"] = argv[index + 1] if index + 1 < len(argv) else ""
        elif kind == "search":
            digits = [a for a in args if a.isdigit()]
            query = " ".join(a for a in args if a not in digits)
            payload = {"command": "play_search", "query": query}
            if digits:
                payload["index"] = int(digits[-1])
        elif kind == "playlist":
            if len(args) < 2:
                raise SystemExit("play playlist <owner_id> <playlist_id> [access_key] [title]")
            payload = {
                "command": "play_playlist",
                "ownerId": int(args[0]),
                "playlistId": int(args[1]),
                "accessKey": args[2] if len(args) > 2 else "",
                "title": " ".join(args[3:]),
            }
        elif kind == "queue":
            payload = {"command": "play_tracks", "tracks": json.load(sys.stdin)}
        elif kind == "keys":
            # Queue exactly these tracks, by their VK keys, without a second search.
            title = ""
            if "--title" in flags:
                index = argv.index("--title")
                title = argv[index + 1] if index + 1 < len(argv) else ""
                args = args[: args.index("--title")]
            if not args:
                raise SystemExit("play keys <key> [<key>...] [--title <title>]")
            payload = {"command": "play_keys", "keys": args, "index": 0, "title": title}
            if "--index" in flags:
                index = argv.index("--index")
                payload["index"] = int(argv[index + 1]) if index + 1 < len(argv) else 0
        else:
            raise SystemExit(f"unknown play target: {kind}")
        return payload

    simple = {
        "status": "status",
        "sections": "sections",
        "home": "home",
        "next": "next",
        "previous": "previous",
        "pause": "pause",
        "stop": "stop",
        "queue": "queue",
        "session": "session",
        "logout": "logout",
    }
    if head in simple:
        return {"command": simple[head]}
    if head == "jump":
        return {"command": "jump", "index": int(words[0]) if words else 0}
    if head == "section":
        payload = {"command": "section", "id": words[0] if words else "all"}
        if len(words) > 1:
            payload["startFrom"] = words[1]
        return payload
    if head == "search":
        query = " ".join(words)
        payload = {"command": "search", "query": query}
        return {"command": "play_search", "query": query} if play_after else payload
    if head == "suggestions":
        return {"command": "suggestions", "query": " ".join(words)}
    if head == "seek":
        return {"command": "seek", "value": float(words[0]) if words else 0}
    if head == "volume":
        if not words:
            return {"command": "status"}
        # `--live` marks a step from a drag: the daemon applies it to mpv but
        # does not write the playback state until the drag ends.
        live = "--live" in flags
        token = words[0]
        if token.startswith(("+", "-")):
            return {"command": "volume", "delta": int(token), "live": live}
        return {"command": "volume", "value": int(float(token)), "live": live}
    if head == "shuffle":
        if not words:
            return {"command": "shuffle"}
        return {"command": "shuffle", "enabled": words[0] in ("on", "true", "1", "yes")}
    if head == "repeat":
        return {"command": "repeat", "mode": words[0] if words else "off"}
    if head == "like":
        return {"command": "like", "key": words[0] if words else "", "liked": True}
    if head == "unlike":
        return {"command": "like", "key": words[0] if words else "", "liked": False}
    if head == "lyrics":
        return {"command": "lyrics", "key": words[0] if words else ""}
    if head == "cache":
        return {"command": "cache", "action": words[0] if words else "stats"}
    if head == "prefs":
        settings = {}
        for word in words:
            key, _, value = word.partition("=")
            if not _:
                continue
            settings[key] = _coerce(value)
        return {"command": "preferences", "set": settings} if settings else {"command": "preferences"}
    if head == "auth":
        action = words[0] if words else "status"
        if action == "web":
            if "--cookies" in flags:
                index = argv.index("--cookies")
                value = argv[index + 1] if index + 1 < len(argv) else ""
                return {"command": "auth_web", "cookies": value, "fromBrowser": False}
            if "--no-browser" in flags:
                return {"command": "auth_web", "cookies": _read_pasted_cookies(), "fromBrowser": False}
            return {"command": "auth_web", "fromBrowser": True}
        if action == "mobile":
            login = words[1] if len(words) > 1 else input("VK login: ").strip()
            import getpass

            password = getpass.getpass("VK password: ")
            client = "kate" if "--kate" in flags else "vk-android"
            return {
                "command": "auth_mobile_start",
                "login": login,
                "password": password,
                "client": client,
            }
        if action == "step":
            payload: dict = {"command": "auth_mobile_step"}
            if "--code" in flags:
                index = argv.index("--code")
                payload["code"] = argv[index + 1] if index + 1 < len(argv) else ""
            if "--success-token" in flags:
                index = argv.index("--success-token")
                payload["successToken"] = argv[index + 1] if index + 1 < len(argv) else ""
            return payload
        return {"command": "session"}
    raise SystemExit(f"unknown command: {head}")


def _coerce(value: str):
    if value in ("true", "on", "yes"):
        return True
    if value in ("false", "off", "no"):
        return False
    try:
        return int(value)
    except ValueError:
        return value


def _read_pasted_cookies() -> str:
    print("Paste `p=<value>; remixsid=<value>` (DevTools → Storage → Cookies):", file=sys.stderr)
    return sys.stdin.readline().strip()


def main() -> int:
    pretty = "--pretty" in sys.argv
    argv = [item for item in sys.argv[1:] if item != "--pretty"]
    try:
        payload = parse_argv(argv)
    except SystemExit as exc:
        print(exc, file=sys.stderr)
        return 2

    response = request(payload)
    if pretty:
        print(json.dumps(response, ensure_ascii=False, indent=2))
    else:
        print(json.dumps(response, ensure_ascii=False))
    return 0 if response.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
