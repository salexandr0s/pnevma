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
SCENARIO="${SCENARIO:-}"
SSH_BIN_OVERRIDE="${SSH_BIN_OVERRIDE:-}"
LOG_ROOT="${LOG_ROOT:-$ROOT_DIR/native/build/logs}"
PROJECT_OPEN_TIMEOUT_SECS="${PROJECT_OPEN_TIMEOUT_SECS:-20}"
PNEVMA_CTL_TIMEOUT_SECS="${PNEVMA_CTL_TIMEOUT_SECS:-20}"
SESSION_STATE_TIMEOUT_SECS="${SESSION_STATE_TIMEOUT_SECS:-20}"

PROFILE_ID="${PROFILE_ID:-}"
SESSION_ID=""
REMOTE_SESSION_ID=""
CONTROLLER_ID=""
app_pid=""
app_launch_count=0
attach_pid=""
attach_stdin_pid=""
attach_fifo=""

usage() {
  cat >&2 <<'EOF'
usage: APP_PATH=/path/to/Pnevma.app|DMG_PATH=/path/to/Pnevma.dmg \
       REMOTE_HOST=... REMOTE_USER=... [REMOTE_PORT=22] [REMOTE_IDENTITY_FILE=...] \
       [REMOTE_PROXY_JUMP=...] EXPECTED_TARGET_TRIPLE=... SCENARIO=... \
       ./scripts/run-packaged-remote-durable-lifecycle-smoke.sh

Supported scenarios:
  disconnect_reconnect
  quit_relaunch_reattach
  detach_reattach
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
  temp_dir="$(mktemp -d /tmp/pnrdl.XXXXXX)"
  PROJECT_PATH="$temp_dir/p"
  mkdir -p "$PROJECT_PATH"

  cat >"$PROJECT_PATH/README.md" <<'EOF'
# Pnevma Remote Durable Lifecycle Fixture

Temporary fixture project for packaged remote durable lifecycle validation.
EOF

  git -C "$PROJECT_PATH" init -q -b main
  git -C "$PROJECT_PATH" config user.email "remote-lifecycle@example.com"
  git -C "$PROJECT_PATH" config user.name "Remote Durable Lifecycle"
  git -C "$PROJECT_PATH" add README.md
  git -C "$PROJECT_PATH" commit -q -m "Initial commit"

  mkdir -p \
    "$PROJECT_PATH/.pnevma/data" \
    "$PROJECT_PATH/.pnevma/rules" \
    "$PROJECT_PATH/.pnevma/conventions"

  cat >"$PROJECT_PATH/pnevma.toml" <<'EOF'
[project]
name = "Remote Durable Lifecycle Fixture"
brief = "Temporary fixture workspace for packaged remote durable lifecycle validation"

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

- Keep lifecycle validation scoped to release/runtime checks.
- Prefer deterministic SSH/runtime assertions over UI-only observations.
EOF

  cat >"$PROJECT_PATH/.pnevma/conventions/conventions.md" <<'EOF'
# Conventions

- Capture operator-visible evidence in native/build/logs.
- Fail fast when remote durable lifecycle validation drifts from the bundled artifact.
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

    mounted_dir="$(mktemp -d -t pnevma-remote-lifecycle-mount.XXXXXX)"
    copied_app_dir="$(mktemp -d -t pnevma-remote-lifecycle-copy.XXXXXX)"
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
  RUN_LOG_DIR="${LOG_ROOT}/remote-durable-lifecycle-${run_id}"
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
  echo "[setup] Seeding remote helper/runtime fixture"
  REMOTE_HOST="$REMOTE_HOST" \
  REMOTE_USER="$REMOTE_USER" \
  REMOTE_PORT="$REMOTE_PORT" \
  REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
  REMOTE_PROXY_JUMP="$REMOTE_PROXY_JUMP" \
  EXPECTED_TARGET_TRIPLE="$EXPECTED_TARGET_TRIPLE" \
  EXPECTED_PACKAGE_VERSION="$EXPECTED_PACKAGE_VERSION" \
  EXPECTED_PROTOCOL_VERSION="$EXPECTED_PROTOCOL_VERSION" \
  EXPECTED_ARTIFACT_SHA="$EXPECTED_ARTIFACT_SHA" \
  SCENARIO="fresh" \
  "$ROOT_DIR/scripts/seed-remote-helper-fixture.sh" | tee "$RUN_LOG_DIR/seed.log"
}

