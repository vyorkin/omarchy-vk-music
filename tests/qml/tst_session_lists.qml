// What the session fetched, and the three obligations that used to live in the widget.
//
// Forgetting a session was thirty assignments by name, repainting a like was four lists out
// of eleven, and "still loading" was eight flags plus two counters, each with its own way of
// going stale. Each of those failed the same silent way: an empty list where a row should
// be, a heart that did not flip, a loading line that ran forever. So the tests are one per
// obligation, plus the vocabulary check that keeps the store and the plan speaking the same
// names.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import vkmusic

TestCase {
  name: "SessionLists"

  function track(key, title) {
    return { key: key, title: title || ("Track " + key), artist: "Artist", is_liked: false }
  }

  function card(id) {
    return { id: id, title: "Playlist " + id }
  }

  function loaded() {
    var lists = createTemporaryObject(sessionComponent, null)
    lists.queue = [track("q1"), track("q2")]
    lists.tracks = [track("t1")]
    lists.playlists = [card(1)]
    lists.playlistTracks = [track("p1")]
    lists.personPlaylists = [card(2)]
    lists.friends = [card(3)]
    lists.stations = [{ id: 1, name: "Jazz" }]
    lists.foundPlaylists = [card(4)]
    lists.results = [track("r1")]
    lists.suggestions = ["kino"]
    lists.sources = [{ id: "all", title: "Моя музыка" }]
    lists.sourcesLoadedAt = 42
    lists.sourcesAskedAt = 43
    lists.foundPlaylistsTotal = 7
    lists.emptySectionTries = 2
    return lists
  }

  Component {
    id: sessionComponent
    SessionLists {}
  }

  // Every list is emptied, every counter is zeroed, every flag is gone. A field added to the
  // session without being added to `reset()` fails here rather than after an account switch.
  function test_reset_forgets_everything() {
    var lists = loaded()
    lists.begin("browse")
    lists.reset()
    var all = lists.lists()
    for (var name in all) compare(lists[name].length, 0)
    compare(lists.sourcesLoadedAt, 0)
    compare(lists.sourcesAskedAt, 0)
    compare(lists.foundPlaylistsTotal, 0)
    compare(lists.emptySectionTries, 0)
    verify(!lists.anyLoading())
    compare(lists.loading("browse"), false)
  }

  // The plan reads eleven of these twelve names, and reads them straight from `state()`:
  // a name that drifts here is a list the plan silently sees as empty.
  function test_state_speaks_the_plans_names() {
    var lists = loaded()
    var state = lists.state()
    var expected = ["queue", "tracks", "playlists", "playlistTracks", "personPlaylists",
      "friends", "stations", "foundPlaylists", "results", "suggestions"]
    for (var i = 0; i < expected.length; i++) {
      verify(state[expected[i]] !== undefined, expected[i])
    }
    compare(state.queue.length, 2)
    compare(state.tracks.length, 1)
    // `sources` is the bar's chips, not a list the plan draws.
    compare(state.sources, undefined)
  }

  // A heart is one fact about every list holding a copy of the track — not about the four
  // somebody remembered. Lists that hold playlists, stations or queries are left alone.
  function test_a_like_repaints_every_list_that_holds_the_track() {
    var lists = loaded()
    lists.queue = [track("k"), track("other")]
    lists.playlistTracks = [track("k")]
    lists.tracks = [track("k")]
    lists.results = [track("k")]
    lists.like("k", true)
    compare(lists.queue[0].is_liked, true)
    compare(lists.playlistTracks[0].is_liked, true)
    compare(lists.tracks[0].is_liked, true)
    compare(lists.results[0].is_liked, true)
    // Untouched: a list of a different kind is not a list of tracks.
    compare(lists.playlists[0].is_liked, undefined)
    compare(lists.stations[0].is_liked, undefined)
    compare(lists.suggestions[0], "kino")
    // And a like that is taken back is taken back everywhere.
    lists.like("k", false)
    compare(lists.queue[0].is_liked, false)
    compare(lists.tracks[0].is_liked, false)
  }

  // One answer per fetch: a slow reply for a page the user has left must paint nothing, and
  // must not clear the flag the newer fetch is holding.
  function test_a_stale_answer_is_dropped() {
    var lists = loaded()
    var first = lists.begin("browse")
    var second = lists.begin("browse")
    compare(lists.accept(first), false)
    compare(lists.loading("browse"), true)
    compare(lists.accept(second), true)
    compare(lists.loading("browse"), false)
    // The same token twice does not count twice.
    compare(lists.accept(second), false)
  }

  // A fetch that fails is not loading any more either: the flag has one owner, and it lets
  // go on both roads.
  function test_a_failed_fetch_clears_its_flag() {
    var lists = loaded()
    var token = lists.begin("queue")
    compare(lists.loading("queue"), true)
    compare(lists.fail(token), true)
    compare(lists.loading("queue"), false)
    // A stale failure clears nothing.
    var stale = lists.begin("queue")
    lists.begin("queue")
    compare(lists.fail(stale), false)
    compare(lists.loading("queue"), true)
  }

  // A page is one guard with several flags: «Ещё» and an opened playlist both belong to the
  // browse page, so walking away from it cancels them without touching the queue's fetch.
  function test_a_guard_covers_the_flags_of_its_page() {
    var lists = loaded()
    var queueToken = lists.begin("queue")
    lists.begin("browse")
    var more = lists.begin("browse", "browseMore")
    verify(lists.anyLoading())
    lists.clearLoading()
    verify(!lists.anyLoading())
    // The queue's answer was cancelled with everything else on screen...
    compare(lists.accept(queueToken), false)
    compare(lists.accept(more), false)
  }

  function test_stepping_back_cancels_one_page_only() {
    var lists = loaded()
    var queueToken = lists.begin("queue")
    var browse = lists.begin("browse")
    lists.cancel("browse")
    compare(lists.accept(browse), false)
    compare(lists.accept(queueToken), true)
  }
}
