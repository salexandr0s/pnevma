#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ipc-common.sh"

SOCKET_PATH="${SOCKET_PATH:-.pnevma/run/control.sock}"
PROJECT_PATH="${PROJECT_PATH:-}"
TITLE="${TITLE:-IPC Recovery Smoke Task}"
GOAL="${GOAL:-Exercise timeline + session recovery control methods}"
SESSION_NAME="${SESSION_NAME:-ipc-recovery-smoke}"
SESSION_CWD="${SESSION_CWD:-.}"
SESSION_COMMAND="${SESSION_COMMAND:-zsh}"

echo "[1/8] environment.readiness"
READINESS_JSON="$(pnevma_ctl environment.readiness "{\"path\":\"${PROJECT_PATH:-.}\"}")"
echo "$READINESS_JSON"

if [[ -n "$PROJECT_PATH" ]]; then
  echo "[2/8] project.initialize_scaffold ($PROJECT_PATH)"
  pnevma_ctl project.initialize_scaffold "{\"path\":\"$PROJECT_PATH\"}"
else
  echo "[2/8] skip scaffold init (PROJECT_PATH not provided)"
fi

echo "[3/8] project.status (requires an already-open project in running app)"
pnevma_ctl project.status

echo "[4/8] task.create"
TASK_JSON="$(pnevma_ctl task.create "{\"title\":\"$TITLE\",\"goal\":\"$GOAL\",\"priority\":\"P1\",\"acceptance_criteria\":[\"manual review\"]}")"
echo "$TASK_JSON"

echo "[5/8] session.new"
SESSION_JSON="$(pnevma_ctl session.new "{\"name\":\"$SESSION_NAME\",\"cwd\":\"$SESSION_CWD\",\"command\":\"$SESSION_COMMAND\"}")"
echo "$SESSION_JSON"

SESSION_ID="$(json_extract "$SESSION_JSON" "result.session_id" || true)"
if [[ -z "$SESSION_ID" ]]; then
  echo "Could not parse session_id from session.new response"
  exit 1
fi

echo "[6/8] session.timeline"
TIMELINE_JSON="$(pnevma_ctl session.timeline "{\"session_id\":\"$SESSION_ID\",\"limit\":50}")"
echo "$TIMELINE_JSON"

echo "[7/8] session.recovery.options"
OPTIONS_JSON="$(pnevma_ctl session.recovery.options "{\"session_id\":\"$SESSION_ID\"}")"
echo "$OPTIONS_JSON"

echo "[8/8] session.recovery.execute (interrupt)"
RECOVERY_JSON="$(pnevma_ctl session.recovery.execute "{\"session_id\":\"$SESSION_ID\",\"action\":\"interrupt\"}")"
echo "$RECOVERY_JSON"
ACTION="$(json_extract "$RECOVERY_JSON" "result.action" || true)"
if [[ "$ACTION" != "interrupt" ]]; then
  echo "Expected recovery action to be 'interrupt', got '$ACTION'"
  exit 1
fi

echo "IPC recovery smoke completed for session $SESSION_ID."