wait_for_project_socket() {
  local deadline=$((SECONDS + PROJECT_OPEN_TIMEOUT_SECS))
  while (( SECONDS < deadline )); do
    if [[ -S "$SOCKET_PATH" ]]; then
      return 0
    fi
    if [[ -n "$app_pid" ]] && ! kill -0 "$app_pid" >/dev/null 2>&1; then
      echo "error: app exited before project control socket became available; see $APP_LOG_PATH" >&2
      tail -n 120 "$APP_LOG_PATH" >&2 || true
      return 1
    fi
    sleep 1
  done

  echo "error: project control socket did not appear within ${PROJECT_OPEN_TIMEOUT_SECS}s at $SOCKET_PATH; see $APP_LOG_PATH" >&2
  tail -n 120 "$APP_LOG_PATH" >&2 || true
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
        printf '%s\n' "$status_output" >"$RUN_LOG_DIR/project-status-ready.json"
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

write_json_log() {
  local name="$1"
  local body="$2"
  printf '%s\n' "$body" >"$RUN_LOG_DIR/$name"
}

ctl_request() {
  local method="$1"
  local params="${2-}"
  if [[ -z "$params" ]]; then
    params='{}'
  fi

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
        f"ctl_request: invalid params JSON for {method}: {exc}: {params_json!r}\n"
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
    sys.stderr.write(f"ctl_request: connection failed: {exc}\n")
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
        f"ctl_request: timed out waiting for {method} after {timeout:.0f}s\n"
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
}

run_ctl_json() {
  local method="$1"
  local params="${2-}"
  local log_name="$3"
  local output
  local status

  set +e
  output="$(ctl_request "$method" "$params" 2>&1)"
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

try_ctl_json() {
  local method="$1"
  local params="${2-}"
  local log_name="$3"
  local output
  local status

  set +e
  output="$(ctl_request "$method" "$params" 2>&1)"
  status=$?
  set -e

  write_json_log "$log_name" "$output"
  printf '%s' "$output"
  return $status
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

write_sql_json() {
  local path="$1"
  local query="$2"
  shift 2
  python3 - "$PROJECT_DB_PATH" "$path" "$query" "$@" <<'PY'
import json
import sqlite3
import sys

db_path = sys.argv[1]
output_path = sys.argv[2]
query = sys.argv[3]
params = sys.argv[4:]

conn = sqlite3.connect(db_path)
conn.row_factory = sqlite3.Row
rows = conn.execute(query, params).fetchall()

def convert(row):
    item = dict(row)
    for key, value in list(item.items()):
        if key.endswith("_json") and isinstance(value, str):
            try:
                item[key] = json.loads(value)
            except Exception:
                pass
    return item

with open(output_path, "w", encoding="utf-8") as handle:
    json.dump([convert(row) for row in rows], handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

current_session_row_compact() {
  local session_id="$1"
  sqlite3 "$PROJECT_DB_PATH" \
    "SELECT backend || '|' || status || '|' || lifecycle_state FROM sessions WHERE id = '$session_id' LIMIT 1;"
}

capture_session_identifiers() {
  local session_id="$1"
  local compact
  compact="$(
    python3 - "$PROJECT_DB_PATH" "$session_id" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
row = conn.execute(
    "SELECT remote_session_id, controller_id FROM sessions WHERE id = ? LIMIT 1",
    (sys.argv[2],),
).fetchone()
if row is None:
    sys.exit(1)
print((row[0] or "") + "|" + (row[1] or ""))
PY
  )"
  REMOTE_SESSION_ID="${compact%%|*}"
  CONTROLLER_ID="${compact#*|}"
}

capture_transition_artifacts() {
  local label="$1"
  local session_id="${2:-}"

  run_ctl_json project.status '{}' "project-status-${label}.json" >/dev/null
  run_ctl_json session.list '{}' "session-list-${label}.json" >/dev/null
  run_ctl_json session.list_live '{}' "session-live-${label}.json" >/dev/null
  run_ctl_json ssh.runtime.health "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "helper-health-${label}.json" >/dev/null

  if [[ -n "$session_id" ]]; then
    try_ctl_json session.binding "$(jq -cn --arg id "$session_id" '{"session_id": $id}')" "session-binding-${label}.json" >/dev/null || true
    write_sql_json \
      "$RUN_LOG_DIR/session-row-${label}.json" \
      "SELECT id, type, backend, durability, status, lifecycle_state, connection_id, remote_session_id, controller_id, started_at, last_heartbeat, last_output_at, detached_at, last_error, restore_status, exit_code, ended_at FROM sessions WHERE id = ?" \
      "$session_id"
    write_sql_json \
      "$RUN_LOG_DIR/session-restore-log-${label}.json" \
      "SELECT id, action, outcome, error_message, created_at FROM session_restore_log WHERE session_id = ? ORDER BY created_at" \
      "$session_id"
    write_sql_json \
      "$RUN_LOG_DIR/session-events-${label}.json" \
      "SELECT timestamp, source, event_type, payload_json FROM events WHERE session_id = ? ORDER BY timestamp" \
      "$session_id"
  fi
}

assert_unique_live_remote_ssh_rows() {
  local expected_count="$1"
  local actual_count
  actual_count="$(
    python3 - "$PROJECT_DB_PATH" "$PROFILE_ID" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
count = conn.execute(
    """
    SELECT COUNT(*)
    FROM sessions
    WHERE backend = 'remote_ssh_durable'
      AND type = 'ssh'
      AND connection_id = ?
      AND status IN ('running', 'waiting')
    """,
    (sys.argv[2],),
).fetchone()[0]
print(count)
PY
  )"
  if [[ "$actual_count" != "$expected_count" ]]; then
    echo "error: expected $expected_count live remote SSH rows for connection $PROFILE_ID, found $actual_count" >&2
    sqlite3 -header -box "$PROJECT_DB_PATH" \
      "SELECT id, type, backend, status, lifecycle_state, connection_id, remote_session_id, controller_id FROM sessions ORDER BY started_at DESC;" \
      >&2
    exit 1
  fi
}

wait_for_session_state() {
  local session_id="$1"
  local expected_status="$2"
  local expected_lifecycle="$3"
  local label="$4"
  local deadline=$((SECONDS + SESSION_STATE_TIMEOUT_SECS))
  local row=""

  while (( SECONDS < deadline )); do
    try_ctl_json session.binding "$(jq -cn --arg id "$session_id" '{"session_id": $id}')" "session-binding-poll-${label}.json" >/dev/null || true
    row="$(current_session_row_compact "$session_id" || true)"
    if [[ "$row" == "remote_ssh_durable|${expected_status}|${expected_lifecycle}" ]]; then
      capture_transition_artifacts "$label" "$session_id"
      return 0
    fi
    sleep 1
  done

  echo "error: session $session_id did not reach ${expected_status}/${expected_lifecycle}; last row: ${row:-<missing>}" >&2
  capture_transition_artifacts "${label}-timeout" "$session_id"
  sqlite3 -header -box "$PROJECT_DB_PATH" \
    "SELECT id, type, backend, status, lifecycle_state, connection_id, remote_session_id, controller_id, restore_status, last_error FROM sessions ORDER BY started_at DESC LIMIT 10;" \
    >&2
  exit 1
}

start_packaged_app() {
  if [[ -S "$SOCKET_PATH" ]]; then
    if pnevma_ctl environment.readiness "$(jq -n --arg path "$PROJECT_PATH" '{"path": $path}')" >/dev/null 2>&1; then
      echo "error: an existing control socket is already serving requests at $SOCKET_PATH" >&2
      exit 1
    fi
    rm -f "$SOCKET_PATH"
  fi

  app_launch_count=$((app_launch_count + 1))
  printf '\n=== launch %s (%s) ===\n' "$app_launch_count" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$APP_LOG_PATH"
  (
    cd "$ROOT_DIR"
    unset PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT
    unset PNEVMA_REMOTE_HELPER_ARTIFACT_DIR
    unset PNEVMA_REMOTE_HELPER_BUNDLE_DIR
    unset PNEVMA_REMOTE_HELPER_ARTIFACT_X86_64_UNKNOWN_LINUX_MUSL
    unset PNEVMA_REMOTE_HELPER_ARTIFACT_AARCH64_UNKNOWN_LINUX_MUSL
    unset PNEVMA_REMOTE_HELPER_ARTIFACT_X86_64_APPLE_DARWIN
    unset PNEVMA_REMOTE_HELPER_ARTIFACT_AARCH64_APPLE_DARWIN
    unset PNEVMA_SSH_NAME
    if [[ -n "$SSH_BIN_OVERRIDE" ]]; then
      export PNEVMA_SSH_BIN="$SSH_BIN_OVERRIDE"
    else
      unset PNEVMA_SSH_BIN
    fi
    export PNEVMA_UI_TESTING=1
    export PNEVMA_UI_TEST_PROJECT_PATH="$PROJECT_PATH"
    exec "$APP_EXECUTABLE" >>"$APP_LOG_PATH" 2>&1
  ) &
  app_pid=$!

  wait_for_project_socket
  wait_for_project_status
}

request_app_quit() {
  if [[ -z "$app_pid" ]] || ! kill -0 "$app_pid" >/dev/null 2>&1; then
    return 0
  fi

  if command -v swift >/dev/null 2>&1; then
    swift -e '
      import AppKit
      import Foundation

      let pid = pid_t(CommandLine.arguments[1]) ?? 0
      if let app = NSRunningApplication(processIdentifier: pid) {
          _ = app.terminate()
      }
    ' "$app_pid" >/dev/null 2>&1 || true
    return 0
  fi

  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'tell application id "com.pnevma.app" to quit' >/dev/null 2>&1 || true
    return 0
  fi
}

wait_for_app_exit() {
  local deadline=$((SECONDS + PROJECT_OPEN_TIMEOUT_SECS))
  while (( SECONDS < deadline )); do
    if [[ -z "$app_pid" ]] || ! kill -0 "$app_pid" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

log_live_app_processes() {
  ps -Ao pid=,ppid=,command= | awk '/Pnevma\.app\/Contents\/MacOS\/Pnevma/ {print}' >&2 || true
}

stop_packaged_app() {
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    request_app_quit
    if ! wait_for_app_exit; then
      kill "$app_pid" >/dev/null 2>&1 || true
    fi
    if ! wait_for_app_exit; then
      kill -9 "$app_pid" >/dev/null 2>&1 || true
    fi
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  app_pid=""
  local deadline=$((SECONDS + PROJECT_OPEN_TIMEOUT_SECS))
  while (( SECONDS < deadline )); do
    if [[ ! -S "$SOCKET_PATH" ]]; then
      return 0
    fi
    if ! pnevma_ctl environment.readiness "$(jq -n --arg path "$PROJECT_PATH" '{"path": $path}')" >/dev/null 2>&1; then
      rm -f "$SOCKET_PATH" >/dev/null 2>&1 || true
      return 0
    fi
    sleep 1
  done
  log_live_app_processes
  echo "error: control socket remained active after app shutdown: $SOCKET_PATH" >&2
  exit 1
}

ensure_remote_profile() {
  local requested_profile_id
  requested_profile_id="${PROFILE_ID:-remote-durable-lifecycle-${SCENARIO}}"
  local profile_payload
  profile_payload="$(
    jq -cn \
      --arg id "$requested_profile_id" \
      --arg name "Remote Durable Lifecycle (${SCENARIO})" \
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
  run_ctl_json ssh.upsert_profile "$profile_payload" "ssh-profile-upsert-${app_launch_count}.json" >/dev/null
  assert_json_expr "ssh-profile-upsert-${app_launch_count}.json" '.ok == true and (.result.id | type) == "string" and (.result.id | length) > 0'
  PROFILE_ID="$(jq -r '.result.id' "$RUN_LOG_DIR/ssh-profile-upsert-${app_launch_count}.json")"
}

run_helper_checks() {
  local label="$1"
  run_ctl_json ssh.runtime.ensure_helper "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "ensure-helper-${label}.json" >/dev/null
  assert_json_expr "ensure-helper-${label}.json" '.ok == true'
  assert_json_expr "ensure-helper-${label}.json" '.result.artifact_source == "bundle_relative"'
  assert_json_expr "ensure-helper-${label}.json" '.result.helper_kind == "binary"'
  assert_json_expr "ensure-helper-${label}.json" '.result.target_triple == "'"$EXPECTED_TARGET_TRIPLE"'"'
  assert_json_expr "ensure-helper-${label}.json" '.result.protocol_compatible == true'
  assert_json_expr "ensure-helper-${label}.json" '.result.healthy == true'
  assert_json_expr "ensure-helper-${label}.json" '(.result.missing_dependencies // []) == []'
  assert_json_expr "ensure-helper-${label}.json" '.result.version == "'"$EXPECTED_HELPER_VERSION"'"'
  assert_json_expr "ensure-helper-${label}.json" '.result.protocol_version == "'"$EXPECTED_PROTOCOL_VERSION"'"'
  assert_json_expr "ensure-helper-${label}.json" '.result.artifact_sha256 == "'"$EXPECTED_ARTIFACT_SHA"'"'

  run_ctl_json ssh.runtime.health "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "helper-health-asserted-${label}.json" >/dev/null
  assert_json_expr "helper-health-asserted-${label}.json" '.ok == true'
  assert_json_expr "helper-health-asserted-${label}.json" '.result.artifact_source == "bundle_relative"'
  assert_json_expr "helper-health-asserted-${label}.json" '.result.helper_kind == "binary"'
  assert_json_expr "helper-health-asserted-${label}.json" '.result.target_triple == "'"$EXPECTED_TARGET_TRIPLE"'"'
  assert_json_expr "helper-health-asserted-${label}.json" '.result.protocol_compatible == true'
  assert_json_expr "helper-health-asserted-${label}.json" '.result.healthy == true'
  assert_json_expr "helper-health-asserted-${label}.json" '(.result.missing_dependencies // []) == []'
}

connect_remote_session() {
  local label="$1"
  local connect_json
  connect_json="$(run_ctl_json ssh.connect "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "ssh-connect-${label}.json")"
  SESSION_ID="$(printf '%s' "$connect_json" | jq -r '.result.session_id // empty')"
  if [[ -z "$SESSION_ID" ]]; then
    echo "error: could not parse session_id from ssh.connect response for $label" >&2
    exit 1
  fi
  wait_for_session_state "$SESSION_ID" "waiting" "detached" "${label}-detached"
  capture_session_identifiers "$SESSION_ID"
  assert_unique_live_remote_ssh_rows 1
}

disconnect_remote_session() {
  local label="$1"
  run_ctl_json ssh.disconnect "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "ssh-disconnect-${label}.json" >/dev/null
  assert_json_expr "ssh-disconnect-${label}.json" '.ok == true and .result.ok == true'
  wait_for_session_state "$SESSION_ID" "complete" "exited" "${label}-exited"
}

assert_session_identifiers() {
  local session_id="$1"
  local expected_remote_session_id="$2"
  local expected_controller_id="$3"
  local actual_remote_session_id=""
  local actual_controller_id=""
  local compact
  compact="$(
    python3 - "$PROJECT_DB_PATH" "$session_id" <<'PY'
import sqlite3
import sys

conn = sqlite3.connect(sys.argv[1])
row = conn.execute(
    "SELECT remote_session_id, controller_id FROM sessions WHERE id = ? LIMIT 1",
    (sys.argv[2],),
).fetchone()
if row is None:
    sys.exit(1)
print((row[0] or "") + "|" + (row[1] or ""))
PY
  )"
  actual_remote_session_id="${compact%%|*}"
  actual_controller_id="${compact#*|}"
  if [[ "$actual_remote_session_id" != "$expected_remote_session_id" || "$actual_controller_id" != "$expected_controller_id" ]]; then
    echo "error: session identifiers drifted for $session_id" >&2
    echo "expected remote_session_id=$expected_remote_session_id controller_id=$expected_controller_id" >&2
    echo "actual   remote_session_id=$actual_remote_session_id controller_id=$actual_controller_id" >&2
    capture_transition_artifacts "identifier-drift" "$session_id"
    exit 1
  fi
}

start_attach_process() {
  local label="$1"
  local binding_json
  local launch_command

  binding_json="$(run_ctl_json session.binding "$(jq -cn --arg id "$SESSION_ID" '{"session_id": $id}')" "session-binding-${label}.json")"
  launch_command="$(printf '%s' "$binding_json" | jq -r '.result.launch_command // empty')"
  if [[ -z "$launch_command" ]]; then
    echo "error: session.binding did not provide a launch_command for $label" >&2
    cat "$RUN_LOG_DIR/session-binding-${label}.json" >&2
    exit 1
  fi

  attach_fifo="$RUN_LOG_DIR/attach-${label}.fifo"
  rm -f "$attach_fifo"
  mkfifo "$attach_fifo"
  tail -f /dev/null >"$attach_fifo" &
  attach_stdin_pid=$!

  /bin/sh -lc "exec $launch_command" <"$attach_fifo" >>"$RUN_LOG_DIR/attach-${label}.log" 2>&1 &
  attach_pid=$!
  sleep 1
  if ! kill -0 "$attach_pid" >/dev/null 2>&1; then
    echo "error: attach process exited immediately for $label" >&2
    cat "$RUN_LOG_DIR/attach-${label}.log" >&2 || true
    exit 1
  fi
}

stop_attach_process() {
  if [[ -n "$attach_stdin_pid" ]] && kill -0 "$attach_stdin_pid" >/dev/null 2>&1; then
    kill "$attach_stdin_pid" >/dev/null 2>&1 || true
    wait "$attach_stdin_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$attach_pid" ]] && kill -0 "$attach_pid" >/dev/null 2>&1; then
    local deadline=$((SECONDS + 5))
    while kill -0 "$attach_pid" >/dev/null 2>&1; do
      if (( SECONDS >= deadline )); then
        kill "$attach_pid" >/dev/null 2>&1 || true
        break
      fi
      sleep 1
    done
    wait "$attach_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$attach_fifo" ]]; then
    rm -f "$attach_fifo"
  fi
  attach_pid=""
  attach_stdin_pid=""
  attach_fifo=""
}

