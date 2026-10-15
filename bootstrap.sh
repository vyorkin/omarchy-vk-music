#!/usr/bin/env bash
# Update the backend of an already installed plugin without touching the UI.
# The plugin's own bootstrap calls this whenever it loads.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$ROOT/install.sh" --backend-only
