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

  // One line of state for the popup header. Signing in, an empty queue and a
  // finished load are states, not errors: only a halt and a failed command are
  // painted with the urgent colour.
  readonly property string statusText: {
    if (root.errorText !== "") return root.errorText
    if (root.halted !== "") return root.halted
    if (root.loading) return "Загрузка трека…"
    if (root.notice !== "") return root.notice
    if (!root.signedIn) return "нет входа"
    if (!root.hasTrack) return "готов"
    return root.busy !== "" ? "…" : ""
  }
  readonly property bool statusUrgent: root.errorText !== "" || root.halted !== ""

  readonly property color fg: bar && bar.barForeground !== undefined ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(root.fg, 1.5)
  readonly property color textColor: Color.popups ? Color.popups.text : Color.foreground
  readonly property color cardBg: bar && bar.background !== undefined ? bar.background : Color.background

  readonly property int upcomingStart: Number(status.index === undefined ? -1 : status.index) + 1

  // The upcoming few tracks, taken from the queue the service already holds.
  readonly property var upcoming: {
    if (!queue || queue.length === 0) return []
    var out = []
    for (var i = root.upcomingStart; i < queue.length && out.length < 5; i++) out.push(queue[i])
    return out
  }

  // Refresh while a popup is open or music is playing; otherwise idle cheaply.
  //
  // One line of geometry also goes to the shell log, so a layout complaint can
  // be checked with numbers instead of a screenshot. It fires once per session
  // for the bar row and once per popup opening.
  property bool _reportedBarLayout: false
  property string _loggedTrack: ""
  onWidthChanged: reportBarLayout()

  function reportBarLayout() {
    if (root._reportedBarLayout || root.width <= 0) return
    root._reportedBarLayout = true
    console.log("[vk-music] bar layout", JSON.stringify({
      width: root.width,
      implicitWidth: root.implicitWidth,
      implicitHeight: root.implicitHeight,
      barSize: root.bar ? root.bar.barSize : -1,
      artwork: artwork.width,
      label: labelText.implicitWidth,
      transport: transportZone.width,
      labelSize: Style.font.bodySmall
    }))
  }

  Timer {
    interval: root.playing ? 1000 : 5000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    refresh()
    reportBarLayout()
  }

  // ----------------------------------------------------------------- io ---

  // One fresh Process per command: a reused object can miss its exit event and
  // then keep reporting "running", which would wedge every later action.
  //
  // The answer is parsed in the collector's own `onStreamFinished`, because
  // `text` is a property of the collector and not of the Process. Reading it
  // from `onExited` yields undefined, which is how every command silently
  // became "команда не выполнена" while the service was in fact working.
  Component {
    id: commandComponent
    Process {
      property var onDone
      stderr: StdioCollector { id: commandError; waitForEnd: true }
      stdout: StdioCollector {
        id: commandOutput
        waitForEnd: true
        onStreamFinished: {
          var raw = String(text || "").trim()
          var answer = null
          try {
            answer = raw === "" ? null : JSON.parse(raw)
          } catch (parseError) {
            answer = null
          }
          root.busy = ""
          if (answer && answer.ok) {
            root.errorText = ""
          } else if (answer && answer.error) {
            root.errorText = String(answer.error.message || answer.error.code || "ошибка")
          } else if (raw !== "") {
            root.errorText = raw
          } else {
            root.errorText = String(commandError.text || "").trim() || "команда не выполнена"
          }
          if (onDone) onDone(answer)
        }
      }
      onExited: function(code) { destroy() }
    }
  }

  function call(args, onDone) {
    var process = commandComponent.createObject(root, { command: args, onDone: onDone })
    if (!process) return
    root.busy = args.join(" ")
    process.running = true
  }

  readonly property bool streaming: status.streaming === true

  // Position display. The backend reports a position once per poll; between
  // polls the widget interpolates, and right after a seek it holds the target
  // until the backend confirms it. Without this the knob snapped back to the
  // stale reported position on release and jumped forward a second later, which
  // is what made seeking feel broken.
  property real reportedPosition: 0
  property double reportedAt: 0
  property real seekTarget: -1
  property double seekTargetAt: 0
  property real pendingSeek: -1
  property int tick: 0

  readonly property real displayPosition: {
    root.tick // reactive dependency: the ticker below advances it
    var now = Date.now()
    if (root.seekTarget >= 0 && now - root.seekTargetAt < 2500) return root.seekTarget
    if (!root.playing || root.paused) return root.reportedPosition
    var upper = root.duration > 0 ? root.duration : root.reportedPosition + 3600
    return Math.min(upper, root.reportedPosition + (now - root.reportedAt) / 1000)
  }

  // Advances the interpolated position while music plays.
  Timer {
    interval: 250
    running: root.playing && !root.paused
    repeat: true
    onTriggered: root.tick++
  }

  // A drag asks the backend to follow the hand, but not on every mouse move:
  // one seek per 250 ms is enough to hear the position and cheap for a local
  // file. A remote stream is left alone until the drag ends.
  Timer {
    id: liveSeek
    interval: 250
    repeat: false
    onTriggered: {
      if (root.pendingSeek < 0) return
      var target = root.pendingSeek
      root.pendingSeek = -1
      root.call([root.cli, "seek", String(Math.round(target))])
    }
  }

  // Volume is optimistic for the same reason as the position: the backend
  // reports it once per poll, and a drag must not be dragged back by that.
  property real volumeTarget: -1
  property double volumeTargetAt: 0
  property real pendingVolume: -1
  property real lastAudibleVolume: 70

  readonly property real displayVolume: {
    if (root.volumeTarget >= 0 && Date.now() - root.volumeTargetAt < 2000) return root.volumeTarget
    return root.volume
  }

  Timer {
    id: liveVolume
    interval: 200
    repeat: false
    onTriggered: {
      if (root.pendingVolume < 0) return
      var target = root.pendingVolume
      root.pendingVolume = -1
      root.call([root.cli, "volume", String(Math.round(target))])
    }
  }

  function setVolume(value, live) {
    var clamped = Math.max(0, Math.min(100, value))
    root.volumeTarget = clamped
    root.volumeTargetAt = Date.now()
    if (clamped > 0) root.lastAudibleVolume = clamped
    if (live) {
      root.pendingVolume = clamped
      liveVolume.restart()
      return
    }
    root.pendingVolume = -1
    liveVolume.stop()
    root.call([root.cli, "volume", String(Math.round(clamped))])
  }

  function toggleMute() {
    root.setVolume(root.displayVolume > 0 ? 0 : root.lastAudibleVolume, false)
  }

  function seekTo(target) {
    var upper = root.duration > 0 ? root.duration : target
    var clamped = Math.max(0, Math.min(upper, target))
    root.seekTarget = clamped
    root.seekTargetAt = Date.now()
    root.reportedPosition = clamped
    root.reportedAt = Date.now()
    root.tick++
    return clamped
  }

  function seekLive(target) {
    var clamped = seekTo(target)
    if (root.streaming) return
    root.pendingSeek = clamped
    liveSeek.restart()
  }

  function seekFinal(target) {
    var clamped = seekTo(target)
    root.pendingSeek = -1
    liveSeek.stop()
    root.call([root.cli, "seek", String(Math.round(clamped))])
  }

  function refresh() {
    call([root.cli, "status"], function(answer) {
      if (!answer || !answer.ok) return
      root.status = answer.data
      root.reportedPosition = Number(answer.data.position || 0)
      root.reportedAt = Date.now()
      if (root.seekTarget >= 0 && Math.abs(root.reportedPosition - root.seekTarget) < 2) {
        root.seekTarget = -1
      }
      if (root.volumeTarget >= 0 && Math.abs(Number(answer.data.volume || 0) - root.volumeTarget) < 1) {
        root.volumeTarget = -1
      }
      if (Number(answer.data.volume || 0) > 0) {
        root.lastAudibleVolume = Number(answer.data.volume)
      }
      // One line per track so the widget's own view of the state can be checked
      // from the shell log instead of a screenshot.
      var key = String((answer.data.track || {}).key || "-")
      if (root._loggedTrack !== key) {
        root._loggedTrack = key
        console.log("[vk-music] widget state", JSON.stringify({
          signedIn: root.signedIn,
          playing: root.playing,
          loading: root.loading,
          title: root.hasTrack ? root.trackValue("title") : null,
          queue: answer.data.queueLength,
          error: root.errorText
        }))
      }
    })
    if (root.opened) root.loadQueue()
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

  function playQueueAt(index) {
    call([root.cli, "jump", String(index)], function() { root.refresh() })
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

  // The height is the bar's own row height, not the content's: a taller widget
  // pushes its neighbours out of line, which is exactly what a padded Button
  // inside the row used to do.
  implicitWidth: barRow.implicitWidth + Style.space(12)
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  // The label shown in the bar. Signing in, an empty queue and a stopped
  // service are states of the widget, not errors: only a halt paints red.
  readonly property string barLabel: {
    if (root.halted !== "") return "остановлен"
    if (!root.signedIn) return "vk music"
    if (!root.hasTrack) return root.loading ? "загрузка…" : "vk music"
    return root.trackValue("title") + (root.trackValue("artist", "") ? "  ·  " + root.trackValue("artist", "") : "")
  }
  readonly property color barLabelColor: root.halted !== "" ? Color.urgent
    : (root.errorText !== "" ? root.dim : root.fg)

  // This layer must stay UNDER the row: a MouseArea declared after its siblings
  // covers them, and the transport zone would never see a click.
  MouseArea {
    id: barMouse
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar) root.bar.showTooltip(root, root.errorText !== ""
      ? ("vk music: " + root.errorText)
      : (root.halted !== "" ? root.halted : (root.hasTrack
        ? (root.trackValue("title") + (root.trackValue("artist", "") ? " — " + root.trackValue("artist", "") : ""))
        : "vk music")))
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) root.skipNext()
      else if (mouse.button === Qt.RightButton && root.hasTrack) root.togglePause()
      else root.toggle()
    }
  }

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    readonly property bool showArtwork: root.setting("showArtwork", true)
    readonly property bool showText: root.setting("showText", true)
    readonly property int labelWidth: Number(root.setting("labelWidth", 180))

    BorderSurface {
      id: artwork
      // 20 px matches the cover size the other bar players in this shell use.
      width: Style.space(20)
      height: width
      radius: Style.spacing.labelGap
      visible: barRow.showArtwork
      anchors.verticalCenter: parent.verticalCenter
      color: Style.normalFillFor(root.fg, Color.accent)
      borderSpec: Border.controlSpec("normal", root.fg, Color.accent)
      opacity: root.hasTrack ? 1.0 : 0.6

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
        font.pixelSize: Style.font.caption
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
        text: root.barLabel
        color: root.barLabelColor
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // A small urgent dot is the whole error report in the bar; the text stays
    // readable and the popup carries the reason.
    Item {
      width: Style.space(7)
      height: width
      anchors.verticalCenter: parent.verticalCenter
      visible: root.errorText !== "" || root.halted !== ""

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Color.urgent
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.open()
      }
    }

    Item {
      id: transportZone
      width: Style.space(24)
      height: root.implicitHeight
      anchors.verticalCenter: parent.verticalCenter
      visible: root.hasTrack

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: root.loading ? "󰇚" : (root.playing ? "󰏤" : "󰐊")
        color: root.fg
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.togglePause()
      }
    }
  }

  onOpenedChanged: {
    if (root.opened) {
      root.refresh()
      root.loadQueue()
      root.loadSources()
      // The sizes only exist after the panel has been laid out, so the probe
      // waits a beat instead of reading zeroes at the moment of opening.
      layoutProbe.restart()
    }
  }

  Timer {
    id: layoutProbe
    interval: 400
    repeat: false
    onTriggered: console.log("[vk-music] popup layout", JSON.stringify({
      card: [panel.contentWidth, panel.contentHeight],
      body: body.implicitHeight,
      available: [panel.availableCardWidth, panel.availableCardHeight],
      inset: panel.verticalContentInset,
      blocks: body.children.length
    }))
  }

  // -------------------------------------------------------------- popup ---
  //
  // The card has a fixed height and the list area scrolls. Sizing the card from
  // the column's implicit height looked right in theory, but that height only
  // exists after a layout pass, so the popup opened collapsed and grew a frame
  // later. A fixed card with one Flickable is boring and always correct.

  KeyboardPanel {
    id: panel
    anchorItem: barRow
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Fixed height, but not one height for everything: a signed-out card holding
    // two lines of text and one button would otherwise be mostly empty space.
    contentHeight: panel.fittedContentHeight(root.signedIn ? Style.space(460) : Style.space(200))

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

      ColumnLayout {
        id: body
        anchors.fill: parent
        spacing: Style.spacing.controlGap

        // ------------------------------------------------------ header ---
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          PanelSectionHeader {
            id: header
            text: "vk music"
            foreground: root.textColor
            Layout.alignment: Qt.AlignVCenter
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            text: root.statusText
            color: root.statusUrgent ? Color.urgent : root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.textColor; visible: root.signedIn }

        // ----------------------------------------------------- sign-in ---
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap
          visible: !root.signedIn

          Text {
            Layout.fillWidth: true
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

        // ----------------------------------------------------- player ---
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          visible: root.signedIn

          BorderSurface {
            Layout.alignment: Qt.AlignTop
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

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(2)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: root.hasTrack ? root.trackValue("title") : "Ничего не играет"
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
              visible: root.hasTrack
              text: root.trackValue("artist", "")
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              visible: root.hasTrack
              text: root.clock(root.displayPosition) + " / " + root.clock(root.duration)
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Item { Layout.fillHeight: true }
          }
        }

        PanelSlider {
          Layout.fillWidth: true
          visible: root.hasTrack && root.duration > 0
          minimum: 0
          maximum: Math.max(1, root.duration)
          value: root.displayPosition
          integer: true
          bar: root.bar
          onMoved: function(value) { root.seekLive(value) }
          onReleased: function(value) { root.seekFinal(value) }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.signedIn

          Item { Layout.fillWidth: true }

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

          Item { Layout.fillWidth: true }
        }

        // Volume has its own row: a slider squeezed next to the transport was
        // cramped, and this is the control the hand reaches for most often.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.signedIn

          Button {
            iconText: root.displayVolume <= 0 ? "󰝟" : "󰕾"
            foreground: root.textColor
            tooltipText: root.displayVolume <= 0 ? "Включить звук" : "Выключить звук"
            onClicked: root.toggleMute()
          }

          PanelSlider {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            minimum: 0
            maximum: 100
            value: root.displayVolume
            integer: true
            bar: root.bar
            onMoved: function(value) { root.setVolume(value, true) }
            onReleased: function(value) { root.setVolume(value, false) }
          }

          Text {
            Layout.preferredWidth: Style.space(38)
            Layout.alignment: Qt.AlignVCenter
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: Math.round(root.displayVolume) + "%"
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.textColor; visible: root.signedIn }

        // ------------------------------------------------------- views ---
        RowLayout {
          Layout.fillWidth: true
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

          Item { Layout.fillWidth: true }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.signedIn && root.view === "search"

          TextField {
            id: searchField
            Layout.fillWidth: true
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
        }

        Flickable {
          id: listView
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.signedIn
          clip: true
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: listColumn
            width: listView.width
            spacing: Style.space(4)

            // Queue: the sources that fill it, then the next few tracks.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.view === "queue"

              Row {
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
                delegate: Button {
                  width: listColumn.width
                  text: modelData ? ((root.upcomingStart + index + 1) + ".  " + modelData.artist + " — " + modelData.title) : ""
                  foreground: root.textColor
                  onClicked: root.playQueueAt(root.upcomingStart + index)
                }
              }

              Text {
                visible: root.queue.length === 0
                textFormat: Text.PlainText
                text: "Очередь пуста. Начни с «Моя музыка»."
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            // Playlists from the catalog.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.view === "playlists"

              Repeater {
                model: root.playlists
                delegate: Button {
                  width: listColumn.width
                  text: modelData ? (modelData.title + (modelData.count ? "  ·  " + modelData.count : "")) : ""
                  foreground: root.textColor
                  onClicked: if (modelData) root.playPlaylist(modelData)
                }
              }

              Text {
                visible: root.playlists.length === 0
                textFormat: Text.PlainText
                text: "Плейлисты не найдены"
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            // Search results.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.view === "search"

              Repeater {
                model: root.results
                delegate: Button {
                  width: listColumn.width
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
  }
}
