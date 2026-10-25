"""Thin client for the VK audio API.

The VK audio API is undocumented. What is known, verified against the live
API and against `@toil/vk-audio` (September 2026):

* the web client talks to `https://api.vk.ru/method/` with version `5.282`;
* auth parameters travel in the query string, method parameters in a
  form-urlencoded POST body;
* the modern method set is catalog-first: `catalog.getAudio` returns the
  sections, `catalog.getSection` a section; `audio.search`, `audio.add`,
  `audio.delete` and `audio.getSearchSuggestions` cover the rest;
* the older `audio.*` methods still exist on both `api.vk.com` and
  `api.vk.ru`, and still return `url` per track — a bogus token answers
  "authorization failed" rather than "unknown method", which proves they
  are registered, not removed.

Two behaviours are policy, not convenience:

* **Pacing.** All calls share one jittered minimum interval, because VK
  throttles bursts with error 6 and error 9.
* **Halting.** A rejected token, a captcha demand, or flood control raises
  `VkHaltError` and marks the client halted, after which it refuses to touch
  the network at all.

Nothing here logs or formats the access token. Callers that need to show a
request for debugging must use `redact_url`.
"""

from __future__ import annotations

import json
import random
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Iterable, Mapping, Sequence
from urllib.parse import urlparse

import requests

API_BASE = "https://api.vk.ru/method/"
API_BASE_FALLBACK = "https://api.vk.com/method/"
API_VERSION = "5.282"

# The web client's application id. Its token is the long-lived one: it is
# minted from browser cookies and refreshed from the same cookies.
WEB_APP_ID = "6287487"
WEB_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:153.0) "
    "Gecko/20100101 Firefox/153.0"
)

# Mobile clients. Their tokens are short-lived (the API reports 10800 s for
# the app below), so they exist only as a fallback path.
VK_ANDROID_USER_AGENT = "VKAndroidApp/4.13.1-1206 (Android 4.4.3; SDK 19; armeabi; ; ru)"
KATE_USER_AGENT = (
    "KateMobileAndroid/56 lite-460 (Android 4.4.2; SDK 19; x86; "
    "unknown Android SDK built for x86; en)"
)

DEFAULT_TIMEOUT = 15.0
DEFAULT_MIN_INTERVAL = 0.4
DEFAULT_JITTER = 0.25

# VK error codes this plugin has to tell apart.
ERROR_AUTH_FAILED = 5
ERROR_TOO_MANY_REQUESTS = 6
ERROR_CAPTCHA = 14
ERROR_ACCESS_DENIED = 15
ERROR_AUDIO_ACCESS_DENIED = 200
ERROR_AUDIO_ACCESS_DENIED_ALT = 201

# Codes that mean "stop everything": a rejected token, a captcha demand, and
# flood control. Error 6 is not here because VK also emits it for an ordinary
# burst; it gets one backoff retry instead.
HALT_CODES = frozenset({ERROR_AUTH_FAILED, ERROR_CAPTCHA, 9})


def safe_error_text(exc: BaseException) -> str:
    """A failure description that can never contain the access token.

    `requests` puts the whole request URL into the exception message, and that
    URL carries `access_token` in its query string. Anything derived from an
    exception must go through here before it is stored, logged or shown in the
    bar.
    """
    reason = getattr(exc, "reason", None)
    if isinstance(exc, requests.HTTPError):
        response = getattr(exc, "response", None)
        status = getattr(response, "status_code", "?")
        target = redact_url(str(getattr(getattr(exc, "request", None), "url", "")))
        return f"HTTP {status} from {target or 'the API'}"
    if reason:
        return f"{type(exc).__name__}: {reason}"
    return type(exc).__name__


