• Proposed Plan


  # docs/upgrade-plan.md

  ## Summary

  Build Symphony-inspired (github.com/openAI/symphony) automation as a project-scoped runtime inside Pnevma, not as a replacement architecture. The codebase supports this, but the current task.dispatch path is too monolithic and the current
  auto_dispatch.rs loop is too thin to carry retries, reconciliation, tracker sync, or structured Codex sessions. The plan below first extracts a reusable run lifecycle, then adds a repo-owned automation contract, a
  coordinator, a real Codex app-server adapter, and finally tracker-driven automation and dynamic tools.

  ## Important Interface and Type Changes

  - Add AutomationConfig loaded from repo-owned WORKFLOW.md; keep ProjectConfig/pnevma.toml for static app and project settings.
  - Add project-scoped AutomationCoordinator and AutomationSnapshot types under crates/pnevma-commands.
  - Add persistent automation rows in SQLite for live run state and retry state instead of overloading tasks or sessions.
  - Keep AgentAdapter method shape; extend AgentEvent and TaskPayload so Codex can report thread/turn IDs, token/rate-limit updates, semantic heartbeats, and dynamic tool calls without breaking Claude support.
  - Add TaskExternalSource metadata so external tracker items materialize into normal TaskContracts instead of a second work-item model.

  ## Build Order

  1. Extract the agent-run lifecycle out of task.dispatch and make it project-runtime-owned.
     What: Split dispatch_task into reusable prepare/start/event/finalize steps and move automation task ownership into ProjectRuntime.
     Where: crates/pnevma-commands/src/commands/tasks.rs, new crates/pnevma-commands/src/automation/{mod.rs,runner.rs}, crates/pnevma-commands/src/state.rs, crates/pnevma-commands/src/commands/project.rs, crates/pnevma-
     bridge/src/lib.rs.
     How: Keep manual task.dispatch behavior unchanged, but have it call a new runner service; stop starting auto_dispatch globally from the bridge and start/stop automation per open project.
     Depends on: none.
     Effort: L (~500 LOC, extraction across 5 files, no schema change).
  2. Add repo-owned WORKFLOW.md parsing, validation, and hot reload.
     What: Introduce a markdown contract with YAML front matter for automation policy and a body for base prompt instructions.
     Where: crates/pnevma-core/src/config.rs, new crates/pnevma-core/src/workflow_contract.rs, new crates/pnevma-commands/src/automation/workflow_store.rs, new doc docs/pnevma-workflow-reference.md.

• Explored
  └ Search "id"|"threadId"|"turnId"|"status" in TurnStartResponse.json
     How: Support enabled, poll_interval_seconds, max_concurrent, active_task_statuses, hooks, retry, # docs/upgrade-plan.md` Content

  ## Summary

  Build the Symphony-inspired upgrade as a project-scoped automation runtime inside Pnevma, not as a product rewrite. The codebase reality changes the first step: before adding a coordinator, extract the task-run lifecycle
  out of crates/pnevma-commands/src/commands/tasks.rs so scheduling, retries, and tracker polling are not bolted onto a single 700+ line command handler. The local codex binary on this machine already exposes app-server
  plus JSON schema generation, so the Codex upgrade should target the real v2 JSON-RPC app-server protocol over stdio.

  ## Important Interface And Type Changes

  - Add AutomationConfig / WorkflowContract loaded from repo-owned WORKFLOW.md; keep ProjectConfig in crates/pnevma-core/src/config.rs for static app/project settings.
  - Add AutomationCoordinator, AutomationSnapshot, and a project-owned automation runtime handle under crates/pnevma-commands/src/state.rs.
  - Add persistent automation state in SQLite: automation_runs, automation_retries, and task_external_sources.
  - Extend AgentEvent for structured Codex app-server semantics (ThreadStarted, TurnStarted, TurnCompleted, RateLimitUpdated, SemanticHeartbeat, DynamicToolCall) while keeping the existing AgentAdapter trait shape so Claude
    stays compatible.
  - Extend TaskContract with external_source metadata instead of introducing a second work-item model.

  ## Build Order


  1. What: Extract the agent-backed task execution lifecycle into a reusable automation runner and make
project runtime ownership explicit. Where: crates/pnevma-commands/src/commands/tasks.rs, new crates/
pnevma-commands/
     src/automation/{mod.rs,runner.rs}, crates/pnevma-commands/src/state.rs, crates/pnevma-commands/src/
