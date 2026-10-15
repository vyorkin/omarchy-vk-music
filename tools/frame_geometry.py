#!/usr/bin/env python3
"""Geometry check for the buffering frame.

`ProgressFrame.qml` walks a rounded rectangle as an ordered ring of straight
edges and four arcs. The risky part of that is arithmetic, not painting: the
perimeter has to match the rounded-rectangle formula, the walk has to start at
the middle of the top edge and close there at 100 %, coverage has to grow with
progress, and a radius larger than half the box must clamp instead of producing
NaN.

This ports the same walk and asserts all of it, so the QML can be re-checked
after an edit without a running shell:

    python3 tools/frame_geometry.py
"""

from __future__ import annotations

import math

LINE = "line"
ARC = "arc"


def segments(width: float, height: float, radius: float, thickness: float) -> list[tuple]:
    """The frame as an ordered ring, starting at the middle of the top edge."""
    inset = max(1, thickness) / 2
    x0, y0, x1, y1 = inset, inset, width - inset, height - inset
    r = max(0.0, min(radius, min(x1 - x0, y1 - y0) / 2))
    cx = (x0 + x1) / 2
    half = math.pi / 2
    return [
        (LINE, (cx, y0), (x1 - r - cx, 0.0), max(0.0, x1 - r - cx)),
        (ARC, (x1 - r, y0 + r), r, (-half, half), half * r),
        (LINE, (x1, y0 + r), (0.0, (y1 - r) - (y0 + r)), max(0.0, y1 - y0 - 2 * r)),
        (ARC, (x1 - r, y1 - r), r, (0.0, half), half * r),
        (LINE, (x1 - r, y1), ((x0 + r) - (x1 - r), 0.0), max(0.0, x1 - x0 - 2 * r)),
        (ARC, (x0 + r, y1 - r), r, (half, half), half * r),
        (LINE, (x0, y1 - r), (0.0, (y0 + r) - (y1 - r)), max(0.0, y1 - y0 - 2 * r)),
        (ARC, (x0 + r, y0 + r), r, (math.pi, half), half * r),
        (LINE, (x0 + r, y0), (cx - (x0 + r), 0.0), max(0.0, cx - (x0 + r))),
    ]


def total_length(ring: list[tuple]) -> float:
    return sum(segment[-1] for segment in ring)


def walked_points(ring: list[tuple], start: float, length: float, samples: int = 2000) -> list[tuple]:
    """Points the path actually touches while walking `[start, start + length)`."""
    points: list[tuple[float, float]] = []
    position = 0.0
    for segment in ring:
        segment_start = position
        segment_end = position + segment[-1]
        position = segment_end
        span = segment[-1]
        if span <= 0 or segment_end <= start or segment_start >= start + length:
            continue
        inside = max(0.0, start - segment_start)
        outside = min(span, start + length - segment_start)
        if outside <= inside:
            continue
        steps = max(2, int(samples * (outside - inside) / span))
        for step in range(steps + 1):
            distance = inside + (outside - inside) * step / steps
            if segment[0] == LINE:
                (px, py), (dx, dy) = segment[1], segment[2]
                points.append((px + dx * distance / span, py + dy * distance / span))
            else:
                (cx, cy), r, (a0, sweep) = segment[1], segment[2], segment[3]
                angle = a0 + (distance / span) * sweep
                points.append((cx + r * math.cos(angle), cy + r * math.sin(angle)))
    return points


def expected_perimeter(width: float, height: float, radius: float, thickness: float) -> float:
    inset = max(1, thickness) / 2
    r = min(radius, min(width - 2 * inset, height - 2 * inset) / 2)
    return (2 * (width - 2 * inset - 2 * r) + 2 * (height - 2 * inset - 2 * r)
            + 2 * math.pi * r)


def check(width: float, height: float, radius: float, thickness: float) -> list[str]:
    ring = segments(width, height, radius, thickness)
    length = total_length(ring)
    walked = walked_points(ring, 0, length)
    start, end = walked[0], walked[-1]
    xs = [point[0] for point in walked]
    ys = [point[1] for point in walked]
    inset = max(1, thickness) / 2

    problems: list[str] = []
    expected = expected_perimeter(width, height, radius, thickness)
    if abs(length - expected) > 0.01:
        problems.append(f"perimeter {length:.3f} != {expected:.3f}")
    if abs(start[0] - width / 2) > 0.01 or abs(start[1] - inset) > 0.01:
        problems.append(f"start {start} is not the middle of the top edge")
    if abs(end[0] - start[0]) > 0.01 or abs(end[1] - start[1]) > 0.01:
        problems.append(f"100% does not close the frame: {end}")
    if min(xs) < -0.01 or min(ys) < -0.01 or max(xs) > width + 0.01 or max(ys) > height + 0.01:
        problems.append(
            f"path leaves the box: x {min(xs):.2f}..{max(xs):.2f}, "
            f"y {min(ys):.2f}..{max(ys):.2f}"
        )
    if any(math.isnan(value) for point in walked for value in point):
        problems.append("NaN in the path")
    coverage = [len(walked_points(ring, 0, length * step / 10)) for step in range(11)]
    if any(later <= earlier for earlier, later in zip(coverage, coverage[1:])):
        problems.append(f"coverage does not grow: {coverage}")
    return problems


def main() -> int:
    cases = [
        (20, 20, 4, 2),      # the bar
        (64, 64, 6, 3),      # the popup
        (64, 64, 32, 3),     # radius larger than the box allows
        (16, 16, 2, 1),      # a small cover with a hairline
    ]
    failures = 0
    for width, height, radius, thickness in cases:
        label = f"{width}x{height} radius {radius} thickness {thickness}"
        problems = check(width, height, radius, thickness)
        if problems:
            failures += 1
            print(f"FAIL  {label}: " + "; ".join(problems))
        else:
            length = total_length(segments(width, height, radius, thickness))
            print(f"ok    {label}: perimeter {length:.2f}, closes at the top edge")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
