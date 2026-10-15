"""Authentication for the VK audio API.

Two paths exist, and they are not equal:

**Web (primary).** `POST https://login.vk.ru/?act=web_token` with the browser
cookies `p` and `remixsid` returns a long-lived `vk1.` token (the project
measured 50+ days) and, more importantly, can be called again with the same
cookies to refresh it. Nothing about this looks unusual to VK: it is exactly
the call the VK web player itself makes, from the user's own address and user
agent.

**Mobile (fallback).** The password grant against `oauth.vk.com/token` with a
mobile client's credentials. Its token lives about three hours, it triggers
VK's password brute-force protection, and it needs the SMS or the mobile
prompt that follows. It is kept only for users who cannot reach the browser
cookies.

Only the resulting token is written to disk, together with the cookies when
the web path was used, because a refresh needs them. The file is mode 600 and
holds a live session, so it must never be committed or shared.
"""

from __future__ import annotations

import getpass
import json
import os
import re
import secrets
import subprocess
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Mapping

import requests

from vk_api import (
    API_VERSION,
    VK_ANDROID_USER_AGENT,
    WEB_APP_ID,
    WEB_USER_AGENT,
)

WEB_TOKEN_ENDPOINT = "https://login.vk.ru/?act=web_token"
WEB_ORIGIN = "https://vk.ru"
WEB_REFERER = "https://vk.ru/"
MOBILE_TOKEN_ENDPOINT = "https://oauth.vk.com/token"
MOBILE_VALIDATE_ENDPOINT = "https://api.vk.com/method/auth.validatePhone"

CONFIG_DIR = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / (
    "omarchy-vk-music"
)
TOKEN_FILE = CONFIG_DIR / "token.json"

# Refresh a web token this long before it expires.
WEB_REFRESH_THRESHOLD = 600

COOKIE_NAMES = ("p", "remixsid")


class VkAuthError(RuntimeError):
    """Login cannot continue; the message is safe to show."""


@dataclass(frozen=True)
class WebToken:
    access_token: str
    expires: int
    user_id: int | None
    logout_hash: str = ""


@dataclass(frozen=True)
class MobileClient:
    key: str
    name: str
    client_id: str
    client_secret: str
    user_agent: str


MOBILE_CLIENTS: dict[str, MobileClient] = {
    "vk-android": MobileClient(
        key="vk-android",
        name="VK Android app",
        client_id="2274003",
        client_secret="hHbZxrka2uZ6jB1inYsH",
        user_agent=VK_ANDROID_USER_AGENT,
    ),
    "kate": MobileClient(
        key="kate",
        name="Kate Mobile",
        client_id="2685278",
        client_secret="lxhD8OD7dMsqtXIm5IUY",
        user_agent=(
            "KateMobileAndroid/56 lite-460 (Android 4.4.2; SDK 19; x86; "
            "unknown Android SDK built for x86; en)"
        ),
    ),
}


# -- web path --------------------------------------------------------------


def parse_cookies(text: str) -> dict[str, str]:
    """Pull `p` and `remixsid` out of anything a user can realistically paste.

    Accepts a `document.cookie` string, one `name=value` per line, or a
    DevTools table copy where the value is on its own line.
    """
    pairs = dict(re.findall(r"(?:^|[\s;,])(p|remixsid)=([^;\s]+)", text))
    if all(name in pairs for name in COOKIE_NAMES):
        return {name: pairs[name] for name in COOKIE_NAMES}

    lines = [line.strip() for line in text.splitlines() if line.strip()]
    values = [line for line in lines if "=" not in line]
    for name, value in zip(COOKIE_NAMES, values):
        if len(value) < 8:
            raise VkAuthError(
                "could not read the cookies: paste them as `p=<value>; remixsid=<value>`"
            )
        pairs.setdefault(name, value)
    missing = [name for name in COOKIE_NAMES if name not in pairs]
    if missing:
        raise VkAuthError(f"missing cookie(s): {', '.join(missing)}")
    return {name: pairs[name] for name in COOKIE_NAMES}


