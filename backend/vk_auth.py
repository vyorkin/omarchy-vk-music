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
import threading
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
# The single-account file this plugin used before accounts existed. It is read
# once, migrated into ACCOUNTS_FILE and removed.
TOKEN_FILE = CONFIG_DIR / "token.json"
ACCOUNTS_FILE = CONFIG_DIR / "accounts.json"
_STORE_LOCK = threading.RLock()

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

    A machine can hold several Firefox-family profiles, and only one of them is
    the session the user is looking at. Picking the first profile that has VK
    cookies is what signed the panel into an old account: profile directory
    names sort before the one in use, and both hold a complete `p`/`remixsid`
    pair. The freshest pair wins instead — `lastAccessed` moves whenever the
    browser uses a cookie, so the session in the open window is the newest one.
    """
    candidates = [Path(store)] if store else _firefox_stores()
    if not candidates:
        raise VkAuthError("no Firefox-family cookie database found")

    found = _best_cookie_set(candidates)
    if found:
        return found

    raise VkAuthError(
        "no VK login found in the browser profiles checked: "
        + ", ".join(str(path) for path in candidates)
    )


def _best_cookie_set(candidates: list[Path]) -> dict[str, str] | None:
    """The complete VK cookie pair with the newest `lastAccessed`."""
    best: dict[str, str] | None = None
    best_score = -1
    for path in candidates:
        try:
            cookies, score = _read_firefox_cookies(path, COOKIE_NAMES)
        except VkAuthError:
            # A profile this process cannot read is not a profile with a login;
            # one broken store must not hide the account in the next one.
            continue
        if not all(name in cookies for name in COOKIE_NAMES):
            continue
        if score > best_score:
            best = {name: cookies[name] for name in COOKIE_NAMES}
            best_score = score
    return best


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
    return _read_firefox_cookies(path, names)[0]


def _read_firefox_cookies(
    path: Path, names: tuple[str, ...]
) -> tuple[dict[str, str], int]:
    """The cookies, plus the newest `lastAccessed` among them.

    The timestamp is what tells two profiles' sessions apart; `read_firefox_cookies`
    keeps its old shape for callers that only want the values.
    """
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
    freshest = max((score for score, _ in best.values()), default=0)
    return {name: value for name, (_, value) in best.items()}, freshest


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
    return ACCOUNTS_FILE


def save_web_token(
    token: WebToken,
    cookies: Mapping[str, str],
    profile: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Store (or refresh) one web account and make it the active one."""
    return save_account(
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
        profile=profile,
    )


def save_mobile_token(
    client: MobileClient,
    payload: Mapping[str, Any],
    profile: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    return save_account(
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
        profile=profile,
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
            "user_id": token.user_id or record.get("user_id"),
            "logout_hash": token.logout_hash,
            "obtained_at": _now(),
        }
    )
    return save_account(updated, make_active=False)


def needs_refresh(record: Mapping[str, Any], threshold: int = WEB_REFRESH_THRESHOLD) -> bool:
    """True when the token is close to expiry and can be refreshed."""
    if record.get("mode") != "web":
        return False
    expires = int(record.get("expires", 0) or 0)
    if expires <= 0:
        return False
    return expires - int(time.time()) < threshold


# -- the account store ------------------------------------------------------
#
# One file holds every session, keyed by VK's own user id:
#
#     {"active": "12345", "accounts": {"12345": {...}, "67890": {...}}}
#
# The id is a string in the document and the account's own `user_id` stays an
# int, because QML compares the active marker against what `users.get` sent.
# "Active" is which record the daemon should sign in with; the per-account
# queue and likes live in the state file, not here.


def _account_key(value: Any) -> str:
    text = str(value).strip()
    try:
        return str(int(text))
    except ValueError:
        return text


def _normalize_store(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, Mapping):
        raise VkAuthError("account store is not an object")
    accounts = raw.get("accounts")
    if not isinstance(accounts, Mapping):
        accounts = {}
    store: dict[str, Any] = {
        "active": None,
        "accounts": {
            str(key): dict(record)
            for key, record in accounts.items()
            if isinstance(record, Mapping)
        },
    }
    active = raw.get("active")
    if active is not None:
        store["active"] = _account_key(active)
        if store["active"] not in store["accounts"]:
            store["active"] = next(iter(store["accounts"]), None)
    return store


def _read_store() -> dict[str, Any]:
    with _STORE_LOCK:
        return _read_store_unlocked()


