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
  readonly property string searchHeader: {
    if (root._queryLength < 2) return ""
    // A playlist search answers in playlists, so its heading counts those.
    if (root.searchMode === "playlists") {
      if (root.playlistSearchLoading) return "Ищу…"
      var found = root.foundPlaylists.length
      if (found === 0) return "Плейлисты не найдены"
      return "Найдено " + found + " " + root.plural(found, "плейлист", "плейлиста", "плейлистов")
    }
    if (root.searchState === "searching") return "Ищу…"
    if (!root.resultsShowing) return "Подсказки"
    if (root.results.length === 0) {
      return root.suggestionsShown.length > 0 ? "Ничего не найдено. Похожее:" : "Ничего не найдено"
    }
    var span = root.tracksSpan(root.results)
    return "Найдено " + root.results.length + (span === "" ? "" : " · " + span)
  }
  // The popup answers to five keys and nothing on screen says so. Esc is the one
  // that means two things, so the hint follows the query.
  readonly property string keyHints: (root.view === "search" && root.query.length > 0)
    ? "Space пауза · ↑↓ выбор · Enter играть · Esc очистить поиск"
    : "Space пауза · n/p трек · ↑↓ выбор · Enter играть · Esc закрыть"

  // The heading is worth its line only when there is something under it: while
  // the query is still short nothing is shown at all.
  readonly property bool searchHeaderVisible: root.searchHeader !== ""
    && (root.searchState !== "typing" || root.suggestionsShown.length > 0)

  // «6 ч 12 мин» for a list of tracks: the queue and a section page are both
  // worth summarising, and VK already sent us every duration.
  function humanSpan(seconds) {
    if (!(seconds > 0)) return ""
    var minutes = Math.round(seconds / 60)
    var hours = Math.floor(minutes / 60)
    minutes = minutes % 60
    if (hours > 0) return hours + " ч " + minutes + " мин"
    return minutes + " мин"
  }

  function tracksSpan(tracks) {
    var seconds = 0
    for (var i = 0; i < (tracks ? tracks.length : 0); i++) {
      var value = Number(tracks[i] ? tracks[i].duration : 0)
      if (value > 0 && value < 86400) seconds += value
    }
    return root.humanSpan(seconds)
  }

  // «100 треков · 6 ч 12 мин» — how long a list is, in both senses.
  function listSummary(tracks, one, few, many) {
    var count = tracks ? tracks.length : 0
    if (count === 0) return ""
    var parts = count + " " + root.plural(count, one, few, many)
    var span = root.tracksSpan(tracks)
    return span === "" ? parts : parts + " · " + span
  }

  // What is playing, by key. The queue's own rows start after the current track,
  // but a section page or a search result can contain it, and then the row says
  // so with a glyph — the accent fill belongs to the keyboard selection.
  function isPlayingTrack(key) {
    return root.hasTrack && String(key) !== "" && root.trackValue("key", "") === String(key)
  }

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
  // Which popup shape is in use: the compact one or the extended two-column one.
  // Both are built from the same blocks, and only the visible one takes keys.
  //
  // Read through a function rather than a cached property, for the same reason
  // `onAir` is: a `readonly property bool` whose binding digs into a field of a
  // `var` kept its first value, and the card stayed 400 wide after the setting
  // was switched until the shell was restarted.
  function isExtended() {
    return String(root.setting("popupView", root.prefs.popupView || "compact")) === "extended"
  }

  function activeList() {
    return root.isExtended() ? extendedList : compactList
  }

  function activeField() {
    return root.isExtended() ? extendedFieldRow.field : compactFieldRow.field
  }

  function activeBody() {
    return root.isExtended() ? extendedBody : compactBody
  }

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
    id: wheelWrite
    interval: 400
    repeat: false
    // A wheel notch is a whole action, unlike a drag: the volume is written down
    // once the wheel stops, so a restart does not lose it.
    onTriggered: if (root.volumeTarget >= 0) root.setVolume(root.volumeTarget, false)
  }

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

  // Recent queries, most recent first, from the daemon's state file. A committed
  // search is what goes in: the debounce means only settled text is ever sent.
  readonly property var history: root.status.history || []
  // People whose playlists were opened before: the local stand-in for VK's
  // bookmarks, which its API no longer exposes.
  readonly property var people: root.status.people || []

  function runSearch(force) {
    var text = root.query.trim()
    if (text.length < 2) {
      root.results = []
      root.foundPlaylists = []
      root.searchState = "typing"
      return
    }
    // One box, two kinds of answer: a playlist search is the same request to a
    // different VK method, so everything else about searching stays the same.
    if (root.searchMode === "playlists") {
      if (!force && text === root._searchedQuery && root.foundPlaylists.length > 0) return
      root._searchedQuery = text
      root.searchState = "results"
      root.loadPlaylistSearch()
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
    root.call([root.cli, "search", text, "--remember"], function(answer) {
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

  // People and their playlists: the friend list, anyone opened by link or name,
  // and whatever the playlist search found. VK's own bookmarks API is gone, so
  // «Недавние» — the people opened before — stands in for «закладки».
  property var friends: []
  property bool friendsLoading: false
  property var person: null
  property var personPlaylists: []
  property bool personLoading: false
  property string personQuery: ""
  property var foundPlaylists: []
  property int foundPlaylistsTotal: 0
  property bool playlistSearchLoading: false
  // «Треки» or «Плейлисты»: one search box, two kinds of answer.
  property string searchMode: "tracks"

  // Right-clicking a row offers what can be done with a track without throwing
  // away the queue you are listening to.
  property var pendingTrack: null

  function openRowMenu(track) {
    if (!track || !track.key) return
    root.pendingTrack = track
  }

  function closeRowMenu() {
    root.pendingTrack = null
  }

  function queuePendingTrack(next) {
    var track = root.pendingTrack
    root.closeRowMenu()
    if (!track || !track.key) return
    root.call([root.cli, "queue", next ? "next" : "add", String(track.key)], function() {
      root.refresh()
    })
  }

  function searchSuggestion(text) {
    if (!text) return
    root.query = text
    root.runSearch(true)
  }

  function setSearchMode(mode) {
    if (root.searchMode === mode) return
    root.searchMode = mode
    root.cursor = -1
    if (root.query.trim().length >= 2) root.runSearch(true)
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
      if (root.browseSlug === "person") return root.personPlaylists
      if (root.browseSlug === "friends") return root.friends
      return root.browseSlug === "radiostations" ? root.stations : root.browseTracks
    }
    if (root.view === "search") {
      if (root.searchMode === "playlists") return root.foundPlaylists
      if (root.resultsShown.length > 0) return root.resultsShown
      // With an empty field the list on screen is the recent queries.
      if (root._queryLength < 2 && root.history.length > 0) return root.history
      return root.suggestionsShown
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
    if (root.view === "queue") return root.activeList().queueRepeater.itemAt(index)
    if (root.view === "browse") {
      if (root.browseSlug === "person") {
        return root.gridView
          ? root.activeList().browseGrid.itemAt(index)
          : root.activeList().browsePlaylistRows.itemAt(index)
      }
      if (root.browseSlug === "friends") return root.activeList().friendRepeater.itemAt(index)
      return root.browseSlug === "radiostations"
        ? root.activeList().stationRepeater.itemAt(index)
        : root.activeList().browseTrackRepeater.itemAt(index)
    }
    if (root.view === "search") {
      if (root.searchMode === "playlists") {
        return root.gridView
          ? root.activeList().searchGrid.itemAt(index)
          : root.activeList().searchPlaylistRows.itemAt(index)
      }
      if (root.resultsShown.length > 0) return root.activeList().resultRepeater.itemAt(index)
      if (root._queryLength < 2 && root.history.length > 0) {
        return root.activeList().historyRepeater.itemAt(index)
      }
      return root.activeList().suggestionRepeater.itemAt(index)
    }
    return null
  }

  function revealCursor() {
    var row = root.cursorRow()
    if (!row) return
    var margin = Style.space(6)
    var top = row.y
    var bottom = top + row.height
    if (top - margin < root.activeList().contentY) {
      root.activeList().contentY = Math.max(0, top - margin)
    } else if (bottom + margin > root.activeList().contentY + root.activeList().height) {
      root.activeList().contentY = bottom + margin - root.activeList().height
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
      if (root.browseSlug === "person") root.playPlaylist(root.personPlaylists[index])
      else if (root.browseSlug === "friends") root.openPerson(root.friends[index].id)
      else if (root.browseSlug === "radiostations") root.playStation(root.stations[index])
      else root.playBrowseTrack(index)
    } else if (root.view === "search") {
      if (root.searchMode === "playlists") root.playPlaylist(root.foundPlaylists[index])
      else if (root.resultsShown.length > 0) root.playSearchResult(index)
      else if (root._queryLength < 2 && root.history.length > 0) {
        root.searchSuggestion(String(root.history[index]))
      } else root.searchSuggestion(String(root.suggestionsShown[index]))
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
    if (root.browseSlug === "person") {
      if (root.personLoading) return "Открываю…"
      var mine = root.personPlaylists.length
      if (!root.person) return "Человек не найден"
      return String(root.person.name || "Человек")
        + (mine === 0 ? " · пусто" : " · " + mine + " " + root.plural(mine, "плейлист", "плейлиста", "плейлистов"))
    }
    if (root.browseSlug === "friends") {
      if (root.friendsLoading) return "Друзья · загрузка…"
      var count = root.friends.length
      return "Друзья · " + count + " " + root.plural(count, "человек", "человека", "человек")
    }
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
    return title + " · " + root.listSummary(root.browseTracks, "трек", "трека", "треков")
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

  function setPlaylistView(mode) {
    root.setPreference("playlistView", mode)
  }

  function browseFriends() {
    if (root.browseSlug === "friends" && root.friends.length > 0) return
    root.browseSlug = "friends"
    root.browseTitle = "Друзья"
    root.browseTracks = []
    root.browsePlaylists = []
    root.browseNext = ""
    root.closePerson()
    if (root.friends.length > 0) return
    root.friendsLoading = true
    root.call([root.cli, "friends"], function(answer) {
      root.friendsLoading = false
      root.friends = (answer && answer.ok && answer.data) ? answer.data : []
    })
  }

  function openPerson(reference) {
    var text = String(reference || "").trim()
    if (text === "") return
    root.personLoading = true
    root.person = null
    root.personPlaylists = []
    root.browseSlug = "person"
    root.browseTracks = []
    root.browseNext = ""
    root.browseTitle = "Человек"
    root.call([root.cli, "person", text], function(answer) {
      root.personLoading = false
      if (answer && answer.ok && answer.data) {
        root.person = answer.data.person || null
        root.personPlaylists = answer.data.playlists || []
        // The same list feeds the gallery and the rows: one place decides what a
        // person's page shows.
        root.browsePlaylists = root.personPlaylists
        root.browseTitle = root.person ? String(root.person.name || "Человек") : "Человек"
      } else {
        root.notice = "Человек не найден"
      }
    })
  }

  function openPersonFromField() {
    root.openPerson(root.personQuery)
  }

  function closePerson() {
    root.person = null
    root.personPlaylists = []
  }

  function loadPlaylistSearch() {
    var text = root.query.trim()
    if (text.length < 2) {
      root.foundPlaylists = []
      root.foundPlaylistsTotal = 0
      return
    }
    root.playlistSearchLoading = true
    root.call([root.cli, "playlists", text], function(answer) {
      root.playlistSearchLoading = false
      if (answer && answer.ok && answer.data) {
        root.foundPlaylists = answer.data.playlists || []
        root.foundPlaylistsTotal = Number(answer.data.total || 0)
      } else {
        root.foundPlaylists = []
        root.foundPlaylistsTotal = 0
      }
    })
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

  readonly property bool shuffled: root.status.shuffle === true
  readonly property string repeatMode: String(root.status.repeat || "off")
  // Repeat has three states and two faces: the queue repeating, and the one track.
  readonly property string repeatGlyph: root.repeatMode === "one" ? "󰑘" : "󰑖"

  function toggleShuffle() {
    root.call([root.cli, "shuffle", root.shuffled ? "off" : "on"], function() { root.refresh() })
  }

  function cycleRepeat() {
    var next = root.repeatMode === "off" ? "all" : (root.repeatMode === "all" ? "one" : "off")
    root.call([root.cli, "repeat", next], function() { root.refresh() })
  }

  function removeCurrentTrack() {
    if (!root.hasTrack) return
    var index = Number(root.status.index)
    if (!(index >= 0)) return
    root.call([root.cli, "queue", "remove", String(index)], function() { root.watchForTrack() })
  }

  function clearQueue() {
    root.call([root.cli, "queue", "clear"], function() { root.refresh() })
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

  // What the bar row shows. A shell.json entry wins for that instance; the popup
  // settings are the fallback, since they are the backend's preferences.
  readonly property bool barShowArtwork: root.setting("showArtwork", root.prefs.showArtwork !== false)
  readonly property bool barShowTitle: root.setting("showTitle", root.prefs.showTitle !== false)
  readonly property bool barShowArtist: root.setting("showArtist", root.prefs.showArtist !== false)
  readonly property bool barShowControls: root.setting("showControls", root.prefs.showControls !== false)
  readonly property bool barShowProgress: root.setting("showProgress", root.prefs.showProgress !== false)
  readonly property bool barShowTime: root.setting("showTime", root.prefs.showTime === true)
  readonly property bool barShowLike: root.setting("showLike", root.prefs.showLike === true)
  readonly property string barCoverShape: String(root.setting("coverShape", root.prefs.coverShape || "rounded"))
  readonly property string barLongTitle: String(root.setting("longTitleMode", root.prefs.longTitleMode || "scroll"))
  readonly property int barInformationWidth: Number(root.setting("labelWidth", Number(root.prefs.labelWidth) || 180))
  // The scrolling label: how long each end of the text rests, and how fast it
  // moves in pixels a second. Both are taste, so both live in the settings.
  readonly property int marqueePause: {
    var value = Number(root.setting("marqueePauseMs", root.prefs.marqueePauseMs))
    return isNaN(value) ? 1600 : Math.max(0, Math.min(6000, value))
  }
  // Playlists look the same wherever they appear: covers in a gallery, or rows.
  // Three across the wide popup, two across the narrow one, so a cover is never
  // too small to recognise.
  readonly property string playlistView: String(root.setting("playlistView", root.prefs.playlistView || "list"))
  readonly property bool gridView: root.playlistView === "grid"
  readonly property int galleryColumns: root.isExtended() ? 3 : 2

  readonly property int marqueeSpeed: {
    var value = Number(root.setting("marqueeSpeed", root.prefs.marqueeSpeed))
    return isNaN(value) ? 70 : Math.max(10, Math.min(300, value))
  }
  // The progress line has something to say only for a track with a length: a
  // station is endless and shows nothing.
  readonly property bool barHasProgress: root.hasTrack && !root.onAir() && root.duration > 0
  readonly property real barProgress: root.barHasProgress
    ? Math.max(0, Math.min(1, root.displayPosition / root.duration)) : 0

  // The label shown in the bar. Signing in, an empty queue and a stopped
  // service are states of the widget, not errors: only a halt paints red.
  readonly property string barLabel: {
    if (root.halted !== "") return "остановлен"
    if (!root.signedIn) return "vk music"
    // A live station has no track behind it: its name is the whole label.
    if (root.onAir()) return String(root.radioValue("name", "радио"))
    if (!root.hasTrack) return root.loading ? "загрузка…" : "vk music"
    var title = root.barShowTitle ? root.trackValue("title") : ""
    var artist = root.barShowArtist ? root.trackValue("artist", "") : ""
    if (title !== "" && artist !== "") return title + "  ·  " + artist
    if (title !== "") return title
    if (artist !== "") return artist
    return "vk music"
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
    // The wheel is the volume, as it is on most bars: one notch, five percent.
    // The steps go out live and the value is written down once the wheel stops.
    onWheel: function(wheel) {
      var delta = wheel.angleDelta.y > 0 ? 5 : -5
      root.setVolume(Math.round(root.displayVolume) + delta, true)
      wheelWrite.restart()
      wheel.accepted = true
    }
  }

  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(6)

    BorderSurface {
      id: artwork
      // 20 px matches the cover size the other bar players in this shell use.
      width: Style.space(20)
      height: width
      radius: root.barCoverShape === "circle" ? width / 2
        : (root.barCoverShape === "square" ? 0 : Style.spacing.labelGap)
      visible: root.barShowArtwork
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
        cornerRadius: artwork.radius
        thickness: Math.max(1.5, Style.space(2))
      }
    }

    Item {
      id: labelClip
      visible: root.barShowTitle || root.barShowArtist
      width: Math.min(root.barInformationWidth, labelText.implicitWidth)
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

        readonly property bool needsScroll: implicitWidth > labelClip.width
        // How far the text has to travel for its end to come into view: exactly
        // the overflow, not a pixel more. Walking to the text's own width used to
        // carry it off the edge, which left the label empty until the next pass —
        // a title that looked broken rather than long.
        readonly property real travel: Math.max(0, implicitWidth - labelClip.width)

        // The text is placed from an animated offset instead of animating `x`
        // itself: an animation on `x` discards the binding that puts the text back
        // at the start, so a clip that stopped scrolling kept its last position —
        // off the edge — and a perfectly short title looked like an empty label
        // until another long one came along.
        property real scrollOffset: 0
        x: -scrollOffset

        // A new title starts at its beginning, and one that fits stays there.
        onTextChanged: scrollOffset = 0
        onNeedsScrollChanged: if (!needsScroll) scrollOffset = 0

        // Both ends of the walk get a pause: the beginning while it is there, and
        // the end once it has arrived. With the text stopping inside the label
        // instead of past it, the field is never empty and neither end is missed.
        SequentialAnimation on scrollOffset {
          running: root.barLongTitle === "scroll" && labelText.needsScroll
          loops: Animation.Infinite

          PauseAnimation { duration: root.marqueePause }

          NumberAnimation {
            from: 0
            to: labelText.travel
            duration: Math.max(400, labelText.travel / Math.max(1, root.marqueeSpeed) * 1000)
            easing.type: Easing.Linear
          }

          PauseAnimation { duration: root.marqueePause }

          // Back to the beginning: a jump, made to read as a loop rather than a
          // glitch by the pause in front of it.
          PropertyAction { target: labelText; property: "scrollOffset"; value: 0 }
        }
      }
    }

    // The time is a caption in the same dim colour the popup uses for them.
    Text {
      id: barTime
      visible: root.barShowTime && root.hasTrack && !root.onAir()
      textFormat: Text.PlainText
      text: root.clock(root.displayPosition) + " / " + root.clock(root.duration)
      color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.55)
      font.family: bar ? bar.fontFamily : Style.font.family
      font.pixelSize: Style.font.caption
      anchors.verticalCenter: parent.verticalCenter
    }

    // Liking from the bar, without opening the popup.
    Item {
      visible: root.barShowLike && root.hasTrack && !root.onAir()
      width: Style.space(18)
      height: root.implicitHeight
      anchors.verticalCenter: parent.verticalCenter

      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: root.liked ? "󰋑" : "󰋕"
        color: root.liked ? Color.urgent : root.fg
        font.family: bar ? bar.fontFamily : Style.font.family
        font.pixelSize: Style.font.caption
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.toggleLike()
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
      visible: root.hasTrack && root.barShowControls

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

  // Where the track is, along the bottom edge of the widget: the same line the
  // lists use while loading, with a length instead of a guess. It is a sibling of
  // the row, not a child — a Row cannot lay out an anchored item.
  ProgressLine {
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    visible: root.barShowProgress && root.barHasProgress
    indeterminate: false
    progress: root.barProgress
    thickness: Math.max(2, Style.space(2))
    color: Color.accent
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
      body: root.activeBody().implicitHeight,
      available: [panel.availableCardWidth, panel.availableCardHeight],
      inset: panel.verticalContentInset,
      blocks: root.activeBody().children.length,
      list: [root.activeList().height, root.activeList().contentHeight],
      shown: [root.suggestionsShown.length, root.resultsShown.length]
    }))
    console.log("[vk-music] body", JSON.stringify({
      extended: root.isExtended(),
      children: Array.prototype.map.call(root.activeBody().children, function(child, i) {
        return [i, String(child).split("(")[0].replace("QQuick", ""), Math.round(child.height),
                Math.round(child.implicitHeight), child.visible, Math.round(child.Layout.preferredHeight) || 0]
      })
    }))
    if (root.view === "search") root.activeField().forceActiveFocus()
  }

  Timer {
    id: afterOpen
    interval: 400
    repeat: false
    onTriggered: root.afterOpen()
  }

  // ------------------------------------------------------------ settings ---
  //
  // Fourteen preferences need a shape of their own, or the page turns into a wall
  // of rows. Three shapes are enough: a labelled switch, a chip that flips one
  // preference, and a row of chips that picks one value out of a list.

  component ToggleRow: Row {
    id: toggleRow
    property string label: ""
    property string key: ""
    property bool on: false
    property bool dim: false
    width: parent ? parent.width : 0
    spacing: Style.space(8)

    Text {
      width: parent.width - toggle.width - Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: toggleRow.label
      color: toggleRow.dim ? root.dim : root.textColor
      font.family: Style.font.family
      font.pixelSize: toggleRow.dim ? Style.font.caption : Style.font.bodySmall
    }

    ToggleSwitch {
      id: toggle
      anchors.verticalCenter: parent.verticalCenter
      checked: toggleRow.on
      onToggled: root.setPreference(toggleRow.key, !toggleRow.on)
    }
  }

  component ChipToggle: Button {
    property string key: ""
    property bool on: false
    foreground: root.textColor
    selected: on
    onClicked: root.setPreference(key, !on)
  }

  component ChoiceRow: Column {
    id: choiceRow
    property string label: ""
    property string key: ""
    property string value: ""
    property var options: []
    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Text {
      text: choiceRow.label
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Row {
      spacing: Style.space(6)

      Repeater {
        model: choiceRow.options
        delegate: Button {
          text: modelData ? String(modelData.label) : ""
          foreground: root.textColor
          selected: choiceRow.value === (modelData ? modelData.value : "")
          onClicked: if (modelData) root.setPreference(choiceRow.key, modelData.value)
        }
      }
    }
  }

  // The popup's list: the queue, a catalog section, the search results or the
  // settings page. It is a component of its own because the extended popup shows
  // it beside the player rather than under it.
  // A playlist in the gallery: the cover, its name, how long it is. The accent
  // frame is the keyboard cursor, the way the fill is on a row.
  component PlaylistCard: Item {
    id: card
    property var item: null
    property real cellWidth: 100
    property bool selected: false
    signal activated()

    width: cellWidth
    // The Column lays itself out; the MouseArea sits beside it, because a
    // positioner refuses to lay out an anchored child.
    height: body.implicitHeight

    Column {
      id: body
      width: parent.width
      spacing: Style.space(3)

      // The accent frame is the keyboard cursor, the way the fill is on a row.
      BorderSurface {
        width: parent.width
        height: width
        radius: Style.spacing.labelGap
        color: Color.popups.background
        borderSpec: card.selected
          ? Border.controlSpec("selected", Color.foreground, Color.accent, Color.urgent)
          : Border.none()

        Image {
          anchors.fill: parent
          anchors.margins: Style.space(2)
          source: card.item ? String(card.item.cover || "") : ""
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          visible: String(card.item ? card.item.cover || "" : "") !== ""
        }

        Text {
          anchors.centerIn: parent
          visible: !(card.item && card.item.cover)
          text: "󰝚"
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.displayLarge
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 1
        text: card.item ? String(card.item.title || "") : ""
        color: root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: card.item && card.item.count
          ? (Number(card.item.count) + " " + root.plural(Number(card.item.count), "трек", "трека", "треков"))
          : ""
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: card.activated()
    }
  }

  // The same list of playlists as rows, for people who would rather read names.
  component PlaylistRows: Column {
    id: rows
    property var items: []
    signal picked(int index)

    function itemAt(index) { return rowRepeater.itemAt(index) }

    width: parent ? parent.width : 0
    spacing: Style.space(4)

    Repeater {
      id: rowRepeater
      model: rows.items
      delegate: Button {
        width: rows.width
        leftAlign: true
        selected: index === root.cursor
        text: modelData
          ? (String(modelData.title || "")
             + (modelData.count
                ? "  ·  " + modelData.count + " " + root.plural(Number(modelData.count), "трек", "трека", "треков")
                : ""))
          : ""
        foreground: root.textColor
        onClicked: rows.picked(index)
      }
    }
  }

  // And the gallery: the same items, as covers.
  component PlaylistGrid: Grid {
    id: grid
    property var items: []
    readonly property real cellWidth: (width - spacing * (columns - 1)) / Math.max(1, columns)
    signal picked(int index)

    function itemAt(index) { return cellRepeater.itemAt(index) }

    width: parent ? parent.width : 0
    columns: root.galleryColumns
    spacing: Style.space(6)

    Repeater {
      id: cellRepeater
      model: grid.items
      delegate: PlaylistCard {
        item: modelData
        cellWidth: grid.cellWidth
        selected: index === root.cursor
        onActivated: grid.picked(index)
      }
    }
  }

  // Gallery or rows: two small buttons in the header, one remembered setting.
  component PlaylistViewSwitch: Row {
    spacing: Style.space(4)

    Button {
      iconText: "󰕳"
      foreground: root.textColor
      selected: root.gridView
      tooltipText: "Галерея обложек"
      onClicked: root.setPlaylistView("grid")
    }

    Button {
      iconText: "󰉹"
      foreground: root.textColor
      selected: !root.gridView
      tooltipText: "Список"
      onClicked: root.setPlaylistView("list")
    }
  }

  // What a right-click on a track row offers. It floats over the panel, anchored
  // to the bottom of the key catcher, so nothing moves when it appears.
  component RowMenu: BorderSurface {
    id: rowMenu
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(10)
    radius: Style.cornerRadius
    color: Color.popups.background
    borderSpec: Border.controlSpec("selected", Color.foreground, Color.accent, Color.urgent)
    padding: Style.spacing.controlGap
    implicitHeight: menuRow.implicitHeight + rowMenu.contentTopInset + rowMenu.contentBottomInset
    visible: root.pendingTrack !== null

    RowLayout {
      id: menuRow
      x: rowMenu.contentLeftInset
      y: rowMenu.contentTopInset
      width: rowMenu.width - rowMenu.contentLeftInset - rowMenu.contentRightInset
      spacing: Style.space(6)

      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        elide: Text.ElideRight
        color: root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        text: root.pendingTrack
          ? (root.pendingTrack.artist + " — " + root.pendingTrack.title)
          : ""
      }

      Button {
        text: "В очередь"
        foreground: root.textColor
        tooltipText: "Добавить в конец очереди"
        onClicked: root.queuePendingTrack(false)
      }

      Button {
        text: "Следующим"
        foreground: root.textColor
        tooltipText: "Поставить сразу после текущего трека"
        onClicked: root.queuePendingTrack(true)
      }

      Button {
        iconText: "󰅖"
        foreground: root.textColor
        tooltipText: "Отмена"
        onClicked: root.closeRowMenu()
      }
    }
  }

  // One line of key hints under the list, above the loading line, which stays the
  // bottom edge of the card.
  component HintRow: Text {
    Layout.fillWidth: true
    textFormat: Text.PlainText
    elide: Text.ElideRight
    color: root.dim
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    text: root.keyHints
    visible: root.signedIn
  }

  component TrackList: Flickable {
    id: view

    // The keyboard cursor scrolls the selected row into view, and a component
    // cannot see the ids of the file around it: the delegates are handed out here.
    property alias queueRepeater: queueRepeater
    property alias stationRepeater: stationRepeater
    property alias browseTrackRepeater: browseTrackRepeater
    property alias suggestionRepeater: suggestionRepeater
    property alias resultRepeater: resultRepeater
    property alias historyRepeater: historyRepeater
    property alias browseGrid: browseGrid
    property alias browsePlaylistRows: browsePlaylistRows
    property alias searchGrid: searchGrid
    property alias searchPlaylistRows: searchPlaylistRows

    Layout.fillWidth: true
    Layout.fillHeight: true
    visible: root.signedIn
    clip: true
    contentWidth: width
    contentHeight: listColumn.implicitHeight
    boundsBehavior: Flickable.StopAtBounds

    Column {
      id: listColumn
      width: view.width
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
          // The queue is numbered by absolute position, so the header carries the
          // count and the remaining time: «Дальше в очереди · 96 треков · 5 ч 58 мин».
          text: {
            var summary = root.listSummary(root.upcoming, "трек", "трека", "треков")
            return summary === "" ? "Дальше в очереди" : "Дальше в очереди · " + summary
          }
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
            onRightClicked: root.openRowMenu(modelData)
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

            Button {
              text: "Друзья"
              foreground: root.textColor
              selected: root.browseSlug === "friends" || root.browseSlug === "person"
              tooltipText: "Плейлисты друзей и любого человека по ссылке"
              onClicked: root.browseFriends()
            }
          }
        }

        PlaylistGrid {
          id: browseGrid
          items: root.browsePlaylists
          visible: root.gridView && items.length > 0
          onPicked: function(index) { root.playPlaylist(root.browsePlaylists[index]) }
        }

        PlaylistRows {
          id: browsePlaylistRows
          items: root.gridView ? [] : root.browsePlaylists
          onPicked: function(index) { root.playPlaylist(root.browsePlaylists[index]) }
        }

        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.browseHeader !== "" || root.person !== null

          Button {
            id: backButton
            visible: root.person !== null
            text: "Назад"
            foreground: root.textColor
            tooltipText: "К списку людей"
            onClicked: {
              root.closePerson()
              root.browseFriends()
            }
          }

          PanelSectionHeader {
            width: parent.width - (backButton.visible ? backButton.width + Style.space(6) : 0) - viewSwitch.width - Style.space(6)
            text: root.browseHeader
            foreground: root.dim
          }

          PlaylistViewSwitch {
            id: viewSwitch
            visible: root.browsePlaylists.length > 0
          }
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

        // Friends: a photo and a name each, plus a field for anyone else. The
        // people opened before are listed too, since VK's bookmarks API is gone.
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.browseSlug === "friends"

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: personField
              width: parent.width - personGo.width - Style.space(6)
              placeholderText: "Ссылка, id или имя друга"
              text: root.personQuery
              onTextChanged: root.personQuery = text
              onAccepted: root.openPersonFromField()
            }

            Button {
              id: personGo
              text: "Открыть"
              foreground: root.textColor
              enabled: root.personQuery.trim() !== ""
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.openPersonFromField()
            }
          }

          PanelSectionHeader {
            text: "Друзья"
            foreground: root.dim
            visible: root.friends.length > 0
          }

          Repeater {
            id: friendRepeater
            model: root.friends
            delegate: Button {
              width: listColumn.width
              leftAlign: true
              selected: index === root.cursor
              text: modelData ? String(modelData.name || "") : ""
              foreground: root.textColor
              onClicked: if (modelData) root.openPerson(String(modelData.id))
            }
          }

          PanelSectionHeader {
            text: "Недавние"
            foreground: root.dim
            visible: root.people.length > 0
          }

          Repeater {
            id: recentPeopleRepeater
            model: root.people
            delegate: Button {
              width: listColumn.width
              leftAlign: true
              text: modelData ? String(modelData.name || "") : ""
              foreground: root.textColor
              onClicked: if (modelData) root.openPerson(String(modelData.id))
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            visible: !root.friendsLoading && root.friends.length === 0 && root.people.length === 0
            text: "Список друзей пуст. Вставь ссылку на человека — например vk.com/id213706100."
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }
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
            text: modelData
              ? ((root.isPlayingTrack(modelData.key) ? "▶  " : "")
                 + modelData.artist + " — " + modelData.title)
              : ""
            foreground: modelData && root.isPlayingTrack(modelData.key) ? Color.accent : root.textColor
            onClicked: if (modelData) {
              if (root.browseSlug === "radiostations") root.playStation(modelData)
              else root.playBrowseTrack(index)
            }
            onRightClicked: if (root.browseSlug !== "radiostations") root.openRowMenu(modelData)
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

        // One box, two kinds of answer.
        Row {
          width: parent.width
          spacing: Style.space(4)
          visible: root.signedIn

          Button {
            text: "Треки"
            foreground: root.textColor
            selected: root.searchMode === "tracks"
            onClicked: root.setSearchMode("tracks")
          }

          Button {
            text: "Плейлисты"
            foreground: root.textColor
            selected: root.searchMode === "playlists"
            tooltipText: "Искать плейлисты других людей"
            onClicked: root.setSearchMode("playlists")
          }

          PlaylistViewSwitch { visible: root.searchMode === "playlists" }
        }

        Text {
          visible: root._queryLength < 2 && root.history.length === 0
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: "Начни печатать — подсказки ВК появятся сами, поиск пойдёт после паузы"
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        // What was searched before, offered back while the field is empty.
        PanelSectionHeader {
          text: "Недавние запросы"
          foreground: root.dim
          visible: root._queryLength < 2 && root.history.length > 0
        }

        Repeater {
          id: historyRepeater
          model: root._queryLength < 2 ? root.history : []
          delegate: Button {
            width: listColumn.width
            leftAlign: true
            selected: index === root.cursor
            text: modelData ? String(modelData) : ""
            foreground: root.textColor
            onClicked: if (modelData) root.searchSuggestion(String(modelData))
          }
        }

        PanelSectionHeader {
          text: root.searchHeader
          foreground: root.dim
          visible: root.searchHeaderVisible
        }

        PlaylistGrid {
          id: searchGrid
          items: root.searchMode === "playlists" ? root.foundPlaylists : []
          visible: root.gridView && items.length > 0
          onPicked: function(index) { root.playPlaylist(root.foundPlaylists[index]) }
        }

        PlaylistRows {
          id: searchPlaylistRows
          items: (root.searchMode === "playlists" && !root.gridView) ? root.foundPlaylists : []
          onPicked: function(index) { root.playPlaylist(root.foundPlaylists[index]) }
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
            text: modelData
              ? ((root.isPlayingTrack(modelData.key) ? "▶  " : "")
                 + modelData.artist + " — " + modelData.title)
              : ""
            foreground: modelData && root.isPlayingTrack(modelData.key) ? Color.accent : root.textColor
            onClicked: root.playSearchResult(index)
            onRightClicked: root.openRowMenu(modelData)
          }
        }
      }

      // Settings. Everything here is a backend preference: the widget only
      // sends the new value and re-reads the status, so the daemon stays the
      // one place that knows how the plugin behaves.
      Column {
        width: parent.width
        spacing: Style.spacing.controlGap
        visible: root.view === "settings"

        PanelSectionHeader { text: "Строка в баре"; foreground: root.dim }

        ToggleRow { label: "Обложка трека"; key: "showArtwork"; on: root.prefs.showArtwork !== false }
        ToggleRow { label: "Название трека"; key: "showTitle"; on: root.prefs.showTitle !== false }
        ToggleRow { label: "Исполнитель"; key: "showArtist"; on: root.prefs.showArtist !== false }
        ToggleRow { label: "Кнопки управления"; key: "showControls"; on: root.prefs.showControls !== false }
        ToggleRow { label: "Линия прогресса"; key: "showProgress"; on: root.prefs.showProgress !== false }
        ToggleRow { label: "Время трека"; key: "showTime"; on: root.prefs.showTime === true }
        ToggleRow { label: "Кнопка «Нравится»"; key: "showLike"; on: root.prefs.showLike === true }

        ChoiceRow {
          label: "Форма обложки"
          key: "coverShape"
          value: String(root.prefs.coverShape || "rounded")
          options: [
            { value: "square", label: "Квадрат" },
            { value: "rounded", label: "Скруглённая" },
            { value: "circle", label: "Круг" }
          ]
        }

        ChoiceRow {
          label: "Длинные названия"
          key: "longTitleMode"
          value: String(root.prefs.longTitleMode || "scroll")
          options: [
            { value: "truncate", label: "Обрезать" },
            { value: "scroll", label: "Прокрутка" }
          ]
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          // Both matter only while the label scrolls.
          opacity: root.barLongTitle === "scroll" ? 1.0 : 0.4

          Text {
            text: "Пауза перед прокруткой"
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            id: pauseRow
            width: parent.width
            spacing: Style.space(8)

            PanelSlider {
              width: parent.width - pauseLabel.width - Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              minimum: 0
              maximum: 4000
              step: 200
              integer: true
              enabled: root.barLongTitle === "scroll"
              value: root.marqueePause
              bar: root.bar
              onReleased: function(value) { root.setPreference("marqueePauseMs", Math.round(value)) }
            }

            Text {
              id: pauseLabel
              width: 62
              text: root.marqueePause + " мс"
              horizontalAlignment: Text.AlignRight
              anchors.verticalCenter: parent.verticalCenter
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          opacity: root.barLongTitle === "scroll" ? 1.0 : 0.4

          Text {
            text: "Скорость прокрутки"
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            id: speedRow
            width: parent.width
            spacing: Style.space(8)

            PanelSlider {
              width: parent.width - speedLabel.width - Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              minimum: 10
              maximum: 300
              step: 10
              integer: true
              enabled: root.barLongTitle === "scroll"
              value: root.marqueeSpeed
              bar: root.bar
              onReleased: function(value) { root.setPreference("marqueeSpeed", Math.round(value)) }
            }

            Text {
              id: speedLabel
              width: 62
              text: root.marqueeSpeed + " px/с"
              horizontalAlignment: Text.AlignRight
              anchors.verticalCenter: parent.verticalCenter
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            text: "Ширина подписи"
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Row {
            spacing: Style.space(6)

            Repeater {
              model: [
                { value: 120, label: "Узкая" },
                { value: 180, label: "Обычная" },
                { value: 260, label: "Широкая" }
              ]
              delegate: Button {
                text: modelData ? String(modelData.label) : ""
                foreground: root.textColor
                selected: (Number(root.prefs.labelWidth) || 180) === (modelData ? modelData.value : -1)
                onClicked: if (modelData) root.setPreference("labelWidth", modelData.value)
              }
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            PanelSlider {
              width: parent.width - widthLabel.width - Style.space(8)
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
              id: widthLabel
              width: 46
              text: (Number(root.prefs.labelWidth) || 180) + " px"
              horizontalAlignment: Text.AlignRight
              anchors.verticalCenter: parent.verticalCenter
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.textColor }

        PanelSectionHeader { text: "Попап"; foreground: root.dim }

        ChoiceRow {
          label: "Вид попапа"
          key: "popupView"
          value: String(root.prefs.popupView || "compact")
          options: [
            { value: "compact", label: "Компактный" },
            { value: "extended", label: "Расширенный" }
          ]
        }

        PanelSeparator { width: parent.width; foreground: root.textColor }

        PanelSectionHeader { text: "Воспроизведение"; foreground: root.dim }

        ToggleRow {
          label: "Скачивать следующий трек заранее — переключение без паузы"
          key: "prefetchEnabled"
          on: root.prefs.prefetchEnabled !== false && root.prefs.cacheEnabled !== false
          dim: root.prefs.cacheEnabled === false
        }

        Text {
          text: "Возвращать при запуске"
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.space(6)

          ChipToggle { text: "Очередь"; key: "restoreQueue"; on: root.prefs.restoreQueue !== false }
          ChipToggle { text: "Позицию"; key: "restorePosition"; on: root.prefs.restorePosition !== false }
          ChipToggle { text: "Громкость"; key: "restoreVolume"; on: root.prefs.restoreVolume !== false }
        }

        PanelSeparator { width: parent.width; foreground: root.textColor }

        PanelSectionHeader { text: "Уведомления"; foreground: root.dim }

        ChoiceRow {
          label: "Уведомлять о смене трека"
          key: "notifications"
          value: String(root.prefs.notifications || "off")
          options: [
            { value: "off", label: "Нет" },
            { value: "all", label: "Показывать" }
          ]
        }

        PanelSeparator { width: parent.width; foreground: root.textColor }

        PanelSectionHeader { text: "Кеш"; foreground: root.dim }

        ToggleRow {
          label: "Хранить треки на диске · "
            + root.megabytes(root.status.cache ? root.status.cache.bytes : 0)
            + " из " + root.megabytes(root.status.cache ? root.status.cache.limit_bytes : 0)
            + (root.status.cache && root.status.cache.files ? " · файлов " + root.status.cache.files : "")
          key: "cacheEnabled"
          on: root.prefs.cacheEnabled !== false
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
      }

    }
  }

  component HeaderRow: RowLayout {
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

  component SignInBlock: ColumnLayout {
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

  component PlayerColumn: ColumnLayout {
    id: playerColumn

    // The extended popup gives the cover twice the room: it is the one thing in
    // the panel that is worth looking at.
    property bool wide: false
    readonly property real coverPixels: wide ? Style.space(128) : Style.space(64)
    spacing: Style.spacing.controlGap

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(10)
    visible: root.signedIn

    BorderSurface {
      Layout.alignment: Qt.AlignTop
      width: playerColumn.coverPixels
      height: playerColumn.coverPixels
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
      // Filled is `mdi-heart`, outline is `mdi-heart-outline`: the filled one
      // means the track is in «Моя музыка».
      iconText: root.liked ? "󰋑" : "󰋕"
      foreground: root.liked ? Color.urgent : root.textColor
      enabled: root.hasTrack
      opacity: enabled ? 1.0 : 0.4
      tooltipText: root.liked ? "Убрать из моей музыки" : "В мою музыку"
      onClicked: root.toggleLike()
    }

    Button {
      iconText: "󰒟"
      foreground: root.shuffled ? Color.accent : root.textColor
      tooltipText: root.shuffled ? "Перемешивание включено" : "Перемешать"
      onClicked: root.toggleShuffle()
    }

    Button {
      iconText: root.repeatGlyph
      foreground: root.repeatMode === "off" ? root.textColor : Color.accent
      tooltipText: root.repeatMode === "off" ? "Повтор выключен"
        : (root.repeatMode === "one" ? "Повторять трек" : "Повторять очередь")
      onClicked: root.cycleRepeat()
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

    // The queue actions get a row of their own, and only the extended popup has
    // the room for it: everything else lives in the transport row.
    RowLayout {
      Layout.fillWidth: true
      visible: playerColumn.wide
      spacing: Style.space(6)

      Item { Layout.fillWidth: true }

      Button {
        text: "Убрать"
        foreground: root.textColor
        enabled: root.hasTrack
        opacity: enabled ? 1.0 : 0.4
        tooltipText: "Убрать текущий трек из очереди"
        onClicked: root.removeCurrentTrack()
      }

      Button {
        text: "Очистить"
        foreground: root.textColor
        enabled: root.queue.length > 0
        opacity: enabled ? 1.0 : 0.4
        tooltipText: "Очистить очередь"
        onClicked: root.clearQueue()
      }
    }

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
  }

  component TabsRow: RowLayout {
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

  component SearchFieldRow: RowLayout {
    id: fieldRow

    // The key catcher and the tab buttons need the field itself: two of these
    // exist (one per popup shape) and only the visible one collects keys.
    property alias field: searchField

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

  component LoadingLine: Item {
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
    contentWidth: panel.fittedContentWidth(Style.space(root.isExtended() ? 620 : 400))
    // Fixed height, but not one height for everything: a signed-out card holding
    // two lines of text and one button would otherwise be mostly empty space.
    // 690 rather than 460: with the smaller card the queue showed four tracks and
    // had to be scrolled for a fifth, and the settings page was barely usable.
    contentHeight: panel.fittedContentHeight(
      root.signedIn ? Style.space(root.isExtended() ? 760 : 690) : Style.space(200))

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
        if (root.activeField().activeFocus) {
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
      // Esc backs out one step at a time: the search it can clear, the popup it
      // closes.
      onCloseRequested: {
        if (root.pendingTrack !== null) {
          root.closeRowMenu()
          return
        }
        if (root.view === "search" && root.query.length > 0) {
          root.clearSearch()
          root.activeField().forceActiveFocus()
          return
        }
        root.close()
      }
      onTextKey: function(character) {
        if (root.activeField().activeFocus) return
        if (character === "/") {
          // A search is one keystroke away, as it is in most editors.
          root.view = "search"
          root.activeField().forceActiveFocus()
          return
        }
        if (character === "n") root.skipNext()
        else if (character === "p") root.skipPrevious()
      }

      // Compact: the player above the list, one column, the size it has always
      // been.
      ColumnLayout {
        id: compactBody
        anchors.fill: parent
        visible: !root.isExtended()
        spacing: Style.spacing.controlGap

        HeaderRow { Layout.fillWidth: true }
        PanelSeparator { Layout.fillWidth: true; foreground: root.textColor; visible: root.signedIn }
        SignInBlock { Layout.fillWidth: true }
        PlayerColumn { Layout.fillWidth: true; wide: false }
        PanelSeparator { Layout.fillWidth: true; foreground: root.textColor; visible: root.signedIn }
        TabsRow { Layout.fillWidth: true }
        SearchFieldRow { id: compactFieldRow; Layout.fillWidth: true }
        TrackList { id: compactList }
        HintRow { Layout.fillWidth: true }
        LoadingLine { Layout.fillWidth: true; Layout.preferredHeight: Math.max(2, Style.space(2)) }
      }

      // Extended: the player on the left, the list on the right. Two columns need
      // the wider card the panel is told to open with.
      ColumnLayout {
        id: extendedBody
        anchors.fill: parent
        visible: root.isExtended()
        spacing: Style.spacing.controlGap

        HeaderRow { Layout.fillWidth: true }
        PanelSeparator { Layout.fillWidth: true; foreground: root.textColor; visible: root.signedIn }
        SignInBlock { Layout.fillWidth: true }

        RowLayout {
          Layout.fillWidth: true
          Layout.fillHeight: true
          spacing: Style.space(14)

          PlayerColumn {
            wide: true
            Layout.fillWidth: true
            Layout.preferredWidth: Style.space(240)
            Layout.alignment: Qt.AlignTop
          }

          ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Style.spacing.controlGap

            TabsRow { Layout.fillWidth: true }
            SearchFieldRow { id: extendedFieldRow; Layout.fillWidth: true }
            TrackList { id: extendedList }
          }
        }

        HintRow { Layout.fillWidth: true }
        LoadingLine { Layout.fillWidth: true; Layout.preferredHeight: Math.max(2, Style.space(2)) }
      }

      // Last inside the key catcher, so it floats over whichever body is showing.
      RowMenu { }
    }
  }
}
