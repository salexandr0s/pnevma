#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ipc-common.sh"

APP_PATH="${APP_PATH:-$ROOT_DIR/native/build/Debug/Pnevma.app}"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/Pnevma"
APP_LOG_PATH="${APP_LOG_PATH:-$ROOT_DIR/native/build/logs/ipc-e2e-app.log}"
SOCKET_PATH="${SOCKET_PATH:-$ROOT_DIR/.pnevma/run/control.sock}"
PROJECT_PATH="${PROJECT_PATH:-}"
PROJECT_OPEN_TIMEOUT_SECS="${PROJECT_OPEN_TIMEOUT_SECS:-20}"

mkdir -p "$(dirname "$APP_LOG_PATH")"

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  echo "Run 'just xcode-build' or 'just xcode-test' first." >&2
  exit 1
fi

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "error: app executable not found at $APP_EXECUTABLE" >&2
  exit 1
fi

export SOCKET_PATH

app_pid=""
temp_dir=""
project_dir=""
project_canonical_path=""

cleanup() {
  set +e
  if [[ -n "$app_pid" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
  if [[ -n "$temp_dir" && -d "$temp_dir" ]]; then
    rm -rf "$temp_dir"
  fi
}
trap cleanup EXIT

if [[ -S "$SOCKET_PATH" ]]; then
  if pnevma_ctl environment.readiness "$(jq -n --arg path "${PROJECT_PATH:-$ROOT_DIR}" '{"path": $path}')" >/dev/null 2>&1; then
    echo "error: an existing control socket is already serving requests at $SOCKET_PATH" >&2
    echo "Close the running app or set SOCKET_PATH to an isolated path before running the E2E harness." >&2
    exit 1
  fi
  rm -f "$SOCKET_PATH"
fi

if [[ -z "$PROJECT_PATH" ]]; then
  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pne2e.XXXXXX")"
  project_dir="$temp_dir/p"
  mkdir -p "$project_dir"
  PROJECT_PATH="$project_dir"

  cat > "$project_dir/README.md" <<'DOC'
# IPC E2E Fixture

Temporary fixture repository for the self-bootstrapping IPC smoke harness.
DOC

  git -C "$project_dir" init -q
  git -C "$project_dir" config user.email "e2e@example.com"
  git -C "$project_dir" config user.name "IPC E2E"
  git -C "$project_dir" add README.md
  git -C "$project_dir" commit -q -m "Initial commit"
fi

export PROJECT_PATH

canonicalize_path() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
}

ensure_project_scaffold() {
  mkdir -p \
    "$PROJECT_PATH/.pnevma/data" \
    "$PROJECT_PATH/.pnevma/rules" \
    "$PROJECT_PATH/.pnevma/conventions"

  if [[ ! -f "$PROJECT_PATH/pnevma.toml" ]]; then
    cat > "$PROJECT_PATH/pnevma.toml" <<'DOC'
[project]
name = "IPC E2E Fixture"
brief = "Temporary fixture workspace for IPC smoke tests"

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
DOC
  fi

  if [[ ! -f "$PROJECT_PATH/.pnevma/rules/project-rules.md" ]]; then
    cat > "$PROJECT_PATH/.pnevma/rules/project-rules.md" <<'DOC'
# Project Rules

- Keep work scoped to the active task contract.
- Prefer deterministic checks before requesting review.
DOC
  fi

  if [[ ! -f "$PROJECT_PATH/.pnevma/conventions/conventions.md" ]]; then
    cat > "$PROJECT_PATH/.pnevma/conventions/conventions.md" <<'DOC'
# Conventions

- Write concise commit messages in imperative mood.
- Capture reusable decisions in ADR knowledge artifacts.
DOC
  fi
}

project_socket_path() {
  printf '%s/.pnevma/run/control.sock\n' "$PROJECT_PATH"
}

wait_for_project_socket() {
  local deadline=$((SECONDS + PROJECT_OPEN_TIMEOUT_SECS))
  SOCKET_PATH="$(project_socket_path)"
  export SOCKET_PATH

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
      if [[ -n "$project_path" && "$project_path" == "$project_canonical_path" ]]; then
        echo "$status_output"
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

ensure_project_scaffold
project_canonical_path="$(canonicalize_path "$PROJECT_PATH")"

echo "Launching app for IPC E2E harness..."
(
  cd "$ROOT_DIR"
  PNEVMA_UI_TESTING=1 \
  PNEVMA_UI_TEST_PROJECT_PATH="$PROJECT_PATH" \
  "$APP_EXECUTABLE" >"$APP_LOG_PATH" 2>&1
) &
app_pid=$!

wait_for_project_socket
wait_for_project_status >/dev/null

echo "Running IPC smoke test..."
"$ROOT_DIR/scripts/ipc-e2e-smoke.sh"

echo "Running IPC recovery test..."
"$ROOT_DIR/scripts/ipc-e2e-recovery.sh"

echo "IPC E2E harness passed. App log: $APP_LOG_PATH"
