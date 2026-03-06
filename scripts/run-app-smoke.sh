#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: run-app-smoke.sh --app <path/to/Pnevma.app> --mode <launch|ghostty> [--timeout <seconds>] [--log <path>]
EOF
  exit 2
}

app_path=""
mode=""
timeout_secs=20
log_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      shift
      [[ $# -gt 0 ]] || usage
      app_path="$1"
      ;;
    --mode)
      shift
      [[ $# -gt 0 ]] || usage
      mode="$1"
      ;;
    --timeout)
      shift
      [[ $# -gt 0 ]] || usage
      timeout_secs="$1"
      ;;
    --log)
      shift
      [[ $# -gt 0 ]] || usage
      log_path="$1"
      ;;
    *)
      usage
      ;;
  esac
  shift
done

[[ -n "$app_path" ]] || usage
[[ -n "$mode" ]] || usage
[[ "$mode" == "launch" || "$mode" == "ghostty" ]] || usage

app_executable="$app_path/Contents/MacOS/Pnevma"
[[ -d "$app_path" ]] || { echo "error: app bundle not found: $app_path" >&2; exit 1; }
[[ -x "$app_executable" ]] || {
  echo "error: app executable not found: $app_executable" >&2
  exit 1
}

if [[ -z "$log_path" ]]; then
  log_path="$(mktemp -t pnevma-smoke.XXXXXX.log)"
else
  mkdir -p "$(dirname "$log_path")"
fi

cleanup() {
  if [[ -n "${app_pid:-}" ]] && kill -0 "$app_pid" >/dev/null 2>&1; then
    kill "$app_pid" >/dev/null 2>&1 || true
    wait "$app_pid" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

PNEVMA_SMOKE_MODE="$mode" "$app_executable" >"$log_path" 2>&1 &
app_pid=$!

deadline=$((SECONDS + timeout_secs))
while kill -0 "$app_pid" >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "error: smoke mode '$mode' timed out after ${timeout_secs}s; see $log_path" >&2
    exit 1
  fi
  sleep 1
done

if wait "$app_pid"; then
  status=0
else
  status=$?
fi

if [[ $status -ne 0 ]]; then
  echo "error: smoke mode '$mode' exited with code $status; see $log_path" >&2
  tail -n 50 "$log_path" >&2 || true
  exit "$status"
fi

echo "Smoke '$mode' passed. Log: $log_path"
