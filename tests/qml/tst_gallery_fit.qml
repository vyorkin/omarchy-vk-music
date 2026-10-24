// The gallery's arithmetic: how many cards stand across, how wide each one is, and how
// many whole rows a room holds.
//
// The failure this guards is geometry. A card must take its full share of the width —
// a grid that stops short of the right edge looks like a grid missing its last column —
// and the rows must divide the room they are given, or the keyboard cursor lands on a
// card that is half under the edge. Both are decided here, without a delegate.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../GalleryFit.js" as GalleryFit

TestCase {
  name: "GalleryFit"

  readonly property real caption: 42
  readonly property real gap: 8
  readonly property int columns: 4

  function rowsHeight(width, rows, rowGap) {
    return rows * (width + caption) + (rows - 1) * rowGap
  }

  // Four cards and their three gaps are the whole width, with nothing left over. The
  // gaps used to come on top of the cards' share, so a full row was a gap too wide and
  // the last column hung over the edge of the list.
  function test_cells_fill_the_width() {
    var plan = GalleryFit.plan(640, columns, gap, caption, 12)
    compare(plan.columns, 4)
    compare(plan.cellWidth, (640 - 3 * gap) / 4)
    compare(plan.cellRows, 3)
    compare(4 * plan.cellWidth + 3 * gap, 640)
  }

  // Three friends out of a possible four: the row is filled by stretching the cards
  // rather than by leaving a hole at the right edge.
  function test_a_short_row_stretches() {
    var plan = GalleryFit.plan(640, columns, gap, caption, 3)
    compare(plan.columns, 3)
    verify(Math.abs(plan.cellWidth - (640 - 2 * gap) / 3) < 0.01, "three cards and two gaps share the width")
    compare(plan.cellRows, 1)
  }

  // One card is not a poster: the stretch stops at twice the width of a card in a full
  // row, and the rest of the row is left empty on purpose.
  function test_one_card_is_not_stretched_to_the_panel() {
    var plan = GalleryFit.plan(640, columns, gap, caption, 1)
    compare(plan.cellWidth, 320)
    compare(plan.cellRows, 1)
  }

  // What a room holds: two whole rows in a room too short for three, and the height they
  // take is what the card has to end at.
  function test_whole_room_counts_rows_that_fit() {
    var width = GalleryFit.plan(640, columns, gap, caption, 12).cellWidth
    var block = width + caption
    var room = GalleryFit.wholeRoom(500, block, gap, 3)
    compare(room.rows, 2)
    compare(room.height, rowsHeight(width, 2, gap))
    verify(room.height <= 500, "two rows fit: " + room.height)
  }

  // A grid shorter than the room is not counted past its own end.
  function test_whole_room_stops_at_a_short_grid() {
    var block = 160 + caption
    var room = GalleryFit.wholeRoom(2000, block, gap, 2)
    compare(room.rows, 2)
    compare(room.height, rowsHeight(160, 2, gap))
  }

  function test_whole_room_reports_nothing_when_a_card_does_not_fit() {
    var block = 160 + caption
    compare(GalleryFit.wholeRoom(100, block, gap, 3).rows, 0)
    compare(GalleryFit.wholeRoom(0, block, gap, 3).height, 0)
    compare(GalleryFit.wholeRoom(500, 0, gap, 3).rows, 0)
  }

  function test_degenerate_inputs_do_not_divide_by_zero() {
    var plan = GalleryFit.plan(0, columns, gap, caption, 12)
    compare(plan.cellWidth, 0)
    plan = GalleryFit.plan(640, 0, gap, caption, 12)
    verify(plan.cellWidth > 0, "one column still holds the cards")
    compare(plan.columns, 1)
    // No items at all: the layout of an empty grid is the layout of a full row.
    plan = GalleryFit.plan(640, columns, gap, caption, 0)
    compare(plan.columns, 4)
    compare(plan.cellRows, 0)
    // A negative gap is no gap, not a division by nothing.
    compare(GalleryFit.wholeRoom(500, 160 + caption, -5, 3).rows, 2)
  }
}
