# VK Music for Omarchy

A native VK Music player in the [Omarchy](https://omarchy.org/) bar. Music
plays in the background through `mpv`; the browser is only needed to sign in —
and only as a source of two cookies.

Status: working prototype. Playback, queue, search, playlists and MPRIS are
done; the interface is deliberately small (bar widget plus a popup with the
queue). Design notes and the verified API facts live in
[`docs/design.md`](docs/design.md).

## How it works

```
BarWidget.qml  ──>  bin/omarchy-vk-music  ──>  omarchy-vk-music.service
(artwork, title,        (one JSON command         (Python: VK session,
 transport, popup)       over a Unix socket)       cache, mpv, MPRIS)
```

The widget knows nothing about VK: it runs the CLI and reads JSON. The service
owns the session, the API client, the download cache, one `mpv` process and the
MPRIS identity, so the media keys work without any Hyprland configuration.

## Requirements

`python`, `mpv`, `ffmpeg`. Install with `omarchy pkg add python mpv ffmpeg`.

## Install

```bash
./install.sh
```

This creates a virtualenv in `~/.local/share/omarchy-vk-music`, installs the CLI
to `~/.local/bin`, writes the user unit, starts it, and enables the plugin in
the bar.

## Sign in

The player reads the cookies `p` and `remixsid` from your Firefox-family
browser profile (Firefox, Zen, LibreWolf) and exchanges them for a VK web
token. No password, no new device login, no captcha.

- From the widget: click it and press **Войти через браузер**.
- From a terminal: `omarchy-vk-music auth web`, or `omarchy-vk-music auth web
  --no-browser` to paste the cookies from DevTools yourself.

The token is stored in `~/.config/omarchy-vk-music/token.json` together with the
cookies, mode 600, because the token is refreshed from those cookies. That file
is a live session: never commit it and never share it. Revoking it means
"завершить все сессии" in VK's security settings.

A password login exists as a fallback (`omarchy-vk-music auth mobile`). It is not
the default: VK throttles password logins, its token dies after about three
hours, and it can ask for a captcha and an SMS code.

## Controls

| Where | Action |
| --- | --- |
| Bar artwork or title, left click | Open the popup |
| Bar, right click | Play / pause |
| Bar, middle click | Next track |
| Media keys | Through MPRIS, no configuration needed |
| `Space` in the popup | Play / pause |
| `N` / `P` in the popup | Next / previous |

## Commands

Everything the widget does is available from a terminal:

```bash
omarchy-vk-music status                 # the whole state as JSON
omarchy-vk-music play section all       # queue "Моя музыка" and start
omarchy-vk-music search radiohead --play
omarchy-vk-music next | previous | pause
omarchy-vk-music seek 90 | volume 40 | volume +10
omarchy-vk-music shuffle on | repeat all
omarchy-vk-music home                   # sections and playlists
omarchy-vk-music cache stats | cache clear
omarchy-vk-music session                # sign-in state, without secrets
```

## Troubleshooting

```bash
systemctl --user status omarchy-vk-music.service
journalctl --user -u omarchy-vk-music.service -n 100
omarchy-vk-music status --pretty
```

If the widget shows a VK error and stops responding to actions, the service has
halted itself on purpose: it stops all traffic when VK answers with a rejected
token, flood control or a captcha demand. Fix the cause (usually sign in again),
then `systemctl --user restart omarchy-vk-music.service`.

## Storage

| Path | Contents |
| --- | --- |
| `~/.config/omarchy-vk-music/token.json` | token, cookies, client identity, expiry (600) |
| `~/.config/omarchy-vk-music/state.json` | queue, position, volume, preferences (600) |
| `~/.cache/omarchy-vk-music/audio` | finished tracks, LRU, 256 MiB cap |

Sign-in and preferences survive uninstalling; `uninstall.sh --purge` removes
them too.

## Uninstall

```bash
~/.config/omarchy/plugins/vyorkin.vk-music/uninstall.sh          # keeps sign-in
~/.config/omarchy/plugins/vyorkin.vk-music/uninstall.sh --purge  # removes it
```

## Legal

Unofficial. VK's audio API is not public and its use is against VK's terms; your
account is the one at risk. The plugin is built to behave like the VK web player
— same session, same address, browser-like requests, no telemetry, and a full
stop instead of retries when VK pushes back — but that is a mitigation, not a
guarantee.

Licence: MIT.
