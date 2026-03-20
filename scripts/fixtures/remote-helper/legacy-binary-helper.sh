#!/bin/sh
set -eu

HELPER_PATH="$0"
METADATA_PATH="${HELPER_PATH}.metadata"
STATE_ROOT="${HOME}/.local/state/pnevma/remote"
SESSION_ROOT="${STATE_ROOT}/fixture-sessions"

metadata_value() {
  key="$1"
  if [ -f "$METADATA_PATH" ]; then
    sed -n "s/^${key}=//p" "$METADATA_PATH" | head -n 1
  fi
}

session_file() {
  session_id="$1"
  printf '%s/%s.env\n' "$SESSION_ROOT" "$session_id"
}

read_session_value() {
  file="$1"
  key="$2"
  if [ -f "$file" ]; then
    sed -n "s/^${key}=//p" "$file" | head -n 1
  fi
}

write_session() {
  file="$1"
  session_id="$2"
  state="$3"
  pid="$4"
  mkdir -p "$SESSION_ROOT"
  {
    printf 'session_id=%s\n' "$session_id"
    printf 'state=%s\n' "$state"
    printf 'pid=%s\n' "$pid"
  } >"$file"
}

print_health() {
  printf 'version=%s\n' "$(metadata_value version)"
  printf 'protocol_version=%s\n' "$(metadata_value protocol_version)"
  printf 'helper_kind=binary\n'
  printf 'helper_path=%s\n' "$HELPER_PATH"
  printf 'state_root=%s\n' "$STATE_ROOT"
  printf 'controller_id=%s\n' "$(metadata_value controller_id)"
  printf 'target_triple=%s\n' "$(metadata_value target_triple)"
  printf 'artifact_source=%s\n' "$(metadata_value artifact_source)"
  printf 'artifact_sha256=%s\n' "$(metadata_value artifact_sha256)"
  printf 'missing_dependencies=%s\n' "$(metadata_value missing_dependencies)"
  printf 'healthy=%s\n' "$(metadata_value healthy)"
}

session_create() {
  session_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      --cwd|--command)
        shift 2
        ;;
      --json)
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  [ -n "$session_id" ] || session_id="fixture-session"
  write_session "$(session_file "$session_id")" "$session_id" "detached" "4343"
  printf 'session_id=%s\n' "$session_id"
  printf 'controller_id=%s\n' "$(metadata_value controller_id)"
  printf 'state=detached\n'
  printf 'pid=4343\n'
  printf 'log_path=%s/%s.log\n' "$STATE_ROOT" "$session_id"
}

session_status() {
  session_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      --json)
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  [ -n "$session_id" ] || session_id="fixture-session"
  file="$(session_file "$session_id")"
  state="$(read_session_value "$file" state)"
  pid="$(read_session_value "$file" pid)"
  [ -n "$state" ] || state="detached"
  printf 'session_id=%s\n' "$session_id"
  printf 'controller_id=%s\n' "$(metadata_value controller_id)"
  printf 'state=%s\n' "$state"
  if [ -n "$pid" ]; then
    printf 'pid=%s\n' "$pid"
  fi
  printf 'total_bytes=0\n'
}

session_signal() {
  printf 'ok=true\n'
}

session_terminate() {
  session_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      --json)
        shift
        ;;
      *)
        shift
        ;;
    esac
  done

  if [ -n "$session_id" ]; then
    write_session "$(session_file "$session_id")" "$session_id" "exited" ""
  fi
  printf 'ok=true\n'
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
        session_create "$@"
        ;;
      status)
        session_status "$@"
        ;;
      signal)
        session_signal "$@"
        ;;
      terminate)
        session_terminate "$@"
        ;;
      attach)
        exit 0
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
