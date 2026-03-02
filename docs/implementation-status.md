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
- Dependency DAG validation now rejects invalid IDs, self-deps, missing deps, and cycles; dependency status refresh now reconciles from `task_dependencies` table and emits `TaskStatusChanged` events on auto-block/unblock.
- Phase 3 persistence migration added for `check_runs`, `check_results`, `merge_queue`, `notifications`, and `secret_refs`.
- Acceptance checks now run on agent completion; automated failures keep tasks `InProgress`, automated pass paths generate review packs and move tasks to `Review`.
- Review pack generation now writes JSON and diff artifacts to `.pnevma/data/reviews/<task-id>/` and persists review metadata.
- Review decisions now support approve/reject flows and merge queue enqueueing.
- Merge execution command now performs rebase, post-rebase check reruns, conflict blocking, merge, and task/worktree finalization.
- Merge queue now has explicit reorder support (`move_merge_queue_item`) and emits `merge_queue_updated` events.
- Checkpoint create/list/restore commands are implemented with git tag snapshots.
- Secrets references are persisted and backed by macOS Keychain (`security` CLI), with secret injection for agent env and redaction in notification/tool-output persistence paths.
- Notifications are now persisted, support unread/read lifecycle commands, have a dedicated frontend pane, and now ingest OSC attention sequences (`9`/`99`/`777`) from both session and agent output streams.
- Frontend review pane now supports task selection, check result display, review pack inspection, approve/reject actions, and merge trigger.
- Frontend now includes a dedicated merge queue pane with queue ordering controls and merge execution action.
- macOS build-script environment handling now sets temp-directory vars before Tauri build tooling to avoid `xcrun` temp-path warnings in constrained environments.
- Redaction hardening expanded:
  - append-only event payload redaction at write path
  - automation control-plane audit redaction
  - session stream redaction before scrollback persistence
  - context markdown + manifest redaction before export
  - review pack diff/check content redaction before persistence
- Phase 4 backend command surface added:
  - session replay timeline: `get_session_timeline`
  - recovery workflow: `get_session_recovery_options`, `recover_session`
  - daily brief: `get_daily_brief`
  - task drafting: `draft_task_contract`
- Control-plane methods now include:
  - `session.timeline`
  - `session.recovery.options`
  - `session.recovery.execute`
  - `project.daily_brief`
  - `task.draft`
  - `merge.queue.reorder`
- Added tests for OSC parsing and redaction paths in `pnevma-app` and `pnevma-session`.
- Phase 4 frontend surfaces are now implemented:
  - replay timeline pane
  - recovery action panel
  - daily brief pane
- Command palette now includes pane actions for replay and daily brief, and frontend includes “Draft Task From Text” flow with pre-save editable fields.
- Task drafting now attempts provider-backed generation first and falls back to deterministic local drafting with warning metadata.
- Added proxy latency benchmark script (`scripts/latency_proxy.sh`) and recorded proxy measurements in `spike/tauri-terminal/latency-notes.md`.
- Pane layout templates are now persisted in project DB (`pane_layout_templates`) with built-in system templates:
  - `solo-focus`
  - `review-mode`
  - `debug-mode`
- New Tauri commands:
  - `list_pane_layout_templates`
  - `save_pane_layout_template`
  - `apply_pane_layout_template`
- Template apply is non-destructive by default: backend preflights replacement panes for unsaved state and returns warnings unless `force=true`.
- Applying templates now emits both `pane_updated` and `project_refreshed` events for immediate frontend synchronization.
- Command palette now includes:
  - save current pane graph as a named template
  - apply any available template (system or custom), with unsaved-replacement confirmation when required
- Phase 5 workflow slices implemented:
  - project-wide search command and pane (`search_project`) across tasks/events/artifacts/commits/scrollback
  - file browser command/pane (`list_project_files`, `open_file_target`) with git-status indicators and preview/editor open actions
  - dedicated diff viewer command/pane (`get_task_diff`) with inline and side-by-side rendering by file/hunk
  - control-plane coverage for the above (`project.search`, `workspace.files`, `workspace.file.open`, `review.diff`)
  - command palette pane actions for Search, Diff, and File Browser
- Additional Phase 5 polish slices now implemented:
  - rule/convention manager pane + control-plane methods + context inclusion usage tracking
  - post-merge knowledge-capture flow with artifact persistence and merge-triggered prompt
  - keybinding customization persisted in global config and consumed by command-palette/pane-focus shortcuts
  - quick keyboard actions for high-frequency flow (`task.new`, `task.dispatch_next_ready`, `review.approve_next`)
  - settings/rules UX hardening: inline forms with validation/status messages (no browser `prompt`/`alert`/`confirm` dependency)
  - onboarding state API + frontend guided overlay + onboarding instrumentation events/telemetry
  - telemetry management surface (opt-in, queue count, export, clear)
  - design-partner instrumentation primitives (`submit_feedback`, expanded partner metrics report)
  - macOS release scripts and runbook for signing/notarization/stapling (`scripts/release-macos-*.sh`, `docs/macos-release.md`)
  - strict checks-only release preflight gate (`scripts/release-preflight.sh`)
  - shared IPC harness helper + recovery smoke scenario (`scripts/ipc-common.sh`, `scripts/ipc-e2e-recovery.sh`)
  - deeper Phase 5 testing:
    - property-based dispatch queue ordering invariants
    - property-based merge-queue FIFO + serialized merge lock coverage
    - worktree lease stale/refresh invariants
    - DB roundtrip tests for onboarding/rules usage/telemetry/feedback
    - session fault-path tests for missing-session scrollback/input operations
    - session fault-path tests for offset clamp, zero-limit reads, directory-path IO failures, invalid UTF-8 safety
    - control-plane auth regression tests (missing/invalid/valid password + same-user mode)
