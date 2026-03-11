#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MIGRATIONS_DIR="$ROOT_DIR/crates/pnevma-db/migrations"
CHECKSUM_FILE="$MIGRATIONS_DIR/checksums.sha256"

cd "$ROOT_DIR"

# Regenerate checksums from all .sql files
GENERATED=$(find "$MIGRATIONS_DIR" -name '*.sql' ! -name 'checksums.sha256' | sort | while read -r f; do
  REL="crates/pnevma-db/migrations/$(basename "$f")"
  shasum -a 256 "$REL"
done)

if [[ ! -f "$CHECKSUM_FILE" ]]; then
  echo "$GENERATED" > "$CHECKSUM_FILE"
  echo "Created checksum manifest with $(echo "$GENERATED" | wc -l | tr -d ' ') entries."
  exit 0
fi

CURRENT=$(cat "$CHECKSUM_FILE")

if [[ "$GENERATED" != "$CURRENT" ]]; then
  echo "$GENERATED" > "$CHECKSUM_FILE"
  echo "Updated checksum manifest (was out of date)."
  echo "Re-run 'just check' to verify."
  exit 1
fi

echo "Migration checksums OK."