def request_web_token(
    cookies: Mapping[str, str],
    *,
    app_id: str = WEB_APP_ID,
    user_agent: str = WEB_USER_AGENT,
    timeout: float = 20.0,
    session: requests.Session | None = None,
) -> WebToken:
    """Mint (or refresh) the web token from the browser cookies."""
    cookie_header = "; ".join(f"{name}={cookies[name]}" for name in COOKIE_NAMES)
    client = session or requests
    try:
        response = client.post(
            WEB_TOKEN_ENDPOINT,
            headers={
                "User-Agent": user_agent,
                "Content-Type": "application/x-www-form-urlencoded",
                "Origin": WEB_ORIGIN,
                "Referer": WEB_REFERER,
                "Cookie": cookie_header,
            },
            data={"version": "1", "app_id": app_id},
            timeout=timeout,
        )
        payload = response.json()
    except requests.RequestException as exc:
        raise VkAuthError(f"network failure: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise VkAuthError("web token endpoint did not return JSON") from exc

    if payload.get("type") != "okay":
        info = str(payload.get("error_info") or payload.get("error_code") or payload)
        if info == "unauthorized":
            raise VkAuthError(
                "VK says unauthorized: the cookies are stale or were copied incompletely"
            )
        raise VkAuthError(f"web token refused: {info}")

    data = payload.get("data") or {}
    token = str(data.get("access_token", ""))
    if not token:
        raise VkAuthError("web token endpoint returned no token")
    return WebToken(
        access_token=token,
        expires=int(data.get("expires", 0) or 0),
        user_id=data.get("user_id"),
        logout_hash=str(data.get("logout_hash", "")),
    )


def fetch_browser_cookies(
    store: str | Path | None = None,
) -> dict[str, str]:
    """Read `p` and `remixsid` from a Firefox-family cookie database.

    Firefox keeps cookies unencrypted in `cookies.sqlite`, so no keyring
    access is needed. Chromium-family stores are encrypted and deliberately
    not handled here.

    The stores that matter on this machine are searched in order unless a
    specific one is passed. `p` lives on `.login.vk.ru` and `remixsid` on
    `.vk.ru`, so both hosts are queried and the freshest row per name wins.
    """
    candidates = [Path(store)] if store else _firefox_stores()
    if not candidates:
        raise VkAuthError("no Firefox-family cookie database found")

    attempted: list[str] = []
    for path in candidates:
        attempted.append(str(path))
        found = read_firefox_cookies(path, COOKIE_NAMES)
        if all(name in found for name in COOKIE_NAMES):
            return {name: found[name] for name in COOKIE_NAMES}

    raise VkAuthError(
        "no VK login found in the browser profiles checked: " + ", ".join(attempted)
    )


def _firefox_stores() -> list[Path]:
    patterns = (
        "~/.config/mozilla/firefox/*/cookies.sqlite",
        "~/.mozilla/firefox/*/cookies.sqlite",
        "~/.config/zen/*/cookies.sqlite",
        "~/.librewolf/*/cookies.sqlite",
        "~/.config/librewolf/*/cookies.sqlite",
        "~/.var/app/org.mozilla.firefox/.mozilla/firefox/*/cookies.sqlite",
    )
    stores: list[Path] = []
    for pattern in patterns:
        stores.extend(
            path
            for path in sorted(Path.home().glob(pattern.removeprefix("~/")))
            if path.is_file()
        )
    return stores


def read_firefox_cookies(path: Path, names: tuple[str, ...]) -> dict[str, str]:
    """Return the freshest value per cookie name, for VK hosts only."""
    import shutil
    import sqlite3
    import tempfile

    plain_names = {"p": (".login.vk.ru", "login.vk.ru", ".vk.ru", "vk.ru")}
    with tempfile.TemporaryDirectory() as tmp:
        # A Firefox profile keeps recent writes in the write-ahead log, so the
        # whole set has to travel together or the copy looks empty.
        for suffix in ("", "-wal", "-shm"):
            source = Path(str(path) + suffix)
            if source.exists():
                shutil.copy2(source, Path(tmp) / (path.name + suffix))
        try:
            connection = sqlite3.connect(str(Path(tmp) / path.name))
            rows = connection.execute(
                "SELECT name, value, host, lastAccessed FROM moz_cookies "
                "WHERE name IN ({}) AND (host LIKE '%vk.ru' OR host LIKE '%vk.com') "
                "ORDER BY lastAccessed DESC".format(",".join("?" * len(names))),
                names,
            ).fetchall()
            connection.close()
        except sqlite3.Error as exc:
            raise VkAuthError(f"could not read {path}: {exc}") from exc

    best: dict[str, tuple[int, str]] = {}
    for name, value, host, last_accessed in rows:
        if not value:
            continue
        preferred = plain_names.get(name, ())
        rank = (
            len(preferred) - preferred.index(host)
            if host in preferred
            else 0
        )
        score = rank * 10**13 + int(last_accessed or 0)
        if name not in best or score > best[name][0]:
            best[name] = (score, str(value))
    return {name: value for name, (_, value) in best.items()}


# -- mobile path -----------------------------------------------------------


def request_mobile_token(
    client: MobileClient,
    login: str,
    password: str,
    *,
    code: str | None = None,
    success_token: str | None = None,
    timeout: float = 20.0,
) -> Mapping[str, Any]:
    payload: dict[str, Any] = {
        "grant_type": "password",
        "client_id": client.client_id,
        "client_secret": client.client_secret,
        "username": login,
        "password": password,
        "scope": "audio,offline",
        "2fa_supported": 1,
        "https": 1,
        "lang": "ru",
        "v": API_VERSION,
    }
    if code:
        payload["code"] = code
    if success_token:
        payload["success_token"] = success_token
    response = requests.post(
        MOBILE_TOKEN_ENDPOINT,
        data=payload,
        headers={"User-Agent": client.user_agent},
        timeout=timeout,
    )
    try:
        return response.json()
    except json.JSONDecodeError as exc:
        raise VkAuthError(f"login endpoint returned HTTP {response.status_code}") from exc


def request_sms_code(client: MobileClient, sid: str, *, timeout: float = 20.0) -> dict[str, Any]:
    response = requests.post(
        MOBILE_VALIDATE_ENDPOINT,
        data={"sid": sid, "v": API_VERSION},
        headers={"User-Agent": client.user_agent},
        timeout=timeout,
    )
    try:
        return response.json()
    except json.JSONDecodeError:
        return {}


def open_in_browser(url: str) -> bool:
    from shutil import which

    for command in (["xdg-open", url], ["gio", "open", url]):
        if not which(command[0]):
            continue
        try:
            subprocess.Popen(
                command,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
            )
        except OSError:
            continue
        return True
    return False


def mobile_authorize(client: MobileClient, *, max_attempts: int = 3) -> Mapping[str, Any]:
    """Interactive password login. Secrets stay in this process."""
    print(f"\n=== {client.name} (client_id {client.client_id}) ===")
    print("Login and password stay in this terminal. They are not stored.")
    login = input("VK login (phone, email or id): ").strip()
    password = getpass.getpass("VK password: ")
    if not login or not password:
        raise VkAuthError("empty login or password")

    code: str | None = None
    success_token: str | None = None
    for attempt in range(1, max_attempts + 1):
        payload = request_mobile_token(
            client, login, password, code=code, success_token=success_token
        )
        if payload.get("access_token"):
            return payload

        error = str(payload.get("error", ""))
        description = str(payload.get("error_description", ""))
        print(f"  attempt {attempt}: {error} {description}".rstrip())

        if error == "need_captcha" or payload.get("redirect_uri"):
            redirect_uri = str(payload.get("redirect_uri", ""))
            print("\nVK wants a captcha. Solve it in your browser:")
            print(f"  {redirect_uri}")
            print("Then paste the `success_token` value, or the whole address.")
            if attempt == 1 and not open_in_browser(redirect_uri):
                print("(open the link manually)")
            answer = input("success_token: ").strip()
            match = re.search(r"success_token=([^&\s]+)", answer)
            success_token = match.group(1) if match else (answer or None)
            if not success_token:
                raise VkAuthError("empty captcha answer")
        elif error == "need_validation":
            validation_type = str(payload.get("validation_type", ""))
            sid = str(payload.get("validation_sid", ""))
            hint = {
                "2fa_app": "code from the authenticator app",
                "2fa_sms": "code from SMS",
                "2fa_callreset": "last 4 digits of the incoming call",
            }.get(validation_type, f"code ({validation_type})")
            if sid:
                request_sms_code(client, sid)
            code = input(f"Enter the {hint} (empty to retry): ").strip() or None
        elif error == "invalid_request":
            code = input("Code rejected. Try again: ").strip() or None
        elif error in ("invalid_client", "invalid_grant"):
            reason = description or "login or password rejected"
            raise VkAuthError(reason)
        elif "Flood control" in error or payload.get("error_type") == "password_bruteforce_attempt":
            raise VkAuthError(
                "flood control: VK is throttling password logins for this account. "
                "Stop and wait a few hours; use the web cookie path instead."
            )
        else:
            raise VkAuthError(f"unhandled response: {json.dumps(payload, ensure_ascii=False)}")

    raise VkAuthError("attempts exhausted")


# -- storage ---------------------------------------------------------------


def new_device_id() -> str:
    return secrets.token_hex(8)


def store_path() -> Path:
    return TOKEN_FILE


def save_web_token(token: WebToken, cookies: Mapping[str, str]) -> Path:
    return _write_record(
        {
            "mode": "web",
            "access_token": token.access_token,
            "expires": token.expires,
            "user_id": token.user_id,
            "logout_hash": token.logout_hash,
            "client_id": WEB_APP_ID,
            "user_agent": WEB_USER_AGENT,
            "cookies": {name: cookies[name] for name in COOKIE_NAMES},
            "device_id": new_device_id(),
            "obtained_at": _now(),
        },
        token.access_token,
    )


def save_mobile_token(client: MobileClient, payload: Mapping[str, Any]) -> Path:
    return _write_record(
        {
            "mode": "mobile",
            "access_token": payload["access_token"],
            "expires": int(time.time()) + int(payload.get("expires_in", 0) or 0),
            "user_id": payload.get("user_id"),
            "client_id": client.client_id,
            "client_name": client.key,
            "user_agent": client.user_agent,
            "cookies": {},
            "device_id": new_device_id(),
            "obtained_at": _now(),
        },
        payload["access_token"],
    )


def refresh_web_record(record: Mapping[str, Any]) -> dict[str, Any]:
    """Mint a fresh web token from the stored cookies, keeping the record shape."""
    cookies = record.get("cookies") or {}
    missing = [name for name in COOKIE_NAMES if not cookies.get(name)]
    if missing:
        raise VkAuthError(
            "stored record has no cookies, so the token cannot be refreshed: "
            + ", ".join(missing)
        )
    token = request_web_token(cookies)
    updated = dict(record)
    updated.update(
        {
            "access_token": token.access_token,
            "expires": token.expires,
            "user_id": token.user_id,
            "logout_hash": token.logout_hash,
            "obtained_at": _now(),
        }
    )
    _write_record(updated, token.access_token)
    return updated


def needs_refresh(record: Mapping[str, Any], threshold: int = WEB_REFRESH_THRESHOLD) -> bool:
    """True when the token is close to expiry and can be refreshed."""
    if record.get("mode") != "web":
        return False
    expires = int(record.get("expires", 0) or 0)
    if expires <= 0:
        return False
    return expires - int(time.time()) < threshold


def load_record() -> dict[str, Any] | None:
    try:
        return json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        raise VkAuthError(f"token store is unreadable: {exc}") from exc


def _write_record(record: Mapping[str, Any], token: str) -> Path:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CONFIG_DIR, 0o700)
    payload = dict(record)
    if isinstance(payload.get("access_token"), str) and payload["access_token"] == token:
        payload["token_hint"] = f"{token[:6]}...{len(token)} chars"
    tmp = TOKEN_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(TOKEN_FILE)
    return TOKEN_FILE


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")
