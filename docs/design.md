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
3. Store the token **and the cookies** in
   `~/.config/omarchy-vk-music/accounts.json` (mode 600), keyed by VK's user
   id: the refresh call needs the cookies again.
4. Refresh before a call when `expires - now < 600 s`.

Fallback: **mobile password grant** (`oauth.vk.com/token`, `grant_type=password`,
client 2274003 or 2685278). It is implemented but not the default: the token
lives about three hours, and VK's brute-force protection already answered one
of our attempts with "too many password login attempts … try again in a few
hours". It also needs the VK ID captcha (solved in the user's browser, returned
as `success_token`) and 2FA.

The password path never stores the password. Both paths store only what is
listed above.

### Several accounts

One file holds every account, keyed by its user id, plus an `active` marker. The
single-account `token.json` of earlier versions is read once, folded into the
store and removed; an existing installation keeps its session.

The reason the store exists is a browser fact: cookies describe the one session
the browser is signed into, so the browser path can only ever add that account.
A second account is added with the password grant instead, which is why that
path is part of the panel and not only of the CLI. The password travels over a
`request` command's stdin, never as an argument, and is dropped from the daemon
as soon as the token arrives.

Reading the browser cookies is also a choice of profile: a machine keeps
several Firefox-family profiles, and more than one can hold a complete
`p`/`remixsid` pair. Taking the first profile that has them signed the panel
into an old account while the window in front of the user was signed into
another, and the click looked dead because the account it added was already
active. The freshest pair wins now — `lastAccessed` moves whenever a browser
uses a cookie — and the form reports which account was added.

Each account owns its queue, position, liked copies, search history and recent
people; those live under `state.json`'s `accounts` map. Preferences and volume
stay at the top level, because they describe the panel and the speakers rather
than a VK account. Switching saves the outgoing slice, stops playback, adopts
the new token, restores that account's queue paused at its own position and
publishes it to MPRIS. The stream URL is deliberately not reused: it was
resolved for the old session. Removing the active account hands the session to
the next stored one; removing the last one leaves the panel signed out.

The panel owns its own copy of everything the account answered, and a switch has
to empty it: a section page, the queue, the people, the sections themselves. The
sections are the delicate one, because the bar draws them as its chips and their
ids belong to the account that answered. Clearing them and waiting for the retry
under `sectionsWatch` left the bar with nothing in it but «Люди» for up to five
seconds, which reads as the menu having vanished, and a page that had already
spent its three re-asks stayed «пусто» for the rest of the session because that
counter survived the switch. `reloadAfterAccountChange` resets the counter and
asks for the sections, the friend list and — when the browse tab is the one on
screen — the section page itself, in the same turn as the switch. A person's
page or an opened playlist cannot be asked for on behalf of another account and
steps back to «Люди»; a section page that was off screen is asked for when the
tab is opened, which is where the empty-page re-ask now also happens.

User names and portraits come from one `users.get` call right after sign-in and
are stored beside the token, so the account list is readable without asking VK
on every open.

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
| `~/.config/omarchy-vk-music/accounts.json` | every account: token, cookies, user agent, client id, device id, expiry, name and portrait; plus the active id | 600 |
| `~/.config/omarchy-vk-music/state.json` | shared preferences and volume, and one queue/position/likes/history slice per account | 600 |
| `~/.config/omarchy-vk-music/lyrics/` | cached lyrics (later version) | 700 |
| `$XDG_CACHE_HOME/omarchy-vk-music/audio` | finished tracks, LRU, 256 MiB cap | 700 |

The account store holds live sessions and must never be committed. Revoking one
means «завершить все сессии» for that account in VK's security settings.

## Buffering, as the interface shows it

A track is fetched whole before it plays, which takes one to three seconds, so the
wait needs an honest indicator rather than a spinner. ffmpeg is asked for
`-progress pipe:1`, and the `out_time_us=` lines are the position inside the
*audio*: against the track's known duration that is an exact percentage. Measured
on a 235 s track: 0 → 12 → 29 → 43 → 65 → 87 → ready in 3.05 s.

The indicator is the cover's own border, filling clockwise from the middle of
the top edge: 2 px in the bar, 3 px in the popup. Not a ring — a ring ignores the
shape the cover already has. The whole frame is drawn faintly first and the
loaded part on top, so the outline that is left reads as "how much is still
missing". Nothing shifts, no second element appears in a 30 px row, and the
artwork stays recognisable while the frame fills. In the popup the cover also
dims and the percentage takes its centre; in the bar the frame alone says it.
When the length is unknown (the cache is off and the stream is not being
downloaded) a short piece travels around the frame instead of a made-up
progress.

The frame walks a rounded rectangle as an ordered ring of straight edges and
arcs, and two checks guard it:

* `tools/frame_geometry.py` — the arithmetic: perimeter against the
  rounded-rectangle formula, the walk starting and closing at the top edge,
  coverage growing with progress, and a clamped radius.
* `tests/qml/tst_progress_frame.qml` plus `tools/check_frame_render.py` — the
  pixels. The QML test renders the frame at a quarter, a half and the whole
  perimeter (offscreen, `QT_QPA_PLATFORM=offscreen`), and the script walks the
  same outline in a rendered image to measure how much of it came out filled:
  25.9 %, 51.2 % and 100 %. The arithmetic check cannot see the failure this
  finds — the fill length was a *share* clamped with `Math.max(1, …)`, which
  means "the whole frame" — because the walk was right and the number handed to
  it was wrong.

Deliberate choices around it:

* The play/pause glyph never turns into a downloader; it stays play/pause and
  dims while the track is fetched.
* The seek slider is disabled while buffering: a seek would move the track that
  is still playing, not the one being fetched.
* Buffering is polled four times a second so the frame grows in more than three
  steps; a status call costs 2–4 ms over the socket, and the queue (a hundred
  tracks of JSON) is only reloaded when the track actually changes. The fast
  interval is armed by the widget's own commands and by any observed track
  change, so a jump from a media key is not missed either.
* A running download never reports 100 %: ffmpeg reaches the end of the audio
  well before it finishes writing the file, and a frame that sits visibly full
  for the last stretch of every track reads as a stuck indicator. 100 % belongs
  to the moment the file is in place, when the frame disappears anyway.
* The percentage in the popup sits on the theme's own panel colour at 82 %
  opacity with the panel foreground over it, rather than on black with white
  text: over album art a fixed pair is unreadable on some covers, while the
  theme's background and foreground contrast by construction, dark theme or
  light.

## Search, as the interface shows it

The field searches as you type, in two stages, because the two calls cost very
different amounts:

* 250 ms after the last keystroke, `audio.getSearchSuggestions` — the same call
  VK's own player makes while typing, so asking for it is unremarkable. Its
  answers fill the list under the field under the heading **Подсказки**, and each
  one is a ready-made query: tapping it searches for that string.
* 700 ms after the last keystroke, `audio.search`, whose results replace the
  suggestions under the heading **Найдено N**. `Enter` asks for them at once
  instead of waiting.

Every keystroke restarts both timers, so a typed query costs a handful of calls
and never a burst; asking for the same query twice is skipped, and a slow reply
for an older query is dropped rather than painted over newer results (a sequence
number per search). Nothing is searched below two characters.

When a search finds nothing the suggestions come back under **Ничего не найдено.
Похожее:** — they are the useful thing left on screen.

Tapping a result queues *those* results: the widget sends the list it is showing
(`play tracks` with the rows themselves, `--index N` for the row that was tapped)
rather than the query, so the queue is exactly the list the user was looking at
rather than whatever the same query returns a few seconds later, and no second
answer is asked for at all.

## Starting a track, and where its time goes

One line goes to the journal per track start:

```
track start: resolve 0.10 s, download 2.88 s, total 2.93 s
```

It exists because "playback takes a few seconds" is otherwise unanswerable: a
click from the widget costs an `audio.getById` for the list, a URL resolution,
the download itself and mpv's load, and only the split says which one is to
blame. In practice the download dominates, and now that starting a track clears
mpv's pause, the sound follows the download by about 0.2 s.

The bar's control glyph is drawn to the recipe the reference music widget uses for its
own bar buttons, because two music widgets sitting in the same bar should not look like
two different applications: a 24 px wide, full-height target with a 14 px icon,
transparent at rest, a fill of the foreground at 8 % under the pointer, an accent fill
with an accent icon while pressed, 35 % opacity when disabled, and the tooltip through
the bar's own tooltip. Nothing else is drawn — no frame, no background, no border.

The bar's transport is three plain glyphs — previous, play or pause, next — each in
its own 22-24 px target, with no frame around any of them. The bar is not a panel: a box
around a glyph is one more thing to read at a size where every pixel competes with the
clock. The glyph size is the bar's own icon token rather than a panel font, so the row
cannot grow taller than the bar, and the middle glyph still never turns into a download
icon — it dims while the track is being fetched.

The heart is not a transport control — it is a statement about the track — so it sits
at the right end of the band, after the volume. It is Lucide's `heart`: an outline while
the track is not in «Моя музыка», filled (and accent-coloured) once it is. «Моя музыка»
and the favourites are one list on VK, so the glyph is the same one the bar shows.

The transport glyphs are FILLED — the reference sets `filled: true` on all three of its
transport buttons, which is what turns Lucide's polygons into solid shapes. Its heart is
the exception: filled only while the track is in the favourites, outlined otherwise.