commands/project.rs, crates/pnevma-bridge/src/lib.rs. How: Move worktree creation, context compilation,
adapter spawn/
     send, event draining, acceptance checks, and cleanup into automation::runner; keep task.dispatch
behavior unchanged but have it call the runner; stop starting auto-dispatch globally from the bridge and
instead attach
     automation tasks to ProjectRuntime. Depends on: none. Effort: L, ~500 LOC extracted across 4-5
files.
  2. What: Introduce repo-owned WORKFLOW.md with typed automation config and hot reload. Where: crates/
pnevma-core/src/config.rs, new crates/pnevma-core/src/workflow_contract.rs, new crates/pnevma-commands/
src/automation/
     workflow_store.rs, new docs/pnevma-workflow-reference.md. How: Parse YAML front matter plus
markdown body into AutomationConfig with fields for polling, concurrency, active task statuses, retry
policy, hooks, Codex
     settings, tracker settings, and prompt template; poll WORKFLOW.md by mtime+hash every 2s; keep
last-known-good config on parse/validation failure; do not hot-reload pnevma.toml. Depends on: 1.
Effort: M, ~250 LOC plus
     parser/watcher tests. Parallel with 3 after item 1 lands.
  3. What: Replace the current polling loop with a project-scoped AutomationCoordinator. Where: crates/
pnevma-commands/src/auto_dispatch.rs, new crates/pnevma-commands/src/automation/coordinator.rs, crates/
pnevma-commands/
     src/state.rs, crates/pnevma-commands/src/commands/project.rs. How: Coordinator owns claims,
dispatch queue, running set, retry queue, and a canonical AutomationSnapshot; on each tick it validates
current automation
     config, discovers Ready && auto_dispatch tasks, ignores already-claimed work, starts runs via item
1 until concurrency is full, and reconciles stale claims before sleeping. Manual task.dispatch keeps
working but
     registers into the same running-set snapshot with origin=manual. Depends on: 1, 2. Effort: L, ~400-
600 LOC and one new service boundary.
  4. What: Persist automation runtime state and expose the canonical snapshot through existing status
surfaces. Where: new DB migration 0017_automation_runtime, crates/pnevma-db/src/models.rs, crates/
pnevma-db/src/store.rs,
     crates/pnevma-commands/src/commands/project.rs, crates/pnevma-remote/src/routes/api.rs, crates/
pnevma-remote/src/server.rs. How: Add automation_runs and automation_retries rows keyed by task/session/
thread;
     project.status grows an automation object; add GET /api/project/automation rather than a separate
API namespace. Depends on: 3. Effort: M, 1 migration plus ~250 LOC. Parallel with 5 once snapshot fields
are fixed.
  5. What: Replace the one-shot Codex CLI adapter with a Codex app-server v2 adapter. Where: crates/
pnevma-agents/src/adapters/codex.rs, crates/pnevma-agents/src/model.rs, crates/pnevma-agents/src/
registry.rs, runner glue
     from item 1. How: Start codex app-server --listen stdio://, speak JSON-RPC v2 over stdio, use thre
ad.start for initial session setup and turn.start for each prompt/continuation, map
turn.interrupt/thread shutdown to i
     nterrupt/stop, and emit structured usage/rate-limit/tool-call events instead of regex-parsing
stdout. Keep the AgentAdapter trait intact; enrich AgentEvent instead. Depends on: 1. Effort: L, full
adapter rewrite across
     ~600 LOC. Parallel with 4 after item 1.
  6. What: Add continuation, retry backoff, stall recovery, and reconciliation semantics to the
coordinator. Where: crates/pnevma-commands/src/automation/{coordinator.rs,runner.rs}, crates/pnevma-
session/src/supervisor.rs,
     crates/pnevma-core/src/task.rs, crates/pnevma-core/src/workflow.rs. How: Continue on the same Codex
thread after normal non-terminal completion, retry transient failures with exponential backoff, treat
semantic-event
     silence as stall, and reconcile every running claim against task status, session liveness, and
worktree validity on each tick and at project open; keep worktrees/branches intact across retriable
failures and only clean
     them up on terminal fail/done/cancel. Depends on: 3, 4, 5. Effort: L, behavior refactor across 4
files. Parallel with 7 after item 2.
  7. What: Add repo-defined worktree hooks and harden worktree path validation. Where: crates/pnevma-
