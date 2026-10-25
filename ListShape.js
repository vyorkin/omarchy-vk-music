// What is on screen: which list the cursor walks, how many cards stand across each
// band of it, and where a row's delegate lives. One module, because the answer was
// being given seven times.
//
// Before this file, `BarWidget.qml` carried the same five inputs — the view, the
// browse slug, an open playlist, the search mode and the gallery preference — through
// seven separate branch matrices: `cursorItems`, `galleryBands`, `browseCursorOffset`,
// `rowAt`, `galleryMode`, `playlistsShown`, `barRowEmpty`. A page that was a gallery for
// one of them was a plain list for another, and the released bugs are the ones where two
// answers disagreed: «j» landing on the first card of «Недавние» because the bands and the
// cursor disagreed about where the friends ended, and a reveal scrolling to the far end of
// a section because `rowAt` returned a track row for a playlist index.
//
// The shape is a plan: a list of segments in cursor order. Each segment knows the kind of
// thing it holds, where it starts in the cursor's list, how long it is and how many stand
// across it. `items` is those segments joined, so the cursor's list and the rows on screen
// are literally the same array — the one thing that cannot disagree with itself.
//
// Two rules this file keeps, both from ADR-0001:
//   * the filter applies to every list, and
//   * every decision about the *shape* of a list counts the filtered list, never the raw
//     one, because the filter is what decides whether a wall of cards is still there.
//
// What it deliberately does NOT own: the delegate lookup. `rowAt` in the widget takes
// `slotAt(index)` and asks the repeater for the item; that is QML, and a segment can say
// `{ kind: "tracks", index: 3 }` without knowing a repeater's id.
//
// It also owns what a row *means*. A plan names each segment's list and its kind; a delegate
// knows the index it drew; `actionAt` turns the two into one intent and one position in the
// array the command will read. Before that function there were four answers to "what does
// this row do" — `activateCursor`, the delegate's own `onActivated`, and the position each of
// them computed — and the two positions disagreed: Enter handed the filtered index to a
// command that reads the raw list, so with a filter on it played the row above the click.
//
// The answers below that are not obviously shape-shaped are preserved on purpose, and each
// one cost a commit to learn:
//   * «Моя музыка» (`browseSlug === "all"`) is a hundred tracks and never a playlist, so it
//     is never a gallery and the representation switch has nothing to say there;
//   * one friend is not a wall (`friendsGallery` needs more than one card), so a section of
//     one is drawn as the row it would be with the gallery off;
//   * while a search is shorter than two characters the list on screen is the recent
//     queries, and when a search found nothing it is the suggestions.
.pragma library

// The lists the panel can put the cursor on. `kind` names the *thing* a segment holds, not
// the QML item that draws it: the widget keeps a kind-to-repeater table, so a test of this
// file never has to know a delegate's id.
var KINDS = {
  playlistTracks: "playlistTracks",
  queue: "queue",
  playlists: "playlists",
  tracks: "tracks",
  friends: "friends",
  people: "people",
  stations: "stations",
  results: "results",
  history: "history",
  suggestions: "suggestions"
}

function trimmed(text) {
  return String(text === undefined || text === null ? "" : text).trim()
}

// A row matches when the filter appears in its title, its artist or its name. Stations
// carry a `name` and no title, which is why `name` is one of the three.
function matches(item, filter) {
  if (!item) return false
  var needle = filter.toLowerCase()
  var haystack = String(item.title || "") + " " + String(item.artist || "")
    + " " + String(item.name || "")
  return haystack.toLowerCase().indexOf(needle) >= 0
}

function filtered(items, filter) {
  var needle = trimmed(filter)
  if (needle === "" || !items) return items || []
  var out = []
  for (var i = 0; i < items.length; i++) {
    if (matches(items[i], needle)) out.push(items[i])
  }
  return out
}

// A row can hold a copy of the object rather than the object itself: a delegate over a JS
// array model is handed a copy, so identity fails while the track is the same one. The key
// is what identifies a track, and a wrong index plays the wrong song — worse than any
// lookup — so it is the fallback.
function indexOf(list, item) {
  if (!list || !item) return -1
  for (var i = 0; i < list.length; i++) {
    if (list[i] === item) return i
  }
  for (var j = 0; j < list.length; j++) {
    if (list[j] && item.key !== undefined && String(list[j].key) === String(item.key)) return j
  }
  return -1
}

function array(value) {
  return value && value.length !== undefined ? value : []
}

// One segment, appended to `segments` and to `items` together, so the two can never drift.
// `scope` says where the segment came from — a section's playlists and a search's playlists
// are the same kind of thing drawn by two different repeaters, and a segment that named only
// its kind would leave the widget guessing which one it meant.
//
// `name` is the array the rows were cut from, under the name `plan` files it by. It is what
// lets a segment, a delegate and a command speak of one list: a click names the array it drew
// and Enter names its segment, and both resolve to the same rows.
function append(built, scope, name, kind, list, columns) {
  if (list.length === 0) return
  built.segments.push({
    scope: scope,
    list: name,
    kind: kind,
    offset: built.items.length,
    count: list.length,
    columns: Math.max(1, Math.min(columns, list.length))
  })
  for (var i = 0; i < list.length; i++) built.items.push(list[i])
}

