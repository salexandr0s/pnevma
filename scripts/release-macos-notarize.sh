#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NOTARIZE_TARGET_PATH="${TARGET_PATH:-${APP_PATH:-}}"
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

if [[ -z "$NOTARIZE_TARGET_PATH" ]]; then
  NOTARIZE_TARGET_PATH="$(default_app_path)"
fi

if [[ ! -e "$NOTARIZE_TARGET_PATH" ]]; then
  echo "Notarize target not found at $NOTARIZE_TARGET_PATH"
  exit 1
fi

submit_path="$NOTARIZE_TARGET_PATH"
if [[ -d "$NOTARIZE_TARGET_PATH" && "$NOTARIZE_TARGET_PATH" == *.app ]]; then
  echo "Creating notarization archive at $ZIP_PATH"
  mkdir -p "$(dirname "$ZIP_PATH")"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$NOTARIZE_TARGET_PATH" "$ZIP_PATH"
  submit_path="$ZIP_PATH"
elif [[ ! ( -f "$NOTARIZE_TARGET_PATH" && "$NOTARIZE_TARGET_PATH" == *.dmg ) ]]; then
  echo "Unsupported notarize target: $NOTARIZE_TARGET_PATH"
  echo "Expected a .app bundle or .dmg file."
  exit 1
fi

echo "Submitting to Apple notary service"
NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE" --wait)
if [[ -n "$NOTARY_KEYCHAIN" ]]; then
  NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
fi
xcrun notarytool submit "$submit_path" "${NOTARY_ARGS[@]}"

echo "Notarization submitted and accepted."
echo "Next: run scripts/release-macos-staple-verify.sh"
