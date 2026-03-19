#!/bin/sh
set -eu

HELPER_VERSION="pnevma-remote-helper-v1"
PROTOCOL_VERSION="1"
HELPER_KIND="shell_compat"
HELPER_PATH="${HOME}/.local/share/pnevma/bin/pnevma-remote-helper"
STATE_ROOT="${XDG_STATE_HOME:-${HOME}/.local/state}/pnevma/remote"
SESSIONS_ROOT="${STATE_ROOT}/sessions"
CONTROLLER_ID="remote-helper-v1"
DEFAULT_ATTACH_TAIL_BYTES=16384

mkdir -p "${SESSIONS_ROOT}"

print_kv() {
  printf '%s=%s\n' "$1" "$2"
}

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}

session_dir() {
  printf '%s/%s' "${SESSIONS_ROOT}" "$1"
}

file_mtime() {
  file_path="$1"
  if [ ! -e "$file_path" ]; then
    printf '%s' ""
    return 0
  fi
  if stat -c %Y "$file_path" >/dev/null 2>&1; then
    stat -c %Y "$file_path"
  else
    stat -f %m "$file_path"
  fi
}

read_pid_file() {
  pid_file="$1"
  if [ -f "$pid_file" ]; then
    tr -d ' \n\r\t' < "$pid_file"
  fi
}

pid_alive() {
  pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

cleanup_dead_pid_file() {
  pid_file="$1"
  pid="$(read_pid_file "$pid_file")"
  if [ -n "$pid" ] && ! pid_alive "$pid"; then
    rm -f "$pid_file"
  fi
}

write_launch_script() {
  launch_script="$1"
  cwd="$2"
  command="$3"
  cat > "$launch_script" <<LAUNCH
#!/bin/sh
set -eu
cd -- $(shell_quote "$cwd")
exec /bin/sh -lc $(shell_quote "$command")
LAUNCH
  chmod 700 "$launch_script"
}

start_keepalive_writer() {
  fifo_path="$1"
  keepalive_pid_file="$2"
  current_pid="$(read_pid_file "$keepalive_pid_file")"
  if [ -n "$current_pid" ] && pid_alive "$current_pid"; then
    return 0
  fi
  nohup sh -c "exec tail -f /dev/null > $(shell_quote "$fifo_path")" >/dev/null 2>&1 &
  keepalive_pid=$!
  printf '%s\n' "$keepalive_pid" > "$keepalive_pid_file"
}

script_launch_command() {
  launch_script="$1"
  if script -qefc "printf ''" /dev/null >/dev/null 2>&1; then
    printf 'script -qefc %s /dev/null' "$(shell_quote "sh $launch_script")"
  else
    printf 'script -q /dev/null sh %s' "$(shell_quote "$launch_script")"
  fi
}

cmd_version() {
  print_kv version "$HELPER_VERSION"
  print_kv protocol_version "$PROTOCOL_VERSION"
  print_kv helper_kind "$HELPER_KIND"
  print_kv helper_path "$HELPER_PATH"
  print_kv state_root "$STATE_ROOT"
  print_kv controller_id "$CONTROLLER_ID"
}

cmd_health() {
  cmd_version
  print_kv healthy "true"
}

cmd_controller_ensure() {
  controller_id="$CONTROLLER_ID"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --controller-id)
        controller_id="$2"
        shift 2
        ;;
      --json)
        shift
        ;;
      *)
        fail "unknown controller ensure arg: $1"
        ;;
    esac
  done
  print_kv controller_id "$controller_id"
  print_kv protocol_version "$PROTOCOL_VERSION"
  print_kv helper_kind "$HELPER_KIND"
}

