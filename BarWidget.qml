// VK Music in the bar: artwork, title, transport, and a popup with the queue.
//
// The widget owns no VK knowledge at all. Every action and every piece of state
// goes through `bin/omarchy-vk-music`, which forwards one JSON command to the
// user service over a Unix socket and prints one JSON answer. That keeps the QML
// free of tokens, HLS, pacing and cache logic, and lets the same commands be
// driven from a terminal while debugging.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "vyorkin.vk-music"
  ipcTarget: "vyorkin.vk-music"

  // ------------------------------------------------------------- state ---
  property var status: ({})
  property var queue: []
  property var playlists: []
  property var sources: []
  property var results: []
  property string view: "queue" // queue | playlists | search
  property string query: ""
  property string busy: ""
  property string errorText: ""

  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string cli: root.pluginDir + "/bin/omarchy-vk-music"

  readonly property var track: (status && status.track !== undefined) ? status.track : null
  readonly property bool hasTrack: track !== null && track !== undefined
  readonly property bool signedIn: status.authenticated === true
  readonly property bool playing: status.playing === true && status.paused !== true
  readonly property bool loading: status.loading === true
  readonly property int position: status.position === undefined ? 0 : Number(status.position)
  readonly property int duration: status.duration === undefined ? 0 : Number(status.duration)
  readonly property int volume: status.volume === undefined ? 70 : Number(status.volume)
  readonly property string notice: String(status.notice || "")
  readonly property string halted: String(status.halted || "")

  readonly property color fg: bar && bar.barForeground !== undefined ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(root.fg, 1.5)
  readonly property color textColor: Color.popups ? Color.popups.text : Color.foreground
  readonly property color cardBg: bar && bar.background !== undefined ? bar.background : Color.background

  // The upcoming few tracks, taken from the queue the service already holds.
  readonly property var upcoming: {
    if (!queue || queue.length === 0) return []
    var start = Number(status.index === undefined ? -1 : status.index) + 1
    var out = []
    for (var i = start; i < queue.length && out.length < 5; i++) out.push(queue[i])
    return out
  }

  // Refresh while a popup is open or music is playing; otherwise idle cheaply.
  Timer {
    interval: root.playing ? 1000 : 5000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: refresh()

  // ----------------------------------------------------------------- io ---

  // One fresh Process per command: a reused object can miss its exit event and
  // then keep reporting "running", which would wedge every later action.
  Component {
    id: commandComponent
    Process {
      property var onDone
      stderr: StdioCollector { id: commandError; waitForEnd: true }
      stdout: StdioCollector { waitForEnd: true }
      onExited: function(code) {
        var answer = null
        try {
          answer = JSON.parse(text)
        } catch (parseError) {
          answer = null
        }
        root.busy = ""
        if (code === 0 && answer && answer.ok) {
          root.errorText = ""
        } else if (answer && answer.error) {
          root.errorText = String(answer.error.message || answer.error.code)
        } else {
          root.errorText = String(commandError.text || "").trim() || "команда не выполнена"
        }
        if (onDone) onDone(answer)
        destroy()
      }
    }
  }

  function call(args, onDone) {
    var process = commandComponent.createObject(root, { command: args, onDone: onDone })
    if (!process) return
    root.busy = args.join(" ")
    process.running = true
  }

  function refresh() {
    call([root.cli, "status"], function(answer) {
      if (answer && answer.ok) root.status = answer.data
      if (root.opened) root.loadQueue()
    })
  }

  function loadQueue() {
    call([root.cli, "queue"], function(answer) {
      if (answer && answer.ok) root.queue = answer.data
    })
  }

  function loadSources() {
    call([root.cli, "sections"], function(answer) {
      if (answer && answer.ok) root.sources = answer.data
    })
    call([root.cli, "home"], function(answer) {
      if (answer && answer.ok) {
        root.playlists = answer.data.playlists || []
        root.queue = root.queue
      }
    })
  }

  function runSearch() {
    var text = root.query.trim()
    if (text === "") return
    call([root.cli, "search", text], function(answer) {
      if (answer && answer.ok) root.results = answer.data.tracks || []
    })
  }

  function playSection(id, title) {
    call([root.cli, "play", "section", id, "0", "--title", title], function() { root.refresh() })
  }

  function playPlaylist(playlist) {
    call([
      root.cli, "play", "playlist", String(playlist.owner_id), String(playlist.playlist_id),
      String(playlist.access_key || ""), String(playlist.title || "")
    ], function() { root.refresh() })
  }

  function playSearchResult(index) {
    call([root.cli, "play", "search", root.query.trim(), String(index)], function() { root.refresh() })
  }

  function togglePause() {
    call([root.cli, "pause"], function() { root.refresh() })
  }

  function skipNext() {
    call([root.cli, "next"], function() { root.refresh() })
  }

  function skipPrevious() {
    call([root.cli, "previous"], function() { root.refresh() })
  }

  function signIn() {
    call([root.cli, "auth", "web"], function() { root.refresh() })
  }

  function clock(seconds) {
    var total = Math.max(0, Math.floor(Number(seconds) || 0))
    var minutes = Math.floor(total / 60)
    var rest = total % 60
    return minutes + ":" + (rest < 10 ? "0" : "") + rest
  }

  // Reading a field of the current track always goes through here. The track is
  // null until the first status arrives, and a ternary on `hasTrack` is not
  // enough: QML still evaluates the other branch while the two properties settle.
  function trackValue(name, fallback) {
    if (!root.track) return fallback
    var value = root.track[name]
    return value === undefined || value === null ? fallback : value
  }

  // ---------------------------------------------------------------- bar ---

  implicitWidth: barRow.implicitWidth
  implicitHeight: barRow.implicitHeight

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    readonly property bool showArtwork: root.setting("showArtwork", true)
    readonly property bool showText: root.setting("showText", true)
    readonly property int labelWidth: Number(root.setting("labelWidth", 180))

    BorderSurface {
      id: artwork
      width: Style.space(22)
      height: width
      radius: Style.spacing.labelGap
      visible: barRow.showArtwork
      anchors.verticalCenter: parent.verticalCenter
      color: Style.normalFillFor(root.fg, Color.accent)
      borderSpec: Border.controlSpec("normal", root.fg, Color.accent)

      Image {
        anchors.fill: parent
        anchors.margins: Style.space(2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        source: root.hasTrack && root.trackValue("thumb", "") ? root.trackValue("thumb", "") : ""
        visible: source !== ""
      }

      Text {
        anchors.centerIn: parent
        visible: !root.hasTrack || !root.trackValue("thumb", "")
        text: "󰝚"
        color: root.fg
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    Item {
      id: labelClip
      visible: barRow.showText
      width: Math.min(barRow.labelWidth, labelText.implicitWidth)
      height: labelText.height
      anchors.verticalCenter: parent.verticalCenter
      clip: true

      Text {
        id: labelText
        textFormat: Text.PlainText
        text: root.hasTrack
          ? (root.trackValue("title") + (root.trackValue("artist", "") ? "  ·  " + root.trackValue("artist", "") : ""))
          : (root.signedIn ? "VK Music" : "Войти в VK Music")
        color: root.errorText !== "" ? Color.urgent : root.fg
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.body
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Button {
      id: transportButton
      iconText: root.loading ? "󰇚" : (root.playing ? "󰏤" : "󰐊")
      foreground: root.fg
      visible: root.hasTrack
      anchors.verticalCenter: parent.verticalCenter
      horizontalPadding: Style.spacing.controlPaddingX
      verticalPadding: Style.spacing.controlPaddingY
      onClicked: root.togglePause()
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar) root.bar.showTooltip(root, root.hasTrack
      ? (root.trackValue("title") + (root.trackValue("artist", "") ? " — " + root.trackValue("artist", "") : ""))
      : "VK Music")
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        root.skipNext()
      } else if (mouse.button === Qt.RightButton && root.hasTrack) {
        root.togglePause()
      } else {
        root.toggle()
      }
    }
  }

  onOpenedChanged: {
    if (root.opened) {
      root.refresh()
      root.loadQueue()
      root.loadSources()
    }
  }

  // -------------------------------------------------------------- popup ---

  KeyboardPanel {
    id: panel
    anchorItem: barRow
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(body.implicitHeight)

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy < 0) root.skipPrevious(); else root.skipNext() }
      onActivateRequested: root.togglePause()
      onCloseRequested: root.close()
      onTextKey: function(character) {
        if (searchField.activeFocus) return
        if (character === "n") root.skipNext()
        else if (character === "p") root.skipPrevious()
      }

      Column {
        id: body
        width: parent.width
        spacing: Style.spacing.controlGap

        Row {
          width: parent.width
          spacing: Style.spacing.controlGap

          PanelSectionHeader {
            id: header
            text: "VK Music"
            foreground: root.textColor
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width - header.width - parent.spacing
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: root.errorText !== "" ? root.errorText
              : (root.halted !== "" ? root.halted : (root.loading ? "Загрузка трека…" : root.notice))
            color: root.errorText !== "" || root.halted !== "" ? Color.urgent : root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // Sign-in state, shown instead of the player when there is no session.
        Column {
          width: parent.width
          spacing: Style.spacing.controlGap
          visible: !root.signedIn

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Нужен вход в VK. Плагин возьмёт cookie p и remixsid из профиля браузера и обменяет их на токен — пароль не спрашивается."
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "Войти через браузер"
            foreground: root.textColor
            onClicked: root.signIn()
          }
        }

        // Current track.
        Row {
          width: parent.width
          spacing: Style.space(10)
          visible: root.signedIn

          BorderSurface {
            width: Style.space(64)
            height: Style.space(64)
            radius: Style.spacing.labelGap
            color: Style.normalFillFor(root.textColor, Color.accent)
            borderSpec: Border.controlSpec("normal", root.textColor, Color.accent)

            Image {
              anchors.fill: parent
              anchors.margins: Style.space(2)
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              source: root.hasTrack && root.trackValue("thumb", "") ? root.trackValue("thumb", "") : ""
              visible: source !== ""
            }

            Text {
              anchors.centerIn: parent
              visible: !root.hasTrack || !root.trackValue("thumb", "")
              text: "󰝚"
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
            }
          }

          Column {
            spacing: Style.space(3)
            width: parent.width - Style.space(74)

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: root.hasTrack ? root.trackValue("title", "Ничего не играет") : "Ничего не играет"
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              visible: root.hasTrack
              text: root.trackValue("artist", "")
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              visible: root.hasTrack && root.trackValue("duration", 0) > 0
              text: root.clock(root.position) + " / " + root.clock(root.duration)
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSlider {
          width: parent.width
          visible: root.hasTrack && root.duration > 0
          minimum: 0
          maximum: Math.max(1, root.duration)
          value: root.position
          integer: true
          bar: root.bar
          onReleased: function(value) { root.call([root.cli, "seek", String(Math.round(value))]) }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(6)
          visible: root.signedIn

          Button {
            iconText: "󰒮"
            foreground: root.textColor
            enabled: root.queue.length > 0
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.skipPrevious()
          }

          Button {
            iconText: root.loading ? "󰇚" : (root.playing ? "󰏤" : "󰐊")
            foreground: root.textColor
            enabled: root.hasTrack || root.queue.length > 0
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.togglePause()
          }

          Button {
            iconText: "󰒭"
            foreground: root.textColor
            enabled: root.queue.length > 0
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.skipNext()
          }

          Button {
            text: "×" + root.volume
            foreground: root.textColor
            onClicked: root.call([root.cli, "volume", String(root.volume >= 100 ? 0 : root.volume + 10)])
          }
        }

        // View switch.
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.signedIn

          Button {
            text: "Очередь"
            foreground: root.textColor
            selected: root.view === "queue"
            onClicked: root.view = "queue"
          }

          Button {
            text: "Плейлисты"
            foreground: root.textColor
            selected: root.view === "playlists"
            onClicked: root.view = "playlists"
          }

          Button {
            text: "Поиск"
            foreground: root.textColor
            selected: root.view === "search"
            onClicked: root.view = "search"
          }
        }

        // Queue view.
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.signedIn && root.view === "queue"

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              text: "Моя музыка"
              foreground: root.textColor
              onClicked: root.playSection("all", "Моя музыка")
            }

            Repeater {
              model: root.sources.filter(function(s) { return s.url.indexOf("section=updates") !== -1 })
              delegate: Button {
                text: modelData ? modelData.title : ""
                foreground: root.textColor
                onClicked: if (modelData) root.playSection(modelData.id, modelData.title)
              }
            }
          }

          PanelSectionHeader {
            text: "Дальше в очереди"
            foreground: root.dim
            visible: root.upcoming.length > 0
          }

          Repeater {
            model: root.upcoming
            delegate: Text {
              width: parent.width
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: modelData ? ((index + 1) + ". " + modelData.artist + " — " + modelData.title) : ""
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // Playlists view.
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.signedIn && root.view === "playlists"

          Repeater {
            model: root.playlists
            delegate: Button {
              width: parent.width
              text: modelData ? (modelData.title + (modelData.count ? "  ·  " + modelData.count : "")) : ""
              foreground: root.textColor
              onClicked: if (modelData) root.playPlaylist(modelData)
            }
          }

          Text {
            visible: root.playlists.length === 0
            text: "Плейлисты не найдены"
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
        }

        // Search view.
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.signedIn && root.view === "search"

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "Артист, трек, альбом"
            foreground: root.textColor
            accent: Color.accent
            onAccepted: root.runSearch()
          }

          Button {
            text: "Найти"
            foreground: root.textColor
            onClicked: root.runSearch()
          }

          Repeater {
            model: root.results
            delegate: Button {
              width: parent.width
              text: modelData ? (modelData.artist + " — " + modelData.title) : ""
              foreground: root.textColor
              onClicked: root.playSearchResult(index)
            }
          }
        }
      }
    }
  }
}
