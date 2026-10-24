// How the keyboard cursor walks a gallery: a step down is the card under the selected
// one, never the next card in the list.
//
// A page can hold more than one wall of cards — the friends page is the friends and then
// the people opened before, a section is its playlists and then its tracks — and the walls
// do not have to stand the same number of cards across. So a step is handed the bands on
// screen in cursor order: each one says where it starts in the cursor's list, how many
// items it holds and how many cards stand across it. That is all the arithmetic needs —
// the column a step keeps, the gap between two walls, and the single column the rows
// under them are.
//
// The failure this guards is the one the old edge clamp caused instead of fixing: «j» on
// the right-hand card of «Друзья» landed on the first card of «Недавние», which is a step
// left as well as down, and read as a key that lost its place.
.pragma library

// The items the bands hold together.
function total(bands) {
  if (!bands || bands.length === 0) return 0
  var last = bands[bands.length - 1]
  return last.offset + last.count
}

// The band an index falls in. An index past the end belongs to the last band, so a step
// never has to be told the list is shorter than its own geometry says.
function bandAt(bands, index) {
  for (var i = 0; i < bands.length; i++) {
    if (index < bands[i].offset + bands[i].count) return i
  }
  return bands.length - 1
}

// One card to the left or the right, wrapping over the end of a row the way a list does.
function stepAcross(bands, index, dx) {
  var count = total(bands)
  if (count === 0) return index
  return Math.max(0, Math.min(count - 1, index + dx))
}

// One row up or down, keeping the column. Within a band the same column; over the edge of
// a band, the same column of the next one, or its last column when it is narrower, and
// the first row of it either way. Off the end of the first or the last band a step stays
// where it is: there is no card above the top or below the bottom.
function stepRow(bands, index, down) {
  var which = bandAt(bands, index)
  if (which < 0) return index
  var band = bands[which]
  var column = (index - band.offset) % band.columns
  var row = Math.floor((index - band.offset) / band.columns)
  var target = row + (down ? 1 : -1)

  if (target >= 0 && target < Math.ceil(band.count / band.columns)) {
    var cell = band.offset + target * band.columns + column
    // A last row that is not full has no card in this column: the step lands on the last
    // card of the row rather than hanging over the end of the band.
    return cell < band.offset + band.count ? cell : band.offset + band.count - 1
  }

  var next = down ? which + 1 : which - 1
  if (next < 0 || next >= bands.length) return index
  var other = bands[next]
  var otherColumn = Math.min(column, other.columns - 1)
  if (down) return other.offset + otherColumn
  // Coming back up, the row above is the last row of the band above.
  var lastRow = Math.ceil(other.count / other.columns) - 1
  var up = other.offset + lastRow * other.columns + otherColumn
  return Math.min(up, other.offset + other.count - 1)
}

// A whole step: `dx` cards across or `dy` rows down, not both.
function step(bands, index, dx, dy) {
  var count = total(bands)
  if (count === 0) return index
  var at = Math.max(0, Math.min(count - 1, index))
  if (!dy) return stepAcross(bands, at, dx)
  var down = dy > 0
  for (var i = 0; i < Math.abs(dy); i++) at = stepRow(bands, at, down)
  return at
}
