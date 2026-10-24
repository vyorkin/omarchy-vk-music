// Marking a like across the lists that hold the track.
//
// The catch this exists for: a delegate over a JS array model is handed a COPY of the
// element, not the element itself. Writing `is_liked` into a track inside `root.queue`
// therefore changes the stored list and nothing on screen — the row keeps the copy it was
// born with, and the row's heart stays an outline while the backend already has the like.
// Only a new array reaches the rows, because replacing the model is what rebuilds the
// delegates. So this returns a rebuilt list instead of editing the one it was given, and
// the caller assigns the answer back.
.pragma library

// The same list with every entry for `key` carrying `liked`. A list with nothing to change
// comes back as the very same array, so a row that is not in this list does not make the
// panel rebuild it for nothing. Copies are shallow: a track is flat, and its other fields
// are carried over as they are.
function mark(list, key, liked) {
  if (!list || !list.length || !key) return list
  var changed = false
  var out = []
  for (var i = 0; i < list.length; i++) {
    var track = list[i]
    if (track && String(track.key || "") === String(key) && (track.is_liked === true) !== (liked === true)) {
      var updated = {}
      for (var name in track) updated[name] = track[name]
      updated.is_liked = liked === true
      out.push(updated)
      changed = true
    } else {
      out.push(track)
    }
  }
  return changed ? out : list
}