class VkApiError(RuntimeError):
    """A structured error returned by the VK API.

    `reason` is a code the panel can translate (`token_rejected`, `person_not_found`,
    …), and `params` carries what a template needs to finish the sentence. `message` is
    the sentence itself, for the CLI and the journal: nothing in the panel reads it, so
    rewording it can never break the interface.
    """

    def __init__(
        self,
        code: int,
        message: str,
        *,
        method: str = "",
        captcha_sid: str = "",
        captcha_img: str = "",
        details: Any = None,
        reason: str = "",
        params: Mapping[str, Any] | None = None,
    ) -> None:
        super().__init__(f"VK API error {code}: {message}")
        self.code = code
        self.message = message
        self.method = method
        self.captcha_sid = captcha_sid
        self.captcha_img = captcha_img
        self.details = details
        self.reason = reason
        self.params = dict(params or {})

    @property
    def needs_captcha(self) -> bool:
        return self.code == ERROR_CAPTCHA

    @property
    def token_rejected(self) -> bool:
        return self.code == ERROR_AUTH_FAILED

    @property
    def audio_denied(self) -> bool:
        """The account or the token has no access to the audio methods."""
        return self.code in (
            ERROR_ACCESS_DENIED,
            ERROR_AUDIO_ACCESS_DENIED,
            ERROR_AUDIO_ACCESS_DENIED_ALT,
        )


class VkHaltError(VkApiError):
    """A condition that must stop all VK traffic until the user acts."""

    def __init__(self, error: VkApiError) -> None:
        super().__init__(
            error.code,
            error.message,
            method=error.method,
            captcha_sid=error.captcha_sid,
            captcha_img=error.captcha_img,
            details=error.details,
            reason=error.reason,
            params=error.params,
        )


def classify(error: VkApiError) -> str:
    """A reason code for a failed call — never a sentence.

    The code is what the panel translates and what `describe` turns into a phrase for the
    journal and the CLI. Keeping the two apart is the point: a reworded sentence cannot
    change what the interface shows, and a new phrase needs no release of the panel.
    """
    if error.reason:
        return error.reason
    if error.audio_denied:
        return "no_audio_access"
    mapped = REASON_BY_CODE.get(error.code)
    if mapped:
        return mapped
    return "request_refused" if error.code == 0 else "vk_error"


# VK's own codes that the plugin has reason to name.
REASON_BY_CODE = {
    ERROR_AUTH_FAILED: "token_rejected",
    ERROR_CAPTCHA: "captcha",
    9: "flood_control",
    ERROR_TOO_MANY_REQUESTS: "rate_limited",
    3: "method_unavailable",
}

# The sentence each reason stands for, in the one place a human reads it: the journal and
# the command line. The panel never sees these; it translates the codes itself.
DESCRIPTIONS = {
    "token_rejected": "token rejected",
    "captcha": "captcha required",
    "flood_control": "flood control",
    "rate_limited": "rate limited",
    "method_unavailable": "method unavailable for this token's app",
    "no_audio_access": "no audio access for this account or token",
    "request_refused": "the request was refused",
    "vk_error": "vk error",
    "not_signed_in": "not signed in",
    "person_not_found": "person not found",
    "no_stream_link": "no stream link",
    "empty_link": "empty link",
    "unknown_section": "unknown section",
    "unknown_station": "unknown radio station",
    "no_keys": "no track keys given",
    "nothing_for_keys": "VK returned nothing for those keys",
    "track_key_required": "track key is required",
}


def describe(reason: str) -> str:
    """The phrase the CLI and the journal print for a reason code."""
    return DESCRIPTIONS.get(reason, f"vk error: {reason}")


