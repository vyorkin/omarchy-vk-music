# ADR-0003: the panel reads codes, and one module owns the protocol

Status: accepted, 2026-10-25.

## Context

The interface between the daemon and the panel was a sentence, three times over.

* **Refusals.** The daemon answered `{"ok": false, "error": {"code", "message"}}`, where the
  message was Russian prose written for the CLI. The panel looked that sentence up in the
  translation table and, when it was absent, recognised two shapes with regular expressions
  (`tm()`: «Пропущен трек «X»: …», «человек не найден: …»). Rewording a message in the
  daemon could therefore change what the panel showed without touching the panel.
* **Notices.** A skipped track reached the panel as a finished Russian sentence and was
  printed as-is, so an English panel showed Russian text. The `tm()` path never covered it.
* **Halts.** `HALT_MESSAGES` in `backend.py` mapped VK's error codes to Russian sentences,
  so the one place that knew why traffic had stopped was also the place that decided how
  the reason was worded.

Underneath sat a fourth copy of the same knowledge: every one of the forty-odd call sites
in `BarWidget.qml` built an argv (`[cli, "queue", "remove", String(index)]`) and knew that
some replies needed a second process because they carried a body (`callRequest`). The
command language existed three times — the shell front-end, the Python front-end, and the
panel's call sites — while the daemon dispatched on a name in a JSON envelope all along.

## Decision

1. **The wire carries `{code, params}` beside `message`.** Anything the panel displays
   arrives as a code: `error:<code>`, `halted:<reason>`, `notice:<code>`. `message` stays
   for the two adapters a human reads — the CLI and the journal — and may be reworded
   freely.
2. **The panel never reads `message`.** A refusal becomes a sentence through
   `I18n.failure()`, a notice or a halt through `I18n.message()`; a reason inside a phrase
   (`params.reason`) is a code as well and is translated before it is substituted. An
   unknown code prints as the code, never as an empty line.
3. **The reason codes are `classify()`'s answer.** It returns a code
   (`token_rejected`, `flood_control`, `captcha`, `rate_limited`, `method_unavailable`,
   `no_audio_access`, `request_refused`, `vk_error`) and `describe()` builds the phrase from
   the same code for the journal. No Russian sentence is left in the daemon.
4. **One module owns the protocol.** `BackendClient.qml` holds the envelope, the process,
   the stdin body, the busy count and the refusal text. Callers pass a command and its data:
   `api.request("queue_remove", {index: 3})`. No caller builds an argv, and
   `tools/check_widget_source.py` fails the build if one appears again.
5. **The transport is the CLI's `request` verb**, which reads one JSON line from stdin. The
   shell front-end gained that one word; its human-facing verbs and the Python front-end
   stay as they are. Replacing the process with a socket later is a change *behind*
   `BackendClient`, not an interface change.
6. **A service that is not running answers in the same envelope** (`backend_down`), so a
   stopped service reads as a sentence about the service rather than as a line about `nc`.

## Consequences

* A new message is a row in `i18n.js` and a code in the daemon; neither side needs the
  other's wording. A new language touches `i18n.js` only.
* A refused connection used to leave the socket file behind, so the shell handed the panel
  whatever the transport printed. It now answers `backend_down`, which the panel
  translates.
* Two assignments to `root.notice` were writes to a read-only property and never painted
  anything; the refusal that came with them already owned the status line, so they are gone
  rather than revived.
* `status.halted` and `status.notice` are objects on the wire (`null` when absent), not
  strings. Nothing else in the status payload changed shape.
* Untranslated technical text is still possible on purpose: `detail` carries VK's own
  wording or ffmpeg's reason, printed as it arrives.

## Alternatives rejected

* **Keeping the prose and translating it by lookup.** Rejected: the panel had to recognise
  two sentence shapes with regular expressions, and the skipped-track sentence escaped that
  path entirely — the failure the tests now cover.
* **Sending `{code, params}` with no `message`.** Rejected: the CLI and the journal are the
  second and third readers of the same answer, and a human debugging a service wants a
  sentence, not an envelope.
* **A socket in the panel now.** Rejected for this step, not for good: it needs request ids
  and a server that keeps the connection open, which doubles the change while making it
  unclear which half broke. The seam is placed so it can happen behind `BackendClient`.
* **Collapsing the two CLI front-ends.** Rejected: after this decision the panel no longer
  uses them, so they are two ways for a human to talk to the daemon, and the shell one
  exists for responsiveness during a volume drag.
