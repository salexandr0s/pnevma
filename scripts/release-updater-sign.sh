#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_PATH="${ARTIFACT_PATH:-}"
UPDATER_KEY_PATH="${PNEVMA_UPDATER_PRIVATE_KEY_PATH:-}"
UPDATER_KEY_PASSWORD="${PNEVMA_UPDATER_PRIVATE_KEY_PASSWORD:-}"

if [[ -z "$ARTIFACT_PATH" ]]; then
  echo "ARTIFACT_PATH is required"
  exit 1
fi
if [[ -z "$UPDATER_KEY_PATH" ]]; then
  echo "PNEVMA_UPDATER_PRIVATE_KEY_PATH is required"
  exit 1
fi
if [[ ! -f "$ARTIFACT_PATH" ]]; then
  echo "Artifact not found: $ARTIFACT_PATH"
  exit 1
fi
if [[ ! -f "$UPDATER_KEY_PATH" ]]; then
  echo "Updater private key not found: $UPDATER_KEY_PATH"
  exit 1
fi

SIGNATURE_PATH="${SIGNATURE_PATH:-$ARTIFACT_PATH.sig}"

generated_sig="${ARTIFACT_PATH}.sig"

if [[ -n "$UPDATER_KEY_PASSWORD" ]]; then
  cargo tauri signer sign \
    -f "$UPDATER_KEY_PATH" \
    -p "$UPDATER_KEY_PASSWORD" \
    "$ARTIFACT_PATH" >/dev/null
else
  cargo tauri signer sign \
    -f "$UPDATER_KEY_PATH" \
    "$ARTIFACT_PATH" >/dev/null
fi

if [[ ! -f "$generated_sig" ]]; then
  echo "Signer did not produce expected signature file: $generated_sig"
  exit 1
fi

if [[ "$SIGNATURE_PATH" != "$generated_sig" ]]; then
  cp "$generated_sig" "$SIGNATURE_PATH"
fi

echo "Updater signature written: $SIGNATURE_PATH"
