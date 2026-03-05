#!/usr/bin/env bash
set -euo pipefail

KEY_PATH="${PNEVMA_UPDATER_PRIVATE_KEY_PATH:-$HOME/.config/pnevma/updater/private.key}"
KEY_PASSWORD="${PNEVMA_UPDATER_PRIVATE_KEY_PASSWORD:-}"
FORCE="${FORCE:-false}"

mkdir -p "$(dirname "$KEY_PATH")"

args=(tauri signer generate --ci -w "$KEY_PATH")
if [[ -n "$KEY_PASSWORD" ]]; then
  # Tauri CLI reads password from this env var — avoids exposing it in process args.
  export TAURI_SIGNING_PRIVATE_KEY_PASSWORD="$KEY_PASSWORD"
fi
if [[ "$FORCE" == "true" ]]; then
  args+=(--force)
fi

cargo "${args[@]}" >/dev/null

pub_path="${KEY_PATH}.pub"
if [[ ! -f "$pub_path" ]]; then
  echo "Public key not found at $pub_path"
  exit 1
fi

echo "Updater keys generated:"
echo "private: $KEY_PATH"
echo "public:  $pub_path"
echo
echo "Use this public key in crates/pnevma-app/tauri.conf.json plugins.updater.pubkey:"
cat "$pub_path"
