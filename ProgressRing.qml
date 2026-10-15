// Thin arc around a cover: how much of the current track has been fetched.
//
// The point of a ring rather than a bar is that it needs no layout: it is drawn
// on top of artwork that is already there, so nothing shifts, nothing blinks and
// no second element appears in a bar row that is 30 px tall. While the fill
// grows the cover stays recognisable underneath.
//
// `indeterminate` is for a stream whose length is unknown (the cache is off):
// a fixed arc spins instead of a progress that would be a guess.
import QtQuick
import qs.Commons

Item {
  id: root

  // 0..1. Ignored while `indeterminate`.
  property real progress: 0
  property bool indeterminate: false
  property color color: Color.accent
  property real thickness: Math.max(1, Math.round(Math.min(width, height) * 0.09))
  // Where the arc starts: -90 is the top of the circle, and the fill runs
  // clockwise from there.
  property real startAngle: -90

  readonly property real sweep: root.indeterminate
    ? 90
    : Math.max(0.5, Math.min(360, root.progress * 360))

  onProgressChanged: canvas.requestPaint()
  onIndeterminateChanged: canvas.requestPaint()
  onColorChanged: canvas.requestPaint()
  onThicknessChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var size = Math.min(width, height)
      if (size <= 0) return
      var centre = size / 2
      var radius = Math.max(root.thickness / 2, centre - root.thickness / 2)
      var toRadians = Math.PI / 180

      ctx.strokeStyle = root.color
      ctx.lineWidth = root.thickness
      ctx.lineCap = "round"
      ctx.beginPath()
      ctx.arc(centre, centre, radius, root.startAngle * toRadians,
              (root.startAngle + root.sweep) * toRadians, false)
      ctx.stroke()
    }
  }

  // A rotation, not repeated repainting: the arc itself never changes while the
  // real length is unknown.
  RotationAnimation on rotation {
    running: root.indeterminate
    from: 0
    to: 360
    duration: 900
    loops: Animation.Infinite
  }
}
