#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Default: Xcode DerivedData build output.
# Override APP_PATH to use a custom location.
APP_PATH="${APP_PATH:-}"

if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "APPLE_SIGNING_IDENTITY is required"
  exit 1
fi

if [[ -z "$APP_PATH" ]]; then
  # Try standard xcodebuild output location
  DERIVED="$ROOT_DIR/native/build/Build/Products/Release/Pnevma.app"
  if [[ -d "$DERIVED" ]]; then
    APP_PATH="$DERIVED"
  else
    echo "App bundle not found. Set APP_PATH or build with:"
    echo "  just xcode-build-release"
    exit 1
  fi
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  exit 1
fi

echo "Signing $APP_PATH"
codesign --force --deep --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$APP_PATH"

echo "Verifying signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "Signed app ready: $APP_PATH"
