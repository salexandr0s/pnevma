#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <lock-name> <command...>" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_name="$1"
shift

lock_root="$repo_root/native/build/.locks"
lock_dir="$lock_root/${lock_name}.lock"
pid_file="$lock_dir/pid"

mkdir -p "$lock_root"

cleanup() {
  rm -f "$pid_file" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
}

wait_for_lock() {
  local attempts=0
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if [[ -f "$pid_file" ]]; then
      local owner_pid
      owner_pid="$(cat "$pid_file" 2>/dev/null || true)"
      if [[ -n "$owner_pid" ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
        rm -f "$pid_file" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
        continue
      fi
    fi

    attempts=$((attempts + 1))
    if (( attempts > 600 )); then
      echo "timed out waiting for native build lock: $lock_name" >&2
      exit 1
    fi
    sleep 1
  done
}

wait_for_lock
trap cleanup EXIT INT TERM
printf '%s\n' "$$" >"$pid_file"

"$@"
