#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH_DEFAULT="$ROOT_DIR/target/release/bundle/macos/Pnevma.app"
APP_PATH="${APP_PATH:-$APP_PATH_DEFAULT}"

if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "APPLE_SIGNING_IDENTITY is required"
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  echo "Building release bundle via cargo-tauri..."
  (cd "$ROOT_DIR" && cargo tauri build --manifest-path crates/pnevma-app/Cargo.toml)
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle still not found at $APP_PATH"
  exit 1
fi

echo "Signing $APP_PATH"
codesign --force --deep --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$APP_PATH"

echo "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "Signed app ready: $APP_PATH"