cmd_create_session() {
  session_id=""
  cwd=""
  command=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      --cwd)
        cwd="$2"
        shift 2
        ;;
      --command)
        command="$2"
        shift 2
        ;;
      --json)
        shift
        ;;
      *)
        fail "unknown create-session arg: $1"
        ;;
    esac
  done

  [ -n "$session_id" ] || fail "missing --session-id"
  [ -n "$cwd" ] || fail "missing --cwd"
  if [ -z "$command" ]; then
    command='${SHELL:-/bin/sh} -il'
  fi

  session_path="$(session_dir "$session_id")"
  mkdir -p "$session_path"

  fifo_path="$session_path/input.fifo"
  log_path="$session_path/output.log"
  launch_path="$session_path/launch.sh"
  runner_pid_path="$session_path/runner.pid"
  keepalive_pid_path="$session_path/keepalive.pid"
  exit_code_path="$session_path/exit_code"
  attach_marker="$session_path/attached.lock"

  [ -p "$fifo_path" ] || { rm -f "$fifo_path"; mkfifo "$fifo_path"; }
  touch "$log_path"
  write_launch_script "$launch_path" "$cwd" "$command"

  cleanup_dead_pid_file "$runner_pid_path"
  cleanup_dead_pid_file "$keepalive_pid_path"

  runner_pid="$(read_pid_file "$runner_pid_path")"
  if [ -n "$runner_pid" ] && pid_alive "$runner_pid"; then
    print_kv session_id "$session_id"
    print_kv controller_id "$CONTROLLER_ID"
    if [ -f "$attach_marker" ]; then
      print_kv state "attached"
    else
      print_kv state "detached"
    fi
    print_kv pid "$runner_pid"
    print_kv log_path "$log_path"
    return 0
  fi

  rm -f "$exit_code_path" "$attach_marker"
  launch_cmd="$(script_launch_command "$launch_path")"
  nohup sh -c "${launch_cmd} < $(shell_quote "$fifo_path") >> $(shell_quote "$log_path") 2>&1; code=\$?; printf '%s' \"\$code\" > $(shell_quote "$exit_code_path"); rm -f $(shell_quote "$runner_pid_path")" >/dev/null 2>&1 &
  runner_pid=$!
  printf '%s\n' "$runner_pid" > "$runner_pid_path"
  start_keepalive_writer "$fifo_path" "$keepalive_pid_path"

  print_kv session_id "$session_id"
  print_kv controller_id "$CONTROLLER_ID"
  print_kv state "detached"
  print_kv pid "$runner_pid"
  print_kv log_path "$log_path"
}

cmd_session_status() {
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
        fail "unknown session-status arg: $1"
        ;;
    esac
  done

  [ -n "$session_id" ] || fail "missing --session-id"
  session_path="$(session_dir "$session_id")"
  if [ ! -d "$session_path" ]; then
    print_kv session_id "$session_id"
    print_kv controller_id "$CONTROLLER_ID"
    print_kv state "lost"
    return 0
  fi

  runner_pid_path="$session_path/runner.pid"
  keepalive_pid_path="$session_path/keepalive.pid"
  log_path="$session_path/output.log"
  exit_code_path="$session_path/exit_code"
  attach_marker="$session_path/attached.lock"

  cleanup_dead_pid_file "$runner_pid_path"
  cleanup_dead_pid_file "$keepalive_pid_path"

  runner_pid="$(read_pid_file "$runner_pid_path")"
  state="lost"
  if [ -n "$runner_pid" ] && pid_alive "$runner_pid"; then
    if [ -f "$attach_marker" ]; then
      state="attached"
    else
      state="detached"
    fi
  elif [ -f "$exit_code_path" ]; then
    state="exited"
  fi

  print_kv session_id "$session_id"
  print_kv controller_id "$CONTROLLER_ID"
  print_kv state "$state"
  print_kv pid "$runner_pid"
  if [ -f "$exit_code_path" ]; then
    print_kv exit_code "$(cat "$exit_code_path")"
  else
    print_kv exit_code ""
  fi
  print_kv total_bytes "$(wc -c < "$log_path" 2>/dev/null | tr -d ' ' || printf '0')"
  print_kv last_output_at "$(file_mtime "$log_path")"
}

cmd_signal() {
  session_id=""
  signal_name="INT"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      --signal)
        signal_name="$2"
        shift 2
        ;;
      --json)
        shift
        ;;
      *)
        fail "unknown signal arg: $1"
        ;;
    esac
  done

  [ -n "$session_id" ] || fail "missing --session-id"
  session_path="$(session_dir "$session_id")"
  fifo_path="$session_path/input.fifo"
  runner_pid_path="$session_path/runner.pid"
  runner_pid="$(read_pid_file "$runner_pid_path")"
  pid_alive "$runner_pid" || fail "session is not running"

  case "$signal_name" in
    INT)
      printf '\003' > "$fifo_path"
      ;;
    TERM)
      kill -TERM "$runner_pid"
      ;;
    KILL)
      kill -KILL "$runner_pid"
      ;;
    *)
      fail "unsupported signal: $signal_name"
      ;;
  esac

  print_kv ok "true"
}