@dataclass(frozen=True)
class Track:
    """A normalised audio record, covering both legacy and catalog payloads.

    `key` is the "owner_id_id" pair VK uses for `audio.getById`, restoring
    playlists, and liking.
    """

    key: str
    owner_id: int
    audio_id: int
    title: str
    artist: str
    duration: int
    url: str = ""
    lyrics_id: int | None = None
    access_key: str = ""
    album_id: int | None = None
    genre_id: int | None = None
    date: int | None = None
    subtitle: str = ""
    # What the player shows under the artist: VK sends the record as `album.title`
    # in the newer payloads and as a free-form `subtitle` in the old ones.
    album: str = ""
    thumb: str = ""
    has_lyrics: bool = False
    is_liked: bool = False
    is_explicit: bool = False
    artists: tuple[Mapping[str, Any], ...] = ()
    raw: Mapping[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_item(cls, item: Mapping[str, Any]) -> "Track":
        owner_id = int(item.get("owner_id", 0))
        audio_id = int(item.get("id", 0))
        main_artists = item.get("main_artists")
        return cls(
            key=f"{owner_id}_{audio_id}",
            owner_id=owner_id,
            audio_id=audio_id,
            title=str(item.get("title", "")),
            artist=str(item.get("artist", "")),
            duration=int(item.get("duration", 0) or 0),
            url=str(item.get("url") or ""),
            lyrics_id=_optional_int(item.get("lyrics_id")),
            access_key=str(item.get("access_key") or ""),
            album_id=_optional_int(item.get("album_id")),
            genre_id=_optional_int(item.get("genre_id")),
            date=_optional_int(item.get("date")),
            subtitle=str(item.get("subtitle") or ""),
            album=_extract_album(item),
            thumb=_extract_thumb(item),
            has_lyrics=bool(item.get("has_lyrics")) or bool(item.get("lyrics_id")),
            is_liked=bool(item.get("like")),
            is_explicit=bool(item.get("is_explicit")),
            artists=tuple(a for a in (main_artists or ()) if isinstance(a, Mapping)),
            raw=item,
        )

    @property
    def stream_kind(self) -> str:
        """`hls` when VK sends an HLS playlist, else `file`."""
        if not self.url:
            return "none"
        return "hls" if ".m3u8" in urlparse(self.url).path else "file"

    @property
    def label(self) -> str:
        return f"{self.artist} — {self.title}" if self.artist else self.title

    def to_dict(self) -> dict[str, Any]:
        """Everything except the raw payload and the stream URL."""
        return {
            "key": self.key,
            "title": self.title,
            "artist": self.artist,
            "duration": self.duration,
            "has_url": bool(self.url),
            "stream_kind": self.stream_kind,
            "has_lyrics": self.has_lyrics,
            "is_liked": self.is_liked,
            "has_thumb": bool(self.thumb),
            "subtitle": self.subtitle,
            "album": self.album,
        }


@dataclass(frozen=True)
class Playlist:
    key: str
    owner_id: int
    playlist_id: int
    title: str
    count: int
    access_key: str = ""
    description: str = ""
    # The gallery needs a cover, and the card is worth two numbers: how long the
    # playlist is (count) and how many people listen to it.
    cover: str = ""
    # A gallery wants a big cover and a row wants a small one, and VK keeps both:
    # asking for the big one thirty times is a slow list for no reason.
    cover_small: str = ""
    plays: int = 0
    followers: int = 0
    main_color: str = ""
    raw: Mapping[str, Any] = field(default_factory=dict, repr=False)

    @classmethod
    def from_item(cls, item: Mapping[str, Any]) -> "Playlist":
        owner_id = int(item.get("owner_id", 0))
        playlist_id = int(item.get("id", 0) or item.get("playlist_id", 0))
        return cls(
            key=f"{owner_id}_{playlist_id}",
            owner_id=owner_id,
            playlist_id=playlist_id,
            title=str(item.get("title", "")),
            count=int(item.get("count", 0) or 0),
            access_key=str(item.get("access_key") or ""),
            description=str(item.get("description") or ""),
            cover=_extract_cover(item),
            cover_small=_extract_cover(item, small=True),
            plays=int(item.get("plays", 0) or 0),
            followers=int(item.get("followers", 0) or 0),
            main_color=str(item.get("main_color") or ""),
            raw=item,
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "owner_id": self.owner_id,
            "playlist_id": self.playlist_id,
            "title": self.title,
            "count": self.count,
            "cover": self.cover,
            "cover_small": self.cover_small,
            "plays": self.plays,
            "followers": self.followers,
            # The widget plays a playlist by handing this back, so it has to travel.
            "access_key": self.access_key,
            "has_access_key": bool(self.access_key),
        }


@dataclass(frozen=True)
class Person:
    """A VK user, as far as the plugin cares: id, name, small photo.

    Friends arrive from `friends.get` and anyone else from `users.get` after their
    link or screen name has been resolved, so one shape serves both lists.
    """

    id: int
    name: str
    photo: str = ""
    screen_name: str = ""

    @classmethod
    def from_item(cls, item: Mapping[str, Any]) -> "Person":
        first = str(item.get("first_name", ""))
        last = str(item.get("last_name", ""))
        return cls(
            id=int(item.get("id", 0) or 0),
            name=(first + " " + last).strip() or str(item.get("screen_name") or item.get("id")),
            photo=_person_photo(item),
            screen_name=str(item.get("screen_name") or ""),
        )

    def to_dict(self) -> dict[str, Any]:
        return {"id": self.id, "name": self.name, "photo": self.photo}


@dataclass(frozen=True)
class Section:
    """A catalog section, as returned by `catalog.getAudio`."""

    id: str
    title: str
    url: str

    @classmethod
    def from_item(cls, item: Mapping[str, Any]) -> "Section":
        return cls(
            id=str(item.get("id", "")),
            title=str(item.get("title", "")),
            url=str(item.get("url", "")),
        )


@dataclass(frozen=True)
class RadioStation:
    """A live radio stream.

    Radio is not a queue of tracks: VK returns the stations with a plain
    `stream_url` to hand to the player, and nothing about them is resolved
    through the audio API afterwards.
    """

    id: int
    name: str
    logo_url: str
    stream_url: str
    is_enabled: bool = True

    @classmethod
    def from_item(cls, item: Mapping[str, Any]) -> "RadioStation":
        return cls(
            id=int(item.get("id", 0) or 0),
            name=str(item.get("name", "")),
            logo_url=str(item.get("logo_url", "") or item.get("logo_png_url", "")),
            stream_url=str(item.get("stream_url", "")),
            is_enabled=bool(item.get("is_enabled", True)),
        )


@dataclass(frozen=True)
class SectionBlocks:
    """A flattened `catalog.getSection` answer."""

    id: str
    title: str
    next_offset: str
    url: str
    audios: tuple[Track, ...]
    playlists: tuple[Playlist, ...]

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.id,
            "title": self.title,
            "has_next": bool(self.next_offset),
            "audios": len(self.audios),
            "playlists": len(self.playlists),
        }