def _read_store_unlocked() -> dict[str, Any]:
    try:
        raw = json.loads(ACCOUNTS_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return _migrate_legacy()
    except (OSError, json.JSONDecodeError) as exc:
        raise VkAuthError(f"account store is unreadable: {exc}") from exc
    return _normalize_store(raw)


def _migrate_legacy() -> dict[str, Any]:
    """Turn the old single-account token file into the store, once."""
    try:
        record = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"active": None, "accounts": {}}
    except (OSError, json.JSONDecodeError) as exc:
        raise VkAuthError(f"token store is unreadable: {exc}") from exc
    if not isinstance(record, Mapping):
        raise VkAuthError("token store is not an object")
    store: dict[str, Any] = {"active": None, "accounts": {}}
    user_id = record.get("user_id")
    if user_id is not None:
        key = _account_key(user_id)
        migrated = dict(record)
        migrated.setdefault("added_at", _now())
        store["accounts"][key] = migrated
        store["active"] = key
        _write_store(store)
        TOKEN_FILE.unlink(missing_ok=True)
    return store


def _write_store(store: Mapping[str, Any]) -> Path:
    with _STORE_LOCK:
        payload = _normalize_store(store)
        payload["version"] = 1
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        os.chmod(CONFIG_DIR, 0o700)
        tmp = ACCOUNTS_FILE.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
        os.chmod(tmp, 0o600)
        tmp.replace(ACCOUNTS_FILE)
        return ACCOUNTS_FILE


def summarize_record(record: Mapping[str, Any], *, active: bool = False) -> dict[str, Any]:
    """The public face of an account: never the token, the cookies or the ua."""
    expires = int(record.get("expires", 0) or 0)
    return {
        "id": record.get("user_id"),
        "name": str(record.get("name") or ""),
        "photo": str(record.get("photo") or ""),
        "mode": str(record.get("mode", "")),
        "active": active,
        "has_cookies": all(
            (record.get("cookies") or {}).get(name) for name in COOKIE_NAMES
        ),
        "expires_in": max(0, expires - int(time.time())) if expires else 0,
    }


def account_list() -> list[dict[str, Any]]:
    store = _read_store()
    active = store.get("active")
    items = [
        summarize_record(record, active=key == active)
        for key, record in store["accounts"].items()
    ]
    items.sort(key=lambda item: 0 if item["active"] else 1)
    return items


def active_account_id() -> str | None:
    return _read_store().get("active")


def active_record() -> dict[str, Any] | None:
    store = _read_store()
    key = store.get("active")
    record = store["accounts"].get(key) if key is not None else None
    return dict(record) if record else None


def account_record(user_id: Any) -> dict[str, Any] | None:
    store = _read_store()
    record = store["accounts"].get(_account_key(user_id))
    return dict(record) if record else None


def save_account(
    record: Mapping[str, Any],
    *,
    profile: Mapping[str, Any] | None = None,
    make_active: bool = True,
) -> dict[str, Any]:
    """Insert or replace one account. A new or re-added account becomes active."""
    with _STORE_LOCK:
        store = _read_store()
        user_id = record.get("user_id")
        if profile and profile.get("user_id") is not None:
            user_id = profile["user_id"]
        if user_id is None:
            raise VkAuthError(
                "VK did not say which account this token belongs to; "
                "sign in through the browser or the mobile client instead"
            )
        key = _account_key(user_id)
        existing = dict(store["accounts"].get(key) or {})
        updated = dict(existing)
        updated.update({name: value for name, value in record.items() if name != "token_hint"})
        updated["user_id"] = int(key) if key.lstrip("-").isdigit() else user_id
        if profile:
            for name in ("name", "photo"):
                if profile.get(name):
                    updated[name] = str(profile[name])
        if not updated.get("name") and existing.get("name"):
            updated["name"] = existing["name"]
        if not updated.get("photo") and existing.get("photo"):
            updated["photo"] = existing["photo"]
        updated.setdefault("added_at", existing.get("added_at") or _now())
        token = str(updated.get("access_token") or "")
        if token:
            updated["token_hint"] = f"{token[:6]}...{len(token)} chars"
        store["accounts"][key] = updated
        if make_active:
            store["active"] = key
        _write_store(store)
        return dict(updated)


def set_active_account(user_id: Any) -> dict[str, Any]:
    with _STORE_LOCK:
        store = _read_store()
        key = _account_key(user_id)
        record = store["accounts"].get(key)
        if record is None:
            raise VkAuthError(f"account {user_id} is not signed in")
        store["active"] = key
        _write_store(store)
        return dict(record)


def remove_account(user_id: Any) -> dict[str, Any] | None:
    """Drop one account. When it was active, the next one takes over."""
    with _STORE_LOCK:
        store = _read_store()
        key = _account_key(user_id)
        store["accounts"].pop(key, None)
        if store.get("active") == key:
            store["active"] = next(iter(store["accounts"]), None)
        _write_store(store)
        active = store.get("active")
        record = store["accounts"].get(active) if active is not None else None
        return dict(record) if record else None


def load_record() -> dict[str, Any] | None:
    """The active account, under the name the daemon already used."""
    return active_record()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")