// `state` carries the lists under the same twelve names this function returns them by:
// a caller that has them holds them as `queue`, `tracks`, `playlistTracks`, and nothing
// translates between two vocabularies on the way in.
function plan(state) {
  var s = state || {}
  var filter = trimmed(s.filter)
  var columns = Number(s.columns) || 3
  var gridView = s.gridView === true
  var extended = s.extended === true
  var browseLoading = s.browseLoading === true
  var queryLength = Number(s.queryLength) || 0
  var searchState = String(s.searchState || "typing")
  var browseSlug = String(s.browseSlug || "")
  var searchMode = String(s.searchMode || "tracks")
  var view = String(s.view || "")
  var openPlaylist = s.openPlaylist === undefined ? null : s.openPlaylist

  // The state's own arrays, untouched. These are what a command reads when a row is
  // started, and a command takes a *position*: `jump 3` is the fourth track of the queue
  // whether a filter is on or not. They sit beside `lists` so `actionAt` can compute one
  // index from the other, and under the same twelve names, so a segment, a delegate and a
  // command never mean three different lists.
  var raw = {
    queue: array(s.queue),
    playlistTracks: array(s.playlistTracks),
    playlists: array(s.playlists),
    tracks: array(s.tracks),
    personPlaylists: array(s.personPlaylists),
    friends: array(s.friends),
    people: array(s.people),
    stations: array(s.stations),
    foundPlaylists: array(s.foundPlaylists),
    results: array(s.results),
    history: array(s.history),
    suggestions: array(s.suggestions)
  }

  // The lists, filtered once. Every read below goes through these, which is what keeps the
  // cursor and the rows from disagreeing about what a filter left behind.
  var lists = {
    queue: filtered(raw.queue, filter),
    playlistTracks: filtered(raw.playlistTracks, filter),
    playlists: filtered(raw.playlists, filter),
    tracks: filtered(raw.tracks, filter),
    personPlaylists: filtered(raw.personPlaylists, filter),
    friends: filtered(raw.friends, filter),
    people: filtered(raw.people, filter),
    stations: filtered(raw.stations, filter),
    foundPlaylists: filtered(raw.foundPlaylists, filter),
    results: [],
    // The recent queries are the list on screen only while the field holds one character or
    // none: past that the search has something to show. Gated here, so the rows and the
    // cursor read the same array rather than each applying the rule.
    history: queryLength < 2 ? raw.history : [],
    suggestions: []
  }

  // A search answers in two shapes as well: results once it has run, and — while the query
  // is still one character, or when the search found nothing — what the panel can suggest
  // instead. Filtering those again would ask the list to match a text it came from.
  var resultsShowing = searchState === "results" && queryLength >= 2
  lists.results = resultsShowing ? filtered(raw.results, filter) : []
  lists.suggestions = queryLength < 2 ? []
    : (resultsShowing
      ? (raw.results.length === 0 ? raw.suggestions : [])
      : raw.suggestions)

  // One wall of friends and one wall of recently opened people are two bands with two
  // answers, because a section of one is a row: each counts its own cards.
  var friendsGallery = gridView && lists.friends.length > 1
  var recentGallery = gridView && lists.people.length > 1

  var built = { segments: [], items: [] }
  var gallery = false
  var showsPlaylists = false

  if (openPlaylist !== null && openPlaylist !== undefined) {
    // Whatever view it was opened from, an open playlist is the list on screen, and its
    // tracks are rows: a playlist is never a wall, even with the gallery on for playlists.
    append(built, "playlist", "playlistTracks", KINDS.playlistTracks, lists.playlistTracks, 1)
  } else if (view === "queue") {
    append(built, "queue", "queue", KINDS.queue, lists.queue, 1)
  } else if (view === "browse") {
    if (browseSlug === "person") {
      append(built, "person", "personPlaylists", KINDS.playlists, lists.personPlaylists, columns)
      gallery = gridView && lists.personPlaylists.length > 0
    } else if (browseSlug === "friends") {
      append(built, "friends", "friends", KINDS.friends, lists.friends, friendsGallery ? columns : 1)
      append(built, "friends", "people", KINDS.people, lists.people, recentGallery ? columns : 1)
      gallery = friendsGallery || recentGallery
    } else if (browseSlug === "radiostations") {
      append(built, "radio", "stations", KINDS.stations, lists.stations, 1)
    } else {
      // A section is its playlists and then its tracks under them, in one cursor order:
      // the cards above, the rows below.
      append(built, "section", "playlists", KINDS.playlists, lists.playlists, columns)
      append(built, "section", "tracks", KINDS.tracks, lists.tracks, 1)
      gallery = gridView && lists.playlists.length > 0
    }
    if (browseSlug !== "radiostations") {
      if (browseSlug === "friends" || browseSlug === "person") {
        // People are drawn as cards or as rows as well, so the switch means the same thing
        // on the friends page and on a person's page as it does for playlists.
        showsPlaylists = true
      } else if (browseSlug !== "all") {
        // «Моя музыка» is the one section that is a hundred tracks and never a playlist, so
        // the switch has nothing to say there and says it without waiting for an answer. A
        // section that is still loading has no playlists to count yet: asked on the rows
        // alone, the two cells vanished for as long as the request took.
        showsPlaylists = browseLoading || lists.playlists.length > 0
      }
    }
  } else if (view === "search") {
    if (searchMode === "playlists") {
      append(built, "search", "foundPlaylists", KINDS.playlists, lists.foundPlaylists, columns)
      gallery = gridView && lists.foundPlaylists.length > 0
      showsPlaylists = true
    } else if (lists.results.length > 0) {
      append(built, "search", "results", KINDS.results, lists.results, 1)
    } else if (queryLength < 2 && lists.history.length > 0) {
      append(built, "search", "history", KINDS.history, lists.history, 1)
    } else {
      append(built, "search", "suggestions", KINDS.suggestions, lists.suggestions, 1)
    }
  }

  return {
    lists: lists,
    // The same twelve arrays before the filter, which is what a command positions into.
    raw: raw,
    segments: built.segments,
    items: built.items,
    // The bands `GalleryWalk.step` walks: the same segments, and a segment of one column is
    // the rows under a wall. A list with no wall in it is still one segment, so a step that
    // is never taken cannot read an empty array and lose the cursor.
    bands: built.segments,
    gallery: gallery,
    showsPlaylists: showsPlaylists,
    friendsGallery: friendsGallery,
    recentGallery: recentGallery,
    extended: extended
  }
}

