#!/usr/bin/env python3
"""Check the rendered buffering frame against the percentage it was given.

`tests/qml/tst_progress_frame.qml` renders the frame at a quarter, a half and the
whole perimeter into `/tmp/vk-music-frame-tests/`. This walks the same rounded
rectangle along its perimeter, in the same direction the component draws it, and
measures how much of that perimeter came out in the fill colour. The fraction has
to match the progress the frame was rendered with.

The point is the failure that started this: the fill length was a share of the
perimeter clamped with `Math.max(1, …)`, so every percentage painted the whole
outline. Numbers along the path could not see it; pixels can.

Pixels are read with ffmpeg as the PNG decoder — one process turns a rendered
frame into raw 24-bit RGB on stdout.

    cd tests/../ && python3 tools/check_frame_render.py
    QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -import tests/qml -input tests/qml
    python3 tools/check_frame_render.py

The second command must run first: this script only reads what the test rendered.
"""

from __future__ import annotations

import math
import subprocess
import sys
from pathlib import Path

FRAME_DIR = Path("/tmp/vk-music-frame-tests")
SIZE = 64
RADIUS = 6
THICKNESS = 3
TOLERANCE = 0.06
SAMPLES = 2000

# The colours the QML test renders with.
FILL = (255, 0, 0)
TRACK = (0, 0, 255)

CASES = [("q25", 0.25), ("q50", 0.5), ("q100", 1.0)]


def perimeter_points() -> list[tuple[float, float]]:
    """The frame's outline, walked clockwise from the middle of the top edge."""
    inset = THICKNESS / 2
    x0, y0, x1, y1 = inset, inset, SIZE - inset, SIZE - inset
    r = min(RADIUS, (x1 - x0) / 2, (y1 - y0) / 2)
    cx = (x0 + x1) / 2
    half = math.pi / 2
    segments = [
        ("line", (cx, y0), (x1 - r - cx, 0.0), x1 - r - cx),
        ("arc", (x1 - r, y0 + r), r, -half, half, half * r),
        ("line", (x1, y0 + r), (0.0, (y1 - r) - (y0 + r)), y1 - y0 - 2 * r),
        ("arc", (x1 - r, y1 - r), r, 0.0, half, half * r),
        ("line", (x1 - r, y1), ((x0 + r) - (x1 - r), 0.0), x1 - x0 - 2 * r),
        ("arc", (x0 + r, y1 - r), r, half, half, half * r),
        ("line", (x0, y1 - r), (0.0, (y0 + r) - (y1 - r)), y1 - y0 - 2 * r),
        ("arc", (x0 + r, y0 + r), r, math.pi, half, half * r),
        ("line", (x0 + r, y0), (cx - (x0 + r), 0.0), cx - (x0 + r)),
    ]
    total = sum(segment[-1] for segment in segments)
    points: list[tuple[float, float]] = []
    for index in range(SAMPLES):
        distance = total * index / SAMPLES
        walked = 0.0
        for segment in segments:
            if walked + segment[-1] < distance:
                walked += segment[-1]
                continue
            offset = distance - walked
            if segment[0] == "line":
                (px, py), (dx, dy) = segment[1], segment[2]
                points.append((px + dx * offset / segment[-1], py + dy * offset / segment[-1]))
            else:
                (cx_, cy_), radius, start, sweep = segment[1], segment[2], segment[3], segment[4]
                angle = start + (offset / segment[-1]) * sweep
                points.append((cx_ + radius * math.cos(angle), cy_ + radius * math.sin(angle)))
            break
        else:
            points.append(points[0] if points else (cx, y0))
    return points


def read_rgb(path: Path) -> tuple[int, int, list[bytes]]:
    completed = subprocess.run(
        ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(path),
         "-f", "rawvideo", "-pix_fmt", "rgb24", "-"],
        capture_output=True,
    )
    if completed.returncode != 0:
        raise SystemExit(f"ffmpeg could not decode {path}: {completed.stderr.decode()[:200]}")
    raw = completed.stdout
    if len(raw) != SIZE * SIZE * 3:
        raise SystemExit(
            f"{path} is {len(raw)} bytes, expected {SIZE * SIZE * 3}: the test renders "
            f"a {SIZE}x{SIZE} scene"
        )
    return SIZE, SIZE, [raw[i:i + 3] for i in range(0, len(raw), 3)]


def is_fill(pixel: bytes) -> bool:
    return pixel[0] > pixel[2] + 60


def is_track(pixel: bytes) -> bool:
    return pixel[2] > pixel[0] + 60


def main() -> int:
    if not FRAME_DIR.is_dir() or not list(FRAME_DIR.glob("*.png")):
        print(f"nothing rendered in {FRAME_DIR}: run the QML test first", file=sys.stderr)
        return 2

    points = perimeter_points()
    failures = 0
    for name, progress in CASES:
        path = FRAME_DIR / f"{name}.png"
        if not path.is_file():
            print(f"FAIL  {name}: {path} is missing (run the QML test)")
            failures += 1
            continue
        _, _, pixels = read_rgb(path)
        filled = track = other = 0
        for x, y in points:
            pixel = pixels[int(round(y)) * SIZE + int(round(x))]
            if is_fill(pixel):
                filled += 1
            elif is_track(pixel):
                track += 1
            else:
                other += 1
        share = filled / len(points)
        problems = []
        if abs(share - progress) > TOLERANCE:
            problems.append(f"filled {share:.0%} of the perimeter, rendered for {progress:.0%}")
        if other > len(points) * 0.05:
            problems.append(f"{other} of {len(points)} samples are neither fill nor track")
        if progress < 1 and track == 0:
            problems.append("no track left: the whole frame is filled")
        label = f"{name} at {progress:.0%}"
        if problems:
            failures += 1
            print(f"FAIL  {label}: " + "; ".join(problems))
        else:
            print(f"ok    {label}: filled {share:.1%} of the perimeter, "
                  f"track {track / len(points):.1%}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
