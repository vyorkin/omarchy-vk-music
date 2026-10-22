// The gallery's cell width: the number that decides whether the last row of cards is
// whole or cut by the bottom edge of the list.
//
// The failure this guards is geometry, so it is tested as arithmetic: with the cards
// at their natural width two whole rows fit the viewport and the third one is cut in
// half, which is exactly the row the keyboard cursor lands on. The fix is to make the
// rows divide the viewport, and these cases pin that down — including the ones where
// nothing should change.
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

  function rowsHeight(width, rows) {
    return rows * (width + caption) + (rows - 1) * gap
  }

  // Natural width: 4 columns over 640 usable pixels.
  function test_natural_width_needs_no_shrinking() {
    var width = GalleryFit.cellWidth(640, 4, gap, caption, 601, 12)
    verify(width < 160, "the cards give up height so three rows fit: " + width)
    var fits = Math.floor((601 + gap) / (width + caption + gap))
    verify(Math.abs(rowsHeight(width, fits) - 601) < 1.5,
           "three whole rows fill the viewport, got " + rowsHeight(width, fits))
  }

  // Every row count has a width that fills the viewport, and it never grows the cards
  // past what the columns allow.
  function test_rows_always_fill_the_viewport() {
    var views = [300, 420, 601, 628, 900, 1400]
    for (var i = 0; i < views.length; i++) {
      var width = GalleryFit.cellWidth(640, 4, gap, caption, views[i], 40)
      verify(width > 40 && width <= 160, "width out of range for " + views[i] + ": " + width)
      var rows = Math.round((views[i] + gap) / (width + caption + gap))
      var height = rowsHeight(width, rows)
      verify(height <= views[i] + 1, "rows overflow the viewport at " + views[i] + ": " + height)
    }
  }

  // A short grid is not divided: with everything on screen there is no edge to be cut
  // by, and shrinking the covers would be a loss for nothing.
  function test_short_grid_keeps_the_natural_width() {
    compare(GalleryFit.cellWidth(640, 4, gap, caption, 601, 2), 160)
    compare(GalleryFit.cellWidth(640, 4, gap, caption, 601, 1), 160)
  }

  // A single row that is taller than the viewport still has to fit.
  function test_one_row_fits_a_short_viewport() {
    var width = GalleryFit.cellWidth(640, 4, gap, caption, 200, 12)
    verify(width < 160, "card shrinks to fit one row: " + width)
    verify(width + caption <= 200, "one card fits: " + (width + caption))
  }

  function test_degenerate_inputs_do_not_divide_by_zero() {
    compare(GalleryFit.cellWidth(0, 4, gap, caption, 601, 12), 0)
    compare(GalleryFit.cellWidth(640, 0, gap, caption, 601, 12), 0)
    compare(GalleryFit.cellWidth(640, 4, gap, caption, 0, 12), 160)
    // A viewport shorter than a caption cannot be filled: the natural width is the
    // only answer that keeps the cards usable.
    compare(GalleryFit.cellWidth(640, 4, gap, caption, 20, 12), 160)
  }
}
