#!/usr/bin/env python3
"""Check that the indeterminate line's bright piece actually travels.

`tests/qml/tst_progress_line.qml` renders the line at three fixed phases into
`/tmp/vk-music-frame-tests/`. This reads them back (ffmpeg decodes the PNGs) and
measures where the bright piece sits along the line: left, middle and right, in
that order. A line whose piece never moves is indistinguishable from a finished
progress bar, which is exactly the failure this guards against.

    QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
    python3 tools/check_line_render.py
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

FRAME_DIR = Path("/tmp/vk-music-frame-tests")
SIZE = (320, 12)
CASES = [("line-left", 0.0), ("line-middle", 0.5), ("line-right", 0.85)]
FILL_CASES = [("line-fill-35", 0.35), ("line-fill-100", 1.0)]
LINE_THICKNESS = 4


def read_rgb(path: Path) -> bytes:
    completed = subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(path),
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True,
    )
    if completed.returncode != 0:
        raise SystemExit(f"ffmpeg could not decode {path}: {completed.stderr.decode()[:200]}")
    width, height = SIZE
    if len(completed.stdout) != width * height * 3:
        raise SystemExit(f"{path} is {len(completed.stdout)} bytes, expected {width * height * 3}")
    return completed.stdout


def piece_centre(path: Path) -> tuple[float, float]:
    """Where the bright colour sits, and how much of the line is still track."""
    width, height = SIZE
    raw = read_rgb(path)
    bright = []
    track = 0
    for y in range(height):
        for x in range(width):
            i = (y * width + x) * 3
            r, g, b = raw[i], raw[i + 1], raw[i + 2]
            if r > 120 and b < 80:
                bright.append(x)
            elif b > 120 and r < 80:
                track += 1
    if not bright:
        raise SystemExit(f"{path}: no bright piece found")
    # Measured against the line's own area: a share of the whole picture would
    # depend on how much empty space the test scene happens to have.
    return sum(bright) / len(bright) / width, track / (width * LINE_THICKNESS)


def main() -> int:
    if not FRAME_DIR.is_dir():
        print(f"nothing rendered in {FRAME_DIR}: run the QML test first", file=sys.stderr)
        return 2
    centres = []
    failures = 0
    for name, phase in CASES:
        path = FRAME_DIR / f"{name}.png"
        if not path.is_file():
            print(f"FAIL  {name}: {path} is missing (run the QML test)")
            failures += 1
            continue
        centre, track_share = piece_centre(path)
        centres.append(centre)
        problems = []
        if track_share < 0.2:
            problems.append(f"only {track_share:.0%} of the line is track: the piece covers all of it")
        if not 0.0 <= centre <= 1.0:
            problems.append(f"the piece sits outside the line ({centre:.2f})")
        if problems:
            failures += 1
            print(f"FAIL  {name} (phase {phase}): " + "; ".join(problems))
        else:
            print(f"ok    {name} (phase {phase}): piece centred at {centre:.2f}, track {track_share:.0%}")

    # The determinate mode fills from the left edge and covers the given share.
    for name, progress in FILL_CASES:
        path = FRAME_DIR / f"{name}.png"
        if not path.is_file():
            print(f"FAIL  {name}: {path} is missing (run the QML test)")
            failures += 1
            continue
        width, height = SIZE
        raw = read_rgb(path)
        bright = []
        for y in range(height):
            for x in range(width):
                i = (y * width + x) * 3
                r, g, b = raw[i], raw[i + 1], raw[i + 2]
                if r > 120 and b < 80:
                    bright.append(x)
        if not bright:
            print(f"FAIL  {name}: nothing is filled")
            failures += 1
            continue
        filled = (max(bright) + 1) / width
        left_edge = min(bright) <= 2
        problems = []
        if abs(filled - progress) > 0.08:
            problems.append(f"filled {filled:.0%}, expected {progress:.0%}")
        if not left_edge:
            problems.append(f"the fill starts at x={min(bright)}, not at the left edge")
        if problems:
            failures += 1
            print(f"FAIL  {name} (progress {progress}): " + "; ".join(problems))
        else:
            print(f"ok    {name} (progress {progress}): filled {filled:.0%} from the left edge")

    if len(centres) == len(CASES):
        if not (centres[0] < centres[1] < centres[2]):
            print(f"FAIL  the piece does not travel: centres {['%.2f' % c for c in centres]}")
            failures += 1
        elif centres[2] - centres[0] < 0.2:
            print(f"FAIL  the piece barely moves: {centres[2] - centres[0]:.2f} of the width")
            failures += 1
        else:
            print(f"ok    the piece travels left to right: {centres[0]:.2f} -> {centres[2]:.2f}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
