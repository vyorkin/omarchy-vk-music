# ADR-0007: a page's track rows are one virtualized list, and its other bands are that list's header

Status: accepted, 2026-11-22.

## Context

ADR-0006 emptied an off-screen list in the plan so a `Repeater` would build no
rows for it. That fixed what was off screen; on screen, every row was still built.
A section's tracks, an open playlist, a person's tracks, the search results and
the queue were `Repeater`s inside one `Flickable`, so a 1000-track playlist
instantiated a thousand items, requested a cover for each, and laid them all out
even though the card shows about a dozen rows. The card's two shapes doubled the
work. ADR-0006 named this as the remaining cost and left a `Loader` for later.

The four track bands were also four code paths: each band had its own repeater,
and a page's non-row bands (chips, «Моя музыка»'s tabs, a gallery, a header) were
siblings above that repeater in a column. Which band a page drew was decided in
the widget, while `plan()` had already decided which lists were on screen — two
answers to one question again, the defect ADR-0001 and ADR-0002 were written
about, this time about the band rather than the filter or the row.

## Decision

1. Each body (`TrackList`) holds **one `ListView`** for the page's track rows. Its
   `model` is the single list `ListShape.trackKindOf(plan)` names — the queue,
   the catalog page's tracks, an open playlist's tracks, or the search's results —
   or `[]` when the page has no rows. Which band that is comes from the plan's
   segments and the open playlist, not from the tab: an open playlist still
   outranks «Очередь».
2. Every non-row band is the list's **`header`**, in one `Column` in cursor order.
   Bands keep their own ids and the cursor's repeaters, so their behaviour is
   unchanged; they scroll with the rows instead of taking height in a layout. The
   page's «Ещё» row is the list's `footer`, under the rows it describes. The
   loading line is not in the list: it is drawn over the card's bottom edge.
3. Rows are the `ListView`'s delegates. Only the rows the viewport shows, plus a
   reuse buffer, are instantiated; a cover is requested only for a row that exists.
4. The cursor does not compute a track row's position. `rowAt` resolves the
   header's bands through the header's exported repeaters, and reveals a track row
   with `ListView.positionViewAtIndex` / `itemAtIndex`; the first visible row is
   `ListView.indexAt`. A header band's reveal still maps into `contentRoot`, which
   is the space `contentY` counts in.
5. A row's `y` and a band's height are the list's business, not arithmetic the
   widget repeats: the header's height and the row pitch are not baked into any
   index calculation.

## Consequences

* Opening a 1000-track queue or playlist builds a dozen items, not a thousand, and
  the cover requests follow the built rows.
* The four track bands are one delegate definition and one model binding, so a
  change to a track row is made once.
* The header is not virtualized. A page whose header is a thousand-card gallery
  still builds the whole gallery; the header is bounded by the page's own bands,
  and measuring one before changing it is the next step.
* `TrackList` is still a `ColumnLayout` (the sticky status bar and the hints row
  sit under the list), so the wheel handler, the page reset and the reveal address
  the inner `scroller` rather than the component.
* `ListShape.trackKindOf(plan)` is now part of the module's interface and is
  tested by `tests/qml/tst_list_shape.qml`, including the open-playlist-over-queue
  case and a page with no track band.

## Alternatives rejected

* **A `Loader` per section.** Rejected: it moves ids and focus, and it still builds
  every row of the section it loads. Virtualizing the rows is the cheaper fix.
* **A `Repeater` whose `model` is sliced to the viewport.** Rejected: the slice is
  the viewport's arithmetic written by hand, with the scroll offset and the row
  height to keep in step, and it loses the item reuse Qt already does.
* **Keeping the four repeaters and hiding the off-screen ones.** Rejected: it is
  ADR-0006's answer for lists that are not on screen, and it does nothing for the
  list that is.
