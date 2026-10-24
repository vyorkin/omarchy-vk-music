# ADR-0001: the list filter applies to every list

Status: accepted, 2026-10-24.

## Context

`/` filters the list that is on screen. Until this decision the filter was applied
by each list's own code, and three lists had quietly been left out of it:

* **Radio.** `cursorItems()` returned `root.stations` raw, while every other list
  went through `filtered()`. Stations carry a `name`, which is one of the three
  fields `matchesFilter` reads, so the field accepted the query, showed it in the
  heading and filtered nothing. The station rows were drawn from the raw list, so
  the cursor and the rows agreed with each other and only the user disagreed.
* **A section whose playlists the filter had hidden.** `galleryMode` counted the
  *raw* `browsePlaylists.length`, while `playlistsShown` — the switch that offers
  the gallery — counted the filtered length. A filter that hid every playlist left
  the switch gone and `h`/`l` still walking a wall of cards that were not on screen.
* **A playlist search with nothing left.** The same raw length in `galleryMode`
  for `foundPlaylists`.

The filter decides what is on screen, and it decides the *shape* of the list as
well: how many bands the cursor walks, how many cards stand across them, and
whether the list is a wall at all. So "which lists does the filter apply to" is not
a detail of one view; it is a property of the panel.

## Decision

The filter applies to every list the panel draws, without exception.

1. Every list that reaches the cursor goes through `filtered()`: radio included.
2. Every decision about the list's *shape* — `galleryMode`, `friendsGallery`,
   `recentGallery`, `playlistsShown` — counts the filtered list, never the raw one.
3. A list's rows and the cursor's items are always the same array. When a model is
   drawn filtered, the cursor is built from the same filtered array, and an index
   taken from the cursor indexes that array.

## Consequences

* Typing a filter on «Радио» narrows the stations. This is a visible behaviour
  change, made deliberately: the field is the same field everywhere.
* `h`/`l` stop walking a gallery whose cards the filter has hidden, which is what
  the switch already said.
* A future list added to the panel inherits the rule instead of re-deciding it.
  The rule lives in one place: `ListShape.plan()` in `ListShape.js` returns the
  filtered lists and the shape derived from them together, so a list cannot be
  drawn filtered while the cursor walks it raw — the two answers come from one
  call.
* Headings still count the unfiltered list and say `фильтр: …` beside it; the
  heading describes the list, the filter describes the view. That distinction is
  unchanged by this decision.

## Alternatives rejected

* **Filter inside each view's code, as before.** Rejected: three views had already
  disagreed with the rule, and nothing in the code said what the rule was.
* **Filter only the lists that have rows.** Rejected: it is the same exception
  that radio was, stated for a different reason.
