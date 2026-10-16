// VK Music in the bar: artwork, title, transport, and a popup with the queue.
//
// The widget owns no VK knowledge at all. Every action and every piece of state
// goes through `bin/omarchy-vk-music`, which forwards one JSON command to the
// user service over a Unix socket and prints one JSON answer. That keeps the QML
// free of tokens, HLS, pacing and cache logic, and lets the same commands be
// driven from a terminal while debugging.
import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "vyorkin.vk-music"
  ipcTarget: "vyorkin.vk-music"

  // ------------------------------------------------------------- state ---
  property var status: ({})
  property var queue: []
  property var playlists: []
  property var sources: []
  property var results: []
  property var suggestions: []
  // typing | searching | results — what the list under the field is showing.
  property string searchState: "typing"
  // Guards against a slow reply for an older query overwriting newer results.
  property int _searchSeq: 0
  property string _searchedQuery: ""
  property string view: "queue" // queue | browse | search
  // Browsing a catalog section: which one, what came back, and where the next
  // page starts.
  property string browseSlug: ""
  property string browseTitle: ""
  property var browseTracks: []
  property var browsePlaylists: []
  property string browseNext: ""
  property var stations: []
  // A list that is being fetched is not an empty list: without these the popup
  // showed "Пусто" and "Очередь пуста" while the answer was still on its way.
  property bool browseLoading: false
  property bool browseMoreLoading: false
  property bool queueLoading: false
  property bool searchLoading: false
  property double sourcesLoadedAt: 0
  // Where the keyboard is in the list that is on screen: up and down move this,
  // Enter plays what it points at. It is an index into the visible list, so the
  // same number means the same row in every view, and -1 means nothing is picked
  // until a key is pressed.
  property int cursor: -1
  property bool _returnPressed: false
  property string query: ""
  property string busy: ""
  property string errorText: ""

  onViewChanged: root.cursor = -1
  onBrowseSlugChanged: root.cursor = -1
  // A new query means a new list, so the selection goes. A search *answer* for
  // the same query does not: resetting there threw the selection away a moment
  // before Enter could use it.
  onQueryChanged: root.cursor = -1

  readonly property int _queryLength: root.query.trim().length
  readonly property bool resultsShowing: root.searchState === "results" && root._queryLength >= 2
  readonly property var resultsShown: root.resultsShowing ? root.results : []
  // Suggestions stand in for the results while the query is still being typed,
  // and come back when a search found nothing: they are the useful thing left.
  readonly property var suggestionsShown: root._queryLength < 2 ? [] : (root.resultsShowing
    ? (root.results.length === 0 ? root.suggestions : [])
    : root.suggestions)
  readonly property string searchHeader: root._queryLength < 2 ? ""
    : (root.searchState === "searching" ? "Ищу…"
      : (root.resultsShowing
        ? (root.results.length > 0
          ? "Найдено " + root.results.length
          : (root.suggestionsShown.length > 0 ? "Ничего не найдено. Похожее:" : "Ничего не найдено"))
        : "Подсказки"))
  // The heading is worth its line only when there is something under it: while
  // the query is still short nothing is shown at all.
  readonly property bool searchHeaderVisible: root.searchHeader !== ""
    && (root.searchState !== "typing" || root.suggestionsShown.length > 0)

  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string cli: root.pluginDir + "/bin/omarchy-vk-music"

  readonly property var track: (status && status.track !== undefined) ? status.track : null
  readonly property bool hasTrack: track !== null && track !== undefined
  readonly property bool signedIn: status.authenticated === true
  readonly property bool playing: status.playing === true && status.paused !== true
  readonly property bool loading: status.loading === true
  readonly property int position: status.position === undefined ? 0 : Number(status.position)
  readonly property int duration: status.duration === undefined ? 0 : Number(status.duration)
  readonly property int volume: status.volume === undefined ? 70 : Number(status.volume)
  readonly property string notice: String(status.notice || "")
  readonly property string halted: String(status.halted || "")
  readonly property var prefs: status.preferences || ({})
  // A live station stands in for the track: it has no timeline and no queue.
  // The same shape as `track`/`hasTrack` above, deliberately: a cached property
  // whose binding reads a field inside a `var` (`radio.name !== undefined`) went
  // stale — the raw expression was true while the property stayed false — so the
  // station is a nullable object and its fields are read through a helper.
  readonly property var radio: (status && status.radio !== undefined && status.radio.name)
    ? status.radio : null
  // Read through a function, not a cached property: a `readonly property bool
  // onRadio: root.radio !== null` bound to the object above stayed false while
  // the object itself was there — the same staleness `trackValue` was written to
  // avoid. A call is evaluated whenever the binding around it is.
  function onAir() {
    return root.radio !== null
  }

  // Anything at all still on its way: the bottom line has one reason to be there.
  function anyLoading() {
    return root.browseLoading || root.browseMoreLoading || root.searchLoading || root.queueLoading
  }

  function radioValue(name, fallback) {
    if (root.radio === null || root.radio === undefined) return fallback
    var value = root.radio[name]
    return (value === undefined || value === null) ? fallback : value
  }
  readonly property bool liked: root.trackValue("is_liked", false) === true

  // Buffering, as the ring needs it. `bufferProgress` is 0..1, or -1 when the
  // length is unknown (a stream that is not being cached) — then the ring spins.
  readonly property var buffer: status.buffer || ({})
  readonly property bool buffering: root.buffer.active === true
  readonly property bool bufferIndeterminate: root.buffer.percent === null
    || root.buffer.percent === undefined
  readonly property real bufferProgress: root.bufferIndeterminate
    ? -1
    : Math.max(0, Math.min(1, Number(root.buffer.percent || 0) / 100))

  // One line of state for the popup header. Signing in, an empty queue and a
  // finished load are states, not errors: only a halt and a failed command are
  // painted with the urgent colour.
  readonly property string statusText: {
    if (root.errorText !== "") return root.errorText
    if (root.halted !== "") return root.halted
    if (root.notice !== "") return root.notice
    if (!root.signedIn) return "нет входа"
    // Buffering is not text: the ring around the cover says it, in place, and
    // without a word that would appear and vanish three times a second.
    if (!root.hasTrack) return "готов"
    return root.busy !== "" ? "…" : ""
  }
  readonly property bool statusUrgent: root.errorText !== "" || root.halted !== ""

  readonly property color fg: bar && bar.barForeground !== undefined ? bar.barForeground : Color.foreground
  readonly property color dim: Qt.darker(root.fg, 1.5)
  readonly property color textColor: Color.popups ? Color.popups.text : Color.foreground
  readonly property color cardBg: bar && bar.background !== undefined ? bar.background : Color.background
  // The surface the popup sits on. Used for the scrim under the percentage: the
  // theme's own panel colour is dark in a dark theme and light in a light one,
  // so the label never has to fight the album art.
  readonly property color panelBackground: Color.popups && Color.popups.background !== undefined
    ? Color.popups.background
    : Color.background

  readonly property int upcomingStart: Number(status.index === undefined ? -1 : status.index) + 1

  // The upcoming few tracks, taken from the queue the service already holds.
  readonly property var upcoming: {
    if (!queue || queue.length === 0) return []
    var out = []
    for (var i = root.upcomingStart; i < queue.length && out.length < 20; i++) out.push(queue[i])
    return out
  }

  // Refresh while a popup is open or music is playing; otherwise idle cheaply.
  //
  // One line of geometry also goes to the shell log, so a layout complaint can
  // be checked with numbers instead of a screenshot. It fires once per session
  // for the bar row and once per popup opening.
  property bool _reportedBarLayout: false
  property bool _watching: false
  property string _loggedTrack: ""
  property int _queueIndex: -2
  onWidthChanged: reportBarLayout()

  function reportBarLayout() {
    if (root._reportedBarLayout || root.width <= 0) return
    root._reportedBarLayout = true
    console.log("[vk-music] bar layout", JSON.stringify({
      width: root.width,
      implicitWidth: root.implicitWidth,
      implicitHeight: root.implicitHeight,
      barSize: root.bar ? root.bar.barSize : -1,
      artwork: artwork.width,
      label: labelText.implicitWidth,
      transport: transportZone.width,
      labelSize: Style.font.bodySmall
    }))
  }

  // Poll fast enough that the ring grows in more than three steps: a download
  // lasts about three seconds, and one status call costs a couple of
  // milliseconds over the socket.
  Timer {
    id: pollTimer
    interval: (root.buffering || root._watching) ? 250 : (root.playing ? 1000 : 5000)
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    id: watchTimer
    interval: 5000
    repeat: false
    onTriggered: root._watching = false
  }

  Component.onCompleted: {
    refresh()
    reportBarLayout()
  }

  // ----------------------------------------------------------------- io ---

  // One fresh Process per command: a reused object can miss its exit event and
  // then keep reporting "running", which would wedge every later action.
  //
  // The answer is parsed in the collector's own `onStreamFinished`, because
  // `text` is a property of the collector and not of the Process. Reading it
  // from `onExited` yields undefined, which is how every command silently
  // became "команда не выполнена" while the service was in fact working.
  Component {
    id: commandComponent
    Process {
      property var onDone
      stderr: StdioCollector { id: commandError; waitForEnd: true }
      stdout: StdioCollector {
        id: commandOutput
        waitForEnd: true
        onStreamFinished: {
          var raw = String(text || "").trim()
          var answer = null
          try {
            answer = raw === "" ? null : JSON.parse(raw)
          } catch (parseError) {
            answer = null
          }
          root.busy = ""
          if (answer && answer.ok) {
            root.errorText = ""
          } else if (answer && answer.error) {
            root.errorText = String(answer.error.message || answer.error.code || "ошибка")
          } else if (raw !== "") {
            root.errorText = raw
          } else {
            root.errorText = String(commandError.text || "").trim() || "команда не выполнена"
          }
          if (onDone) onDone(answer)
        }
      }
      onExited: function(code) { destroy() }
    }
  }

  function call(args, onDone) {
    var process = commandComponent.createObject(root, { command: args, onDone: onDone })
    if (!process) return
    root.busy = args.join(" ")
    process.running = true
  }

  readonly property bool streaming: status.streaming === true

  // Position display. The backend reports a position once per poll; between
  // polls the widget interpolates, and right after a seek it holds the target
  // until the backend confirms it. Without this the knob snapped back to the
  // stale reported position on release and jumped forward a second later, which
  // is what made seeking feel broken.
  property real reportedPosition: 0
  property double reportedAt: 0
  property real seekTarget: -1
  property double seekTargetAt: 0
  property real pendingSeek: -1
  property int tick: 0

  readonly property real displayPosition: {
    root.tick // reactive dependency: the ticker below advances it
    var now = Date.now()
    if (root.seekTarget >= 0 && now - root.seekTargetAt < 2500) return root.seekTarget
    if (!root.playing || root.paused) return root.reportedPosition
    var upper = root.duration > 0 ? root.duration : root.reportedPosition + 3600
    return Math.min(upper, root.reportedPosition + (now - root.reportedAt) / 1000)
  }

  // Advances the interpolated position while music plays.
  Timer {
    interval: 250
    running: root.playing && !root.paused
    repeat: true
    onTriggered: root.tick++
  }

  Timer {
    id: liveSeek
    interval: 150
    repeat: false
    onTriggered: {
      if (root.pendingSeek < 0) return
      var target = root.pendingSeek
      root.pendingSeek = -1
      root.call([root.cli, "seek", String(Math.round(target))])
    }
  }

  // Volume is optimistic for the same reason as the position: the backend
  // reports it once per poll, and a drag must not be dragged back by that.
  property real volumeTarget: -1
  property double volumeTargetAt: 0
  property real pendingVolume: -1
  property real lastAudibleVolume: 70

  readonly property real displayVolume: {
    if (root.volumeTarget >= 0 && Date.now() - root.volumeTargetAt < 2000) return root.volumeTarget
    return root.volume
  }

  // A drag asks the backend to follow the hand. The transport is a Unix socket
  // write (about 0.4 ms), so this throttle is only here to keep the mpv commands
  // and the MPRIS updates from flooding: 50 ms is under the threshold where a
  // change feels detached from the hand.
  Timer {
    id: liveVolume
    interval: 50
    repeat: false
    onTriggered: {
      if (root.pendingVolume < 0) return
      var target = root.pendingVolume
      root.pendingVolume = -1
      root.call([root.cli, "volume", String(Math.round(target)), "--live"])
    }
  }

  // Search-as-you-type: the cheap suggestions call after a short pause, the
  // search itself after a longer one. Both are restarted by the next keystroke,
  // so a typed query costs a handful of calls and never a burst — and the search
  // also runs immediately on Enter or on a tap of a suggestion.
  Timer {
    id: suggestTimer
    interval: 250
    repeat: false
    onTriggered: root.loadSuggestions()
  }

  Timer {
    id: searchTimer
    interval: 700
    repeat: false
    onTriggered: root.runSearch(false)
  }

  function setVolume(value, live) {
    var clamped = Math.max(0, Math.min(100, value))
    root.volumeTarget = clamped
    root.volumeTargetAt = Date.now()
    if (clamped > 0) root.lastAudibleVolume = clamped
    if (live) {
      root.pendingVolume = clamped
      liveVolume.restart()
      return
    }
    root.pendingVolume = -1
    liveVolume.stop()
    root.call([root.cli, "volume", String(Math.round(clamped))])
  }

  function toggleMute() {
    root.setVolume(root.displayVolume > 0 ? 0 : root.lastAudibleVolume, false)
  }

  // Settings live in the backend so the popup can change them; a shell.json
  // entry for the same name still wins, which is how the bar options stay
  // overridable by hand.
  function setPreference(name, value) {
    root.call([root.cli, "prefs", name + "=" + String(value)], function(answer) {
      if (answer && answer.ok) root.refresh()
    })
  }

  function toggleLike() {
    if (!root.hasTrack) return
    var key = root.trackValue("key", "")
    if (key === "") return
    root.call([root.cli, root.liked ? "unlike" : "like", key], function(answer) {
      // The answer carries the refreshed status, so the heart flips in one round
      // trip instead of waiting for the next poll.
      if (answer && answer.ok && answer.data && answer.data.status) {
        root.status = answer.data.status
      }
    })
  }

  function megabytes(bytes) {
    return Math.round(Number(bytes || 0) / 1048576) + " МБ"
  }

  function seekTo(target) {
    var upper = root.duration > 0 ? root.duration : target
    var clamped = Math.max(0, Math.min(upper, target))
    root.seekTarget = clamped
    root.seekTargetAt = Date.now()
    root.reportedPosition = clamped
    root.reportedAt = Date.now()
    root.tick++
    return clamped
  }

  function seekLive(target) {
    var clamped = seekTo(target)
    if (root.streaming) return
    root.pendingSeek = clamped
    liveSeek.restart()
  }

  function seekFinal(target) {
    var clamped = seekTo(target)
    root.pendingSeek = -1
    liveSeek.stop()
    root.call([root.cli, "seek", String(Math.round(clamped))])
  }

  function refresh() {
    call([root.cli, "status"], function(answer) {
      if (!answer || !answer.ok) return
      root.status = answer.data
      root.reportedPosition = Number(answer.data.position || 0)
      root.reportedAt = Date.now()
      if (root.seekTarget >= 0 && Math.abs(root.reportedPosition - root.seekTarget) < 2) {
        root.seekTarget = -1
      }
      if (root.volumeTarget >= 0 && Math.abs(Number(answer.data.volume || 0) - root.volumeTarget) < 1) {
        root.volumeTarget = -1
      }
      if (Number(answer.data.volume || 0) > 0) {
        root.lastAudibleVolume = Number(answer.data.volume)
      }
      // The queue is a hundred tracks: reload it when the track actually changes
      // rather than on every status poll, which during buffering is four a
      // second.
      if (root.opened && Number(answer.data.index) !== root._queueIndex) {
        root._queueIndex = Number(answer.data.index)
        root.loadQueue()
      }
      // One line per track so the widget's own view of the state can be checked
      // from the shell log instead of a screenshot.
      var key = String((answer.data.track || {}).key || "-")
      if (root._loggedTrack !== key) {
        root._loggedTrack = key
        // A track can also change without this widget asking — the media keys go
        // through MPRIS — so a change is worth watching closely for a moment.
        if (root._loggedTrack !== "") {
          root._watching = true
          watchTimer.restart()
        }
        console.log("[vk-music] widget state", JSON.stringify({
          signedIn: root.signedIn,
          playing: root.playing,
          loading: root.loading,
          buffering: root.buffering,
          percent: root.buffer.percent,
          title: root.hasTrack ? root.trackValue("title") : null,
          queue: answer.data.queueLength,
          error: root.errorText
        }))
      }
    })
  }

  function loadQueue() {
    root.queueLoading = root.queue.length === 0
    call([root.cli, "queue"], function(answer) {
      root.queueLoading = false
      if (answer && answer.ok) root.queue = answer.data
    })
  }

  function loadSources() {
    // Opening the popup used to ask for these every time, and each answer queued
    // behind the others; they barely change, so once per ten minutes is plenty.
    if (root.sources.length > 0 && Date.now() - root.sourcesLoadedAt < 600000) return
    root.sourcesLoadedAt = Date.now()
    call([root.cli, "sections"], function(answer) {
      if (answer && answer.ok) root.sources = answer.data
    })
    call([root.cli, "home"], function(answer) {
      if (answer && answer.ok) {
        root.playlists = answer.data.playlists || []
        root.queue = root.queue
      }
    })
  }

  // Suggestions are the cheap call — VK's own player asks for them as you type —
  // so they come first. The search itself waits for a pause, and every keystroke
  // cancels both, so a typed query costs a handful of calls and never a burst.
  function loadSuggestions() {
    var text = root.query.trim()
    if (text.length < 2) {
      root.suggestions = []
      return
    }
    root.call([root.cli, "suggestions", text], function(answer) {
      // The user may have typed on while this was in flight.
      if (answer && answer.ok && root.query.trim() === text) root.suggestions = answer.data || []
    })
  }

  function runSearch(force) {
    var text = root.query.trim()
    if (text.length < 2) {
      root.results = []
      root.searchState = "typing"
      return
    }
    // Typing a letter and deleting it again should not cost a second search, and
    // neither should the debounce firing while the same search is still in
    // flight. A search that failed leaves the state at "typing", so it can be
    // retried by typing again.
    if (!force && text === root._searchedQuery && root.searchState !== "typing") return
    root._searchedQuery = text
    root._searchSeq = root._searchSeq + 1
    var seq = root._searchSeq
    root.searchState = "searching"
    root.searchLoading = true
    root.call([root.cli, "search", text], function(answer) {
      if (seq !== root._searchSeq) return
      root.searchLoading = false
      if (answer && answer.ok) {
        root.results = answer.data.tracks || []
        root.searchState = "results"
      } else {
        root.searchState = "typing"
      }
    })
  }

  function searchSuggestion(text) {
    if (!text) return
    root.query = text
    root.runSearch(true)
  }

  function clearSearch() {
    root.query = ""
    root.results = []
    root.suggestions = []
    root.searchState = "typing"
    root._searchedQuery = ""
  }

  // The list the keyboard walks through. One list per view, so the cursor index
  // needs no kind attached to it.
  function cursorItems() {
    if (root.view === "queue") return root.upcoming
    if (root.view === "browse") {
      return root.browseSlug === "radiostations" ? root.stations : root.browseTracks
    }
    if (root.view === "search") {
      return root.resultsShown.length > 0 ? root.resultsShown : root.suggestionsShown
    }
    return []
  }

  function cursorCount() {
    return root.cursorItems().length
  }

  function moveCursor(step) {
    var count = root.cursorCount()
    if (count === 0) return
    var next = root.cursor < 0 ? (step > 0 ? 0 : count - 1) : root.cursor + step
    root.cursor = Math.max(0, Math.min(count - 1, next))
    root.revealCursor()
  }

  // The delegate item the cursor sits on, so the list can be scrolled to it: rows
  // are not a fixed height, and arithmetic on an index would drift.
  function cursorRow() {
    var index = root.cursor
    if (index < 0) return null
    if (root.view === "queue") return queueRepeater.itemAt(index)
    if (root.view === "browse") {
      return root.browseSlug === "radiostations"
        ? stationRepeater.itemAt(index)
        : browseTrackRepeater.itemAt(index)
    }
    if (root.view === "search") {
      return root.resultsShown.length > 0
        ? resultRepeater.itemAt(index)
        : suggestionRepeater.itemAt(index)
    }
    return null
  }

  function revealCursor() {
    var row = root.cursorRow()
    if (!row) return
    var margin = Style.space(6)
    var top = row.y
    var bottom = top + row.height
    if (top - margin < listView.contentY) {
      listView.contentY = Math.max(0, top - margin)
    } else if (bottom + margin > listView.contentY + listView.height) {
      listView.contentY = bottom + margin - listView.height
    }
  }

  // Enter: play what the cursor points at. Returns false when there is nothing
  // to activate, which is when Enter keeps its old meaning.
  function activateCursor() {
    var count = root.cursorCount()
    if (count === 0) return false
    var index = root.cursor < 0 ? 0 : Math.min(root.cursor, count - 1)
    if (root.view === "queue") {
      root.playQueueAt(root.upcomingStart + index)
    } else if (root.view === "browse") {
      if (root.browseSlug === "radiostations") root.playStation(root.stations[index])
      else root.playBrowseTrack(index)
    } else if (root.view === "search") {
      if (root.resultsShown.length > 0) root.playSearchResult(index)
      else root.searchSuggestion(String(root.suggestionsShown[index]))
    } else {
      return false
    }
    return true
  }

  // Any command that can start a track opens a short watch window: the widget
  // then polls four times a second instead of once, because a download lasts
  // about three seconds and the first poll at one second would land near its end.
  function watchForTrack() {
    root._watching = true
    watchTimer.restart()
    root.refresh()
  }

  function playSection(id, title) {
    call([root.cli, "play", "section", id, "0", "--title", title], function() { root.watchForTrack() })
  }

  // Russian counts a noun three ways; a section header that says "1 треков" is
  // worse than saying nothing.
  function plural(count, one, few, many) {
    var value = Math.abs(Number(count) || 0) % 100
    if (value > 10 && value < 20) return many
    value = value % 10
    if (value === 1) return one
    if (value >= 2 && value <= 4) return few
    return many
  }

  // What the list is showing, and what it is doing: the header is the one place
  // that says both, so the list itself never has to claim anything false.
  readonly property string browseHeader: {
    if (root.browseSlug === "") return ""
    if (root.browseSlug === "radiostations") {
      if (root.browseLoading) return "Радио · загрузка…"
      var stations = root.stations.length
      return "Радио · " + (stations === 0
        ? "пусто"
        : stations + " " + root.plural(stations, "станция", "станции", "станций"))
    }
    var title = root.browseTitle !== "" ? root.browseTitle : (root.sectionTitle(root.browseSlug) || "Раздел")
    if (root.browseLoading) return title + " · загрузка…"
    var tracks = root.browseTracks.length
    var lists = root.browsePlaylists.length
    if (tracks === 0 && lists === 0) return title + " · пусто"
    if (tracks === 0) {
      return title + " · " + lists + " " + root.plural(lists, "плейлист", "плейлиста", "плейлистов")
    }
    return title + " · " + tracks + " " + root.plural(tracks, "трек", "трека", "треков")
  }

  // The sections come as opaque ids with a friendly slug inside the url. The
  // backend accepts either, and the url is what lets the UI label them.
  // The section's own name, known from the section list before its page arrives:
  // "Раздел · загрузка…" tells the user nothing about what is loading.
  function sectionTitle(slug) {
    for (var i = 0; i < root.sources.length; i++) {
      if (root.sourceSlug(root.sources[i]) === slug) return String(root.sources[i].title || "")
    }
    return ""
  }

  function sourceSlug(section) {
    if (!section) return ""
    var match = String(section.url || "").match(/section=([a-z]+)/)
    return match ? match[1] : String(section.id || "")
  }

  // Browsing: a catalog section page by page, or the live stations.
  function browseSource(slug) {
    if (!slug || root.browseSlug === slug) return
    root.browseSlug = slug
    root.browseTracks = []
    root.browsePlaylists = []
    root.browseNext = ""
    root.browseTitle = ""
    if (slug === "radiostations") {
      if (root.stations.length > 0) return
      root.browseLoading = true
      root.call([root.cli, "radio"], function(answer) {
        if (root.browseSlug === slug) root.browseLoading = false
        if (answer && answer.ok) root.stations = answer.data || []
      })
      return
    }
    root.browseLoading = true
    root.call([root.cli, "section", slug], function(answer) {
      if (root.browseSlug !== slug) return
      root.browseLoading = false
      if (answer && answer.ok) root.adoptSection(answer.data)
    })
  }

  function adoptSection(page) {
    if (!page) return
    root.browseTitle = String(page.title || "")
    root.browseTracks = page.tracks || []
    root.browsePlaylists = page.playlists || []
    root.browseNext = String(page.next || "")
  }

  // «Ещё»: the sections are paged by a cursor, the tracks are appended to the
  // list the user is already looking at.
  function browseMore() {
    if (root.browseNext === "" || root.browseMoreLoading) return
    var slug = root.browseSlug
    var cursor = root.browseNext
    root.browseMoreLoading = true
    root.call([root.cli, "section", slug, cursor], function(answer) {
      if (root.browseSlug !== slug) return
      root.browseMoreLoading = false
      if (!answer || !answer.ok) return
      var page = answer.data || {}
      root.browseTracks = root.browseTracks.concat(page.tracks || [])
      root.browsePlaylists = root.browsePlaylists.concat(page.playlists || [])
      root.browseNext = String(page.next || "")
    })
  }

  function playBrowseTrack(index) {
    // Same rule as a search result: the queue is exactly the list on screen.
    var keys = []
    for (var i = 0; i < root.browseTracks.length; i++) {
      if (root.browseTracks[i] && root.browseTracks[i].key) keys.push(String(root.browseTracks[i].key))
    }
    if (keys.length === 0) return
    var args = [root.cli, "play", "keys"].concat(keys)
    args.push("--index", String(index))
    args.push("--title", root.browseTitle !== "" ? root.browseTitle : "Обзор")
    root.call(args, function() { root.watchForTrack() })
  }

  function playStation(station) {
    if (!station || !station.id) return
    root.call([root.cli, "play", "radio", String(station.id)], function() { root.watchForTrack() })
  }

  function playPlaylist(playlist) {
    call([
      root.cli, "play", "playlist", String(playlist.owner_id), String(playlist.playlist_id),
      String(playlist.access_key || ""), String(playlist.title || "")
    ], function() { root.watchForTrack() })
  }

  function playSearchResult(index) {
    // Hand the backend the keys of the results the user is looking at: one
    // `audio.getById` instead of a repeated search, and the queue is exactly
    // this list rather than whatever the same query returns the second time.
    var keys = []
    for (var i = 0; i < root.results.length; i++) {
      if (root.results[i] && root.results[i].key) keys.push(String(root.results[i].key))
    }
    if (keys.length === 0) return
    var args = [root.cli, "play", "keys"].concat(keys)
    args.push("--index", String(index))
    args.push("--title", "Поиск: " + root.query.trim())
    root.call(args, function() { root.watchForTrack() })
  }

  function playQueueAt(index) {
    call([root.cli, "jump", String(index)], function() { root.watchForTrack() })
  }

  function togglePause() {
    call([root.cli, "pause"], function() { root.refresh() })
  }

  function skipNext() {
    call([root.cli, "next"], function() { root.watchForTrack() })
  }

  function skipPrevious() {
    call([root.cli, "previous"], function() { root.watchForTrack() })
  }

  function signIn() {
    call([root.cli, "auth", "web"], function() { root.refresh() })
  }

  function clock(seconds) {
    var total = Math.max(0, Math.floor(Number(seconds) || 0))
    var minutes = Math.floor(total / 60)
    var rest = total % 60
    return minutes + ":" + (rest < 10 ? "0" : "") + rest
  }

  // Reading a field of the current track always goes through here. The track is
  // null until the first status arrives, and a ternary on `hasTrack` is not
  // enough: QML still evaluates the other branch while the two properties settle.
  function trackValue(name, fallback) {
    if (!root.track) return fallback
    var value = root.track[name]
    return value === undefined || value === null ? fallback : value
  }

  // ---------------------------------------------------------------- bar ---

  // The height is the bar's own row height, not the content's: a taller widget
  // pushes its neighbours out of line, which is exactly what a padded Button
  // inside the row used to do.
  implicitWidth: barRow.implicitWidth + Style.space(12)
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  // The label shown in the bar. Signing in, an empty queue and a stopped
  // service are states of the widget, not errors: only a halt paints red.
  readonly property string barLabel: {
    if (root.halted !== "") return "остановлен"
    if (!root.signedIn) return "vk music"
    // A live station has no track behind it: its name is the whole label.
    if (root.onAir()) return String(root.radioValue("name", "радио"))
    if (!root.hasTrack) return root.loading ? "загрузка…" : "vk music"
    return root.trackValue("title") + (root.trackValue("artist", "") ? "  ·  " + root.trackValue("artist", "") : "")
  }
  readonly property color barLabelColor: root.halted !== "" ? Color.urgent
    : (root.errorText !== "" ? root.dim : root.fg)

  // This layer must stay UNDER the row: a MouseArea declared after its siblings
  // covers them, and the transport zone would never see a click.
  MouseArea {
    id: barMouse
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onEntered: if (root.bar) root.bar.showTooltip(root, root.errorText !== ""
      ? ("vk music: " + root.errorText)
      : (root.halted !== "" ? root.halted : (root.hasTrack
        ? (root.trackValue("title") + (root.trackValue("artist", "") ? " — " + root.trackValue("artist", "") : ""))
        : "vk music")))
    onExited: if (root.bar) root.bar.hideTooltip(root)
    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) root.skipNext()
      else if (mouse.button === Qt.RightButton && root.hasTrack) root.togglePause()
      else root.toggle()
    }
  }

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    readonly property bool showArtwork: root.setting("showArtwork", root.prefs.showArtwork !== false)
    readonly property bool showText: root.setting("showText", root.prefs.showText !== false)
    readonly property int labelWidth: Number(root.setting("labelWidth", Number(root.prefs.labelWidth) || 180))

    BorderSurface {
      id: artwork
      // 20 px matches the cover size the other bar players in this shell use.
      width: Style.space(20)
      height: width
      radius: Style.spacing.labelGap
      visible: barRow.showArtwork
      anchors.verticalCenter: parent.verticalCenter
      color: Style.normalFillFor(root.fg, Color.accent)
      borderSpec: root.buffering
        ? Border.none()
        : Border.controlSpec("normal", root.fg, Color.accent)
      opacity: root.hasTrack ? 1.0 : 0.6

      Image {
        anchors.fill: parent
        anchors.margins: Style.space(2)
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
        source: root.onAir()
          ? String(root.radioValue("logo", ""))
          : (root.hasTrack && root.trackValue("thumb", "") ? root.trackValue("thumb", "") : "")
        visible: source !== ""
      }

      Text {
        anchors.centerIn: parent
        visible: !root.hasTrack || !root.trackValue("thumb", "")
        text: "󰝚"
        color: root.fg
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }

      // The ring rides on the artwork that is already there: no layout shift and
      // no second element in a row that is 30 px tall. While it is filling, the
      // artwork's own border steps aside so only one outline is visible.
      ProgressFrame {
        anchors.fill: parent
        visible: root.buffering
        progress: Math.max(0, root.bufferProgress)
        indeterminate: root.bufferIndeterminate
        color: Color.accent
        cornerRadius: Style.spacing.labelGap
        thickness: Math.max(1.5, Style.space(2))
      }
    }

    Item {
      id: labelClip
      visible: barRow.showText
      width: Math.min(barRow.labelWidth, labelText.implicitWidth)
      height: labelText.height
      anchors.verticalCenter: parent.verticalCenter
      clip: true

      Text {
        id: labelText
        textFormat: Text.PlainText
        text: root.barLabel
        color: root.barLabelColor
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.bodySmall
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    // A small urgent dot is the whole error report in the bar; the text stays
    // readable and the popup carries the reason.
    Item {
      width: Style.space(7)
      height: width
      anchors.verticalCenter: parent.verticalCenter
      visible: root.errorText !== "" || root.halted !== ""

      Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Color.urgent
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.open()
      }
    }

    Item {
      id: transportZone
      width: Style.space(24)
      height: root.implicitHeight
      anchors.verticalCenter: parent.verticalCenter
      visible: root.hasTrack

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        // The glyph never turns into a downloader: play stays play, dimmed while
        // the track is being fetched.
        text: root.playing ? "󰏤" : "󰐊"
        color: root.fg
        opacity: root.loading ? 0.45 : 1.0
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.togglePause()
      }
    }
  }

  onOpenedChanged: {
    if (root.opened) {
      root.refresh()
      root._queueIndex = -2
      root.loadQueue()
      root.loadSources()
      afterOpen.restart()
    }
  }

  // After the panel is mapped, not at the moment it opens: the sizes only exist
  // once it has been laid out, and the keyboard focus only takes on a mapped
  // item. Opening the search view hands the keyboard straight to the field, so
  // typing works without a click.
  function afterOpen() {
    console.log("[vk-music] popup layout", JSON.stringify({
      card: [panel.contentWidth, panel.contentHeight],
      body: body.implicitHeight,
      available: [panel.availableCardWidth, panel.availableCardHeight],
      inset: panel.verticalContentInset,
      blocks: body.children.length,
      list: [listView.height, listColumn.implicitHeight],
      shown: [root.suggestionsShown.length, root.resultsShown.length]
    }))
    if (root.view === "search") searchField.forceActiveFocus()
  }

  Timer {
    id: afterOpen
    interval: 400
    repeat: false
    onTriggered: root.afterOpen()
  }

  // -------------------------------------------------------------- popup ---
  //
  // The card has a fixed height and the list area scrolls. Sizing the card from
  // the column's implicit height looked right in theory, but that height only
  // exists after a layout pass, so the popup opened collapsed and grew a frame
  // later. A fixed card with one Flickable is boring and always correct.

  KeyboardPanel {
    id: panel
    anchorItem: barRow
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(400))
    // Fixed height, but not one height for everything: a signed-out card holding
    // two lines of text and one button would otherwise be mostly empty space.
    // 690 rather than 460: with the smaller card the queue showed four tracks and
    // had to be scrolled for a fifth, and the settings page was barely usable.
    contentHeight: panel.fittedContentHeight(root.signedIn ? Style.space(690) : Style.space(200))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      // Up and down move the selection instead of the playback: pressing a key
      // to look through a list should not start a track. `n` and `p` below still
      // switch tracks.
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
      }
      // Enter arrives as `returnRequested` and then as `activateRequested`, so
      // the flag keeps the second one from toggling playback on top of the first.
      onReturnRequested: {
        root._returnPressed = true
        // A picked row wins, even from the search field: after typing the hands
        // are in the field, and Enter there should play what the arrows chose.
        if (root.cursor >= 0 && root.activateCursor()) return
        // With nothing picked, Enter in the field asks for the search at once
        // instead of waiting for the pause that would have done it anyway.
        if (searchField.activeFocus) {
          root.runSearch(true)
          return
        }
        root.togglePause()
      }
      onActivateRequested: {
        if (root._returnPressed) {
          root._returnPressed = false
          return
        }
        root.togglePause()
      }
      onCloseRequested: root.close()
      onTextKey: function(character) {
        if (searchField.activeFocus) return
        if (character === "n") root.skipNext()
        else if (character === "p") root.skipPrevious()
      }

      ColumnLayout {
        id: body
        anchors.fill: parent
        spacing: Style.spacing.controlGap

        // ------------------------------------------------------ header ---
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap

          PanelSectionHeader {
            id: header
            text: "vk music"
            foreground: root.textColor
            Layout.alignment: Qt.AlignVCenter
          }

          Text {
            Layout.fillWidth: true
            textFormat: Text.PlainText
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
            text: root.statusText
            color: root.statusUrgent ? Color.urgent : root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.textColor; visible: root.signedIn }

        // ----------------------------------------------------- sign-in ---
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.spacing.controlGap
          visible: !root.signedIn

          Text {
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Нужен вход в VK. Плагин возьмёт cookie p и remixsid из профиля браузера и обменяет их на токен — пароль не спрашивается."
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            text: "Войти через браузер"
            foreground: root.textColor
            onClicked: root.signIn()
          }
        }

        // ----------------------------------------------------- player ---
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          visible: root.signedIn

          BorderSurface {
            Layout.alignment: Qt.AlignTop
            width: Style.space(64)
            height: Style.space(64)
            radius: Style.spacing.labelGap
            color: Style.normalFillFor(root.textColor, Color.accent)
            borderSpec: root.buffering
              ? Border.none()
              : Border.controlSpec("normal", root.textColor, Color.accent)

            Image {
              anchors.fill: parent
              anchors.margins: Style.space(2)
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              source: root.onAir()
                ? String(root.radioValue("logo", ""))
                : (root.hasTrack && root.trackValue("thumb", "") ? root.trackValue("thumb", "") : "")
              visible: source !== ""
            }

            Text {
              anchors.centerIn: parent
              visible: !root.hasTrack || !root.trackValue("thumb", "")
              text: "󰝚"
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
            }

            // The percentage gets its own surface. Over album art a fixed white on
            // black reads badly on a bright cover and worse on a dark one; the
            // scrim is the theme's panel colour, and the label is the panel
            // foreground, which contrasts with it by construction.
            Rectangle {
              anchors.fill: parent
              radius: parent.radius
              visible: root.buffering
              color: Util.alpha(root.panelBackground, 0.82)
            }

            Text {
              anchors.centerIn: parent
              visible: root.buffering && !root.bufferIndeterminate
              textFormat: Text.PlainText
              text: Math.round(Math.max(0, root.bufferProgress) * 100) + "%"
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            // The frame is the same component as in the bar, just larger: one
            // indicator in both places, drawn on the border the artwork already
            // has.
            ProgressFrame {
              anchors.fill: parent
              visible: root.buffering
              progress: Math.max(0, root.bufferProgress)
              indeterminate: root.bufferIndeterminate
              color: Color.accent
              cornerRadius: Style.spacing.labelGap
              thickness: Math.max(2, Style.space(3))
            }
          }

          ColumnLayout {
            Layout.fillWidth: true
            // Top-aligned, not stretched: filling this column vertically made the
            // whole row swallow the height the list below needs, and the list —
            // the only thing here with `Layout.fillHeight` — was left 2 px tall.
            Layout.alignment: Qt.AlignTop
            spacing: Style.space(2)

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
              text: root.onAir()
                ? String(root.radioValue("name", "Радио"))
                : (root.hasTrack ? root.trackValue("title") : "Ничего не играет")
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              elide: Text.ElideRight
              visible: root.hasTrack || root.onAir()
              text: root.onAir() ? "Радио · в эфире" : root.trackValue("artist", "")
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              // A live stream has no position and no length to show.
              visible: root.hasTrack && !root.onAir()
              text: root.clock(root.displayPosition) + " / " + root.clock(root.duration)
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSlider {
          Layout.fillWidth: true
          // Seeking means nothing until the file is on disk: the position would
          // move the track that is still playing, not the one being fetched.
          enabled: !root.buffering
          opacity: root.buffering ? 0.5 : 1.0
          visible: root.hasTrack && root.duration > 0
          minimum: 0
          maximum: Math.max(1, root.duration)
          value: root.displayPosition
          integer: true
          bar: root.bar
          onMoved: function(value) { root.seekLive(value) }
          onReleased: function(value) { root.seekFinal(value) }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.signedIn

          Button {
            visible: !root.onAir()
            iconText: root.liked ? "󰋕" : "󰋑"
            foreground: root.liked ? Color.urgent : root.textColor
            enabled: root.hasTrack
            opacity: enabled ? 1.0 : 0.4
            tooltipText: root.liked ? "Убрать из моей музыки" : "В мою музыку"
            onClicked: root.toggleLike()
          }

          Item { Layout.fillWidth: true }

          Button {
            iconText: "󰒮"
            foreground: root.textColor
            enabled: root.queue.length > 0
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.skipPrevious()
          }

          Button {
            iconText: root.playing ? "󰏤" : "󰐊"
            foreground: root.textColor
            enabled: root.hasTrack || root.queue.length > 0
            opacity: !enabled ? 0.4 : (root.loading ? 0.5 : 1.0)
            onClicked: root.togglePause()
          }

          Button {
            iconText: "󰒭"
            foreground: root.textColor
            enabled: root.queue.length > 0
            opacity: enabled ? 1.0 : 0.4
            onClicked: root.skipNext()
          }

          Item { Layout.fillWidth: true }
        }

        // Volume has its own row: a slider squeezed next to the transport was
        // cramped, and this is the control the hand reaches for most often.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.signedIn

          Button {
            iconText: root.displayVolume <= 0 ? "󰝟" : "󰕾"
            foreground: root.textColor
            tooltipText: root.displayVolume <= 0 ? "Включить звук" : "Выключить звук"
            onClicked: root.toggleMute()
          }

          PanelSlider {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            minimum: 0
            maximum: 100
            value: root.displayVolume
            integer: true
            bar: root.bar
            onMoved: function(value) { root.setVolume(value, true) }
            onReleased: function(value) { root.setVolume(value, false) }
          }

          Text {
            Layout.preferredWidth: Style.space(38)
            Layout.alignment: Qt.AlignVCenter
            horizontalAlignment: Text.AlignRight
            textFormat: Text.PlainText
            text: Math.round(root.displayVolume) + "%"
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.textColor; visible: root.signedIn }

        // ------------------------------------------------------- views ---
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.signedIn

          Button {
            text: "Очередь"
            foreground: root.textColor
            selected: root.view === "queue"
            onClicked: root.view = "queue"
          }

          Button {
            text: "Обзор"
            foreground: root.textColor
            selected: root.view === "browse"
            onClicked: {
              root.view = "browse"
              root.browseSource(root.browseSlug !== "" ? root.browseSlug : "explore")
            }
          }

          Button {
            text: "Поиск"
            foreground: root.textColor
            selected: root.view === "search"
            onClicked: {
              root.view = "search"
              searchField.forceActiveFocus()
            }
          }

          Button {
            iconText: "󰒓"
            foreground: root.textColor
            selected: root.view === "settings"
            tooltipText: "Настройки"
            onClicked: root.view = "settings"
          }

          Item { Layout.fillWidth: true }
        }

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)
          visible: root.signedIn && root.view === "search"

          TextField {
            id: searchField
            Layout.fillWidth: true
            placeholderText: "Артист, трек, альбом"
            foreground: root.textColor
            accent: Color.accent
            // Two-way in one direction only: the field follows the query, and a
            // keystroke writes it back. The stored query is what the commands
            // use, which is why the missing half of this pair left searching
            // silently doing nothing.
            text: root.query
            // Enter is not handled here: the panel's key catcher owns it, and two
            // handlers meant the field re-ran the search first, which reset the
            // list selection before Enter could play it.
            onTextChanged: {
              if (text !== root.query) root.query = text
              suggestTimer.restart()
              searchTimer.restart()
            }
          }

          Button {
            iconText: "󰅖"
            foreground: root.textColor
            visible: root.query.length > 0
            tooltipText: "Очистить"
            onClicked: {
              root.clearSearch()
              searchField.forceActiveFocus()
            }
          }
        }

        Flickable {
          id: listView
          Layout.fillWidth: true
          Layout.fillHeight: true
          visible: root.signedIn
          clip: true
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: listColumn
            width: listView.width
            spacing: Style.space(4)

            // Queue: the sources that fill it, then the next few tracks.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.view === "queue"

              Row {
                spacing: Style.space(6)

                Button {
                  text: "Моя музыка"
                  foreground: root.textColor
                  onClicked: root.playSection("all", "Моя музыка")
                }

                Repeater {
                  model: root.sources.filter(function(s) { return s.url.indexOf("section=updates") !== -1 })
                  delegate: Button {
                    text: modelData ? modelData.title : ""
                    foreground: root.textColor
                    onClicked: if (modelData) root.playSection(modelData.id, modelData.title)
                  }
                }
              }

              PanelSectionHeader {
                text: "Дальше в очереди"
                foreground: root.dim
                visible: root.upcoming.length > 0
              }

              Repeater {
                id: queueRepeater
                model: root.upcoming
                delegate: Button {
                  width: listColumn.width
                  leftAlign: true
                  selected: index === root.cursor
                  text: modelData ? ((root.upcomingStart + index + 1) + ".  " + modelData.artist + " — " + modelData.title) : ""
                  foreground: root.textColor
                  onClicked: root.playQueueAt(root.upcomingStart + index)
                }
              }

              Text {
                visible: root.queue.length === 0 && !root.queueLoading
                textFormat: Text.PlainText
                text: "Очередь пуста. Начни с «Моя музыка»."
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }
            }

            // Browsing the catalog: choose a section, then look at what it
            // holds. Sections come page by page, so «Ещё» appends the next page
            // to the list instead of replacing what is already on screen.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.view === "browse"

              // The sections do not fit side by side, and wrapping them would
              // cost a row of height: the row scrolls instead.
              Flickable {
                width: parent.width
                height: sourceRow.height
                contentWidth: sourceRow.width
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Row {
                  id: sourceRow
                  spacing: Style.space(6)

                  Repeater {
                    model: root.sources
                    delegate: Button {
                      text: modelData ? String(modelData.title || "") : ""
                      foreground: root.textColor
                      selected: modelData ? root.sourceSlug(modelData) === root.browseSlug : false
                      onClicked: if (modelData) root.browseSource(root.sourceSlug(modelData))
                    }
                  }
                }
              }

              Flickable {
                width: parent.width
                height: playlistRow.height
                contentWidth: playlistRow.width
                clip: true
                visible: root.browsePlaylists.length > 0
                boundsBehavior: Flickable.StopAtBounds

                Row {
                  id: playlistRow
                  spacing: Style.space(6)

                  Repeater {
                    model: root.browsePlaylists
                    delegate: Button {
                      text: modelData ? String(modelData.title || "") : ""
                      tooltipText: modelData
                        ? (String(modelData.title || "")
                           + (modelData.count ? " · " + modelData.count + " треков" : ""))
                        : ""
                      foreground: root.textColor
                      onClicked: if (modelData) root.playPlaylist(modelData)
                    }
                  }
                }
              }

              PanelSectionHeader {
                text: root.browseHeader
                foreground: root.dim
                visible: root.browseHeader !== ""
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                visible: root.browseSlug === ""
                text: "Выбери раздел: подборки, новинки, эфир."
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                id: stationRepeater
                model: root.browseSlug === "radiostations" ? root.stations : []
                delegate: Button {
                  width: listColumn.width
                  leftAlign: true
                  // The accent fill is the keyboard selection; what is playing is
                  // marked with a glyph, so the two never look alike.
                  selected: index === root.cursor
                  text: modelData
                    ? ((root.onAir() && root.radioValue("id", 0) === modelData.id ? "▶  " : "")
                       + String(modelData.name || ""))
                    : ""
                  foreground: root.onAir() && modelData && root.radioValue("id", 0) === modelData.id
                    ? Color.accent : root.textColor
                  onClicked: if (modelData) root.playStation(modelData)
                }
              }

              Repeater {
                id: browseTrackRepeater
                model: root.browseSlug === "radiostations" ? [] : root.browseTracks
                delegate: Button {
                  width: listColumn.width
                  leftAlign: true
                  selected: index === root.cursor
                  text: modelData ? (modelData.artist + " — " + modelData.title) : ""
                  foreground: root.textColor
                  onClicked: if (modelData) {
                    if (root.browseSlug === "radiostations") root.playStation(modelData)
                    else root.playBrowseTrack(index)
                  }
                }
              }

              Button {
                width: listColumn.width
                leftAlign: true
                visible: root.browseNext !== ""
                enabled: !root.browseMoreLoading
                opacity: enabled ? 1.0 : 0.5
                text: "Ещё"
                foreground: root.textColor
                onClicked: root.browseMore()
              }
            }

            // Search: suggestions while typing, results once a search has run.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.view === "search"

              Text {
                visible: root._queryLength < 2
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: "Начни печатать — подсказки ВК появятся сами, поиск пойдёт после паузы"
                color: root.dim
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
              }

              PanelSectionHeader {
                text: root.searchHeader
                foreground: root.dim
                visible: root.searchHeaderVisible
              }

              Repeater {
                id: suggestionRepeater
                model: root.suggestionsShown
                delegate: Button {
                  width: listColumn.width
                  leftAlign: true
                  selected: index === root.cursor
                  text: modelData ? String(modelData) : ""
                  foreground: root.textColor
                  onClicked: if (modelData) root.searchSuggestion(String(modelData))
                }
              }

              Repeater {
                id: resultRepeater
                model: root.resultsShown
                delegate: Button {
                  width: listColumn.width
                  leftAlign: true
                  selected: index === root.cursor
                  text: modelData ? (modelData.artist + " — " + modelData.title) : ""
                  foreground: root.textColor
                  onClicked: root.playSearchResult(index)
                }
              }
            }

            // Settings. Everything here is a backend preference: the widget only
            // sends the new value and re-reads the status.
            Column {
              width: parent.width
              spacing: Style.spacing.controlGap
              visible: root.view === "settings"

              PanelSectionHeader { text: "Кеш"; foreground: root.dim }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - cacheSwitch.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  text: "Хранить треки на диске · " + root.megabytes(root.status.cache ? root.status.cache.bytes : 0)
                    + " из " + root.megabytes(root.status.cache ? root.status.cache.limit_bytes : 0)
                    + (root.status.cache && root.status.cache.files ? " · файлов " + root.status.cache.files : "")
                  color: root.textColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                ToggleSwitch {
                  id: cacheSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.prefs.cacheEnabled !== false
                  onToggled: root.setPreference("cacheEnabled", !root.prefs.cacheEnabled)
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                visible: root.prefs.cacheEnabled !== false

                Text {
                  text: "Лимит кеша"
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                PanelSlider {
                  width: parent.width - 150
                  anchors.verticalCenter: parent.verticalCenter
                  minimum: 64
                  maximum: 1024
                  step: 64
                  integer: true
                  value: Number(root.prefs.cacheLimitMb) || 256
                  bar: root.bar
                  onReleased: function(value) { root.setPreference("cacheLimitMb", Math.round(value)) }
                }

                Text {
                  text: (Number(root.prefs.cacheLimitMb) || 256) + " МБ"
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                visible: root.prefs.cacheEnabled !== false

                Text {
                  width: parent.width - clearButton.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  text: "Освободить место прямо сейчас"
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Button {
                  id: clearButton
                  text: "Очистить кеш"
                  foreground: root.textColor
                  onClicked: root.call([root.cli, "cache", "clear"], function() { root.refresh() })
                }
              }

              PanelSeparator { width: parent.width; foreground: root.textColor }

              PanelSectionHeader { text: "Воспроизведение"; foreground: root.dim }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - prefetchSwitch.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  text: "Скачивать следующий трек заранее — переключение без паузы"
                  color: root.textColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                ToggleSwitch {
                  id: prefetchSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.prefs.prefetchEnabled !== false
                  enabled: root.prefs.cacheEnabled !== false
                  opacity: enabled ? 1.0 : 0.4
                  onToggled: root.setPreference("prefetchEnabled", !root.prefs.prefetchEnabled)
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - restoreSwitch.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  wrapMode: Text.WordWrap
                  text: "Помнить очередь и позицию после перезапуска"
                  color: root.textColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                ToggleSwitch {
                  id: restoreSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.prefs.restoreOnStart !== false
                  onToggled: root.setPreference("restoreOnStart", !root.prefs.restoreOnStart)
                }
              }

              PanelSeparator { width: parent.width; foreground: root.textColor }

              PanelSectionHeader { text: "Строка в баре"; foreground: root.dim }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - artworkSwitch.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Обложка трека"
                  color: root.textColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                ToggleSwitch {
                  id: artworkSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.prefs.showArtwork !== false
                  onToggled: root.setPreference("showArtwork", !root.prefs.showArtwork)
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                Text {
                  width: parent.width - textSwitch.width - Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Название и исполнитель"
                  color: root.textColor
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                ToggleSwitch {
                  id: textSwitch
                  anchors.verticalCenter: parent.verticalCenter
                  checked: root.prefs.showText !== false
                  onToggled: root.setPreference("showText", !root.prefs.showText)
                }
              }

              Row {
                width: parent.width
                spacing: Style.space(8)
                visible: root.prefs.showText !== false

                Text {
                  text: "Ширина подписи"
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                PanelSlider {
                  width: parent.width - 150
                  anchors.verticalCenter: parent.verticalCenter
                  minimum: 80
                  maximum: 400
                  step: 20
                  integer: true
                  value: Number(root.prefs.labelWidth) || 180
                  bar: root.bar
                  onReleased: function(value) { root.setPreference("labelWidth", Math.round(value)) }
                }

                Text {
                  text: (Number(root.prefs.labelWidth) || 180) + " px"
                  anchors.verticalCenter: parent.verticalCenter
                  color: root.dim
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
        // The line sits at the bottom of the card, not inside a list: one place
        // for every view, its own row of height, and the list keeps all of its
        // own. The row is always here, so nothing shifts when it lights up.
        Item {
          Layout.fillWidth: true
          Layout.preferredHeight: Math.max(2, Style.space(2))
          visible: root.signedIn

          ProgressLine {
            anchors.fill: parent
            thickness: Math.max(2, Style.space(2))
            color: Color.accent
            visible: root.anyLoading()
          }
        }

      }
    }
  }
}
