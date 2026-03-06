#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-}"
NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-}"
NOTARY_KEYCHAIN="${APPLE_NOTARY_KEYCHAIN:-}"
ZIP_PATH="${ZIP_PATH:-$ROOT_DIR/native/build/Pnevma-notarize.zip}"

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

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "APPLE_NOTARY_PROFILE is required (xcrun notarytool keychain profile name)"
  exit 1
fi

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$(default_app_path)"
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
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE" --wait)
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
  NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi
xcrun notarytool submit "$ZIP_PATH" "${NOTARY_ARGS[@]}"

echo "Notarization submitted and accepted."
echo "Next: run scripts/release-macos-staple-verify.sh"
