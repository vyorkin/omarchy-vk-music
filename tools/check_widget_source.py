#!/usr/bin/env python3
"""Guards the widget source against leftover debugging and misnamed rows.

A probe timer that sets the view is invisible: the file parses, the widget loads, the
journal stays clean, and the only symptom is the panel doing something the user did
not ask for. Three rounds were lost to exactly that, so the check is a tool now.

Fails when BarWidget.qml contains:
  * a Timer that logs, changes the view, or loads a section — that is a probe, not code;
  * the marker `ВРЕМЕННО`, which every temporary edit is supposed to carry;
  * a `root.rowAction("name", …)` whose name is not a list `ListShape` knows. A delegate
    names the array it drew, and a misspelt name is not a crash: `actionAt` answers null
    and the row quietly stops doing anything, which is the kind of failure this file exists
    to catch before the shell is restarted.

Run it before deploying: python3 tools/check_widget_source.py
"""

import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "BarWidget.qml"
SHAPE = Path(__file__).resolve().parent.parent / "ListShape.js"
# A timer that logs, switches the view or overrides the playlist representation is a
# probe. A timer that loads a section after a delay is not: `browseDelay` exists so that
# running through the tabs costs one request instead of one per tab.
SUSPECT = ("console.log(", "setPlaylistView(", 'root.view = "')

# `root.rowAction("queue", index)` — the literal is the list a delegate drew.
ROW_ACTION = re.compile(r'root\.rowAction\(\s*"([a-zA-Z]+)"')
# `[root.cli, "seek", …]` — a command line the panel had to assemble itself.
ARGV = re.compile(r'root\.cli,\s*"')
# `queue: "playQueue",` inside `var INTENTS` — the lists a row can be started from.
INTENT = re.compile(r'^\s{2}([a-zA-Z]+):\s*"[a-zA-Z]+",?$', re.MULTILINE)


def intents() -> set[str]:
    text = SHAPE.read_text(encoding="utf-8")
    start = text.find("var INTENTS = {")
    if start == -1:
        return set()
    end = text.find("}", start)
    return set(INTENT.findall(text[start:end]))


def timer_blocks(text):
    start = 0
    while True:
        i = text.find("Timer {", start)
        if i == -1:
            return
        depth = 0
        j = i
        while j < len(text):
            if text[j] == "{":
                depth += 1
            elif text[j] == "}":
                depth -= 1
                if depth == 0:
                    break
            j += 1
        yield i, j + 1, text[i:j + 1]
        start = j + 1


def main():
    text = SOURCE.read_text(encoding="utf-8")
    failures = []

    for i, _, block in timer_blocks(text):
        line = text[:i].count("\n") + 1
        for marker in SUSPECT:
            if marker in block:
                first = next(l.strip() for l in block.split("\n")[1:4] if l.strip())
                failures.append(f"BarWidget.qml:{line}: a Timer carries {marker!r} — that is a probe ({first})")

    # The poll is the widget's only source of truth for playback state; it has been lost
    # to a careless cleanup once already, and everything in the bar went stale.
    if "id: pollTimer" not in text:
        failures.append("BarWidget.qml: the poll timer is missing — the bar cannot show playback state")

    if "ВРЕМЕННО" in text:
        line = text[: text.index("ВРЕМЕННО")].count("\n") + 1
        failures.append(f"BarWidget.qml:{line}: the temporary marker is still in the file")

    known = intents()
    if not known:
        failures.append("ListShape.js: `INTENTS` is gone — no row has an action any more")
    for match in ROW_ACTION.finditer(text):
        name = match.group(1)
        if name in known:
            continue
        line = text[: match.start()].count("\n") + 1
        failures.append(
            f"BarWidget.qml:{line}: root.rowAction(\"{name}\", …) names no list in ListShape.INTENTS"
        )

    # The panel speaks the protocol, not the command line: `api.request("search", …)` and
    # never `root.call([root.cli, "search", …])`. A rebuilt argv here would be a second
    # owner of the protocol, which is the thing `BackendClient` exists to prevent.
    for match in ARGV.finditer(text):
        line = text[: match.start()].count("\n") + 1
        failures.append(f"BarWidget.qml:{line}: an argv is built again — commands go through api.request")

    for failure in failures:
        print(f"FAIL {failure}")
    if failures:
        return 1
    print(f"ok {SOURCE.name}: no probe timers, no temporary markers, every row names a known list,"
          " no argv")
    return 0


if __name__ == "__main__":
    sys.exit(main())
