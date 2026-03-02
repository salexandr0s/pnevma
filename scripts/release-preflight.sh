#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/frontend"
FAILURES=0

print_check() {
  printf "\n==> %s\n" "$1"
}

pass() {
  printf "PASS: %s\n" "$1"
}

fail() {
  printf "FAIL: %s\n" "$1"
  FAILURES=$((FAILURES + 1))
}

check_cmd() {
  local cmd="$1"
  print_check "tooling: $cmd"
  if command -v "$cmd" >/dev/null 2>&1; then
    pass "$cmd is available"
  else
    fail "$cmd not found on PATH"
  fi
}

check_env_var() {
  local key="$1"
  print_check "env: $key"
  if [[ -z "${!key:-}" ]]; then
    fail "$key is required"
  else
    pass "$key is set"
  fi
}

run_check() {
  local label="$1"
  shift
  print_check "$label"
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

run_root_cmd() {
  local label="$1"
  shift
  run_check "$label" bash -lc "cd \"$ROOT_DIR\" && $*"
}

run_frontend_cmd() {
  local label="$1"
  shift
  run_check "$label" bash -lc "cd \"$FRONTEND_DIR\" && $*"
}

check_cmd cargo
check_cmd rustc
check_cmd git
check_cmd node
check_cmd npm
check_cmd npx
check_cmd xcrun
check_cmd codesign

print_check "tooling: cargo-tauri subcommand"
if ! cargo tauri --version >/dev/null 2>&1; then
  fail "cargo tauri subcommand unavailable (run: cargo install tauri-cli)"
else
  pass "cargo tauri subcommand is available"
fi

run_root_cmd "cargo fmt --all -- --check" "cargo fmt --all -- --check"
run_root_cmd "cargo clippy --workspace --all-targets -- -D warnings" "cargo clippy --workspace --all-targets -- -D warnings"
run_root_cmd "cargo test --workspace" "cargo test --workspace"

run_frontend_cmd "npx tsc --noEmit" "npx tsc --noEmit"
run_frontend_cmd "npx eslint ." "npx eslint ."
run_frontend_cmd "npx vite build" "npx vite build"

for key in \
  APPLE_SIGNING_IDENTITY \
  APPLE_NOTARY_PROFILE \
  PNEVMA_UPDATER_ENDPOINT \
  PNEVMA_UPDATER_PUBKEY \
  PNEVMA_UPDATER_PRIVATE_KEY_PATH \
  VERSION \
  TARGET_TRIPLE \
  BASE_URL
do
  check_env_var "$key"
done

print_check "env: updater private key path exists"
if [[ -n "${PNEVMA_UPDATER_PRIVATE_KEY_PATH:-}" && -f "${PNEVMA_UPDATER_PRIVATE_KEY_PATH:-}" ]]; then
  pass "updater private key found"
else
  fail "updater private key missing: ${PNEVMA_UPDATER_PRIVATE_KEY_PATH:-<unset>}"
fi

TMP_OVERLAY="$(mktemp "${TMPDIR:-/tmp}/pnevma-updater-overlay.XXXXXX.json")"
cleanup() {
  rm -f "$TMP_OVERLAY"
}
trap cleanup EXIT

run_check "updater overlay generation" bash -lc "cd \"$ROOT_DIR\" && OVERLAY_PATH=\"$TMP_OVERLAY\" ./scripts/release-updater-overlay.sh"
run_check "updater overlay schema sanity" node -e '
const fs = require("fs");
const path = process.argv[1];
const payload = JSON.parse(fs.readFileSync(path, "utf8"));
const updater = payload?.plugins?.updater;
if (!updater || updater.active !== true) process.exit(1);
if (!Array.isArray(updater.endpoints) || updater.endpoints.length === 0) process.exit(1);
if (typeof updater.pubkey !== "string" || updater.pubkey.trim() === "") process.exit(1);
' "$TMP_OVERLAY"

printf "\n---- Release Preflight Summary ----\n"
if [[ "$FAILURES" -gt 0 ]]; then
  printf "Preflight failed with %d check(s).\n" "$FAILURES"
  exit 1
fi

printf "Preflight passed.\n"
