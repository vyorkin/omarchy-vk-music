# ADR-0002: a row's action comes from the plan, and its index is a position in the raw list

Status: accepted, 2026-10-25.

## Context

"What does this row do" was answered in four places, and the answers disagreed.

* `activateCursor()` in `BarWidget.qml` walked a switch over `slot.scope` — `playlist`,
  `queue`, `section`, `person`, `friends`, `radio`, `search` — and called one of eight
  functions. That is the same union of scopes `ListShape.plan()` already separates into
  segments, written a second time.
* Every delegate in the panel called its own verb directly: `onActivated:
  root.playQueueAt(root.indexOfItem(root.queue, modelData))`, `root.openPlaylistView(…)`,
  `root.openPerson(…)`, and eleven more. Nothing in the panel said that Enter and a click
  on the same row were the same fact.
* Each of those two roads computed its own index, from a different array. Enter took the
  element out of the *filtered* list and asked `ListShape.indexOf` for its position there;
  a click asked `indexOfItem` for its position in the *raw* one.
* A segment carried `kind` but not the list it was cut from, so nothing tied the row the
  cursor walks to the array the command reads.

The commands read the raw array. `jump N` is a place in the queue, `playBrowseTrack(N)`
indexes `root.browseTracks`, and `play_tracks` is sent the section's whole list with an
index. That makes the click right and Enter wrong: with a filter narrowing the queue to
two rows, Enter on the first drawn row sent `jump 0` and played the wrong track. It is the
same defect ADR-0001 was written about — two answers to one question — one level down:
ADR-0001 fixed *which rows are on screen*, not *which position a command receives*.

## Decision

1. `ListShape.actionAt(planned, list, drawnIndex)` is the only answer to what a row means.
   It takes the list's name and a position among the rows as drawn — which is what a
   delegate holds and what a segment's index counts — and returns one intent:
   `playQueue`, `playPlaylist`, `playSection`, `playSearch`, `openPlaylist`, `openPerson`,
   `playStation`, `query`.
2. The `index` it returns is a position in the same list **before** the filter. The plan
   keeps both arrays, so the conversion happens where both are visible, and nowhere else.
3. A segment names the list it was cut from (`list`), beside its `kind`. A click names the
   array it drew; Enter names its segment; the two resolve to the same rows.
4. `BarWidget.qml` keeps one table, one call per intent, and no branch on which page is
   open. Both roads go through it, so Enter and a click cannot mean two different tracks.
5. `null` means there is nothing to do, which is what lets Enter keep its old meaning on an
   empty list.

## Consequences

* Enter on a filtered list plays the row it points at. This is a visible behaviour change
  and a bug fix: before it played the row at the same position in the unfiltered list.
* Enter on a playlist found by a search now opens it, like a click on its card does.
  Before, Enter started it and the card opened it. The card's meaning wins: one row, one
  action.
* `playPlaylist()` — the whole-playlist start that only Enter called — is gone. A playlist
  is started from its own screen.
* A new list kind is one entry in `INTENTS`, one segment in `plan()` and one word at the
  delegate that draws it. The tests in `tests/qml/tst_list_shape.qml` assert that every
  list the plan files has an intent, and that a play intent's index is the raw position.
* `repeaterForSlot()` and `rowAt()` are unchanged and still in the widget: which QML item
  draws a row is the widget's business, not the plan's.

## Alternatives rejected

* **Only Enter routed through the plan, clicks left as they were.** Rejected: the two roads
  would drift again with the next list kind, which is exactly how this bug arrived.
* **The plan returning a function name and arguments** (`{verb: "playPlaylistTrack"}`).
  Rejected: the set of intents stops being visible, and a typo becomes a silent no-op.
* **Passing the element instead of its drawn position.** Rejected: it moves the identity
  question (a delegate is handed a copy) into the caller, which is what made the two roads
  disagree about the index in the first place.
* **Fixing only the index base, leaving both matrices.** Rejected: the two matrices are the
  reason the base could differ, and the released bugs of this family keep arriving in pairs.
