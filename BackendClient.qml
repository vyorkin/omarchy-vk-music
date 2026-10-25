// The daemon's protocol, in one place.
//
// One command is one JSON line over `bin/omarchy-vk-music request`: the envelope, the
// stdin that carries it, the answer, the busy indicator and the refusal text all live
// here. A caller passes a command and its data and receives the answer; it never builds
// an argv, never reads `error.message`, and never decides which failures are worth
// showing.
//
// Before this file each of the forty-odd call sites assembled the command line, and every
// one of them had to know that a refusal arrives as prose and that some replies are read
// from a second process because they carry a body. Both facts now have one owner.
//
// `errorText` is a property rather than a signal because it is a fact about the last
// command and the panel shows it in one line; a signal would make every caller decide
// where it goes.

import QtQuick
import Quickshell
import Quickshell.Io
import "i18n.js" as I18n

QtObject {
  id: client

  // The command-line client, which is the transport: `request` reads one JSON line from
  // stdin and answers with one. The panel never names another command.
  property string cli: ""
  property string language: "en"

  // The last refusal, in the panel's language. Empty once a command answers.
  property string errorText: ""
  // How many commands are in flight. The status line draws «…» while this is above zero,
  // which is why a quiet command does not count: the status poll runs four times a second
  // and used to make that line blink.
  property int inflight: 0
  readonly property bool busy: client.inflight > 0

  // One command. `params` is the command's own payload (`query`, `index`, `keys`, …) plus
  // `quiet` as a request option; `onDone` receives the parsed answer, or null when the
  // service answered with something that is not JSON.
  function request(command, params, onDone) {
    var payload = { command: String(command) }
    var settings = params || {}
    var quiet = settings.quiet === true
    for (var name in settings) {
      if (name === "quiet") continue
      payload[name] = settings[name]
    }
    var exchange = client.transport.createObject(client, {
      // One verb, always the same: `request` reads the JSON on stdin and forwards it. The
      // command the daemon runs is inside the envelope, never in this line.
      command: [client.cli, "request"],
      payload: JSON.stringify(payload),
      quiet: quiet,
      onDone: onDone
    })
    if (!exchange) return
    if (!quiet) client.inflight = client.inflight + 1
    exchange.running = true
  }

  // A fresh process per command: a reused object can miss its exit event and then keep
  // reporting "running", which would wedge every later command.
  //
  // The answer is collected in the collector's own `onStreamFinished`, because `text` is a
  // property of the collector and not of the Process: reading it from `onExited` yields
  // undefined, which is how every command once became "the command failed" while the
  // service was in fact working.
  property Component transport: Component {
    Process {
      id: exchange
      property string payload: ""
      property var onDone
      property bool quiet: false
      stdinEnabled: true
      stderr: StdioCollector { id: complaint; waitForEnd: true }
      stdout: StdioCollector {
        id: reply
        waitForEnd: true
        onStreamFinished: client.finish(text, complaint.text, exchange)
      }
      onStarted: {
        write(payload)
        // Closing stdin is what lets the reader finish; `cat` waits for EOF.
        stdinEnabled = false
      }
      onExited: function(code) { destroy() }
    }
  }

  function finish(rawText, complaintText, exchange) {
    var raw = String(rawText || "").trim()
    var answer = null
    try {
      answer = raw === "" ? null : JSON.parse(raw)
    } catch (parseError) {
      answer = null
    }
    if (exchange.quiet !== true) client.inflight = Math.max(0, client.inflight - 1)
    if (answer && answer.ok) {
      client.errorText = ""
    } else if (answer && answer.error) {
      // The envelope's code and params, never its sentence: the sentence belongs to the
      // CLI and the journal, and this panel translates the code itself.
      var text = I18n.failure(client.language, answer.error)
      client.errorText = text !== "" ? text : client.complaint()
    } else if (raw !== "") {
      // Not JSON at all — a traceback, a missing binary. Nothing to translate.
      client.errorText = raw
    } else {
      var stderrText = String(complaintText || "").trim()
      client.errorText = stderrText !== "" ? stderrText : client.complaint()
    }
    if (exchange.onDone) exchange.onDone(answer)
  }

  function complaint() {
    return I18n.translate(client.language, "команда не выполнена")
  }
}
