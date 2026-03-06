#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-$ROOT_DIR/native/build/Debug/Pnevma.app}"
GHOSTTY_XCFRAMEWORK="$ROOT_DIR/vendor/ghostty/macos/GhosttyKit.xcframework"
LOG_PATH="${LOG_PATH:-$ROOT_DIR/native/build/logs/ghostty-smoke.log}"
TIMEOUT_SECS="${SMOKE_TIMEOUT_SECS:-20}"

if [[ ! -d "$GHOSTTY_XCFRAMEWORK" ]]; then
  echo "error: Ghostty xcframework not found at $GHOSTTY_XCFRAMEWORK" >&2
  echo "Run 'just ghostty-build' first." >&2
  exit 1
fi

"$ROOT_DIR/scripts/run-app-smoke.sh" \
  --app "$APP_PATH" \
  --mode ghostty \
  --timeout "$TIMEOUT_SECS" \
  --log "$LOG_PATH"
