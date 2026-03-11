#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/native/Pnevma/Pnevma.entitlements}"

# Default: detect the xcodebuild release output location.
# Override APP_PATH to use a custom location.
SIGN_TARGET_PATH="${TARGET_PATH:-${APP_PATH:-}}"

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

if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "APPLE_SIGNING_IDENTITY is required"
  exit 1
fi

if [[ -z "$SIGN_TARGET_PATH" ]]; then
  SIGN_TARGET_PATH="$(default_app_path)"
fi

if [[ ! -e "$SIGN_TARGET_PATH" ]]; then
  echo "Sign target not found at $SIGN_TARGET_PATH"
  exit 1
fi

if [[ -d "$SIGN_TARGET_PATH" && "$SIGN_TARGET_PATH" == *.app ]]; then
  echo "Signing app bundle $SIGN_TARGET_PATH"

  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Entitlements file not found at $ENTITLEMENTS_PATH"
    exit 1
  fi

  # Sign embedded frameworks/dylibs first (inside-out signing), then the outer app.
  if [[ -d "$SIGN_TARGET_PATH/Contents/Frameworks" ]]; then
    find "$SIGN_TARGET_PATH/Contents/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' fw; do
      echo "Signing embedded: $fw"
      codesign --force --options runtime --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$fw"
    done
  fi

  codesign \
    --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$APPLE_SIGNING_IDENTITY" \
    "$SIGN_TARGET_PATH"

  echo "Verifying app signature"
  codesign --verify --deep --strict --verbose=2 "$SIGN_TARGET_PATH"
  spctl --assess --type execute --verbose=4 "$SIGN_TARGET_PATH"
  echo "Signed app ready: $SIGN_TARGET_PATH"
  exit 0
fi

if [[ -f "$SIGN_TARGET_PATH" && "$SIGN_TARGET_PATH" == *.dmg ]]; then
  echo "Signing disk image $SIGN_TARGET_PATH"
  codesign --force --timestamp --sign "$APPLE_SIGNING_IDENTITY" "$SIGN_TARGET_PATH"
  echo "Verifying disk image signature"
  codesign --verify --verbose=2 "$SIGN_TARGET_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$SIGN_TARGET_PATH"
  echo "Signed disk image ready: $SIGN_TARGET_PATH"
  exit 0
fi

echo "Unsupported sign target: $SIGN_TARGET_PATH"
echo "Expected a .app bundle or .dmg file."
exit 1
