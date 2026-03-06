#!/usr/bin/env bash
set -euo pipefail

missing=0

check_cmd() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "missing: $name"
    missing=1
  else
    echo "ok: $name ($(command -v "$name"))"
  fi
}

echo "Checking toolchain..."
check_cmd cargo
check_cmd just
check_cmd zig
check_cmd xcodegen

if [[ "$missing" -ne 0 ]]; then
  echo "\nInstall missing dependencies and rerun scripts/bootstrap-dev.sh"
  exit 1
fi

echo "\nBootstrap complete. Run: just check"
