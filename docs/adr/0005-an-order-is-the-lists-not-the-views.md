# ADR-0005: an order is the list's, not the view's

Status: accepted, 2026-11-18.

## Context

Two sorts were asked for: playlists by how many tracks they hold, and tracks by
how long they are. The obvious place for them was the view — `ListShape.plan()`
already narrows a list with a filter, so a different order could be a second
transform on the same rows.

That is the shape ADR-0002 was written about, one transform further. A sorted
*plan* would put the drawn order out of step with the raw array that commands
read: `jump N` is a place in the queue, `playBrowseTrack(N)` indexes
`root.browseTracks`, and `play_tracks` is sent a list with an index. Every action
would then need a second conversion — drawn index to sorted index to raw index —
and the first one to forget it would play the wrong track, silently, exactly as
the filter once did.

There is also a semantic question the plan cannot answer: «Играть весь
плейлист» builds a queue from `playlistTracks`. If the screen is sorted by length
and the array is not, the queue that starts from the screen is in an order the
screen never showed.

`queue` is the opposite case. Its order *is* the order of playback; a queue
sorted by length would be a different queue, not a different drawing of it.

## Decision

1. The order is applied to the array the session stores, by `Sort.apply()`,
   through the single door an answer comes in by: `SessionLists.put(name, list)`.
   Every reader — the rows, the queue `Играть весь плейлист` builds, «Ещё»'s
   offset, the cursor — reads that one array, so they cannot disagree.
2. `put()` records the order the answer arrived in as a rank per `key`
   (`Sort.arrivals`), not as a copy of the array. A like or a follow rebuilds a
   list in place (`SessionLists.like`/`follow`), and a copy would undo the
   rebuild on the next sort.
3. `vk` — the order VK sent — is a choice like the others, and is restored from
   the rank table. VK's orders are meaningful: a section is curated, «Моя музыка»
   is newest like first.
4. The two choices are preferences (`playlistSort`, `trackSort`), `shown: false`:
   they are drawn as a cell in the popup's bar with a menu, not as labelled rows
   in the settings.
5. Lists `Sort` does not name are never reordered — the queue above all. An item
   with no value (a station's duration, a playlist VK sent with no count) sorts to
   the end whichever way the rest is sorted.

## Consequences

* A different order is a rebuild of the loaded lists, not a refetch. A page
  appended with «Ещё» extends the rank table (`Sort.extend`) instead of replacing
  it: the page on screen keeps the places VK sent, and the new page lands after
  them in «Порядок VK», whichever order the reader was looking at when it came.
* A sort at the wrong moment moves rows under the pointer: `changeSort()` holds
  the item under the cursor by `key` across the rebuild, so Enter after `s` plays
  what it played before.
* `reset()` drops the ranks with the lists (they describe items that are gone)
  and keeps the chosen order (it is the panel's preference, not the account's).
