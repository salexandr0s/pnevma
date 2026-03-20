#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=./scripts/ipc-common.sh
source "$ROOT_DIR/scripts/ipc-common.sh"

APP_PATH="${APP_PATH:-}"
DMG_PATH="${DMG_PATH:-}"
REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_USER="${REMOTE_USER:-}"
REMOTE_PORT="${REMOTE_PORT:-22}"
REMOTE_IDENTITY_FILE="${REMOTE_IDENTITY_FILE:-}"
REMOTE_PROXY_JUMP="${REMOTE_PROXY_JUMP:-}"
EXPECTED_TARGET_TRIPLE="${EXPECTED_TARGET_TRIPLE:-}"
SCENARIO="${SCENARIO:-fresh}"
LOG_ROOT="${LOG_ROOT:-$ROOT_DIR/native/build/logs}"
PROJECT_OPEN_TIMEOUT_SECS="${PROJECT_OPEN_TIMEOUT_SECS:-20}"
PNEVMA_CTL_TIMEOUT_SECS="${PNEVMA_CTL_TIMEOUT_SECS:-20}"

usage() {
  cat >&2 <<'EOF'
usage: APP_PATH=/path/to/Pnevma.app|DMG_PATH=/path/to/Pnevma.dmg \
       REMOTE_HOST=... REMOTE_USER=... [REMOTE_PORT=22] [REMOTE_IDENTITY_FILE=...] \
       [REMOTE_PROXY_JUMP=...] EXPECTED_TARGET_TRIPLE=... SCENARIO=... \
       ./scripts/run-packaged-remote-helper-smoke.sh

Supported scenarios:
  fresh
  legacy_shell
  legacy_binary_version_mismatch
  legacy_binary_digest_mismatch
  legacy_binary_protocol_mismatch
EOF
  exit 2
}

require_command() {
  local name="$1"
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "error: required command not found: $name" >&2
    exit 1
  fi
}

require_env() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "error: $name is required" >&2
    usage
  fi
}

require_numeric_port() {
  if [[ ! "$REMOTE_PORT" =~ ^[0-9]+$ ]]; then
    echo "error: REMOTE_PORT must be an integer, got '$REMOTE_PORT'" >&2
    exit 1
  fi
}

canonicalize_path() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
}

create_fixture_project() {
  temp_dir="$(mktemp -d /tmp/pnhs.XXXXXX)"
  PROJECT_PATH="$temp_dir/p"
  mkdir -p "$PROJECT_PATH"

  cat >"$PROJECT_PATH/README.md" <<'EOF'
# Pnevma Remote Helper Smoke Fixture

Temporary fixture project for packaged remote helper smoke validation.
EOF

  git -C "$PROJECT_PATH" init -q -b main
  git -C "$PROJECT_PATH" config user.email "remote-smoke@example.com"
  git -C "$PROJECT_PATH" config user.name "Remote Helper Smoke"
  git -C "$PROJECT_PATH" add README.md
  git -C "$PROJECT_PATH" commit -q -m "Initial commit"

  mkdir -p \
    "$PROJECT_PATH/.pnevma/data" \
    "$PROJECT_PATH/.pnevma/rules" \
    "$PROJECT_PATH/.pnevma/conventions"

  cat >"$PROJECT_PATH/pnevma.toml" <<'EOF'
[project]
name = "Remote Helper Smoke Fixture"
brief = "Temporary fixture workspace for packaged remote helper smoke validation"

[agents]
default_provider = "claude-code"
max_concurrent = 4

[branches]
target = "main"
naming = "task/{id}-{slug}"

[automation]
socket_enabled = true
socket_path = ".pnevma/run/control.sock"
socket_auth = "same-user"

[rules]
paths = [".pnevma/rules/*.md"]

[conventions]
paths = [".pnevma/conventions/*.md"]
EOF

  cat >"$PROJECT_PATH/.pnevma/rules/project-rules.md" <<'EOF'
# Project Rules

- Keep smoke validation scoped to release/runtime checks.
- Prefer deterministic SSH/runtime assertions over UI-only observations.
EOF

  cat >"$PROJECT_PATH/.pnevma/conventions/conventions.md" <<'EOF'
# Conventions

- Capture operator-visible evidence in native/build/logs.
- Fail fast when remote helper validation drifts from the bundled artifact.
EOF

  PROJECT_CANONICAL_PATH="$(canonicalize_path "$PROJECT_PATH")"
  PROJECT_DB_PATH="$PROJECT_PATH/.pnevma/pnevma.db"
  SOCKET_PATH="$PROJECT_PATH/.pnevma/run/control.sock"
  export PROJECT_PATH PROJECT_DB_PATH SOCKET_PATH
}