The glyphs themselves are Lucide's own paths, vendored in `LucideIcons.js` (ISC licence,
v0.468.0, the same set the reference widget uses) and drawn as an SVG data URL with a
2 px round stroke and no fill — except the heart, which is filled when the track is in
«Моя музыка». The reference names its icons, so ours are asked for by the same names:
`skip-back`, `play`, `pause`, `skip-forward`, `heart`. The icon font stays as a fallback
for a name the set does not carry.


The MPRIS track id is built from VK's track key, and a key starts with a minus sign for
anything a community owns. A D-Bus object path segment allows letters, digits and
underscores only, so one minus made every publish raise `SignatureBodyMismatchError` — the
whole interface failed at export, and clients that ask a player to pause itself, a
dictation tool among them, waited on a name that answered nothing. The key is sanitised
before it becomes a path.

The cover in the BAR is twenty pixels, and that is why its frame looked wrong: a
four-pixel corner is a fifth of a twenty-pixel picture, so the frame's rounding and the
picture's square corners read as two shapes fighting. Its rounding is proportional now —
two pixels, with the picture one pixel in — and `coverShape: circle` still means a circle.

Three rounds were spent on the wrong element: «топ-бар» is the system bar, and the cover
there is the twenty-pixel artwork in the bar row, not the one in the popup's band. The
lesson is cheap and worth keeping: when a report says «в топ-баре», the first question is
*which* bar, and the answer is in the screenshot's scale — twenty pixels look like sixty
only when the capture is zoomed.

A person's portrait fills its frame now, flush to the edge. The inset existed to keep the
picture inside the circular frame, but an inset shows the surface colour as a ring around
the portrait — in a light theme, a white gap, which is what it looked like. The price is
the same one the covers pay: a picture cannot be clipped to a rounded shape here, so a
circular frame around a square picture has to choose between a ring of background and a
picture whose corners reach past the frame. Flush is the lesser evil.

The row that is playing carries a faint wash of the accent across its whole width, and
the keyboard cursor keeps the theme's selected fill: two different facts, two different
marks. Where they meet, the cursor wins — a wash you cannot select over would be a mark
that lies. The accent text on that row stays: the wash says «here», the colour says
«this one is sounding».

The row is a grid, not a chain: the place column is a fixed 28 px whether or not this row
has a number, so every cover in every list — the queue, a section, a playlist, the search
results — sits on one vertical line. The row's side padding is the same 10 px on both
sides, which is what the selected pill shows off.

A row is laid out the way the players people come from lay theirs out: the place number,
a small cover, the title over «artist · album», the length, and the heart. The playing row
sits on a plain rounded pill with a play glyph where its number would be, and its title is
bold — the pill says «here», the glyph says «this one is sounding». The keyboard cursor
takes the accent tint instead, so the two marks never look alike.

The cover is VK's own thumbnail, the one the panel has already fetched for the player; it
costs no extra request.

Every track row carries a heart as well, at its right end: filled when the track is in
«Моя музыка», outlined when it is not, and a left click toggles it without disturbing
playback. The heart cannot be flipped by writing into the track inside the list: a
delegate over a JS array model is handed a copy of the element, so that write changes the
list and nothing on screen. `Likes.js` returns a rebuilt list instead, with every copy of
that key carrying the new state, and the panel assigns it back to the lists that hold the
track — replacing the model is what rebuilds the rows.

In the extended player band the heart sits just left of the volume slider: it
belongs with the things that act on the sound, not after them. The compact player puts it
at the end of the title block instead, on the first line of what is playing, where the eye
already is.

The record under the artist is `album.title` from VK's catalog payloads, or the free-form
`subtitle` the older `audio.get` answers carry. Both are in the track state the daemon
sends, so the player needs no second request; when a track has neither — most of what
`audio.get` returns — the same line shows `0:00 / 4:06`, which is what it showed before
the record was in it.

## Languages

The panel speaks eight languages — English (the default), German, Spanish, French,
Japanese, Chinese, Ukrainian and Russian — and the language is a preference, switched in the
settings with a dropdown and stored like every other one. A row of chips was the first
attempt and it does not hold: eight names in their own spellings are wider than the panel,
and a row that scrolls sideways is a row most people never finish. The dropdown shows the
language in use and puts the others behind one click.

The strings live in `i18n.js`, keyed by the Russian literals the code was written with — which is also why Russian is
the one language whose values are the keys themselves.
That has one property worth the ugliness: a key with no translation falls back to itself,
so a half-translated panel stays readable instead of showing empty labels. English is not
a fallback — every key carries all seven languages, and a check over the file asserts it.

`plural(count, one, few, many)` asks the language how many forms it has: Russian and
Ukrainian three, English, German, Spanish and French two, Japanese and Chinese one. The
callers keep passing the Russian three, and each language maps its own groups onto them.

The daemon still answers in Russian prose, because its CLI and the journal are read by a
human too. The panel translates it with `tm()`: a whole sentence is looked up as a key,
and the two sentences the daemon builds around a value — «человек не найден: <query>» and
«Пропущен трек «<label>»: <reason>» — are recognised by their shape, so a dynamic message
translates around its own value instead of staying Russian.

What is NOT translated: the daemon's own messages — «Список пуст», the halt reasons, VK's
error text. They reach the widget as Russian sentences. Translating them means the
backend returning codes instead of prose, which is a change of its own.

## What the bar row shows

Fourteen preferences, most of them about the row in the bar, taken from the shape
the Yandex Music plugin uses — its list was the reference for which switches are
worth having. They are backend preferences, so `shell.json` still overrides any of
them for one instance, and the popup is where they are set.

| Preference | Values | Default |
| --- | --- | --- |
| `showArtwork` | on/off | on |
| `showTitle` / `showArtist` | on/off | on / on |
| `showControls` | on/off | on |
| `showProgress` | on/off | on |
| `showTime` | on/off | off |
| `showLike` | on/off | off |
| `coverShape` | square / rounded / circle | rounded |
| `longTitleMode` | truncate / scroll | scroll |
| `labelWidth` | 80–400 px (three presets) | 180 |
| `notifications` | off / all | off |
| `restoreQueue` / `restorePosition` / `restoreVolume` | on/off | on |
| `popupView` | compact / extended | compact |

Notes from building it:

* `restoreOnStart` was decorative — it was stored and shown but nothing read it.
  It is now three switches that are actually honoured by `_load_state`, and the
  old key is migrated on load.
* The same goes for the old `showText`: it became `showTitle` and `showArtist`,
  with the stored value applied to both.
* Scrolling titles animate a `scrollOffset` property that `x` is bound to, not
  `x` itself. An animation on `x` discards the binding that puts the text back at
  the start, so a clip that stopped scrolling kept its last position — off the
  edge — and a perfectly short title looked like an empty label until another
  long one came along. The text is also readable for a moment before it walks,
  rather than starting off the right edge.
* `ProgressLine` grew a determinate mode — a share filled from the left — for the
  track's position along the bottom of the bar. The pixel test covers it: 35 % and
  100 % fills, measured from the left edge.
* Notifications carry the cover, and the cover is scaled down with ffmpeg first:
  VK hands out 1200x1200 images, half a megabyte each for a notification drawn at
  a hundred pixels. It lands at about 4 KB, in `~/.cache/omarchy-vk-music/covers`,
  and `cache clear` removes it along with the audio.
* A `Row` cannot lay out an anchored child, so the progress line is a sibling of
  the bar row rather than a child of it.

## Two popups, one set of blocks

The popup comes in two shapes, chosen in the settings:

* **Compact** — 480x690: the player above the list, laid out the way VK's own player
  lays its controls out, and scaled from it. That reference is 415 pixels of content
  wide and this card is 524, so every size in the player is the reference's times 1.26:
  a bare 106-pixel cover — no rim, no inset, square corners, unlike every other cover in
  the panel — beside three lines, the title bold at 21, the artist at 17 and the record
  (or the position, when the track has none) at 16, all three in the same ink, since it
  is the bold title that separates the first line from the two under it. The block is
  centred against the cover rather than hung from its top edge, and the heart — 22
  pixels — sits at the row's far end on the block's centre line, not the row's.

  The lines under it are the reference's too: 29 pixels of air, then one row of
  controls, the transport with a 53-pixel round play button in the middle, the seek line
  between the transport and the two buttons at the right with a dot for a handle, its
  two times under it — elapsed at the start of the line, the track's length at its end,
  both at 18 — then the speaker and a menu button. Shuffle, repeat and the volume slider
  did not fit that row and are not worth losing, so the menu button opens them as one
  more line below. The card is 480 wide rather than 400 for that row: at 400 the times
  and the two buttons crowded the seek line, and the extra 80 pixels are also what lets
  the gallery put three covers across instead of two.

  The three lines came down from 23/18/17 on request — the block read as one size too
  loud beside a cover that is the same 106 pixels — and the reference's proportions
  survive it: the title is still the largest and the bold one, the artist still a step
  above the record.

  The player logs its own geometry once per popup, the way the bar row does: these
  numbers were measured against the reference art, and a later complaint about them
  should be answered from the journal rather than by eye.
* **Extended** — 620x760: the player is one band across the top — a 56 px cover,
  the title and the artist with the time, then shuffle, repeat, the transport, mute
  and the volume slider in the same row, with a thin seek line under it — and
  everything else, the tabs and the list, gets the full width below. A left column
  holding the player cost the list half the card for no reason; the band is about
  90 pixels, and the gallery went from three covers across to four.

