#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH_DEFAULT="$ROOT_DIR/target/release/bundle/macos/Pnevma.app"
APP_PATH="${APP_PATH:-$APP_PATH_DEFAULT}"

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
