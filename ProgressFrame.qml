// The border of a cover, filling clockwise as a track is fetched.
//
// Not a ring: a ring ignores the shape the cover already has. This walks the
// rounded rectangle itself — starting at the middle of the top edge, down the
// right side, along the bottom and back up the left — so the progress is drawn
// on the very border of the artwork, in the artwork's own corner radius. Nothing
// moves, nothing appears next to the cover, and the outline that is left reads
// as "how much is still missing".
//
// The faint whole frame is drawn first, the filled part on top of it: that is
// what makes it read as a frame filling up rather than a line growing.
import QtQuick
import qs.Commons

Item {
  id: root

  // 0..1. Ignored while `indeterminate`.
  property real progress: 0
  // Unknown length: a short piece travels around the frame instead of a
  // progress that would be a guess.
  property bool indeterminate: false
  property color color: Color.accent
  property color frameColor: Qt.rgba(color.r, color.g, color.b, 0.28)
  property real thickness: Math.max(1, Math.round(Math.min(width, height) * 0.1))
  // Corner radius; the caller passes the cover's own radius.
  property real cornerRadius: width * 0.18
  // Position of the travelling piece, 0..1.
  property real phase: 0
  readonly property real chaseLength: 0.18

  onProgressChanged: canvas.requestPaint()
  onIndeterminateChanged: canvas.requestPaint()
  onPhaseChanged: canvas.requestPaint()
  onColorChanged: canvas.requestPaint()
  onFrameColorChanged: canvas.requestPaint()
  onThicknessChanged: canvas.requestPaint()
  onCornerRadiusChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    // The rounded rectangle as an ordered ring of segments, walked from the
    // middle of the top edge clockwise. Lengths are in pixels, angles in radians.
    function segments(w, h, radius) {
      var inset = Math.max(1, root.thickness) / 2
      var x0 = inset
      var y0 = inset
      var x1 = w - inset
      var y1 = h - inset
      var r = Math.max(0, Math.min(radius, Math.min(x1 - x0, y1 - y0) / 2))
      var cx = (x0 + x1) / 2
      var half = Math.PI / 2
      return [
        { kind: "line", x: cx, y: y0, dx: x1 - r - cx, dy: 0, len: Math.max(0, x1 - r - cx) },
        { kind: "arc", cx: x1 - r, cy: y0 + r, r: r, a0: -half, sweep: half, len: half * r },
        { kind: "line", x: x1, y: y0 + r, dx: 0, dy: (y1 - r) - (y0 + r), len: Math.max(0, y1 - y0 - 2 * r) },
        { kind: "arc", cx: x1 - r, cy: y1 - r, r: r, a0: 0, sweep: half, len: half * r },
        { kind: "line", x: x1 - r, y: y1, dx: (x0 + r) - (x1 - r), dy: 0, len: Math.max(0, x1 - x0 - 2 * r) },
        { kind: "arc", cx: x0 + r, cy: y1 - r, r: r, a0: half, sweep: half, len: half * r },
        { kind: "line", x: x0, y: y1 - r, dx: 0, dy: (y0 + r) - (y1 - r), len: Math.max(0, y1 - y0 - 2 * r) },
        { kind: "arc", cx: x0 + r, cy: y0 + r, r: r, a0: Math.PI, sweep: half, len: half * r },
        { kind: "line", x: x0 + r, y: y0, dx: cx - (x0 + r), dy: 0, len: Math.max(0, cx - (x0 + r)) }
      ]
    }

    function totalLength(segs) {
      var total = 0
      for (var i = 0; i < segs.length; i++) total += segs[i].len
      return total
    }

    // Stroke the part of the ring between `from` and `from + length`, both in
    // pixels along the perimeter.
    function strokeRange(ctx, segs, from, length) {
      var position = 0
      var started = false
      for (var i = 0; i < segs.length; i++) {
        var seg = segs[i]
        var segStart = position
        var segEnd = position + seg.len
        position = segEnd
        if (seg.len <= 0 || segEnd <= from || segStart >= from + length) continue
        var inside = Math.max(0, from - segStart)
        var outside = Math.min(seg.len, from + length - segStart)
        if (outside <= inside) continue
        if (seg.kind === "line") {
          var t0 = inside / seg.len
          var t1 = outside / seg.len
          var x0 = seg.x + seg.dx * t0
          var y0 = seg.y + seg.dy * t0
          var x1 = seg.x + seg.dx * t1
          var y1 = seg.y + seg.dy * t1
          if (!started) {
            ctx.moveTo(x0, y0)
            started = true
          }
          ctx.lineTo(x1, y1)
        } else {
          var a0 = seg.a0 + (inside / seg.len) * seg.sweep
          var a1 = seg.a0 + (outside / seg.len) * seg.sweep
          if (!started) {
            ctx.moveTo(seg.cx + seg.r * Math.cos(a0), seg.cy + seg.r * Math.sin(a0))
            started = true
          }
          ctx.arc(seg.cx, seg.cy, seg.r, a0, a1, false)
        }
      }
    }

    function strokeRing(ctx, segs, width) {
      ctx.strokeStyle = root.frameColor
      ctx.lineWidth = width
      ctx.beginPath()
      strokeRange(ctx, segs, 0, totalLength(segs))
      ctx.stroke()
    }

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      if (width <= 0 || height <= 0) return

      var segs = segments(width, height, root.cornerRadius)
      var total = totalLength(segs)
      if (total <= 0) return

      ctx.lineCap = "round"
      ctx.lineJoin = "round"
      strokeRing(ctx, segs, Math.max(1, root.thickness))

      ctx.strokeStyle = root.color
      ctx.lineWidth = Math.max(1, root.thickness)
      ctx.beginPath()
      if (root.indeterminate) {
        var start = root.phase * total
        var span = root.chaseLength * total
        strokeRange(ctx, segs, start, span)
        if (start + span > total) strokeRange(ctx, segs, 0, start + span - total)
      } else {
        strokeRange(ctx, segs, 0, Math.max(1, Math.min(1, root.progress)) * total)
      }
      ctx.stroke()
    }
  }

  NumberAnimation on phase {
    running: root.indeterminate
    from: 0
    to: 1
    duration: 1400
    loops: Animation.Infinite
  }
}
