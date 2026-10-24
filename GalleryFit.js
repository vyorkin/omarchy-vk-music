// How a gallery fills the list: the width of a card, its columns, and how many whole
// rows a room holds.
//
// The width and the height are one question asked at right angles. The cards fill the
// list across — the column count divides the width and a card is exactly as wide as its
// share, so no gallery stops short of the right edge. The bottom edge is the list's
// business: `wholeRoom` says what a room holds in whole rows so the card can end where
// the last row ends, and the last row on screen is never a slice of one. Both matter
// because the keyboard cursor walks the gallery: a card half under the edge is the card
// the cursor lands on.
//
// Narrowing the cards so that their rows divided the viewport was the other way round,
// and it cost a strip of empty background at the right edge of every gallery.
.pragma library

// A card's share of the width. `cap` keeps one or two cards from becoming posters when
// the grid holds fewer items than it has columns.
function cellWidth(usable, columns, cap) {
  if (!(usable > 0) || !(columns >= 1)) return 0
  var width = usable / columns
  if (cap > 0 && width > cap) width = cap
  return width
}

// Everything a gallery needs to place itself.
//
// usable   – the grid's inner width, column gaps still in it
// columns  – the most cards the layout allows across
// gap      – the gap between two rows
// caption  – what sits under a cover: two lines of text and their spacing
// count    – how many cards there are, so a short row is not stretched
//
// Returns { columns, cellRows, cellWidth }.
function plan(usable, columns, gap, caption, count) {
  var base = columns >= 1 ? usable / columns : 0
  var across = count > 0 ? Math.max(1, Math.min(columns, count)) : Math.max(1, columns)
  var rows = count > 0 ? Math.ceil(count / across) : 0
  // One card in a panel this wide is not «filling the space», it is a poster: the
  // stretch stops at twice the width of a card in a full row.
  return { columns: across, cellRows: rows, cellWidth: cellWidth(usable, across, base * 2) }
}

// How many whole rows a room holds, and the height they take. The gap is the designed
// one: what does not fit a row is taken out of the room, not spread between the rows,
// because a gallery with two rows and a gap of a whole card is empty space with a card
// at each end.
//
// Returns { rows, height }, or { rows: 0, height: 0 } when not even one row fits.
function wholeRoom(space, block, gap, rows) {
  if (!(gap >= 0)) gap = 0
  if (!(space > 0) || !(block > 0)) return { rows: 0, height: 0 }
  var fits = Math.floor((space + gap) / (block + gap))
  if (!(fits >= 1)) return { rows: 0, height: 0 }
  if (rows > 0 && fits > rows) fits = rows
  return { rows: fits, height: fits * block + (fits - 1) * gap }
}
