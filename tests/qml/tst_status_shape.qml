// A poll that repeats itself is not a change.
//
// Every status poll hands the panel a freshly parsed document, so `preferences`, `history`
// and `people` come back as new objects and new arrays whether or not a byte of them
// changed. The panel plans the visible list from those fields, and the plan is read by
// every list, every row count and every switch in the panel — so each poll re-ran the whole
// plan a dozen times, over a list of three hundred tracks, and threw the copies away. Once a
// second while a track plays, four times a second while one is being fetched, which is the
// stutter the pointer hit while it was moving down a list: a widget busy planning rows
// nobody had changed.
//
// QML is what makes the fix as small as it is: a binding that re-evaluates to the same
// object identity notifies nobody below it, while a new array holding the same elements
// does. So the tests below are two kinds: what `adopt` keeps, and what a Repeater does when
// a poll goes through it.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../StatusShape.js" as StatusShape

TestCase {
  id: tc
  name: "StatusShape"
  width: 200
  height: 200

  property var status: ({
    position: 0,
    preferences: { language: "ru", playlistView: "list" },
    history: ["kino", "морфин"],
    people: [{ id: 1, name: "Аня" }]
  })

  // The rows of the list a poll can wake: one delegate per recent query, and the count of
  // the ones built and thrown away since the test began.
  property int built: 0
  property int rebuilt: 0

  Repeater {
    model: tc.status.history
    delegate: Item {
      Component.onCompleted: tc.built++
      Component.onDestruction: tc.rebuilt++
    }
  }

  function init() {
    tc.status = {
      position: 0,
      preferences: { language: "ru", playlistView: "list" },
      history: ["kino", "морфин"],
      people: [{ id: 1, name: "Аня" }]
    }
    // The rows for the status just set are built, and the previous test's are gone.
    wait(50)
    tc.built = 0
    tc.rebuilt = 0
  }

  // What the daemon answers with: the same content, parsed again, so every container is a
  // new object holding equal values.
  function poll(changes) {
    var document = JSON.parse(JSON.stringify(tc.status))
    for (var key in changes) document[key] = changes[key]
    var next = StatusShape.adopt(tc.status, document)
    if (next !== tc.status) tc.status = next
    wait(50)
  }

  function test_a_poll_that_repeats_itself_is_the_same_status() {
    var before = tc.status
    var prefs = tc.status.preferences
    var history = tc.status.history
    poll({})
    verify(tc.status === before)
    verify(tc.status.preferences === prefs)
    verify(tc.status.history === history)
    // Nothing woke: the rows on screen are the rows that were there.
    compare(tc.built, 0)
    compare(tc.rebuilt, 0)
  }

  // A track that has played on says one thing that changed. The rest of the document is the
  // document the panel already had, so everything planned from it stands.
  function test_the_field_that_changed_is_the_only_new_one() {
    var before = tc.status
    var prefs = tc.status.preferences
    var history = tc.status.history
    var people = tc.status.people
    poll({ position: 7 })
    verify(tc.status !== before)
    compare(tc.status.position, 7)
    verify(tc.status.preferences === prefs)
    verify(tc.status.history === history)
    verify(tc.status.people === people)
    compare(tc.built, 0)
    compare(tc.rebuilt, 0)
  }

  // The one list a poll really can change: a committed search puts a query at its head.
  function test_a_list_that_changed_keeps_the_list_that_did_not() {
    var people = tc.status.people
    poll({ history: ["небо", "kino", "морфин"] })
    verify(tc.status.people === people)
    compare(tc.status.history.length, 3)
    // A changed array is what a Repeater rebuilds: the old two are gone, three stand.
    compare(tc.rebuilt, 2)
    compare(tc.built, 3)
  }

  // A field the daemon stopped sending is a change like any other, and the status built from
  // it has to lose it.
  function test_a_field_that_stopped_arriving_is_a_change() {
    var document = JSON.parse(JSON.stringify(tc.status))
    delete document.people
    var next = StatusShape.adopt(tc.status, document)
    verify(next !== tc.status)
    compare(next.people, undefined)
    verify(next.history === tc.status.history)
  }

  // Nothing to compare against yet, or nothing to compare: the status the panel has stays
  // as it is rather than becoming null.
  function test_a_refusal_or_the_first_answer() {
    var first = StatusShape.adopt({}, { position: 3 })
    compare(first.position, 3)
    verify(StatusShape.adopt(first, null) === first)
    verify(StatusShape.adopt(first, undefined) === first)
    verify(StatusShape.adopt(first, "no") === first)
  }

  // The poll is the widget breathing once a second, and a breath that changes nothing must
  // not plan a single row: a hundred of them are a hundred plans that never were.
  function test_a_hundred_polls_build_no_rows() {
    var prefs = tc.status.preferences
    for (var i = 0; i < 100; i++) poll({})
    compare(tc.built, 0)
    compare(tc.rebuilt, 0)
    verify(tc.status.preferences === prefs)
  }
}
