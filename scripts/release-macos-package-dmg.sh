#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-}"
VERSION="${VERSION:-}"
DMG_PATH="${DMG_PATH:-}"
CHECKSUM_PATH="${CHECKSUM_PATH:-}"
VOLUME_NAME="${DMG_VOLUME_NAME:-Pnevma}"
ARCH_SUFFIX="${ARCH_SUFFIX:-arm64}"

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

resolve_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/native/Info.plist"
}

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$(default_app_path)"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  exit 1
fi

if [[ -z "$VERSION" ]]; then
  VERSION="$(resolve_version)"
fi

if [[ -z "$DMG_PATH" ]]; then
  DMG_PATH="$ROOT_DIR/Pnevma-${VERSION}-macos-${ARCH_SUFFIX}.dmg"
fi

if [[ -z "$CHECKSUM_PATH" ]]; then
  CHECKSUM_PATH="${DMG_PATH}.sha256"
fi

staging_dir="$(mktemp -d -t pnevma-dmg-staging.XXXXXX)"
cleanup() {
  rm -rf "$staging_dir"
}
trap cleanup EXIT

mkdir -p "$staging_dir"
ditto "$APP_PATH" "$staging_dir/$(basename "$APP_PATH")"
ln -s /Applications "$staging_dir/Applications"

rm -f "$DMG_PATH" "$CHECKSUM_PATH"
echo "Creating DMG at $DMG_PATH"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$staging_dir" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Writing checksum to $CHECKSUM_PATH"
shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"

echo "Created DMG: $DMG_PATH"
echo "Created checksum: $CHECKSUM_PATH"