They are not two popups: they are two arrangements of the same blocks, each block
a component of its own (`TopRow`, `SignInBlock`, `PlayerColumn`, `SearchFieldRow`,
`LoadingLine`, `TrackList`, `HintRow`). A layout cannot move a block into
another column; a component can be instantiated in either one. Only the visible
shape takes keys, so `activeList()`, `activeField()` and `activeBody()` pick the
one in use.

The top of both shapes is a bar of cells, one object, not a row of buttons: settings
in a square cell at the left end, the three views sharing what is left in three equal
cells, then the two cells that choose how a list of playlists is drawn, and the card's
own width in a square cell at the right end. What makes it one object rather than six
buttons is that the cells are flush — no gap, no padding, no frame around them — and
that the cell in use is filled for the bar's whole height, square corners and all. The
only lines in it are the two dividers that close the tools at either end; between two
views the fill of the one in use is the divider. The bar's height is stated once
(`cellHeight`, one line of text plus the control padding) instead of measured per cell,
and the two tools are as wide as that height is tall: a cell that measured its own glyph
left the fill of the active one a pixel off its neighbours, which in a band of flush
cells is exactly what the eye picks up. The bar at the top of the card is a fifth taller
than the bars under it — `cellHeight` is `barCellHeight * 1.2` there — because it is the
first thing the eye lands on and the one a hand reaches for without looking.

The card has no padding of its own (`padding: 0` on the panel) and everything is placed
inside `cardInset` instead: the bar takes none, so it is the card's lid and the cell in
use is filled from the top border to the rule under it, and every block below the bar
carries the inset as its own left and right margin. An inset bar was the first version,
and it read as a strip lying on the card with its own inner margins rather than as the
top of it.

The insets moved out of the panel and into the blocks for a second reason, and it is the
one that mattered: a first attempt kept the panel's padding and pulled the bar over it
with negative layout margins. The bar looked right — the fill reached the border — and
half of every cell stopped answering the pointer. The cells that hung outside the content
area were dead over the part that hung out, which for a bar 14 pixels above the content
area meant everything except the lower half of each glyph, and the pointer stayed an
arrow everywhere else. An item that is drawn outside its parent is an item the pointer
can miss; the bar's own cells are now inside their ancestors like any other control, and
nothing in the panel overhangs its parent for paint either.

That bottom edge is a solid two-pixel rule the width of the card's border, not one of
the panel's 12 % separators: the cell in use has to run into it. Under a soft line the
fill stopped a gap short and floated, and the eye read the gap as a margin the bar does
not have — which is exactly what «я всё ещё вижу отступ снизу» was looking at.

