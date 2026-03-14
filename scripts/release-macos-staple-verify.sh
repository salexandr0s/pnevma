#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/release-common.sh"

STAPLE_TARGET_PATH="${TARGET_PATH:-${APP_PATH:-}}"

if [[ -z "$STAPLE_TARGET_PATH" ]]; then
  STAPLE_TARGET_PATH="$(default_app_path)"
fi

if [[ ! -e "$STAPLE_TARGET_PATH" ]]; then
  echo "Staple target not found at $STAPLE_TARGET_PATH"
  exit 1
fi

echo "Stapling notarization ticket"
xcrun stapler staple "$STAPLE_TARGET_PATH"

echo "Validating stapled ticket"
xcrun stapler validate "$STAPLE_TARGET_PATH"

if [[ -d "$STAPLE_TARGET_PATH" && "$STAPLE_TARGET_PATH" == *.app ]]; then
  codesign --verify --deep --strict --verbose=2 "$STAPLE_TARGET_PATH"
  spctl --assess --type execute --verbose=4 "$STAPLE_TARGET_PATH"
  echo "Stapled + verified app: $STAPLE_TARGET_PATH"
  exit 0
fi

if [[ -f "$STAPLE_TARGET_PATH" && "$STAPLE_TARGET_PATH" == *.dmg ]]; then
  codesign --verify --verbose=2 "$STAPLE_TARGET_PATH"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$STAPLE_TARGET_PATH"
  echo "Stapled + verified disk image: $STAPLE_TARGET_PATH"
  exit 0
fi

echo "Unsupported staple target: $STAPLE_TARGET_PATH"
echo "Expected a .app bundle or .dmg file."
exit 1
