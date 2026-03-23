#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-}"
DMG_PATH="${DMG_PATH:-}"
LOG_PATH="${LOG_PATH:-$ROOT_DIR/native/build/logs/packaged-launch-smoke.log}"
TIMEOUT_SECS="${SMOKE_TIMEOUT_SECS:-20}"

if [[ -n "$APP_PATH" && -n "$DMG_PATH" ]]; then
  # GitHub Actions persists both variables across steps. Prefer the explicit
  # packaged-artifact path only when the DMG already exists; otherwise fall
  # back to the app bundle for pre-signing smoke tests.
  if [[ -f "$DMG_PATH" ]]; then
    APP_PATH=""
  else
    DMG_PATH=""
  fi
fi

if [[ -z "$APP_PATH" && -z "$DMG_PATH" ]]; then
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

mounted_dir=""
copied_app_dir=""
cleanup() {
  if [[ -n "$mounted_dir" && -d "$mounted_dir" ]]; then
    hdiutil detach "$mounted_dir" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "$copied_app_dir" && -d "$copied_app_dir" ]]; then
    rm -rf "$copied_app_dir"
  fi
}
trap cleanup EXIT

if [[ -n "$DMG_PATH" ]]; then
  if [[ ! -f "$DMG_PATH" ]]; then
    echo "error: DMG_PATH must point to a packaged Pnevma disk image" >&2
    exit 1
  fi

  mounted_dir="$(mktemp -d -t pnevma-dmg-mount.XXXXXX)"
  copied_app_dir="$(mktemp -d -t pnevma-dmg-copy.XXXXXX)"
  if ! hdiutil attach "$DMG_PATH" -mountpoint "$mounted_dir" -nobrowse -readonly; then
    echo "error: failed to mount DMG at $DMG_PATH" >&2
    exit 1
  fi

  mounted_app="$(find "$mounted_dir" -maxdepth 1 -type d -name 'Pnevma.app' -print -quit)"
  if [[ -z "$mounted_app" ]]; then
    echo "error: mounted disk image did not contain Pnevma.app" >&2
    exit 1
  fi

  APP_PATH="$copied_app_dir/Pnevma.app"
  ditto "$mounted_app" "$APP_PATH"
fi

if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "error: APP_PATH must point to a packaged Pnevma.app bundle" >&2
  exit 1
fi

"$ROOT_DIR/scripts/run-app-smoke.sh" \
  --app "$APP_PATH" \
  --mode launch \
  --timeout "$TIMEOUT_SECS" \
  --log "$LOG_PATH"
