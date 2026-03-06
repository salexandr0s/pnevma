#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="$ROOT_DIR/native"
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

run_in_dir() {
  local dir="$1"
  local label="$2"
  shift 2
  run_check "$label" bash -lc 'cd "$1" && shift && "$@"' -- "$dir" "$@"
}

# ── Tooling checks ──────────────────────────────────────────────────────────

check_cmd cargo
check_cmd rustc
check_cmd git
check_cmd just
check_cmd swift
check_cmd xcrun
check_cmd codesign
check_cmd xcodebuild
check_cmd xcodegen
check_cmd zig

# ── Rust quality gates ───────────────────────────────────────────────────────

run_in_dir "$ROOT_DIR" "just check" just check
run_in_dir "$ROOT_DIR" "cargo deny check" cargo deny check
run_in_dir "$ROOT_DIR" "just ghostty-build" just ghostty-build
run_in_dir "$ROOT_DIR" "just spm-test-clean" just spm-test-clean

# ── Native build validation ──────────────────────────────────────────────────

print_check "xcodegen: generate project"
if (cd "$NATIVE_DIR" && xcodegen generate --spec project.yml --project . >/dev/null 2>&1); then
  pass "xcodegen project generated"
else
  fail "xcodegen project generation failed"
fi

run_in_dir "$ROOT_DIR" "just xcode-build-release" just xcode-build-release

print_check "xcodebuild: release entitlements"
if APP_PATH="$NATIVE_DIR/build/Build/Products/Release/Pnevma.app" ./scripts/check-entitlements.sh >/dev/null 2>&1; then
  pass "release entitlements match allowlist"
else
  fail "release entitlements do not match allowlist"
fi

print_check "packaged launch smoke"
if APP_PATH="$NATIVE_DIR/build/Build/Products/Release/Pnevma.app" ./scripts/run-packaged-launch-smoke.sh >/dev/null 2>&1; then
  pass "packaged launch smoke succeeded"
else
  fail "packaged launch smoke failed"
fi

# ── Environment variables for signing ───────────────────────────────────────

for key in \
  APPLE_SIGNING_IDENTITY \
  APPLE_NOTARY_PROFILE
do
  check_env_var "$key"
done

# ── Summary ──────────────────────────────────────────────────────────────────

printf "\n---- Release Preflight Summary ----\n"
if [[ "$FAILURES" -gt 0 ]]; then
  printf "Preflight failed with %d check(s).\n" "$FAILURES"
  exit 1
fi

printf "Preflight passed.\n"
