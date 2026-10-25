// One glyph of the bar or of the player: a Lucide shape drawn as an SVG with the theme's
// colour, over a 24 px target.
//
// It is a file because two things draw it — the row in the bar and the player's buttons —
// and it used to be an inline component of the widget, where only that one file could reach
// it. What it does not know: whose bar it sits in, whether the app is loading, or what the
// theme's foreground is. Those arrive as properties.

import QtQuick
import Quickshell
import qs.Commons
import "LucideIcons.js" as Lucide

Item {
  id: glyph

  // Lucide's name, the way the reference widget asks for its icons: `skip-back`, `play`,
  // `pause`, `skip-forward`, `heart`. `icon` stays as a fallback glyph from the icon font
  // for a name the set does not carry.
  property string name: ""
  property string icon: ""
  property bool filled: false
  // Some glyphs answer the pointer by filling in rather than by lighting a rectangle around
  // themselves: a 24 px box under a 14 px outline heart is four times the shape it points
  // at, and the box reads as a button while the heart reads as the thing being offered.
  property bool fillOnHover: false
  property real strokeWidth: 2
  // How large the drawn glyph is inside its target. The bar's own controls keep the 14 px
  // icon they have always had; the player, which is not a 30 px row, asks for a bigger one.
  property real iconSize: Style.space(14)
  property string tooltip: ""
  // The colour the glyph is drawn in when nobody says otherwise, and the one its hover
  // lightens.
  property color baseColor: Color.foreground
  property color iconColor: glyph.baseColor
  // Dimmed while a track is being fetched: the glyph says "wait", not "press me".
  property bool loading: false
  // The bar's own object, for its tooltip and its font. Null outside the bar.
  property var barItem: null

  signal clicked()
  signal wheeled(var wheel)

  readonly property bool hot: glyphArea.pressed
  readonly property bool under: glyphArea.containsMouse
  readonly property color tint: glyph.hot
    ? Color.accent
    : (glyph.under ? Qt.lighter(glyph.iconColor, 1.15) : glyph.iconColor)
  readonly property string tintRgb: "rgb(" + Math.round(glyph.tint.r * 255) + ","
    + Math.round(glyph.tint.g * 255) + "," + Math.round(glyph.tint.b * 255) + ")"
  readonly property string body: glyph.name !== "" ? (Lucide.bodies[glyph.name] || "") : ""
  // What the drawing asks for: the state the glyph was given, or the one the pointer puts
  // it in.
  readonly property bool drawnFilled: glyph.filled || (glyph.fillOnHover && (glyph.under || glyph.hot))
  readonly property string svg: glyph.body === "" ? "" : "data:image/svg+xml;utf8,"
    + encodeURIComponent(
      '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="'
      + (glyph.drawnFilled ? glyph.tintRgb : "none")
      + '" stroke="' + glyph.tintRgb + '" stroke-width="' + glyph.strokeWidth
      + '" stroke-linecap="round" stroke-linejoin="round">' + glyph.body + "</svg>")

  width: Style.space(24)
  height: parent ? parent.height : Style.space(24)
  opacity: enabled ? 1 : 0.35

  Rectangle {
    anchors.fill: parent
    // None for a glyph that fills in on hover: the highlight is the shape, and a box around
    // it would be the second thing the pointer draws.
    visible: !glyph.fillOnHover
    radius: Style.cornerRadius
    color: glyph.hot
      ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
      : (glyph.under
         ? Qt.rgba(glyph.iconColor.r, glyph.iconColor.g, glyph.iconColor.b, 0.08)
         : "transparent")
  }

  Image {
    anchors.centerIn: parent
    width: glyph.iconSize
    height: width
    visible: glyph.body !== ""
    smooth: true
    asynchronous: false
    fillMode: Image.PreserveAspectFit
    sourceSize.width: Math.ceil(width * 2)
    sourceSize.height: Math.ceil(width * 2)
    opacity: glyph.loading ? 0.45 : 1.0
    source: glyph.svg
  }

  Text {
    anchors.centerIn: parent
    textFormat: Text.PlainText
    visible: glyph.body === "" && glyph.icon !== ""
    text: glyph.icon
    color: glyph.tint
    opacity: glyph.loading ? 0.45 : 1.0
    font.family: glyph.barItem ? glyph.barItem.fontFamily : Style.font.family
    font.pixelSize: Style.space(14)
  }

  MouseArea {
    id: glyphArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: glyph.clicked()
    onWheel: function(wheel) { glyph.wheeled(wheel) }
    onEntered: if (glyph.barItem && glyph.tooltip !== "") glyph.barItem.showTooltip(glyph, glyph.tooltip)
    onExited: if (glyph.barItem) glyph.barItem.hideTooltip(glyph)
  }
}
