#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CHECKSUM_FILE="$ROOT_DIR/crates/pnevma-db/migrations/checksums.sha256"

if [[ ! -f "$CHECKSUM_FILE" ]]; then
  echo "Missing checksum manifest: $CHECKSUM_FILE"
  exit 1
fi

cd "$ROOT_DIR"
shasum -a 256 -c "$CHECKSUM_FILE"
