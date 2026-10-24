// Marking a like across the lists that hold the track.
//
// The failure this guards: a row's heart stayed an outline after the track it plays was
// liked, while the backend had the like. The cause is not arithmetic but how a model
// hands out its elements — a delegate over a JS array model is given a COPY of the
// element, so writing `is_liked` into the track inside the list changes the list and
// nothing on screen. The delegate test below is the proof of that, and the reason
// `Likes.mark` returns a new array instead of editing the one it was given.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../Likes.js" as Likes

TestCase {
  name: "Likes"
  when: windowShown
  width: 320
  height: 200

  // The panel's own shape, cut down: a list of tracks, a delegate that reads one, and the
  // heart's state as the delegate sees it.
  Item {
    id: panel
    property var queue: []

    Column {
      Repeater {
        id: rows
        model: panel.queue
        delegate: Item {
          width: 100
          height: 16
          property var track: modelData
          property bool filled: panel.isLiked(track)
        }
      }
    }

    function isLiked(track) {
      return track ? track.is_liked === true : false
    }

    function markLiked(key, liked) {
      queue = Likes.mark(queue, key, liked)
    }
  }

  function queueWithLikes() {
    panel.queue = [
      { key: "1_1", title: "Veidr", is_liked: false },
      { key: "2_2", title: "Tainted Love", is_liked: false },
      { key: "3_3", title: "Von Der Tiefe", is_liked: true }
    ]
  }

  function test_the_row_heart_follows_a_like() {
    queueWithLikes()
    compare(rows.count, 3)
    compare(rows.itemAt(1).filled, false, "the row starts unliked")
    panel.markLiked("2_2", true)
    compare(rows.itemAt(1).filled, true, "the row of the liked track is filled")
    compare(rows.itemAt(0).filled, false, "a row of another track keeps its heart")
    compare(rows.itemAt(2).filled, true, "a row that was liked stays liked")
  }

  function test_unliking_empties_the_heart_again() {
    queueWithLikes()
    panel.markLiked("3_3", false)
    compare(rows.itemAt(2).filled, false)
  }

  // The trap itself, kept as a test: this is what the panel used to do, and it is why the
  // heart could stay an outline forever no matter how many times the epoch was bumped.
  function test_editing_the_track_in_place_is_invisible() {
    queueWithLikes()
    panel.queue[1].is_liked = true
    compare(panel.queue[1].is_liked, true)
    compare(rows.itemAt(1).filled, false, "the delegate was given a copy, not the element")
  }

  function test_a_list_with_nothing_to_change_is_the_same_list() {
    queueWithLikes()
    var before = panel.queue
    compare(Likes.mark(before, "9_9", true) === before, true, "another track's key changes nothing")
    compare(Likes.mark(before, "1_1", false) === before, true, "the state already holds")
    compare(Likes.mark(null, "1_1", true), null)
    compare(Likes.mark([], "1_1", true).length, 0)
  }

  // The list the caller keeps is left as it was: the answer is a new list, and a caller
  // that forgets to assign it back sees an honest unchanged list rather than a half edit.
  function test_the_given_list_is_not_edited() {
    queueWithLikes()
    var before = panel.queue
    var after = Likes.mark(before, "2_2", true)
    compare(after === before, false)
    compare(before[1].is_liked, false, "the old list kept the old state")
    compare(after[1].is_liked, true)
    compare(after[0] === before[0], true, "the untouched tracks are the same objects")
  }

  // A queue can hold the same track more than once, and VK's own lists have carried
  // duplicates: every copy has to answer the same way.
  function test_every_copy_of_the_key_is_marked() {
    panel.queue = [
      { key: "5_5", title: "a", is_liked: false },
      { key: "5_5", title: "a", is_liked: false }
    ]
    panel.markLiked("5_5", true)
    compare(rows.itemAt(0).filled, true)
    compare(rows.itemAt(1).filled, true)
  }
}
