// An indeterminate line: the same language the cover's frame uses when the
// length is unknown — a bright piece travelling along a faint track.
//
// It marks the place where missing content will appear, which is why the caller
// puts it at the top of an empty list and above the "Ещё" row when a further page
// is on its way. Nothing here pretends to be content: it is a state, and it is
// the only thing on screen that says what is happening.
import QtQuick

Item {
  id: root

  property color color: "white"
  property color trackColor: Qt.rgba(color.r, color.g, color.b, 0.28)
  // A known length fills from the left; an unknown one travels. The travelling
  // piece is the default because that is what a loading list needs.
  property real progress: 0
  property bool indeterminate: true
  property real thickness: 2
  // How much of the width the bright piece covers, 0..1.
  property real piece: 0.3
  // Position of the travelling piece, 0..1, driven by the animation below.
  property real phase: 0

  implicitHeight: thickness
  implicitWidth: 120

  onProgressChanged: canvas.requestPaint()
  onIndeterminateChanged: canvas.requestPaint()
  onColorChanged: canvas.requestPaint()
  onTrackColorChanged: canvas.requestPaint()
  onThicknessChanged: canvas.requestPaint()
  onPieceChanged: canvas.requestPaint()
  onPhaseChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    // A piece of the line, drawn as a capsule: two end circles joined by the
    // straight part, which keeps a piece narrower than its own radius round.
    function piece(ctx, from, length) {
      var h = Math.max(1, root.thickness)
      var radius = h / 2
      var y = (height - h) / 2 + radius
      if (length <= 0) return
      var end = from + length
      ctx.beginPath()
      ctx.arc(from + radius, y, radius, 0, Math.PI * 2)
      ctx.arc(end - radius, y, radius, 0, Math.PI * 2)
      ctx.rect(from + radius, y - radius, Math.max(0, length - 2 * radius), h)
      ctx.closePath()
      ctx.fill()
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (width <= 0 || height <= 0) return

      ctx.fillStyle = root.trackColor
      piece(ctx, 0, width)

      ctx.fillStyle = root.color
      if (!root.indeterminate) {
        // A share of the width, clamped to it. The minimum is in pixels, not a
        // share: `Math.max(1, progress)` would mean "always the whole line".
        var share = Math.min(1, Math.max(0, root.progress))
        piece(ctx, 0, Math.min(width, Math.max(2, share * width)))
        return
      }
      // The bright piece runs in from the left, out at the right and starts over,
      // so it enters and leaves instead of appearing in the middle.
      var span = Math.max(2, Math.min(width, root.piece * width))
      var start = Math.max(0, Math.min(width, root.phase * (width + span) - span))
      piece(ctx, start, Math.min(span, width - start))
    }
  }

  NumberAnimation on phase {
    running: root.visible && root.indeterminate
    from: 0
    to: 1
    duration: 1300
    loops: Animation.Infinite
  }
}
