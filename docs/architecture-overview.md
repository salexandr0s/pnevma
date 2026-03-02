# Architecture Overview

Pnevma is a single Tauri application where the Rust backend is the orchestrator and the frontend is a thin rendering layer.

## High-level flow

1. Frontend issues Tauri commands (`invoke`).
2. Backend mutates project/session/task state and persists to SQLite/event log.
3. Backend emits events (`task_updated`, `session_*`, `project_refreshed`).
4. Frontend refreshes state via commands and rerenders panes.

Optional external automation uses the same backend through a local Unix socket (`pnevma ctl`).

## Crate boundaries

- `pnevma-core`: task model, state transitions, orchestration, config parsing.
- `pnevma-session`: PTY/tmux session supervision, health, scrollback persistence.
- `pnevma-agents`: provider adapters and dispatch pool.
- `pnevma-git`: worktrees, leases, merge queue mechanics.
- `pnevma-context`: context compiler and manifests.
- `pnevma-db`: SQLx migrations/query layer.
- `pnevma-app`: Tauri command/control bridge and app state glue.

## State ownership rules

- Backend owns all workflow state and writes.
- Frontend never mutates authoritative state directly.
- Cross-pane synchronization happens through backend events + command refresh.

## Persistence model

- SQLite: project/task/session/pane/check/review/telemetry/feedback records.
- Append-only event log: audit/replay timeline.
- Filesystem artifacts: review packs, scrollback, knowledge captures, telemetry exports.

## Security/reliability controls

- One-task-one-worktree invariant.
- Merge queue serialization and pre-merge checks.
- Secret redaction on output paths (events/scrollback/review/context).
- Control socket permissions (`0600`) and optional password mode.
