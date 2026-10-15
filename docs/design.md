# omarchy-vk-music — design

A native VK Music player for the [Omarchy](https://omarchy.org/) bar, modelled
on [omarchy-yandex-music](https://github.com/vornashev/omarchy-yandex-music) but
built on its own code, its own API client, and a different set of constraints.

Status: research complete, facts verified against the live API on 2026-10-15.
Nothing here is a guess unless the line says "unverified".

## What was verified on the live API

| Question | Answer | Evidence |
| --- | --- | --- |
| Can a token be minted from the browser session? | Yes | `POST https://login.vk.ru/?act=web_token`, body `version=1&app_id=6287487`, cookies `p` + `remixsid`, origin/referer `https://vk.ru` → `{"type":"okay","data":{"access_token":"vk1.…","expires":…,"user_id":…,"logout_hash":…}}` |
| Are these the right cookies? | Yes, and they live on different hosts | `p` on `.login.vk.ru` (177 chars), `remixsid` on `.vk.ru` (88 chars). Wrong origin (`login.vk.com`) is refused with `wrong origin` |
| Does a token from the address bar work? | No | VK ID implicit flow token: every `audio.*` and `catalog.*` call answers error 3 `Unknown method passed`, on both hosts and all API versions tried (5.81, 5.131, 5.199). VK itself warns against copying the token from the address bar |
| Do the methods exist? | Yes, audio and catalog included | With a deliberately bogus token every method answers error 5 `authorization failed` — a missing method would answer error 3. Probed on `api.vk.com` 5.131 and `api.vk.ru` 5.282 |
| What shape does the modern API take? | `api.vk.ru/method/`, `v=5.282`, POST, auth in query, params in form body | Matches `@toil/vk-audio` (Sept 2026) and works live |
| Catalog | `catalog.getAudio` → sections `Главная`, `Моя музыка`, `Обзор`, `Радио`, `Обновления`; `catalog.getSection` → 36–100 tracks plus `next_from` for paging; blocks carry 8 playlists (`Для вас`, `Открытия`, `Новинки`, `Плейлист дня 1/2`) | Live calls, section ids are opaque strings and must be used verbatim |
| Search | `audio.search` (30 results, all HLS) and `audio.getSearchSuggestions` | Live calls |
| Legacy audio methods | `audio.get`, `audio.getById`, `audio.getPlaylists`, `audio.getLyrics` are reachable; `audio.getCount` is not (error 3) | `audio.get` returned the user's own 100 tracks; `audio.getPlaylists` returned an empty list, so playlists come from the catalog |
| Stream format | HLS `index.m3u8` on `vkuseraudio.ru`, per-segment `EXT-X-KEY` — `AES-128` for some segments, `METHOD=NONE` for others; the AES key is fetched over plain HTTP (16 bytes) | Live probe of the first bytes and the key URL |
| Does playback work? | Yes | `ffprobe`: `format=hls`, `codec=mp3`, 44100 Hz stereo, duration matches. `mpv` with the plugin's planned flags: exit code 0 |
| Lyrics | `audio.getLyrics` takes the composite `audio_id=<owner_id>_<audio_id>` and returns `{"lyrics":{"language":"en","text":[line,…]},"credits":"","md5":"…"}` | Live call. **No timestamps** — synchronized lyrics need LRCLIB |
| Token lifetime | The endpoint returned `expires` about 15 minutes ahead (875 s), not the 50 days the library README claims | One reading; needs a measured re-check. Refresh-before-call makes the number unimportant |

## Goals

- Play VK Music from the bar without a browser, the way the Yandex plugin does.
- Sound like a normal VK client on the wire — see *Stealth* below. This is a
  design requirement, not a nice-to-have: the audio API is undocumented and the
  account is the user's.
- Own code. The reference plugin's QML is 80 KB per screen; copying it would
  import years of decisions about a different service.

## Non-goals for v1

- No synchronized lyrics, no artist or album pages, no catalog browsing beyond
  the sections the API hands over.
- No playlist editing (`audio.add` / `audio.delete` exist but only for the
  user's own tracks).
- No global Hyprland keybindings: MPRIS covers the media keys.
- No publishing. The plugin stays a local checkout.

## v1 scope

Bar widget: artwork, title and artist, transport, with a popup holding the
queue. Track sources: **Моя музыка** (`catalog.getSection` on `section=all`),
**playlists** (read-only, from catalog blocks), **search** (`audio.search`).
Playback through `mpv` with a disk cache capped at 256 MiB. MPRIS for media
keys. Settings: cache limit, cache on/off, default source, bar contents.

## Architecture

```
                    ┌──────────────────────────── omarchy-shell (QML) ─────┐
                    │  BarWidget.qml  ── art, title, transport              │
                    │  Panel.qml      ── queue, sections, playlists, search │
                    │  SettingsPage.qml                                     │
                    └───────────────┬──────────────────────────────────────┘
                                    │  Quickshell Process → CLI (JSON on stdout)
                                    │  omarchy-shell IPC → popup toggle
┌───────────────────────────────────▼──────────────────────────────────────┐
│ omarchy-vk-music.service (Python, systemd --user)                        │
│   • JSON socket  $XDG_RUNTIME_DIR/omarchy-vk-music.sock                  │
│   • vk_api    – pacing, halting, catalog, search, legacy audio           │
│   • vk_auth   – web token from cookies, refresh, mobile fallback         │
│   • queue     – shuffle, repeat, restore last track and position         │
│   • mpv       – one process, `--idle=yes --input-ipc-server=…`           │
│   • cache     – 256 MiB LRU of finished tracks under $XDG_CACHE_HOME     │
│   • MPRIS     – org.mpris.MediaPlayer2 via dbus-next                     │
└──────────────────────────────────────────────────────────────────────────┘
```

The CLI is the contract between QML and the daemon: `omarchy-vk-music status`,
`… play section all`, `… search radiohead`, `… next`. The widget shells out and
parses JSON, exactly like the reference plugin and like the user's own
`omarchy-rgb`.

### Why a daemon and not QML-only

The API needs cookie handling, token refresh, HLS, a cache LRU, pacing and
halting. All of that is ordinary Python, and none of it belongs in a QML file
that also draws the bar.

## Authentication

Primary: **web token from the browser session.**

1. Read `p` and `remixsid` from the Firefox-family cookie database
   (`~/.config/mozilla/firefox/*/cookies.sqlite`, Zen, LibreWolf). The store is
   unencrypted; the write-ahead log must be copied together with the main file
   or recent cookies are invisible. Chromium-family stores are encrypted
   against the OS keyring and are not read.
2. Exchange them for a token with `POST login.vk.ru/?act=web_token`.
3. Store the token **and the cookies** in `~/.config/omarchy-vk-music/token.json`
   (mode 600): the refresh call needs the cookies again.
4. Refresh before a call when `expires - now < 600 s`.

Fallback: **mobile password grant** (`oauth.vk.com/token`, `grant_type=password`,
client 2274003 or 2685278). It is implemented but not the default: the token
lives about three hours, and VK's brute-force protection already answered one
of our attempts with "too many password login attempts … try again in a few
hours". It also needs the VK ID captcha (solved in the user's browser, returned
as `success_token`) and 2FA.

The password path never stores the password. Both paths store only what is
listed above.

## Stealth rules (enforced in code)

These exist because the user asked that we not be noticed; each one has a
counterpart in `backend/`.

1. **One identity.** User agent, `client_id` and `device_id` are fixed when the
   token is stored and reused for every call. No rotation.
2. **Pacing.** Every call goes through one limiter: at least 0.4 s apart plus
   0–0.25 s jitter. No parallel requests.
3. **Halting.** Errors 5 (token rejected), 9 (flood control) and 14 (captcha)
   raise `VkHaltError`, mark the client halted, and stop all traffic. The bar
   shows a warning. Nothing retries behind the user's back.
4. **One retry ceiling.** Error 6 (rate limited) gets a single backoff retry,
   because VK also emits it for an ordinary burst.
5. **No telemetry.** The reference plugin reports playback to the service
   provider; this one reports nothing anywhere.
6. **Refresh, don't log in.** The web token is refreshed from cookies; a fresh
   password login is never performed automatically.
7. **No scraping.** Only documented method calls. No HTML parsing.
8. **Requests look like the player.** Same cookies, same address, browser-like
   user agent, POST with a form body, auth in the query string — the shape the
   VK web player itself uses.

## Storage

| Path | Contents | Mode |
| --- | --- | --- |
| `~/.config/omarchy-vk-music/token.json` | token, cookies, user agent, client id, device id, expiry | 600 |
| `~/.config/omarchy-vk-music/state.json` | last track, position, queue, volume, preferences | 600 |
| `~/.config/omarchy-vk-music/lyrics/` | cached lyrics (later version) | 700 |
| `$XDG_CACHE_HOME/omarchy-vk-music/audio` | finished tracks, LRU, 256 MiB cap | 700 |

The token store holds a live session and must never be committed. Revoking it
means "завершить все сессии" in VK's security settings.

## Playback and cache

- One long-lived `mpv` with `--no-config --idle=yes --no-video
  --audio-display=no --force-window=no --input-ipc-server=…`, controlled over
  its JSON IPC. Verified working against a live stream.
- Stream URLs are short-lived and IP-bound, so they are resolved per playback
  and never persisted.
- Cache: when a track starts, `ffmpeg`/`mpv`-free download of the HLS playlist
  (AES-128 keys are fetched over plain HTTP) into a single file under the cache
  directory, then play the local file. Replays and seeks are then instant.
  LRU eviction keeps the directory under the cap.
- The cache is not an offline library: no UI promises offline playback in v1.

## Token refresh policy

Refresh when the token is within 600 s of `expires`, at most once per minute,
and only from the web path. With the observed ~15-minute lifetime this means a
refresh roughly every 14 minutes — the same rate as a browser tab playing
music. If the measured lifetime turns out to be longer, the rate drops
automatically.

## Risks and open questions

1. **Token lifetime.** One reading of 875 s. If a token dies mid-track, playback
   continues (the URL is already resolved) but the next API call refreshes.
   Measurement planned.
2. **Account risk.** The audio API is unofficial. A wrong-looking client can be
   throttled; errors 5/9/14 stop the plugin instead of retrying.
3. **Unplayable tracks.** VK returns an empty `url` for some tracks (rights,
   region, subscription). The UI must mark them instead of failing silently.
4. **`expires` semantics.** Whether the token is really rejected after
   `expires` is unverified; refresh-before-call makes it moot, but a test will
   confirm.
5. **Cookies expire.** `remixsid` is a session cookie with a long expiry; when
   it goes, re-authentication is needed and the UI must say so plainly.

## Roadmap

1. ~~**Skeleton** — manifest, widget that loads, daemon that answers `status`,
   `install.sh`, systemd unit, CLI.~~ done
2. ~~**Playback** — sections and queues, mpv control, MPRIS, restore state.~~ done
3. ~~**Cache** — HLS download, LRU, preload of the next track.~~ done: a track
   is fetched whole before it plays, the next one is fetched while the current
   one plays, and two downloads of the same file are deduplicated.
4. **Auth UI** — sign-in page for both paths, warning states from error 5/9/14.
   The web path works from the popup; the mobile path exists on the CLI only.
5. **Polish** — search-as-you-type, likes, settings page.
6. **Later** — lyrics via LRCLIB, radio sections, playlist editing.

## What is built and verified

| Piece | State |
| --- | --- |
| Web sign-in from browser cookies | works; the token refreshes itself from the stored cookies |
| Queue from **Моя музыка** (`section=all`), 100 tracks per page | works |
| Search and playlists (read-only) | works |
| Download-then-play through mpv | works; a cached track starts in about a second |
| MPRIS (`org.mpris.MediaPlayer2.omarchy_vk_music`) | works; `PlayPause` and `Next` were driven over the bus |
| Auto-advance on track end | works |
| Disk cache with a 256 MiB LRU cap | works |
| Prefetch of the next track | works: switching to a prefetched track starts in 0.4 s instead of 1–3 s |
| Pacing and halting | in place; no halt has been triggered in normal use |
| Bar widget and queue popup | loads clean in the shell; polling confirmed |

The queue and the position survive a restart, but playback does **not** resume
by itself at login: the bar shows the track that was playing, paused, and one
click continues it.

### Pitfalls found the hard way

* **`StdioCollector.text`, not the `Process`.** Reading `text` from a `Process`'s
  `onExited` yields `undefined`, because `text` belongs to the collector. Every
  command then looked like a failure while the service was working fine. Parse in
  the collector's own `onStreamFinished`, and keep `destroy()` in `onExited`.
* **Sizing a popup from `implicitHeight`.** That value only exists after a layout
  pass, so the card opened collapsed and grew a frame later. A fixed card with a
  `Flickable` list is boring and always correct.
* **A `MouseArea` declared after its siblings covers them.** The bar row's
  transport button never received a click until the interaction layer moved under
  the row.
* **`requests` puts the whole URL in its exception message**, and the URL carries
  `access_token`. Errors go through `safe_error_text()` before they are stored,
  logged or shown.
* **`dbus-next` rejects `-> None`** on `@method()`: with PEP 563 the annotation is
  the string `"None"`, which parses to a constant that is not a string.
* **A Python CLI is 15 ms, an `nc -U` write is 0.4 ms.** The widget runs one
  command per interaction step, so a drag paid Python's startup twenty times a
  second; `bin/omarchy-vk-music` is a shell script on a Unix socket now, with the
  Python client kept for the interactive login and as a fallback.
* **`PanelSlider` resets `liveValue` to `value` on release.** With `value` bound to
  a position that arrives once per poll, the knob jumped back to the stale position
  and forward again a second later. Seeking now holds the target locally and
  interpolates the position between polls; a drift of 15 ms in the backend was
  never the problem.
