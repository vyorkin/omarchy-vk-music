// The section bar's arithmetic: how the width of a row of chips is divided between them.
//
// The failure this guards is a bar that stops short of its own end. The row's Repeater is
// a child of the row it fills and a zero-width one, so counting it as a cell handed it a
// chip's share of the bar, which nothing drew: the chips ended a whole cell before the
// tools, and the empty strip read as a bar with a hole in it. A cell that asks for more
// than an even share is the other half of the question — its name must not be cut.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../BarShares.js" as BarShares

TestCase {
  name: "BarShares"

  function sum(widths) {
    var total = 0
    for (var i = 0; i < widths.length; i++) total += widths[i]
    return total
  }

  // Five chips and the Repeater that draws four of them: the Repeater asks for nothing,
  // and the bar is divided among the five that do.
  function test_a_child_that_asks_for_nothing_takes_nothing() {
    var widths = BarShares.widths([60, 90, 70, 60, 110, 0], 650)
    compare(widths.length, 6)
    compare(widths[5], 0)
    compare(sum(widths), 650)
    for (var i = 0; i < 5; i++)
      verify(widths[i] >= 108, "chip " + i + " is a sixth of the bar at least, not " + widths[i])
  }

  // Without the zero the same bar is divided a sixth too many ways, which is the bug the
  // test above is about: five even shares of 650 do not fit in six of them.
  function test_the_shares_fill_the_bar() {
    compare(sum(BarShares.widths([1, 1, 1, 1, 1, 0], 650)), 650)
    compare(sum(BarShares.widths([1, 1, 1, 1, 1], 650)), 650)
  }

  // Equal cells take equal shares, and the pixels left over by the division go to the
  // first cells, one each, so nothing is left over at the end of the row.
  function test_the_remainder_goes_to_the_first_cells() {
    var widths = BarShares.widths([10, 10, 10], 100)
    compare(widths, [34, 33, 33])
  }

  // «Моя музыка» needs more than its even share and keeps what it needs: a name cut
  // mid-glyph reads as a bug, where an ellipsis reads as a decision.
  function test_a_wide_name_keeps_what_it_needs() {
    var widths = BarShares.widths([60, 140, 60, 60, 100], 600)
    compare(widths[1], 140)
    compare(sum(widths), 600)
    for (var i = 0; i < widths.length; i++)
      if (i !== 1) verify(widths[i] >= 60, "chip " + i + " keeps its own name, not " + widths[i])
  }

  // Nothing to divide: no cells, or no width to give them.
  function test_a_bar_with_no_room_asks_for_nothing() {
    compare(BarShares.widths([], 400), [])
    compare(BarShares.widths([60, 60], 0), [])
    compare(BarShares.widths([60, 60], -10), [])
  }

  // The same question asked of a real row: the chips are children of it, and the Repeater
  // that draws them is a child too — that is where the zero the division skips comes from,
  // and a test that only counts array entries would not say so.
  function test_a_row_of_chips_fills_its_width() {
    var row = Qt.createQmlObject('import QtQuick
      Row {
        Repeater {
          model: 4
          delegate: Item { implicitWidth: 80; implicitHeight: 10 }
        }
      }', Qt.application, "row")
    var needs = []
    for (var i = 0; i < row.children.length; i++) needs.push(row.children[i].implicitWidth)
    compare(row.children.length, 5)
    compare(needs[4], 0)
    var widths = BarShares.widths(needs, 650)
    compare(widths[4], 0)
    compare(sum(widths), 650)
    row.destroy()
  }
}
