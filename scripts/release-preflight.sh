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

run_root_cmd() {
  local label="$1"
  shift
  run_check "$label" bash -lc 'cd "$1" && shift && "$@"' -- "$ROOT_DIR" "$@"
}

# ── Tooling checks ──────────────────────────────────────────────────────────

check_cmd cargo
check_cmd rustc
check_cmd git
check_cmd xcrun
check_cmd codesign
check_cmd xcodebuild
check_cmd xcodegen

# ── Rust quality gates ───────────────────────────────────────────────────────

run_root_cmd "cargo fmt --all -- --check" cargo fmt --all -- --check
run_root_cmd "cargo clippy --workspace --all-targets -- -D warnings" cargo clippy --workspace --all-targets -- -D warnings
run_root_cmd "cargo test --workspace" cargo test --workspace
run_root_cmd "cargo deny check" cargo deny check

# ── Native build validation ──────────────────────────────────────────────────

print_check "xcodegen: generate project"
if (cd "$NATIVE_DIR" && xcodegen generate --spec project.yml --project . >/dev/null 2>&1); then
  pass "xcodegen project generated"
else
  fail "xcodegen project generation failed"
fi

print_check "xcodebuild: release build"
if xcodebuild build -project "$NATIVE_DIR/Pnevma.xcodeproj" -scheme Pnevma -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO >/dev/null 2>&1; then
  pass "xcodebuild release build succeeded"
else
  fail "xcodebuild release build failed"
fi

# ── Environment variables for signing ────────────────────────────────────────

for key in \
  APPLE_SIGNING_IDENTITY \
  APPLE_NOTARY_PROFILE \
  VERSION \
  TARGET_TRIPLE
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
