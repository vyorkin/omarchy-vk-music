# VK Music for Omarchy

**[Русская версия](README.ru.md)** · English

VK Music in the Omarchy bar: artwork, title and transport in the bar, and a panel with the
queue, your own music, other people's playlists and the radio. Playback goes through mpv,
so the media keys and any MPRIS client work without extra setup.

| Queue | Gallery | Settings |
|---|---|---|
| ![Queue](docs/screenshots/queue.png) | ![Gallery](docs/screenshots/gallery.png) | ![Settings](docs/screenshots/settings.png) |

## What it does

- **The bar row** — cover, title and artist, previous / play-pause / next, a progress line
  and a like button. Every piece can be turned off, and the row remembers what you chose.
- **The queue** — the tracks you started, in order. Rows can be jumped to, removed, and a
  right click puts a track next in line or at the end.
- **Your music and the catalogue** — «Моя музыка», the sections VK offers, and any
  playlist: cover gallery or compact rows, whichever you prefer.
- **Other people's playlists** — friends, anyone by link, and a playlist search.
- **Radio** — the stations VK links to, played straight from their own streams.
- **Likes** — a heart on every row and in the player. On VK a like IS «Моя музыка», so the
  two can never disagree.
- **Search** — suggestions as you type, results after a pause, tracks or playlists.
- **Keyboard** — `hjkl` or arrows to move, `Enter` to play, `/` to filter the open list,
  `m` to switch gallery and list, `[`/`]` for the tabs, `⇧H`/`⇧L` for the sections.
- **Eight languages** — English (default), German, Spanish, French, Japanese, Chinese,
  Ukrainian and Russian, switched in the settings.

## Requirements

```bash
omarchy pkg add python mpv ffmpeg
```

## Install

Adding the plugin only puts the widget in place. The backend — a Python service with its
own virtualenv — is installed in a second step, because a plugin must never run an installer
just by being enabled:

```bash
omarchy plugin add https://github.com/vyorkin/omarchy-vk-music --enable
cd ~/.config/omarchy/plugins/vyorkin.vk-music
./install.sh --backend-only
```

The second command builds the backend into a virtualenv under
`~/.local/share/omarchy-vk-music`, installs the systemd user service and starts it. Without
it the panel opens with an empty state and the bar says the service is not running. Re-run
the same command after changing the backend.

## Signing in

VK's audio API has no public OAuth flow, so the default path does what a browser does: it
takes the `p` and `remixsid` cookies from your browser profile and exchanges them for a
token — no password is asked for and none is stored. The password path below does ask for
one, keeps it only in the daemon's memory until VK answers, and never writes it down.

1. Sign in to <https://vk.ru> in Firefox, Zen or LibreWolf.
2. Open the panel and press **Sign in with the browser**, or run
   `omarchy-vk-music auth web` in a terminal.
3. The session ends when VK ends it; finishing all sessions in VK's settings logs the
   plugin out too.

### Several accounts

The panel keeps as many VK accounts as you sign in, and each one has its own queue,
position, likes and recent searches. Preferences and the volume stay shared, because they
belong to the panel and the speakers rather than to an account.

- **Settings → Accounts** lists every stored account. The active one is marked; another
  one is one click away and becomes active with its own queue restored, paused.
- **Add an account** offers the browser path (the session Firefox, Zen or LibreWolf is
  signed into now) and the password path (login, password, then the SMS or app code).
  The password path is what makes a second account possible without signing out of the
  first one in the browser.
- **Remove** forgets the account, its token, its queue and its likes. Removing the active
  account hands the session to the next stored one; removing the last one returns the
  panel to the sign-in screen.

Adding or switching an account stops playback: the resolved stream URL belongs to the old
session, and the tracks in the old queue are not the new account's. `omarchy-vk-music
accounts`, `account switch <id>` and `account remove <id>` do the same from a terminal.

The tokens and cookies live in `~/.config/omarchy-vk-music/accounts.json` with mode 600.
They are never written to the repository, the journal, or anywhere else.

## Controls

| Where | What |
|---|---|
| Bar, left click | open the panel |
| Bar, right click | pause or resume |
| Bar, middle click | next track |
| Bar, wheel | volume |
| `Space` | pause |
| `j` `k` / `↑` `↓` | move the cursor |
| `h` `l` | sideways in the gallery |
| `Enter` | play what is selected |
| `/` | filter the open list |
| `m` | gallery or list |
| `[` `]` | previous / next tab |
| `⇧H` `⇧L` | previous / next section |
| `Tab` | from a field into the list |
| `Esc` | one step back |
| `Backspace` | one level back |

## Terminal

```bash
omarchy-vk-music status                 # what is playing, queue length, preferences
omarchy-vk-music play section all       # start with «Моя музыка»
omarchy-vk-music search radiohead       # find and print tracks
omarchy-vk-music play search radiohead  # play the results
omarchy-vk-music next
omarchy-vk-music volume 60
omarchy-vk-music queue remove 3
omarchy-vk-music prefs language=de
omarchy-vk-music auth status
omarchy-vk-music accounts
omarchy-vk-music account switch 213706100
omarchy-vk-music account remove 213706100
```

Every command prints one line of JSON. `--pretty` formats it.

## Troubleshooting

```bash
systemctl --user status omarchy-vk-music
journalctl --user -u omarchy-vk-music -f
omarchy-vk-music auth status
```

The plugin stops rather than retries when VK asks for a captcha or starts rate limiting —
that is deliberate: hammering an unofficial endpoint is how accounts get blocked. Restart
the service after waiting, or sign in again.

If the widget disappears from the bar, `omarchy restart shell`, then
`omarchy plugin enable vyorkin.vk-music --after omarchy.clock`.

## Storage

| Path | What |
|---|---|
| `~/.config/omarchy-vk-music/accounts.json` | every account's token and cookies, active marker, mode 600 |
| `~/.config/omarchy-vk-music/state.json` | per-account queue, position, likes and history; shared volume and preferences |
| `~/.cache/omarchy-vk-music/audio` | downloaded tracks, 256 MiB by default |

## Uninstall

```bash
./uninstall.sh           # keeps your sign-in and preferences
./uninstall.sh --purge   # removes those too
```

## Legal

VK's audio API is unofficial and undocumented. This plugin uses it the way a mobile client
does — one identity, paced requests, no scraping — but the risk to your account is yours.
Nothing here downloads or shares music; the cache exists so that seeking in a track you are
already playing is instant.

## Credits

- [Lucide](https://lucide.dev) icons, ISC licence, vendored in `LucideIcons.js`.
- [vornashev/omarchy-yandex-music](https://github.com/vornashev/omarchy-yandex-music), whose
  structure — a Python backend, mpv over a socket, MPRIS, a QML panel — this plugin follows.

MIT licence.