def _optional_int(value: Any) -> int | None:
    if value is None or value == "":
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _extract_album(item: Mapping[str, Any]) -> str:
    """The record a track belongs to, as the player's third line wants it.

    `album.title` is there in catalog payloads and `subtitle` carries the record in
    the legacy `audio.get` ones; either is better than an empty line, and an empty
    string lets the caller fall back to something else it knows.
    """
    album = item.get("album")
    if isinstance(album, Mapping):
        title = str(album.get("title") or "").strip()
        if title:
            return title
    return str(item.get("subtitle") or "").strip()


def _extract_thumb(item: Mapping[str, Any]) -> str:
    """Cover art lives in `thumb` in catalog payloads and `album.thumb` in legacy ones."""
    for candidate in (item.get("thumb"), (item.get("album") or {}).get("thumb") if isinstance(item.get("album"), Mapping) else None):
        if not isinstance(candidate, Mapping):
            continue
        for size in ("photo_1200", "photo_600", "photo_300", "photo_270", "photo_68"):
            value = candidate.get(size)
            if value:
                return str(value)
    return ""


def _person_photo(item: Mapping[str, Any]) -> str:
    """A user's picture: unlike a playlist's, the sizes sit on the item itself."""
    for size in ("photo_200", "photo_100", "photo_max", "photo_50"):
        value = item.get(size)
        if value:
            return str(value)
    return ""


