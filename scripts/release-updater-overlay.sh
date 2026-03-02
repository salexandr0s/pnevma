#!/usr/bin/env bash
set -euo pipefail

UPDATER_ENDPOINT="${PNEVMA_UPDATER_ENDPOINT:-}"
UPDATER_PUBKEY="${PNEVMA_UPDATER_PUBKEY:-}"
OVERLAY_PATH="${OVERLAY_PATH:-target/release/updater-overlay.json}"

if [[ -z "$UPDATER_ENDPOINT" ]]; then
  echo "PNEVMA_UPDATER_ENDPOINT is required"
  exit 1
fi
if [[ -z "$UPDATER_PUBKEY" ]]; then
  echo "PNEVMA_UPDATER_PUBKEY is required"
  exit 1
fi

json_escape() {
  printf '%s' "$1" | perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'
}

endpoint_escaped="$(json_escape "$UPDATER_ENDPOINT")"
pubkey_escaped="$(json_escape "$UPDATER_PUBKEY")"

mkdir -p "$(dirname "$OVERLAY_PATH")"

cat > "$OVERLAY_PATH" <<EOF
{
  "plugins": {
    "updater": {
      "active": true,
      "dialog": false,
      "endpoints": ["$endpoint_escaped"],
      "pubkey": "$pubkey_escaped"
    }
  }
}
EOF

echo "Updater overlay config written: $OVERLAY_PATH"
echo "Use with:"
echo "  cargo tauri build --manifest-path crates/pnevma-app/Cargo.toml -c \"$OVERLAY_PATH\""
