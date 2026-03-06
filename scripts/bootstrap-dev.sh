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

channel_from_toolchain() {
  sed -n 's/^channel = "\(.*\)"/\1/p' rust-toolchain.toml | head -n 1
}

echo "Checking toolchain..."
check_cmd cargo
check_cmd rustc
check_cmd just
check_cmd zig
check_cmd xcodegen

if command -v rustup >/dev/null 2>&1; then
  echo "ok: rustup ($(command -v rustup))"
else
  echo "missing: rustup"
  missing=1
fi

if [[ "$missing" -ne 0 ]]; then
  echo "\nInstall missing dependencies and rerun scripts/bootstrap-dev.sh"
  exit 1
fi

channel="$(channel_from_toolchain)"
if [[ -n "$channel" ]]; then
  rustup toolchain install "$channel" --component rustfmt --component clippy >/dev/null
  echo "ok: rustup toolchain $channel"
fi

echo "Fetching Ghostty source checkout..."
"$(cd "$(dirname "$0")/.." && pwd)/scripts/fetch-ghostty.sh"

echo "\nBootstrap complete. Run: just check"