def _extract_cover(item: Mapping[str, Any], *, small: bool = False) -> str:
    """A playlist's cover.

    Playlists arrive in two shapes: `photo` for anything from `audio.*`, and
    `thumb` for the catalog's own blocks. Both carry the same size keys, which is
    why one helper reads them. `small` asks for the thumbnail a list row needs.
    """
    sizes = (
        ("photo_68", "photo_135", "photo_270", "photo_300", "photo_600", "photo_1200")
        if small
        else ("photo_600", "photo_300", "photo_270", "photo_1200", "photo_135", "photo_68")
    )
    for candidate in (item.get("photo"), item.get("thumb")):
        if not isinstance(candidate, Mapping):
            continue
        for size in sizes:
            value = candidate.get(size)
            if value:
                return str(value)
    return ""


def redact_url(url: str, *, keep_query: bool = False) -> str:
    """Strip credentials and query strings so a URL is safe to log."""
    if not url:
        return ""
    parsed = urlparse(url)
    if keep_query:
        return f"{parsed.scheme}://{parsed.netloc}{parsed.path}?<query>"
    return f"{parsed.scheme}://{parsed.netloc}{parsed.path}"


class VkClient:
    """Minimal synchronous VK API client.

    One instance is bound to one token, one user agent, one client id and one
    device id. A token issued to a different client will not authenticate, so
    these travel together.
    """

    def __init__(
        self,
        token: str,
        *,
        user_agent: str = WEB_USER_AGENT,
        version: str = API_VERSION,
        client_id: str = WEB_APP_ID,
        api_base: str = API_BASE,
        session: requests.Session | None = None,
        timeout: float = DEFAULT_TIMEOUT,
        min_interval: float = DEFAULT_MIN_INTERVAL,
        jitter: float = DEFAULT_JITTER,
        device_id: str | None = None,
        http: str = "post",
    ) -> None:
        if not token:
            raise ValueError("VK token is empty")
        self._token = token
        self.user_agent = user_agent
        self.version = version
        self.client_id = client_id
        self.api_base = api_base
        self.http = http
        self.timeout = timeout
        self.device_id = device_id
        self.session = session or requests.Session()
        self._sections_cache: tuple[float, list[Section]] | None = None
        self.session.headers.update({"User-Agent": user_agent})
        self._min_interval = max(min_interval, 0.0)
        self._jitter = max(jitter, 0.0)
        self._last_call = 0.0
        self._lock = threading.Lock()
        self.halted_reason = ""

    # -- pacing and halting ------------------------------------------------

    @property
    def halted(self) -> bool:
        return bool(self.halted_reason)

    def halt(self, reason: str) -> str:
        """Stop all traffic. Idempotent; the first reason wins."""
        with self._lock:
            if not self.halted_reason:
                self.halted_reason = reason
            return self.halted_reason

    def resume(self) -> None:
        """Allow traffic again, after the user has fixed the cause."""
        with self._lock:
            self.halted_reason = ""
            self._last_call = 0.0

    def _pace(self) -> None:
        with self._lock:
            wait = self._min_interval - (time.monotonic() - self._last_call)
            if wait > 0:
                time.sleep(wait + random.uniform(0, self._jitter))
            self._last_call = time.monotonic()

    # -- transport ---------------------------------------------------------

    def call(
        self,
        method: str,
        *,
        http: str | None = None,
        api_base: str | None = None,
        **params: Any,
    ) -> Any:
        """Call one API method and return its `response` payload.

        Auth parameters go in the query string, method parameters in the
        body: that is how the VK web client itself speaks.
        """
        if self.halted:
            raise VkHaltError(VkApiError(0, f"halted: {self.halted_reason}", method=method))
        try:
            return self._call_once(method, http=http, api_base=api_base, **params)
        except VkHaltError:
            raise
        except VkApiError as exc:
            if exc.code != ERROR_TOO_MANY_REQUESTS:
                raise
            time.sleep(1.5 + random.uniform(0, 0.5))
            return self._call_once(method, http=http, api_base=api_base, **params)

    def _call_once(
        self,
        method: str,
        *,
        http: str | None = None,
        api_base: str | None = None,
        **params: Any,
    ) -> Any:
        self._pace()
        query = {
            "v": self.version,
            "access_token": self._token,
            "lang": "ru",
            "client_id": self.client_id,
        }
        if self.device_id:
            query["device_id"] = self.device_id
        body = {key: value for key, value in params.items() if value is not None}
        url = (api_base or self.api_base) + method
        verb = (http or self.http).lower()
        try:
            if verb == "get":
                response = self.session.get(
                    url, params={**query, **body}, timeout=self.timeout
                )
            else:
                response = self.session.post(
                    url, params=query, data=body, timeout=self.timeout
                )
            response.raise_for_status()
            payload = response.json()
        except requests.RequestException as exc:
            raise VkApiError(0, safe_error_text(exc), method=method) from exc
        except json.JSONDecodeError as exc:
            raise VkApiError(0, "response is not JSON", method=method) from exc

        if "response" in payload:
            return payload["response"]
        error = payload.get("error")
        if not isinstance(error, Mapping):
            raise VkApiError(0, f"unexpected payload: {sorted(payload)}", method=method)
        wrapped = VkApiError(
            int(error.get("error_code", 0)),
            str(error.get("error_msg", "unknown error")),
            method=method,
            captcha_sid=str(error.get("captcha_sid", "")),
            captcha_img=str(error.get("captcha_img", "")),
            details=error,
        )
        if wrapped.code in HALT_CODES:
            raise VkHaltError(wrapped)
        raise wrapped

    # -- account -----------------------------------------------------------

    def me(self) -> Mapping[str, Any]:
        """The user the token belongs to."""
        response = self.call("users.get", fields="uid")
        if not isinstance(response, list) or not response:
            raise VkApiError(0, "users.get returned no user", method="users.get")
        return response[0]

    def profile(self) -> Mapping[str, Any]:
        return self.call("account.getProfileInfo")

    # -- catalog -----------------------------------------------------------

    # The five sections are the same list for minutes, and every friendly-slug
    # lookup asks for them: without this, opening the popup cost one request per
    # lookup on top of the section being opened, and they queue behind the
    # pacing, which is a second or two of waiting for nothing.
    SECTIONS_TTL = 300.0

    def sections(self, *, owner_id: int | None = None, need_blocks: bool = False) -> list[Section]:
        """`catalog.getAudio`: the section list, without blocks."""
        cacheable = owner_id is None and not need_blocks
        if cacheable:
            cached = self._sections_cache
            if cached is not None and time.monotonic() < cached[0]:
                return list(cached[1])
        response = self.call(
            "catalog.getAudio",
            owner_id=owner_id,
            need_blocks=1 if need_blocks else None,
        )
        catalog = response.get("catalog") if isinstance(response, Mapping) else None
        if isinstance(catalog, Mapping):
            result = [Section.from_item(item) for item in catalog.get("sections") or []]
            if cacheable:
                self._sections_cache = (time.monotonic() + self.SECTIONS_TTL, result)
            return result
        return []

    def catalog_home(
        self, *, owner_id: int | None = None
    ) -> tuple[list[Section], list[Track], list[Playlist], str]:
        """`catalog.getAudio` with `need_blocks=1`: sections, recent tracks, playlists."""
        response = self.call("catalog.getAudio", owner_id=owner_id, need_blocks=1)
        if not isinstance(response, Mapping):
            return [], [], [], ""
        catalog = response.get("catalog") or {}
        sections = [Section.from_item(item) for item in catalog.get("sections") or []]
        audios = [
            Track.from_item(item)
            for item in response.get("audios") or []
            if isinstance(item, Mapping)
        ]
        playlists = [
            Playlist.from_item(item)
            for item in response.get("playlists") or []
            if isinstance(item, Mapping)
        ]
        return sections, audios, playlists, str(catalog.get("default_section", ""))

    def radio_stations(self) -> list[RadioStation]:
        """`catalog.getAudio` on the radio section: live stations, not tracks.

        They arrive next to the catalog rather than inside it (`radio_stations`
        at the top level), which is why the station list is read separately
        instead of from the section blocks.
        """
        station_section = next(
            (section for section in self.sections() if "section=radiostations" in section.url),
            None,
        )
        if station_section is None:
            return []
        response = self.call("catalog.getAudio", url=station_section.url, need_blocks=1)
        if not isinstance(response, Mapping):
            return []
        return [
            RadioStation.from_item(item)
            for item in response.get("radio_stations") or []
            if isinstance(item, Mapping)
        ]

    def section(self, section_id: str, *, start_from: str | None = None) -> SectionBlocks:
        """`catalog.getSection`: one section, flattened into tracks."""
        response = self.call(
            "catalog.getSection", section_id=section_id, start_from=start_from
        )
        if not isinstance(response, Mapping):
            return SectionBlocks(section_id, "", "", "", (), ())
        section = response.get("section") or {}
        audios = [
            Track.from_item(item)
            for item in response.get("audios") or []
            if isinstance(item, Mapping)
        ]
        playlists = [
            Playlist.from_item(item)
            for item in response.get("playlists") or []
            if isinstance(item, Mapping)
        ]
        return SectionBlocks(
            id=str(section.get("id", section_id)),
            title=str(section.get("title", "")),
            next_offset=str(section.get("next_from", "")),
            url=str(section.get("url", "")),
            audios=tuple(audios),
            playlists=tuple(playlists),
        )

    def search(self, query: str, *, offset: int | None = None) -> list[Track]:
        response = self.call("audio.search", q=query, offset=offset)
        return _tracks_from(response)

    def search_suggestions(self, query: str) -> list[str]:
        response = self.call("audio.getSearchSuggestions", query=query)
        if isinstance(response, Mapping):
            return [str(item) for item in response.get("suggestions") or []]
        return []

    def add(self, owner_id: int, audio_id: int) -> list[Mapping[str, Any]]:
        """`audio.add`: like a track into the user's own audio."""
        response = self.call("audio.add", owner_id=owner_id, audio_id=audio_id)
        if isinstance(response, Mapping):
            return list(response.get("items") or [])
        return []

    def delete(self, owner_id: int, audio_id: int) -> list[str]:
        """`audio.delete`: remove a track from the user's own audio."""
        response = self.call("audio.delete", owner_id=owner_id, audio_id=audio_id)
        if isinstance(response, Mapping):
            return [str(item) for item in response.get("audio_ids") or []]
        return []

    # -- legacy audio methods (still registered, used as a fallback) --------

    def audio_count(self, owner_id: int) -> int:
        response = self.call("audio.getCount", owner_id=owner_id)
        if isinstance(response, Mapping):
            return int(response.get("count", 0) or 0)
        return int(response or 0)

    def audio_get(
        self,
        owner_id: int,
        *,
        count: int = 100,
        offset: int = 0,
        album_id: int | None = None,
        access_key: str | None = None,
    ) -> list[Track]:
        response = self.call(
            "audio.get",
            owner_id=owner_id,
            count=count,
            offset=offset,
            album_id=album_id,
            access_key=access_key,
            extended=1,
        )
        return _tracks_from(response)

    def audio_get_by_keys(self, keys: Sequence[str]) -> list[Track]:
        if not keys:
            return []
        response = self.call("audio.getById", audios=",".join(keys))
        return _tracks_from(response)

    def audio_playlists(self, owner_id: int, *, count: int = 50, offset: int = 0) -> list[Playlist]:
        response = self.call(
            "audio.getPlaylists", owner_id=owner_id, count=count, offset=offset
        )
        return _playlists_from(response)

    def search_playlists(
        self, query: str, *, count: int = 30, offset: int = 0
    ) -> tuple[list[Playlist], int]:
        """Search other people's playlists by name.

        Verified live: `audio.searchPlaylists` answers with `count` and `items`,
        and each item carries its cover, its length, its listener count and the
        `access_key` that makes it playable without owning it.
        """
        response = self.call(
            "audio.searchPlaylists", q=query, count=count, offset=offset
        )
        total = 0
        if isinstance(response, Mapping):
            try:
                total = int(response.get("count", 0) or 0)
            except (TypeError, ValueError):
                total = 0
        return _playlists_from(response), total

    def friends(self, *, count: int = 200) -> list[Person]:
        """Everyone on my friend list, by name."""
        response = self.call("friends.get", count=count, order="name", fields="photo_200")
        items = response.get("items") if isinstance(response, Mapping) else None
        return [Person.from_item(item) for item in (items or []) if isinstance(item, Mapping)]

    def users(self, ids: str) -> list[Person]:
        """Resolve ids or screen names into people, for a pasted link."""
        response = self.call("users.get", user_ids=ids, fields="photo_200")
        items = response if isinstance(response, list) else []
        return [Person.from_item(item) for item in items if isinstance(item, Mapping)]

    def audio_playlist_tracks(
        self, owner_id: int, playlist_id: int, *, access_key: str = "", count: int = 300
    ) -> list[Track]:
        # 300 rather than 100: playlists of three hundred tracks are ordinary, and
        # one call answers them.
        return self.audio_get(
            owner_id,
            count=count,
            album_id=playlist_id,
            access_key=access_key or None,
        )

    def audio_lyrics(self, track: Track) -> dict[str, Any]:
        """Lyrics for a track, as VK serves them.

        Verified against the live API: the parameter is the composite
        `audio_id=<owner_id>_<audio_id>`, and the answer is
        `{"lyrics": {"language": "en", "text": [line, ...]}, "credits": str,
        "md5": str}`. VK has **no timed lyrics**, so a synchronized view
        needs a second source (LRCLIB in the reference plugin's approach).
        """
        response = self.call("audio.getLyrics", audio_id=track.key)
        if not isinstance(response, Mapping):
            return {"language": "", "text": [], "credits": ""}
        lyrics = response.get("lyrics")
        lines: list[str] = []
        language = ""
        if isinstance(lyrics, Mapping):
            language = str(lyrics.get("language", ""))
            text = lyrics.get("text")
            if isinstance(text, list):
                lines = [str(line) for line in text]
        elif isinstance(lyrics, str):
            lines = lyrics.splitlines()
        return {
            "language": language,
            "text": lines,
            "credits": str(response.get("credits") or ""),
            "md5": str(response.get("md5") or ""),
        }


def _tracks_from(response: Any) -> list[Track]:
    items = _items_of(response)
    return [Track.from_item(item) for item in items if isinstance(item, Mapping)]


def _playlists_from(response: Any) -> list[Playlist]:
    items = _items_of(response)
    return [Playlist.from_item(item) for item in items if isinstance(item, Mapping)]


def _items_of(response: Any) -> list[Any]:
    if isinstance(response, Mapping):
        items = response.get("items")
        return list(items) if isinstance(items, list) else []
    if isinstance(response, list):
        return response
    return []


def iter_pages_available(total: int, page_size: int) -> Iterable[tuple[int, int]]:
    """Yield `(offset, count)` pairs covering `total` items."""
    offset = 0
    while offset < total:
        count = min(page_size, total - offset)
        yield offset, count
        offset += count