The bar over the list — the catalog's sections — is the same bar as the one at the top of
the card: flush, square, from the card's edge to its edge and with no inset of its own,
the section in use filled, and no icons (a section's name is the whole of it). The two
cells that choose how a list of playlists is drawn — gallery or rows — sit at its right
end, past a divider, where they cannot scroll away with the sections: they are about THIS
list, so they belong where the list starts, not in the bar at the top of the card. In the
search view the same bar holds the two kinds of answer a search can give: «Треки» and
«Плейлисты» split what the tools leave in half, because a switch of two equal halves reads
as a choice between two things. That switch used to be the first thing inside the scrolled
list, which put it inside the list's margins — a tab bar with a margin on it, which is the
thing the bar above the list exists not to be.

A list row is the same shape as the bar's cells: square, and as wide as the card. The
scroller is the width of the card and the column inside it carries `cardInset`, so the
text, the headings, the grids and the switches between the rows keep the card's margin —
and a row's *fill* is the one thing allowed to bleed wider than its parent, out to the
card's edge, which is where a selected row has to end. The bleed is paint: the row itself,
with its MouseArea, sits inside its parent like every other control, and that is the
distinction that matters — a fill that overhangs is invisible to the pointer, a control
that overhangs is dead where it overhangs. The gallery is the exception: a grid of cards
keeps `cardRim` as its padding on top of the column's inset, because a wall of covers
flush with the card edge reads as a crop rather than as a gallery, and because that
padding is what the column arithmetic in `GalleryFit` is measured against.

Two things about that arithmetic were wrong and both showed as margins. `plan()` divided
the row by the column count and then the grid added the gaps *between* the cards on top,
so a full row was (columns - 1) gaps wider than the list and the last column hung over the
edge. The gaps are taken out of the row first now, which is what the test's own comment
always said. And the leftover of the division all landed on the right, so a gallery's left
margin was the rim and its right margin was the rim plus a few pixels: the columns are
centred in what the plan leaves, and the two margins are equal by construction. A selected
card's fill is square, like a row's — a rounded one around a square cover was the last
rounding left in the panel.

The one-line rows of a search — a suggestion while typing, a query searched before — are
the same row language, and they are the ones that used to be `Button`s: a rounded pill
with a border, inset from the card and narrower than the text under it.

The cells are not `Button`s. A `Button` keeps the width of its own label, and three
equal cells cannot: a longer translation (German «Warteschlange») would push the bar
past the card instead of eliding. It also paints a rounded fill with a border of its
own, and a rounded fill that a divider runs past reads as one fuzzy edge — the two
were the same foreground tint, nine levels apart, and the divider disappeared into the
selection. `BarCell` is a Rectangle with `radius: 0`, no border, a `MouseArea` and a
`PanelToolTip`, so a view, a tool and a section chip are one component; the section
chips row below the list's heading is the same cells without icons.

The queue's own two actions — «Моя музыка» and «Обновления» — were the last buttons of the
old language in the panel: rounded pills with a border, inset from the card, inside the
scrolled column, in a panel where nothing else is either. They are cells of the bar now, two
of them stretched across it with their labels in the middle, flush with the card and with
nothing above or below, because what fills the queue is a choice between two things in
exactly the way a section is. They open those two sections rather than starting them — see
«A place that is already playing, and the list a click is about» for why.

A sections request that failed used to be remembered as if it had succeeded, so a single
error kept the bar empty of everything but «Люди» for ten minutes. A failed answer is a
reason to ask again, not a cache: only a successful one stamps the time, and the "in flight"
guard is a four-second window rather than a flag, because a reply that never arrives — a
process destroyed before its output was read — would leave a flag set for the life of the
shell, and there is no worse bug than one that only a restart clears.

Two more states look like a broken panel and are not: a section that is chosen but has no
rows (the widget's state is cleared by a plugin reload or an account change while the choice
of section survives, and what is left is a page that says «пусто», a stray «Ещё» and a bar
in which the section in use is filled and empty), and the same for the sections themselves.
Both are re-asked — once when the popup opens, and every five seconds while the popup is up
and the answer is still empty, capped at three tries per section because a section can be
empty on purpose and a panel that keeps asking is a panel that keeps flickering.

The bar over the list does not go away when a playlist is opened, and it is not the sections
that stay in it. Inside a playlist, or on somebody's page, the bar holds one cell at its left
end — «Назад», with an arrow, because a word alone at the edge of a bar is a label and an
arrow makes it a way out — and the sections are hidden: a row of section names beside it had
its tail cut off by the tools at the other end, which reads as a broken bar rather than as a
way in. The tools keep to the far right either way, held there by a spacer when there are no
chips to push them. A heading that floats where a bar used to be is what a reader has to hunt
for the way out in; the bar is where the list says what it is, so it is where the list says
how to leave it.

The bar over the list is framed by the same rule that closes the player, and the cells sit
flush between the two: one line above them, one under them, no gap either side. A rule that
floats a few pixels above a band of cells reads as the bottom border of the block above it
rather than as the top of this one. The frame lives in `TrackList` around the section bar,
so the rule the player ends with is the rule the bar starts with — the same separator, drawn
once — and the bar of status at the card's bottom is drawn to the height of the bar at its
top: the two close the card, and two bars that frame a card should be the same bar.

The volume is where the hand already is. The speaker button used to do one thing only —
mute — and a volume button that cannot set a volume is a switch with a speaker drawn on it;
it opens a popover over itself now, the same slider the panel keeps behind the dots, with
the mute glyph and the percentage beside it. The popover ends where the button ends rather
than being centred on it: the button sits at the card's right edge, and a panel centred on it
hangs over that edge and reads as something that fell out of the card. It closes on the first
click elsewhere, because nothing on the card moved while it was open and nothing needs
putting back.

The transport buttons are the one place a circle is the right shape. The kit's `Button`
paints a rounded square with a hover border, and beside a play button drawn as a circle it
is the shape that does not belong; `GlyphButton` paints the same hover fill and the same
hover border in a circle — a square box, `radius: width / 2`, so the fill cannot become an
ellipse. Every glyph in the player rows uses it: shuffle, repeat, previous, play, next,
volume, and the dots that open the rest.

A glyph that says what it is by lighting a box is not always right: under a 14 px outline
heart a 24 px rectangle is four times the shape it points at, and it reads as a button
while the heart reads as the thing being offered. `BarGlyph` takes `fillOnHover` for that,
and the hearts use it — the pointer fills the inside of the heart and paints no background,
the way a heart in a list of tracks is expected to answer. Pressing still paints the accent,
so the two states stay apart.

The glyph and the label are centred as one pair: the content is a `Row` with
`anchors.centerIn`, and the label gives up width — `Math.min(implicitWidth, cell width
minus the padding and the glyph's slot)`, `elide: ElideRight` — only when the pair is
too wide. Centring the label inside the room the glyph leaves instead put the pair half
a glyph left of the middle, which is what the bar looked like; and deriving the label's
width from the layout's own width is the binding loop that clipped «Поиск» the first
time round. The divider between a tool and the views is 30 % rather than the
separator's 12 % for the same reason: the bar's line has to win against a filled cell
by a margin, or it reads as that cell's border.

Three things learned in the move:

* A component cannot see the ids of the file around it, so the delegate repeaters
  are handed out through `property alias` — the keyboard cursor uses them to
  scroll the selected row into view — and the search field is reached the same
  way, since two of them exist now.
* An exception in a QML function kills the whole handler silently. The people list
  moved nothing at all because `rowAt` called `itemAt` on a repeater the component had
  not handed out — the missing alias threw, `moveCursor` died with it, and the panel
  showed a dead key with no error in the UI. `TypeError` in the shell journal is the
  first thing to look for when a key "does nothing"; the second is whether every
  repeater the cursor may look up is actually exported.
* An index in the cursor's list is not an index in a repeater. A section's column is
  the playlists and then the tracks, so the cursor's row 0 is the first playlist while
  `browseTrackRepeater`'s row 0 is the first track: resolving a playlist index against
  the track repeater sent the reveal to a row far below the viewport, and the row the
  cursor had actually moved to stayed off-screen — the keys looked dead because
  nothing visible changed. `rowAt` now picks the repeater by where the index falls.
* Running through the tabs must not cost a request per tab: that is a burst that looks
  like a robot and spends traffic nobody asked for. A section load from a tab or from
  ⇧H/⇧L goes through `scheduleBrowse`, which waits 350 ms and then checks that the
  panel is still on the section view — a load for a list nobody is looking at is exactly
  the traffic the delay exists to avoid. The window is 600 ms because that is longer
  than a person's own repeat: at 350 ms a load could begin between two keypresses and
  spend traffic on a tab that was already left. Measured with a log on every daemon call:
  six tab presses in a row issue no section request at all. A click on a source chip
  still loads at once:
  A section's playlists are empty while its request is in flight, so the two cells that
choose how a list is drawn — asked on the loaded rows alone — vanished for as long as the
request took and came back after it. They are shown while the section is loading as well;
a control that flickers every time a tab is pressed is worse than a control that is
occasionally redundant.

A delayed load also means the section's SLUG is still the old one for those 600 ms, so
  a second ⇧L must count from the *scheduled* one — otherwise the second press asks for
  the same section again and the first press looks like it did nothing. `effectiveBrowse()`
  is what both the cycle and the source chips read, so the chip lights up on the press
  even though the rows arrive later.
  the pointer is on the chip the user chose.
* A fix that reports "ok" is not a fix. Last round's replacement for exactly this
  `fillHeight` matched a block that had already changed and moved the heart instead of
  repairing it, while the check that followed — the popup's own layout line — could not
  see the difference, because the body is stretched to the card either way. What did see
  it in the end was the LIST's height: 210 px with the band inflated, 536 px with it
  fixed. When a defect is in one child's height, verify on the number that depends on it.
* A Text in a Layout without `Layout.fillWidth` and `Layout.preferredWidth: 0` has its
  own content as its implicit width, and a Layout takes the largest implicit width of its
  children as the minimum it will not go below. The hint line grew by one shortcut
  («g l вид») and the whole popup went from 588 px of content to 614: every row bled past
  the card. Any label that can grow with data or configuration needs `fillWidth` plus a
  zero preferred width, so it takes what is left and elides the rest.
  The popup's layout line reports the body's and the list's widths for exactly this
  reason — 588 against 614 is the whole story.
* `Layout.fillHeight: true` inside a Row inflates the ROW, not the child. Putting it on
  the heart's wrapper turned an 82 px band into most of the card, squashed the seek slider
  and made its knob a fat black dot — and the mistake is already in this document from
  the collapsed-list round. A control in a row wants `Layout.alignment: Qt.AlignVCenter`
  and a preferred height, never `fillHeight`.
* Air above a list is not decoration. A selected fill reaches past its row, and a
  selected tab's fill reaches down; with nothing between them the two read as one
  shape. The list keeps a fixed 10 px spacer at the top of its column, so the gap does
  not depend on whether a heading happens to be visible.
* A representation switch belongs where there is something with two representations.
  «Моя музыка» is a hundred tracks and not one playlist, so the gallery has nothing to
  show and the switch would be a control that changes nothing — worse than absent, since
  it promises a view that does not exist. `playlistsShown` gates both the switch and the
  keys, the same rule the switch already followed for an opened playlist.
  Its first version asked only for playlists, which hid the switch on the friends page —
  where people are cards or rows, the very same choice. The condition is «this list has
  two representations», not «this list contains playlists».
* A key that silently does nothing reads as a broken key. ⇧H and ⇧L switch sections,
  which only means something in the section view — on any other tab they returned early
  and the panel ignored the press. They take the panel to the section view first now.
* `m` toggles the representation — gallery or rows — wherever both exist. It was briefly
  `g` and `l`, and `l` was the mistake: it is the same finger that walks a gallery, and a
  key that sometimes moves the cursor and sometimes rearranges the panel cannot be
  learned. Navigation keeps hjkl whole; the switch has one key of its own.
* Keys, and which pair does what: `[` and `]` walk the tabs (queue, section, search,
  settings) and `⇧H`/`⇧L` walk the sources of the section view. The second pair is free
  because the key catcher turns an unshifted h and l into cursor moves, while a shifted
  letter is not «h» and arrives as a plain text key — so navigation and switching can
  never be confused for one another.
* A selected fill that reaches past its card needs room to reach into: a grid keeps a
  rim of its own (`cardRim`) on both sides, and the cell width subtracts it, otherwise
  the first column's fill is cut by the edge of the list. The same rim's worth of space
  is needed between the tab row and the first row of a list, or the two selected fills
  touch and read as one thing.
* Two functions that call each other are a loop, not a pair. Closing a person went back
  to the people list, and going to the people list closed a person: the pair recursed,
  the friends came back empty and the header read «Друзья · 0 человек». They share a
  `loadFriends()` now, and each clears what it needs on its own.
* Closing a person's page has to change the slug, not only the person: with `browseSlug`
  left on «person» and nobody in it, the header said «Человек не найден» — a step back
  that leads to a message about a search that never happened.
* A probe left in the widget is invisible from the outside: the file parses, the widget
  loads, the journal is clean — and the panel does something the user never asked for,
  two seconds after every open. It happened three times, so it is a tool now:
  `tools/check_widget_source.py` fails when a Timer logs, changes the view or loads a
  section, and when the `ВРЕМЕННО` marker is still in the file. Run it before deploying.
* A cleanup script that removes blocks by text matching removes the WRONG blocks, and
  nothing about the result looks wrong: the file still parses, the widget still loads,
  the journal is clean. A probe timer that switches the view was left alive and the
  panel jumped to «Обзор» two seconds after every open; at the same time five working
  timers — the poll and tick, `liveVolume`, `liveSeek`, `suggestTimer`, `wheelWrite` —
  had been cut out, leaving calls to ids that no longer existed. What catches it is
  counting the things that are NOT the thing being edited (how many timers exist, and
  whether the ids they are called by still exist), not the brace balance. The fix was
  to restore the file from the last complete commit and re-apply the round's changes.
* A filter belongs to the list it was typed in. Filtering a section to «Русс» and then
  opening a playlist showed an *empty* playlist, because the filter was still applied
  to the new list's rows — the playlist had forty tracks and none of them matched the
  text typed into a different list. Every navigation that changes the list clears the
  filter.
* The keyboard belongs to the list when the panel opens, not to a field of a view that
  is not showing: the field would sit there focused and eat every key it was given,
  Backspace included.
* Backspace goes back one level, the same thing the «Назад» button does. It cannot be
  read from `onTextKey` (it is not a character) and the panel never sees it (the key
  catcher owns the focus and its handler accepts what it maps), but the catcher does not
  map Backspace — so it arrives as a key *release* on the catcher instance, which is the
  one place a plugin can legitimately attach to.
* A hidden field cannot own the keyboard, but it can think it does: the panel blocks
  every key for whichever field is focused, and a search field that kept focus while
  another view was showing left j, k and everything else dead — the keys went to a
  field nobody could see. `visible` is part of the question now.
* With nothing picked yet, the first j or k starts from the first row of the visible
  area rather than from the top or the bottom of the whole list, which in a hundred-row
  section is a jump to somewhere the user is not looking.
* The component's height is not the viewport's height. `TrackList` is a column with
  the sticky row on top and the Flickable underneath, so `activeList().height` is the
  viewport plus that row; the scrolling maths used it anyway, asked for a scroll
  45 pixels further than the list could go, and the last row of every long list stayed
  half under the bottom edge — an unclamped target plus a height that was the wrong
  one. The reveal now clamps to `contentHeight - viewHeight` with `viewHeight` aliased
  from the Flickable itself, and repeats once with `Qt.callLater`, because the list's
  height is still settling while the panel opens.
* A loading line that reserves its place is a line that can sit on the last row of
  the list above it. The panel's indicator held two pixels in the layout whether or
  not anything was loading, and the row of a list ended up looking cut by a dark
  stripe. It is only in the layout while it is loading now, and it clips to its own
  height, so an idle panel has nothing below the last row. The same one line serves
  every view — the queue, a playlist, a section, a person's playlists, the search —
  so the fix holds wherever a list is.
* A hint at the bottom of the card is a hint on top of the last row of every list, and
  the key hints moved to the top for exactly that reason; then back down when the top
  became a bar of views and switches; and finally out of the card altogether, into a sheet
  behind a question mark. Three homes in three rounds is the honest history: a line of
  tiny print is either in the way of the list or in the way of the controls, and the only
  place it fits is somewhere nobody has to look at it until they want to.
* One column of rows is one cursor. A section shows its playlists and then its
  tracks as two Repeaters in one column, and the cursor used to cover only the tracks
  — so k from the first track stopped there instead of reaching the playlist above
  it. The cursor list is the playlists followed by the tracks, and everything that
  resolves a row accounts for the offset. The gallery is the exception, because there
  the cards are the list and the tracks are drawn under them.
* A cursor belongs to a list, not to a session. Moving between tabs, sections, a
  person, a playlist or a search mode resets it: the position in the queue has
  nothing to do with the position in a section.
* A view preference is not the same as the view. `galleryMode` asked whether the
  playlist view was set to the gallery, which is a setting about playlists — so `j`
  stepped a whole row inside a playlist's tracks and inside the queue, where the
  list is one column, and the cursor landed four tracks further down than it was
  asked to. What decides is the list on screen: a playlist's tracks and the queue are
  lists whatever the preference says, and only a grid of cards steps by a row.
* A function on the root cannot reach an id inside a component. `startFilter()` was
  one: it called `filterField.forceActiveFocus()`, the name resolved to nothing, and
  the filter field never took the keyboard — so «/» opened a field that swallowed
  nothing and typed nowhere. The field focuses itself when it appears and reports the
  fact back through `filterFocused`, which is also what the key catcher needs before
  it can decide who owns the keys.
* Leaving a search field in focus while another view is on screen blocks the list's
  keys, because the catcher is blocked while a field owns the keyboard. Switching
  tabs and sections now hands the keyboard back to the list.
* The cursor walks what is on screen. In the gallery the section's playlists are the
  cards, so h and l step a card and j and k step a row keeping the column
  (`GalleryWalk`), and the cursor covers the playlists rather than the tracks drawn
  underneath them; in a list only j and k mean anything. Tab hands the keyboard to the
  list and puts the cursor on its first item, which is the way out of a search field
  that has been typed into.
  Esc in a field now drops the focus and nothing else — clearing the query and
  closing the panel are the next Escs, from the list.
* `containsMouse` is always false without `hoverEnabled`. The track rows had no
  hover state at all — not a styling choice, a MouseArea that never tracked the
  pointer. A row now has two fills: the selected one for the keyboard cursor and the
  plain one under the pointer, so a list answers both «here is the keyboard» and
  «here is the mouse» without the two looking alike.
* A field that has the keyboard owns every key. The panel's key catcher translated
  «j» and «k» into a step down and up the list *before* the search field could see
  them, so moving by j/k after typing a query did nothing visible and the letters
  never reached the field. `blocked: root.activeField().activeFocus` hands the
  keyboard to the field while it is focused, and the field answers Esc itself.
* «/» belongs to the list in front of you, not to VK. It used to jump to the search
  view; it now filters what is on screen — the open playlist, the queue, a section,
  the search results — matching the title, the artist or the name, with the heading
  saying which filter is on. Because the visible row's position is then not its
  position in the queue, everything that acts on a row acts on the item
  (`indexOfItem`), which is what keeps a filtered list from playing the wrong track.
  A gallery is drawn from the filtered list as well: a card that is not drawn must not be
  in the cursor's list either, or the selected fill sits on the neighbour of the row the
  keys act on. The friends page and the search results were the two walls that were still
  drawn whole, and the recent people's offset was counted against the filtered friends
  while their cards were not — the highlight landed one card off with every filter.
  Radio was the last list outside the rule, and the shape decisions (`galleryMode`,
  `playlistsShown`) were still counting raw lengths while the rows were filtered: see
  [ADR-0001](adr/0001-filter-applies-to-every-list.md). Every list now goes through
  `filtered()`, and the filter and the shape it produces come from one call.
* A click must have somewhere to show its result. The playlist screen was drawn
  only in the browse view, so a playlist clicked in the search results was fetched,
  remembered and never seen — the click looked dead. The screen now belongs to the
  open playlist rather than to a view, the search's own content steps aside while it
  is up, and the pair `(view, browseSlug)` is remembered at open time so «Назад»
  returns to the search with the query still in the field.
* A heading inside the scroll stops being a heading. Every view's header row lived
  in the list's own column, so it slid away with the rows — and for the settings
  page, which is the longest thing in the panel, it meant losing the only thing that
  says where you are. `TrackList` is a `ColumnLayout`, and the heading, the way back
  and the view's action left the scroll. They left the top of the card as well, in the
  end: they are the status bar under the list now, behind a full-width rule. A heading
  above the first row — «Друзья · 3 человека», «Главная · 54 трека · 3ч 44мин»,
  «Моя музыка · загрузка…» — is the list talking about itself, and it reads as the first
  thing in the list rather than as a line about it. Under the list it costs the list
  nothing and it is the place a status belongs: the same line the panel already had for
  a skipped track, now shared with the heading, with the filter field while «/» is being
  typed, and with the two cells that act on the list («Назад», «Играть»/«Очистить») and
  the question mark. Those cells are drawn as cells of a bar, not as buttons in a row:
  the rule above them and the card's own edge below are the bar's edges, a divider marks
  where the line stops being text, and the last cell carries the card's corner the way
  the first cell of the top bar does. A bar that closes a card is the bar that opens it —
  which is why «Назад», the first cell on that line, starts at the card's edge and not at
  the inset the text beside it keeps: the cell's fill is what has to reach the edge, and a
  fill that starts an inset later reads as a margin the bar does not have.
* The status line was not the place for «…». Every command raised the marker, the poll
  among them, so while a track played the line blinked once a second — measured at two
  frames in seventy with the poll marked, none in seventy without it. The marker belongs
  to the commands the reader gave; the poll is the widget breathing, and `call` takes a
  `quiet` flag for it.
* A caption in a plain `Row` is not aligned with buttons: a Row places every child
  at its top, and a `PanelSectionHeader` is a `Text` whose own height is smaller
  than a button's, so the caption floats above the row's centre line. The three
  header rows of the popup are `RowLayout`s with `Layout.alignment: Qt.AlignVCenter`,
  and the caption carries `Layout.fillWidth`, which is also what pushes whatever
  follows it — «Играть», «Очистить» — against the right edge instead of leaving it
  somewhere in the middle. A `PanelSeparator` closes each of them, so a list is
  visibly a list and not more controls.
* A loading flag is not a decoration: a reply that arrives after the pane has
  moved on has to clear the flag it set even when it must not paint its rows. The
  section loader returned early on a mismatched slug — with the flag still up — so
  opening «Люди» while a section was in flight left the loading line running under
  the panel forever, most visibly on the settings page, where nothing at all is
  loading. One request token per pane drops stale data; every entry point clears
  the flags of the kinds it is not, and `anyLoading()` names all of them.
* The queue's own actions («Убрать» and «Очистить») lost their place when the
  player became a band, so they moved to where the queue is: «Очистить» sits in
  the queue's header, and right-clicking a queue row offers «Играть сейчас» and
  «Убрать» instead of the two verbs that belong to a row from somewhere else.
* A component's root must *be* the block, not wrap it. Both `TrackList` and five
  smaller blocks first came out as `component X: RowLayout { RowLayout { ... } }`,
  because the extracted text already began with its own declaration line. The
  nesting is invisible in the source, but a nested layout has a size of its own:
  the sign-in block took 384 of the popup's pixels and left the list 6. Printing
  every child's height is what found it.
* Screen coordinates for testing are a moving target: the widget's own width
  changes with the track, the bar re-centres the widget when it does, and the
  panel follows the widget. The technique that finally worked was a temporary
  full-size `MouseArea` inside the floating card logging its local click
  coordinates — a click that reaches the probe hit the card but not a button, and
  a click that reaches no probe is a button. Scanning x across the row found the
  buttons' real rectangle after two rounds of estimating them wrongly from
  screenshots.
* The shape is read through a function (`isExtended()`), not a cached property,
  for the reason `onAir()` is: a `readonly property bool` digging into a field of
  a `var` kept its first value, and the card stayed 400 wide after the setting was
  switched until the shell was restarted.

## Adding to the queue, and the right mouse button

The queue used to be whatever the last command made it, so looking something up
cost you the list you were listening to. Two verbs fix that, and they are the only
ones that touch a queue without replacing it:

* `queue add <key>` appends to the end (`Player.enqueue`).
* `queue next <key>` inserts right after the current track (`Player.insert_next`),
  so the next «next» plays them; with nothing playing yet they simply become the
  queue.

The popup reaches them by right-clicking a track row — in the queue, in a section
page, and in the search results, but not on a radio station, which is a stream
rather than a track. The offer is a small card floating over the panel's bottom
edge: the track, «В очередь», «Следующим» and a cancel cross. It is anchored to the
key catcher rather than laid out in the body, so nothing moves when it appears, and
Esc closes it before it closes the popup.

## The wheel, and a search one keystroke away

The wheel over the bar widget is the volume, five percent a notch, the way most
bars do it — the same `onWheel` the reference plugin uses. The steps go out live
and a 400 ms timer writes the value down once the wheel stops, because a notch is a
whole action rather than part of a drag.

`/` anywhere in the popup opens the search view and puts the cursor in the field.
With the field empty, the last few committed searches are offered back under
«Недавние запросы», and the arrows and Enter pick one. Only a search that settled
is remembered — the debounce means intermediate prefixes never reach the daemon —
and the list lives in the state file (`searchHistory`, at most eight), read out of
`status` by the widget.

## Other people's playlists

VK's audio API no longer exposes bookmarks (`fave.getUsers` and
`bookmarks.getBookmarks` answer «Unknown method passed» on 5.131, 5.199 and 5.282,
while `fave.getPhotos` works), and a community's playlists are refused with error
15. Everything else is open, and was checked live before anything was built:

