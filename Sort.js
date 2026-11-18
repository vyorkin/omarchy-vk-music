// How a list may be ordered, and what that order is a function of.
//
// An order is not a view: the panel's rows, the queue it builds from a row, and «Ещё»'s
// offset all read the same array, so the array itself has to be in the order the reader
// chose. The filter is the view's business (`ListShape.plan` draws fewer rows of it); an
// order is the list's, and this module is the one place that decides it.
//
// `vk` is the order the answer arrived in — not "sorted by nothing": VK's own orders are
// meaningful (a section is curated, «Моя музыка» is newest like first), and a list merely
// returns to it. The arrival rank is kept per `key` rather than as a copy of the array,
// because a like or a follow rebuilds a list in place and a copy would undo it.

var PLAYLIST_MODES = ["vk", "count-desc", "count-asc"]
var TRACK_MODES = ["vk", "duration-desc", "duration-asc"]

// The lists `SessionLists.put()` sorts, by the names `ListShape.plan()` reads. The queue is
// deliberately absent: its order is the order of playback, and a queue sorted by length
// would be a different queue, not a different drawing of it.
var PLAYLIST_LISTS = { playlists: true, personPlaylists: true, foundPlaylists: true }
var TRACK_LISTS = { playlistTracks: true, tracks: true, results: true }

function family(name) {
  var key = String(name)
  if (PLAYLIST_LISTS[key] === true) return "playlists"
  if (TRACK_LISTS[key] === true) return "tracks"
  return ""
}

function modes(familyName) {
  if (familyName === "playlists") return PLAYLIST_MODES.slice()
  if (familyName === "tracks") return TRACK_MODES.slice()
  return []
}

// A value the daemon's schema could have sent. A preference is written by a person and read
// by a list: one bad word must not reorder anything.
function sanitize(familyName, mode) {
  var allowed = modes(familyName)
  var wanted = String(mode)
  for (var i = 0; i < allowed.length; i++) {
    if (allowed[i] === wanted) return wanted
  }
  return "vk"
}

// Who an item is across a reload. A refresh hands over new objects, and the order they
// arrived in has to be recognised in them: a track and a playlist both carry `key`.
function identity(item) {
  if (!item) return ""
  if (item.key !== undefined && item.key !== null && String(item.key) !== "") return String(item.key)
  var owner = item.owner_id !== undefined ? item.owner_id : item.ownerId
  var id = item.playlist_id !== undefined ? item.playlist_id : item.id
  if (owner !== undefined && owner !== null && id !== undefined && id !== null) {
    return String(owner) + "/" + String(id)
  }
  if (item.id !== undefined && item.id !== null) return "id/" + String(item.id)
  return "title/" + String(item.title || "")
}

// The order a list arrived in, as a rank per identity. First sighting wins: a list may hold
// a track twice, and both copies keep the place of the first.
function arrivals(list) {
  var ranks = {}
  for (var i = 0; i < (list ? list.length : 0); i++) {
    var id = identity(list[i])
    if (ranks[id] === undefined) ranks[id] = i
  }
  return ranks
}

// The ranks of a list that grew by a page. The keys already in the table keep theirs — that
// is what makes «Ещё» a page appended to the order VK sent, and not a page at the end of
// whatever order the reader was looking at when the button was pressed — and the new keys
// take the numbers after the highest one.
function extend(ranks, added) {
  var table = {}
  var highest = -1
  for (var id in ranks) {
    table[id] = ranks[id]
    if (ranks[id] > highest) highest = ranks[id]
  }
  for (var i = 0; i < (added ? added.length : 0); i++) {
    var key = identity(added[i])
    if (table[key] === undefined) table[key] = ++highest
  }
  return table
}

function rankOf(item, ranks) {
  var rank = ranks ? ranks[identity(item)] : undefined
  return rank === undefined ? Infinity : rank
}

function valueOf(item, familyName) {
  if (!item) return 0
  var raw = familyName === "playlists" ? Number(item.count) : Number(item.duration)
  return raw > 0 ? raw : 0
}

// `/`'s order is the same everywhere, so a tie never depends on the engine's locale: the
// title is compared by code point, and the arrival rank settles two titles that match.
function compareText(a, b) {
  var left = String(a || "")
  var right = String(b || "")
  if (left === right) return 0
  return left < right ? -1 : 1
}

function compareByRank(a, b, ranks) {
  var left = rankOf(a, ranks)
  var right = rankOf(b, ranks)
  if (left === right) return compareText(a && a.title, b && b.title)
  return left < right ? -1 : 1
}

// A tie in the value — two four-minute tracks, two playlists of fifty — is broken by the
// title first: next to each other they should read in an order the reader can see, and the
// arrival rank only settles two titles that match.
function compareByTitleThenRank(a, b, ranks) {
  var byTitle = compareText(a && a.title, b && b.title)
  if (byTitle !== 0) return byTitle
  return compareByRank(a, b, ranks)
}

// A list in the order `mode` asks for. Never mutates: a sorted list is a new array, and the
// rank table keeps «VK order» recoverable after any other order. An item with no value — a
// station's duration, a playlist VK sent with no count — goes to the end whichever way the
// rest is sorted: an unknown length at the top would read as the shortest one.
function apply(list, familyName, mode, ranks) {
  var items = (list || []).slice()
  var wanted = sanitize(familyName, mode)
  if (wanted === "vk") {
    items.sort(function(a, b) { return compareByRank(a, b, ranks) })
    return items
  }
  var ascending = wanted.indexOf("-asc") > 0
  items.sort(function(a, b) {
    var left = valueOf(a, familyName)
    var right = valueOf(b, familyName)
    var leftKnown = left > 0
    var rightKnown = right > 0
    if (leftKnown !== rightKnown) return leftKnown ? -1 : 1
    if (leftKnown && left !== right) return ascending ? left - right : right - left
    return compareByTitleThenRank(a, b, ranks)
  })
  return items
}
