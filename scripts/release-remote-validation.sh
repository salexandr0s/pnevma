#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/release-common.sh"

APP_PATH="${APP_PATH:-}"
DMG_PATH="${DMG_PATH:-}"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT_DIR/release-evidence}"
REMOTE_EVIDENCE_DIR="$EVIDENCE_DIR/remote"
LOG_ROOT="${LOG_ROOT:-$ROOT_DIR/native/build/logs}"
RELEASE_MODE="${RELEASE_MODE:-signed-only}"
VERSION="${VERSION:-$("$ROOT_DIR/scripts/release-version.sh" check)}"

REMOTE_HELPER_SMOKE_CMD="${REMOTE_HELPER_SMOKE_CMD:-$ROOT_DIR/scripts/run-packaged-remote-helper-smoke.sh}"
REMOTE_LIFECYCLE_SMOKE_CMD="${REMOTE_LIFECYCLE_SMOKE_CMD:-$ROOT_DIR/scripts/run-packaged-remote-durable-lifecycle-smoke.sh}"

CLEAN_MACHINE_REMOTE_LIFECYCLE_RESULT="${CLEAN_MACHINE_REMOTE_LIFECYCLE_RESULT:-not-run}"
CLEAN_MACHINE_REMOTE_LIFECYCLE_NOTES="${CLEAN_MACHINE_REMOTE_LIFECYCLE_NOTES:-}"

tmp_root="$(mktemp -d -t pnevma-release-remote-validation.XXXXXX)"
trap 'rm -rf "$tmp_root"' EXIT

usage() {
  cat <<'EOF'
Usage: release-remote-validation.sh

Runs the packaged remote helper and durable lifecycle release matrix and copies
the resulting log directories into the canonical release evidence bundle.

Environment:
  APP_PATH / DMG_PATH                      Packaged app or candidate DMG
  EVIDENCE_DIR                            Release evidence root (default: ./release-evidence)
  LOG_ROOT                                Smoke log root (default: native/build/logs)
  REMOTE_HELPER_SMOKE_CMD                 Override helper smoke command for testing
  REMOTE_LIFECYCLE_SMOKE_CMD              Override lifecycle smoke command for testing

Required host groups:
  REMOTE_LINUX_X86_64_HOST
  REMOTE_LINUX_AARCH64_HOST
  REMOTE_MAC_AARCH64_HOST

Per-host overrides (optional, otherwise fall back to global REMOTE_* values):
  REMOTE_<GROUP>_USER
  REMOTE_<GROUP>_PORT
  REMOTE_<GROUP>_IDENTITY_FILE
  REMOTE_<GROUP>_PROXY_JUMP

Global fallbacks:
  REMOTE_USER
  REMOTE_PORT
  REMOTE_IDENTITY_FILE
  REMOTE_PROXY_JUMP

Optional clean-machine status:
  CLEAN_MACHINE_REMOTE_LIFECYCLE_RESULT=pass|fail|not-run
  CLEAN_MACHINE_REMOTE_LIFECYCLE_NOTES="..."
EOF
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "error: required command not found: $name" >&2
    exit 1
  fi
}

canonicalize_path() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
}

ensure_artifact_input() {
  if [[ -z "$APP_PATH" && -z "$DMG_PATH" ]]; then
    APP_PATH="$(default_app_path)"
  fi

  if [[ -n "$DMG_PATH" ]]; then
    [[ -f "$DMG_PATH" ]] || {
      echo "error: DMG_PATH must point to an existing candidate DMG" >&2
      exit 1
    }
    return 0
  fi

  [[ -d "$APP_PATH" ]] || {
    echo "error: APP_PATH must point to an existing packaged Pnevma.app bundle" >&2
    exit 1
  }
}

