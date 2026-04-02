#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="$ROOT_DIR/native"
FAILURES=0
RELEASE_REQUIRE_SIGNING_ENV="${RELEASE_REQUIRE_SIGNING_ENV:-0}"
PREVIEW_ARTIFACT_DIR=""

cleanup() {
  if [[ -n "$PREVIEW_ARTIFACT_DIR" && -d "$PREVIEW_ARTIFACT_DIR" ]]; then
    rm -rf "$PREVIEW_ARTIFACT_DIR"
  fi
}
trap cleanup EXIT

current_branch() {
  git -C "$ROOT_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

resolve_sync_ref() {
  if [[ -n "${RELEASE_GIT_SYNC_REF:-}" ]]; then
    printf '%s\n' "$RELEASE_GIT_SYNC_REF"
    return 0
  fi

  if [[ "$(current_branch)" == "main" || "${GITHUB_REF_NAME:-}" == "main" ]]; then
    printf 'origin/main\n'
  fi
}

resolve_release_app_path() {
  local candidate
  for candidate in \
    "$NATIVE_DIR/build/Release/Pnevma.app" \
    "$NATIVE_DIR/build/Build/Products/Release/Pnevma.app"
  do
    if [[ -d "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  printf '%s\n' "$NATIVE_DIR/build/Release/Pnevma.app"
}

resolve_release_version() {
  "$ROOT_DIR/scripts/release-version.sh" check
}

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
  print_check "$label"
  if (
    cd "$dir"
    "$@"
  ); then
    pass "$label"
  else
    fail "$label"
  fi
}

check_git_clean() {
  local status
  print_check "git: worktree clean"
  status="$(git -C "$ROOT_DIR" status --short --untracked-files=normal)"
  if [[ -n "$status" ]]; then
    printf '%s\n' "$status"
    fail "git worktree is dirty"
  else
    pass "git worktree is clean"
  fi
}

check_git_sync() {
  local sync_ref ahead behind
  sync_ref="$(resolve_sync_ref)"

  if [[ -z "$sync_ref" ]]; then
    print_check "git: sync status"
    pass "skipped sync check on non-main branch"
    return 0
  fi

  print_check "git: sync with $sync_ref"
  if ! git -C "$ROOT_DIR" rev-parse --verify "$sync_ref" >/dev/null 2>&1; then
    fail "$sync_ref is unavailable; fetch full history or set RELEASE_GIT_SYNC_REF"
    return 0
  fi

  read -r ahead behind < <(git -C "$ROOT_DIR" rev-list --left-right --count HEAD..."$sync_ref")
  if [[ "$ahead" == "0" && "$behind" == "0" ]]; then
    pass "HEAD matches $sync_ref"
  else
    fail "HEAD is ahead by $ahead and behind by $behind relative to $sync_ref"
  fi
}

# ── Tooling checks ──────────────────────────────────────────────────────────

check_cmd cargo
check_cmd cargo-deny
check_cmd rustc
check_cmd git
check_cmd just
check_cmd swift
check_cmd xcrun
check_cmd codesign
check_cmd xcodebuild
check_cmd xcodegen
check_cmd zig

# ── Git release hygiene ─────────────────────────────────────────────────────

check_git_clean
check_git_sync

# ── Release metadata alignment ──────────────────────────────────────────────

run_in_dir "$ROOT_DIR" "release metadata alignment" ./scripts/release-version.sh check

# ── Rust quality gates ───────────────────────────────────────────────────────

run_in_dir "$ROOT_DIR" "just check" just check
run_in_dir "$ROOT_DIR" "agent team rehydrate validation" cargo test -p pnevma-commands agent_teams::tests::collect_rehydrated_teams_preserves_remote_target_metadata -- --exact
run_in_dir "$ROOT_DIR" "cargo deny check" cargo deny check
run_in_dir "$ROOT_DIR" "just ghostty-build" just ghostty-build
run_in_dir "$ROOT_DIR" "just spm-test-clean" just spm-test-clean
run_in_dir "$ROOT_DIR" "just xcodegen-check" just xcodegen-check

# ── Native build validation ──────────────────────────────────────────────────

run_in_dir "$ROOT_DIR" "just xcode-build-release" just xcode-build-release

print_check "xcodebuild: release entitlements"
if ./scripts/check-entitlements.sh >/dev/null 2>&1; then
  pass "checked-in entitlements match allowlist"
else
  fail "checked-in entitlements do not match allowlist"
fi

release_version="$(resolve_release_version)"
PREVIEW_ARTIFACT_DIR="$(mktemp -d -t pnevma-release-preflight.XXXXXX)"
release_dmg_path="$PREVIEW_ARTIFACT_DIR/Pnevma-${release_version}-macos-arm64.dmg"
release_checksum_path="${release_dmg_path}.sha256"

print_check "package release DMG"
if APP_PATH="$(resolve_release_app_path)" \
  DMG_PATH="$release_dmg_path" \
  CHECKSUM_PATH="$release_checksum_path" \
  ./scripts/release-macos-package-dmg.sh >/dev/null 2>&1; then
  pass "package release DMG"
else
  fail "package release DMG"
fi

print_check "packaged launch smoke"
if DMG_PATH="$release_dmg_path" ./scripts/run-packaged-launch-smoke.sh >/dev/null 2>&1; then
  pass "packaged launch smoke succeeded"
else
  fail "packaged launch smoke failed"
fi

# ── Optional environment variables for signing ──────────────────────────────

if [[ "$RELEASE_REQUIRE_SIGNING_ENV" == "1" ]]; then
  for key in \
    APPLE_SIGNING_IDENTITY \
    APPLE_NOTARY_PROFILE
  do
    check_env_var "$key"
  done
else
  print_check "env: signing credentials"
  pass "signing env checks skipped (set RELEASE_REQUIRE_SIGNING_ENV=1 to enforce)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

printf "\n---- Release Preflight Summary ----\n"
if [[ "$FAILURES" -gt 0 ]]; then
  printf "Preflight failed with %d check(s).\n" "$FAILURES"
  exit 1
fi

printf "Preflight passed.\n"
