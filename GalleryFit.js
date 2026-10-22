// How wide a gallery card is allowed to be.
//
// The columns decide the width, and the list's own viewport decides how many rows are
// on screen at once. A row that is half under the edge is worse than a slightly
// smaller cover: with hjkl the cursor always lands on the row that is cut, and a card
// without its caption under it reads as broken. So the cells are narrowed until a
// whole number of rows fills the viewport — a gallery with no half-row at either edge,
// and a keyboard that never has to stop between two cards.
.pragma library

// usable   – the width the columns share, inter-column gaps already taken out
// columns  – cards across
// spacing  – the gap between two rows (and between two columns)
// caption  – what sits under a cover: two lines of text and their spacing
// viewport – the height of the scrolling area the grid is seen through
// rows     – how many rows the grid has, so a short grid is left alone
function cellWidth(usable, columns, spacing, caption, viewport, rows) {
  if (!(usable > 0) || !(columns >= 1)) return 0
  var natural = usable / columns
  if (!(viewport > 0) || !(caption >= 0)) return natural
  // A grid that fits its viewport does not have to divide anything: no scrolling
  // means no edge to be cut by.
  if (rows > 0) {
    var needed = rows * (natural + caption) + (rows - 1) * spacing
    if (needed <= viewport) return natural
  }
  // One row more than the natural size fits is the row count that fills the viewport:
  // the cards give up a little height so that the last row is whole instead of the
  // next one being cut.
  var filledRows = Math.ceil((viewport + spacing) / (natural + caption + spacing))
  if (!(filledRows >= 1)) filledRows = 1
  var filled = (viewport - (filledRows - 1) * spacing) / filledRows - caption
  // A viewport too short to hold even one whole card is a size the caller has to
  // survive, not one this function can invent: keep the natural width.
  if (!(filled > 0)) return natural
  return Math.min(natural, filled)
}
