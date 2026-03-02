#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-}"
TARGET_TRIPLE="${TARGET_TRIPLE:-}"
ARTIFACT_PATH="${ARTIFACT_PATH:-}"
SIGNATURE_PATH="${SIGNATURE_PATH:-}"
BASE_URL="${BASE_URL:-}"
FEED_PATH="${FEED_PATH:-target/release/bundle/updater/latest.json}"
NOTES_FILE="${NOTES_FILE:-}"

if [[ -z "$VERSION" ]]; then
  echo "VERSION is required"
  exit 1
fi
if [[ -z "$TARGET_TRIPLE" ]]; then
  echo "TARGET_TRIPLE is required (example: darwin-aarch64)"
  exit 1
fi
if [[ -z "$ARTIFACT_PATH" ]]; then
  echo "ARTIFACT_PATH is required"
  exit 1
fi
if [[ -z "$SIGNATURE_PATH" ]]; then
  echo "SIGNATURE_PATH is required"
  exit 1
fi
if [[ -z "$BASE_URL" ]]; then
  echo "BASE_URL is required (public URL prefix where artifacts are hosted)"
  exit 1
fi
if [[ ! -f "$ARTIFACT_PATH" ]]; then
  echo "Artifact not found: $ARTIFACT_PATH"
  exit 1
fi
if [[ ! -f "$SIGNATURE_PATH" ]]; then
  echo "Signature not found: $SIGNATURE_PATH"
  exit 1
fi

ARTIFACT_NAME="$(basename "$ARTIFACT_PATH")"
ARTIFACT_URL="${BASE_URL%/}/$ARTIFACT_NAME"
SIGNATURE_RAW="$(cat "$SIGNATURE_PATH")"
PUB_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

NOTES="Release $VERSION"
if [[ -n "$NOTES_FILE" ]]; then
  if [[ ! -f "$NOTES_FILE" ]]; then
    echo "Notes file not found: $NOTES_FILE"
    exit 1
  fi
  NOTES="$(cat "$NOTES_FILE")"
fi

json_escape() {
  printf '%s' "$1" | perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\n/\\n/g'
}

NOTES_ESCAPED="$(json_escape "$NOTES")"
SIGNATURE_ESCAPED="$(json_escape "$SIGNATURE_RAW")"

mkdir -p "$(dirname "$FEED_PATH")"

cat > "$FEED_PATH" <<EOF
{
  "version": "$VERSION",
  "notes": "$NOTES_ESCAPED",
  "pub_date": "$PUB_DATE",
  "platforms": {
    "$TARGET_TRIPLE": {
      "signature": "$SIGNATURE_ESCAPED",
      "url": "$ARTIFACT_URL"
    }
  }
}
EOF

echo "Updater feed manifest written: $FEED_PATH"
