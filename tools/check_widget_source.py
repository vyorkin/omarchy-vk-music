#!/usr/bin/env python3
"""Guards the widget source against leftover debugging.

A probe timer that sets the view is invisible: the file parses, the widget loads, the
journal stays clean, and the only symptom is the panel doing something the user did
not ask for. Three rounds were lost to exactly that, so the check is a tool now.

Fails when BarWidget.qml contains:
  * a Timer that logs, changes the view, or loads a section — that is a probe, not code;
  * the marker `ВРЕМЕННО`, which every temporary edit is supposed to carry.

Run it before deploying: python3 tools/check_widget_source.py
"""

import re
import sys
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "BarWidget.qml"
# A timer that logs, switches the view or overrides the playlist representation is a
# probe. A timer that loads a section after a delay is not: `browseDelay` exists so that
# running through the tabs costs one request instead of one per tab.
SUSPECT = ("console.log(", "setPlaylistView(", 'root.view = "')


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

    for failure in failures:
        print(f"FAIL {failure}")
    if failures:
        return 1
    print(f"ok {SOURCE.name}: no probe timers, no temporary markers")
    return 0


if __name__ == "__main__":
    sys.exit(main())