resolve_app_path() {
  if [[ -n "$APP_PATH" && -n "$DMG_PATH" ]]; then
    if [[ -f "$DMG_PATH" ]]; then
      APP_PATH=""
    else
      DMG_PATH=""
    fi
  fi

  if [[ -z "$APP_PATH" && -z "$DMG_PATH" ]]; then
    for candidate in \
      "$ROOT_DIR/native/build/Release/Pnevma.app" \
      "$ROOT_DIR/native/build/Build/Products/Release/Pnevma.app"
    do
      if [[ -d "$candidate" ]]; then
        APP_PATH="$candidate"
        break
      fi
    done
  fi

  if [[ -n "$DMG_PATH" ]]; then
    [[ -f "$DMG_PATH" ]] || {
      echo "error: DMG_PATH must point to a packaged Pnevma disk image" >&2
      exit 1
    }

    mounted_dir="$(mktemp -d -t pnevma-remote-helper-mount.XXXXXX)"
    copied_app_dir="$(mktemp -d -t pnevma-remote-helper-copy.XXXXXX)"
    hdiutil attach "$DMG_PATH" -mountpoint "$mounted_dir" -nobrowse -readonly -quiet

    mounted_app="$(find "$mounted_dir" -maxdepth 1 -type d -name 'Pnevma.app' -print -quit)"
    if [[ -z "$mounted_app" ]]; then
      echo "error: mounted disk image did not contain Pnevma.app" >&2
      exit 1
    fi

    APP_PATH="$copied_app_dir/Pnevma.app"
    ditto "$mounted_app" "$APP_PATH"
  fi

  [[ -n "$APP_PATH" && -d "$APP_PATH" ]] || {
    echo "error: APP_PATH must point to a packaged Pnevma.app bundle" >&2
    exit 1
  }

  APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Pnevma"
  [[ -x "$APP_EXECUTABLE" ]] || {
    echo "error: app executable not found: $APP_EXECUTABLE" >&2
    exit 1
  }
}

prepare_log_dir() {
  timestamp="$(date +%Y%m%d-%H%M%S)"
  run_id="${SCENARIO}-${timestamp}"
  RUN_LOG_DIR="${LOG_ROOT}/remote-helper-smoke-${run_id}"
  mkdir -p "$RUN_LOG_DIR"
  APP_LOG_PATH="$RUN_LOG_DIR/app.log"
  export RUN_LOG_DIR APP_LOG_PATH
}

load_bundle_expectations() {
  MANIFEST_PATH="$APP_PATH/Contents/Resources/remote-helper/manifest.json"
  [[ -f "$MANIFEST_PATH" ]] || {
    echo "error: bundled remote helper manifest not found at $MANIFEST_PATH" >&2
    exit 1
  }

  EXPECTED_PACKAGE_VERSION="$(jq -re '.package_version' "$MANIFEST_PATH")"
  EXPECTED_PROTOCOL_VERSION="$(jq -re '.protocol_version' "$MANIFEST_PATH")"
  EXPECTED_ARTIFACT_SHA="$(jq -re --arg triple "$EXPECTED_TARGET_TRIPLE" '.artifacts[] | select(.target_triple == $triple) | .sha256' "$MANIFEST_PATH")"
  EXPECTED_HELPER_VERSION="pnevma-remote-helper/${EXPECTED_PACKAGE_VERSION}"
}

seed_remote_fixture() {
  echo "[1/7] Seeding remote helper scenario: $SCENARIO"
  REMOTE_HOST="$REMOTE_HOST" \
  REMOTE_USER="$REMOTE_USER" \
  REMOTE_PORT="$REMOTE_PORT" \
  REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
  REMOTE_PROXY_JUMP="$REMOTE_PROXY_JUMP" \
  EXPECTED_TARGET_TRIPLE="$EXPECTED_TARGET_TRIPLE" \
  EXPECTED_PACKAGE_VERSION="$EXPECTED_PACKAGE_VERSION" \
  EXPECTED_PROTOCOL_VERSION="$EXPECTED_PROTOCOL_VERSION" \
  EXPECTED_ARTIFACT_SHA="$EXPECTED_ARTIFACT_SHA" \
  SCENARIO="$SCENARIO" \
  "$ROOT_DIR/scripts/seed-remote-helper-fixture.sh" | tee "$RUN_LOG_DIR/seed.log"
}