git/src/service.rs, runner/coordinator modules, workflow_contract.rs. How: Support after_create,
before_run, after_run,
     and before_remove hooks as explicit argv commands with per-hook timeout and redacted logging; make
after_create/before_run fatal to dispatch and after_run/before_remove best-effort; replace canonicalize-
only checks
     with per-component symlink_metadata validation before create/remove/cleanup. Depends on: 1, 2, 3.
Effort: M, ~200 LOC plus tests.
  8. What: Add external tracker support with a Linear adapter, mapped into normal Pnevma tasks. Where:
new crates/pnevma-tracker/, crates/pnevma-core/src/task.rs, new DB migration 0018_task_external_sources,
crates/pnevma-
     db/src/store.rs, coordinator module. How: Define TrackerAdapter { poll_candidates, fetch_states,
transition_item }; add TaskExternalSource { kind, external_id, identifier, url, state }; upsert tasks by
(project_id,
     kind, external_id); let the coordinator poll tracker candidates and reconcile running work against
external state without introducing a second execution model. Depends on: 2, 3, 4, 6. Effort: L, 1 new
crate plus schema
     and coordinator wiring.
  9. What: Add coordinator-owned dynamic tracker tools for Codex automation mode. Where: Codex adapter
from item 5, tracker crate from item 8, coordinator module. How: Register tracker.query and
tracker.update_state as
     dynamic tools during thread.start; handle DynamicToolCallParams callbacks from the app-server;
delegate execution to the tracker crate with scoped credentials; persist redacted tool request/response
events in the
     existing event log and expose them in the automation snapshot. Depends on: 5, 8. Effort: M, ~150-
250 LOC. No useful parallelism before item 8.

  ## Conflicts Resolved

  - Coordinator-first vs hot-reload-first: both source plans missed the monolithic dispatch_task seam;
the real first move is runner extraction, then coordinator, then hot-reload consumption.
  - Add continuation to the current adapter vs replace Codex transport first: use Codex app-server
first; the current stdin-close subprocess model cannot support real continuation.
  - Standalone observability API vs reuse current surfaces: extend project.status and /api/project/*;
the repo already has authenticated remote API plumbing.
  - Hooks in pnevma.toml vs hooks in WORKFLOW.md: split ownership; static product config stays in
pnevma.toml, repo automation behavior moves to WORKFLOW.md.
  - Tracker on current auto_dispatch.rs vs tracker after coordinator: wait for coordinator + persisted
retry/reconciliation; the current loop has no claim ownership.

  ## Cut List

  - Hot-reloading pnevma.toml: cut as wrong boundary; it mixes app settings with repo automation policy.
  - Priority-based concurrency caps: cut as premature; the useful abstraction is external-state-aware
gating after tracker support exists.
  - A separate /api/v1/state observability product: cut as redundant with existing remote/API surfaces.
  - A parallel external issue model beside TaskContract: cut because it would fork review, merge,
history, and UI logic.
  - Pseudo-continuation on the current Codex adapter: cut because the transport exits after one prompt.
  - Symphony-style persistent plain directories instead of Git worktrees: cut because it regresses
Pnevma’s branch/worktree isolation.

  ## Validation Criteria
automation tasks start/stop with open_project instead of from the bridge singleton.
      2. cargo test -p pnevma-core workflow_contract and cargo test -p pnevma-commands workflow_store
pass, including a test where invalid WORKFLOW.md reload preserves the prior config.
      3. cargo test -p pnevma-commands automation_coordinator passes, including no-double-claim, max-
concurrency, and manual-dispatch-registration cases.
      4. cargo test -p pnevma-db && cargo test -p pnevma-remote pass, and GET /api/project/automation
plus project.status return the same snapshot fields.
      5. cargo test -p pnevma-agents codex_adapter passes, and the adapter emits thread/turn IDs plus
token usage from app-server notifications instead of regex text parsing.
      6. cargo test -p pnevma-commands automation_retry passes, proving continuation reuse, exponential
backoff, semantic stall recovery, restart recovery, and no cleanup on retriable failure.
      7. cargo test -p pnevma-git && cargo test -p pnevma-commands hook pass, including symlink-
component rejection and fatal-vs-best-effort hook behavior.
tracker adapter and produces a redacted event-log record.

  - Use Codex app-server v2 over stdio, not WebSocket transport.
  - Keep the existing AgentAdapter method surface; add structured events rather than a second provider
API.