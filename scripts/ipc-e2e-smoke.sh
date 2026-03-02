#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ipc-common.sh"

SOCKET_PATH="${SOCKET_PATH:-.pnevma/run/control.sock}"
PROJECT_PATH="${PROJECT_PATH:-}"
TITLE="${TITLE:-IPC Smoke Task}"
GOAL="${GOAL:-Validate control-plane end-to-end path}"

echo "[1/7] environment.readiness"
READINESS_JSON="$(pnevma_ctl environment.readiness "{\"path\":\"${PROJECT_PATH:-.}\"}")"
echo "$READINESS_JSON"

if [[ -n "$PROJECT_PATH" ]]; then
  echo "[2/7] project.initialize_scaffold ($PROJECT_PATH)"
  pnevma_ctl project.initialize_scaffold "{\"path\":\"$PROJECT_PATH\"}"
else
  echo "[2/7] skip scaffold init (PROJECT_PATH not provided)"
fi

echo "[3/7] project.status (requires an already-open project in running app)"
pnevma_ctl project.status

echo "[4/7] task.create"
CREATE_JSON="$(pnevma_ctl task.create "{\"title\":\"$TITLE\",\"goal\":\"$GOAL\",\"priority\":\"P1\",\"acceptance_criteria\":[\"manual review\"]}")"
echo "$CREATE_JSON"
TASK_ID="$(printf '%s' "$CREATE_JSON" | tr -d '\n' | sed -n 's/.*"task_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [[ -z "$TASK_ID" ]]; then
  echo "Could not parse task_id from task.create response"
  exit 1
fi

echo "[5/7] task.list"
pnevma_ctl task.list

echo "[6/7] project.daily_brief + optional dispatch/timeline"
pnevma_ctl project.daily_brief

if printf '%s' "$READINESS_JSON" | grep -q '"detected_adapters": \[\]'; then
  echo "No adapters detected; skipping dispatch/timeline checks."
  exit 0
fi

echo "[7/7] task.dispatch (optional)"
if pnevma_ctl task.dispatch "{\"task_id\":\"$TASK_ID\"}"; then
  echo "dispatch requested for $TASK_ID"
else
  echo "dispatch request failed (continuing; environment may be missing provider auth/config)"
fi

echo "IPC smoke completed."
