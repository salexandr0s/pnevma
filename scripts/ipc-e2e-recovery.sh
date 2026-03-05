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
READINESS_JSON="$(pnevma_ctl environment.readiness "$(jq -n --arg path "${PROJECT_PATH:-.}" '{"path": $path}')")"
echo "$READINESS_JSON"

if [[ -n "$PROJECT_PATH" ]]; then
  echo "[2/8] project.initialize_scaffold ($PROJECT_PATH)"
  pnevma_ctl project.initialize_scaffold "$(jq -n --arg path "$PROJECT_PATH" '{"path": $path}')"
else
  echo "[2/8] skip scaffold init (PROJECT_PATH not provided)"
fi

echo "[3/8] project.status (requires an already-open project in running app)"
pnevma_ctl project.status

echo "[4/8] task.create"
TASK_JSON="$(pnevma_ctl task.create "$(jq -n --arg title "$TITLE" --arg goal "$GOAL" '{"title": $title, "goal": $goal, "priority": "P1", "acceptance_criteria": ["manual review"]}')")"
echo "$TASK_JSON"

echo "[5/8] session.new"
SESSION_JSON="$(pnevma_ctl session.new "$(jq -n --arg name "$SESSION_NAME" --arg cwd "$SESSION_CWD" --arg cmd "$SESSION_COMMAND" '{"name": $name, "cwd": $cwd, "command": $cmd}')")"
echo "$SESSION_JSON"

SESSION_ID="$(json_extract "$SESSION_JSON" "result.session_id" || true)"
if [[ -z "$SESSION_ID" ]]; then
  echo "Could not parse session_id from session.new response"
  exit 1
fi

echo "[6/8] session.timeline"
TIMELINE_JSON="$(pnevma_ctl session.timeline "$(jq -n --arg id "$SESSION_ID" '{"session_id": $id, "limit": 50}')")"
echo "$TIMELINE_JSON"

echo "[7/8] session.recovery.options"
OPTIONS_JSON="$(pnevma_ctl session.recovery.options "$(jq -n --arg id "$SESSION_ID" '{"session_id": $id}')")"
echo "$OPTIONS_JSON"

echo "[8/8] session.recovery.execute (interrupt)"
RECOVERY_JSON="$(pnevma_ctl session.recovery.execute "$(jq -n --arg id "$SESSION_ID" '{"session_id": $id, "action": "interrupt"}')")"
echo "$RECOVERY_JSON"
ACTION="$(json_extract "$RECOVERY_JSON" "result.action" || true)"
if [[ "$ACTION" != "interrupt" ]]; then
  echo "Expected recovery action to be 'interrupt', got '$ACTION'"
  exit 1
fi

echo "IPC recovery smoke completed for session $SESSION_ID."
