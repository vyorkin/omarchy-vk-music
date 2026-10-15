#!/usr/bin/env bash
# Install the VK Music backend, its CLI and its user service.
#
# The plugin directory is the source of truth: when this script runs from
# somewhere else (a git checkout used for development), everything the service
# needs is copied into ~/.config/omarchy/plugins/<id>/ first, so later updates
# through the Omarchy plugin commands keep working.
set -euo pipefail

PLUGIN_ID="vyorkin.vk-music"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
APP_DIR="$HOME/.local/share/omarchy-vk-music"
UNIT_DIR="$HOME/.config/systemd/user"
CONFIG_DIR="$HOME/.config/omarchy-vk-music"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
[[ "$CACHE_HOME" = /* ]] || CACHE_HOME="$HOME/.cache"
AUDIO_CACHE_DIR="$CACHE_HOME/omarchy-vk-music/audio"
BACKEND_ONLY=0

case "${1:-}" in
"") ;;
--backend-only) BACKEND_ONLY=1 ;;
*)
  echo "Usage: $0 [--backend-only]" >&2
  exit 2
  ;;
esac

for command in python mpv ffmpeg systemctl; do
  if ! command -v "$command" >/dev/null; then
    echo "Missing dependency: $command" >&2
    echo "Install it with: omarchy pkg add python mpv ffmpeg" >&2
    exit 1
  fi
done

RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
mkdir -p "$RUNTIME_DIR"
exec 9>"$RUNTIME_DIR/omarchy-vk-music-install.lock"
flock 9

mkdir -p "$PLUGIN_DIR/backend" "$PLUGIN_DIR/bin" "$PLUGIN_DIR/systemd" \
  "$APP_DIR" "$HOME/.local/bin" "$UNIT_DIR" "$CONFIG_DIR" "$AUDIO_CACHE_DIR"
chmod 700 "$CONFIG_DIR" "$AUDIO_CACHE_DIR"

if [[ "$(realpath "$ROOT")" != "$(realpath "$PLUGIN_DIR")" ]]; then
  install -m 644 "$ROOT/manifest.json" "$ROOT/requirements.txt" "$PLUGIN_DIR/"
  install -m 644 "$ROOT/backend/vk_api.py" "$ROOT/backend/vk_auth.py" \
    "$ROOT/backend/audio_cache.py" "$ROOT/backend/backend.py" "$PLUGIN_DIR/backend/"
  install -m 755 "$ROOT/bin/omarchy-vk-music" "$ROOT/bin/omarchy-vk-music.py" "$PLUGIN_DIR/bin/"
  install -m 644 "$ROOT/systemd/omarchy-vk-music.service" "$PLUGIN_DIR/systemd/"
  install -m 755 "$ROOT/install.sh" "$ROOT/bootstrap.sh" "$ROOT/uninstall.sh" "$PLUGIN_DIR/"
  for file in "$ROOT"/*.qml "$ROOT"/*.js; do
    [[ -e "$file" ]] || continue
    install -m 644 "$file" "$PLUGIN_DIR/"
  done
fi

install -m 755 "$PLUGIN_DIR/backend/backend.py" "$APP_DIR/backend.py"
install -m 644 "$PLUGIN_DIR/backend/vk_api.py" "$PLUGIN_DIR/backend/vk_auth.py" \
  "$PLUGIN_DIR/backend/audio_cache.py" "$APP_DIR/"
install -m 755 "$PLUGIN_DIR/bin/omarchy-vk-music" "$PLUGIN_DIR/bin/omarchy-vk-music.py" "$HOME/.local/bin/"
install -m 644 "$PLUGIN_DIR/systemd/omarchy-vk-music.service" \
  "$UNIT_DIR/omarchy-vk-music.service"

if [[ ! -x "$APP_DIR/venv/bin/python" ]]; then
  python -m venv "$APP_DIR/venv"
fi
"$APP_DIR/venv/bin/python" -m pip install \
  --disable-pip-version-check --no-input --quiet \
  --upgrade pip >/dev/null
"$APP_DIR/venv/bin/python" -m pip install \
  --disable-pip-version-check --no-input --quiet \
  --only-binary=:all: -r "$PLUGIN_DIR/requirements.txt"

systemctl --user daemon-reload
systemctl --user enable --now omarchy-vk-music.service >/dev/null

if ((BACKEND_ONLY)); then
  echo "VK Music backend is ready."
  exit 0
fi

if command -v omarchy >/dev/null && omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell shell rescanPlugins >/dev/null || true
  omarchy plugin enable "$PLUGIN_ID" --after omarchy.clock >/dev/null 2>&1 || true
fi

echo
echo "VK Music installed."
echo "Sign in from the widget, or run: omarchy-vk-music auth web"
