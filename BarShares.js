// How a bar of cells divides its width between them.
//
// The chips of the section bar are the cells this exists for: they share the bar between
// them and the row always ends on the card's edge. A name that needs more than its even
// share keeps what it needs — «Моя музыка» is wider than a sixth of the bar — and the
// cells that need less take the rest in equal parts. That way nothing is sliced by the
// card's edge: a name cut mid-glyph reads as a bug, while the ellipsis a cell draws when
// its label is wider than what is left reads as a decision.
//
// The failure this guards is a bar that stops short of its own end. A child that asks for
// nothing draws nothing, and a share handed to it is a share taken from the cells and
// left as empty background: the row's own Repeater is exactly that — a zero-width child
// of the row it fills — and counting it as a cell left the bar a whole chip short of the
// tools, widest of all in the wide card, where a chip is at its widest.
.pragma library

// needs – what each cell asks for: its own implicitWidth, the width it would take if
//         nothing shared the bar. A width of zero marks a child that is not a cell.
// room  – the bar's width, in the same pixels.
//
// Returns one width per need, in the same order, adding up to `room` — the pixels left
// over by the division go to the first cells, one each.
function widths(needs, room) {
  var count = needs.length
  if (count === 0 || !(room > 0)) return []
  var width = new Array(count)
  var pinned = 0
  var used = 0
  // A child that asks for nothing is not a cell: it keeps its zero, and the whole bar is
  // divided among the rest.
  for (var none = 0; none < count; none++) {
    if (needs[none] > 0) continue
    width[none] = 0
    pinned++
  }
  // Pin the labels that ask for more than an even share against the rest of the bar,
  // then share what is left among the others — a few passes settle it.
  for (var pass = 0; pass < 8; pass++) {
    var free = count - pinned
    if (free <= 0) break
    var share = (room - used) / free
    var changed = false
    for (var i = 0; i < count; i++) {
      if (width[i] !== undefined) continue
      if (needs[i] >= share) {
        width[i] = Math.ceil(needs[i])
        used += width[i]
        pinned++
        changed = true
      }
    }
    if (!changed) break
  }
  var left = count - pinned
  var each = left > 0 ? Math.floor((room - used) / left) : 0
  var spare = left > 0 ? Math.round(room - used) - each * left : 0
  for (var j = 0; j < count; j++) {
    if (width[j] !== undefined) continue
    width[j] = each + (spare > 0 ? 1 : 0)
    if (spare > 0) spare--
  }
  return width
}
