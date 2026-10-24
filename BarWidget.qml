// VK Music in the bar: artwork, title, transport, and a popup with the queue.
//
// The widget owns no VK knowledge at all. Every action and every piece of state
// goes through `bin/omarchy-vk-music`, which forwards one JSON command to the
// user service over a Unix socket and prints one JSON answer. That keeps the QML
// free of tokens, HLS, pacing and cache logic, and lets the same commands be
// driven from a terminal while debugging.
import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "LucideIcons.js" as Lucide
import "i18n.js" as I18n
import "CoverTint.js" as CoverTint
import "GalleryFit.js" as GalleryFit

Panel {
  id: root

  moduleName: "vyorkin.vk-music"
  ipcTarget: "vyorkin.vk-music"

  // ------------------------------------------------------------- state ---
  // The interface language: a backend preference, English by default, read through a
  // function so a switch in the settings takes effect without a reload.
  readonly property string language: String(root.setting("language", root.prefs.language || "en"))

  function t(text) {
    return I18n.translate(root.language, text)
  }

  // The daemon answers in prose, in Russian, because that is what its own CLI and the
  // journal show. The panel translates it by looking the sentence up as a key, and the
  // two sentences the daemon builds around a value are recognised by their shape.
  function tm(message) {
    var text = String(message || "")
    if (text === "") return ""
    var known = root.t(text)
    if (known !== text) return known
    var person = text.match(/^человек не найден: (.*)$/)
    if (person) return root.t("Человек не найден")
    var skipped = text.match(/^Пропущен трек «(.*)»: (.*)$/)
    if (skipped) return root.t("Пропущен трек") + " «" + skipped[1] + "»: " + root.tm(skipped[2])
    return text
  }

  // The halt reason is prose from the daemon as well.
  readonly property string haltText: root.tm(String(root.status.halted || ""))

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
  // showed root.t("Пусто") and root.t("Очередь пуста") while the answer was still on its way.
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
  // The accounts the daemon holds, the form that adds another one, and the
  // removal that is waiting for a second click. None of this is a preference:
  // it is loaded from the daemon with the `accounts` command.
  property var accounts: []
  property bool accountFormOpen: false
  property bool accountBusy: false
  property string accountLogin: ""
  property string accountPassword: ""
  property string accountStep: ""
  property string accountCode: ""
  property string accountValidationType: ""
  property string accountPhoneMask: ""
  property string accountRedirectUri: ""
  property string accountSuccessToken: ""
  // What the account form says about the last attempt: a success stays in the
  // settings block after the form closes, a failure stays next to the fields.
  property string accountNotice: ""
  property string accountError: ""
  // How many of the form's fields hold the keyboard. While one does, the key
  // catcher must not read «j» as a step down the list.
  property int accountFieldFocus: 0
  property string pendingAccountRemove: ""

  // The line under the artist in the player: the record, or the position when the
  // track has no record. A live stream says it is one instead.
  function captionLine() {
    if (root.onAir()) return root.t("Радио · в эфире")
    if (!root.hasTrack) return ""
    var album = String(root.trackValue("album", ""))
    if (album !== "") return album
    if (!(root.duration > 0)) return ""
    return root.clock(root.displayPosition) + " / " + root.clock(root.duration)
  }

  // Shuffle, repeat and the volume slider live behind the player's menu button, so
  // whether they are showing is a state of the panel. It closes with the panel: a
  // row that is open under a card that was just reopened is a surprise.
  property bool playerControlsOpen: false

  onViewChanged: {
    root.cursor = -1
    if (root.view === "settings") root.loadAccounts()
  }
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
      if (root.playlistSearchLoading) return root.t("Ищу…")
      var found = root.foundPlaylists.length
      if (found === 0) return root.t("Плейлисты не найдены")
      return root.t("Найдено ") + found + " " + root.plural(found, root.t("плейлист"), root.t("плейлиста"), root.t("плейлистов"))
    }
    if (root.searchState === "searching") return root.t("Ищу…")
    if (!root.resultsShowing) return root.t("Подсказки")
    if (root.results.length === 0) {
      return root.suggestionsShown.length > 0 ? root.t("Ничего не найдено. Похожее:") : root.t("Ничего не найдено")
    }
    var span = root.tracksSpan(root.results)
    return root.t("Найдено ") + root.results.length + (span === "" ? "" : " · " + span)
  }
  // The popup answers to five keys and nothing on screen says so. Esc is the one
  // that means two things, so the hint follows the query.
  readonly property string keyHints: {
    if (root.activeField().activeFocus) return root.t("Enter искать · Tab к списку · Esc выйти из поля")
    return root.t("Space пауза · jk выбор · Enter играть · / фильтр · m вид · [ ] вкладки · ⇧H ⇧L раздел · Esc закрыть")
  }
  // Whether the key sheet is up. The line of tiny print that used to sit under the list is
  // gone: two captions of four-point type that nobody read, and the keys it could not fit
  // were the ones a beginner needs most. A question mark in the corner opens the sheet.
  property bool hintsOpen: false

  // The sheet's rows, out of the hint line itself: it is translated as one string with «·»
  // between the keys, and the sheet is a list of the same phrases, one per row. A phrase
  // whose first words are keys — latin, short, and never the last word — is drawn as a key
  // cap with its description beside it; anything else stands as one line, which is what a
  // pair like «[ ] вкладки» needs.
  readonly property var keyHelpRows: {
    var parts = String(root.keyHints).split("·")
    var rows = []
    for (var i = 0; i < parts.length; i++) {
      var tokens = String(parts[i]).trim().split(/\s+/)
      var keys = []
      while (tokens.length > 1 && keys.length < 2
             && tokens[0].length <= 10 && !/[\u0400-\u04FF]/.test(tokens[0])) {
        keys.push(tokens.shift())
      }
      rows.push({ keys: keys.join(" "), what: tokens.join(" ") })
    }
    return rows
  }

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
    if (hours > 0) return hours + root.t("ч ") + minutes + root.t("мин")
    return minutes + root.t("мин")
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
  // The card's own inset, in one place. The card is given no padding of its own and
  // everything is placed inside this: a bar or a row that is meant to reach the card's
  // edge needs an ancestor that reaches it too, and an item that hangs outside its parent
  // — which is what the padding of the panel and a negative margin amount to — is an item
  // the pointer can miss on the part that hangs out.
  readonly property real cardInset: Style.spacing.popupPadding
  // What is left of the card's rounding inside its own border. The two cells at the ends
  // of the bar follow it: a square fill there paints over the card's corner, and in the
  // settings view — where the first cell is the filled one — that shows.
  readonly property real cardCorner: Math.max(0, Style.cornerRadius - Style.space(2))
  // The height of a bar of cells: one line of text plus the control padding on each side.
  // Stated once and read by both bars — the one at the top of the card and the one over
  // the list — because a cell that measured its own glyph leaves the fill of the one in
  // use a pixel off its neighbours, and in a band of flush cells that shows. `barProbe`
  // is the invisible Text at the bottom of this file that measures it.
  readonly property real barCellHeight: Math.ceil(barProbe.implicitHeight)
    + 2 * Style.spacing.controlPaddingY
  // The bar at the top of the card is a fifth taller than the others, because it is the
  // first thing the eye lands on and the one a hand reaches for without looking. The bar
  // of status under the list is drawn to the same height: the two close the card, and two
  // bars that frame a card should be the same bar.
  readonly property real topBarHeight: Math.round(barCellHeight * 1.2)

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
    // Every kind of load the panel can have in flight: one of them left behind is
    // the difference between an honest line and one that never stops.
    return root.browseLoading || root.browseMoreLoading || root.searchLoading
      || root.queueLoading || root.playlistSearchLoading || root.personLoading
      || root.friendsLoading || root.openPlaylistLoading
  }

  // A reply that arrives after the pane has moved on must not paint stale rows —
  // but it must still clear the flag it set. Forgetting the second half is what
  // left the loading line running under the settings page forever.
  property int _browseSeq: 0

  function clearBrowseLoading() {
    root.browseLoading = false
    root.browseMoreLoading = false
    root.openPlaylistLoading = false
    root.personLoading = false
    root.friendsLoading = false
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
    if (root.halted !== "") return root.haltText
    if (root.notice !== "") return root.notice
    if (!root.signedIn) return root.t("нет входа")
    // Buffering is not text: the ring around the cover says it, in place, and
    // without a word that would appear and vanish three times a second.
    if (!root.hasTrack) return root.t("готов")
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

  // The queue starts AT the current track, not after it: a list that hides the row you
  // are listening to cannot show that it is playing, and the playing row is the one place
  // the pill and the play glyph exist to be seen.
  readonly property int upcomingStart:
    Math.max(0, Number(status.index === undefined ? -1 : status.index))

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
      labelSize: Style.font.bodySmall,
      // A bar widget of zero width is invisible and cannot be clicked; the idle
      // note is the fallback that keeps a stopped, option-less row reachable.
      empty: root.barRowEmpty,
      idle: [idleGlyph.visible, idleGlyph.width, idleGlyph.height],
      shown: [root.barShowArtwork, root.barShowTitle, root.barShowArtist,
              root.barShowTime, root.barShowControls]
    }))
  }

  // The poll is the only thing that makes «playing» mean anything outside a button press:
  // the bar's glyph, its time and the seek slider all come from it. Fast while a track is
  // being fetched or a change is being watched, one second while it plays, slow when idle.
  Timer {
    id: pollTimer
    interval: root.buffering || root._watching ? 250 : (root.playing ? 1000 : 5000)
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // A change is watched closely for a moment; after that the poll goes back to its rhythm.
  Timer {
    id: watchTimer
    interval: 5000
    repeat: false
    onTriggered: root._watching = false
  }

  Component.onCompleted: {
    refresh()
    reportBarLayout()
    loadAccounts()
  }

  // ----------------------------------------------------------------- io ---

  // One fresh Process per command: a reused object can miss its exit event and
  // then keep reporting "running", which would wedge every later action.
  //
  // The answer is parsed in the collector's own `onStreamFinished`, because
  // `text` is a property of the collector and not of the Process. Reading it
  // from `onExited` yields undefined, which is how every command silently
  // became root.t("команда не выполнена") while the service was in fact working.
  Component {
    id: commandComponent
    Process {
      id: commandProcess
      property var onDone
      // A command nobody asked for — the status poll — must not put «…» on the status
      // line: it runs once a second while a track plays, and the line blinked with it.
      property bool quiet: false
      stderr: StdioCollector { id: commandError; waitForEnd: true }
      stdout: StdioCollector {
        id: commandOutput
        waitForEnd: true
        onStreamFinished: root.finishCommand(text, commandError.text, commandProcess.onDone,
          commandProcess.quiet)
      }
      onExited: function(code) { destroy() }
    }
  }

  // The password login needs a request body. It travels over stdin — `request`
  // reads one JSON line and forwards it — so a password never appears in the
  // process list the way an argument would.
  Component {
    id: requestComponent
    Process {
      id: requestProcess
      property var onDone
      property string payload: ""
      stdinEnabled: true
      stderr: StdioCollector { id: requestError; waitForEnd: true }
      stdout: StdioCollector {
        id: requestOutput
        waitForEnd: true
        onStreamFinished: root.finishCommand(text, requestError.text, requestProcess.onDone)
      }
      onStarted: {
        write(payload)
        // Closing stdin is what lets the reader finish; `cat` waits for EOF.
        stdinEnabled = false
      }
      onExited: function(code) { destroy() }
    }
  }

  // One parser for both channels: a reply is a reply no matter which process
  // carried it, and an error must paint the same line either way.
  function finishCommand(rawText, errorText, onDone, quiet) {
    var raw = String(rawText || "").trim()
    var answer = null
    try {
      answer = raw === "" ? null : JSON.parse(raw)
    } catch (parseError) {
      answer = null
    }
    if (quiet !== true) root.busy = ""
    if (answer && answer.ok) {
      root.errorText = ""
    } else if (answer && answer.error) {
      root.errorText = root.tm(String(answer.error.message || answer.error.code || ""))
      if (root.errorText === "") root.errorText = root.t("ошибка")
    } else if (raw !== "") {
      root.errorText = raw
    } else {
      root.errorText = String(errorText || "").trim() || root.t("команда не выполнена")
    }
    if (onDone) onDone(answer)
  }

  function call(args, onDone, quiet) {
    var process = commandComponent.createObject(root, {
      command: args,
      onDone: onDone,
      quiet: quiet === true
    })
    if (!process) return
    if (quiet !== true) root.busy = args.join(" ")
    process.running = true
  }

  function callRequest(request, onDone) {
    var process = requestComponent.createObject(root, {
      command: [root.cli, "request"],
      payload: JSON.stringify(request),
      onDone: onDone
    })
    if (!process) return
    root.busy = String(request.command || "request")
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

  // Likes made from a row: the same list holds its own copy of the track, so the
  // panel keeps an epoch that every heart depends on and bumps it after a change.
  property int likeEpoch: 0

  function isLiked(track) {
    root.likeEpoch
    return track ? track.is_liked === true : false
  }

  function markLiked(key, liked) {
    function mark(list) {
      for (var i = 0; i < (list ? list.length : 0); i++) {
        if (list[i] && String(list[i].key) === key) list[i].is_liked = liked
      }
    }
    mark(root.queue)
    mark(root.browseTracks)
    mark(root.openPlaylistTracks)
    mark(root.results)
    root.likeEpoch = root.likeEpoch + 1
  }

  function toggleLikeFor(track) {
    if (!track || String(track.key || "") === "") return
    var key = String(track.key)
    var liked = root.isLiked(track)
    root.call([root.cli, liked ? "unlike" : "like", key], function(answer) {
      if (!answer || !answer.ok || !answer.data) return
      root.markLiked(key, answer.data.liked === true)
      if (answer.data.status) root.status = answer.data.status
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
    // Quiet: the poll is the widget breathing, not a command the reader gave it.
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
    }, true)
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
  // «/» filters the list in front of you rather than searching VK: vim's search
  // inside the open buffer. It applies to whatever the panel is showing, and it is
  // only a view of the same data, so clearing it costs nothing.
  property bool filtering: false
  property string filter: ""
  // The filter field lives inside the list component, where the root cannot reach
  // it: it takes the keyboard itself and reports back, which is also what the key
  // catcher needs to know before it decides who owns the keys.
  property bool filterFocused: false

  function startFilter() {
    root.filtering = true
  }

  function clearFilter() {
    root.cursor = -1
    root.filter = ""
    root.filtering = false
    root.filterFocused = false
    root.focusList()
  }

  function filterActive() {
    return root.filter.trim() !== ""
  }

  function matchesFilter(item) {
    if (!root.filterActive()) return true
    if (!item) return false
    var haystack = String(item.title || "") + " " + String(item.artist || "")
      + " " + String(item.name || "")
    return haystack.toLowerCase().indexOf(root.filter.trim().toLowerCase()) >= 0
  }

  // With a filter on, a row's position in the list on screen is not its position in
  // the queue or the playlist: everything that acts on a row acts on the item.
  function indexOfItem(list, item) {
    if (!list || !item) return -1
    for (var i = 0; i < list.length; i++) {
      if (list[i] === item) return i
    }
    // A row can hold a copy rather than the very object, and identity then fails while
    // the track is the same one. The key is what identifies a track, so it is the
    // fallback — and a wrong index plays the wrong song, which is worse than any lookup.
    for (var j = 0; j < list.length; j++) {
      if (list[j] && item.key && String(list[j].key) === String(item.key)) return j
    }
    return -1
  }

  function filtered(items) {
    if (!root.filterActive() || !items) return items
    var out = []
    for (var i = 0; i < items.length; i++) {
      if (root.matchesFilter(items[i])) out.push(items[i])
    }
    return out
  }

  // A playlist that was opened rather than started: what it holds, and where to
  // come back to.
  property var openPlaylist: null
  property var openPlaylistTracks: []
  property bool openPlaylistLoading: false
  property string playlistBack: ""
  // Where the playlist was opened from. A playlist opened from a search must come
  // back to that search, with the query still in the field.
  property string playlistBackView: ""
  property var foundPlaylists: []
  property int foundPlaylistsTotal: 0
  property bool playlistSearchLoading: false
  // «Треки» or «Плейлисты»: one search box, two kinds of answer.
  property string searchMode: "tracks"

  // Right-clicking a row offers what can be done with a track without throwing
  // away the queue you are listening to.
  property var pendingTrack: null
  property int pendingIndex: -1

  function openRowMenu(track, queueIndex) {
    if (!track || !track.key) return
    root.pendingTrack = track
    root.pendingIndex = queueIndex === undefined ? -1 : Number(queueIndex)
  }

  function closeRowMenu() {
    root.pendingTrack = null
    root.pendingIndex = -1
  }

  // A queue row can be played now or dropped; anything else can be queued.
  function jumpPending() {
    var index = root.pendingIndex
    root.closeRowMenu()
    if (index < 0) return
    root.call([root.cli, "jump", String(index)], function() { root.watchForTrack() })
  }

  function removePending() {
    var index = root.pendingIndex
    root.closeRowMenu()
    if (index < 0) return
    root.call([root.cli, "queue", "remove", String(index)], function() { root.refresh() })
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

  function focusList() {
    keys.forceActiveFocus()
  }

  // A filter belongs to the list it was typed in. Carrying it into a list the user did
  // not type it in hides rows they have every reason to expect: filtering a section
  // and then opening a playlist showed an empty playlist.
  function clearFilterQuiet() {
    root.filter = ""
    root.filtering = false
    root.filterFocused = false
  }

  // «[» and «]» walk the tabs, «⇧H» and «⇧L» walk the sources of the section view:
  // one pair for what is being looked at, one for where it comes from. The key catcher
  // turns h and l into cursor moves, but a shifted letter is not «h», so these arrive
  // as plain text keys and cannot be confused with navigation.
  // Running through the tabs must not fire a request per tab: the load waits until the
  // panel has settled on the section view for a moment. Short enough that stopping on
  // the tab feels instant, long enough that a burst of keypresses costs one request.
  property string _pendingBrowse: ""

  function scheduleBrowse(slug) {
    if (slug === "") return
    root._pendingBrowse = slug
    browseDelay.restart()
  }

  Timer {
    id: browseDelay
    // Long enough that passing through a tab never starts a request — a person pressing
    // the key again does it in 250-450 ms, so a shorter window let the load begin
    // between two presses and spend traffic on a tab that was already left. Short
    // enough that stopping on the tab still feels immediate, especially since the load
    // itself takes a couple of seconds.
    interval: 600
    repeat: false
    onTriggered: {
      var slug = root._pendingBrowse
      root._pendingBrowse = ""
      // The view may have moved on while the timer ran: a request for a list nobody is
      // looking at is exactly the traffic this exists to avoid.
      if (slug === "" || root.view !== "browse") return
      if (slug === "friends") root.browseFriends()
      else root.browseSource(slug)
    }
  }

  // A representation switch only means something where there is something with two
  // representations. «Моя музыка» is a hundred tracks and not a single playlist, so the
  // gallery has nothing to show there and both the switch and its keys must be silent.
  readonly property bool playlistsShown: {
    if (root.openPlaylist !== null) return false
    if (root.view === "browse") {
      if (root.browseSlug === "radiostations") return false
      // «Моя музыка» is the one section that is a hundred tracks and never a playlist, so
      // the switch has nothing to say there and says it without waiting for an answer.
      if (root.browseSlug === "all") return false
      // People are drawn as cards or as rows as well, so the switch means the same
      // thing on the friends page and on a person's page as it does for playlists.
      if (root.browseSlug === "friends" || root.browseSlug === "person") return true
      // A section that is still loading has no playlists to count yet: asked on the rows
      // alone, the two cells vanished for as long as the request took and came back after
      // it, which read as a control that flickers every time a tab is pressed.
      return root.browseLoading || root.filtered(root.browsePlaylists).length > 0
    }
    if (root.view === "search") return root.searchMode === "playlists"
    return false
  }

  // The section the panel is on, counting a scheduled one: the chip lights up the
  // moment the key is pressed, even though the load waits.
  function effectiveBrowse() {
    return root._pendingBrowse !== "" ? root._pendingBrowse : root.browseSlug
  }

  function cycleView(step) {
    var views = ["queue", "browse", "search", "settings"]
    var index = views.indexOf(root.view)
    if (index < 0) index = 0
    var next = views[(index + step + views.length) % views.length]
    root.view = next
    root.cursor = -1
    if (next === "browse" && root.browseSlug === "") root.scheduleBrowse("friends")
    root.focusList()
  }

  function cycleSource(step) {
    // The keys are about the section view, so they take the panel there instead of
    // doing nothing when it is on another tab — a key that silently ignores you reads
    // as a broken key.
    if (root.view !== "browse") {
      root.view = "browse"
      root.cursor = -1
      root.focusList()
    }
    var slugs = ["friends"]
    for (var i = 0; i < root.sources.length; i++) slugs.push(root.sourceSlug(root.sources[i]))
    // Count from what is scheduled, not from what is loaded: the load is delayed by
    // 600 ms, and with the loaded slug a second press would ask for the same section
    // again — which is why the first press looked like it did nothing.
    var current = root._pendingBrowse !== ""
      ? root._pendingBrowse
      : (root.browseSlug === "person" || root.browseSlug === "playlist" ? "friends" : root.browseSlug)
    var index = slugs.indexOf(current)
    if (index < 0) index = 0
    var next = slugs[(index + step + slugs.length) % slugs.length]
    root.scheduleBrowse(next)
  }

  function setSearchMode(mode) {
    root.clearFilterQuiet()
    if (root.searchMode === mode) return
    root.cursor = -1
    root.searchLoading = false
    root.playlistSearchLoading = false
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
    // Whatever view it was opened from, an open playlist is the list on screen.
    if (root.openPlaylist !== null) return root.filtered(root.openPlaylistTracks)
    if (root.view === "queue") return root.filtered(root.upcoming)
    if (root.view === "browse") {
      if (root.browseSlug === "person") return root.filtered(root.personPlaylists)
      if (root.browseSlug === "friends") {
        // Friends and the people opened recently are one list on screen, so the
        // cursor walks both, the same way a section walks its playlists and tracks.
        return root.filtered(root.friends).concat(root.filtered(root.people))
      }
      if (root.browseSlug === "radiostations") return root.stations
      var lists = root.filtered(root.browsePlaylists)
      // The cursor walks what is on screen: one column of playlists and then tracks in
      // the list view, a grid of cards with the same tracks under it in the gallery.
      // Either way it is both, so j carries on from the last card to the first track
      // below and k comes back up to the last card.
      return lists.concat(root.filtered(root.browseTracks))
    }
    if (root.view === "search") {
      if (root.searchMode === "playlists") return root.filtered(root.foundPlaylists)
      if (root.resultsShown.length > 0) return root.filtered(root.resultsShown)
      // With an empty field the list on screen is the recent queries.
      if (root._queryLength < 2 && root.history.length > 0) return root.history
      return root.suggestionsShown
    }
    return []
  }

  function cursorCount() {
    return root.cursorItems().length
  }

  // Where the section's tracks start in the cursor's list: the playlists come first.
  function browseCursorOffset() {
    // Where the section's tracks begin in the cursor's list. The playlists come first
    // in the list view and stand above the tracks in the gallery, so one offset
    // describes both — the cursor walks the cards and then the rows under them.
    if (root.browseSlug !== "" && root.browseSlug !== "person" && root.browseSlug !== "friends") {
      return root.filtered(root.browsePlaylists).length
    }
    return 0
  }

  function moveCursor(step) {
    var count = root.cursorCount()
    if (count === 0) return
    // With nothing picked yet, the first j or k starts where the list is already
    // scrolled, not at the first or the last row of a list that may be a hundred long.
    var next = root.cursor < 0
      ? root.firstVisibleIndex() + (step > 0 ? 0 : -1)
      : root.cursor + step
    // In the gallery a step is a whole row of cards, which must not skip over the
    // tracks underneath them: one step down from the last card is the first track, and
    // one step up from there is the last card. It cannot cross on the way back up from
    // the rows, because the row above the first track is the card it came from.
    if (root.view === "browse" && root.galleryMode && root.cursor >= 0) {
      var edge = root.browseSlug === "friends"
        ? root.filtered(root.friends).length
        : root.filtered(root.browsePlaylists).length
      if (edge > 0 && edge < count) {
        if (root.cursor < edge && next >= edge) next = edge
        else if (root.cursor >= edge && next < edge) next = edge - 1
      }
    }
    root.cursor = Math.max(0, Math.min(count - 1, next))
    root.revealCursor()
    // Again once the layout has settled: the list's height is still changing while
    // the panel opens, and a scroll computed against the old height lands short.
    Qt.callLater(root.revealCursor)
  }

  // The delegate item the cursor sits on, so the list can be scrolled to it: rows
  // are not a fixed height, and arithmetic on an index would drift.
  // The row of the cursor's list at an index. Separate from the cursor so that the
  // panel can also ask about rows the cursor is not on.
  function rowAt(index) {
    if (index < 0) return null
    if (root.openPlaylist !== null) return root.activeList().playlistTrackRepeater.itemAt(index)
    if (root.view === "queue") return root.activeList().queueRepeater.itemAt(index)
    if (root.view === "browse") {
      // Which repeater holds the row depends on where the index falls: with the
      // gallery off a section's column is the playlists and then the tracks, so an
      // index below the offset is a playlist row and one at or above it a track row.
      // Returning a track row for a playlist index made the reveal scroll to the far
      // end of the list and leave the highlighted row above the viewport.
      var offset = root.browseCursorOffset()
      if (root.browseSlug === "person") {
        return root.gridView
          ? root.activeList().browseGrid.itemAt(index)
          : root.activeList().browsePlaylistRows.itemAt(index)
      }
      if (root.browseSlug === "friends") {
        var friends = root.filtered(root.friends).length
        if (index >= friends) {
          var rest = index - friends
          return root.gridView
            ? root.activeList().recentGrid.itemAt(rest)
            : root.activeList().recentPeopleRepeater.itemAt(rest)
        }
        return root.gridView
          ? root.activeList().friendsGrid.itemAt(index)
          : root.activeList().friendRepeater.itemAt(index)
      }
      if (root.browseSlug === "radiostations") {
        return root.activeList().stationRepeater.itemAt(index)
      }
      if (offset > 0 && index >= offset) {
        return root.activeList().browseTrackRepeater.itemAt(index - offset)
      }
      if (offset > 0) {
        return root.gridView
          ? root.activeList().browseGrid.itemAt(index)
          : root.activeList().browsePlaylistRows.itemAt(index)
      }
      return root.activeList().browseTrackRepeater.itemAt(index)
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

  function cursorRow() {
    return root.rowAt(root.cursor)
  }

  // The first row of the cursor's list that is inside the viewport: where the eye
  // already is, and the honest place to start from.
  function firstVisibleIndex() {
    var list = root.activeList()
    var count = root.cursorCount()
    for (var i = 0; i < count; i++) {
      var row = root.rowAt(i)
      if (row && row.mapToItem(list.contentRoot, 0, 0).y + row.height > list.contentY) return i
    }
    return 0
  }

  function revealCursor() {
    var row = root.cursorRow()
    if (!row) return
    var list = root.activeList()
    // A row's own `y` is the y its parent block gave it, not a position in the
    // content: a card sits in a grid, the grid in a column, and the column under the
    // section chips. Mapping the row into the content item is what contentY counts
    // in; using the raw y landed the reveal short by every block above the row, which
    // is why the last card of a gallery kept its caption below the bottom edge.
    var top = row.mapToItem(list.contentRoot, 0, 0).y
    // The mapped position is clamped into the scrollable range: unclamped, the last
    // row of a long list asked for a scroll past the end, the flickable refused it,
    // and the row stayed half under the bottom edge.
    var maxScroll = Math.max(0, list.contentHeight - list.viewHeight)
    if (root.galleryMode) {
      // A gallery puts the cursor's row on the row boundary the viewport ends with,
      // not at the nearest edge of it: the viewport is a whole number of rows tall,
      // and the content above the grid is what those rows start after. Scrolling just
      // far enough instead cut the row above the cursor in half, which is what the
      // gallery kept showing.
      var rowsAbove = root.activeList() ? root.activeList().galleryRowOffset : 0
      list.contentY = Math.max(0, Math.min(maxScroll, top - rowsAbove))
      return
    }
    var margin = Style.space(6)
    var bottom = top + row.height
    var target = list.contentY
    if (top - margin < target) target = top - margin
    else if (bottom + margin > target + list.viewHeight) target = bottom + margin - list.viewHeight
    list.contentY = Math.max(0, Math.min(maxScroll, target))
  }

  // Enter: play what the cursor points at. Returns false when there is nothing
  // to activate, which is when Enter keeps its old meaning.
  function activateCursor() {
    var count = root.cursorCount()
    if (count === 0) return false
    var index = root.cursor < 0 ? 0 : Math.min(root.cursor, count - 1)
    var item = root.cursorItems()[index]
    if (root.openPlaylist !== null) {
      root.playPlaylistTrack(root.indexOfItem(root.openPlaylistTracks, item))
      return true
    }
    if (root.view === "queue") {
      root.playQueueAt(root.indexOfItem(root.queue, item))
    } else if (root.view === "browse") {
      var offset = root.browseCursorOffset()
      if (offset > 0 && index >= offset) {
        root.playBrowseTrack(root.indexOfItem(root.browseTracks, item))
      }
      else if (root.galleryMode && root.browseSlug !== "person" && root.browseSlug !== "friends"
          && root.browseSlug !== "radiostations" && root.browsePlaylists.length > 0) {
        root.openPlaylistView(item)
      }
      else if (root.browseSlug === "person") root.openPlaylistView(root.personPlaylists[index])
      else if (root.browseSlug === "friends") {
        var friendCount = root.filtered(root.friends).length
        var person = index < friendCount
          ? root.filtered(root.friends)[index]
          : root.filtered(root.people)[index - friendCount]
        if (person) root.openPerson(String(person.id))
      }
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
    // Which form to use is the language's business: Russian and Ukrainian count to
    // three forms, English and German to two, Japanese and Chinese to one. The callers
    // pass the Russian three, so a language maps its own groups onto them.
    var forms = [one, few, many]
    return root.t(forms[I18n.pluralIndex(root.language, count)])
  }

  // A playlist with no cover still has to be told apart from its neighbours. The hue
  // is a hash of the title, so the same playlist keeps the same colour on every open,
  // and the tint is mixed into the popup's own surface rather than painted at full
  // strength: quiet in a dark theme, pale in a light one, and never a saturated block
  // that fights the real covers beside it. The hash itself lives in `CoverTint.js`,
  // where the tests can reach it without a shell.
  function coverHue(text) {
    return CoverTint.hue(text)
  }

  function coverTint(text) {
    var tint = Qt.hsla(root.coverHue(text) / 360, 0.55, 0.5, 1)
    return Qt.tint(root.panelBackground, Qt.rgba(tint.r, tint.g, tint.b, 0.24))
  }

  function coverMonogram(text) {
    return CoverTint.monogram(text)
  }

  // What the list is showing, and what it is doing: the header is the one place
  // that says both, so the list itself never has to claim anything false.
  // What the sticky row above the list says, and what its right button does: one
  // place per view instead of one header per list.
  function listHeading() {
    // A playlist that is open owns the heading, whichever view it was opened from.
    if (root.openPlaylist !== null) {
      if (root.openPlaylistLoading) return root.openPlaylistTitle + root.t(" · загрузка…")
      var held = root.openPlaylistTracks.length
      if (held === 0) return root.openPlaylistTitle + root.t(" · пусто")
      var span = root.tracksSpan(root.openPlaylistTracks)
      return root.openPlaylistTitle + " · " + held + " "
        + root.plural(held, root.t("трек"), root.t("трека"), root.t("треков")) + (span === "" ? "" : " · " + span)
    }
    if (root.view === "queue") {
      if (root.queue.length === 0) return ""
      var summary = root.listSummary(root.upcoming, root.t("трек"), root.t("трека"), root.t("треков"))
      return summary === "" ? root.t("Дальше в очереди") : root.t("Дальше в очереди · ") + summary
    }
    var base = ""
    if (root.view === "browse") base = root.browseHeader
    else if (root.view === "search") base = root.searchHeaderVisible ? root.searchHeader : ""
    if (root.filterActive()) {
      return (base === "" ? "" : base + " · ") + root.t("фильтр: ") + root.filter.trim()
    }
    return base
  }

  function listAction() {
    if (root.view === "browse" && root.openPlaylist !== null) return root.t("Играть")
    if (root.view === "queue" && root.queue.length > 0) return root.t("Очистить")
    return ""
  }

  readonly property string browseHeader: {
    if (root.browseSlug === "") return ""
    if (root.browseSlug === "person") {
      if (root.personLoading) return root.t("Открываю…")
      var mine = root.personPlaylists.length
      if (!root.person) return root.t("Человек не найден")
      return String(root.person.name || root.t("Человек"))
        + (mine === 0 ? root.t(" · пусто") : " · " + mine + " " + root.plural(mine, root.t("плейлист"), root.t("плейлиста"), root.t("плейлистов")))
    }
    if (root.browseSlug === "friends") {
      if (root.friendsLoading) return root.t("Друзья · загрузка…")
      var count = root.friends.length
      return root.t("Друзья · ") + count + " " + root.plural(count, root.t("человек"), root.t("человека"), root.t("человек"))
    }
    if (root.browseSlug === "radiostations") {
      if (root.browseLoading) return root.t("Радио · загрузка…")
      var stations = root.stations.length
      return root.t("Радио · ") + (stations === 0
        ? root.t("пусто")
        : stations + " " + root.plural(stations, root.t("станция"), root.t("станции"), root.t("станций")))
    }
    var title = root.browseTitle !== "" ? root.browseTitle : (root.sectionTitle(root.browseSlug) || root.t("Раздел"))
    if (root.browseLoading) return title + root.t(" · загрузка…")
    var tracks = root.browseTracks.length
    var lists = root.browsePlaylists.length
    if (tracks === 0 && lists === 0) return title + root.t(" · пусто")
    if (tracks === 0) {
      return title + " · " + lists + " " + root.plural(lists, root.t("плейлист"), root.t("плейлиста"), root.t("плейлистов"))
    }
    return title + " · " + root.listSummary(root.browseTracks, root.t("трек"), root.t("трека"), root.t("треков"))
  }

  // The sections come as opaque ids with a friendly slug inside the url. The
  // backend accepts either, and the url is what lets the UI label them.
  // The section's own name, known from the section list before its page arrives:
  // root.t("Раздел · загрузка…") tells the user nothing about what is loading.
  // VK's section titles come in Russian: the slugs are stable, so the name shown is
  // translated by slug and VK's own title is only the fallback.
  function sectionName(slug) {
    var known = {
      general: "Главная",
      all: "Моя музыка",
      explore: "Обзор",
      radiostations: "Радио",
      updates: "Обновления"
    }
    var key = known[slug]
    return key ? root.t(key) : ""
  }

  function sectionTitle(slug) {
    var translated = root.sectionName(slug)
    if (translated !== "") return translated
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
    root.clearFilterQuiet()
    if (!slug || root.browseSlug === slug) return
    root.cursor = -1
    root.browseSlug = slug
    root.browseTracks = []
    root.browsePlaylists = []
    root.browseNext = ""
    root.browseTitle = ""
    root.clearBrowseLoading()
    root._browseSeq = root._browseSeq + 1
    var seq = root._browseSeq
    if (slug === "radiostations") {
      if (root.stations.length > 0) return
      root.browseLoading = true
      root.call([root.cli, "radio"], function(answer) {
        root.browseLoading = false
        if (seq !== root._browseSeq) return
        if (answer && answer.ok) root.stations = answer.data || []
      })
      return
    }
    root.browseLoading = true
    root.call([root.cli, "section", slug], function(answer) {
      root.browseLoading = false
      if (seq !== root._browseSeq) return
      if (answer && answer.ok) root.adoptSection(answer.data)
    })
  }

  function adoptSection(page) {
    if (!page) return
    root.browseTitle = root.sectionTitle(root.browseSlug) || String(page.title || "")
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
    root.browseMoreLoading = false
    root._browseSeq = root._browseSeq + 1
    var seqMore = root._browseSeq
    root.browseMoreLoading = true
    root.call([root.cli, "section", slug, cursor], function(answer) {
      if (root.browseSlug !== slug) return
      root.browseMoreLoading = false
      if (seqMore !== root._browseSeq) return
      if (!answer || !answer.ok) return
      var page = answer.data || {}
      root.browseTracks = root.browseTracks.concat(page.tracks || [])
      root.browsePlaylists = root.browsePlaylists.concat(page.playlists || [])
      root.browseNext = String(page.next || "")
    })
  }

  function playBrowseTrack(index) {
    if (!(index >= 0)) return
    // Same rule as a search result: the queue is exactly the list on screen.
    var keys = []
    for (var i = 0; i < root.browseTracks.length; i++) {
      if (root.browseTracks[i] && root.browseTracks[i].key) keys.push(String(root.browseTracks[i].key))
    }
    if (keys.length === 0) return
    var args = [root.cli, "play", "keys"].concat(keys)
    args.push("--index", String(index))
    args.push("--title", root.browseTitle !== "" ? root.browseTitle : root.t("Обзор"))
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

  readonly property string openPlaylistTitle: root.openPlaylist
    ? String(root.openPlaylist.title || root.t("Плейлист"))
    : ""

  // Opening a playlist is not the same as playing it: the tracks are fetched and
  // shown, and the click that plays one of them builds the queue from exactly
  // this list.
  function openPlaylistView(item) {
    root.clearFilterQuiet()
    root.focusList()
    if (!item) return
    var owner = Number(item.owner_id || 0)
    var list = Number(item.playlist_id || 0)
    if (!(owner !== 0 && list > 0)) return
    root.clearBrowseLoading()
    root._browseSeq = root._browseSeq + 1
    var seqList = root._browseSeq
    root.cursor = -1
    root.playlistBackView = root.view
    root.playlistBack = root.browseSlug
    root.openPlaylist = item
    root.openPlaylistTracks = []
    root.openPlaylistLoading = true
    root.browseSlug = "playlist"
    var args = [root.cli, "playlist", String(owner), String(list)]
    if (item.access_key) args.push(String(item.access_key))
    if (item.title) args.push(String(item.title))
    root.call(args, function(answer) {
      root.openPlaylistLoading = false
      if (seqList !== root._browseSeq) return
      if (answer && answer.ok && answer.data) {
        root.openPlaylistTracks = answer.data.tracks || []
      } else {
        root.notice = root.t("Не удалось открыть плейлист")
      }
    })
  }

  function closePlaylistView() {
    root.focusList()
    root.cursor = -1
    root.clearBrowseLoading()
    root._browseSeq = root._browseSeq + 1
    root.openPlaylist = null
    root.openPlaylistTracks = []
    root.openPlaylistLoading = false
    root.view = root.playlistBackView !== "" ? root.playlistBackView : "browse"
    root.browseSlug = root.playlistBack !== "" ? root.playlistBack : "explore"
  }

  function playPlaylistTrack(index) {
    if (!(index >= 0)) return
    var keys = []
    for (var i = 0; i < root.openPlaylistTracks.length; i++) {
      var key = String(root.openPlaylistTracks[i].key || "")
      if (key !== "") keys.push(key)
    }
    if (keys.length === 0) return
    var args = [root.cli, "play", "keys"].concat(keys)
    args.push("--index")
    args.push(String(index))
    args.push("--title")
    args.push(root.openPlaylistTitle)
    root.call(args, function() { root.watchForTrack() })
  }

  function setPlaylistView(mode) {
    root.setPreference("playlistView", mode)
  }

  // The friends are fetched once and kept: the list barely changes and the panel is
  // opened far more often than it changes.
  function loadFriends() {
    if (root.friends.length > 0) return
    root.friendsLoading = true
    root.call([root.cli, "friends"], function(answer) {
      root.friendsLoading = false
      root.friends = (answer && answer.ok && answer.data) ? answer.data : []
    })
  }

  function browseFriends() {
    root.clearFilterQuiet()
    root.cursor = -1
    root.focusList()
    root.clearBrowseLoading()
    root._browseSeq = root._browseSeq + 1
    // Everything a person's page left behind goes, but by clearing it here rather than
    // by calling closePerson: that function returns to this list, and two functions
    // that call each other are a loop, not a pair.
    root.person = null
    root.personPlaylists = []
    root.browseSlug = "friends"
    root.browseTitle = root.t("Друзья")
    root.browseTracks = []
    root.browsePlaylists = []
    root.browseNext = ""
    root.loadFriends()
  }

  function openPerson(reference) {
    root.clearFilterQuiet()
    root.focusList()
    var text = String(reference || "").trim()
    if (text === "") return
    root.cursor = -1
    root.clearBrowseLoading()
    root._browseSeq = root._browseSeq + 1
    var seqPerson = root._browseSeq
    root.personLoading = true
    root.person = null
    root.personPlaylists = []
    // The previous person's playlists must not linger under the new name.
    root.browsePlaylists = []
    root.browseSlug = "person"
    root.browseTracks = []
    root.browseNext = ""
    root.browseTitle = root.t("Человек")
    root.call([root.cli, "person", text], function(answer) {
      root.personLoading = false
      if (seqPerson !== root._browseSeq) return
      if (answer && answer.ok && answer.data) {
        root.person = answer.data.person || null
        root.personPlaylists = answer.data.playlists || []
        // The same list feeds the gallery and the rows: one place decides what a
        // person's page shows.
        root.browsePlaylists = root.personPlaylists
        root.browseTitle = root.person ? String(root.person.name || root.t("Человек")) : root.t("Человек")
      } else {
        root.notice = root.t("Человек не найден")
      }
    })
  }

  function openPersonFromField() {
    root.openPerson(root.personQuery)
  }

  function closePerson() {
    root.cursor = -1
    root.person = null
    root.personPlaylists = []
    // Back to the people the page was opened from. Leaving the slug on «person» with
    // nobody in it is what made the header say «Человек не найден» after a step back
    // instead of showing the list again — the page's own «Назад» button had the same
    // hole.
    root.browsePlaylists = []
    root.browseTracks = []
    root.browseNext = ""
    root.browseSlug = "friends"
    root.browseTitle = root.t("Друзья")
    root.loadFriends()
    root.focusList()
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
    if (!(index >= 0)) return
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
    args.push("--title", root.t("Поиск: ") + root.query.trim())
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

  // ---------------------------------------------------------- accounts ---

  function loadAccounts() {
    root.call([root.cli, "accounts"], function(answer) {
      if (answer && answer.ok && answer.data) root.accounts = answer.data.accounts || []
    })
  }

  function accountById(id) {
    var wanted = String(id)
    for (var i = 0; i < root.accounts.length; i++) {
      if (root.accounts[i] && String(root.accounts[i].id) === wanted) return root.accounts[i]
    }
    return null
  }

  function accountName(account) {
    if (!account) return ""
    var name = String(account.name || "").trim()
    return name !== "" ? name : root.t("Аккаунт ") + String(account.id)
  }

  function removeAccountHint() {
    var account = root.accountById(root.pendingAccountRemove)
    var text = root.t("Удалить аккаунт") + " «" + root.accountName(account) + "»?"
    // Removing the active account is a sign-out, not just forgetting a list of
    // tokens; saying so is the difference between a confirmation and a surprise.
    if (account && account.active === true) text += " " + root.t("Сеанс завершится.")
    return text
  }

  // A switched account has its own queue, its own likes and its own people:
  // every list on screen belongs to the old session and must go, or the panel
  // keeps showing tracks the new account cannot play.
  function reloadAfterAccountChange(newStatus) {
    root.queue = []
    root.playlists = []
    root.results = []
    root.suggestions = []
    root.browseTracks = []
    root.browsePlaylists = []
    root.stations = []
    root.sources = []
    root.sourcesLoadedAt = 0
    root.openPlaylist = null
    root.openPlaylistTracks = []
    root.playlistBack = ""
    root.playlistBackView = ""
    root.person = null
    root.personPlaylists = []
    root.friends = []
    root.foundPlaylists = []
    root.foundPlaylistsTotal = 0
    root.pendingTrack = null
    root.pendingIndex = -1
    // A filter belongs to the list it was typed in, and every one of those lists
    // now belongs to another account.
    root.filter = ""
    root.filtering = false
    root.filterFocused = false
    root.query = ""
    root._searchedQuery = ""
    root.searchState = "typing"
    root.cursor = -1
    root._queueIndex = -2
    // The answer already carries the new session's status; using it here keeps
    // the panel from flashing the signed-out form (or the old account's track)
    // while the follow-up status call is on its way.
    if (newStatus) root.status = newStatus
    root.refresh()
    root.loadQueue()
    root.loadAccounts()
  }

  function switchAccount(id) {
    root.pendingAccountRemove = ""
    root.accountNotice = ""
    root.accountError = ""
    root.call([root.cli, "account", "switch", String(id)], function(answer) {
      if (!answer || !answer.ok) return
      if (answer.data && answer.data.accounts) root.accounts = answer.data.accounts
      root.reloadAfterAccountChange(answer.data ? answer.data.status : null)
    })
  }

  function removeAccount(id) {
    if (String(id) === "") return
    root.pendingAccountRemove = ""
    root.accountNotice = ""
    root.accountError = ""
    root.call([root.cli, "account", "remove", String(id)], function(answer) {
      if (!answer || !answer.ok) return
      if (answer.data && answer.data.accounts) root.accounts = answer.data.accounts
      root.reloadAfterAccountChange(answer.data ? answer.data.status : null)
    })
  }

  function openAccountForm() {
    root.accountFormOpen = true
    root.accountNotice = ""
    root.accountError = ""
    root.accountStep = ""
    root.accountCode = ""
    root.accountSuccessToken = ""
  }

  function closeAccountForm() {
    // The daemon may be holding a password between the login and the code step;
    // closing the form is how the panel says it is no longer needed.
    if (root.accountStep !== "" || root.accountBusy) {
      root.call([root.cli, "auth", "cancel"])
    }
    root.accountFormOpen = false
    root.accountBusy = false
    root.accountLogin = ""
    root.accountPassword = ""
    root.accountCode = ""
    root.accountSuccessToken = ""
    root.accountStep = ""
    root.accountValidationType = ""
    root.accountPhoneMask = ""
    root.accountRedirectUri = ""
    root.accountFieldFocus = 0
  }

  function toggleAccountForm() {
    if (root.accountFormOpen) root.closeAccountForm()
    else root.openAccountForm()
  }

  function accountFailure(answer) {
    if (!answer || !answer.error) return root.t("Не удалось войти")
    var text = root.tm(String(answer.error.message || answer.error.code || ""))
    return text !== "" ? text : root.t("Не удалось войти")
  }

  function accountAddedNotice(answer) {
    var session = answer && answer.data ? answer.data.session : null
    var name = session ? String(session.name || "") : ""
    return name !== "" ? root.t("Аккаунт добавлен: ") + name : root.t("Аккаунт добавлен.")
  }

  function addAccountFromBrowser() {
    root.accountBusy = true
    root.accountError = ""
    root.call([root.cli, "auth", "web"], function(answer) {
      root.accountBusy = false
      if (!answer || !answer.ok) {
        root.accountError = root.accountFailure(answer)
        return
      }
      if (answer.data && answer.data.accounts) root.accounts = answer.data.accounts
      root.accountNotice = root.accountAddedNotice(answer)
      root.closeAccountForm()
      root.reloadAfterAccountChange(answer.data ? answer.data.status : null)
    })
  }

  function submitAccountLogin() {
    var login = root.accountLogin.trim()
    var password = root.accountPassword
    if (login === "" || password === "") {
      root.accountError = root.t("Нужны логин и пароль")
      return
    }
    root.accountError = ""
    root.accountBusy = true
    root.callRequest({ command: "auth_mobile_start", login: login, password: password }, function(answer) {
      // The password is not kept a moment longer than the request needs it.
      root.accountPassword = ""
      root.accountBusy = false
      root.handleAccountAuth(answer)
    })
  }

  function submitAccountCode() {
    var code = root.accountCode.trim()
    if (code === "") return
    root.accountError = ""
    root.accountBusy = true
    root.callRequest({ command: "auth_mobile_step", code: code }, function(answer) {
      root.accountBusy = false
      root.handleAccountAuth(answer)
    })
  }

  function submitAccountCaptcha() {
    var token = root.accountSuccessToken.trim()
    if (token === "") return
    root.accountError = ""
    root.accountBusy = true
    root.callRequest({ command: "auth_mobile_step", successToken: token }, function(answer) {
      root.accountBusy = false
      root.handleAccountAuth(answer)
    })
  }

  function handleAccountAuth(answer) {
    if (!answer || !answer.ok) {
      root.accountError = root.accountFailure(answer)
      return
    }
    var data = answer.data || ({})
    if (data.done === true) {
      if (data.accounts) root.accounts = data.accounts
      root.accountNotice = root.accountAddedNotice(answer)
      root.closeAccountForm()
      root.reloadAfterAccountChange(data.status || null)
      return
    }
    root.accountStep = String(data.step || "")
    root.accountValidationType = String(data.validationType || "")
    root.accountPhoneMask = String(data.phoneMask || "")
    root.accountRedirectUri = String(data.redirectUri || "")
    root.accountCode = ""
    root.accountSuccessToken = ""
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
  // The height the card grows by so that a gallery ends where a row ends. The list asks
  // for it (`TrackList.alignGallery`) instead of the card computing it: the room the list
  // gets comes from this height, and a binding from one to the other is a loop. Zero
  // unless a gallery needs the extra row.
  property real galleryRoom: 0
  function setGalleryRoom(delta) {
    var value = delta > 1 ? delta : 0
    // A pixel of rounding is not worth a re-layout.
    if (Math.abs(root.galleryRoom - value) < 1) return
    root.galleryRoom = value
  }
  // How far the selected fill reaches past a card, and therefore how much room a grid
  // has to leave around its columns.
  readonly property real cardRim: Style.space(4)
  readonly property int galleryColumns: root.isExtended() ? 4 : 3
  // A grid of cards, as opposed to a one-column list: only then do h and l mean
  // anything, and only then does j move a row rather than a line. It is the list ON
  // SCREEN that decides, never the playlist-view preference alone — a playlist's
  // tracks and the queue are lists even when the gallery is on for playlists, and
  // stepping four at a time there is what made «j» land on the wrong track.
  readonly property bool galleryMode: {
    if (root.openPlaylist !== null) return false
    if (root.view === "browse") {
      if (root.browseSlug === "radiostations") return false
      if (root.browseSlug === "person") return root.gridView && root.personPlaylists.length > 0
      if (root.browseSlug === "friends") {
        return root.gridView && (root.friends.length > 0 || root.people.length > 0)
      }
      return root.gridView && root.browsePlaylists.length > 0
    }
    if (root.view === "search") {
      return root.gridView && root.searchMode === "playlists" && root.foundPlaylists.length > 0
    }
    return false
  }

  readonly property int marqueeSpeed: {
    var value = Number(root.setting("marqueeSpeed", root.prefs.marqueeSpeed))
    return isNaN(value) ? 70 : Math.max(10, Math.min(300, value))
  }
  // The progress line has something to say only for a track with a length: a
  // station is endless and shows nothing.
  readonly property bool barHasProgress: root.hasTrack && !root.onAir() && root.duration > 0
  // A row with nothing in it has no width, and a widget of zero width cannot be
  // clicked. Cover, title and artist can all be switched off, and then a stopped
  // player vanished from the bar entirely — leaving no way back to the panel.
  // One note stands in for the whole row in that case.
  readonly property bool barRowEmpty: {
    if (root.barShowArtwork) return false
    if (root.barShowTitle || root.barShowArtist) return false
    if (root.barShowTime && root.hasTrack && !root.onAir()) return false
    if (root.barShowControls && root.hasTrack) return false
    if (root.barShowLike && root.hasTrack && !root.onAir()) return false
    if (root.barShowProgress && root.barHasProgress) return false
    return true
  }
  readonly property real barProgress: root.barHasProgress
    ? Math.max(0, Math.min(1, root.displayPosition / root.duration)) : 0

  // The label shown in the bar. Signing in, an empty queue and a stopped
  // service are states of the widget, not errors: only a halt paints red.
  readonly property string barLabel: {
    if (root.halted !== "") return root.t("остановлен")
    if (!root.signedIn) return "vk music"
    // A live station has no track behind it: its name is the whole label.
    if (root.onAir()) return String(root.radioValue("name", root.t("радио")))
    if (!root.hasTrack) return root.loading ? root.t("загрузка…") : "vk music"
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
      : (root.halted !== "" ? root.haltText : (root.hasTrack
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

    // Kept even when the row is otherwise empty: this is the way back to the
    // panel, so it must exist at the smallest configuration as well.
    BarGlyph {
      id: idleGlyph
      visible: root.barRowEmpty
      height: root.implicitHeight
      // Lucide has no bare «music» body; the icon font glyph is the fallback
      // that keeps this visible even if the set changes again.
      name: "list-music"
      icon: "󰝚"
      filled: false
      tooltip: "VK Music"
      onClicked: root.open()
    }

    BorderSurface {
      id: artwork
      // 20 px matches the cover size the other bar players in this shell use.
      width: Style.space(20)
      height: width
      // At twenty pixels a four-pixel corner is a fifth of the picture, so the frame's
      // rounding and the picture's square corners read as two shapes fighting. The
      // rounding is proportional here, and the picture sits one pixel in.
      radius: root.barCoverShape === "circle" ? width / 2
        : (root.barCoverShape === "square" ? 0 : Style.space(2))
      visible: root.barShowArtwork
      anchors.verticalCenter: parent.verticalCenter
      color: Style.normalFillFor(root.fg, Color.accent)
      borderSpec: root.buffering
        ? Border.none()
        : Border.controlSpec("normal", root.fg, Color.accent)
      opacity: root.hasTrack ? 1.0 : 0.6

      CoverTile {
        anchors.fill: parent
        anchors.margins: Style.space(1)
        // The rounding is proportional here, and the picture sits one pixel in: at
        // twenty pixels a four-pixel corner is a fifth of the picture.
        radius: Math.max(0, artwork.radius - Style.space(1))
        inset: 0
        glyphFamily: bar ? bar.fontFamily : Style.font.family
        markColor: root.fg
        decodeSize: Style.space(20)
        source: root.onAir()
          ? String(root.radioValue("logo", ""))
          : (root.hasTrack && root.trackValue("thumb", "") ? root.trackValue("thumb", "") : "")
        title: root.onAir()
          ? String(root.radioValue("name", ""))
          : (root.hasTrack ? root.trackValue("artist", "") : "")
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

    // Liking from the bar, without opening the popup: the same glyph target as the
    // transport, with the accent colour standing for «it is in my music».


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

    Row {
      id: transportZone
      visible: root.hasTrack && root.barShowControls
      height: root.implicitHeight
      anchors.verticalCenter: parent.verticalCenter
      // The reference leaves two pixels between its transport buttons.
      spacing: Style.space(2)

      // The same three glyphs the reference widget shows, in the same shape: previous,
      // play or pause, next — 24 px each, nothing drawn between them.
      BarGlyph {
        name: "skip-back"
        filled: true
        icon: "󰒮"
        tooltip: root.t("Предыдущий трек")
        onClicked: root.skipPrevious()
      }

      BarGlyph {
        // The glyph never turns into a downloader: play stays play, dimmed while the
        // track is being fetched.
        name: root.playing ? "pause" : "play"
        filled: true
        icon: root.playing ? "󰏤" : "󰐊"
        tooltip: root.playing ? root.t("Пауза") : root.t("Играть")
        onClicked: root.togglePause()
      }

      BarGlyph {
        name: "skip-forward"
        filled: true
        icon: "󰒭"
        tooltip: root.t("Следующий трек")
        onClicked: root.skipNext()
      }
    }

    // The heart sits after the transport, at the right end: it is not a control of the
    // sound, it is a statement about the track.
    BarGlyph {
      visible: root.barShowLike && root.hasTrack && !root.onAir()
      anchors.verticalCenter: parent.verticalCenter
        name: "heart"
      fillOnHover: true
      filled: root.liked
      icon: root.liked ? "󰋑" : "󰋕"
      iconColor: root.liked ? Color.accent : root.fg
      tooltip: root.liked ? root.t("Убрать из моей музыки") : root.t("В мою музыку")
      onClicked: root.toggleLike()
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
      root.loadAccounts()
      afterOpen.restart()
      return
    }
    // A password must not outlive the popup that asked for it.
    root.accountPassword = ""
    root.accountFieldFocus = 0
    root.playerControlsOpen = false
    // Neither does a sheet left open over a card that is closed again.
    root.hintsOpen = false
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
      // Widths as well as heights: a child wider than the body is what made every row
      // bleed past the card, and only this number showed it.
      widths: [root.activeBody().width, root.activeList().width],
      list: [root.activeList().viewHeight, root.activeList().contentHeight],
      shown: [root.suggestionsShown.length, root.resultsShown.length]
    }))
    // The keyboard belongs to the list when the panel opens. A field of a view that is
    // not showing would otherwise keep it, and a hidden field eats every key it is
    // given — j, k and Backspace included, which is why the keys looked dead.
    if (root.view === "search") root.activeField().forceActiveFocus()
    else root.focusList()
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

    // One row of equal cells across the width, the way the switch over the search results
    // is drawn: the options of a preference are a choice, not a set of buttons.
    RowLayout {
      width: parent.width
      spacing: 0

      Repeater {
        model: choiceRow.options
        delegate: BarCell {
          Layout.fillWidth: true
          Layout.preferredWidth: 0
          Layout.minimumWidth: 0
          Layout.preferredHeight: root.barCellHeight
          text: modelData ? String(modelData.label) : ""
          selected: choiceRow.value === (modelData ? modelData.value : "")
          onClicked: if (modelData) root.setPreference(choiceRow.key, modelData.value)
        }
      }
    }
  }

  // ------------------------------------------------------------ accounts ---
  //
  // Accounts are not a preference: they are sessions the daemon holds, and the
  // panel shows them in the settings page and on the signed-out screen. One
  // block, used in both places, keeps the two from drifting apart.

  component AccountRow: RowLayout {
    id: accountRow
    property var account: null
    width: parent ? parent.width : 0
    spacing: Style.space(8)

    // A Row positions its children, it does not align them: with the switch
    // button taller than the two text lines, the anchored column and the two
    // anchored buttons settled on different heights. A RowLayout aligns every
    // child on one centre line, which is the thing the screenshot was missing.
    CoverTile {
      id: accountAvatar
      Layout.preferredWidth: Style.space(28)
      Layout.preferredHeight: Style.space(28)
      Layout.alignment: Qt.AlignVCenter
      width: Style.space(28)
      height: width
      radius: width / 2
      inset: 0
      mark: "󰀄"
      decodeSize: Style.space(28)
      source: accountRow.account ? String(accountRow.account.photo || "") : ""
      title: accountRow.account ? root.accountName(accountRow.account) : ""
    }

    ColumnLayout {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      Layout.alignment: Qt.AlignVCenter
      spacing: Style.space(2)

      Text {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: root.accountName(accountRow.account)
        color: root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: accountRow.account && accountRow.account.active === true
          ? root.t("Активный") : root.t("Войти")
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    Button {
      id: accountSwitch
      Layout.alignment: Qt.AlignVCenter
      visible: !(accountRow.account && accountRow.account.active === true)
      text: root.t("Переключить")
      foreground: root.textColor
      onClicked: if (accountRow.account) root.switchAccount(accountRow.account.id)
    }

    Button {
      id: accountRemove
      Layout.alignment: Qt.AlignVCenter
      iconText: "󰆴"
      tooltipText: root.t("Удалить")
      foreground: root.textColor
      onClicked: root.pendingAccountRemove = accountRow.account ? String(accountRow.account.id) : ""
    }
  }

  component AccountLoginForm: ColumnLayout {
    id: accountForm
    spacing: Style.spacing.controlGap

    Text {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: root.t("Через браузер — текущая сессия VK. Или войдите по логину и паролю: второй аккаунт в браузере не нужен.")
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Button {
      Layout.fillWidth: true
      text: root.accountBusy ? root.t("Вход…") : root.t("Войти через браузер")
      foreground: root.textColor
      enabled: !root.accountBusy
      onClicked: root.addAccountFromBrowser()
    }

    Text {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      visible: root.accountError !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: root.accountError
      color: Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    PanelSeparator { Layout.fillWidth: true; foreground: root.textColor }

    TextField {
      id: accountLoginField
      Layout.fillWidth: true
      placeholderText: root.t("Телефон, email или id")
      foreground: root.textColor
      accent: Color.accent
      enabled: !root.accountBusy && root.accountStep === ""
      text: root.accountLogin
      onTextChanged: if (text !== root.accountLogin) root.accountLogin = text
      onActiveFocusChanged: root.accountFieldFocus = Math.max(0,
        root.accountFieldFocus + (activeFocus ? 1 : -1))
      Keys.onEscapePressed: function(event) { root.focusList(); event.accepted = true }
      onAccepted: root.submitAccountLogin()
    }

    TextField {
      id: accountPasswordField
      Layout.fillWidth: true
      placeholderText: root.t("Пароль")
      password: true
      foreground: root.textColor
      accent: Color.accent
      enabled: !root.accountBusy && root.accountStep === ""
      text: root.accountPassword
      onTextChanged: if (text !== root.accountPassword) root.accountPassword = text
      onActiveFocusChanged: root.accountFieldFocus = Math.max(0,
        root.accountFieldFocus + (activeFocus ? 1 : -1))
      Keys.onEscapePressed: function(event) { root.focusList(); event.accepted = true }
      onAccepted: root.submitAccountLogin()
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)

      Button {
        text: root.t("Войти")
        foreground: root.textColor
        enabled: !root.accountBusy && root.accountStep === ""
          && root.accountLogin.trim() !== "" && root.accountPassword !== ""
        onClicked: root.submitAccountLogin()
      }

      Text {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        elide: Text.ElideRight
        visible: root.accountBusy
        text: root.t("Вход…")
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(4)
      visible: root.accountStep === "code"

      Text {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: root.t("Код из SMS или приложения") + (root.accountPhoneMask !== ""
          ? " · " + root.accountPhoneMask : "")
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      TextField {
        id: accountCodeField
        Layout.fillWidth: true
        placeholderText: root.t("Код подтверждения")
        foreground: root.textColor
        accent: Color.accent
        enabled: !root.accountBusy
        text: root.accountCode
        onVisibleChanged: if (visible) forceActiveFocus()
        onTextChanged: if (text !== root.accountCode) root.accountCode = text
        onActiveFocusChanged: root.accountFieldFocus = Math.max(0,
          root.accountFieldFocus + (activeFocus ? 1 : -1))
        Keys.onEscapePressed: function(event) { root.focusList(); event.accepted = true }
        onAccepted: root.submitAccountCode()
      }

      Button {
        text: root.t("Подтвердить")
        foreground: root.textColor
        enabled: !root.accountBusy && root.accountCode.trim() !== ""
        onClicked: root.submitAccountCode()
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.space(4)
      visible: root.accountStep === "captcha"

      Text {
        Layout.fillWidth: true
        Layout.preferredWidth: 0
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: root.t("VK просит капчу. Откройте ссылку, решите её и вставьте success_token.")
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Button {
        text: root.t("Открыть в браузере")
        foreground: root.textColor
        enabled: root.accountRedirectUri !== ""
        onClicked: if (root.accountRedirectUri !== "") Qt.openUrlExternally(root.accountRedirectUri)
      }

      TextField {
        id: accountCaptchaField
        Layout.fillWidth: true
        placeholderText: "success_token"
        foreground: root.textColor
        accent: Color.accent
        enabled: !root.accountBusy
        text: root.accountSuccessToken
        onVisibleChanged: if (visible) forceActiveFocus()
        onTextChanged: if (text !== root.accountSuccessToken) root.accountSuccessToken = text
        onActiveFocusChanged: root.accountFieldFocus = Math.max(0,
          root.accountFieldFocus + (activeFocus ? 1 : -1))
        Keys.onEscapePressed: function(event) { root.focusList(); event.accepted = true }
        onAccepted: root.submitAccountCaptcha()
      }

      Button {
        text: root.t("Подтвердить")
        foreground: root.textColor
        enabled: !root.accountBusy && root.accountSuccessToken.trim() !== ""
        onClicked: root.submitAccountCaptcha()
      }
    }
  }

  component AccountsBlock: Column {
    id: accountsBlock
    width: parent ? parent.width : 0
    spacing: Style.spacing.controlGap

    Repeater {
      model: root.accounts
      delegate: AccountRow { account: modelData }
    }

    Text {
      width: parent.width
      visible: root.accounts.length === 0
      textFormat: Text.PlainText
      text: root.t("Аккаунтов пока нет")
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      width: parent.width
      visible: root.accountNotice !== ""
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      text: root.accountNotice
      color: root.textColor
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Row {
      width: parent.width
      spacing: Style.space(6)
      visible: root.pendingAccountRemove !== ""

      Text {
        width: parent.width - removeAccountButton.width - cancelAccountButton.width
          - parent.spacing * 2
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: root.removeAccountHint()
        color: root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      Button {
        id: removeAccountButton
        anchors.verticalCenter: parent.verticalCenter
        text: root.t("Удалить")
        foreground: root.textColor
        onClicked: root.removeAccount(root.pendingAccountRemove)
      }

      Button {
        id: cancelAccountButton
        anchors.verticalCenter: parent.verticalCenter
        text: root.t("Отмена")
        foreground: root.textColor
        onClicked: root.pendingAccountRemove = ""
      }
    }

    Button {
      text: root.accountFormOpen ? root.t("Отмена") : root.t("Добавить аккаунт")
      foreground: root.textColor
      onClicked: root.toggleAccountForm()
    }

    // A ColumnLayout inside a plain Column needs its width said out loud.
    AccountLoginForm {
      width: parent.width
      visible: root.accountFormOpen
    }
  }

  // The popup's list: the queue, a catalog section, the search results or the
  // settings page. It is a component of its own because the extended popup shows
  // it beside the player rather than under it.
  // A playlist in the gallery: the cover, its name, how long it is. The accent
  // frame is the keyboard cursor, the way the fill is on a row.
  // The bar's control glyph, drawn to the same recipe the reference music widget uses:
  // a 24 px wide, full-height target with a 14 px icon, transparent at rest, a faint
  // fill under the pointer and an accent fill with an accent icon while pressed. That
  // is the whole vocabulary — in a 30 px bar a frame around every glyph competes with
  // every other widget for the same pixels.
  component BarGlyph: Item {
    id: glyph
    // Lucide's name, the way the reference widget asks for its icons: `skip-back`,
    // `play`, `pause`, `skip-forward`, `heart`. `icon` stays as a fallback glyph from
    // the icon font for a name the set does not carry.
    property string name: ""
    property string icon: ""
    property bool filled: false
    // Some glyphs answer the pointer by filling in rather than by lighting a rectangle
    // around themselves: a 24 px box under a 14 px outline heart is four times the shape
    // it points at, and the box reads as a button while the heart reads as the thing
    // being offered. With this set, hovering fills the glyph and paints no background.
    property bool fillOnHover: false
    property real strokeWidth: 2
    // How large the drawn glyph is inside its target. The bar's own controls keep the
    // 14 px icon they have always had; the player, which is not a 30 px row, asks for
    // a bigger one and gets it without a second copy of this component.
    property real iconSize: Style.space(14)
    property string tooltip: ""
    property color iconColor: root.fg
    signal clicked()
    signal wheeled(var wheel)

    readonly property bool hot: glyphArea.pressed
    readonly property bool under: glyphArea.containsMouse
    readonly property color tint: glyph.hot
      ? Color.accent
      : (glyph.under ? Qt.lighter(glyph.iconColor, 1.15) : glyph.iconColor)
    readonly property string tintRgb: "rgb(" + Math.round(glyph.tint.r * 255) + ","
      + Math.round(glyph.tint.g * 255) + "," + Math.round(glyph.tint.b * 255) + ")"
    readonly property string body: glyph.name !== "" ? (Lucide.bodies[glyph.name] || "") : ""
    // What the drawing asks for: the state the glyph was given, or the one the pointer
    // puts it in.
    readonly property bool drawnFilled: glyph.filled
      || (glyph.fillOnHover && (glyph.under || glyph.hot))
    readonly property string svg: glyph.body === "" ? "" : "data:image/svg+xml;utf8,"
      + encodeURIComponent(
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="'
        + (glyph.drawnFilled ? glyph.tintRgb : "none")
        + '" stroke="' + glyph.tintRgb + '" stroke-width="' + glyph.strokeWidth
        + '" stroke-linecap="round" stroke-linejoin="round">' + glyph.body + "</svg>")

    width: Style.space(24)
    height: parent ? parent.height : Style.space(24)
    opacity: enabled ? 1 : 0.35

    Rectangle {
      anchors.fill: parent
      // None for a glyph that fills in on hover: the highlight is the shape, and a box
      // around it would be the second thing the pointer draws.
      visible: !glyph.fillOnHover
      radius: Style.cornerRadius
      color: glyph.hot
        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.2)
        : (glyph.under
           ? Qt.rgba(glyph.iconColor.r, glyph.iconColor.g, glyph.iconColor.b, 0.08)
           : "transparent")
    }

    Image {
      anchors.centerIn: parent
      width: glyph.iconSize
      height: width
      visible: glyph.body !== ""
      smooth: true
      asynchronous: false
      fillMode: Image.PreserveAspectFit
      sourceSize.width: Math.ceil(width * 2)
      sourceSize.height: Math.ceil(width * 2)
      opacity: root.loading ? 0.45 : 1.0
      source: glyph.svg
    }

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      visible: glyph.body === "" && glyph.icon !== ""
      text: glyph.icon
      color: glyph.tint
      opacity: root.loading ? 0.45 : 1.0
      font.family: bar ? bar.fontFamily : Style.font.family
      font.pixelSize: Style.space(14)
    }

    MouseArea {
      id: glyphArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: glyph.clicked()
      onWheel: function(wheel) { glyph.wheeled(wheel) }
      onEntered: if (bar && glyph.tooltip !== "") bar.showTooltip(glyph, glyph.tooltip)
      onExited: if (bar) bar.hideTooltip(glyph)
    }
  }

  // A cover that may not be there. Loading and failure look the same on purpose: the
  // tile is drawn first and the picture fades in over it only once it is ready, so a
  // card never shows the surface colour where a cover belongs. A signed VK link that
  // has expired used to leave exactly that — a flat white square, with the glyph hidden
  // because the URL was not empty. What stays when there is no picture is a tint of the
  // item's own title and its first letters.
  component CoverTile: BorderSurface {
    id: tile
    property string source: ""
    // Both the monogram and the tint come from this, so it has to be the item's name:
    // the same playlist keeps one colour between opens, and no id has to be hashed.
    property string title: ""
    // The corner mark says what kind of item this is — a note for a playlist or a track,
    // a person for a profile. Empty leaves the tile wordless.
    property string mark: "󰝚"
    property string glyphFamily: Style.font.family
    property color markColor: root.dim
    property color monogramColor: root.textColor
    // The picture sits a pixel or two inside the surface: a Rectangle cannot clip its
    // children to a radius, so the frame has to show around it instead.
    property real inset: 0
    // How many pixels the picture is asked for. The callers pass the width the tile
    // will have, because the tile starts at zero and a size that grows would ask the
    // network for the same cover twice — once at 0 (the original) and once at the final
    // width. Twice the width keeps it sharp on a scaled display.
    property real decodeSize: 0

    readonly property bool shown: picture.status === Image.Ready
    readonly property real side: Math.min(width, height)
    readonly property string monogram: root.coverMonogram(title)
    // Below about forty pixels there is no room for two marks: the glyph alone says
    // what the row is, the way it always has in the small covers. A tile with nothing
    // to abbreviate keeps the large centred glyph at any size.
    readonly property bool roomy: tile.side >= Style.space(40)
    readonly property bool labeled: tile.roomy && tile.monogram !== ""
    // Below eighty pixels the corner mark is a speck beside the letters rather than a
    // second word, so a small tile keeps the monogram alone. A circle has no corners
    // either: the bottom-right of the square is the part its radius cuts away.
    readonly property bool round: tile.radius * 2 >= tile.side - 1
    readonly property bool cornerMark: tile.labeled && !tile.round && tile.side >= Style.space(80)

    radius: Style.spacing.labelGap
    // The tint belongs to the fallback, not to the frame: a picture keeps the neutral
    // rim it has always had, and only the tile that stands in for it is coloured.
    color: tile.shown ? root.panelBackground : root.coverTint(title)

    Image {
      id: picture
      anchors.fill: parent
      anchors.margins: tile.inset
      source: tile.source
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      smooth: true
      // A 600 px cover decoded for a 160 px card is memory for nothing: the tile says
      // what it needs, and nothing is asked for while that is unknown.
      sourceSize.width: tile.decodeSize > 0 ? Math.ceil(tile.decodeSize * 2) : 0
      sourceSize.height: tile.decodeSize > 0 ? Math.ceil(tile.decodeSize * 2) : 0
      opacity: tile.shown ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutQuad } }
    }

    Text {
      anchors.centerIn: parent
      visible: !tile.shown && tile.labeled
      text: tile.monogram
      textFormat: Text.PlainText
      color: tile.monogramColor
      opacity: 0.8
      font.family: tile.glyphFamily
      font.bold: true
      font.pixelSize: Math.round(tile.side * 0.34)
      font.letterSpacing: Math.round(tile.side * 0.02)
    }

    Text {
      anchors.centerIn: parent
      visible: !tile.shown && !tile.labeled && tile.mark !== ""
      text: tile.mark
      textFormat: Text.PlainText
      color: tile.markColor
      font.family: tile.glyphFamily
      font.pixelSize: Math.max(Style.font.caption, Math.round(tile.side * (tile.roomy ? 0.34 : 0.5)))
    }

    Text {
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.margins: Math.round(tile.side * 0.07)
      visible: !tile.shown && tile.cornerMark
      text: tile.mark
      textFormat: Text.PlainText
      color: tile.markColor
      opacity: 0.45
      font.family: tile.glyphFamily
      font.pixelSize: Math.round(tile.side * 0.15)
    }
  }

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
    // The border says «the pointer is here», the cover steps back a little to say it
    // twice: a border alone is easy to miss under a bright picture.
    opacity: cardArea.containsMouse && !card.selected ? 0.82 : 1.0

    // The selected fill goes behind the whole card — cover and captions — which is
    // exactly what a row in a list does, so the same state looks the same in both
    // views. A rim of it shows around the picture, which is what makes the card read
    // as one thing rather than as a picture with a label under it.
    BorderSurface {
      anchors.fill: parent
      anchors.margins: -root.cardRim
      radius: 0
      color: Style.selectedFillFor(Color.foreground, Color.accent)
      borderSpec: Border.none()
      visible: card.selected
    }

    Column {
      id: body
      width: parent.width
      spacing: Style.space(3)

      // The accent frame is the keyboard cursor, the way the fill is on a row.
      CoverTile {
        width: parent.width
        height: width
        inset: Style.space(2)
        // The cover keeps only the hover border: selection is the fill behind the
        // card, and two marks for one state would say nothing extra.
        borderSpec: cardArea.containsMouse && !card.selected
          ? Border.controlSpec("hover", Color.foreground, Color.accent, Color.urgent)
          : Border.none()
        decodeSize: card.cellWidth
        source: card.item ? String(card.item.cover || "") : ""
        title: card.item ? String(card.item.title || "") : ""
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 1
        // Padding inside the card: text that touches the edge of the surface it sits
        // on reads as a layout accident, not as a caption.
        leftPadding: Style.space(6)
        rightPadding: Style.space(6)
        text: card.item ? String(card.item.title || "") : ""
        color: card.selected ? Color.accent : root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        leftPadding: Style.space(6)
        rightPadding: Style.space(6)
        text: card.item && card.item.count
          ? (Number(card.item.count) + " " + root.plural(Number(card.item.count), root.t("трек"), root.t("трека"), root.t("треков")))
          : ""
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    MouseArea {
      id: cardArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: card.activated()
    }
  }

  // A person in the gallery: their picture and their name. The picture is a
  // circle, the way every VK profile is, and the name sits under it.
  component PersonCard: Item {
    id: personCard
    property var item: null
    property real cellWidth: 100
    property bool selected: false
    signal activated()

    width: cellWidth
    height: body.implicitHeight
    // A border alone is easy to miss under a bright picture: the card steps back a
    // little as well when the pointer is on it.
    opacity: personCardArea.containsMouse && !personCard.selected ? 0.82 : 1.0

    // The same selected fill as a playlist card, for the same reason.
    BorderSurface {
      anchors.fill: parent
      anchors.margins: -root.cardRim
      radius: 0
      color: Style.selectedFillFor(Color.foreground, Color.accent)
      borderSpec: Border.none()
      visible: personCard.selected
    }

    Column {
      id: body
      width: parent.width
      spacing: Style.space(3)

      CoverTile {
        width: parent.width
        height: width
        radius: width / 2
        // Flush with the frame: an inset shows the surface colour as a ring around the
        // portrait, which reads as a white gap in a light theme.
        inset: 0
        mark: "󰀄"
        borderSpec: personCardArea.containsMouse && !personCard.selected
          ? Border.controlSpec("hover", Color.foreground, Color.accent, Color.urgent)
          : Border.none()
        decodeSize: personCard.cellWidth
        source: personCard.item ? String(personCard.item.photo || "") : ""
        title: personCard.item ? String(personCard.item.name || "") : ""
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 2
        wrapMode: Text.WordWrap
        horizontalAlignment: Text.AlignHCenter
        leftPadding: Style.space(6)
        rightPadding: Style.space(6)
        text: personCard.item ? String(personCard.item.name || "") : ""
        color: personCard.selected ? Color.accent : root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }
    }

    MouseArea {
      id: personCardArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: personCard.activated()
    }
  }

  // The same people as a grid: choosing a person is picking a face, which is what
  // a gallery is for.
  component PeopleGrid: Grid {
    id: peopleGrid
    property var items: []
    // Where this grid starts in the cursor's list: the recent people come after the
    // friends, so their cards must not light up for the friends' indices.
    property int baseOffset: 0
    // The captions under a portrait are two known lines of known fonts, and their
    // height is what turns a picture into a card. Measured from the fonts rather than
    // from a delegate: a card's width would otherwise feed back into the height that
    // decides that width, and the binding would settle wherever the loop was broken.
    TextMetrics {
      id: personTitleLine
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Ag"
    }
    TextMetrics {
      id: personCountLine
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      text: "Ag"
    }
    readonly property real captionBlock:
      personTitleLine.height + personCountLine.height + 2 * Style.space(3)
    // How many cards across and how wide each of them is: both come from
    // `GalleryFit.plan`, where the arithmetic is tested. The cards fill the width the
    // column count gives them — including the three friends that are the whole list.
    readonly property real usable: peopleGrid.width - 2 * peopleGrid.rim
    readonly property var plan: GalleryFit.plan(usable, root.galleryColumns,
      spacing, captionBlock, items.length)
    readonly property real cellWidth: plan.cellWidth
    readonly property real tableWidth: plan.columns * plan.cellWidth
      + Math.max(0, plan.columns - 1) * spacing
    signal picked(int index)

    function itemAt(index) { return cardRepeater.itemAt(index) }

    width: parent ? parent.width : 0
    columns: plan.columns
    spacing: Style.space(6)
    // The selected fill reaches a few pixels past its card, so the grid keeps a rim of
    // its own — otherwise the first column's fill is cut by the edge of the list.
    // The rim keeps a selected card's fill from being cut by the list's edge. The card's
    // own inset is on top of it now that the list runs edge to edge: the gallery is not a
    // row, and a wall of covers flush with the card reads as a crop, not as a gallery.
    readonly property real rim: root.cardRim
    leftPadding: Math.max(rim, Math.round((width - tableWidth) / 2))
    rightPadding: leftPadding

    Repeater {
      id: cardRepeater
      model: peopleGrid.items
      delegate: PersonCard {
        item: modelData
        cellWidth: peopleGrid.cellWidth
        selected: (peopleGrid.baseOffset + index) === root.cursor
        onActivated: peopleGrid.picked(index)
      }
    }
  }

  // A person in a list: their picture, their name, and a click that opens their
  // playlists. The selected fill is the keyboard cursor, as everywhere else.
  // One line of the search: a suggestion while typing, or a query that was searched
  // before. The same row language as a track — square, as wide as the card, the cursor's
  // fill reaching both edges — with its text where a track's title starts.
  component SuggestionRow: Item {
    id: suggestionRow
    property string text: ""
    property bool selected: false
    signal clicked()

    width: parent ? parent.width : 0
    height: Style.space(30)

    BorderSurface {
      anchors.fill: parent
      anchors.leftMargin: -root.cardInset
      anchors.rightMargin: -root.cardInset
      radius: 0
      color: suggestionRow.selected
        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
        : Style.normalFillFor(Color.foreground, Color.accent)
      borderSpec: Border.none()
      visible: suggestionRow.selected || suggestionArea.containsMouse
    }

    Text {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: suggestionRow.text
      color: root.textColor
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: suggestionArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: suggestionRow.clicked()
    }
  }

  component PersonRow: Item {
    id: person
    property var item: null
    property bool selected: false
    signal activated()

    width: parent ? parent.width : 0
    height: Style.space(30)

    BorderSurface {
      anchors.fill: parent
      anchors.leftMargin: -root.cardInset
      anchors.rightMargin: -root.cardInset
      radius: 0
      color: person.selected
        ? Style.selectedFillFor(Color.foreground, Color.accent)
        : Style.normalFillFor(Color.foreground, Color.accent)
      borderSpec: Border.none()
      visible: person.selected || personArea.containsMouse
    }

    CoverTile {
      id: avatar
      width: Style.space(24)
      height: width
      radius: width / 2
      anchors.left: parent.left
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      // Flush with the frame: an inset shows the surface colour as a ring around the
      // portrait, which reads as a white gap in a light theme.
      inset: 0
      mark: "󰀄"
      decodeSize: Style.space(24)
      source: person.item ? String(person.item.photo || "") : ""
      title: person.item ? String(person.item.name || "") : ""
    }

    Text {
      anchors.left: avatar.right
      anchors.leftMargin: Style.space(8)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      elide: Text.ElideRight
      text: person.item ? String(person.item.name || "") : ""
      color: root.textColor
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    MouseArea {
      id: personArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: person.activated()
    }
  }

  // A track in a list: its place, its name and its artist on two lines, and its
  // length on the right. No cover — three hundred thumbnails is a slow list, and
  // the album art is one line higher in the player. The number is left out where
  // it means nothing (a search result has no place in a playlist), and the playing
  // row says so in the accent colour while the cursor keeps the fill.
  component TrackRow: Item {
    id: trackRow
    property var track: null
    property int position: 0
    property bool selected: false
    signal activated()
    signal contextRequested()

    width: parent ? parent.width : 0
    height: Style.space(48)

    readonly property bool playing: trackRow.track !== null
      && root.isPlayingTrack(trackRow.track.key)

    // The row that is playing sits on a plain rounded pill, the way the players people
    // come from do it, and the play glyph in its number column says why. The keyboard
    // cursor takes the accent tint instead: two facts, two marks, no confusion.
    BorderSurface {
      anchors.fill: parent
      anchors.leftMargin: -root.cardInset
      anchors.rightMargin: -root.cardInset
      radius: 0
      color: Style.selectedFillFor(Color.foreground, Color.accent)
      borderSpec: Border.none()
      visible: trackRow.playing && !trackRow.selected
    }

    BorderSurface {
      anchors.fill: parent
      anchors.leftMargin: -root.cardInset
      anchors.rightMargin: -root.cardInset
      radius: 0
      color: trackRow.selected
        ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)
        : Style.normalFillFor(Color.foreground, Color.accent)
      borderSpec: Border.none()
      visible: trackRow.selected || trackArea.containsMouse
    }

    Text {
      id: positionText
      // Always the same width, so the cover never moves when a track starts playing and
      // the glyph has to appear. The right side of the row is inset by the same total, so
      // the two paddings match without either side depending on what the row contains.
      width: Style.space(20)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      // Flush left, not centred: a centred glyph sits ten pixels deeper than a flush one,
      // and the row's two side paddings then look nothing alike. The column is a fixed
      // width, so the cover stays on its line whatever the number is.
      horizontalAlignment: Text.AlignLeft
      textFormat: Text.PlainText
      // A playing row shows the play glyph where its number would be.
      text: trackRow.playing ? "▶" : (trackRow.position > 0 ? String(trackRow.position) : "")
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    Text {
      id: durationText
      width: Style.space(42)
      anchors.right: parent.right
      anchors.rightMargin: Style.space(28)
      anchors.verticalCenter: parent.verticalCenter
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: trackRow.track ? root.clock(Number(trackRow.track.duration || 0)) : ""
      color: root.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // A cover per row: the list is browsed with the eye, and a wall of text is harder
    // to scan than a column of pictures. It is VK's own thumbnail, so it costs no
    // extra request the panel has not already made.
    CoverTile {
      id: rowCover
      width: Style.space(32)
      height: width
      anchors.left: positionText.right
      anchors.leftMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      radius: Style.space(3)
      inset: Style.space(1)
      decodeSize: Style.space(32)
      source: trackRow.track ? String(trackRow.track.thumb || "") : ""
      title: trackRow.track ? String(trackRow.track.title || "") : ""
    }

    Column {
      anchors.left: rowCover.right
      anchors.leftMargin: Style.space(8)
      anchors.right: durationText.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 1
        text: trackRow.track ? String(trackRow.track.title || "") : ""
        color: root.textColor
        font.bold: trackRow.playing
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        elide: Text.ElideRight
        maximumLineCount: 1
        text: {
          if (!trackRow.track) return ""
          var artist = String(trackRow.track.artist || "")
          var more = String(trackRow.track.subtitle || "")
          return more !== "" ? (artist !== "" ? artist + " · " + more : more) : artist
        }
        color: root.dim
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
    }

    // A heart on every row: the same glyph the player uses, filled when the track is in
    // «Моя музыка». Right-click on the row still opens the queue menu, so the heart is
    // a plain left-click target of its own.
    // The glyph is 14 px wide inside a 26 px target, so its painted right edge sits six
    // pixels in from the target's. A 14 px wrapper makes the edge of the icon the edge of
    // the box: the row's right padding is then exactly Style.space(8), the same as the
    // number's left padding, and nothing depends on how a control centres its icon.
    Item {
      // The right padding mirrors the left one: eight, the glyph column's twenty and the
      // four before the cover, so 32 on both sides. Symmetry is worth the width here —
      // the alternative was a cover that jumps when the play glyph appears.
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(14)
      height: trackRow.height

      BarGlyph {
        anchors.fill: parent
      name: "heart"
        fillOnHover: true
        filled: root.isLiked(trackRow.track)
        iconColor: root.isLiked(trackRow.track) ? Color.accent : (trackRow.playing ? Color.accent : root.dim)
        tooltip: root.isLiked(trackRow.track) ? root.t("Убрать из моей музыки") : root.t("В мою музыку")
        onClicked: root.toggleLikeFor(trackRow.track)
      }
    }

    MouseArea {
      id: trackArea
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.RightButton) trackRow.contextRequested()
        else trackRow.activated()
      }
    }
  }

  // A playlist as a row: its cover, its name, and how long it is. The cover is the
  // small one VK keeps for exactly this, so a list of thirty rows costs thirty
  // thumbnails rather than thirty covers, and the text sits on two lines so a long
  // name has somewhere to go instead of being cut off after the first few words.
  component PlaylistRows: Column {
    id: rows
    property var items: []
    signal picked(int index)

    function itemAt(index) { return rowRepeater.itemAt(index) }

    width: parent ? parent.width : 0
    spacing: Style.space(2)

    Repeater {
      id: rowRepeater
      model: rows.items
      delegate: Item {
        id: row
        // The same name the other rows use, so the state can be read rather than
        // inferred from the fill.
        property bool selected: index === root.cursor

        width: rows.width
        height: Style.space(44)

        // The cursor's fill, the same language as a filled row anywhere else.
        BorderSurface {
          anchors.fill: parent
          anchors.leftMargin: -root.cardInset
          anchors.rightMargin: -root.cardInset
          radius: 0
          color: row.selected
            ? Style.selectedFillFor(Color.foreground, Color.accent)
            : Style.normalFillFor(Color.foreground, Color.accent)
          borderSpec: Border.none()
          visible: row.selected || rowArea.containsMouse
        }

        CoverTile {
          id: rowCover
          width: Style.space(28)
          height: width
          anchors.left: parent.left
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          inset: Style.space(1)
          decodeSize: Style.space(28)
          source: modelData
            ? String(modelData.cover_small || modelData.cover || "")
            : ""
          title: modelData ? String(modelData.title || "") : ""
        }

        Column {
          anchors.left: rowCover.right
          anchors.leftMargin: Style.space(8)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            maximumLineCount: 1
            text: modelData ? (root.sectionName(root.sourceSlug(modelData)) || String(modelData.title || "")) : ""
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            elide: Text.ElideRight
            text: modelData && modelData.count
              ? (Number(modelData.count) + " "
                 + root.plural(Number(modelData.count), root.t("трек"), root.t("трека"), root.t("треков")))
              : ""
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          id: rowArea
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: rows.picked(index)
        }
      }
    }
  }

  // And the gallery: the same items, as covers.
  component PlaylistGrid: Grid {
    id: grid
    property var items: []
    // The same two lines of caption as a person card, for the same reason: the card's
    // height decides how many rows fit, and the width must not feed back into it.
    TextMetrics {
      id: cellTitleLine
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      text: "Ag"
    }
    TextMetrics {
      id: cellCountLine
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      text: "Ag"
    }
    readonly property real captionBlock:
      cellTitleLine.height + cellCountLine.height + 2 * Style.space(3)
    // How many cards across and how wide each of them is: both come from
    // `GalleryFit.plan`, where the arithmetic is tested. A gallery with fewer playlists
    // than columns stretches its cards to the width it has instead of leaving a hole at
    // the right edge.
    // Measured against the rim, not against the padding the table ends up with: the
    // padding is derived from the plan below, and a plan derived from the padding that
    // depends on it is a binding loop.
    readonly property real usable: grid.width - 2 * grid.rim
    readonly property var plan: GalleryFit.plan(usable, root.galleryColumns,
      spacing, captionBlock, items.length)
    readonly property real cellWidth: plan.cellWidth
    // What the columns actually take, and then the same air on both sides of them. Left to
    // the grid, the leftover of the column arithmetic all landed on the right, so a
    // gallery had a wider margin on one side than on the other.
    readonly property real tableWidth: plan.columns * plan.cellWidth
      + Math.max(0, plan.columns - 1) * spacing
    signal picked(int index)

    function itemAt(index) { return cellRepeater.itemAt(index) }

    width: parent ? parent.width : 0
    columns: plan.columns
    spacing: Style.space(6)
    // The selected fill reaches a few pixels past its card, so the grid keeps a rim of
    // its own — otherwise the first column's fill is cut by the edge of the list.
    // The rim keeps a selected card's fill from being cut by the list's edge. The card's
    // own inset is on top of it now that the list runs edge to edge: the gallery is not a
    // row, and a wall of covers flush with the card reads as a crop, not as a gallery.
    readonly property real rim: root.cardRim
    leftPadding: Math.max(rim, Math.round((width - tableWidth) / 2))
    rightPadding: leftPadding

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

  // What a right-click on a track row offers. It floats over the panel, anchored
  // to the bottom of the key catcher, so nothing moves when it appears.
  component RowMenu: BorderSurface {
    id: rowMenu
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(10)
    radius: Style.space(6)
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
        text: root.pendingIndex >= 0 ? root.t("Играть сейчас") : root.t("В очередь")
        foreground: root.textColor
        tooltipText: root.pendingIndex >= 0
          ? root.t("Перейти к этому треку")
          : root.t("Добавить в конец очереди")
        onClicked: if (root.pendingIndex >= 0) root.jumpPending()
          else root.queuePendingTrack(false)
      }

      Button {
        text: root.pendingIndex >= 0 ? root.t("Убрать") : root.t("Следующим")
        foreground: root.textColor
        tooltipText: root.pendingIndex >= 0
          ? root.t("Убрать из очереди")
          : root.t("Поставить сразу после текущего трека")
        onClicked: if (root.pendingIndex >= 0) root.removePending()
          else root.queuePendingTrack(true)
      }

      Button {
        iconText: "󰅖"
        foreground: root.textColor
        tooltipText: root.t("Отмена")
        onClicked: root.closeRowMenu()
      }
    }
  }

  // One line of key hints under the list, above the loading line, which stays the
  // bottom edge of the card.
  component TrackList: ColumnLayout {
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
    property alias friendsGrid: friendsGrid
    property alias recentGrid: recentGrid
    // The rows as well as the cards: with the gallery off the people are rows, and
    // the cursor needs to find them by index. Without these two the lookup threw and
    // took the whole movement with it.
    property alias friendRepeater: friendRepeater
    property alias recentPeopleRepeater: recentPeopleRepeater
    property alias browsePlaylistRows: browsePlaylistRows
    property alias playlistTrackRepeater: playlistTrackRepeater
    property alias searchGrid: searchGrid
    property alias searchPlaylistRows: searchPlaylistRows
    // The parts of a Flickable the cursor and the diagnostics use, so the list can
    // be a column with a header that does not scroll.
    property alias contentY: scroller.contentY
    property alias contentHeight: scroller.contentHeight
    // The item contentY counts in. Delegates are grandchildren of it at best — a
    // card in a grid, a track row in a block — so their own y is not a scroll
    // position and the reveal has to map into this before comparing.
    property Item contentRoot: scroller.contentItem
    property Item scrollerItem: scroller
    // The scrolling viewport is the inner Flickable, which is shorter than this
    // component by the sticky row above it. Scrolling maths that used the component's
    // own height was off by exactly that much and left the last row half hidden.
    property alias viewHeight: scroller.height

    Layout.fillWidth: true
    Layout.fillHeight: true
    visible: root.signedIn
    spacing: Style.space(4)

    // A gallery fills the list across, and it fills it down as well: the cards take the
    // width the columns give them and the gap between rows grows until a whole number
    // of rows fits the room. Nothing is cut by the bottom edge, and no strip of
    // background is left over to be filled with nothing.
    property bool isTrackList: true
    // What sits in the scroll above the grid: the air under the heading. The grid's own
    // `y` is its parent's, not a scroll position, so it is mapped into the content item
    // — the same mapping the cursor reveal does. The sections used to stand here, and
    // at a hundred pixels they were the reason a gallery could not align with either
    // edge of the scroll.
    readonly property real galleryRowOffset: {
      var gallery = activeGallery()
      if (!gallery) return 0
      var top = gallery.mapToItem(listColumn, 0, 0).y
      return top > 0 ? top : 0
    }
    // The height the scroller would take if it simply filled the column: what is left
    // of the column after the sticky heading, its separator and the section chips.
    readonly property real roomHeight: {
      var used = 0
      var chrome = 0
      for (var i = 0; i < children.length; i++) {
        var child = children[i]
        if (!child.visible || child === scroller) continue
        // The measured height, not the implicit one: a Flickable has no implicit height
        // at all, and the section chips are exactly that — a row of buttons that scroll
        // sideways. Counting it as zero made the room a row too big.
        used += Math.max(child.implicitHeight, child.height)
        chrome++
      }
      // One gap between each of those and its neighbour, the scroller included.
      return Math.max(0, view.height - used - chrome * spacing)
    }
    // The gallery's size, as a value that changes when there is something new to align.
    readonly property string gallerySignature: {
      var gallery = activeGallery()
      if (!gallery) return ""
      return [gallery.plan.columns, gallery.plan.cellRows,
        Math.round(gallery.plan.cellWidth), Math.round(gallery.captionBlock)].join(":")
    }
    // The card is a fixed height, and a gallery wants it to end where a row ends. The
    // height is nudged by the leftover, once, from here — a binding from the card's
    // height to the room it gives the list would be a loop, and QML would break it at
    // the wrong moment.
    //
    // Upwards, never down: a card one row taller shows one row more, while a card cut
    // down to the rows of a short gallery would change height for every section the user
    // looks at. What does not fit is left under the last row, where it reads as air.
    function alignGallery() {
      // The room the card grows by belongs to the popup, and the popup has one list on
      // screen: the other body's copy of this list would reset it to zero every frame.
      if (view !== root.activeList()) return
      var gallery = activeGallery()
      if (!gallery || !gallery.plan.cellWidth) {
        root.setGalleryRoom(0)
        return
      }
      var block = gallery.plan.cellWidth + gallery.captionBlock
      var gap = gallery.spacing
      // Counted without what the card already grew by: asked from the current room, every
      // answer would find the next row worth asking for, and the card would climb to the
      // height of the screen one row at a time.
      var space = roomHeight - galleryRowOffset - root.galleryRoom
      var rows = gallery.plan.cellRows
      var now = GalleryFit.wholeRoom(space, block, gap, rows)
      if (now.rows < 1 || now.rows >= rows) {
        root.setGalleryRoom(0)
        return
      }
      // One row more is worth asking for: the next row needs a card and a gap, and what
      // it does not use is the height the card is missing today.
      var next = GalleryFit.wholeRoom(space + block + gap, block, gap, rows)
      root.setGalleryRoom(next.rows > now.rows ? next.height - space : 0)
    }
    onGallerySignatureChanged: Qt.callLater(alignGallery)
    onRoomHeightChanged: Qt.callLater(alignGallery)
    onGalleryRowOffsetChanged: Qt.callLater(alignGallery)
    Component.onCompleted: Qt.callLater(alignGallery)
    // A grid is on screen only when every block it sits in is: the popup holds two
    // bodies, and the one that is not showing keeps its own copy of the same ids. Only
    // an ancestor that is drawn has a row to leave whole.
    function effectiveVisible(item) {
      var node = item
      while (node && node !== root) {
        if (!node.visible) return false
        node = node.parent
      }
      return true
    }
    // The gallery that is on screen, if the list is showing one: the cursor walks one
    // list at a time, and only a grid that is drawn has a row to leave whole.
    function activeGallery() {
      var grids = [browseGrid, searchGrid, friendsGrid, recentGrid]
      for (var i = 0; i < grids.length; i++) {
        var gallery = grids[i]
        // Visibility, not size: the gallery's own width comes from the room this list
        // gives it, and asking for that width here would make the two bindings a loop.
        if (gallery && effectiveVisible(gallery)) return gallery
      }
      return null
    }

    // The sections are a way around the catalog, not part of what the list holds. Kept
    // in the scroll they scrolled away, and their hundred pixels stood between the top
    // of the list and the first card — which is what made a gallery align with neither
    // edge of the scroll once the cursor moved. Out here they are always reachable, and
    // the grid starts at the same place whatever the section shows.
    //
    // It is a bar of cells like the one at the top of the card: flush, square, from the
    // card's edge to its edge, with no inset of its own — and the two cells that choose
    // how a list of playlists is drawn at its right end. They belong here rather than up
    // there: they say how THIS list is drawn, and they sit where the list starts.
    // The bar over the list, framed by the same rule that closes the player: one line
    // above the cells and one under them, both flush with them. A gap between a rule and
    // the cells it separates makes the rule look like the bottom border of the block
    // above rather than the top of this one.
    ColumnLayout {
      id: sectionBand
      Layout.fillWidth: true
      spacing: 0

      PanelSeparator { Layout.fillWidth: true; foreground: root.textColor }

      RowLayout {
        id: sectionBar
        Layout.fillWidth: true
        spacing: 0
        // The catalog's sections in the browse view, the two kinds of answer a search can
        // give in the search view, and at the right either way the two cells that choose how
        // a list of playlists is drawn. Both kinds of content are cells of this one bar, so
        // the bar is flush with the card and neither of them carries a margin of its own.
        visible: (root.view === "browse" && root.openPlaylist === null) || root.view === "search"

        Flickable {
          id: sectionChips
          visible: root.view === "browse"
          Layout.fillWidth: true
          Layout.preferredHeight: sectionChipRow.height
          contentWidth: sectionChipRow.width
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          // The sections as cells of a bar, the way the views at the top of the card are
          // drawn — square, flush, the one in use filled — and without icons, because a
          // section's name is the whole of it.
          Row {
            id: sectionChipRow
            spacing: 0

            // First, and deliberately: choosing a person is a way in, not a
            // section, and it must not hide behind a scrolling row.
            BarCell {
              width: implicitWidth
              text: root.t("Люди")
              selected: root.effectiveBrowse() === "friends" || root.effectiveBrowse() === "person"
              tooltipText: root.t("Друзья и любой человек по ссылке — их плейлисты")
              onClicked: root.browseFriends()
            }

            Repeater {
              model: root.sources
              delegate: BarCell {
                width: implicitWidth
                text: modelData ? (root.sectionName(root.sourceSlug(modelData)) || String(modelData.title || "")) : ""
                selected: modelData ? root.sourceSlug(modelData) === root.effectiveBrowse() : false
                onClicked: if (modelData) {
                  root.browseSource(root.sourceSlug(modelData))
                  root.focusList()
                }
              }
            }
          }
        }

        // What a search can answer with: two equal halves of what the tools leave, because
        // a switch of two equal halves reads as a choice between two things, where two cells
        // hugging their labels read as two buttons.
        BarCell {
          visible: root.view === "search"
          Layout.fillWidth: true
          Layout.preferredWidth: 0
          Layout.minimumWidth: 0
          Layout.preferredHeight: root.barCellHeight
          text: root.t("Треки")
          selected: root.searchMode === "tracks"
          onClicked: root.setSearchMode("tracks")
        }

        BarCell {
          visible: root.view === "search"
          Layout.fillWidth: true
          Layout.preferredWidth: 0
          Layout.minimumWidth: 0
          Layout.preferredHeight: root.barCellHeight
          text: root.t("Плейлисты")
          selected: root.searchMode === "playlists"
          tooltipText: root.t("Искать плейлисты других людей")
          onClicked: root.setSearchMode("playlists")
        }

        // Only where something has two representations: «Моя музыка» is a hundred tracks
        // and no playlists, so neither these two cells nor their keys may claim otherwise.
        BarDivider {
          visible: root.playlistsShown
          Layout.preferredHeight: root.barCellHeight
        }

        BarCell {
          visible: root.playlistsShown
          Layout.preferredWidth: root.barCellHeight
          Layout.preferredHeight: root.barCellHeight
          horizontalPadding: 0
          iconText: "󰕳"
          selected: root.gridView
          tooltipText: root.t("Галерея обложек")
          onClicked: root.setPlaylistView("grid")
        }

        BarCell {
          visible: root.playlistsShown
          Layout.preferredWidth: root.barCellHeight
          Layout.preferredHeight: root.barCellHeight
          horizontalPadding: 0
          iconText: "󰉹"
          selected: !root.gridView
          tooltipText: root.t("Список")
          onClicked: root.setPlaylistView("list")
        }
      }

      // Closing the band, and only when the cells are there to close:
      // the rule above is the player's own edge in every other view.
      PanelSeparator {
        Layout.fillWidth: true
        foreground: root.textColor
        visible: sectionBar.visible
      }
    }

    Flickable {
      id: scroller
      Layout.fillWidth: true
      Layout.fillHeight: true
      clip: true
      contentWidth: width
      contentHeight: listColumn.implicitHeight
      boundsBehavior: Flickable.StopAtBounds

    Column {
      id: listColumn
      // Air above the first row even when the heading above is empty: otherwise a
      // selected row's fill touches the selected tab's fill and the two read as one.
      Item { width: 1; height: Style.space(10) }

      // The scroller is the width of the card and the column inside it is inset by
      // `cardInset`: text, headings, grids and switches keep the card's own margin, and a
      // row's FILL is the one thing allowed to bleed wider than its parent — out to the
      // card's edge, which is where a selected row has to end. The bleed is paint: the
      // row itself, with its MouseArea, stays inside its parent like every other control.
      x: root.cardInset
      width: scroller.width - 2 * root.cardInset
      spacing: Style.space(4)

      // Queue: the sources that fill it, then the next few tracks.
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.view === "queue"

        Row {
          spacing: Style.space(6)

          Button {
            text: root.t("Моя музыка")
            foreground: root.textColor
            onClicked: root.playSection("all", root.t("Моя музыка"))
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

        Repeater {
          id: queueRepeater
          model: root.filtered(root.upcoming)
          delegate: TrackRow {
            track: modelData
            position: root.upcomingStart + index + 1
            selected: index === root.cursor
            onActivated: root.playQueueAt(root.indexOfItem(root.queue, modelData))
            onContextRequested: root.openRowMenu(modelData, root.indexOfItem(root.queue, modelData))
          }
        }

        Text {
          visible: root.queue.length === 0 && !root.queueLoading
          textFormat: Text.PlainText
          text: root.t("Очередь пуста. Начни с «Моя музыка».")
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
        visible: root.view === "browse" && root.openPlaylist === null

        // The sections are out of the scroll (see above): the list starts with what the
        // section holds, so the gallery's first row is the list's first row.
        PlaylistGrid {
          id: browseGrid
          items: root.filtered(root.browsePlaylists)
          visible: root.gridView && items.length > 0
          onPicked: function(index) {
            root.openPlaylistView(root.filtered(root.browsePlaylists)[index])
          }
        }

        PlaylistRows {
          id: browsePlaylistRows
          items: root.gridView ? [] : root.filtered(root.browsePlaylists)
          onPicked: function(index) {
            root.openPlaylistView(root.filtered(root.browsePlaylists)[index])
          }
        }

        // A RowLayout rather than a Row: a caption in a plain Row sits at the top
        // of the line while the buttons sit in the middle of it, and the two never
        // look aligned. The caption takes the free width, so whatever follows it
        // ends up against the right edge.
        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          visible: root.browseSlug === ""
          text: root.t("Выбери раздел: подборки, новинки, эфир.")
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
              placeholderText: root.t("Ссылка, id или имя друга")
              text: root.personQuery
              onTextChanged: root.personQuery = text
              onAccepted: root.openPersonFromField()
            }

            Button {
              id: personGo
              text: root.t("Открыть")
              foreground: root.textColor
              enabled: root.personQuery.trim() !== ""
              opacity: enabled ? 1.0 : 0.4
              onClicked: root.openPersonFromField()
            }
          }

          PanelSectionHeader {
            text: root.t("Друзья")
            foreground: root.dim
            visible: root.friends.length > 0
          }

          PeopleGrid {
            id: friendsGrid
            items: root.gridView ? root.friends : []
            visible: items.length > 0
            onPicked: function(index) {
              if (root.friends[index]) root.openPerson(String(root.friends[index].id))
            }
          }

          Repeater {
            id: friendRepeater
            model: root.gridView ? [] : root.friends
            delegate: PersonRow {
              item: modelData
              selected: index === root.cursor
              onActivated: if (modelData) root.openPerson(String(modelData.id))
            }
          }

          PanelSectionHeader {
            text: root.t("Недавние")
            foreground: root.dim
            visible: root.people.length > 0
          }

          PeopleGrid {
            id: recentGrid
            baseOffset: root.filtered(root.friends).length
            items: root.gridView ? root.people : []
            visible: items.length > 0
            onPicked: function(index) {
              if (root.people[index]) root.openPerson(String(root.people[index].id))
            }
          }

          Repeater {
            id: recentPeopleRepeater
            model: root.gridView ? [] : root.people
            delegate: PersonRow {
              item: modelData
              selected: (root.filtered(root.friends).length + index) === root.cursor
              onActivated: if (modelData) root.openPerson(String(modelData.id))
            }
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            visible: !root.friendsLoading && root.friends.length === 0 && root.people.length === 0
            text: root.t("Список друзей пуст. Вставь ссылку на человека — например vk.com/id213706100.")
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
          model: root.browseSlug === "radiostations" ? [] : root.filtered(root.browseTracks)
          delegate: TrackRow {
            track: modelData
            selected: (root.browseCursorOffset() + index) === root.cursor
            onActivated: if (modelData) root.playBrowseTrack(root.indexOfItem(root.browseTracks, modelData))
            onContextRequested: root.openRowMenu(modelData)
          }
        }

        Button {
          width: listColumn.width
          leftAlign: true
          visible: root.browseNext !== ""
          enabled: !root.browseMoreLoading
          opacity: enabled ? 1.0 : 0.5
          text: root.t("Ещё")
          foreground: root.textColor
          onClicked: root.browseMore()
        }
      }

      // One playlist, opened: its tracks, with a way back and a way to play the
      // whole thing. Clicking a track queues the playlist from that track.
      Column {
        width: parent.width
        spacing: Style.space(4)
        // Opened from a search or from a section: the tracks replace whatever the
        // view was showing, so a click always has something to show for itself.
        visible: (root.view === "browse" || root.view === "search") && root.openPlaylist !== null

        // The tracks are a list, not more controls: the line says so.
        Repeater {
          id: playlistTrackRepeater
          model: root.filtered(root.openPlaylistTracks)
          delegate: TrackRow {
            track: modelData
            position: index + 1
            selected: index === root.cursor
            onActivated: root.playPlaylistTrack(root.indexOfItem(root.openPlaylistTracks, modelData))
            onContextRequested: root.openRowMenu(modelData)
          }
        }

        Text {
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          visible: root.openPlaylistLoading && root.openPlaylistTracks.length === 0
          text: root.t("Открываю плейлист…")
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }
      }

      // Search: suggestions while typing, results once a search has run.
      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.view === "search" && root.openPlaylist === null

        Text {
          visible: root._queryLength < 2 && root.history.length === 0
          width: parent.width
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          text: root.t("Начни печатать — подсказки ВК появятся сами, поиск пойдёт после паузы")
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
        }

        // What was searched before, offered back while the field is empty.
        PanelSectionHeader {
          text: root.t("Недавние запросы")
          foreground: root.dim
          visible: root._queryLength < 2 && root.history.length > 0
        }

        Repeater {
          id: historyRepeater
          model: root._queryLength < 2 ? root.history : []
          delegate: SuggestionRow {
            text: modelData ? String(modelData) : ""
            selected: index === root.cursor
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
          onPicked: function(index) {
            root.openPlaylistView(root.filtered(root.foundPlaylists)[index])
          }
        }

        PlaylistRows {
          id: searchPlaylistRows
          items: (root.searchMode === "playlists" && !root.gridView) ? root.foundPlaylists : []
          onPicked: function(index) {
            root.openPlaylistView(root.filtered(root.foundPlaylists)[index])
          }
        }

        Repeater {
          id: suggestionRepeater
          model: root.suggestionsShown
          delegate: SuggestionRow {
            text: modelData ? String(modelData) : ""
            selected: index === root.cursor
            onClicked: if (modelData) root.searchSuggestion(String(modelData))
          }
        }

        Repeater {
          id: resultRepeater
          model: root.filtered(root.resultsShown)
          delegate: TrackRow {
            track: modelData
            selected: index === root.cursor
            onActivated: root.playSearchResult(root.indexOfItem(root.results, modelData))
            onContextRequested: root.openRowMenu(modelData)
          }
        }
      }

      // Settings. Every preference here lives in the backend: the widget only
      // sends the new value and re-reads the status, so the daemon stays the
      // one place that knows how the plugin behaves. The account block above
      // the preferences is not a preference — it reads and changes sessions.
      Column {
        width: parent.width
        spacing: Style.spacing.controlGap
        visible: root.view === "settings"

        PanelSectionHeader { text: root.t("Аккаунты"); foreground: root.dim }

        AccountsBlock { width: parent.width }

        PanelSeparator { Layout.fillWidth: true; foreground: root.textColor }

        // Eight names never fit one row, and a row that scrolls is a row nobody scrolls.
        // One line with the current language, the rest behind a click.
        Dropdown {
          width: parent.width
          label: root.t("Язык")
          value: root.language
          options: I18n.LANGUAGES.map(function(entry) { return { value: entry.code, label: entry.name } })
          foreground: root.textColor
          onChanged: function(value) { root.setPreference("language", value) }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.textColor }

        PanelSectionHeader { text: root.t("Строка в баре"); foreground: root.dim }

        ToggleRow { label: root.t("Обложка трека"); key: "showArtwork"; on: root.prefs.showArtwork !== false }
        ToggleRow { label: root.t("Название трека"); key: "showTitle"; on: root.prefs.showTitle !== false }
        ToggleRow { label: root.t("Исполнитель"); key: "showArtist"; on: root.prefs.showArtist !== false }
        ToggleRow { label: root.t("Кнопки управления"); key: "showControls"; on: root.prefs.showControls !== false }
        ToggleRow { label: root.t("Линия прогресса"); key: "showProgress"; on: root.prefs.showProgress !== false }
        ToggleRow { label: root.t("Время трека"); key: "showTime"; on: root.prefs.showTime === true }
        ToggleRow { label: root.t("Кнопка «Нравится»"); key: "showLike"; on: root.prefs.showLike === true }

        ChoiceRow {
          label: root.t("Форма обложки")
          key: "coverShape"
          value: String(root.prefs.coverShape || "rounded")
          options: [
            { value: "square", label: root.t("Квадрат") },
            { value: "rounded", label: root.t("Скруглённая") },
            { value: "circle", label: root.t("Круг") }
          ]
        }

        ChoiceRow {
          label: root.t("Длинные названия")
          key: "longTitleMode"
          value: String(root.prefs.longTitleMode || "scroll")
          options: [
            { value: "truncate", label: root.t("Обрезать") },
            { value: "scroll", label: root.t("Прокрутка") }
          ]
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          // Both matter only while the label scrolls.
          opacity: root.barLongTitle === "scroll" ? 1.0 : 0.4

          Text {
            text: root.t("Пауза перед прокруткой")
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
            text: root.t("Скорость прокрутки")
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
            text: root.t("Ширина подписи")
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          RowLayout {
            width: parent.width
            spacing: 0

            Repeater {
              model: [
                { value: 120, label: root.t("Узкая") },
                { value: 180, label: root.t("Обычная") },
                { value: 260, label: root.t("Широкая") }
              ]
              delegate: BarCell {
                Layout.fillWidth: true
                Layout.preferredWidth: 0
                Layout.minimumWidth: 0
                Layout.preferredHeight: root.barCellHeight
                text: modelData ? String(modelData.label) : ""
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

        // Out of the column's inset and across the card: see the heading separator.
        PanelSeparator {
          x: -root.cardInset
          width: parent.width + 2 * root.cardInset
          foreground: root.textColor
        }

        PanelSectionHeader { text: root.t("Попап"); foreground: root.dim }

        ChoiceRow {
          label: root.t("Вид попапа")
          key: "popupView"
          value: String(root.prefs.popupView || "compact")
          options: [
            { value: "compact", label: root.t("Компактный") },
            { value: "extended", label: root.t("Расширенный") }
          ]
        }

        // Out of the column's inset and across the card: see the heading separator.
        PanelSeparator {
          x: -root.cardInset
          width: parent.width + 2 * root.cardInset
          foreground: root.textColor
        }

        PanelSectionHeader { text: root.t("Воспроизведение"); foreground: root.dim }

        ToggleRow {
          label: root.t("Скачивать следующий трек заранее — переключение без паузы")
          key: "prefetchEnabled"
          on: root.prefs.prefetchEnabled !== false && root.prefs.cacheEnabled !== false
          dim: root.prefs.cacheEnabled === false
        }

        Text {
          text: root.t("Возвращать при запуске")
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Row {
          spacing: Style.space(6)

          ChipToggle { text: root.t("Очередь"); key: "restoreQueue"; on: root.prefs.restoreQueue !== false }
          ChipToggle { text: root.t("Позицию"); key: "restorePosition"; on: root.prefs.restorePosition !== false }
          ChipToggle { text: root.t("Громкость"); key: "restoreVolume"; on: root.prefs.restoreVolume !== false }
        }

        // Out of the column's inset and across the card: see the heading separator.
        PanelSeparator {
          x: -root.cardInset
          width: parent.width + 2 * root.cardInset
          foreground: root.textColor
        }

        PanelSectionHeader { text: root.t("Уведомления"); foreground: root.dim }

        ChoiceRow {
          label: root.t("Уведомлять о смене трека")
          key: "notifications"
          value: String(root.prefs.notifications || "off")
          options: [
            { value: "off", label: root.t("Нет") },
            { value: "all", label: root.t("Показывать") }
          ]
        }

        // Out of the column's inset and across the card: see the heading separator.
        PanelSeparator {
          x: -root.cardInset
          width: parent.width + 2 * root.cardInset
          foreground: root.textColor
        }

        PanelSectionHeader { text: root.t("Кеш"); foreground: root.dim }

        ToggleRow {
          label: root.t("Хранить треки на диске · ")
            + root.megabytes(root.status.cache ? root.status.cache.bytes : 0)
            + " из " + root.megabytes(root.status.cache ? root.status.cache.limit_bytes : 0)
            + (root.status.cache && root.status.cache.files ? root.t(" · файлов ") + root.status.cache.files : "")
          key: "cacheEnabled"
          on: root.prefs.cacheEnabled !== false
        }

        Row {
          width: parent.width
          spacing: Style.space(8)
          visible: root.prefs.cacheEnabled !== false

          Text {
            text: root.t("Лимит кеша")
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
            text: root.t("Освободить место прямо сейчас")
            color: root.dim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Button {
            id: clearButton
            text: root.t("Очистить кеш")
            foreground: root.textColor
            onClicked: root.call([root.cli, "cache", "clear"], function() { root.refresh() })
          }
        }
      }

    }
    }

    // The status bar: what the list is showing, how much of it there is, and the two
    // things that can be done with it — under the list and behind a full-width rule.
    // It used to be a heading above the first row, which cost the list a line and made
    // the list's own state look like the first thing in the list.
    //
    // The rule and the cells are one band with nothing between them, and the cells run to
    // the card's own edge: the bar that closes the card is drawn like the one that opens
    // it — a divider before each cell that is a tool, no margins anywhere.
    ColumnLayout {
      id: statusBand
      Layout.fillWidth: true
      spacing: 0

      PanelSeparator { Layout.fillWidth: true; foreground: root.textColor }

      RowLayout {
        id: statusBar
        Layout.fillWidth: true
        Layout.preferredHeight: root.topBarHeight
        spacing: 0

        // The way back, when there is one: an open playlist or a person's page — and only in
        // the view they were opened from, or the queue would offer a way back to somebody
        // else's playlists.
        BarCell {
          visible: root.view === "browse" && !root.filtering
            && (root.openPlaylist !== null || root.person !== null)
          Layout.preferredHeight: root.topBarHeight
          text: root.t("Назад")
          tooltipText: root.openPlaylist !== null ? root.t("К плейлистам") : root.t("К списку людей")
          onClicked: {
            if (root.openPlaylist !== null) {
              root.closePlaylistView()
              return
            }
            root.closePerson()
            root.browseFriends()
          }
        }

        // Vim's «/»: the field takes the status line while a filter is being typed, the list
        // above shrinks to what matches, and Enter hands the keyboard back to the list.
        TextField {
          id: filterField
          Layout.fillWidth: true
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: root.cardInset
          Layout.alignment: Qt.AlignVCenter
          visible: root.filtering
          placeholderText: root.t("Фильтр по списку: название или исполнитель")
          text: root.filter
          // Vim-like: «/» puts you in the field, Enter leaves it, Esc clears it.
          onVisibleChanged: if (visible) forceActiveFocus()
          onActiveFocusChanged: root.filterFocused = activeFocus
          onTextChanged: root.filter = text
          onAccepted: {
            root.filtering = false
            root.focusList()
          }
          Keys.onEscapePressed: function(event) {
            root.clearFilter()
            event.accepted = true
          }
        }

        // What the list is: «Друзья · 3 человека», «Главная · 54 трека · 3ч 44мин»,
        // «Моя музыка · загрузка…» — and a complaint from the daemon when there is one,
        // which wins the line because it is the thing the reader cannot guess.
        Text {
          Layout.fillWidth: true
          Layout.preferredWidth: 0
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: Style.space(8)
          Layout.alignment: Qt.AlignVCenter
          visible: !root.filtering
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: root.statusText !== "" ? root.statusText : root.listHeading()
          color: root.statusUrgent ? Color.urgent : root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        BarDivider {
          visible: !root.filtering && root.listAction() !== ""
          Layout.preferredHeight: root.topBarHeight
        }

        BarCell {
          visible: !root.filtering && root.listAction() !== ""
          Layout.preferredHeight: root.topBarHeight
          text: root.listAction()
          tooltipText: root.listAction() === root.t("Играть")
            ? root.t("Играть весь плейлист")
            : root.t("Очистить очередь")
          enabled: root.listAction() === root.t("Играть")
            ? root.openPlaylistTracks.length > 0
            : root.queue.length > 0
          opacity: enabled ? 1.0 : 0.4
          onClicked: {
            if (root.listAction() === root.t("Играть")) root.playPlaylistTrack(0)
            else root.clearQueue()
          }
        }

        BarDivider { Layout.preferredHeight: root.topBarHeight }

        // The key sheet's button, one more cell of the bar and the last one, so it carries
        // the card's corner the way the cell at the bar's other end does.
        BarCell {
          Layout.preferredWidth: root.topBarHeight
          Layout.preferredHeight: root.topBarHeight
          horizontalPadding: 0
          bottomRightRadius: root.cardCorner
          iconText: "?"
          tooltipText: root.t("Горячие клавиши")
          onClicked: root.hintsOpen = !root.hintsOpen
        }
      }
    }

  }

  // The key sheet the question mark opens: a sheet over the card rather than a line under
  // the list, because the line could be read at a glance and taught nothing, and because
  // the keys it could not fit are the ones a beginner needs most.
  component HintsPanel: Item {
    id: hintsPanel
    anchors.fill: parent
    visible: root.hintsOpen

    // The sheet is a dialog: the list behind it does not take clicks while it is up, which
    // is also what makes «click anywhere to close» work.
    Rectangle {
      anchors.fill: parent
      color: Color.popups.background
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.hintsOpen = false
    }

    RowLayout {
      id: hintsHeader
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: root.barCellHeight
      spacing: 0

      Text {
        Layout.leftMargin: root.cardInset
        Layout.alignment: Qt.AlignVCenter
        textFormat: Text.PlainText
        text: root.t("Горячие клавиши")
        color: root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: true
      }

      Item { Layout.fillWidth: true }

      BarCell {
        Layout.preferredWidth: root.barCellHeight
        Layout.preferredHeight: root.barCellHeight
        horizontalPadding: 0
        iconText: "󰅖"
        tooltipText: root.t("Закрыть")
        onClicked: root.hintsOpen = false
      }
    }

    BarEdge {
      id: hintsRule
      anchors.top: hintsHeader.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      visible: root.signedIn
    }

    Flickable {
      anchors.top: hintsRule.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      clip: true
      contentWidth: width
      contentHeight: hintsColumn.implicitHeight + 2 * root.cardInset
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: hintsColumn
        x: root.cardInset
        y: root.cardInset
        width: hintsPanel.width - 2 * root.cardInset
        spacing: Style.space(10)

        Repeater {
          model: root.keyHelpRows
          delegate: RowLayout {
            required property var modelData
            width: parent.width
            spacing: Style.space(12)

            // The key column is a fixed width, so the descriptions line up under each
            // other instead of following the length of each key.
            Text {
              Layout.preferredWidth: Style.space(90)
              Layout.alignment: Qt.AlignTop
              textFormat: Text.PlainText
              text: modelData.keys
              color: root.textColor
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }

            Text {
              Layout.fillWidth: true
              Layout.preferredWidth: 0
              textFormat: Text.PlainText
              wrapMode: Text.WordWrap
              text: modelData.what
              color: root.dim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }
        }
      }
    }
  }

  component SignInBlock: ColumnLayout {
    Layout.fillWidth: true
    spacing: Style.spacing.controlGap
    visible: !root.signedIn

    Text {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: root.t("Нужен вход в VK. Возьмите cookie из браузера или войдите по логину и паролю — подойдёт любой аккаунт.")
      color: root.textColor
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }

    AccountLoginForm { Layout.fillWidth: true }
  }

  // Album art in the two sizes the popup uses. The buffering indicator lives
  // here so both sizes keep exactly the same one.
  component CoverArt: BorderSurface {
    id: coverArt
    property real size: Style.space(64)
    // A framed cover is a picture inside a rim, the way every other card in the panel
    // draws one. The compact player follows its reference and draws the picture bare:
    // no rim, no inset between the rim and the picture, square corners.
    property bool framed: true

    width: size
    height: size
    radius: coverArt.framed ? Style.spacing.labelGap : 0
    color: Style.normalFillFor(root.textColor, Color.accent)
    borderSpec: root.buffering || !coverArt.framed
      ? Border.none()
      : Border.controlSpec("normal", root.textColor, Color.accent)

    CoverTile {
      anchors.fill: parent
      anchors.margins: coverArt.framed ? Style.space(2) : 0
      radius: Math.max(0, coverArt.radius - (coverArt.framed ? Style.space(2) : 0))
      inset: 0
      decodeSize: coverArt.size
      source: root.onAir()
        ? String(root.radioValue("logo", ""))
        : (root.hasTrack && root.trackValue("thumb", "") ? root.trackValue("thumb", "") : "")
      // A player with no art names what it is playing: the artist is what the eye
      // looks for when the picture is not there.
      title: root.onAir()
        ? String(root.radioValue("name", ""))
        : (root.hasTrack ? root.trackValue("artist", "") : "")
    }

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
      font.pixelSize: coverArt.size >= Style.space(100) ? Style.font.subtitle : Style.font.bodySmall
      font.bold: true
    }

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

  // The wide popup keeps its player to one band at the top: the cover, what it
  // is playing, and everything that controls it in a single row, with a thin
  // seek line under it. The list below gets the full width.
  component PlayerBar: ColumnLayout {
    id: playerBar
    spacing: Style.space(4)

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      visible: root.signedIn

      CoverArt {
        Layout.alignment: Qt.AlignVCenter
        size: Style.space(56)
      }

      ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: Style.space(110)
        Layout.alignment: Qt.AlignVCenter
        spacing: Style.space(1)

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: root.onAir()
            ? String(root.radioValue("name", root.t("Радио")))
            : (root.hasTrack ? root.trackValue("title") : root.t("Ничего не играет"))
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: root.onAir()
            ? root.t("Радио · в эфире")
            : (root.hasTrack
               ? (root.trackValue("artist", "") + (root.duration > 0
                  ? (root.trackValue("artist", "") ? " · " : "") + root.clock(root.displayPosition)
                    + " / " + root.clock(root.duration)
                  : ""))
               : "")
          color: root.dim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      GlyphButton {
        iconText: "󰒟"
        tint: root.shuffled ? Color.accent : root.textColor
        tooltipText: root.shuffled ? root.t("Перемешивание включено") : root.t("Перемешать")
        onClicked: root.toggleShuffle()
      }

      GlyphButton {
        iconText: root.repeatGlyph
        tint: root.repeatMode === "off" ? root.textColor : Color.accent
        tooltipText: root.repeatMode === "off" ? root.t("Повтор выключен")
          : (root.repeatMode === "one" ? root.t("Повторять трек") : root.t("Повторять очередь"))
        onClicked: root.cycleRepeat()
      }

      GlyphButton {
        iconText: "󰒮"
        tint: root.textColor
        enabled: root.queue.length > 0
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.skipPrevious()
      }

      GlyphButton {
        iconText: root.playing ? "󰏤" : "󰐊"
        tint: root.textColor
        enabled: root.hasTrack || root.queue.length > 0
        opacity: !enabled ? 0.4 : (root.loading ? 0.5 : 1.0)
        onClicked: root.togglePause()
      }

      GlyphButton {
        iconText: "󰒭"
        tint: root.textColor
        enabled: root.queue.length > 0
        opacity: enabled ? 1.0 : 0.4
        onClicked: root.skipNext()
      }

      GlyphButton {
        iconText: root.displayVolume <= 0 ? "󰝟" : "󰕾"
        tint: root.textColor
        tooltipText: root.displayVolume <= 0 ? root.t("Включить звук") : root.t("Выключить звук")
        onClicked: root.toggleMute()
      }

      // The heart sits at the right end, after everything that controls the sound:
      // it is not a transport control, it is a statement about the track. Lucide's
      // heart is an outline until the track is in «Моя музыка», then it is filled —
      // the same glyph the bar uses, so the two say the same thing the same way.
      Item {
        Layout.preferredWidth: Style.space(26)
        Layout.preferredHeight: Style.space(24)
        Layout.alignment: Qt.AlignVCenter
        visible: !root.onAir() && root.hasTrack

        BarGlyph {
          anchors.fill: parent
          name: "heart"
          fillOnHover: true
          filled: root.liked
          iconColor: root.liked ? Color.accent : root.textColor
          tooltip: root.liked ? root.t("Убрать из моей музыки") : root.t("В мою музыку")
          enabled: root.hasTrack
          onClicked: root.toggleLike()
        }
      }
      PanelSlider {
        Layout.preferredWidth: Style.space(84)
        Layout.alignment: Qt.AlignVCenter
        minimum: 0
        maximum: 100
        integer: true
        value: root.displayVolume
        bar: root.bar
        onMoved: function(value) { root.setVolume(value, true) }
        onReleased: function(value) { root.setVolume(value, false) }
      }

    }

    // The seek line: the one control that wants the whole width.
    PanelSlider {
      Layout.fillWidth: true
      visible: root.hasTrack && !root.onAir() && root.duration > 0
      minimum: 0
      maximum: Math.max(1, root.duration)
      value: root.displayPosition
      bar: root.bar
      onMoved: function(value) { root.seekLive(value) }
      onReleased: function(value) { root.seekFinal(value) }
    }
  }

  // The player, arranged the way VK's own player arranges it: the cover with what is
  // playing beside it and the heart at the far end; under them one row — transport, the
  // seek line with its two times under it, the speaker, and a menu. The arrangement is
  // the point: the title is read first, the times belong to the line they describe, and
  // the heart sits where the eye already is rather than at the end of a row of buttons.
  //
  // Shuffle, repeat and the volume slider did not fit that row and are not worth losing:
  // the menu button opens them as one more line under it.
  component PlayerColumn: ColumnLayout {
    id: playerColumn
    spacing: Style.spacing.controlGap

    // What is playing: cover, the three lines, and the heart at the right end. The
    // three lines are centred against the cover rather than hung from its top: the
    // cover is a fifth of the card's width now, and a block of text starting at the
    // picture's top edge would leave all of its air at the bottom.
    RowLayout {
      id: metaRow
      Layout.fillWidth: true
      spacing: Style.space(20)
      visible: root.signedIn

      CoverArt {
        id: playerCover
        Layout.alignment: Qt.AlignVCenter
        framed: false
        size: Style.space(91)
      }

      ColumnLayout {
        id: metaColumn
        Layout.fillWidth: true
        // Centred, not stretched: filling this column vertically made the
        // whole row swallow the height the list below needs, and the list —
        // the only thing here with `Layout.fillHeight` — was left 2 px tall.
        Layout.alignment: Qt.AlignVCenter
        // The lines are set by their own leading, not by extra air between them: the
        // reference's three lines are one block, and the bold title is what separates
        // the first from the two under it.
        spacing: Style.space(8)

        Text {
          id: titleText
          Layout.fillWidth: true
          textFormat: Text.PlainText
          elide: Text.ElideRight
          text: root.onAir()
            ? String(root.radioValue("name", root.t("Радио")))
            : (root.hasTrack ? root.trackValue("title") : root.t("Ничего не играет"))
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.heading * 1.1)
          font.bold: true
        }

        Text {
          id: artistText
          Layout.fillWidth: true
          textFormat: Text.PlainText
          elide: Text.ElideRight
          visible: root.hasTrack || root.onAir()
          text: root.onAir() ? root.t("Радио · в эфире") : root.trackValue("artist", "")
          // The artist is not a second headline and not a colour of its own: the
          // reference draws the three lines below the title in one weight and one
          // colour, and it is the bold title that separates them.
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.subtitle * 1.1)
        }

        Text {
          id: captionText
          Layout.fillWidth: true
          textFormat: Text.PlainText
          elide: Text.ElideRight
          // The record, or the position when there is no record: a line that is
          // always there and always says something. A live stream has neither.
          visible: root.signedIn && (root.hasTrack || root.onAir())
          text: root.captionLine()
          color: root.textColor
          font.family: Style.font.family
          font.pixelSize: Math.round(Style.font.subtitle * 1.05)
        }
      }

      // The heart sits at the far end of what is playing, on the block's own centre
      // line: it is not a control of the sound, it is a statement about the track.
      Item {
        Layout.preferredWidth: Style.space(24)
        Layout.preferredHeight: Style.space(24)
        Layout.alignment: Qt.AlignVCenter
        visible: root.hasTrack && !root.onAir()

        BarGlyph {
          anchors.fill: parent
          iconSize: Math.round(Style.font.iconLarge * 1.2)
          name: "heart"
          fillOnHover: true
          filled: root.liked
          iconColor: root.liked ? Color.accent : root.textColor
          tooltip: root.liked ? root.t("Убрать из моей музыки") : root.t("В мою музыку")
          onClicked: root.toggleLike()
        }
      }
    }

    // The controls: what a hand reaches for, in one line, with the seek line taking
    // whatever room is left between the transport and the two buttons at the right.
    RowLayout {
      id: controlsRow
      Layout.fillWidth: true
      // The reference leaves more air under the cover than between the controls
      // themselves: the picture and the row of buttons are two bands, not one block.
      Layout.topMargin: Style.space(17)
      spacing: Style.space(6)
      visible: root.signedIn

      GlyphButton {
        id: prevButton
        iconText: "󰒮"
        tint: root.textColor
        enabled: root.queue.length > 0
        opacity: enabled ? 1.0 : 0.4
        glyphSize: Math.round(Style.font.iconLarge * 1.1)
        tooltipText: root.t("Предыдущий трек")
        onClicked: root.skipPrevious()
      }

      // The one round control in the panel: the accent ring is where the eye looks
      // first, and a circle says «this is the play button» without a word. The box is
      // square because a circle drawn from a glyph's own width is an ellipse.
      Item {
        Layout.preferredWidth: Style.space(45)
        Layout.preferredHeight: Style.space(45)
        Layout.alignment: Qt.AlignVCenter

        Button {
          id: playButton
          anchors.fill: parent
          iconText: root.playing ? "󰏤" : "󰐊"
          foreground: Color.accent
          background: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.16)
          radius: width / 2
          bordered: true
          iconSize: Math.round(Style.font.iconLarge * 1.05)
          enabled: root.hasTrack || root.queue.length > 0
          opacity: !enabled ? 0.4 : (root.loading ? 0.5 : 1.0)
          tooltipText: root.playing ? root.t("Пауза") : root.t("Играть")
          onClicked: root.togglePause()
        }
      }

      GlyphButton {
        iconText: "󰒭"
        tint: root.textColor
        enabled: root.queue.length > 0
        opacity: enabled ? 1.0 : 0.4
        glyphSize: Math.round(Style.font.iconLarge * 1.1)
        tooltipText: root.t("Следующий трек")
        onClicked: root.skipNext()
      }

      // The seek line and its two times: under the line, where they describe it,
      // with the elapsed time at the start and what is left of the track at the end.
      ColumnLayout {
        Layout.fillWidth: true
        Layout.leftMargin: Style.space(16)
        Layout.rightMargin: Style.space(6)
        Layout.alignment: Qt.AlignVCenter
        spacing: 0
        visible: root.hasTrack && !root.onAir() && root.duration > 0

        PanelSlider {
          Layout.fillWidth: true
          // Seeking means nothing until the file is on disk: the position would
          // move the track that is still playing, not the one being fetched.
          enabled: !root.buffering
          opacity: root.buffering ? 0.5 : 1.0
          // The reference's handle is a dot on the line, not the kit's 14 px handle:
          // at this size the bigger one hides the start of a track that just began.
          knobSize: Style.space(9)
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
          Layout.topMargin: -Style.space(2)
          spacing: Style.space(4)

          Text {
            id: elapsedText
            Layout.alignment: Qt.AlignLeft
            textFormat: Text.PlainText
            text: root.clock(root.displayPosition)
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * 1.25)
          }

          Item { Layout.fillWidth: true }

          Text {
            id: totalText
            Layout.alignment: Qt.AlignRight
            textFormat: Text.PlainText
            text: root.clock(root.duration)
            color: root.textColor
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * 1.25)
          }
        }
      }

      GlyphButton {
        id: speakerButton
        iconText: root.displayVolume <= 0 ? "󰝟" : "󰕾"
        tint: root.textColor
        glyphSize: Math.round(Style.font.iconLarge * 1.25)
        tooltipText: root.displayVolume <= 0 ? root.t("Включить звук") : root.t("Выключить звук")
        onClicked: root.toggleMute()
      }

      // The three dots: the controls that did not fit the row, one line below it.
      GlyphButton {
        iconText: "󰇙"
        tint: root.playerControlsOpen ? Color.accent : root.textColor
        glyphSize: Math.round(Style.font.iconLarge * 1.25)
        tooltipText: root.playerControlsOpen
          ? root.t("Свернуть управление")
          : root.t("Перемешать, повтор и громкость")
        onClicked: root.playerControlsOpen = !root.playerControlsOpen
      }
    }

    // What the menu button opens: the three controls the row above has no place for.
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)
      visible: root.signedIn && root.playerControlsOpen

      GlyphButton {
        iconText: "󰒟"
        tint: root.shuffled ? Color.accent : root.textColor
        glyphSize: Math.round(Style.font.iconLarge * 1.1)
        tooltipText: root.shuffled ? root.t("Перемешивание включено") : root.t("Перемешать")
        onClicked: root.toggleShuffle()
      }

      GlyphButton {
        iconText: root.repeatGlyph
        tint: root.repeatMode === "off" ? root.textColor : Color.accent
        glyphSize: Math.round(Style.font.iconLarge * 1.1)
        tooltipText: root.repeatMode === "off" ? root.t("Повтор выключен")
          : (root.repeatMode === "one" ? root.t("Повторять трек") : root.t("Повторять очередь"))
        onClicked: root.cycleRepeat()
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

    // The geometry this player ends up with, once per popup, the way the bar row
    // reports its own. A complaint about proportions is answered with numbers
    // instead of a screenshot, and nothing has to be re-measured by hand.
    property bool _reported: false
    onHeightChanged: {
      if (playerColumn._reported || playerColumn.width <= 0 || playerColumn.height <= 0) return
      playerColumn._reported = true
      console.log("[vk-music] player", JSON.stringify({
        column: [playerColumn.width, playerColumn.height],
        cover: [playerCover.width, playerCover.height],
        coverToText: metaColumn.x - (playerCover.x + playerCover.width),
        metaRow: metaRow.height,
        controlsRow: controlsRow.height,
        rowGap: controlsRow.y - (metaRow.y + metaRow.height),
        play: [playButton.width, playButton.height],
        glyphs: [playButton.iconSize, prevButton.iconSize, speakerButton.iconSize],
        type: [titleText.font.pixelSize, artistText.font.pixelSize,
               captionText.font.pixelSize, elapsedText.font.pixelSize]
      }))
    }
  }

  // The row at the very top: a bar of cells, one object, rather than a framed strip
  // floating inside the card. Settings at the far left, the three views sharing what is
  // left, and the card's own width at the far right. The cells are flush with each other
  // — a gap between them is what makes a row of buttons out of a tab bar — and the only
  // lines in it are the two dividers that end the tools at either side.
  component TopRow: RowLayout {
    id: topRow
    Layout.fillWidth: true
    // No gap between the cells, and no padding around them: the fill of the cell in use
    // has to reach the bar's own edges or it reads as a button lying on top of a strip.
    spacing: 0
    visible: root.signedIn

    // The height comes from the root, where the bars under it read it too — and the one at
    // the top of the card is a fifth taller than the rest.
    readonly property real cellHeight: root.topBarHeight
    // The two tools at the ends are as wide as the bar is tall: squares at either end of
    // a row of cells, which is what keeps the views between them the same width.
    readonly property real toolWidth: cellHeight

    // Settings is not one of the views, so it stands outside them, at the bar's left
    // end: a tab that is not a place in the card has no claim on a third of it.
    BarCell {
      Layout.preferredWidth: topRow.toolWidth
      Layout.preferredHeight: topRow.cellHeight
      horizontalPadding: 0
      topLeftRadius: root.cardCorner
      iconText: "󰒓"
      selected: root.view === "settings"
      tooltipText: root.t("Настройки")
      onClicked: {
        root.cursor = -1
        root.view = "settings"
      }
    }

    BarDivider { Layout.preferredHeight: topRow.cellHeight }

    // Three equal cells. Equal because each asks for no width of its own and takes a
    // third of what is left — the bar's width does not depend on the longest label.
    BarCell {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      Layout.minimumWidth: 0
      Layout.preferredHeight: topRow.cellHeight
      iconText: "󰲸"
      text: root.t("Очередь")
      selected: root.view === "queue"
      onClicked: {
        root.cursor = -1
        root.view = "queue"
        root.focusList()
      }
    }

    BarCell {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      Layout.minimumWidth: 0
      Layout.preferredHeight: topRow.cellHeight
      iconText: "󰊊"
      text: root.t("Обзор")
      selected: root.view === "browse"
      onClicked: {
        root.cursor = -1
        root.view = "browse"
        root.scheduleBrowse(root.browseSlug !== "" ? root.browseSlug : "friends")
        root.focusList()
      }
    }

    BarCell {
      Layout.fillWidth: true
      Layout.preferredWidth: 0
      Layout.minimumWidth: 0
      Layout.preferredHeight: topRow.cellHeight
      iconText: "󰍉"
      text: root.t("Поиск")
      selected: root.view === "search"
      onClicked: {
        root.cursor = -1
        root.view = "search"
        root.activeField().forceActiveFocus()
      }
    }

    BarDivider { Layout.preferredHeight: topRow.cellHeight }

    // The card's own width, one click away. It writes the same preference the settings
    // page writes, so the two cannot disagree, and the card takes the new shape as soon
    // as the daemon's answer lands.
    BarCell {
      Layout.preferredWidth: topRow.toolWidth
      Layout.preferredHeight: topRow.cellHeight
      horizontalPadding: 0
      topRightRadius: root.cardCorner
      iconText: root.isExtended() ? "󰊔" : "󰊓"
      tooltipText: root.isExtended() ? root.t("Компактный") : root.t("Расширенный")
      onClicked: root.setPreference("popupView", root.isExtended() ? "compact" : "extended")
    }
  }

  // One cell of a bar of cells: a view, a tool, or a section chip. Not a Button. A bar
  // of cells is flush and square — a rounded fill next to the divider that closes a
  // group reads as one blurry edge, which is what «the divider merges into the
  // selection» looked like — and the fill of the cell in use reaches the bar's whole
  // height, the way a tab does.
  component BarCell: Rectangle {
    id: barCell
    property string text: ""
    property string iconText: ""
    property bool selected: false
    property string tooltipText: ""
    // A tool at the end of the bar is a square with nothing but a glyph in it, so it sets
    // this to zero and the glyph is centred in the cell rather than in a padded one.
    property real horizontalPadding: Style.spacing.controlPaddingX
    signal clicked()

    // The two slots, measured from the glyphs' own natural widths and never from the
    // widths the layout hands out: a width derived from a width is the loop that once
    // clipped «Поиск» off the end of its cell.
    readonly property real iconSlot: barCell.iconText !== "" && barCell.text !== ""
      ? barIcon.implicitWidth + Style.spacing.controlGap : 0
    readonly property real labelSlot: barCell.text !== "" ? barLabel.implicitWidth : 0

    implicitWidth: 2 * horizontalPadding + barCell.iconSlot + barCell.labelSlot
      + (barCell.text !== "" ? 0 : (barCell.iconText !== "" ? barIcon.implicitWidth : 0))
    // The bar's height, not its own content's: a cell that measured its own line came out
    // a pixel or two taller than the tool next to it, and in a row of flush cells that is
    // the first thing the eye finds.
    implicitHeight: root.barCellHeight
    radius: 0
    color: pointer.pressed ? Style.pressedFillFor(root.textColor, Color.accent)
      : pointer.containsMouse ? Style.hoverFillFor(root.textColor, Color.accent)
      : barCell.selected ? Style.selectedFillFor(root.textColor, Color.accent)
      : "transparent"

    // The glyph and the label, centred as one pair: a Row centred in the cell is centred
    // as a whole, and the label gives up its width only when the pair is too wide to fit.
    // Centring the label inside the room the glyph leaves put the pair half a glyph left
    // of the middle, which is what the cell looked like.
    Row {
      id: barContent
      anchors.centerIn: parent
      spacing: Style.spacing.controlGap

      Text {
        id: barIcon
        anchors.verticalCenter: parent.verticalCenter
        visible: barCell.iconText !== ""
        textFormat: Text.PlainText
        text: barCell.iconText
        color: barCell.selected ? Style.selectedStateColor(root.textColor, Color.accent) : root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.icon
      }

      Text {
        id: barLabel
        anchors.verticalCenter: parent.verticalCenter
        visible: barCell.text !== ""
        width: Math.min(implicitWidth, barCell.width - 2 * barCell.horizontalPadding - barCell.iconSlot)
        textFormat: Text.PlainText
        elide: Text.ElideRight
        text: barCell.text
        color: barCell.selected ? Style.selectedStateColor(root.textColor, Color.accent) : root.textColor
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: barCell.selected
      }
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: barCell.clicked()
    }

    PanelToolTip {
      visible: barCell.tooltipText !== "" && pointer.containsMouse
      text: barCell.tooltipText
    }
  }

  // A glyph control of the player. The kit's Button paints a rounded square with a border
  // under the pointer, and beside a play button drawn as a circle — the one round control
  // in the panel — that square is the shape that does not belong. This is the same hover
  // fill and the same hover border in a circle: the box is square, so the radius is half
  // of it and the fill cannot become an ellipse.
  component GlyphButton: BorderSurface {
    id: glyphButton
    property string iconText: ""
    property color tint: root.textColor
    property real glyphSize: Style.font.icon
    property string tooltipText: ""
    signal clicked()

    implicitWidth: Style.space(30)
    implicitHeight: Style.space(30)
    radius: width / 2
    color: pointer.pressed ? Style.pressedFillFor(root.textColor, Color.accent)
      : pointer.containsMouse ? Style.hoverFillFor(root.textColor, Color.accent)
      : "transparent"
    borderSpec: pointer.containsMouse
      ? Border.controlSpec("hover-cursor", root.textColor, Color.accent)
      : Border.none()

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: glyphButton.iconText
      color: glyphButton.tint
      font.family: Style.font.family
      font.pixelSize: glyphButton.glyphSize
    }

    MouseArea {
      id: pointer
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: glyphButton.clicked()
    }

    PanelToolTip {
      visible: glyphButton.tooltipText !== "" && pointer.containsMouse
      text: glyphButton.tooltipText
    }
  }

  // The bar's bottom edge: a solid rule the width of the card's own border, and the
  // reason it is solid rather than one of the panel's 12 % separators is that the cell in
  // use has to run into it. A soft line under a hard fill leaves the fill floating, and
  // the eye reads the gap between them as a margin the bar does not have.
  component BarEdge: Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: Math.max(1, Style.space(2))
    color: root.textColor
  }

  // A divider between a tool at the bar's end and the views in the middle. Only there:
  // between two views the fill of the one in use is the divider.
  //
  // Darker than the separator under the bar on purpose. A tool cell can be *selected*, and
  // its fill is the same foreground tint: at the separator's 12 % the line and the fill
  // measured nine levels apart and the two ran together into one soft edge. The bar's own
  // line has to win that comparison by a margin, or it reads as the fill's own border.
  component BarDivider: Rectangle {
    Layout.preferredWidth: 1
    color: Qt.rgba(root.textColor.r, root.textColor.g, root.textColor.b, 0.3)
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
      placeholderText: root.t("Артист, трек, альбом")
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
      // Esc in the field drops the focus and nothing else: the keyboard goes back to
      // the list, where j/k (or hjkl in the gallery) take over. Clearing the query
      // and closing the panel are the next Escs, from the list.
      Keys.onEscapePressed: function(event) {
        root.focusList()
        event.accepted = true
      }
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
      tooltipText: root.t("Очистить")
      onClicked: {
        root.clearSearch()
        searchField.forceActiveFocus()
      }
    }
  }

  component LoadingLine: Item {
    Layout.fillWidth: true
    Layout.preferredHeight: Math.max(2, Style.space(2))
    // Only while something is loading, and clipped to its own two pixels: a line
    // that holds a place for itself in the layout is a line that can sit on the last
    // row of whatever list is above it.
    visible: root.signedIn && root.anyLoading()
    clip: true

    ProgressLine {
      anchors.fill: parent
      thickness: Math.max(2, Style.space(2))
      color: Color.accent
    }
  }

  // -------------------------------------------------------------- popup ---
  //
  // The card has a fixed height and the list area scrolls. Sizing the card from
  // the column's implicit height looked right in theory, but that height only
  // exists after a layout pass, so the popup opened collapsed and grew a frame
  // later. A fixed card with one Flickable is boring and always correct.

  // Measures one line of the bar's font. Invisible and unlaid-out: nothing reads its
  // position, only its height, and only `barCellHeight` reads that.
  Text {
    id: barProbe
    visible: false
    text: "X"
    font.family: Style.font.family
    font.pixelSize: Style.font.body
  }

  KeyboardPanel {
    id: panel
    anchorItem: barRow
    owner: root
    bar: root.bar
    open: root.opened
    // The card carries no padding: `cardInset` is applied by the blocks inside it, so the
    // bar and the rows can reach the card's edges without anything hanging out.
    padding: 0
    focusTarget: keys
    // The card keeps the width it had with the panel's own padding: the blocks now carry
    // `cardInset` themselves, so the two add up to the same number. The height is the one
    // number that grows — the bar no longer pays for the card's top padding, so the same
    // card is 2 * cardInset taller in content terms and the list keeps its room.
    contentWidth: panel.fittedContentWidth(Style.space(root.isExtended() ? 620 : 480))
    // Fixed height, but not one height for everything: a signed-out card holding
    // two lines of text and one button would otherwise be mostly empty space.
    // 690 rather than 460: with the smaller card the queue showed four tracks and
    // had to be scrolled for a fifth, and the settings page was barely usable.
    //
    // `galleryRoom` is the one part that is not fixed: a gallery asks for the height
    // that holds one more whole row of cards, and gives it back when it goes away. It is
    // set from the list (`alignGallery`), not bound to it — the room the list gets comes
    // from this height, and a binding between the two is a loop.
    contentHeight: panel.fittedContentHeight(
      (root.signedIn ? Style.space(root.isExtended() ? 760 : 690) : Style.space(460))
        + root.galleryRoom + 2 * root.cardInset)

    PanelKeyCatcher {
      id: keys
      // Backspace is one of the few keys the catcher does not map, and its own handler
      // does not accept it — so the release event arrives here, on the instance. One
      // key back: the same thing the «Назад» button does, from anywhere in the panel.
      Keys.onReleased: function(event) {
        if (event.key !== Qt.Key_Backspace) return
        event.accepted = true
        if (root.openPlaylist !== null) { root.closePlaylistView(); return }
        if (root.person !== null) { root.closePerson(); return }
        if (root.filterActive() || root.filtering) { root.clearFilter(); return }
      }
      anchors.fill: parent
      // While the search field has the keyboard, the field owns every key: «j» is a
      // letter to type there, not a step down the list. The field handles Esc itself.
      // A hidden field cannot own the keyboard, and one that thinks it does blocks
      // every key in the panel: `visible` is part of the question.
      blocked: (root.activeField().visible && root.activeField().activeFocus) || root.filterFocused
        || root.accountFieldFocus > 0
      // Up and down move the selection instead of the playback: pressing a key
      // to look through a list should not start a track. `n` and `p` below still
      // switch tracks.
      onMoveRequested: function(dx, dy) {
        // hjkl is navigation and nothing else. Taking «l» for the representation switch
        // was a mistake: it is the same finger that walks a gallery, and a key that
        // sometimes moves and sometimes rearranges the panel cannot be learned. The
        // switch has its own key, «m».
        if (dx !== 0) {
          if (root.galleryMode) root.moveCursor(dx)
          return
        }
        if (dy !== 0) root.moveCursor(root.galleryMode ? dy * root.galleryColumns : dy)
      }
      // Tab hands the keyboard to the list and puts the cursor on its first item —
      // the way out of a search field that has finished being typed into.
      onTabRequested: function(direction) {
        root.focusList()
        root.cursor = -1
        root.moveCursor(direction > 0 ? 1 : -1)
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
      // Esc backs out one step at a time: the key sheet it can close, the search it can
      // clear, the popup it closes.
      onCloseRequested: {
        if (root.hintsOpen) {
          root.hintsOpen = false
          return
        }
        if (root.filterActive() || root.filtering) {
          root.clearFilter()
          return
        }
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
        // The question mark is a key like the rest: the sheet it opens is the panel's own
        // help, and a help that needs a mouse is the help that is needed first.
        if (character === "?") {
          root.hintsOpen = !root.hintsOpen
          return
        }
        if (root.activeField().activeFocus) return
        if (character === "]") { root.cycleView(1); return }
        if (character === "[") { root.cycleView(-1); return }
        // One key for the representation, a toggle: «m» switches between the gallery
        // and the list wherever both exist.
        if (character === "m") {
          if (root.playlistsShown) root.setPlaylistView(root.gridView ? "list" : "grid")
          return
        }
        if (character === "L") { root.cycleSource(1); return }
        if (character === "H") { root.cycleSource(-1); return }
        if (character === "/") {
          // Vim's search: inside the list you are looking at, not a new list.
          root.startFilter()
          return
        }
      }

      // Compact: the player above the list, one column, the size it has always
      // been.
      ColumnLayout {
        id: compactBody
        anchors.fill: parent
        visible: !root.isExtended()
        spacing: Style.spacing.controlGap

        // The bar is the card's own top edge and the blocks under it are inset by
        // `cardInset`: the card itself has no padding, so nothing here hangs outside its
        // parent and every cell answers the pointer over its whole rectangle.
        TopRow {
          Layout.fillWidth: true
          // The column's own gap, so the fill of the cell in use reaches the rule under
          // the bar instead of stopping a gap short of it.
          Layout.bottomMargin: -Style.spacing.controlGap
        }
        BarEdge { visible: root.signedIn }
        SignInBlock {
          Layout.fillWidth: true
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: root.cardInset
        }
        PlayerColumn {
          Layout.fillWidth: true
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: root.cardInset
        }
        // The rule that ends the player is the top of the band above the list now, so
        // that the first cell under it sits flush against it.
        SearchFieldRow {
          id: compactFieldRow
          Layout.fillWidth: true
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: root.cardInset
        }
        TrackList { id: compactList }
        LoadingLine {
          Layout.fillWidth: true
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: root.cardInset
          Layout.preferredHeight: Math.max(2, Style.space(2))
        }
      }

      // Extended: the player on the left, the list on the right. Two columns need
      // the wider card the panel is told to open with.
      ColumnLayout {
        id: extendedBody
        anchors.fill: parent
        visible: root.isExtended()
        spacing: Style.spacing.controlGap

        // The same lid on the wide card: see the compact body.
        TopRow {
          Layout.fillWidth: true
          Layout.bottomMargin: -Style.spacing.controlGap
        }
        BarEdge { visible: root.signedIn }
        SignInBlock {
          Layout.fillWidth: true
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: root.cardInset
        }
        // The player is a band, not a column: everything the list needs is
        // underneath it, across the whole card.
        PlayerBar {
          Layout.fillWidth: true
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: root.cardInset
          visible: root.signedIn
        }
        // The band over the list carries the rule that ends the player: see the
        // compact body.
        SearchFieldRow {
          id: extendedFieldRow
          Layout.fillWidth: true
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: root.cardInset
        }
        TrackList { id: extendedList; Layout.topMargin: Style.space(14) }
        LoadingLine {
          Layout.fillWidth: true
          Layout.leftMargin: root.cardInset
          Layout.rightMargin: root.cardInset
          Layout.preferredHeight: Math.max(2, Style.space(2))
        }
      }

      // Last inside the key catcher, so they float over whichever body is showing.
      RowMenu { }
      HintsPanel { }
    }
  }
}
