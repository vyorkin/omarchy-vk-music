// How the keyboard cursor walks a gallery: a step down is the card under the selected
// one, not the next card in the list.
//
// The failure this guards is the friends page: «Друзья» is a wall of cards and «Недавние»
// the wall under it, and both are one band in the cursor's list. Stepping down from the
// right-hand card of the first wall must reach the right-hand card of the second, not its
// first card — a step left as well as down reads as a key that lost its place. The bands
// also carry the cases with no second wall (a section's tracks), with narrower walls, and
// with the cursor at either end of the page.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../GalleryWalk.js" as GalleryWalk

TestCase {
  name: "GalleryWalk"

  function band(offset, count, columns) {
    return { offset: offset, count: count, columns: columns }
  }

  // Two walls of three across: the friends, then the people opened before. The right-hand
  // card of the first row steps onto the right-hand card of the second.
  function test_a_row_step_keeps_the_column_across_two_walls() {
    var bands = [band(0, 3, 3), band(3, 3, 3)]
    compare(GalleryWalk.step(bands, 2, 0, 1), 5)
    compare(GalleryWalk.step(bands, 0, 0, 1), 3)
    compare(GalleryWalk.step(bands, 1, 0, 1), 4)
    // And back up: the same column of the wall above, which is its last row.
    compare(GalleryWalk.step(bands, 5, 0, -1), 2)
    compare(GalleryWalk.step(bands, 3, 0, -1), 0)
  }

  // A wall narrower than the one above it: the step lands on its last column rather than
  // past the end of the row. Coming back up, the column is the card's place in its own
  // wall, which is all the two walls have in common.
  function test_a_narrower_wall_takes_its_last_column() {
    var bands = [band(0, 3, 3), band(3, 2, 2)]
    compare(GalleryWalk.step(bands, 2, 0, 1), 4)
    compare(GalleryWalk.step(bands, 4, 0, -1), 1)
  }

  // Down the rows of one wall before the wall under it: a section of four playlists three
  // across has a second row, and (0,1) has no card under it — the step ends on the last
  // card of that row instead of leaving the wall.
  function test_a_row_without_that_column_lands_on_the_last_card() {
    var bands = [band(0, 4, 3), band(4, 10, 1)]
    compare(GalleryWalk.step(bands, 1, 0, 1), 3)
    compare(GalleryWalk.step(bands, 0, 0, 1), 3)
    compare(GalleryWalk.step(bands, 2, 0, 1), 3)
    // Off the bottom of the cards is the list under them, whatever the column.
    compare(GalleryWalk.step(bands, 3, 0, 1), 4)
    // And back up out of that list: its own rows first, then the cards above it.
    compare(GalleryWalk.step(bands, 5, 0, -1), 4)
    compare(GalleryWalk.step(bands, 4, 0, -1), 3)
  }

  // The ends of the page hold: there is no card above the first row or below the last.
  function test_the_ends_of_the_page_hold() {
    var bands = [band(0, 3, 3), band(3, 3, 3)]
    compare(GalleryWalk.step(bands, 0, 0, -1), 0)
    compare(GalleryWalk.step(bands, 1, 0, -1), 1)
    compare(GalleryWalk.step(bands, 5, 0, 1), 5)
    compare(GalleryWalk.step(bands, 4, 0, 1), 4)
  }

  // Rows of a single column: a step down is the next line, the same as a flat list.
  function test_one_column_steps_line_by_line() {
    var bands = [band(0, 10, 1)]
    compare(GalleryWalk.step(bands, 0, 0, 1), 1)
    compare(GalleryWalk.step(bands, 9, 0, -1), 8)
    compare(GalleryWalk.step(bands, 3, 0, 4), 7)
  }

  // Across is one card, and it wraps over the end of a row the way a list does.
  function test_across_wraps_over_the_end_of_a_row() {
    var bands = [band(0, 3, 3), band(3, 3, 3)]
    compare(GalleryWalk.step(bands, 1, 1, 0), 2)
    compare(GalleryWalk.step(bands, 2, 1, 0), 3)
    compare(GalleryWalk.step(bands, 3, -1, 0), 2)
    compare(GalleryWalk.step(bands, 0, -1, 0), 0)
    compare(GalleryWalk.step(bands, 5, 1, 0), 5)
  }

  function test_empty_bands_do_not_move() {
    compare(GalleryWalk.step([], 0, 0, 1), 0)
    compare(GalleryWalk.step([], 3, 1, 0), 3)
    compare(GalleryWalk.total([]), 0)
  }
}