* `audio.searchPlaylists` searches playlists by name — «джаз» answers 5998 of them,
  each with a cover, a length, a listener count and the `access_key` that makes it
  playable by somebody who does not own it.
* `audio.getPlaylists(owner_id=…)` lists any user's playlists: three for a friend,
  322 for a stranger picked out of the search results.
* `audio.get(owner_id, album_id, access_key)` plays them, which is the same call
  the plugin already made for its own playlists.

The way in is the «Люди» entry, first in the source row of «Обзор» and deliberately
not last: choosing a person is a route to a list, not a section, and a chip at the
end of a row that scrolls is a chip nobody finds. It opens a screen with the friend
list — a photo and a name each, clickable — a field for a link, an id or a friend's
name, and the people opened before. Clicking anybody opens their page: their name,
how many playlists they have, a «Назад» button, and the playlists in the gallery or
as rows. The keyboard cursor walks the list the same way it walks tracks.

So the plugin offers four ways in — the playlist search, the friend list, any
person by link, id or screen name, and its own playlists in the gallery — and keeps
a local list of recently opened people (`recentPeople` in the state file, eight of
them) as the stand-in for the bookmarks VK will not hand over. A pasted link is
parsed for a profile (`vk.com/id213706100`, `@durov`, `durov`, `213706100`) or a
playlist link, from which the owner is taken.