run_detach_reattach_scenario() {
  echo "[scenario] detach_reattach"
  connect_remote_session "detach-reattach-initial"
  local expected_remote_session_id="$REMOTE_SESSION_ID"
  local expected_controller_id="$CONTROLLER_ID"

  start_attach_process "detach-reattach-attach-1"
  wait_for_session_state "$SESSION_ID" "running" "attached" "detach-reattach-attached-1"
  assert_session_identifiers "$SESSION_ID" "$expected_remote_session_id" "$expected_controller_id"

  stop_attach_process
  wait_for_session_state "$SESSION_ID" "waiting" "detached" "detach-reattach-detached-1"
  assert_session_identifiers "$SESSION_ID" "$expected_remote_session_id" "$expected_controller_id"

  start_attach_process "detach-reattach-attach-2"
  wait_for_session_state "$SESSION_ID" "running" "attached" "detach-reattach-attached-2"
  assert_session_identifiers "$SESSION_ID" "$expected_remote_session_id" "$expected_controller_id"

  stop_attach_process
  wait_for_session_state "$SESSION_ID" "waiting" "detached" "detach-reattach-detached-2"
  disconnect_remote_session "detach-reattach-final"
}

run_disconnect_reconnect_scenario() {
  echo "[scenario] disconnect_reconnect"
  connect_remote_session "disconnect-reconnect-initial"
  local first_session_id="$SESSION_ID"
  disconnect_remote_session "disconnect-reconnect-first"
  assert_unique_live_remote_ssh_rows 0

  connect_remote_session "disconnect-reconnect-second"
  if [[ "$SESSION_ID" == "$first_session_id" ]]; then
    echo "error: explicit reconnect reused the exited session row $SESSION_ID" >&2
    exit 1
  fi
  disconnect_remote_session "disconnect-reconnect-final"
}

