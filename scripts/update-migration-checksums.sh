#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MIGRATIONS_DIR="$ROOT_DIR/crates/pnevma-db/migrations"
CHECKSUM_FILE="$MIGRATIONS_DIR/checksums.sha256"

cd "$ROOT_DIR"

find "$MIGRATIONS_DIR" -name '*.sql' ! -name 'checksums.sha256' | sort | while read -r f; do
  REL="crates/pnevma-db/migrations/$(basename "$f")"
  shasum -a 256 "$REL"
done > "$CHECKSUM_FILE"

echo "Updated checksum manifest with $(wc -l < "$CHECKSUM_FILE" | tr -d ' ') entries."
