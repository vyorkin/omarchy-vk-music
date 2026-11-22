# ADR-0006: an off-screen list is empty in the plan, not merely invisible

Status: accepted, 2026-11-22.

## Context

`ListShape.plan()` already applies the rule "a band that is not on screen is
emptied in `lists`" to the bands *inside* a page: an artist's two tabs, «Моя
музыка»'s two tabs, the two scopes of search. The raw array keeps both answers, so
switching bands costs no request.

The rule stopped at the page boundary. `queue`, `tracks`, `playlistTracks` and
`results` stayed full while their view was not the one on screen. That mattered
because a `Repeater` builds its delegates whether or not an ancestor is
`visible: false`: after a search of 300 results and a queue of 100, the panel held
the rows of every list it had ever shown, with a cover request for each, and the
list the user was looking at was not among the reasons.

The card's two shapes doubled it: `compactBody` and `extendedBody` are both
instantiated, each with its own `TrackList`, so the visible list was built twice
before anything was even off screen.

Three answers were available. A guard on each repeater's `model` repeats "which
view draws this list" in eighteen places — the defect ADR-0001 was written about,
one level down. A `Loader` per section stops the construction entirely but moves
ids, focus and the `activeList()` identity, and the gain over emptying the model
was not measured. Emptying the list in the plan keeps one answer, the one the
rows, the cursor and the counts already read.

## Decision

1. `plan()` returns `lists.<name>` non-empty only when the current view, page or
   band draws that list. Off-screen lists are `[]`; `raw` keeps every array, so
   commands, the queue and a return to the view need nothing refetched.
2. No delegate or repeater guards its own `model` against the view. Which list is
   on screen is a property of the plan, the way ADR-0001 made the filter one.
3. The card's shape is not part of the plan. One plan serves both shapes, so the
   card empties the list models of the shape it is not showing; the data stays in
   the session, and switching shape rebuilds rows from the same plan. A `Loader`
   that removes the hidden shape entirely is a later, measurable change.
4. `raw` is never emptied for a view change. An off-screen list means "not drawn",
   not "gone": `jump N` still names a queue position while Search is open.
5. The tests in `tst_list_shape.qml` assert both sides: a list is empty while its
   view is elsewhere, and its raw array is unchanged; switching back restores it.

## Consequences

* `lists` now means "the lists as drawn", not "the lists the session has". The
  glossary names the other side **off-screen list**.
* The cursor and `ListShape.actionAt()` are unchanged: segments only ever contained
  drawn lists, and they still read the same names.
* Memory and delegate count are bounded by what is on screen instead of by
  everything ever visited.
* A new list inherits the rule by naming the view, page or band that draws it. A
  list with no such owner is a bug the plan cannot hide.
* The second shape's player and header are still instantiated while it is hidden;
  that is cosmetic until a measurement says otherwise.

## Alternatives rejected

* **A view guard on every repeater's `model`.** Rejected: eighteen copies of one
  rule drift exactly as the three filter copies did in ADR-0001.
* **A `Loader` on each section now.** Rejected for this step, not for good: it
  changes identity and focus for a gain that has not been measured after the
  models are empty.
* **Clearing the raw arrays on a view change.** Rejected: it destroys the queue
  position and forces a refetch on every tab switch, which is the cost the views
  were designed to avoid.
* **Emptying only the track lists.** Rejected: a wall of 200 people is the same
  question asked of cards; the rule is about lists, not rows.