run_quit_relaunch_reattach_scenario() {
  echo "[scenario] quit_relaunch_reattach"
  connect_remote_session "quit-relaunch-initial"
  local original_session_id="$SESSION_ID"
  local original_remote_session_id="$REMOTE_SESSION_ID"
  local original_controller_id="$CONTROLLER_ID"

  start_attach_process "quit-relaunch-before-quit"
  wait_for_session_state "$SESSION_ID" "running" "attached" "quit-relaunch-attached-before-quit"
  stop_attach_process
  wait_for_session_state "$SESSION_ID" "waiting" "detached" "quit-relaunch-detached-before-quit"

  stop_packaged_app
  start_packaged_app
  ensure_remote_profile
  run_helper_checks "after-relaunch"
  capture_transition_artifacts "after-relaunch" "$original_session_id"
  SESSION_ID="$original_session_id"
  assert_session_identifiers "$SESSION_ID" "$original_remote_session_id" "$original_controller_id"

  local reconnect_json
  reconnect_json="$(run_ctl_json ssh.connect "$(jq -cn --arg id "$PROFILE_ID" '{"profile_id": $id}')" "ssh-connect-after-relaunch.json")"
  SESSION_ID="$(printf '%s' "$reconnect_json" | jq -r '.result.session_id // empty')"
  if [[ "$SESSION_ID" != "$original_session_id" ]]; then
    echo "error: relaunch reconnect created a duplicate session: expected $original_session_id, got $SESSION_ID" >&2
    exit 1
  fi
  assert_unique_live_remote_ssh_rows 1
  wait_for_session_state "$SESSION_ID" "waiting" "detached" "quit-relaunch-reused-detached"
  assert_session_identifiers "$SESSION_ID" "$original_remote_session_id" "$original_controller_id"

  start_attach_process "quit-relaunch-after-relaunch"
  wait_for_session_state "$SESSION_ID" "running" "attached" "quit-relaunch-attached-after-relaunch"
  assert_session_identifiers "$SESSION_ID" "$original_remote_session_id" "$original_controller_id"

  stop_attach_process
  wait_for_session_state "$SESSION_ID" "waiting" "detached" "quit-relaunch-detached-after-relaunch"
  disconnect_remote_session "quit-relaunch-final"
}

cleanup() {
  set +e
  stop_attach_process
  stop_packaged_app
  # Remove the SSH profile created for this lifecycle run
  if [[ -n "${PROFILE_ID:-}" ]]; then
    local db="$HOME/.local/share/pnevma/global.db"
    if [[ -f "$db" ]]; then
      sqlite3 "$db" "DELETE FROM global_ssh_profiles WHERE id = '${PROFILE_ID}';" 2>/dev/null || true
    fi
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
  require_env "SCENARIO" "$SCENARIO"
  require_numeric_port

  case "$SCENARIO" in
    disconnect_reconnect|quit_relaunch_reattach|detach_reattach)
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
  start_packaged_app
  ensure_remote_profile
  run_helper_checks "initial"
  capture_transition_artifacts "initial" ""

  case "$SCENARIO" in
    disconnect_reconnect)
      run_disconnect_reconnect_scenario
      ;;
    quit_relaunch_reattach)
      run_quit_relaunch_reattach_scenario
      ;;
    detach_reattach)
      run_detach_reattach_scenario
      ;;
  esac

  echo "Packaged remote durable lifecycle smoke passed. Logs: $RUN_LOG_DIR"
}

main "$@"
