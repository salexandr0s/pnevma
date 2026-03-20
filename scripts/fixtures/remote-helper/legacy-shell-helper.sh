#!/bin/sh
set -eu

HELPER_PATH="$0"
STATE_ROOT="${HOME}/.local/state/pnevma/remote"
CONTROLLER_ID="remote-helper-v1"

print_health() {
  printf 'version=pnevma-remote-helper-v1\n'
  printf 'protocol_version=1\n'
  printf 'helper_kind=shell_compat\n'
  printf 'helper_path=%s\n' "$HELPER_PATH"
  printf 'state_root=%s\n' "$STATE_ROOT"
  printf 'controller_id=%s\n' "$CONTROLLER_ID"
  printf 'missing_dependencies=\n'
  printf 'healthy=true\n'
}

print_session_status() {
  session_id="${1:-fixture-session}"
  printf 'session_id=%s\n' "$session_id"
  printf 'controller_id=%s\n' "$CONTROLLER_ID"
  printf 'state=detached\n'
  printf 'pid=4242\n'
  printf 'total_bytes=0\n'
}

case "${1:-health}" in
  health)
    print_health
    ;;
  session)
    subcommand="${2:-status}"
    shift 2 || true
    case "$subcommand" in
      create)
        session_id="fixture-session"
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --session-id)
              session_id="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        printf 'session_id=%s\n' "$session_id"
        printf 'controller_id=%s\n' "$CONTROLLER_ID"
        printf 'state=detached\n'
        printf 'pid=4242\n'
        ;;
      status)
        session_id="fixture-session"
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --session-id)
              session_id="$2"
              shift 2
              ;;
            *)
              shift
              ;;
          esac
        done
        print_session_status "$session_id"
        ;;
      signal|terminate|attach)
        printf 'ok=true\n'
        ;;
      *)
        printf 'unsupported session subcommand: %s\n' "$subcommand" >&2
        exit 64
        ;;
    esac
    ;;
  *)
    print_health
    ;;
esac
