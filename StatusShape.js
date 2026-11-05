// A status poll, folded back onto the status it repeats.
//
// The daemon answers every poll with a freshly parsed document, so `preferences`,
// `history` and `people` arrive as new objects and new arrays even when not one byte of
// them changed. The panel plans the visible list from those fields, and the plan is the
// model of every list in the panel: a new identity invalidates the plan, the plan returns
// new arrays, and a Repeater answered with a new array destroys every row and builds it
// again. That happened once per poll — once a second while a track plays, four times a
// second while one is being fetched — and on screen it was the covers blinking out from
// under a pointer that then waited a beat: the rows under the mouse were new items.
//
// QML comparison is what makes the fix as small as it is: a binding that re-evaluates to
// the same object identity does not notify anyone below it, while a new array of the same
// elements does. So a value the poll repeated is the value the old status already held,
// and the status itself is reused when nothing changed at all — an idle poll then wakes
// no binding in the widget.
.pragma library

function stringify(value) {
  try {
    return JSON.stringify(value)
  } catch (error) {
    // A value the parser cannot round-trip is never equal to anything: only the pair of
    // two failures would say otherwise, and that is not a pair the daemon can send.
    return null
  }
}

function isContainer(value) {
  return value !== null && typeof value === "object"
}

// Equality by content for the containers the poll carries. `JSON.stringify` is the
// comparison because a status document is JSON in the first place: both sides came through
// the same parser of the same shape, so key order is the daemon's on both sides and never a
// QML object's.
function same(a, b) {
  if (a === b) return true
  if (!isContainer(a) || !isContainer(b)) return false
  return stringify(a) === stringify(b)
}

// The status to hand the panel: `previous` when the poll said nothing new, and otherwise a
// new document in which every field the poll repeated is the object `previous` held. The
// fields that did change are the poll's own, so the panel sees exactly one change.
function adopt(previous, data) {
  if (!isContainer(data)) return previous
  if (!isContainer(previous)) return data
  var next = {}
  var unchanged = true
  for (var key in data) {
    var value = data[key]
    var old = previous[key]
    if (same(old, value)) {
      next[key] = isContainer(value) ? old : value
    } else {
      unchanged = false
      next[key] = value
    }
  }
  // A field the daemon stopped sending is a change like any other.
  for (var oldKey in previous) {
    if (!(oldKey in data)) {
      unchanged = false
      break
    }
  }
  return unchanged ? previous : next
}
