#!/usr/bin/env bash
set -euo pipefail
# Shared helpers for macOS release scripts.
# Source this file; do not execute directly.

RELEASE_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Locate the release .app bundle.
# Checks two common xcodebuild output layouts.
default_app_path() {
  local candidates=(
    "$RELEASE_ROOT_DIR/native/build/Release/Pnevma.app"
    "$RELEASE_ROOT_DIR/native/build/Build/Products/Release/Pnevma.app"
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
