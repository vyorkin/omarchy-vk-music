// What is on screen, as one answer: which list the cursor walks, how its bands stand, and
// where a row's delegate lives.
//
// This was seven functions in `BarWidget.qml` giving the same answer seven times, and the
// released bugs are the ones where two answers disagreed: «j» stepping onto the first card of
// «Недавние» because the bands and the cursor disagreed about where «Друзья» ended, and a
// reveal scrolling to the far end of a section because the row for a playlist index came back
// as a track row. So the tests come in two shapes: a table of intended answers per page, and
// invariants that hold for every page — the first of which is that `items` is the segments
// joined and nothing else, which is the property that makes the two unable to disagree.
//
// The second half is what a row *means*. A plan names each segment's list; a click names the
// list it drew and the index it drew it at. The two must resolve to one action, and a play
// action's index must be a position in the raw array — a filter narrowing the queue is what
// separates the drawn position from the readable one.
//
// Run:
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
import QtQuick
import QtTest
import "../../ListShape.js" as ListShape

TestCase {
  name: "ListShape"

  function track(key, title, artist) {
    return { key: key, title: title || ("Track " + key), artist: artist || "Artist" }
  }

  function card(id, title) {
    return { id: id, title: title || ("Playlist " + id) }
  }

  function tracks(count, prefix) {
    var out = []
    for (var i = 0; i < count; i++) out.push(track((prefix || "") + i))
    return out
  }

  function cards(count) {
    var out = []
    for (var i = 0; i < count; i++) out.push(card(i))
    return out
  }

  // A section page with playlists and tracks under them, which is the shape most of the
  // assertions below start from.
  function sectionState(extra) {
    var state = {
      view: "browse",
      browseSlug: "main",
      columns: 3,
      gridView: false,
      queue: tracks(3, "q"),
      playlists: cards(4),
      tracks: tracks(10, "t")
    }
    for (var key in extra) state[key] = extra[key]
    return state
  }

  function kinds(planned) {
    var out = []
    for (var i = 0; i < planned.segments.length; i++) out.push(planned.segments[i].kind)
    return out.join(",")
  }

  function counts(planned) {
    var out = []
    for (var i = 0; i < planned.segments.length; i++) out.push(planned.segments[i].count)
    return out.join(",")
  }

  function columnsOf(planned) {
    var out = []
    for (var i = 0; i < planned.segments.length; i++) out.push(planned.segments[i].columns)
    return out.join(",")
  }

  // -- the table ---------------------------------------------------------------

  // A section is its playlists and then its tracks, in one cursor order: the cards above and
  // the rows under them. The offset of the tracks is what every index-based action needs.
  function test_a_section_is_playlists_then_tracks() {
    var planned = ListShape.plan(sectionState())
    compare(kinds(planned), "playlists,tracks")
    compare(counts(planned), "4,10")
    compare(ListShape.offsetOf(planned, "tracks"), 4)
    compare(planned.items.length, 14)
    compare(planned.gallery, false)
    compare(planned.showsPlaylists, true)
  }

  // With the gallery on the playlists stand across the card, and a band of one column is the
  // rows under them. «Моя музыка» is never a gallery: it is a hundred tracks and no playlist.
  function test_a_gallery_stands_the_playlists_across() {
    var planned = ListShape.plan(sectionState({ gridView: true }))
    compare(columnsOf(planned), "3,1")
    compare(planned.gallery, true)
    // «Моя музыка» answers no playlists, so both the wall and the switch are absent — and
    // the switch is absent without waiting for the answer, which is why it is not `browseLoading`.
    var mine = ListShape.plan(sectionState({ gridView: true, browseSlug: "all", playlists: [] }))
    compare(mine.gallery, false)
    compare(mine.showsPlaylists, false)
    compare(mine.segments.length, 1)
  }

  // The friends page is two walls with their own answers: one friend is a row, two are a
  // wall, and each counts its own cards.
  function test_the_friends_page_is_two_bands_with_their_own_columns() {
    var one = ListShape.plan({
      view: "browse", browseSlug: "friends", gridView: true, columns: 4, browseSlugIsFriends: true,
      friends: cards(1), people: cards(3)
    })
    compare(kinds(one), "friends,people")
    // A wall of three stands three across, not four: a band never claims a column it has no
    // card for, or a step down would leave the wall.
    compare(columnsOf(one), "1,3")
    compare(one.friendsGallery, false)
    compare(one.recentGallery, true)
    compare(one.gallery, true)

    var rowed = ListShape.plan({ view: "browse", browseSlug: "friends", gridView: false,
      friends: cards(3), people: cards(3) })
    compare(columnsOf(rowed), "1,1")
    compare(rowed.gallery, false)
  }

  // Radio is a list like every other, and a filter narrows it (ADR-0001). It is never a wall
  // and never offers the representation switch.
  function test_radio_filters_and_is_never_a_wall() {
    var stations = [{ id: 1, name: "Джаз" }, { id: 2, name: "Рок" }]
    var planned = ListShape.plan({ view: "browse", browseSlug: "radiostations", gridView: true,
      columns: 3, stations: stations })
    compare(kinds(planned), "stations")
    compare(planned.items.length, 2)
    compare(planned.gallery, false)
    compare(planned.showsPlaylists, false)

    var narrowed = ListShape.plan({ view: "browse", browseSlug: "radiostations", gridView: true,
      columns: 3, stations: stations, filter: "джаз" })
    compare(narrowed.items.length, 1)
    compare(narrowed.items[0].name, "Джаз")
  }

  // The filter decides the shape as well as the rows: with every playlist filtered away there
  // is no wall to walk, and the switch that offers it has gone with the wall.
  function test_a_filter_that_hides_every_playlist_takes_the_wall_with_it() {
    var planned = ListShape.plan(sectionState({ gridView: true, filter: "no-such-thing" }))
    compare(kinds(planned), "")
    compare(planned.gallery, false)
    compare(planned.showsPlaylists, false)

    var listed = ListShape.plan(sectionState({ gridView: true, filter: "Track t" }))
    compare(kinds(listed), "tracks")
    compare(ListShape.offsetOf(listed, "tracks"), 0)
    compare(listed.gallery, false)
  }

  // A person's page is their playlists and nothing else; the open playlist is tracks and
  // nothing else, whatever view it was opened from.
  function test_a_person_and_an_open_playlist_are_one_band_each() {
    var person = ListShape.plan({ view: "browse", browseSlug: "person", gridView: true,
      columns: 3, personPlaylists: cards(5) })
    compare(kinds(person), "playlists")
    compare(columnsOf(person), "3")
    compare(person.gallery, true)
    compare(person.showsPlaylists, true)

    var opened = ListShape.plan({ view: "search", searchMode: "playlists", gridView: true,
      columns: 3, openPlaylist: { id: 7 }, playlistTracks: tracks(6),
      foundPlaylists: cards(9) })
    compare(kinds(opened), "playlistTracks")
    compare(columnsOf(opened), "1")
    compare(opened.gallery, false)
    compare(opened.items.length, 6)
  }

  // A search shows results once it has run, the recent queries while the query is one
  // character, and the suggestions when the search found nothing.
  function test_a_search_shows_results_history_or_suggestions() {
    var results = ListShape.plan({ view: "search", searchState: "results", queryLength: 4,
      results: tracks(5, "r") })
    compare(kinds(results), "results")

    var history = ListShape.plan({ view: "search", searchState: "typing", queryLength: 1,
      history: ["radiohead", "kino"] })
    compare(kinds(history), "history")
    compare(history.items[0], "radiohead")

    var empty = ListShape.plan({ view: "search", searchState: "results", queryLength: 4,
      results: [], suggestions: tracks(3, "s") })
    compare(kinds(empty), "suggestions")

    var playlists = ListShape.plan({ view: "search", searchMode: "playlists", gridView: true,
      columns: 3, foundPlaylists: cards(3), searchState: "results", queryLength: 4 })
    compare(kinds(playlists), "playlists")
    compare(playlists.gallery, true)
    compare(playlists.showsPlaylists, true)
  }

  // Nothing to walk is not an error: an empty page, or a view with no list at all.
  function test_an_empty_page_is_an_empty_plan() {
    var empty = ListShape.plan({ view: "browse", browseSlug: "main" })
    compare(empty.segments.length, 0)
    compare(empty.items.length, 0)
    compare(empty.gallery, false)
    compare(ListShape.slotAt(empty, 0), null)
    compare(ListShape.offsetOf(empty, "tracks"), -1)

    var settings = ListShape.plan({ view: "settings", queue: tracks(3) })
    compare(settings.items.length, 0)
  }

  // -- the invariants every page keeps -----------------------------------------

  // The property that makes the two halves unable to disagree: `items` is exactly the
  // segments joined, each segment starts where the last one ended, and no segment is empty.
  function test_the_segments_join_into_the_cursor_list() {
    var states = [
      sectionState(),
      sectionState({ gridView: true }),
      sectionState({ filter: "Track" }),
      { view: "queue", queue: tracks(4, "q") },
      { view: "browse", browseSlug: "friends", friends: cards(2), people: cards(3), gridView: true, columns: 4 },
      { view: "browse", browseSlug: "person", personPlaylists: cards(2), gridView: true, columns: 3 },
      { view: "browse", browseSlug: "radiostations", stations: [{ id: 1, name: "Джаз" }] },
      { view: "search", searchState: "results", queryLength: 3, results: tracks(3, "r") }
    ]
    for (var i = 0; i < states.length; i++) {
      var planned = ListShape.plan(states[i])
      var joined = 0
      for (var s = 0; s < planned.segments.length; s++) {
        var segment = planned.segments[s]
        compare(segment.offset, joined)
        verify(segment.count > 0)
        verify(segment.columns >= 1)
        verify(segment.columns <= segment.count)
        joined += segment.count
      }
      compare(planned.items.length, joined)
    }
  }

  // Every index the cursor can hold belongs to exactly one segment, and `slotAt` says where.
  function test_every_index_falls_in_one_segment() {
    var planned = ListShape.plan(sectionState({ gridView: true }))
    compare(ListShape.slotAt(planned, -1), null)
    for (var i = 0; i < planned.items.length; i++) {
      var slot = ListShape.slotAt(planned, i)
      verify(slot !== null)
      compare(planned.items[i], planned.lists[slot.kind === "tracks" ? "tracks" : "playlists"][slot.index])
    }
    compare(ListShape.slotAt(planned, planned.items.length), null)
    // The row above the offset of the tracks is a playlist, and the row at it is a track:
    // this is the bug that scrolled the reveal to the far end of a section.
    compare(ListShape.slotAt(planned, 3).kind, "playlists")
    compare(ListShape.slotAt(planned, 4).kind, "tracks")
    compare(ListShape.slotAt(planned, 4).index, 0)
  }

  // The filter is the same filter on every list, and a row is matched on its title, its
  // artist or its name — the last one being all a station has.
  function test_the_filter_matches_title_artist_and_name() {
    var rows = [track("1", "Kino", "Gruppa Krovi"), track("2", "Aria", "Bekpearl"),
      { id: 3, name: "Джаз" }]
    compare(ListShape.filtered(rows, "kino").length, 1)
    compare(ListShape.filtered(rows, "aer").length, 0)
    compare(ListShape.filtered(rows, "bekpearl").length, 1)
    compare(ListShape.filtered(rows, "джаз").length, 1)
    compare(ListShape.filtered(rows, "   ").length, 3)
    compare(ListShape.filtered(rows, "KINO")[0].key, "1")
  }

  // A delegate is handed a copy of the element, so identity fails while the track is the
  // same one: the key is the fallback, and a wrong index plays the wrong song.
  function test_index_of_falls_back_to_the_track_key() {
    var rows = [track("1"), track("2")]
    compare(ListShape.indexOf(rows, rows[1]), 1)
    compare(ListShape.indexOf(rows, { key: "2", title: "a copy" }), 1)
    compare(ListShape.indexOf(rows, { key: "9" }), -1)
    compare(ListShape.indexOf(rows, null), -1)
  }

  // -- what a row means --------------------------------------------------------

  function namesOf(planned) {
    var out = []
    for (var i = 0; i < planned.segments.length; i++) out.push(planned.segments[i].list)
    return out.join(",")
  }

  // A click names the list it drew; Enter names its segment's list and its own index. If the
  // two ever named different arrays the two roads would mean different rows, so this table
  // pins the name every page's segment carries.
  function test_a_segment_names_the_list_it_was_cut_from() {
    var cases = [
      { state: { view: "queue", queue: tracks(2) }, lists: "queue" },
      { state: { view: "browse", browseSlug: "main", playlists: cards(2), tracks: tracks(2) },
        lists: "playlists,tracks" },
      { state: { view: "browse", browseSlug: "person", personPlaylists: cards(2) },
        lists: "personPlaylists" },
      { state: { view: "browse", browseSlug: "friends", friends: cards(1), people: cards(2) },
        lists: "friends,people" },
      { state: { view: "browse", browseSlug: "radiostations", stations: [{ id: 1, name: "Jazz" }] },
        lists: "stations" },
      { state: { view: "search", searchMode: "playlists", searchState: "results",
        queryLength: 3, foundPlaylists: cards(2) }, lists: "foundPlaylists" },
      { state: { view: "search", searchState: "results", queryLength: 3, results: tracks(2) },
        lists: "results" },
      { state: { view: "search", searchState: "typing", queryLength: 1, history: ["kino"] },
        lists: "history" },
      { state: { view: "search", searchState: "typing", queryLength: 2, suggestions: ["kino"] },
        lists: "suggestions" },
      { state: { view: "browse", browseSlug: "main", openPlaylist: { title: "P" },
        playlistTracks: tracks(2) }, lists: "playlistTracks" }
    ]
    for (var i = 0; i < cases.length; i++) {
      compare(namesOf(ListShape.plan(cases[i].state)), cases[i].lists)
    }
  }

  // Every list the plan files is a list a row can be started from, and every segment names
  // one of them. A list missing from the table is a page whose rows do nothing.
  function test_every_list_the_plan_files_has_an_intent() {
    var planned = ListShape.plan(sectionState())
    var missing = []
    for (var name in planned.lists) {
      if (!ListShape.INTENTS[name]) missing.push(name)
    }
    compare(missing.join(","), "")
    for (var s = 0; s < planned.segments.length; s++) {
      verify(planned.lists[planned.segments[s].list] !== undefined)
    }
  }

  // The bug this table exists for: with a filter on, the row drawn at position 0 is not the
  // first track of the queue, and `jump 0` plays the wrong song. The action's index is a
  // position in the raw array, which is what every command reads.
  function test_a_play_intent_carries_the_raw_index() {
    var queue = [track("a", "Alpha"), track("b", "Bravo"), track("c", "Charlie")]
    var planned = ListShape.plan({ view: "queue", queue: queue, filter: "charlie" })
    compare(planned.lists.queue.length, 1)
    var action = ListShape.actionAt(planned, "queue", 0)
    compare(action.kind, "playQueue")
    compare(action.index, 2)

    var section = ListShape.plan(sectionState({ filter: "t7" }))
    compare(ListShape.actionAt(section, "tracks", 0).index, 7)

    var opened = ListShape.plan(sectionState({
      openPlaylist: { title: "P" }, playlistTracks: tracks(4, "p"), filter: "p3"
    }))
    compare(ListShape.actionAt(opened, "playlistTracks", 0).kind, "playPlaylist")
    compare(ListShape.actionAt(opened, "playlistTracks", 0).index, 3)

    var found = ListShape.plan({ view: "search", searchState: "results", queryLength: 3,
      results: tracks(4, "r"), filter: "r2" })
    compare(ListShape.actionAt(found, "results", 0).kind, "playSearch")
    compare(ListShape.actionAt(found, "results", 0).index, 2)
  }

  // Everything that acts on a whole thing carries the thing, not a position: opening a
  // playlist or a person, starting a station, and a query which carries its text.
  function test_the_other_intents_carry_the_thing_itself() {
    var section = ListShape.plan(sectionState())
    var playlist = section.lists.playlists[1]
    var opened = ListShape.actionAt(section, "playlists", 1)
    compare(opened.kind, "openPlaylist")
    compare(opened.item, playlist)
    compare(opened.index, -1)

    var people = ListShape.plan({ view: "browse", browseSlug: "friends", friends: cards(2) })
    compare(ListShape.actionAt(people, "friends", 0).kind, "openPerson")
    compare(String(ListShape.actionAt(people, "friends", 0).item.id), "0")

    var radio = ListShape.plan({ view: "browse", browseSlug: "radiostations",
      stations: [{ id: 4, name: "Jazz" }] })
    compare(ListShape.actionAt(radio, "stations", 0).kind, "playStation")
    compare(ListShape.actionAt(radio, "stations", 0).item.id, 4)

    var typing = ListShape.plan({ view: "search", searchState: "typing", queryLength: 1,
      history: ["kino"] })
    compare(ListShape.actionAt(typing, "history", 0).kind, "query")
    compare(ListShape.actionAt(typing, "history", 0).text, "kino")
  }

  // Nothing to do is an answer too: it is what lets Enter keep its old meaning on an empty
  // list, and what keeps a stale index from reaching a command.
  function test_nothing_to_do_is_null() {
    var planned = ListShape.plan(sectionState())
    compare(ListShape.actionAt(planned, "playlists", -1), null)
    compare(ListShape.actionAt(planned, "playlists", 4), null)
    compare(ListShape.actionAt(planned, "nowhere", 0), null)
    compare(ListShape.actionAt(planned, "stations", 0), null)
    compare(ListShape.actionAt(null, "playlists", 0), null)
    var empty = ListShape.plan({ view: "queue", queue: [] })
    compare(ListShape.actionAt(empty, "queue", 0), null)
  }

  // The cursor's road and the delegate's road are one function: for every row of a page the
  // segment's own index resolves to the same action a click at that drawn index resolves to.
  function test_enter_and_a_click_ask_the_same_question() {
    var planned = ListShape.plan(sectionState({ gridView: true }))
    for (var i = 0; i < planned.items.length; i++) {
      var slot = ListShape.slotAt(planned, i)
      var byEnter = ListShape.actionAt(planned, slot.list, slot.index)
      var byClick = ListShape.actionAt(planned, slot.list, slot.index)
      compare(byEnter.kind, byClick.kind)
      compare(byEnter.index, byClick.index)
      compare(byEnter.item, planned.items[i])
    }
  }
}
