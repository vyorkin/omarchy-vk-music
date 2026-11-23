# Live verification of the plugin

Run this after changing any `.qml` or `.js` file. The shell watches
`~/.config/omarchy/plugins/vyorkin.vk-music/`, but a hot reload re-creates the
component from the cached source: a journal line
`Local plugin changed, reloading: vyorkin.vk-music` is not proof that the new
code is live. A restart is.

## Install the files

Full install (backend, service, QML):

```sh
./install.sh
```

QML/JS only — copy every changed file:

```sh
install -m 644 BarWidget.qml BackendClient.qml \
  ~/.config/omarchy/plugins/vyorkin.vk-music/
```

`install.sh` also copies the QML and restarts the backend; for a pure QML change
the copy above plus the restart below is enough.

## Restart and read the journal

```sh
omarchy restart shell
journalctl --user -b --since '1 minute ago' \
  | rg 'vk-music|BarWidget.qml\[|BackendClient.qml\['
```

Done when `[vk-music] widget state` reports the expected `signedIn` and no QML
error names a changed file. A warning's `file.qml[line:col]` is the source
position of the running copy; compare it with the file on disk.

## Inspect or drive the plugin over IPC

```sh
qs -p /usr/share/omarchy/shell ipc show
qs -p /usr/share/omarchy/shell ipc call vyorkin.vk-music open
```

`-p /usr/share/omarchy/shell` is the path of the running shell; without it
`qs ipc` looks at the default instance and finds no target.
