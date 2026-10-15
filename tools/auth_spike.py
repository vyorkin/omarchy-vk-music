#!/usr/bin/env python3
"""Log in to VK for omarchy-vk-music and verify the token works.

    python3 tools/auth_spike.py web                 # read the browser cookies, or paste them
    python3 tools/auth_spike.py web --no-browser    # paste the cookies by hand
    python3 tools/auth_spike.py mobile              # password path (fallback)
    python3 tools/auth_spike.py status              # what is stored, without secrets
    python3 tools/auth_spike.py refresh             # mint a new web token from stored cookies

The web path is the quiet one. It reads the cookies `p` and `remixsid` from
the browser session you already have — no password, no new device login — and
exchanges them for a long-lived token the plugin can refresh by itself. By
default the cookies are read from the Firefox-family profiles on this machine
(`~/.config/mozilla/firefox`, Zen, LibreWolf); use `--no-browser` to paste
them from DevTools → Storage → Cookies instead. Note that `p` belongs to
`.login.vk.ru` and `remixsid` to `.vk.ru`.

The password path exists as a fallback. It writes nothing but the token, but
VK throttles password logins hard and its token dies in about three hours.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "backend"))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spike import Report, build_checks, load_record  # noqa: E402
from vk_api import WEB_APP_ID, WEB_USER_AGENT, VkClient  # noqa: E402

from vk_auth import (  # noqa: E402
    MOBILE_CLIENTS,
    TOKEN_FILE,
    VkAuthError,
    fetch_browser_cookies,
    load_record as load_stored,
    mobile_authorize,
    needs_refresh,
    parse_cookies,
    refresh_web_record,
    request_web_token,
    save_mobile_token,
    save_web_token,
)


def cmd_web(args: argparse.Namespace) -> int:
    if args.cookies:
        cookies = parse_cookies(args.cookies)
    elif args.no_browser:
        print("Paste the cookies for https://vk.ru — DevTools → Storage → Cookies.")
        print("`p` lives on `.login.vk.ru`, `remixsid` on `.vk.ru`.")
        print("Either `p=<value>; remixsid=<value>` on one line, or the two values")
        print("on separate lines in that order.")
        cookies = parse_cookies(sys.stdin.read())
    else:
        print("reading cookies from the Firefox-family browser profiles")
        cookies = fetch_browser_cookies()
    print(f"  cookies: p=…{len(cookies['p'])} chars, remixsid=…{len(cookies['remixsid'])} chars")

    token = request_web_token(cookies)
    lifetime_days = (token.expires - time.time()) / 86400 if token.expires else 0
    print(f"  token received: {len(token.access_token)} chars, "
          f"prefix {token.access_token[:6]}…, valid {lifetime_days:.1f} days")
    if not args.no_save:
        path = save_web_token(token, cookies)
        print(f"  stored in {path} (mode 600, holds the session cookies)")
    return _verify(args, token.access_token, WEB_USER_AGENT, WEB_APP_ID, None)


def cmd_mobile(args: argparse.Namespace) -> int:
    client = MOBILE_CLIENTS[args.client]
    payload = mobile_authorize(client)
    expires_in = int(payload.get("expires_in", 0) or 0)
    print(f"  token received: {len(payload['access_token'])} chars, "
          f"prefix {payload['access_token'][:6]}…, valid {expires_in / 3600:.1f} hours")
    if not args.no_save:
        path = save_mobile_token(client, payload)
        print(f"  stored in {path} (mode 600)")
    return _verify(args, payload["access_token"], client.user_agent, client.client_id, None)


def cmd_refresh(args: argparse.Namespace) -> int:
    record = load_stored()
    if record is None:
        print(f"nothing stored in {TOKEN_FILE}", file=sys.stderr)
        return 1
    if record.get("mode") != "web":
        print("only web records can be refreshed from cookies", file=sys.stderr)
        return 1
    updated = refresh_web_record(record)
    print(f"  refreshed: {len(updated['access_token'])} chars, "
          f"valid {(updated['expires'] - time.time()) / 86400:.1f} days")
    return 0


def cmd_status(_: argparse.Namespace) -> int:
    record = load_stored()
    if record is None:
        print(f"nothing stored in {TOKEN_FILE}")
        return 1
    expires = int(record.get("expires", 0) or 0)
    remaining = expires - int(time.time()) if expires else 0
    print(json.dumps(
        {
            "mode": record.get("mode"),
            "client_id": record.get("client_id"),
            "user_id": record.get("user_id"),
            "token": record.get("token_hint", "unknown"),
            "obtained_at": record.get("obtained_at"),
            "expires_in_hours": round(remaining / 3600, 1) if expires else None,
            "has_cookies": all((record.get("cookies") or {}).get(name) for name in ("p", "remixsid")),
            "refresh_needed": needs_refresh(record),
        },
        ensure_ascii=False,
        indent=2,
    ))
    return 0


def _verify(
    args: argparse.Namespace,
    token: str,
    user_agent: str,
    client_id: str,
    device_id: str | None,
) -> int:
    if args.no_verify:
        return 0
    if not args.no_save:
        record = load_record(str(TOKEN_FILE))
        client_id = str(record.get("client_id") or client_id)
        device_id = record.get("device_id")
    client = VkClient(token, user_agent=user_agent, client_id=client_id, device_id=device_id)
    print("\nverifying against the live API")
    report = Report()
    build_checks(client, report, play=args.play)
    summary = report.as_dict()["summary"]
    print(f"\n{summary['ok']}/{summary['total']} checks passed")
    if summary["halted"]:
        return 2
    return 0 if summary["failed"] == 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    web = sub.add_parser("web", help="cookies → long-lived web token")
    web.add_argument(
        "--from-browser",
        action="store_true",
        help="read cookies from the Firefox-family browser profiles (default)",
    )
    web.add_argument("--no-browser", action="store_true", help="paste the cookies by hand")
    web.add_argument("--cookies", help="`p=…; remixsid=…` string")
    web.set_defaults(func=cmd_web)

    mobile = sub.add_parser("mobile", help="password login (fallback path)")
    mobile.add_argument("--client", choices=sorted(MOBILE_CLIENTS), default="vk-android")
    mobile.set_defaults(func=cmd_mobile)

    status = sub.add_parser("status", help="show the stored record without secrets")
    status.set_defaults(func=cmd_status)

    refresh = sub.add_parser("refresh", help="mint a new web token from stored cookies")
    refresh.set_defaults(func=cmd_refresh)

    for child in (web, mobile):
        child.add_argument("--no-save", action="store_true", help="do not store the result")
        child.add_argument("--no-verify", action="store_true", help="skip the API checks")
        child.add_argument("--play", action="store_true", help="also play a few seconds with mpv")

    args = parser.parse_args()
    try:
        return int(args.func(args))
    except VkAuthError as exc:
        print(f"failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