wait_for_project_socket() {
  local deadline=$((SECONDS + PROJECT_OPEN_TIMEOUT_SECS))
  while (( SECONDS < deadline )); do
    if [[ -S "$SOCKET_PATH" ]]; then
      return 0
    fi
    if ! kill -0 "$app_pid" >/dev/null 2>&1; then
      echo "error: app exited before project control socket became available; see $APP_LOG_PATH" >&2
      tail -n 80 "$APP_LOG_PATH" >&2 || true
      return 1
    fi
    sleep 1
  done

  echo "error: project control socket did not appear within ${PROJECT_OPEN_TIMEOUT_SECS}s at $SOCKET_PATH; see $APP_LOG_PATH" >&2
  tail -n 80 "$APP_LOG_PATH" >&2 || true
  return 1
}

wait_for_project_status() {
  local deadline=$((SECONDS + PROJECT_OPEN_TIMEOUT_SECS))
  local status_output=""
  local project_path=""
  while (( SECONDS < deadline )); do
    set +e
    status_output="$(pnevma_ctl project.status 2>&1)"
    local status=$?
    set -e
    if [[ $status -eq 0 ]]; then
      project_path="$(printf '%s' "$status_output" | jq -r '.result.project_path // empty')"
      if [[ -n "$project_path" && "$project_path" == "$PROJECT_CANONICAL_PATH" ]]; then
        printf '%s\n' "$status_output" >"$RUN_LOG_DIR/project-status.json"
        return 0
      fi
    fi
    sleep 1
  done

  echo "error: project.status did not become ready for fixture $PROJECT_PATH within ${PROJECT_OPEN_TIMEOUT_SECS}s" >&2
  if [[ -n "$status_output" ]]; then
    echo "$status_output" >&2
  fi
  return 1
}

launch_app() {
  if [[ -S "$SOCKET_PATH" ]]; then
    if pnevma_ctl environment.readiness "$(jq -n --arg path "$PROJECT_PATH" '{"path": $path}')" >/dev/null 2>&1; then
      echo "error: an existing control socket is already serving requests at $SOCKET_PATH" >&2
      exit 1
    fi
    rm -f "$SOCKET_PATH"
  fi

  echo "[2/7] Launching packaged app"
  (
    cd "$ROOT_DIR"
    unset PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT
    unset PNEVMA_REMOTE_HELPER_ARTIFACT_DIR
    unset PNEVMA_REMOTE_HELPER_BUNDLE_DIR
    unset PNEVMA_REMOTE_HELPER_ARTIFACT_X86_64_UNKNOWN_LINUX_MUSL
    unset PNEVMA_REMOTE_HELPER_ARTIFACT_AARCH64_UNKNOWN_LINUX_MUSL
    unset PNEVMA_SSH_BIN
    PNEVMA_UI_TESTING=1 \
    PNEVMA_UI_TEST_PROJECT_PATH="$PROJECT_PATH" \
    "$APP_EXECUTABLE" >"$APP_LOG_PATH" 2>&1
  ) &
  app_pid=$!

  wait_for_project_socket
  wait_for_project_status
}

write_json_log() {
  local name="$1"
  local body="$2"
  printf '%s\n' "$body" >"$RUN_LOG_DIR/$name"
}

