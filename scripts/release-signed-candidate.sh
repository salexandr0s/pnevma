#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/release-common.sh"

APP_PATH="${APP_PATH:-}"
VERSION="${VERSION:-$("$ROOT_DIR/scripts/release-version.sh" check)}"
DMG_PATH="${DMG_PATH:-$ROOT_DIR/Pnevma-${VERSION}-macos-arm64.dmg}"
CHECKSUM_PATH="${CHECKSUM_PATH:-${DMG_PATH}.sha256}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT_DIR/release-evidence}"
RUN_PREFLIGHT="${RUN_PREFLIGHT:-1}"

if [[ -z "${APPLE_SIGNING_IDENTITY:-}" ]]; then
  echo "APPLE_SIGNING_IDENTITY is required"
  exit 1
fi

if [[ -z "$APP_PATH" ]]; then
  APP_PATH="$(default_app_path)"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH"
  exit 1
fi

AUTOMATED_DIR="$EVIDENCE_DIR/automated"
mkdir -p "$AUTOMATED_DIR"

if [[ "$RUN_PREFLIGHT" == "1" ]]; then
  "$ROOT_DIR/scripts/release-preflight.sh"
fi

EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_MODE="signed-only" VERSION="$VERSION" \
  "$ROOT_DIR/scripts/release-evidence.sh" init

APP_PATH="$APP_PATH" "$ROOT_DIR/scripts/release-macos-sign.sh" | tee "$AUTOMATED_DIR/app-sign.txt"
APP_PATH="$APP_PATH" "$ROOT_DIR/scripts/check-entitlements.sh" | tee "$AUTOMATED_DIR/app-entitlements-check.txt"

"$ROOT_DIR/scripts/run-app-smoke.sh" \
  --app "$APP_PATH" \
  --mode launch \
  --log "$AUTOMATED_DIR/signed-app-launch-smoke.log"

"$ROOT_DIR/scripts/run-app-smoke.sh" \
  --app "$APP_PATH" \
  --mode ghostty \
  --log "$AUTOMATED_DIR/signed-app-ghostty-smoke.log"

APP_PATH="$APP_PATH" \
DMG_PATH="$DMG_PATH" \
CHECKSUM_PATH="$CHECKSUM_PATH" \
"$ROOT_DIR/scripts/release-macos-package-dmg.sh" | tee "$AUTOMATED_DIR/dmg-package.txt"

TARGET_PATH="$DMG_PATH" "$ROOT_DIR/scripts/release-macos-sign.sh" | tee "$AUTOMATED_DIR/dmg-sign.txt"

DMG_PATH="$DMG_PATH" \
LOG_PATH="$AUTOMATED_DIR/packaged-launch-smoke.log" \
"$ROOT_DIR/scripts/run-packaged-launch-smoke.sh"

EVIDENCE_DIR="$EVIDENCE_DIR" \
RELEASE_MODE="signed-only" \
VERSION="$VERSION" \
APP_PATH="$APP_PATH" \
DMG_PATH="$DMG_PATH" \
CHECKSUM_PATH="$CHECKSUM_PATH" \
"$ROOT_DIR/scripts/release-evidence.sh" collect

echo "Signed candidate ready:"
echo "  app: $APP_PATH"
echo "  dmg: $DMG_PATH"
echo "  checksum: $CHECKSUM_PATH"
echo "  evidence: $EVIDENCE_DIR"
