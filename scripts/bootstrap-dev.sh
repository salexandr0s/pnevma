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
check_cmd node
check_cmd npm

if [[ "$missing" -ne 0 ]]; then
  echo "\nInstall missing dependencies and rerun scripts/bootstrap-dev.sh"
  exit 1
fi

echo "\nInstalling frontend dependencies..."
cd "$(dirname "$0")/../frontend"
if [[ -f package-lock.json ]]; then
  npm ci
else
  npm install
fi

echo "\nBootstrap complete. Run: make check"
