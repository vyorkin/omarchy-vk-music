#!/usr/bin/env bash
# Remove the plugin, the backend, the CLI and the service.
#
# Sign-in, preferences, playback state and the audio cache are kept unless
# --purge is passed: reinstalling should not log the user out.
set -euo pipefail

PLUGIN_ID="vyorkin.vk-music"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
APP_DIR="$HOME/.local/share/omarchy-vk-music"
UNIT="$HOME/.config/systemd/user/omarchy-vk-music.service"
CONFIG_DIR="$HOME/.config/omarchy-vk-music"
CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
[[ "$CACHE_HOME" = /* ]] || CACHE_HOME="$HOME/.cache"

systemctl --user disable --now omarchy-vk-music.service >/dev/null 2>&1 || true
rm -f "$UNIT"
systemctl --user daemon-reload || true
rm -rf "$APP_DIR"
rm -f "$HOME/.local/bin/omarchy-vk-music"
rm -rf "$CACHE_HOME/omarchy-vk-music"

if [[ "${1:-}" == "--purge" ]]; then
  rm -rf "$CONFIG_DIR"
  echo "Removed the plugin, the backend and the stored sign-in."
else
  echo "Removed the plugin and the backend; sign-in and preferences kept in $CONFIG_DIR"
fi

if [[ "$(realpath "$0" 2>/dev/null)" != "$(realpath "$PLUGIN_DIR/uninstall.sh" 2>/dev/null)" ]]; then
  rm -rf "$PLUGIN_DIR"
elif [[ -d "$PLUGIN_DIR" ]]; then
  echo "Delete the plugin directory when you are done: $PLUGIN_DIR"
fi
