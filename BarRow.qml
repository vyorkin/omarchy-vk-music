// The row in the bar: the cover, the label, the transport, the heart, and the progress line
// that runs under them.
//
// It is a component because the row is a thing of its own — it reads a track and a set of
// options and it draws; it does not know what a queue is, where a section came from, or how
// a command travels. The panel keeps every one of those and hands the row what it needs.
//
// The properties are one per fact rather than one object of options: a misspelt object key
// reads as `undefined`, which is `false`, which is an element of the bar quietly gone —
// exactly the kind of failure nobody can see and nobody reports. A misspelt property does
// not compile.

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "i18n.js" as I18n
import "LucideIcons.js" as Lucide

Item {
  id: row

  // ------------------------------------------------------------- the track ---
  property string language: "en"
  property var track: null
  property var radio: ({})
  property bool onAir: false
  property bool signedIn: false
  property bool loading: false
  property bool halted: false
  property bool playing: false
  property bool buffering: false
  property bool bufferIndeterminate: false
  property real bufferProgress: 0
  property real position: 0
  property int duration: 0
  property bool liked: false
  // What the wheel moves, and what it moves away from.
  property int volume: 0

  readonly property bool hasTrack: track !== null && track !== undefined

  // ----------------------------------------------------------- the options ---
  property bool showArtwork: true
  property bool showTitle: true
  property bool showArtist: true
  property bool showControls: true
  property bool showProgress: true
  property bool showTime: false
  property bool showLike: false
  property string coverShape: "rounded"
  property string longTitleMode: "scroll"
  property int labelWidth: 180
  property int marqueePause: 1600
  property int marqueeSpeed: 70

  // ------------------------------------------------------------- the paint ---
  property var barItem: null
  property color foreground: "white"
  property color dimmed: "grey"
  property color labelColor: foreground
  // The tooltip's sentence, decided by the panel: it is the panel that knows an error from
  // a halt from a track.
  property string message: ""
  // Whether the urgent dot is up. An error and a halt are the panel's to tell apart.
  property bool complaint: false

  signal open()
  signal next()
  signal previous()
  signal pauseToggle()
  signal likeToggle()
  // A wheel notch, already applied to the volume the row was given.
  signal wheel(int value)

  function trackValue(name, fallback) {
    if (!row.hasTrack) return fallback
    var value = row.track[name]
    return (value === undefined || value === null) ? fallback : value
  }

  function radioValue(name, fallback) {
    if (row.radio === null || row.radio === undefined) return fallback
    var value = row.radio[name]
    return (value === undefined || value === null) ? fallback : value
  }

  function t(text) {
    return I18n.translate(row.language, text)
  }

  // A row with nothing in it has no width, and a widget of zero width cannot be clicked.
  // Cover, label and every glyph can be switched off, and then a stopped player vanished
  // from the bar entirely — leaving no way back to the panel. One glyph stands in.
  readonly property bool empty: {
    if (row.showArtwork) return false
    if (row.showTitle || row.showArtist) return false
    if (row.showTime && row.hasTrack && !row.onAir) return false
    if (row.showControls && row.hasTrack) return false
    if (row.showLike && row.hasTrack && !row.onAir) return false
    if (row.showProgress && row.hasProgress) return false
    return true
  }

  readonly property bool hasProgress: row.hasTrack && !row.onAir && row.duration > 0
  readonly property real progress: row.hasProgress
    ? Math.max(0, Math.min(1, row.position / row.duration)) : 0

  // What the row says. A halt wins over everything, because it is the thing the reader
  // cannot guess; then the station's name, which has no track behind it; then the track the
  // two switches chose; then the panel's own word for "nothing yet".
  readonly property string label: {
    if (row.halted) return row.t("остановлен")
    if (!row.signedIn) return "vk music"
    if (row.onAir) return String(row.radioValue("name", row.t("радио")))
    if (!row.hasTrack) return row.loading ? row.t("загрузка…") : "vk music"
    var title = row.showTitle ? row.trackValue("title", "") : ""
    var artist = row.showArtist ? row.trackValue("artist", "") : ""
    if (title !== "" && artist !== "") return title + "  ·  " + artist
    if (title !== "") return title
    if (artist !== "") return artist
    return "vk music"
  }

  readonly property string artworkSource: row.onAir
    ? String(row.radioValue("logo", ""))
    : (row.hasTrack ? String(row.trackValue("thumb", "")) : "")
  readonly property string artworkTitle: row.onAir
    ? String(row.radioValue("name", ""))
    : (row.hasTrack ? String(row.trackValue("artist", "")) : "")

  implicitWidth: rowContent.implicitWidth
  implicitHeight: Style.bar.sizeHorizontal

  // What the bar row actually came out as, once, into the journal: the question "why is this
  // widget that wide" is otherwise only answerable by reading forty bindings, and the bar is
  // shared with every other widget in the shell.
  function report() {
    if (row.width <= 0) return
    console.log("[vk-music] bar layout", JSON.stringify({
      width: row.width,
      implicitWidth: row.implicitWidth,
      implicitHeight: row.implicitHeight,
      barSize: row.barItem ? row.barItem.barSize : -1,
      artwork: artwork.width,
      label: labelText.implicitWidth,
      transport: transportZone.width,
      labelSize: Style.font.bodySmall,
      // A bar widget of zero width is invisible and cannot be clicked; the idle note is the
      // fallback that keeps a stopped, option-less row reachable.
      empty: row.empty,
      idle: [idleGlyph.visible, idleGlyph.width, idleGlyph.height],
      shown: [row.showArtwork, row.showTitle, row.showArtist, row.showTime, row.showControls]
    }))
  }

  // This layer must stay UNDER the row: a MouseArea declared after its siblings covers
  // them, and the transport would never see a click.
  MouseArea {
    id: rowMouse
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (row.barItem) row.barItem.showTooltip(row, row.message)
    onExited: if (row.barItem) row.barItem.hideTooltip(row)
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) row.next()
      else if (mouse.button === Qt.RightButton && row.hasTrack) row.pauseToggle()
      else row.open()
    }
    // The wheel is the volume, as it is on most bars: one notch, five percent. The panel
    // sends the step live and writes the value down once the wheel stops.
    onWheel: function(wheel) {
      var delta = wheel.angleDelta.y > 0 ? 5 : -5
      row.wheel(Math.round(row.volume) + delta)
      wheel.accepted = true
    }
  }

  Row {
    id: rowContent
    anchors.centerIn: parent
    spacing: Style.space(6)

    // Kept even when the row is otherwise empty: this is the way back to the panel, so it
    // must exist at the smallest configuration as well.
    BarGlyph {
      id: idleGlyph
      visible: row.empty
      height: row.implicitHeight
      // Lucide has no bare «music» body; the icon font glyph is the fallback that keeps this
      // visible even if the set changes again.
      name: "list-music"
      icon: "󰝚"
      filled: false
      tooltip: "VK Music"
      onClicked: row.open()
    }

    BorderSurface {
      id: artwork
      // 20 px matches the cover size the other bar players in this shell use.
      width: Style.space(20)
      height: width
      // At twenty pixels a four-pixel corner is a fifth of the picture, so the frame's
      // rounding and the picture's square corners read as two shapes fighting. The rounding
      // is proportional here, and the picture sits one pixel in.
      radius: row.coverShape === "circle" ? width / 2
        : (row.coverShape === "square" ? 0 : Style.space(2))
      visible: row.showArtwork
      anchors.verticalCenter: parent.verticalCenter
      color: Style.normalFillFor(row.foreground, Color.accent)
      borderSpec: row.buffering
        ? Border.none()
        : Border.controlSpec("normal", row.foreground, Color.accent)
      opacity: row.hasTrack ? 1.0 : 0.6

      CoverTile {
        anchors.fill: parent
        anchors.margins: Style.space(1)
        radius: Math.max(0, artwork.radius - Style.space(1))
        inset: 0
        glyphFamily: row.barItem ? row.barItem.fontFamily : Style.font.family
        markColor: row.foreground
        decodeSize: Style.space(20)
        source: row.artworkSource
        title: row.artworkTitle
      }

      // The ring rides on the artwork that is already there: no layout shift and no second
      // element in a row that is 30 px tall. While it is filling, the artwork's own border
      // steps aside so only one outline is visible.
      ProgressFrame {
        anchors.fill: parent
        visible: row.buffering
        progress: Math.max(0, row.bufferProgress)
        indeterminate: row.bufferIndeterminate
        color: Color.accent
        cornerRadius: artwork.radius
        thickness: Math.max(1.5, Style.space(2))
      }
    }

    Item {
      id: labelClip
      visible: row.showTitle || row.showArtist
      width: Math.min(row.labelWidth, labelText.implicitWidth)
      height: labelText.height
      anchors.verticalCenter: parent.verticalCenter
      clip: true

      Text {
        id: labelText
        textFormat: Text.PlainText
        text: row.label
        color: row.labelColor
        font.family: row.barItem ? row.barItem.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter

        readonly property bool needsScroll: implicitWidth > labelClip.width
        // How far the text has to travel for its end to come into view: exactly the
        // overflow, not a pixel more. Walking to the text's own width used to carry it off
        // the edge, which left the label empty until the next pass — a title that looked
        // broken rather than long.
        readonly property real travel: Math.max(0, implicitWidth - labelClip.width)

        // The text is placed from an animated offset instead of animating `x` itself: an
        // animation on `x` discards the binding that puts the text back at the start, so a
        // clip that stopped scrolling kept its last position — off the edge — and a
        // perfectly short title looked like an empty label until another long one came.
        property real scrollOffset: 0
        x: -scrollOffset

        // A new title starts at its beginning, and one that fits stays there.
        onTextChanged: scrollOffset = 0
        onNeedsScrollChanged: if (!needsScroll) scrollOffset = 0

        // Both ends of the walk get a pause: the beginning while it is there, and the end
        // once it has arrived. With the text stopping inside the label instead of past it,
        // the field is never empty and neither end is missed.
        SequentialAnimation on scrollOffset {
          running: row.longTitleMode === "scroll" && labelText.needsScroll
          loops: Animation.Infinite

          PauseAnimation { duration: row.marqueePause }

          NumberAnimation {
            from: 0
            to: labelText.travel
            duration: Math.max(400, labelText.travel / Math.max(1, row.marqueeSpeed) * 1000)
            easing.type: Easing.Linear
          }

          PauseAnimation { duration: row.marqueePause }

          // Back to the beginning: a jump, made to read as a loop rather than a glitch by
          // the pause in front of it.
          PropertyAction { target: labelText; property: "scrollOffset"; value: 0 }
        }
      }
    }

    // The time is a caption in the same dim colour the popup uses for them.
    Text {
      id: barTime
      visible: row.showTime && row.hasTrack && !row.onAir
      textFormat: Text.PlainText
      text: I18n.clock(row.position) + " / " + I18n.clock(row.duration)
      color: Qt.rgba(row.foreground.r, row.foreground.g, row.foreground.b, 0.55)
      font.family: row.barItem ? row.barItem.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }

    // A small urgent dot is the whole error report in the bar; the text stays readable and
    // the popup carries the reason.
    Item {
      width: Style.space(7)
      height: width
      anchors.verticalCenter: parent.verticalCenter
      visible: row.complaint

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Color.urgent
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: row.open()
      }
    }

    Row {
      id: transportZone
      visible: row.hasTrack && row.showControls
      height: row.implicitHeight
      anchors.verticalCenter: parent.verticalCenter
      // The reference leaves two pixels between its transport buttons.
      spacing: Style.space(2)

      // The same three glyphs the reference widget shows, in the same shape: previous, play
      // or pause, next — 24 px each, nothing drawn between them.
      BarGlyph {
        name: "skip-back"
        filled: true
        icon: "󰒮"
        tooltip: row.t("Предыдущий трек")
        onClicked: row.previous()
      }

      BarGlyph {
        // The glyph never turns into a downloader: play stays play, dimmed while the track
        // is being fetched.
        name: row.playing ? "pause" : "play"
        filled: true
        icon: row.playing ? "󰏤" : "󰐊"
        tooltip: row.playing ? row.t("Пауза") : row.t("Играть")
        onClicked: row.pauseToggle()
      }

      BarGlyph {
        name: "skip-forward"
        filled: true
        icon: "󰒭"
        tooltip: row.t("Следующий трек")
        onClicked: row.next()
      }
    }

    // The heart sits after the transport, at the right end: it is not a control of the
    // sound, it is a statement about the track.
    BarGlyph {
      visible: row.showLike && row.hasTrack && !row.onAir
      anchors.verticalCenter: parent.verticalCenter
      name: "heart"
      fillOnHover: true
      filled: row.liked
      icon: row.liked ? "󰋑" : "󰋕"
      iconColor: row.liked ? Color.accent : row.foreground
      tooltip: row.liked ? row.t("Убрать из моей музыки") : row.t("В мою музыку")
      onClicked: row.likeToggle()
    }
  }
}