cmd_terminate() {
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
        fail "unknown terminate arg: $1"
        ;;
    esac
  done

  [ -n "$session_id" ] || fail "missing --session-id"
  session_path="$(session_dir "$session_id")"
  runner_pid_path="$session_path/runner.pid"
  keepalive_pid_path="$session_path/keepalive.pid"
  attach_marker="$session_path/attached.lock"

  runner_pid="$(read_pid_file "$runner_pid_path")"
  keepalive_pid="$(read_pid_file "$keepalive_pid_path")"
  if [ -n "$runner_pid" ] && pid_alive "$runner_pid"; then
    kill -TERM "$runner_pid" 2>/dev/null || true
    sleep 1
    pid_alive "$runner_pid" && kill -KILL "$runner_pid" 2>/dev/null || true
  fi
  if [ -n "$keepalive_pid" ] && pid_alive "$keepalive_pid"; then
    kill -TERM "$keepalive_pid" 2>/dev/null || true
  fi
  rm -f "$runner_pid_path" "$keepalive_pid_path" "$attach_marker"
  print_kv ok "true"
}

cmd_tail() {
  session_id=""
  limit="65536"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      --limit)
        limit="$2"
        shift 2
        ;;
      *)
        fail "unknown tail arg: $1"
        ;;
    esac
  done

  [ -n "$session_id" ] || fail "missing --session-id"
  session_path="$(session_dir "$session_id")"
  log_path="$session_path/output.log"
  touch "$log_path"
  tail -c "$limit" "$log_path"
}

cmd_attach() {
  session_id=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --session-id)
        session_id="$2"
        shift 2
        ;;
      *)
        fail "unknown attach arg: $1"
        ;;
    esac
  done

  [ -n "$session_id" ] || fail "missing --session-id"
  session_path="$(session_dir "$session_id")"
  fifo_path="$session_path/input.fifo"
  log_path="$session_path/output.log"
  runner_pid_path="$session_path/runner.pid"
  attach_marker="$session_path/attached.lock"

  runner_pid="$(read_pid_file "$runner_pid_path")"
  pid_alive "$runner_pid" || fail "session is not running"
  touch "$log_path"
  : > "$attach_marker"

  cleanup() {
    rm -f "$attach_marker"
    if [ -n "${input_pid:-}" ]; then
      kill "$input_pid" 2>/dev/null || true
    fi
    if [ -n "${tail_pid:-}" ]; then
      kill "$tail_pid" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT INT TERM HUP

  cat > "$fifo_path" &
  input_pid=$!
  tail -c "${DEFAULT_ATTACH_TAIL_BYTES}" -F "$log_path" &
  tail_pid=$!

  wait "$input_pid"
}

command_name="${1:-}"
shift || true
case "$command_name" in
  version)
    cmd_version "$@"
    ;;
  health)
    cmd_health "$@"
    ;;
  controller)
    subcommand="${1:-}"
    shift || true
    case "$subcommand" in
      ensure)
        cmd_controller_ensure "$@"
        ;;
      *)
        fail "unknown controller command: ${subcommand}"
        ;;
    esac
    ;;
  session)
    subcommand="${1:-}"
    shift || true
    case "$subcommand" in
      create)
        cmd_create_session "$@"
        ;;
      status)
        cmd_session_status "$@"
        ;;
      signal)
        cmd_signal "$@"
        ;;
      terminate)
        cmd_terminate "$@"
        ;;
      tail)
        cmd_tail "$@"
        ;;
      attach)
        cmd_attach "$@"
        ;;
      *)
        fail "unknown session command: ${subcommand}"
        ;;
    esac
    ;;
  create-session)
    cmd_create_session "$@"
    ;;
  session-status)
    cmd_session_status "$@"
    ;;
  signal)
    cmd_signal "$@"
    ;;
  terminate)
    cmd_terminate "$@"
    ;;
  tail)
    cmd_tail "$@"
    ;;
  attach)
    cmd_attach "$@"
    ;;
  *)
    fail "unknown command: ${command_name}"
    ;;
esac
