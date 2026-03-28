#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/release-common.sh"

ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/native/Pnevma/Pnevma.entitlements}"
SIGNING_KEYCHAIN_PATH="${SIGNING_KEYCHAIN_PATH:-}"

# Default: detect the xcodebuild release output location.
# Override APP_PATH to use a custom location.
SIGN_TARGET_PATH="${TARGET_PATH:-${APP_PATH:-}}"

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

TIMESTAMP_FLAG="${CODESIGN_TIMESTAMP:-1}"
CODESIGN_ARGS=(--force --sign "$APPLE_SIGNING_IDENTITY")
if [[ "$TIMESTAMP_FLAG" == "1" ]]; then
  CODESIGN_ARGS+=(--timestamp)
fi
if [[ -n "$SIGNING_KEYCHAIN_PATH" ]]; then
  CODESIGN_ARGS+=(--keychain "$SIGNING_KEYCHAIN_PATH")
fi

if [[ -d "$SIGN_TARGET_PATH" && "$SIGN_TARGET_PATH" == *.app ]]; then
  echo "Signing app bundle $SIGN_TARGET_PATH"

  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Entitlements file not found at $ENTITLEMENTS_PATH"
    exit 1
  fi

  # Retry safety: interrupted codesign runs can leave .cstemp files behind.
  find "$SIGN_TARGET_PATH" -name "*.cstemp" -delete

  # Sign embedded frameworks/dylibs first (inside-out signing), then the outer app.
  if [[ -d "$SIGN_TARGET_PATH/Contents/Frameworks" ]]; then
    find "$SIGN_TARGET_PATH/Contents/Frameworks" \( -name "*.framework" -o -name "*.dylib" \) -print0 | while IFS= read -r -d '' fw; do
      echo "Signing embedded: $fw"
      codesign "${CODESIGN_ARGS[@]}" --options runtime "$fw"
    done
  fi

  codesign \
    "${CODESIGN_ARGS[@]}" \
    --options runtime \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$SIGN_TARGET_PATH"

  echo "Verifying app signature"
  codesign --verify --deep --strict --verbose=2 "$SIGN_TARGET_PATH"
  echo "Signed app ready for notarization: $SIGN_TARGET_PATH"
  exit 0
fi

if [[ -f "$SIGN_TARGET_PATH" && "$SIGN_TARGET_PATH" == *.dmg ]]; then
  echo "Signing disk image $SIGN_TARGET_PATH"
  codesign "${CODESIGN_ARGS[@]}" "$SIGN_TARGET_PATH"
  echo "Verifying disk image signature"
  codesign --verify --verbose=2 "$SIGN_TARGET_PATH"
  echo "Signed disk image ready for notarization: $SIGN_TARGET_PATH"
  exit 0
fi

echo "Unsupported sign target: $SIGN_TARGET_PATH"
echo "Expected a .app bundle or .dmg file."
exit 1
