// A cover that may not be there.
//
// Loading and failure look the same on purpose: the tile is drawn first and the picture
// fades in over it only once it is ready, so a card never shows the surface colour where a
// cover belongs. A signed VK link that has expired used to leave exactly that — a flat
// white square, with the glyph hidden because the URL was not empty. What stays when there
// is no picture is a tint of the item's own title and its first letters.
//
// It is a file because eight places draw it — the bar's row, the rows of every list, the
// cards of every gallery, the account avatars — and it used to be an inline component of
// the widget. The tint and the monogram come from `CoverTint.js`, which the panel's own
// two helpers used to wrap.

import QtQuick
import Quickshell
import qs.Commons
import qs.Ui
import "CoverTint.js" as CoverTint

BorderSurface {
  id: tile

  property string source: ""
  // Both the monogram and the tint come from this, so it has to be the item's name: the
  // same playlist keeps one colour between opens, and no id has to be hashed.
  property string title: ""
  // The corner mark says what kind of item this is — a note for a playlist or a track, a
  // person for a profile. Empty leaves the tile wordless.
  property string mark: "󰝚"
  property string glyphFamily: Style.font.family
  // The surface the tile is mixed into, and the two colours of the fallback. The panel
  // passes the theme's own values; a tile outside the popup gets the plain theme.
  property color surface: Color.popups && Color.popups.background !== undefined
    ? Color.popups.background
    : Color.background
  property color markColor: Qt.darker(Color.foreground, 1.5)
  property color monogramColor: Color.popups ? Color.popups.text : Color.foreground
  // The picture sits a pixel or two inside the surface: a Rectangle cannot clip its
  // children to a radius, so the frame has to show around it instead.
  property real inset: 0
  // How many pixels the picture is asked for. The callers pass the width the tile will
  // have, because the tile starts at zero and a size that grows would ask the network for
  // the same cover twice — once at 0 (the original) and once at the final width. Twice the
  // width keeps it sharp on a scaled display.
  property real decodeSize: 0

  readonly property bool shown: picture.status === Image.Ready
  readonly property real side: Math.min(width, height)
  readonly property string monogram: CoverTint.monogram(title)
  // The tint belongs to the fallback, not to the frame: a picture keeps the neutral rim it
  // has always had, and only the tile that stands in for it is coloured.
  readonly property color tint: {
    var hue = CoverTint.hue(tile.title)
    var base = Qt.hsla(hue / 360, 0.55, 0.5, 1)
    return Qt.tint(tile.surface, Qt.rgba(base.r, base.g, base.b, 0.24))
  }
  // Below about forty pixels there is no room for two marks: the glyph alone says what the
  // row is, the way it always has in the small covers. A tile with nothing to abbreviate
  // keeps the large centred glyph at any size.
  readonly property bool roomy: tile.side >= Style.space(40)
  readonly property bool labeled: tile.roomy && tile.monogram !== ""
  // Below eighty pixels the corner mark is a speck beside the letters rather than a second
  // word, so a small tile keeps the monogram alone. A circle has no corners either: the
  // bottom-right of the square is the part its radius cuts away.
  readonly property bool round: tile.radius * 2 >= tile.side - 1
  readonly property bool cornerMark: tile.labeled && !tile.round && tile.side >= Style.space(80)

  radius: Style.spacing.labelGap
  color: tile.shown ? tile.surface : tile.tint

  Image {
    id: picture
    anchors.fill: parent
    anchors.margins: tile.inset
    source: tile.source
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    smooth: true
    // A 600 px cover decoded for a 160 px card is memory for nothing: the tile says what it
    // needs, and nothing is asked for while that is unknown.
    sourceSize.width: tile.decodeSize > 0 ? Math.ceil(tile.decodeSize * 2) : 0
    sourceSize.height: tile.decodeSize > 0 ? Math.ceil(tile.decodeSize * 2) : 0
    opacity: tile.shown ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
  }

  Text {
    anchors.centerIn: parent
    visible: !tile.shown && tile.labeled
    text: tile.monogram
    textFormat: Text.PlainText
    color: tile.monogramColor
    opacity: 0.8
    font.family: tile.glyphFamily
    font.bold: true
    font.pixelSize: Math.round(tile.side * 0.34)
    font.letterSpacing: Math.round(tile.side * 0.02)
  }

  Text {
    anchors.centerIn: parent
    visible: !tile.shown && !tile.labeled && tile.mark !== ""
    text: tile.mark
    textFormat: Text.PlainText
    color: tile.markColor
    font.family: tile.glyphFamily
    font.pixelSize: Math.max(Style.font.caption, Math.round(tile.side * (tile.roomy ? 0.34 : 0.5)))
  }

  Text {
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Math.round(tile.side * 0.07)
    visible: !tile.shown && tile.cornerMark
    text: tile.mark
    textFormat: Text.PlainText
    color: tile.markColor
    opacity: 0.45
    font.family: tile.glyphFamily
    font.pixelSize: Math.round(tile.side * 0.15)
  }
}