## Opening a playlist is not playing it

A click on a playlist used to replace the queue with its tracks, which meant the
only way to look inside one was to start listening to it. It now opens the
playlist: the tracks are fetched (`cmd_playlist_tracks`, the same
`audio.get(owner_id, album_id, access_key)` the player uses), shown as a numbered
list with the playing track marked, and the header carries a «Назад» and an
«Играть» — so playing the whole thing is still one click, and starting from the
fourth track is a click on the fourth track. That click sends the visible rows to
`play tracks`, so the queue becomes exactly the list on screen, the way search
results already worked.

The view switch moved in the same round: gallery and list buttons now sit at the
right end of the tab row rather than beside each list's header. One place, the same
in both popup shapes, and it no longer competes with the header for room.

## A place that is already playing, and the list a click is about

Two rules, one sentence each, both of them learned by watching the panel do work
nobody asked for.

**Pressing the place you are already playing does nothing.** A station card, a
playlist played from a search, and a section reached from the browse page are the
controls a person presses while listening to exactly that thing, so the click
rebuilt the queue from its first track: the track that was sounding went back to
0:00, the fifteen waiting behind it were replaced by the ninety-nine that come
after the first, and the list under the hand that had just decided not to change
anything changed. The daemon already reports where the queue came from
(`source`: kind, id, title), so the widget asks before it acts (`playingFrom`;
a station's id lives in its own field because a station has no queue). Playback
has to still be going for the answer to be «nothing to do»: a queue that ended, or
one that was stopped, is a queue to start again. A pause is not — the pause button
is a centimetre away, and a cell that silently resumes is a cell doing two jobs.

The queue's own two section cells — «Моя музыка» and «Обновления» — left that rule
when they stopped starting anything. They are the two sections a person most often
wants to *look at* from the queue, and pressing one began playing its first track,
so «Обновления» opened as a stream rather than as a list of what is new. A click on
either now opens that section in the browse view (`openSection`: the view, the
section and the cursor in one move) and touches nothing in the player — the queue
keeps sounding, and playing the whole section is the «Играть» in its header, one
click away in the page the cell just opened.

«Играть» in an opened playlist's header stays outside the rule on purpose: it says
play the playlist from the top, and a command with a direction means it. What the
rule protects is the place you are in, not a button that promises a restart.

**A click on a track queues the list that track is in, as that list.** The click
used to travel as VK keys and come back through `audio.getById`, which is a second
answer rather than the one on screen. VK returns the requested order, but it
drops what it no longer serves — one track of a hundred here — and every row after
the dropped one then meant something else in the queue than it did in the list,
while the queue silently lost a row. Beyond a hundred keys the tail was cut off
outright, so a section page with «Ещё» pressed twice was not the queue at all. The
widget holds the rows already, so it sends them (`play tracks`, the same payload
`queue add` uses): the queue is the list in its own order, `index` is the row that
was clicked, and the request costs no call. A track VK will not serve is no longer
filtered out in advance — it fails at its own turn and the player says «Пропущен
трек», which is what should happen: a list that quietly shrinks is worse than one
row that is skipped out loud. The sending function is one (`playList`), and it also
names the place, which is what makes the first rule hold for lists reached through
the browse page, a playlist or a search.

**The queue is a list too.** It was the one list in the panel whose content depended on
what was playing: a window of the next twenty tracks, starting at the current one, so a
click on a row further down re-anchored the window, the rows above the new current track
disappeared, and the list changed under the hand that had clicked. It is now the whole
queue, numbered absolutely, with the playing row marked wherever it is — so a click moves
the mark and nothing else, the same way a click in a section, a playlist or the search
results moves nothing. The playing row can then be below the fold, so the list scrolls to
it when the queue arrives and when the track changes, and never between.

## Two views for playlists

The queue is drawn whole, from its first track to its last. It used to be a window that
started at the current track, and the cost of that window was a list that moved under the
hand: a click on a row below the current one re-anchored it, the rows above the new track
vanished, and every number that stayed meant a different track than a second before. A
queue is the list of what is playing, so it is drawn like every other list in the panel —
section, playlist, search results — where a click marks a row and moves nothing. The row
that is playing keeps its own mark (the pill and the play glyph exist to be seen on
exactly that row), and the numbers are places in the queue, absolute under a filter as
well: a row that says 8 is the eighth track whether the other 99 are on screen or not. The
price is that the playing row can be far below the fold, so the list scrolls to it in the
two moments it may move — the queue arriving, and the track changing — and never between
them. The heading still describes what is *left*, from the current track on, because that
is the question the line answers.

The same holds for people: the friends and the people opened recently are one list on
screen, so the cursor walks both, and a grid's cards know their offset in it — the
recent cards must not light up for the friends' indices.

Cards also keep their captions inside themselves: text that touches the edge of the
surface it sits on reads as a layout accident. And the rounding is small — `Style.space(6)`
rather than the theme's `cornerRadius`, which on a tall card turns a fill into a pill.

The cursor walks what is on screen, and in a section that is both kinds of thing: one
column of playlists and then tracks in the list view, a grid of cards with the same
tracks under it in the gallery. So one offset describes both, and a step down keeps the
column: the card under the selected one, whichever wall of cards it belongs to, and the
first track when it leaves the cards altogether. Coming back up, the first column of the
last card row. The walls of a page do not have to stand the same number of cards across
— the friends page is a wall of friends and then a wall of people — so each wall brings
its own column count and a step into a narrower one lands on its last column instead of
past the end of a row (`GalleryWalk.js`, `tests/qml/tst_gallery_walk.qml`). A step down
that used to count `galleryColumns` from the list's start landed on the first card of
the wall below rather than under the selected one: one key left as well as down.

The cursor's mark is the same in both views: a selected fill. A row takes it behind
everything, and so does a card — cover and captions together, with a few pixels of rim
showing around the picture, which is what makes a card read as one thing rather than a
picture with a label under it. The cover keeps only the hover border, so the two states
say two different things instead of overlapping.

People follow the same switch as playlists, because choosing a person is picking a
face: in the gallery they are cards — the picture in a circle, the name under it, two
lines for a long one — and in the list they are rows with a small round picture and
the name beside it. `friends.get` and `users.get` ask for `photo_200` rather than
`photo_100`, since a card shows the picture at 143 pixels.

A track in a list is a row too, and the same one everywhere it appears — the queue,
a playlist, a section and a search — because four ways of writing «artist — title»
was four things to learn. `TrackRow` puts the track's place on the left when it has
one, the title and the artist on two lines, and the length on the right; the playing
row is written in the accent colour while the cursor keeps the fill, and a row with
no place in a playlist simply leaves the number column out. No cover: three hundred
thumbnails is a slow list, and the album art is already one line higher in the
player.

A playlist row is not a line of text with a dot in the middle: it carries the playlist's
cover at 28 pixels, the name on one line and «N треков» in the muted colour under
it. The cover is the thumbnail VK keeps for exactly this (`photo_68`, then
`photo_135`), so a page of thirty playlists costs thirty small images rather than
thirty covers — the gallery is where the big ones belong, and `_extract_cover`
takes a `small` flag to say which is wanted. The author is deliberately not in the
row: on a person's page the heading already says whose playlists these are, and in
a search the title matters more than the second name.

Playlists are shown as a gallery of covers or as rows, and one setting chooses for
every list of playlists — a section's own, a person's, or a search's. It is
`playlistView`, switched by two small buttons in the header of the list and
remembered like any other preference. The gallery puts two covers across the narrow
popup and three across the wide one (`galleryColumns`), with the name and the length
under each cover; the rows print the same two facts as text.

Both are the same component pair (`PlaylistGrid` / `PlaylistRows`) fed the same
array, so a new place that shows playlists is one instantiation rather than a new
layout. The gallery is the one place the plugin shows images it does not need:
covers load asynchronously, and a missing one leaves the frame with a music glyph
rather than an empty hole.

### A cover that is not there

The frame is a `CoverTile` everywhere a picture appears — a playlist card, a playlist
row, a track row, a person, the player, the twenty-pixel cover in the bar — and the
picture fades in over it only once `Image.status` says `Ready`. Loading and failure
therefore look the same, on purpose, and both look like something: the tile is tinted
and carries the item's first letters. What this replaced was a frame whose picture was
shown whenever the URL was not empty, so a link that did not answer left a flat square
of the popup's own colour, with the glyph hidden because nothing was missing from the
JSON.

The links do stop answering. A playlist's cover comes from VK as a signed URL
(`sign`, `c_uniq_tag`), and a scan of 83 covers fetched in the same minute as their
`photo` object found two already dead — `HTTP 424` and `HTTP 404`. The widget keeps a
section's or a person's payload for as long as it runs, so a gallery reopened hours
later holds signatures that have expired meanwhile. Nothing in the interface can make
such a link work again; it can only stop pretending the picture is coming.

The tint and the letters both come from the title, in `CoverTint.js`:

* the hue is a hash of the title, so one playlist is one colour on every open and on
every machine, and the tests can pin it;
* the tile is that hue mixed 24 % into the popup's own surface, so it is dark in a
dark theme and pale in a light one, and never a saturated block beside the real
covers it sits between;
* the monogram is the first letters of the first two words that are not punctuation
or a short preposition — «Блюз: Краткая история» is «БК», «От Disco до Rave» is
  «DR» — and one word gives one letter;
* under forty pixels there is room for one mark only, so a row shows the glyph, the
  way it always did; the corner mark joins the monogram only from eighty pixels up,
  where it reads as a second word rather than a speck.

The rim of the frame stays neutral: it is the fallback that is coloured, not the
border around a picture that loaded. The picture is asked for at twice the tile's
size (`sourceSize`), so the 600-pixel cover is not decoded for a 160-pixel card.

### The size of a card, and the row that is never cut

The columns give a card its width and the card gives the list its height: 160 pixels of
cover is 160 pixels of cover, and the two rows of caption under it are fixed. The two
are the same question asked at right angles, and it took three answers to get right.

The first narrowed the cells until a whole number of rows filled the list, which left a
strip of empty background at the right edge of every gallery — a grid that looked like
it had lost a column. The second kept the width and cut the *list* down to whole rows,
which filled the viewport with a card ending on a row boundary but left the air under
that last row, and pushed the sticky heading down by the same amount.

What the card does now is grow: `GalleryFit.wholeRoom` says how many whole rows a room
holds and what height they take, and if one more row is worth asking for, the card asks
for exactly that many pixels (`BarWidget.qml`, `alignGallery`). The gallery then ends on
a row boundary at both ends — the cards fill the width, the rows fill the height, no
card is cut by the edge the keyboard cursor walks into, and no strip is left over to be
filled with nothing.

Three details make that work. The room the list gets comes from the card's height, so
the card cannot be *bound* to the rows it holds; the list asks for the height
imperatively, once per layout change. The request is counted without what the card has
already grown by, or every answer would find the next row worth asking for and the card
would climb to the height of the screen one row at a time. And only the body on screen
aligns: the popup holds two bodies with the same ids, and the hidden one would reset the
height every frame.

What sits in the scroll above the grid counts too, which is why the section chips are no
longer in it. At a hundred pixels they stood between the top of the list and the first
card, so a gallery could align with the top edge of the scroll or with the bottom one,
never both. Out of the scroll they are always reachable, and the grid starts at the top.

The reveal follows the same boundary: in a gallery the cursor's row is put where the
viewport's first row goes rather than scrolled just far enough to be seen, which kept
the row above the cursor cut in half. Rows and tracks keep the old behaviour: they are
lines, not squares, and their height does not divide anything. A gallery with fewer
items than columns stretches its cards to the width it has — three friends are three
cards across the panel, not three cards and a hole — but a wall of one is not a wall, and
is not drawn as one. The friends page usually holds a single friend, and that friend as a
card was a poster standing next to two thirds of empty row: a section of one is drawn as
the row it would be with the gallery off. The page has two sections, friends and the
people opened before, and each answers for itself (`friendsGallery`, `recentGallery`), so
one friend under three recent people is a row and three cards. `galleryMode` is
`friendsGallery || recentGallery`: a page of nothing but rows steps the cursor by one,
and a page with any wall in it walks the cards by rows (`galleryBands`), each wall with
its own column count.

The captions under a cover are measured from the fonts (`TextMetrics`), not from a
delegate: a card's height decides how many rows the room holds, and reading it back from
a laid-out card would make the two depend on each other.

### The line of key hints

The hints are the only place the popup says which keys it answers to, and for a long time
they were a line of caption type under the list: two lines of five-point print, read once
and never again, and the keys it could not fit were the ones a beginner needs most. The
line is gone. A question mark in the card's bottom-right corner — a cell of the status bar,
the same flat square as the view toggle at the top of the card, because a framed box among
flat cells reads as a form control that strayed into a strip — opens a sheet: a title, a
rule, and one row per key, the key in the left column and what it does in the right.

The sheet opens from the button and from the «?» key, and Esc closes it before it closes
anything else: a help that needs a mouse is the help that is needed first, and one that
cannot be dismissed from the keyboard is a trap.

The sheet is built from the same translated string the line used: the hint is one string
with «·» between its keys, and the sheet is those phrases, one per row. A phrase whose
first words look like keys — short, latin, and never the last word — is drawn as a key cap
with its description beside it; anything else stands as one line, which is what «[ ] вкладки»
needs. No new translations, and the sheet follows the panel's language for free.

What the footer keeps is the status: a skipped track still says why, on one line, eliding.

## The scrolling label, and why it stops at both ends

A long title scrolls, and the first version scrolled it *past* the clip: the text
walked to its own width plus a gap, so for a while every pass showed an empty
field with only the tail's last letters behind, and the label looked broken rather
than long. The walk now ends at the overflow — `implicitWidth - clip.width` — so
the last frame of the pass shows the string's end, flush with the right edge.

Both ends rest for `marqueePauseMs` (1600 by default): the beginning while the
title reads, the end once the artist has arrived — the two places worth reading.
The return to the start is a jump rather than a second pass, which the pause in
front of it turns into an obvious loop. The speed is `marqueeSpeed` pixels a
second (70 by default), so the duration follows the text instead of a constant.

Both numbers are preferences, so both have sliders in the settings — and both are
dimmed while «Длинные названия» is set to «Обрезать», where they mean nothing. A
slider can send any value, so the daemon clamps these (and `labelWidth`, and the
cache limit) through `PREFERENCE_RANGES` before storing them.

## The transport row

One row, in both popup shapes: the heart, shuffle, repeat, then previous, play and
next. The queue actions — «Убрать» and «Очистить» — need more room than the
240-pixel column of the extended popup's player has, so they keep a row of their
own there and are absent from the compact popup entirely.

The heart says one thing: filled means the track is in «Моя музыка», outline means
it is not. `mdi-heart` is `F2D1` and `mdi-heart-outline` is `F2D5`, and the pair
was wired the wrong way round until both codepoints were rendered side by side and
looked at — the shell draws `󰋑` solid and `󰋕` hollow. A two-glyph question is
settled by rendering the two glyphs, not by reading their names.

## What the lists say

Three small things were added once the lists worked, all of them about a list
telling the truth about itself:

* **Which row is playing.** The accent fill marks the keyboard selection, so the
  playing track is marked with a glyph instead: `▶  Go_A — Жальменіна (2016)` in
  the accent colour, matching by track key (`isPlayingTrack`). The queue needs
  none of this — its rows begin after the current track — but a section page and a
  search result both can contain it, and then the row says so.
* **How long the list is.** Every heading carries a count and a total length,
  both for tracks: `Обзор · 52 трека · 2 ч 26 мин`, `Найдено 30 · 1 ч 41 мин`,
  `Дальше в очереди · 96 треков · 5 ч 58 мин`. The count uses the Russian plural
  rule the plugin already had; the length is the sum of the durations VK sent with
  the tracks (`listSummary` / `tracksSpan` / `humanSpan`), so it costs nothing.
* **Which keys work.** One dim line at the bottom of the card, above the loading
  line: `Space пауза · jk выбор (hjkl в галерее) · Enter играть · / фильтр · Esc закрыть`. The
  popup answers to five keys and nothing on screen said so. Esc is the one key
  with two meanings, and the hint follows the query: with something typed in the
  search it reads `Esc очистить поиск` and clears the field instead of closing the
  popup — the second press closes, so backing out is one step at a time.

## Queue actions

Three commands exist for the popup to build on: `queue_remove <index>`,
`queue_clear`, and the shuffle and repeat toggles that were already in the CLI.
Removing the track that is playing stops playback and leaves the index on the
entry that took its place — playing on while the list says otherwise would make
every later action act on the wrong track.

## The keyboard in the lists

Up and down move a **selection**, not the playback: looking through a list should
not start a track. The selection is one integer — an index into the list the
current view is showing — so the same number means the same row in the queue,
under a section, among search results or among the stations, and each delegate
simply asks `index === root.cursor`. `Enter` plays what the selection points at;
with nothing selected it plays or pauses, as before. `Space` is still play/pause,
and `n`/`p` still switch tracks.

Three details that were not obvious:

* **Scrolling to the selection uses the delegate item, not arithmetic.**
  `Repeater.itemAt(index)` gives the row, and its `height` and its position in the
  content decide how far `contentY` has to move. Rows are not a fixed height, so
  index arithmetic drifts.
* **The row's `y` is not a scroll position.** It is the y its parent block gave
  it: a gallery card sits in a `Grid`, the grid in a column, and the column under
  the section chips, so the card's own `y` started near zero while the card was
  hundreds of pixels down the content. The reveal used it directly and every
  block above the row shortened the scroll — worst in the gallery, where the last
  card's caption stayed below the bottom edge, then got clamped away by the end of
  the content. Both the reveal and the first-visible-row lookup now map the row
  into `scroller.contentItem` (`TrackList.contentRoot`) first, which is the space
  `contentY` counts in.
* **Only one handler may own Enter.** The search field had its own `onAccepted`
  (`runSearch(true)`) *and* the panel's key catcher reported Return. The field
  handled it first, which re-ran the search and reset the selection a moment
  before Enter was supposed to use it — so Enter in the search results appeared to
  do nothing at all. The catcher owns Enter now; with a selection it plays that
  row, and with the field focused and nothing selected it asks for the search at
  once.

## Lists that are loading

A list that is being fetched is not an empty list, and the popup used to say it
was: «Пусто» under a section, «Очередь пуста» on the first open, and «Ничего не
найдено» while a search was still running. All three are claims about the data
that nobody can make yet.

What replaced them:

* **A header that says what the list is and what it is doing.** «Обзор ·
  загрузка…» becomes «Обзор · 52 трека» (or «· 12 плейлистов», or «· пусто» once
  that is true), and the section name is known before the page arrives — it comes
  from the section list, not from the answer. A Russian count needs all three
  forms, so a small `plural()` picks «трек / трека / треков».
* **A line that runs.** `ProgressLine` is the frame's language for an unknown
  length: a bright piece travelling along a faint track. It is placed where the
  missing rows will appear — at the top of an empty list, and above the «Ещё» row
  when a further page is on its way — so it marks a place rather than pretending
  to be content.
* The same treatment in search (the header already said «Ищу…») and in the queue
  on the first open.

The wait itself was worth cutting, and measuring it was the only way to see why
it was 2–3 seconds: opening the popup asked for the queue, the section list, the
home blocks and the section page, and the daemon's pacing queues API calls one
behind another. Two caches remove most of it — the section list is cached in the
client for five minutes (every friendly-slug lookup used to refetch it), and the
widget fetches the sections and playlists at most once per ten minutes instead of
on every open.

## Browsing, and radio as a stream

The **Обзор** tab is a browser: the five catalog sections (`catalog.getAudio`)
sit in a scrollable row, each holding tracks and playlists from
`catalog.getSection`. Sections are paged by an opaque cursor, so `Ещё` asks for
the next page with that cursor and *appends* it — the list the user is looking at
grows rather than being replaced. Search pages by `offset` instead (`audio.search`
has no cursor and answers 30 items at a time; `next_from` never comes back, but
`offset` does move).

Playing from a browse page uses the same rule as a search result: the widget
sends the rows of what is on screen (`play tracks … --index N`), so the queue is
exactly that list and nothing has to be asked for twice.

**Radio is not a queue of tracks.** `catalog.getAudio` on the radio section
returns `radio_stations` beside the catalog rather than inside its blocks: each
station is a name, a logo and a `stream_url` pointing at the broadcaster. There
is nothing to resolve, cache or seek, so a station plays through the same path as
an uncached stream (`_play_url`): no file in the cache, an indeterminate frame,
no timeline in the popup, and MPRIS reports the station as the track with
`CanSeek` false. Starting any track, `next` or `stop` leaves radio behind. The
station list is cached for ten minutes — it barely changes, and asking for it per
open would be noise.

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
4. ~~**Auth UI** — sign-in page for both paths, warning states from error 5/9/14.~~
   done: the web and password paths both work from the panel, a sign-in clears a
   halt, and the settings page stores, switches and removes several accounts.
5. ~~**Polish** — likes, settings page, search-as-you-type.~~ done
6. **Later** — lyrics via LRCLIB, playlist editing.

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
| Likes and unlikes | `audio.add` / `audio.delete` round trip verified against the account |
| Settings in the popup | cache, prefetch, restore, and what the bar row shows |
| Search as you type | suggestions at 250 ms, results at 700 ms or on `Enter`; stale replies dropped |
| Playing a search result | queues the keys of the results on screen, one `audio.getById`, no second search |
| Browsing sections and their playlists | works; `Ещё` appends the next page |
| Radio | 100 live stations play as streams; the bar and MPRIS show the station |
| Bar row options | artwork, title, artist, controls, progress line, time, like; cover shape, scrolling titles, width presets |
| Notifications | a desktop notification per track, with a 4 KB cover, on the bus as `image-path` |
| Settings page | 14 preferences, validated in the backend, with a chip or a switch each |
| Accounts | several VK accounts stored at once, switched and removed from the settings page, added through the browser or the password grant; each keeps its own queue and likes |
| Loading states in lists | the area says it is loading instead of claiming to be empty; `ProgressLine` and the pixel check behind it |

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
* **Half of a two-way QML binding.** `text: root.query` alone makes the field
  *show* the query; without the `onTextChanged: root.query = text` half it never
  *sets* it. Every command reads `root.query`, so searching did nothing at all,
  silently, since the popup was written — the button was wired, the text simply
  never arrived.
* **mpv keeps its `pause` across `loadfile`.** A track started while the player
  was paused loaded paused and stayed silent, while this side believed it was
  playing: the sound appeared only when play was pressed again, and the state
  was inverted from then on. Starting a track now clears `pause` explicitly
  after the `loadfile`, which is the only thing that makes "a click starts a
  track" true.
* **A download that outlives its track.** The cancel event was replaced instead
  of set, so a slow download kept going after the user had chosen another track
  and, on finishing, played itself over it. The old event is set before the new
  one is installed.
* **Play during the download used to throw the download away.** `toggle_pause`
  treated "not playing yet" as "start this track again", so a press while
  fetching the file restarted the fetch — which reads as playback arriving a few
  seconds late. A press while loading is now a no-op.
* **A dbus signal needs a return value.** `@dbus_signal() def Seeked(...): ...`
  builds the signal body from the function's return value in dbus-next, so a bare
  `...` made every emit raise `SignatureBodyMismatchError` and no consumer ever
  saw a `Seeked`. It returns the position now, and the bus shows `Seeked` with
  the expected microseconds.
* **Two Enter handlers cancel each other out.** A `TextField`'s `onAccepted` and
  the panel's `returnRequested` both fire for the same key, and the field's runs
  first: the selection was thrown away by a second search before `Enter` could
  play it. One key, one owner.
* **A pointer click right after a track switch can land elsewhere.** The seek
  slider disappears while a track loads, which moves everything below it up by
  about thirty pixels. Worth knowing when a click seems to do nothing.
* **A false state is worse than no state.** Three places reported emptiness
  while they were fetching, because emptiness and "not yet known" were the same
  value. The rule taken from it: while something is loading, the interface says
  so in the place where the answer will appear.
* **`omarchy restart shell` can race and leave no shell at all.** The new
  instance starts first and refuses ("An instance of this configuration is
  already running"), then the old one exits on the IPC request, and nothing is
  left running — the bar disappears. `omarchy-shell shell ping` after every
  restart is what tells the two cases apart; the journal alone shows only the
  refusal.
* **A cached `readonly property` that reads a field inside a `var` goes stale.**
  `readonly property bool onRadio: root.radio.name !== undefined && …` stayed
  false while the object was demonstrably there, and so did the `!== null` form
  above it: in one logged expression `root.radio === null` was false while
  `root.onRadio` said false. The value is read through a function now
  (`onAir()`), the same reason `trackValue()` exists. Whatever the engine is
  doing, a derived boolean about JSON-shaped state is not something to cache.
* **A nested `Layout.fillHeight` in the wrong place, and a list that reports
  nothing when it has no height.** The popup's list was **2 px** tall, so the
  queue, the playlists, the search results and the whole settings page were never
  visible — the list is the one element meant to grow, and the height went
  elsewhere: a `Item { Layout.fillHeight: true }` inside the column of texts in
  the player row made that row report an implicit height of 64 and take 215. The
  data had been arriving correctly the whole time. Two habits came out of it:
  the popup diagnostic prints the list's own height (`list: [height,
  implicitHeight]`), and layout arithmetic is not evidence — "the card is 460, the
  body 307, so the list has about 150" was wrong about what Qt does with that
  150, and only the measured height settled it.
* **A `case` alias that shadows a verb.** The CLI's command table listed
  `pause|play|toggle)`, and `play` matches that first, so `play section all`,
  `play search …` and `play keys …` were all unreachable and sent *pause*
  instead. A bare `play` is now handled inside the `play` branch, which is what
  the alias meant. Worth a look for this pattern whenever a shell `case` grows a
  verb that is also a word in an earlier pattern.
* **A pixel-style minimum on a share.** `Math.max(1, progress)` looks like the
  neighbouring `Math.max(1, thickness)` and means something else entirely: every
  percentage painted the whole buffering frame. Only a rendered image showed it.
* **`PanelSlider` resets `liveValue` to `value` on release.** With `value` bound to
  a position that arrives once per poll, the knob jumped back to the stale position
  and forward again a second later. Seeking now holds the target locally and
  interpolates the position between polls; a drift of 15 ms in the backend was
  never the problem.