- First-launch bootstrap surface now implemented:
  - backend readiness/init commands (`get_environment_readiness`, `initialize_global_config`, `initialize_project_scaffold`)
  - command registry + control-plane routing for environment/project initialization and `task.create`
  - frontend first-launch setup panel for path-based readiness/init/open flow
- Updater rollout scaffolding now implemented:
  - Tauri updater plugin wiring in app shell
  - updater config stub in `tauri.conf.json` (endpoint/pubkey placeholders)
  - helper scripts for updater key generation, runtime overlay config, artifact signing, and feed manifest generation
- Documentation core set now added:
  - getting started guide
  - `pnevma.toml` reference
  - keyboard shortcut reference
  - architecture overview
  - IPC harness usage + release checklist + design-partner readiness guide
- Additional fault-path coverage now includes restored-session missing-scrollback IO failure handling in `pnevma-session`.

## Resolved since initial audit

The following items were identified as open in an earlier audit snapshot. All have since been resolved:

### P0 — Blocks daily use (all resolved)

- **Terminal resize (SIGWINCH):** Resolved — `supervisor.rs:456` uses `tmux resize-window`; `TerminalPane.tsx` has `ResizeObserver` sending `resize_session` IPC.
- **Content Security Policy:** Resolved — `tauri.conf.json:14` has full CSP: `default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src ipc: https://tauri.localhost; img-src 'self' data:`.
- **CI/CD pipeline:** Resolved — `.github/workflows/ci.yml` (cargo fmt, clippy, test, audit + npm ci, tsc, lint); `.github/dependabot.yml` for cargo/npm/github-actions.

### P1 — Required before design partner use (all resolved)

- **Context compiler file discovery:** Resolved — `crates/pnevma-context/src/discovery.rs` implements `FileDiscovery` with 4 strategies (scope, claude_md, git_diff, grep).
- **Path validation hardening:** Resolved — `open_file_target` and `export_telemetry_bundle` both use `canonicalize()` + `starts_with()`.
- **Deprecated xterm packages:** Resolved — `frontend/package.json` uses `@xterm/xterm@6.0.0` (not deprecated `xterm`).
- **Desktop `.app` bundle:** Resolved — `tauri.conf.json:36` has `bundle.active: true, targets: "all"`; release scripts exist.

### P2 — Should fix before beta (all resolved)

- **Workspace trust:** Resolved — Global trust DB at `~/.local/share/pnevma/global.db` with SHA-256 fingerprinting of `pnevma.toml`. Trust gate in `open_project()` blocks untrusted/changed workspaces. Frontend trust/re-trust dialogs. New commands: `trust_workspace`, `revoke_workspace_trust`, `list_trusted_workspaces`.
- **Native dialog replacement:** Resolved — `frontend/src/components/Dialog.tsx` provides custom React dialog; `nativeAlert`/`nativeConfirm`/`nativePrompt` alias to it.
- **`constant_time_eq` bug:** Resolved — `control.rs:413` now uses `subtle::ConstantTimeEq`.
- **Socket input size limits:** Resolved — `control.rs:223` enforces `MAX_LINE_BYTES = 1MB` guard before JSON parsing.
- **Explicit Tauri capabilities:** Resolved — `crates/pnevma-app/capabilities/default.json` defines explicit per-window IPC restrictions with core:default, core:window, core:event, and updater permissions scoped to the main window.
- **Frontend event efficiency:** Resolved — Backend emits enriched event payloads with full objects (`emit_enriched_task_event`, `session_row_to_event_payload`). Frontend uses surgical store updates (`upsertTask`, `removeTask`, `upsertSession`, `removeSession`, `upsertNotification`, `removeNotification`, etc.) with fallback to full refresh only on `project_refreshed`.
- **`.gitignore` missing `.env`:** Resolved — `.gitignore` now excludes `.env` and `.env.*` files.

## Remaining operational items

These are not code bugs — they are operational/deployment steps:

- **Updater production activation:** Replace updater endpoint/pubkey placeholders in `tauri.conf.json` with production values; publish first signed feed artifacts (`latest.json` + binaries + signatures).
- **Latency validation (manual):** The <50ms perceived-latency target has only been benchmarked via `scripts/latency_proxy.sh`. Must be validated manually on actual hardware before external use. See `docs/latency-validation.md` for the protocol.