run_ctl_json() {
  local method="$1"
  local params="${2-}"
  local log_name="$3"
  local output
  local status

  if [[ -z "$params" ]]; then
    params='{}'
  fi

  set +e
  output="$(
    RUN_CTL_JSON_PARAMS="$params" \
    python3 - "$SOCKET_PATH" "$method" "$PNEVMA_CTL_TIMEOUT_SECS" <<'PY'
import json
import os
import socket
import sys
import time

sock_path = sys.argv[1]
method = sys.argv[2]
params_json = os.environ["RUN_CTL_JSON_PARAMS"]
timeout = float(sys.argv[3])

try:
    params = json.loads(params_json)
except json.JSONDecodeError as exc:
    sys.stderr.write(
        f"run_ctl_json: invalid params JSON for {method}: {exc}: {params_json!r}\n"
    )
    sys.exit(1)

request = json.dumps(
    {
        "id": f"req-{time.time_ns()}",
        "method": method,
        "params": params,
    }
)

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(timeout)
try:
    s.connect(sock_path)
except OSError as exc:
    sys.stderr.write(f"run_ctl_json: connection failed: {exc}\n")
    sys.exit(1)

try:
    s.sendall((request + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
except TimeoutError:
    sys.stderr.write(
        f"run_ctl_json: timed out waiting for {method} after {timeout:.0f}s\n"
    )
    sys.exit(1)
finally:
    s.close()

line = buf.split(b"\n")[0].decode()
print(line)

try:
    resp = json.loads(line)
    sys.exit(0 if resp.get("ok") else 1)
except Exception:
    sys.exit(1)
PY
  )"
  status=$?
  set -e

  write_json_log "$log_name" "$output"

  if [[ $status -ne 0 ]]; then
    echo "error: $method failed; see $RUN_LOG_DIR/$log_name" >&2
    cat "$RUN_LOG_DIR/$log_name" >&2
    exit 1
  fi

  printf '%s' "$output"
}

assert_json_expr() {
  local name="$1"
  local expr="$2"
  local path="$RUN_LOG_DIR/$name"
  if ! jq -e "$expr" "$path" >/dev/null; then
    echo "error: assertion failed for $path: $expr" >&2
    cat "$path" >&2
    exit 1
  fi
}

assert_session_row() {
  local session_id="$1"
  local expected_status="$2"
  local expected_lifecycle="$3"
  local row
  row="$(sqlite3 "$PROJECT_DB_PATH" "SELECT backend || '|' || status || '|' || lifecycle_state FROM sessions WHERE id = '$session_id' LIMIT 1;")"
  if [[ "$row" != "remote_ssh_durable|${expected_status}|${expected_lifecycle}" ]]; then
    echo "error: unexpected session row for $session_id: $row" >&2
    sqlite3 -header -box "$PROJECT_DB_PATH" \
      "SELECT id, backend, status, lifecycle_state, connection_id, remote_session_id FROM sessions ORDER BY started_at DESC LIMIT 5;" \
      >&2
    exit 1
  fi
}

upsert_remote_profile() {
  local profile_payload
  local requested_profile_id
  requested_profile_id="remote-helper-smoke-${SCENARIO}-$(date +%s)"
  profile_payload="$(
    jq -cn \
      --arg id "$requested_profile_id" \
      --arg name "Remote Helper Smoke (${SCENARIO})" \
      --arg host "$REMOTE_HOST" \
      --arg user "$REMOTE_USER" \
      --arg identity_file "$REMOTE_IDENTITY_FILE" \
      --arg proxy_jump "$REMOTE_PROXY_JUMP" \
      --argjson port "$REMOTE_PORT" \
      '{
        id: $id,
        name: $name,
        host: $host,
        port: $port
      }
      + (if $user != "" then {user: $user} else {} end)
      + (if $identity_file != "" then {identity_file: $identity_file} else {} end)
      + (if $proxy_jump != "" then {proxy_jump: $proxy_jump} else {} end)'
  )"

  echo "[3/7] Upserting SSH profile"
  run_ctl_json ssh.upsert_profile "$profile_payload" "ssh-profile.json" >/dev/null
  assert_json_expr "ssh-profile.json" '.ok == true and (.result.id | type) == "string" and (.result.id | length) > 0'
  PROFILE_ID="$(jq -r '.result.id' "$RUN_LOG_DIR/ssh-profile.json")"
}

