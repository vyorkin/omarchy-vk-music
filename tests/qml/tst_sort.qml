// The order a list is drawn in.
//
// An order is the list's, not the view's: `SessionLists.put()` hands the sorted array to
// every reader — the rows, the queue «Играть весь плейлист» builds, «Ещё»'s offset — so what
// the reader sees and what the panel plays cannot disagree. The two things that make that
// safe are tested here: sorting never mutates the array it was given, and «VK order» is
// recoverable from a rank table rather than from a copy that a like would undo.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../Sort.js" as Sort

TestCase {
  name: "Sort"

  function playlist(key, count) {
    return { key: key, title: "Playlist " + key, count: count }
  }

  function track(key, duration) {
    return { key: key, title: "Track " + key, duration: duration }
  }

  function keys(list) {
    var out = []
    for (var i = 0; i < list.length; i++) out.push(list[i].key)
    return out.join("")
  }

  // The lists `ListShape` draws and a sort can order, and the one it must not touch: the
  // queue's order is the order of playback.
  function test_family_names_the_lists_it_orders() {
    compare(Sort.family("playlists"), "playlists")
    compare(Sort.family("personPlaylists"), "playlists")
    compare(Sort.family("foundPlaylists"), "playlists")
    compare(Sort.family("playlistTracks"), "tracks")
    compare(Sort.family("tracks"), "tracks")
    compare(Sort.family("results"), "tracks")
    compare(Sort.family("queue"), "")
    compare(Sort.family("friends"), "")
  }

  function test_a_playlist_list_sorts_by_the_number_of_tracks_inside() {
    var list = [playlist("a", 5), playlist("b", 40), playlist("c", 1)]
    var ranks = Sort.arrivals(list)
    compare(keys(Sort.apply(list, "playlists", "count-desc", ranks)), "bac")
    compare(keys(Sort.apply(list, "playlists", "count-asc", ranks)), "cab")
  }

  function test_a_track_list_sorts_by_length() {
    var list = [track("a", 200), track("b", 30), track("c", 400)]
    var ranks = Sort.arrivals(list)
    compare(keys(Sort.apply(list, "tracks", "duration-desc", ranks)), "cab")
    compare(keys(Sort.apply(list, "tracks", "duration-asc", ranks)), "bac")
  }

  // The order the answer arrived in is not "sorted by nothing": a section is curated and «Моя
  // музыка» is newest like first. A choice has to be able to give it back, and give it back
  // exactly — including the two copies of one track a playlist may hold.
  function test_vk_order_returns_exactly_as_it_arrived() {
    var list = [track("b", 30), track("a", 200), track("c", 400)]
    var ranks = Sort.arrivals(list)
    var sorted = Sort.apply(list, "tracks", "duration-desc", ranks)
    compare(keys(sorted), "cab")
    compare(keys(Sort.apply(sorted, "tracks", "vk", ranks)), "bac")
    // Two copies of one track keep their places relative to it: both are the same `key`,
    // so both carry the rank of the first sighting.
    var twice = [track("x", 1), track("x", 1), track("y", 2)]
    var ranks2 = Sort.arrivals(twice)
    compare(keys(Sort.apply(twice, "tracks", "duration-desc", ranks2)), "yxx")
    compare(keys(Sort.apply(twice, "tracks", "vk", ranks2)), "xxy")
  }

  // A station's duration and a playlist VK sent without a count are unknowns, and an unknown
  // at the top reads as the shortest or the smallest thing in the list.
  function test_an_item_with_no_value_goes_last_either_way() {
    var tracks = [track("a", 0), track("b", 500), track("c", 20)]
    var ranks = Sort.arrivals(tracks)
    compare(keys(Sort.apply(tracks, "tracks", "duration-desc", ranks)), "bca")
    compare(keys(Sort.apply(tracks, "tracks", "duration-asc", ranks)), "cba")
    var lists = [playlist("a", 0), playlist("b", 7), playlist("c", 2)]
    var ranks2 = Sort.arrivals(lists)
    compare(keys(Sort.apply(lists, "playlists", "count-desc", ranks2)), "bca")
    compare(keys(Sort.apply(lists, "playlists", "count-asc", ranks2)), "cba")
  }

  // Two tracks of the same length are not the engine's to place: the title decides, and the
  // arrival rank decides two titles that match. The same list sorted twice is the same list.
  function test_equal_values_fall_back_to_the_title() {
    var list = [track("b", 100), track("a", 100), track("c", 50)]
    var ranks = Sort.arrivals(list)
    var once = Sort.apply(list, "tracks", "duration-desc", ranks)
    compare(keys(once), "abc")
    compare(keys(Sort.apply(list, "tracks", "duration-desc", ranks)), "abc")
    compare(keys(Sort.apply(once, "tracks", "duration-desc", ranks)), "abc")
  }

  // A new page of «Ещё» grows the rank table instead of replacing it: the items already on
  // screen keep the places they arrived in, which is what makes the page land at the end of
  // «VK order» and nowhere else — not at the end of whatever order the reader was looking at
  // when the button was pressed.
  function test_a_page_extends_the_ranks_of_what_was_already_there() {
    var first = [track("a", 300), track("b", 100)]
    var ranks = Sort.arrivals(first)
    var page = [track("c", 200)]
    var merged = Sort.extend(ranks, page)
    compare(merged.a, 0)
    compare(merged.b, 1)
    compare(merged.c, 2)
    // A key already in the table keeps its place when the same item comes back in a page.
    compare(Sort.extend(merged, [track("b", 100)]).b, 1)
    var all = first.concat(page)
    compare(keys(Sort.apply(all, "tracks", "vk", merged)), "abc")
    compare(keys(Sort.apply(all, "tracks", "duration-desc", merged)), "acb")
    // The first page's own ranks still describe the first page.
    compare(keys(Sort.apply(first, "tracks", "vk", ranks)), "ab")
  }

  // A preference is a word from outside: one the schema cannot send must reorder nothing.
  function test_an_unknown_order_is_vk_order() {
    compare(Sort.sanitize("playlists", "count-desc"), "count-desc")
    compare(Sort.sanitize("playlists", "duration-desc"), "vk")
    compare(Sort.sanitize("tracks", "count-asc"), "vk")
    compare(Sort.sanitize("tracks", ""), "vk")
    compare(Sort.sanitize("tracks", undefined), "vk")
    var list = [track("a", 300), track("b", 100)]
    var ranks = Sort.arrivals(list)
    compare(keys(Sort.apply(list, "tracks", "nonsense", ranks)), "ab")
  }

  // The array handed in belongs to the session; a sort that wrote into it would reorder the
  // list it was sorting *and* whatever else held the same array.
  function test_sorting_never_mutates_the_list_it_was_given() {
    var list = [track("a", 300), track("b", 100)]
    var ranks = Sort.arrivals(list)
    Sort.apply(list, "tracks", "duration-asc", ranks)
    compare(keys(list), "ab")
  }
}