// Which segment an index falls in, and where it falls inside it. This is the half of the
// old `rowAt` that described the list; the other half — asking a repeater for its delegate
// — stays in the widget, because a delegate's id is QML's business and not this file's.
function slotAt(planned, index) {
  if (!planned || !planned.segments || index < 0) return null
  for (var i = 0; i < planned.segments.length; i++) {
    var segment = planned.segments[i]
    if (index < segment.offset + segment.count) {
      return {
        scope: segment.scope,
        list: segment.list,
        kind: segment.kind,
        index: index - segment.offset,
        segment: i
      }
    }
  }
  return null
}

// Where a kind starts in the cursor's list, or -1. A section's tracks begin after its
// playlists; the queue and an open playlist are their own first segment.
function offsetOf(planned, kind) {
  if (!planned || !planned.segments) return -1
  for (var i = 0; i < planned.segments.length; i++) {
    if (planned.segments[i].kind === kind) return planned.segments[i].offset
  }
  return -1
}

// What a row means, by the list it was cut from. The value names the intent; the widget
// keeps one call per intent and no branch on which page is open. A list that is not here
// has no action, which is the honest answer for a list nobody can start.
var INTENTS = {
  queue: "playQueue",
  playlistTracks: "playPlaylist",
  tracks: "playSection",
  results: "playSearch",
  playlists: "openPlaylist",
  personPlaylists: "openPlaylist",
  foundPlaylists: "openPlaylist",
  friends: "openPerson",
  people: "openPerson",
  stations: "playStation",
  history: "query",
  suggestions: "query"
}

// One row, one action. `drawnIndex` is a position in the list as drawn — what a delegate
// has, and what a segment's own index counts in — and the answer's `index` is a position
// in the same list *before* the filter, because that is the array a command reads.
//
// The two are not the same number: with a filter on, the third row drawn is the ninth
// track of the queue, and `jump 2` plays the wrong song. This function is the one place
// where the first becomes the second.
//
// What a caller must know:
//   * `null` means there is nothing to do — an empty list, an index past the end, a list
//     with no intent — and the widget must fall back to whatever the key meant before;
//   * `index` is `-1` for everything that acts on the whole thing (opening a playlist or a
//     person, starting a station) and for a query, which carries `text` instead;
//   * `item` is the element as drawn, so an object is the one the panel holds.
function actionAt(planned, list, drawnIndex) {
  if (!planned || !planned.lists || !planned.raw) return null
  var name = String(list === undefined || list === null ? "" : list)
  var intent = INTENTS[name]
  if (!intent) return null
  var drawn = planned.lists[name]
  var position = Number(drawnIndex)
  if (!drawn || !(position >= 0) || position >= drawn.length) return null
  var item = drawn[position]
  if (item === undefined || item === null) return null
  var action = { kind: intent, list: name, item: item, index: -1, text: "" }
  if (intent === "query") {
    action.text = String(item)
    return action
  }
  if (intent === "openPlaylist" || intent === "openPerson" || intent === "playStation") return action
  // A copy of an object is handed to a delegate, so identity fails while the track is the
  // same one. `indexOf` falls back to the key for exactly that reason; a wrong index plays
  // the wrong song, which is worse than any lookup.
  action.index = indexOf(planned.raw[name], item)
  return action
}
