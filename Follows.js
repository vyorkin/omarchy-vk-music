// Marking a saved playlist across the lists that hold it.
//
// The catch is the one `Likes.js` exists for: a delegate over a JS array model is handed a
// COPY of the element, so writing `is_following` into an entry inside `root.playlists`
// changes the stored list and nothing on screen — the card keeps the copy it was born with
// and its heart stays an outline while VK already has the playlist in my music. Only a new
// array reaches the cards. So this returns a rebuilt list instead of editing the one it was
// given, and the caller assigns the answer back.
.pragma library

// The same list with every entry for `key` carrying the saved state, and the ids of the copy
// that holds it in my music (zero when it is not saved). The key names the playlist, not the
// copy — a followed list answers to the key of the original — so one card of a section, one
// card of «Избранное» and the open playlist are edited together.
//
// A list with nothing to change comes back as the very same array, so a list that does not
// hold this playlist does not make the panel rebuild it for nothing. Copies are shallow: a
// playlist is flat, and its other fields are carried over as they are.
function mark(list, key, following, copyOwner, copyPlaylist) {
  if (!list || !list.length || !key) return list
  var saved = following === true
  var owner = saved ? Number(copyOwner || 0) : 0
  var copy = saved ? Number(copyPlaylist || 0) : 0
  var changed = false
  var out = []
  for (var i = 0; i < list.length; i++) {
    var playlist = list[i]
    if (!playlist || String(playlist.key || "") !== String(key)) {
      out.push(playlist)
      continue
    }
    if ((playlist.is_following === true) === saved
        && Number(playlist.copy_owner_id || 0) === owner
        && Number(playlist.copy_playlist_id || 0) === copy) {
      out.push(playlist)
      continue
    }
    var updated = {}
    for (var name in playlist) updated[name] = playlist[name]
    updated.is_following = saved
    updated.copy_owner_id = owner
    updated.copy_playlist_id = copy
    out.push(updated)
    changed = true
  }
  return changed ? out : list
}