global_or_default() {
  local name="$1"
  local fallback="${2:-}"
  local value="${!name:-}"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

group_value() {
  local group="$1"
  local suffix="$2"
  local global_name="$3"
  local fallback="${4:-}"
  local specific_name="REMOTE_${group}_${suffix}"
  local specific_value="${!specific_name:-}"
  if [[ -n "$specific_value" ]]; then
    printf '%s\n' "$specific_value"
  else
    global_or_default "$global_name" "$fallback"
  fi
}

require_group_host() {
  local group="$1"
  local value
  value="$(group_value "$group" HOST REMOTE_HOST)"
  if [[ -z "$value" ]]; then
    echo "error: REMOTE_${group}_HOST is required" >&2
    exit 1
  fi
}

latest_new_log_dir() {
  local pattern="$1"
  local marker="$2"
  python3 - "$LOG_ROOT" "$pattern" "$marker" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
pattern = sys.argv[2]
marker = Path(sys.argv[3]).stat().st_mtime

candidates = [
    path for path in root.glob(pattern)
    if path.is_dir() and path.stat().st_mtime >= marker
]
if not candidates:
    sys.exit(1)
candidates.sort(key=lambda path: path.stat().st_mtime, reverse=True)
print(candidates[0])
PY
}

copy_run_dir() {
  local source_dir="$1"
  local dest_dir="$2"
  rm -rf "$dest_dir"
  mkdir -p "$(dirname "$dest_dir")"
  ditto "$source_dir" "$dest_dir"
}

record_line() {
  local line="$1"
  printf '%s\n' "$line" >> "$tmp_root/summary-lines.txt"
}

run_helper_case() {
  local label="$1"
  local group="$2"
  local target_triple="$3"
  local scenario="$4"
  local marker="$tmp_root/${label}-${scenario}.marker"
  touch "$marker"

  local remote_host remote_user remote_port remote_identity_file remote_proxy_jump
  remote_host="$(group_value "$group" HOST REMOTE_HOST)"
  remote_user="$(group_value "$group" USER REMOTE_USER)"
  remote_port="$(group_value "$group" PORT REMOTE_PORT 22)"
  remote_identity_file="$(group_value "$group" IDENTITY_FILE REMOTE_IDENTITY_FILE)"
  remote_proxy_jump="$(group_value "$group" PROXY_JUMP REMOTE_PROXY_JUMP)"

  APP_PATH="$APP_PATH" \
  DMG_PATH="$DMG_PATH" \
  REMOTE_HOST="$remote_host" \
  REMOTE_USER="$remote_user" \
  REMOTE_PORT="$remote_port" \
  REMOTE_IDENTITY_FILE="$remote_identity_file" \
  REMOTE_PROXY_JUMP="$remote_proxy_jump" \
  EXPECTED_TARGET_TRIPLE="$target_triple" \
  SCENARIO="$scenario" \
  LOG_ROOT="$LOG_ROOT" \
  "$REMOTE_HELPER_SMOKE_CMD"

  local source_dir
  source_dir="$(latest_new_log_dir "remote-helper-smoke-${scenario}-*" "$marker")"
  local dest_dir="$REMOTE_EVIDENCE_DIR/helper/$label/$scenario"
  copy_run_dir "$source_dir" "$dest_dir"
  record_line "- helper/$label/$scenario -> $(canonicalize_path "$dest_dir")"
}

run_lifecycle_case() {
  local scenario="$1"
  local marker="$tmp_root/lifecycle-${scenario}.marker"
  touch "$marker"

  local remote_host remote_user remote_port remote_identity_file remote_proxy_jump
  remote_host="$(group_value MAC_AARCH64 HOST REMOTE_HOST)"
  remote_user="$(group_value MAC_AARCH64 USER REMOTE_USER)"
  remote_port="$(group_value MAC_AARCH64 PORT REMOTE_PORT 22)"
  remote_identity_file="$(group_value MAC_AARCH64 IDENTITY_FILE REMOTE_IDENTITY_FILE)"
  remote_proxy_jump="$(group_value MAC_AARCH64 PROXY_JUMP REMOTE_PROXY_JUMP)"

  APP_PATH="$APP_PATH" \
  DMG_PATH="$DMG_PATH" \
  REMOTE_HOST="$remote_host" \
  REMOTE_USER="$remote_user" \
  REMOTE_PORT="$remote_port" \
  REMOTE_IDENTITY_FILE="$remote_identity_file" \
  REMOTE_PROXY_JUMP="$remote_proxy_jump" \
  EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
  SCENARIO="$scenario" \
  LOG_ROOT="$LOG_ROOT" \
  "$REMOTE_LIFECYCLE_SMOKE_CMD"

  local source_dir
  source_dir="$(latest_new_log_dir "remote-durable-lifecycle-${scenario}-*" "$marker")"
  local dest_dir="$REMOTE_EVIDENCE_DIR/durable-lifecycle/$scenario"
  copy_run_dir "$source_dir" "$dest_dir"
  record_line "- durable-lifecycle/$scenario -> $(canonicalize_path "$dest_dir")"
}

write_remote_results() {
  local candidate_artifact status_line
  if [[ -n "$DMG_PATH" ]]; then
    candidate_artifact="$DMG_PATH"
  else
    candidate_artifact="$APP_PATH"
  fi

  status_line="pending"
  if [[ "$CLEAN_MACHINE_REMOTE_LIFECYCLE_RESULT" == "pass" || "$CLEAN_MACHINE_REMOTE_LIFECYCLE_RESULT" == "fail" ]]; then
    status_line="complete"
  fi

  cat > "$EVIDENCE_DIR/manual/remote-validation-results.md" <<EOF
# Remote validation results

- Status: $status_line
- Date: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- Candidate artifact: $candidate_artifact
- Remote enabled in candidate: yes
- Linux x86_64 helper smoke: pass
- Linux x86_64 canonical upgrade scenarios: pass
- Linux aarch64 helper smoke: pass
- Apple Silicon macOS helper smoke: pass
- Apple Silicon macOS canonical upgrade scenarios: pass
- Durable lifecycle scenarios: pass
- Clean-machine DMG remote lifecycle pass: $CLEAN_MACHINE_REMOTE_LIFECYCLE_RESULT
- Clean-machine notes: ${CLEAN_MACHINE_REMOTE_LIFECYCLE_NOTES:-n/a}

## Evidence directories

$(cat "$tmp_root/summary-lines.txt")
EOF
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
    usage
    exit 0
  fi

  require_command python3
  require_group_host LINUX_X86_64
  require_group_host LINUX_AARCH64
  require_group_host MAC_AARCH64
  ensure_artifact_input

  EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_MODE="$RELEASE_MODE" VERSION="$VERSION" \
    "$ROOT_DIR/scripts/release-evidence.sh" init
  mkdir -p "$REMOTE_EVIDENCE_DIR"
  : > "$tmp_root/summary-lines.txt"

  run_helper_case "linux-x86_64" "LINUX_X86_64" "x86_64-unknown-linux-musl" "fresh"
  run_helper_case "linux-aarch64" "LINUX_AARCH64" "aarch64-unknown-linux-musl" "fresh"
  run_helper_case "mac-aarch64" "MAC_AARCH64" "aarch64-apple-darwin" "fresh"

  run_helper_case "linux-x86_64" "LINUX_X86_64" "x86_64-unknown-linux-musl" "legacy_shell"
  run_helper_case "linux-x86_64" "LINUX_X86_64" "x86_64-unknown-linux-musl" "legacy_binary_version_mismatch"
  run_helper_case "linux-x86_64" "LINUX_X86_64" "x86_64-unknown-linux-musl" "legacy_binary_digest_mismatch"
  run_helper_case "linux-x86_64" "LINUX_X86_64" "x86_64-unknown-linux-musl" "legacy_binary_protocol_mismatch"

  run_helper_case "mac-aarch64" "MAC_AARCH64" "aarch64-apple-darwin" "legacy_shell"
  run_helper_case "mac-aarch64" "MAC_AARCH64" "aarch64-apple-darwin" "legacy_binary_version_mismatch"
  run_helper_case "mac-aarch64" "MAC_AARCH64" "aarch64-apple-darwin" "legacy_binary_digest_mismatch"
  run_helper_case "mac-aarch64" "MAC_AARCH64" "aarch64-apple-darwin" "legacy_binary_protocol_mismatch"

  run_lifecycle_case "disconnect_reconnect"
  run_lifecycle_case "detach_reattach"
  run_lifecycle_case "quit_relaunch_reattach"

  write_remote_results

  EVIDENCE_DIR="$EVIDENCE_DIR" RELEASE_MODE="$RELEASE_MODE" VERSION="$VERSION" \
    "$ROOT_DIR/scripts/release-evidence.sh" init

  echo "Remote release validation complete. Evidence written to $REMOTE_EVIDENCE_DIR"
}

main "$@"