run_helper_checks() {
  echo "[4/7] Ensuring packaged remote helper"
  run_ctl_json ssh.runtime.ensure_helper "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "ensure-helper.json" >/dev/null

  assert_json_expr "ensure-helper.json" '.ok == true'
  assert_json_expr "ensure-helper.json" '.result.artifact_source == "bundle_relative"'
  assert_json_expr "ensure-helper.json" '.result.helper_kind == "binary"'
  assert_json_expr "ensure-helper.json" '.result.install_kind == "binary_artifact"'
  assert_json_expr "ensure-helper.json" '.result.target_triple == "'"$EXPECTED_TARGET_TRIPLE"'"'
  assert_json_expr "ensure-helper.json" '.result.protocol_compatible == true'
  assert_json_expr "ensure-helper.json" '.result.healthy == true'
  assert_json_expr "ensure-helper.json" '(.result.missing_dependencies // []) == []'
  assert_json_expr "ensure-helper.json" '.result.version == "'"$EXPECTED_HELPER_VERSION"'"'
  assert_json_expr "ensure-helper.json" '.result.protocol_version == "'"$EXPECTED_PROTOCOL_VERSION"'"'
  assert_json_expr "ensure-helper.json" '.result.artifact_sha256 == "'"$EXPECTED_ARTIFACT_SHA"'"'

  echo "[5/7] Checking helper health after install"
  run_ctl_json ssh.runtime.health "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "helper-health.json" >/dev/null

  assert_json_expr "helper-health.json" '.ok == true'
  assert_json_expr "helper-health.json" '.result.artifact_source == "bundle_relative"'
  assert_json_expr "helper-health.json" '.result.helper_kind == "binary"'
  assert_json_expr "helper-health.json" '.result.target_triple == "'"$EXPECTED_TARGET_TRIPLE"'"'
  assert_json_expr "helper-health.json" '.result.protocol_compatible == true'
  assert_json_expr "helper-health.json" '.result.healthy == true'
  assert_json_expr "helper-health.json" '(.result.missing_dependencies // []) == []'
  assert_json_expr "helper-health.json" '.result.version == "'"$EXPECTED_HELPER_VERSION"'"'
  assert_json_expr "helper-health.json" '.result.protocol_version == "'"$EXPECTED_PROTOCOL_VERSION"'"'
  assert_json_expr "helper-health.json" '.result.artifact_sha256 == "'"$EXPECTED_ARTIFACT_SHA"'"'
}

run_session_checks() {
  echo "[6/7] Creating remote durable session via ssh.connect"
  CONNECT_JSON="$(run_ctl_json ssh.connect "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "ssh-connect.json")"
  assert_json_expr "ssh-connect.json" '.ok == true'

  SESSION_ID="$(printf '%s' "$CONNECT_JSON" | jq -r '.result.session_id // empty')"
  if [[ -z "$SESSION_ID" ]]; then
    echo "error: could not parse session_id from ssh.connect response" >&2
    exit 1
  fi

  assert_session_row "$SESSION_ID" "waiting" "detached"

  echo "[7/7] Disconnecting remote SSH session"
  run_ctl_json ssh.disconnect "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "ssh-disconnect.json" >/dev/null
  assert_json_expr "ssh-disconnect.json" '.ok == true and .result.ok == true'

  assert_session_row "$SESSION_ID" "complete" "exited"
}

cleanup() {
  set +e
  if [[ -n "${app_pid:-}" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "${mounted_dir:-}" && -d "${mounted_dir:-}" ]]; then
    hdiutil detach "$mounted_dir" -quiet >/dev/null 2>&1 || true
  fi
  if [[ -n "${copied_app_dir:-}" && -d "${copied_app_dir:-}" ]]; then
    rm -rf "$copied_app_dir"
  fi
  if [[ -n "${temp_dir:-}" && -d "${temp_dir:-}" ]]; then
    rm -rf "$temp_dir"
  fi
}
trap cleanup EXIT

main() {
  require_command git
  require_command jq
  require_command python3
  require_command sqlite3
  require_command ssh

  require_env "REMOTE_HOST" "$REMOTE_HOST"
  require_env "REMOTE_USER" "$REMOTE_USER"
  require_env "EXPECTED_TARGET_TRIPLE" "$EXPECTED_TARGET_TRIPLE"
  require_numeric_port

  case "$SCENARIO" in
    fresh|legacy_shell|legacy_binary_version_mismatch|legacy_binary_digest_mismatch|legacy_binary_protocol_mismatch)
      ;;
    *)
      echo "error: unsupported SCENARIO '$SCENARIO'" >&2
      usage
      ;;
  esac

  if [[ -n "$REMOTE_IDENTITY_FILE" && ! -f "$REMOTE_IDENTITY_FILE" ]]; then
    echo "error: REMOTE_IDENTITY_FILE not found: $REMOTE_IDENTITY_FILE" >&2
    exit 1
  fi

  resolve_app_path
  prepare_log_dir
  create_fixture_project
  load_bundle_expectations
  seed_remote_fixture
  launch_app

  upsert_remote_profile
  run_helper_checks
  run_session_checks

  echo "Packaged remote helper smoke passed. Logs: $RUN_LOG_DIR"
}

main "$@"
