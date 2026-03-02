#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH_DEFAULT="$ROOT_DIR/target/release/bundle/macos/Pnevma.app"
APP_PATH="${APP_PATH:-$APP_PATH_DEFAULT}"
NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-}"
ZIP_PATH_DEFAULT="$ROOT_DIR/target/release/bundle/macos/Pnevma-notarize.zip"
ZIP_PATH="${ZIP_PATH:-$ZIP_PATH_DEFAULT}"

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "APPLE_NOTARY_PROFILE is required (xcrun notarytool keychain profile name)"
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  echo "Run scripts/release-macos-sign.sh first."
  exit 1
fi

echo "Creating notarization archive at $ZIP_PATH"
mkdir -p "$(dirname "$ZIP_PATH")"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"

echo "Submitting to Apple notary service"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait

echo "Notarization submitted and accepted."
echo "Next: run scripts/release-macos-staple-verify.sh"
