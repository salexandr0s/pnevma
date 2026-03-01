# Implementation Status

## Completed in this scaffold

- Cargo workspace with all planned crates.
- Core domain contracts: event types, task contract, state transitions, dispatch queue.
- DB layer with full initial migration set and typed query helpers.
- Session supervision model with health transitions and persistence hooks.
- Agent adapter trait with CLI-backed Claude Code and Codex implementations, plus adapter registry and dispatch pool.
- Git service scaffolding for worktree create/cleanup and merge queue lock.
- Context compiler V1/V2 scaffolds with token budget enforcement.
- Tauri app shell with commands for project/session/task/cost/dispatch basics.
- React frontend shell with command palette, pane model, xterm-based terminal pane, task board pane, and placeholders for later panes.
- ADR seed for terminal rendering.
- Session runtime now spawns real shell processes and streams output to the frontend via Tauri events.
- Session scrollback retrieval command (`get_scrollback`) and input command (`send_session_input`) are wired.
- Startup now reconciles persisted sessions against backend liveness and exposes `restart_session` for failed reattach paths.
- Session runtime now uses a tmux-backed backend for live reattach of running sessions after app restart.
- Session liveness reconciliation now checks tmux using the same project-local `TMUX_TMPDIR` socket path as runtime session creation.
- Manual `reattach_session` command is available for waiting sessions; restart remains available for dead backends.
- Pane records are now project-scoped and persisted/reloaded through backend commands.
- Frontend now renders panes simultaneously in a multi-pane grid instead of single-pane-only view.
- Event records now support task/session filters with indexed DB queries and Tauri query command exposure.
- Session scrollback now uses append-only indexed offsets and seek-based retrieval.
- Tracing now writes structured JSON logs to local log files in addition to console output.
- Task API now includes get/update/delete and richer task payloads (constraints, dependencies, status transitions).
- Dispatch flow now creates git worktrees, compiles/writes task context, invokes detected real adapters, and emits reactive task/cost updates.
- Worktree rows are now persisted and exposed via list/cleanup commands.
- Frontend task board now shows dependency counts, queue indicators, cost badges, and listens reactively to backend task/cost events.
- Phase 0 spike directories now contain validation procedures and evidence templates instead of placeholders.
- Backend command palette now uses a registry-driven command catalog and executes command IDs via backend routing.
- Optional local Unix socket control plane now runs inside the Tauri backend, with newline JSON envelopes and method routing for project/task/session/notification automation.
- New `pnevma ctl` CLI binary now sends local automation requests over the control socket.
- Task terminal-state transitions now automatically clean up linked worktrees and clear branch/worktree task links.

## Pending for full plan completion

- Full task dependency DAG persistence + auto-block/unblock transitions across all dependency-edit and completion paths.
- Acceptance checks, review packs, merge gating/conflict flows.
- Keychain-backed secret manager and output redaction middleware.
- Replay timeline, stuck detection, daily brief, AI task drafting.
- Packaging/notarization, full keyboard audit, full-text search, onboarding.
- Manual desktop latency measurement for the xterm UI spike remains pending in this headless environment.
