#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage: assert-clean-command-log.sh --log <path> -- <command...>
EOF
  exit 2
}

log_path=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --log)
      shift
      [[ $# -gt 0 ]] || usage
      log_path="$1"
      ;;
    --)
      shift
      break
      ;;
    *)
      usage
      ;;
  esac
  shift
done

[[ -n "$log_path" ]] || usage
[[ $# -gt 0 ]] || usage

mkdir -p "$(dirname "$log_path")"

set +e
"$@" 2>&1 | tee "$log_path"
status=${PIPESTATUS[0]}
set -e

if [[ $status -ne 0 ]]; then
  echo "error: command failed with exit code $status; see $log_path" >&2
  exit "$status"
fi

if grep -nE 'warning:|error:|IDERunDestination:' "$log_path" >/dev/null; then
  echo "error: disallowed warning/error output detected in $log_path" >&2
  grep -nE 'warning:|error:|IDERunDestination:' "$log_path" >&2 || true
  exit 1
fi

