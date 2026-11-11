// What the session fetched, in one place.
//
// Three obligations used to be spread over the widget and disagreed with each other:
// forgetting a session was thirty assignments by name, repainting a like was a list of four
// arrays out of eleven, and "this list is loading" was eight flags plus two sequence
// counters, each with its own way of going stale. A field added to one of them silently
// missed the other two, and the released bugs are exactly that: a section page that stayed
// «пусто» because its retry counter survived an account switch, and a like that repainted
// the queue but not the search results.
//
// So the lists live here, under the names `ListShape.plan()` files them by, and the three
// obligations are three methods:
//
//   reset()          every list, every flag, every counter — a session is not a subset
//   like(key, liked) every list that can hold the track, not the four somebody remembered
//   begin/accept/fail  one rule for a stale answer, wherever the answer was going
//
// What it deliberately does not own: the view (which tab, which section, what is filtered,
// where the cursor is) and the two lists that arrive with the status rather than from a
// fetch — the recent queries and the recent people. Those are the panel's, and `state()`
// leaves room for them.

import QtQuick
import "Likes.js" as Likes
import "Follows.js" as Follows

QtObject {
  id: session

  // The lists a command fills. Names are the plan's: a section's tracks are `tracks`,
  // an opened playlist's are `playlistTracks`.
  property var queue: []
  property var tracks: []
  property var playlists: []
  property var playlistTracks: []
  property var personPlaylists: []
  property var friends: []
  property var stations: []
  property var foundPlaylists: []
  property var results: []
  // The artist search is a third kind of answer to the same box, and its page rule is
  // the same: a full page is the only sign another exists.
  property var artists: []
  property bool artistsMore: false
  // A full page came back, so VK may have another one after it. The answer's own
  // `count` cannot say this: it is not a total.
  property bool resultsMore: false
  property var suggestions: []
  // The bar's chips: a section list like the rest, and the one the bar cannot afford to
  // lose, which is why it is asked for again the moment the session changes.
  property var sources: []

  // Counters that belong to the data rather than to a page.
  property double sourcesLoadedAt: 0
  property double sourcesAskedAt: 0
  property int foundPlaylistsTotal: 0
  property int emptySectionTries: 0

  // Loading flags and the guards that decide whether an answer is still wanted. A guard is
  // a *page*, not a list: a section, a person and an opened playlist all answer into
  // different lists but cancel one another, because the user has moved on to another page.
  property var _flags: ({})
  property var _tokens: ({})

  // The lists, under the names `plan()` reads. `history` and `people` arrive with the
  // status, so the panel adds them to what this returns.
  function state() {
    return {
      queue: session.queue,
      tracks: session.tracks,
      playlists: session.playlists,
      playlistTracks: session.playlistTracks,
      personPlaylists: session.personPlaylists,
      friends: session.friends,
      stations: session.stations,
      foundPlaylists: session.foundPlaylists,
      results: session.results,
      artists: session.artists,
      suggestions: session.suggestions
    }
  }

  // Start a fetch. `guard` is the page the answer belongs to, `flag` is what the interface
  // draws «загрузка…» for; without a flag the guard's own name is used. The token is
  // opaque on purpose: a caller hands it back, and cannot construct one that is current.
  function begin(guard, flag) {
    var name = String(guard)
    var token = { guard: name, flag: flag === undefined ? name : String(flag), stamp: 0 }
    token.stamp = (session._tokens[name] || 0) + 1
    var tokens = ({})
    for (var key in session._tokens) tokens[key] = session._tokens[key]
    tokens[name] = token.stamp
    session._tokens = tokens
    session.setLoading(token.flag, true)
    return token
  }

  // Is this answer still wanted? A fetch is answered once: taking the answer retires the
  // token, so a duplicate callback paints nothing, and a stale answer clears nothing —
  // because the fetch that superseded it owns the flag now.
  function accept(token) {
    if (!session.current(token)) return false
    session.setLoading(token.flag, false)
    session.cancel(token.guard)
    return true
  }

  // The same, for a fetch that ended without an answer: the flag has to go even when the
  // answer did not arrive, which is the half that used to be forgotten.
  function fail(token) {
    if (!session.current(token)) return false
    session.setLoading(token.flag, false)
    session.cancel(token.guard)
    return true
  }

  function current(token) {
    if (!token) return false
    return (session._tokens[token.guard] || 0) === token.stamp
  }

  // Stop wanting an answer for one guard. Its flag goes with it: a fetch that nobody wants
  // must not leave the loading line running, which is what happened when a page was left
  // while its request was in flight.
  function cancel(guard) {
    var name = String(guard)
    var tokens = ({})
    for (var key in session._tokens) tokens[key] = session._tokens[key]
    tokens[name] = (tokens[name] || 0) + 1
    session._tokens = tokens
  }

  // Nothing is loading, and no answer still in flight is wanted. Stepping back from a page
  // means both: the flag has to go, and the answer must not paint the page it left.
  function clearLoading() {
    for (var name in session._flags) session.cancel(name)
    session._flags = ({})
  }

  // Every write builds a new map. QML compares the value it is handed with the one a var
  // property already holds, so mutating this map in place and assigning the same object
  // back notifies no binding: the word a page shows is the one its binding last evaluated,
  // and a heading that is nothing but that word — a person's name is read only after it —
  // stayed on «Открываю…» after the answer had already arrived.
  function setLoading(name, value) {
    var flags = ({})
    for (var key in session._flags) flags[key] = session._flags[key]
    flags[String(name)] = value === true
    session._flags = flags
  }

  function loading(name) {
    return session._flags[String(name)] === true
  }

  // Something is loading. The status line draws «…» for this, and the panel used to sum
  // eight flags by hand at every new one.
  function anyLoading() {
    for (var name in session._flags) {
      if (session._flags[name] === true) return true
    }
    return false
  }

  // A track's heart is one fact about every list that holds a copy of it: a delegate is
  // handed a copy, so the list has to be rebuilt rather than edited in place. `Likes.mark`
  // is that rebuild; this finds the lists it has to be done to.
  //
  // It finds them by what they hold — a track has a `key`, a playlist, a station and a
  // person do not — rather than by their names. A hand-written list of four arrays is
  // exactly what left the fifth one unrepainted, and the next list of tracks would join it.
  function like(key, liked) {
    for (var name in session.lists()) {
      if (!session.holdsTracks(name)) continue
      session[name] = Likes.mark(session[name], key, liked)
    }
  }

  // The lists this module owns, by the names the plan reads.
  function lists() {
    return {
      queue: session.queue,
      tracks: session.tracks,
      playlists: session.playlists,
      playlistTracks: session.playlistTracks,
      personPlaylists: session.personPlaylists,
      friends: session.friends,
      stations: session.stations,
      foundPlaylists: session.foundPlaylists,
      results: session.results,
      artists: session.artists,
      suggestions: session.suggestions,
      sources: session.sources
    }
  }

  function holdsTracks(name) {
    var list = session[name]
    if (!list || list.length === 0) return false
    return list[0] !== null && list[0] !== undefined && list[0].key !== undefined
  }

  // A playlist is in several lists too — a section page, a person's page, «Избранное» — and
  // a follow is one fact about all of them, for the same reason a like is: a delegate holds
  // a copy, so the list has to be rebuilt rather than edited. Found by what a playlist has
  // (`playlist_id`), never by a hand-written list of names: the next list of playlists would
  // join it and be left unpainted.
  function follow(key, following, copyOwner, copyPlaylist) {
    for (var name in session.lists()) {
      if (!session.holdsPlaylists(name)) continue
      session[name] = Follows.mark(session[name], key, following, copyOwner, copyPlaylist)
    }
  }

  function holdsPlaylists(name) {
    var list = session[name]
    if (!list || list.length === 0) return false
    return list[0] !== null && list[0] !== undefined && list[0].playlist_id !== undefined
  }

  // Nothing of the old session survives: not a list, not a flag, not a counter. A field
  // added here is forgotten by every account switch without anyone remembering to.
  function reset() {
    var all = session.lists()
    for (var name in all) session[name] = []
    session.sourcesLoadedAt = 0
    session.sourcesAskedAt = 0
    session.foundPlaylistsTotal = 0
    session.resultsMore = false
    session.artistsMore = false
    session.emptySectionTries = 0
    session._flags = ({})
    session._tokens = ({})
  }
}
