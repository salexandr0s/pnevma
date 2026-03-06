#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-}"

default_app_path() {
  local candidates=(
    "$ROOT_DIR/native/build/Release/Pnevma.app"
    "$ROOT_DIR/native/build/Build/Products/Release/Pnevma.app"
  )
  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "${candidates[0]}"
}

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$(default_app_path)"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  exit 1
fi

echo "Stapling notarization ticket"
xcrun stapler staple "$APP_PATH"

echo "Validating stapled ticket"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "Stapled + verified app: $APP_PATH"
