# omarchy-vk-music

A VK Music card for the Omarchy shell: a daemon owns the account, playback and the
cache; the card draws views, pages, bands and lists.

## Language

**Card**:
The panel's popup. It has two shapes, the **compact card** and the **wide card**.
_Avoid_: popup body, корпус

**View**:
One of the card's tabs: Queue, Browse, Search, Settings.
_Avoid_: таб, экран

**Page**:
What Browse shows: a catalog section, a person, an artist, or an open playlist.
_Avoid_: секция (when a page is meant)

**Band**:
A group of rows or cards drawn together inside a view or page — the playlists band
under a section, the two bands of an artist's page.
_Avoid_: секция (when a band is meant)

**List**:
A named array the session stores and the panel draws: `queue`, `tracks`,
`playlistTracks`, `results` and their kin.
_Avoid_: коллекция, массив

**Plan**:
The one answer to which lists and segments are on screen — after filtering, in the
order each list itself carries — and in which order. Rows, the cursor and the
counts all read it.
_Avoid_: layout, view model

**List position**:
An item's place in its list before the filter. A command takes a list position.
_Avoid_: raw index (only in prose about the old bug)

**Drawn position**:
An item's place among the rows as drawn, after the filter. A delegate holds a
drawn position; the cursor walks drawn positions.
_Avoid_: filtered index

**Off-screen list**:
A list the current view, page or band does not draw, while the session still holds
it. Its items are not built into rows.
_Avoid_: hidden list (that names a row's visibility, not a list's absence)
