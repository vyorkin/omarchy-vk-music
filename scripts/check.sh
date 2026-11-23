#!/usr/bin/env bash
# The three checks this repo owns: the widget-source guard, the QML suite and
# the Python suite. Run from anywhere; paths are resolved from this file.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

mkdir -p /tmp/vk-music-frame-tests
python3 tools/check_widget_source.py
QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}" \
  scripts/qml-test -import tests/qml -input tests/qml -o -,txt
if command -v ffmpeg >/dev/null 2>&1; then
  python3 tools/check_frame_render.py
  python3 tools/check_line_render.py
fi
python3 -m unittest discover -s tests/python -v
