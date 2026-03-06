#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-}"
LOG_PATH="${LOG_PATH:-$ROOT_DIR/native/build/logs/packaged-launch-smoke.log}"
TIMEOUT_SECS="${SMOKE_TIMEOUT_SECS:-20}"

if [[ -z "$APP_PATH" ]]; then
  for candidate in \
    "$ROOT_DIR/native/build/Release/Pnevma.app" \
    "$ROOT_DIR/native/build/Build/Products/Release/Pnevma.app"
  do
    if [[ -d "$candidate" ]]; then
      APP_PATH="$candidate"
      break
    fi
  done
fi

if [[ -z "$APP_PATH" ]]; then
  echo "error: APP_PATH must point to a packaged Pnevma.app bundle" >&2
  exit 1
fi

"$ROOT_DIR/scripts/run-app-smoke.sh" \
  --app "$APP_PATH" \
  --mode launch \
  --timeout "$TIMEOUT_SECS" \
  --log "$LOG_PATH"
