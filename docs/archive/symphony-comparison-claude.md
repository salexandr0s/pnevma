# Pnevma vs Symphony: Comparative Analysis

## 1. Architecture Comparison

### 1.1 System Identity

| Dimension | Pnevma | Symphony |
|---|---|---|
| **Language** | Rust (10-crate workspace) + Swift/AppKit | Elixir/OTP (Phoenix + GenServer) |
| **Delivery model** | Native macOS app (`.app` bundle) | Long-running daemon/CLI process |
| **Work source** | Local task contracts defined in-app or via YAML workflows | Linear issue tracker polling (API-driven) |
| **Agent targets** | Claude Code, Codex (provider-neutral `AgentAdapter` trait) | Codex app-server only (JSON-RPC stdio) |
| **Concurrency model** | Tokio async + priority `BinaryHeap` dispatch pool | OTP GenServer + `Task.Supervisor` |
| **Persistence** | SQLite (sqlx compile-time queries) + append-only event log | Fully in-memory; recovery is tracker-driven |
| **Terminal integration** | Embedded Ghostty via xcframework (real PTY) | None — agents are headless subprocesses |
| **Remote access** | HTTP/WS server with TLS, token auth, rate limiting | Optional Phoenix HTTP server for observability |

### 1.2 Orchestration Model

| Aspect | Pnevma | Symphony |
|---|---|---|
| **Scheduling trigger** | Auto-dispatch polling loop (`auto_dispatch.rs`) + manual dispatch | Fixed-interval poll tick against Linear |
| **Concurrency control** | `DispatchPool` with max slots + priority queue | `max_concurrent_agents` + per-state limits (`max_concurrent_agents_by_state`) |
| **Task identity** | UUID-based `TaskContract` with inline metadata | Linear issue ID + identifier (external source of truth) |
| **Claim/dedup** | Pool-level `active` counter; one-task-one-worktree invariant | Explicit `claimed` MapSet + `running` map; double-dispatch prevention |
| **State machine** | `Planned→Ready→InProgress→Review→Done/Failed/Blocked/Looped` | `Unclaimed→Claimed→Running→RetryQueued→Released` (internal) + tracker states (external) |
| **Retry strategy** | `FailurePolicy` per-step (Pause/RetryOnce/Skip) + workflow loop config | Exponential backoff with `10s × 2^(attempt-1)` capped at `max_retry_backoff_ms`; continuation retries at 1s fixed delay |
| **Reconciliation** | Manual or workflow-driven; no external tracker polling | Every tick: stall detection + tracker state refresh → terminate/update/release |
| **Config hot-reload** | Static config from `pnevma.toml` at project open | `WorkflowStore` GenServer polls `WORKFLOW.md` every 1s; mtime+hash change detection; last-known-good fallback |

### 1.3 Workspace Isolation

| Aspect | Pnevma | Symphony |
|---|---|---|
| **Isolation unit** | Git worktree per task (`pnevma-git` crate, `GitService.create_worktree`) | Filesystem directory per issue (`Workspace.create_for_issue`) |
| **VCS integration** | Built-in: branch creation, worktree lifecycle, lease tracking, merge queue | None built-in; deferred to `after_create` hook (e.g., `git clone`) |
| **Workspace reuse** | Worktree removed on task completion/failure; branch cleaned up | Workspace persisted across runs for same issue; reused automatically |
| **Path safety** | Worktree stays under `.pnevma/worktrees/`; lease-based ownership | `validate_workspace_path` ensures containment under root; symlink traversal guard |
| **Lifecycle hooks** | No hook system; worktree lifecycle is code-managed | Four hooks: `after_create`, `before_run`, `after_run`, `before_remove` — with timeout enforcement |

### 1.4 Agent Lifecycle

| Aspect | Pnevma | Symphony |
|---|---|---|
| **Agent abstraction** | `AgentAdapter` trait: `spawn`, `send`, `interrupt`, `stop`, `events`, `parse_usage` | Direct Codex app-server integration via Erlang Port (stdio JSON-RPC) |
| **Multi-provider** | Yes — adapter registry supports Claude Code + Codex simultaneously | No — Codex only |
| **Multi-turn** | Single task dispatch per agent session | Multi-turn within one worker run: up to `max_turns` continuation turns on same thread |
| **Session supervision** | `SessionSupervisor` with tmux-backed PTY, scrollback, health tracking | `Task.Supervisor.start_child` + `Process.monitor`; no PTY layer |
| **Stall detection** | `SessionSupervisor.refresh_health()` → idle (2min) → stuck (10min) | Orchestrator-level: `codex.stall_timeout_ms` (default 5min) checked every tick |
| **Cost tracking** | `CostRecord` per session: provider, model, tokens in/out, estimated cost | Aggregate `codex_totals` (input/output/total tokens + seconds_running); rate-limit snapshot |
| **Secret redaction** | Full redaction pipeline: pattern-based + custom secrets, applied to scrollback, events, context packs | `$VAR` indirection for config secrets; no output redaction system |

### 1.5 State Management

| Aspect | Pnevma | Symphony |
|---|---|---|
| **Persistence** | SQLite: 18 row types (projects, tasks, sessions, panes, checks, reviews, telemetry, feedback) + append-only event log + filesystem artifacts | Fully in-memory `State` struct in GenServer; no database |
| **Event sourcing** | `EventStore` trait with `InMemoryEventStore` impl; 40+ event types; filterable by project/task/session/time | No event store; structured logging is the observability layer |
| **Recovery model** | Full state recovery from SQLite + session re-attachment via tmux | Tracker-driven recovery: startup cleanup of terminal workspaces → fresh polling → re-dispatch |

---

## 2. Symphony Components Worth Adopting

### 2.1 Issue Tracker Integration (External Work Source)

**What it does**: Symphony's `Tracker` module polls Linear's GraphQL API on a configurable cadence, fetches candidate issues in active states, normalizes them into a stable `Issue` model, and feeds them to the orchestrator. The tracker also supports reconciliation queries (`fetch_issue_states_by_ids`) and terminal-state cleanup (`fetch_issues_by_states`).

**Why it matters**: Pnevma's work source is entirely local — tasks are created manually or from YAML workflow definitions. Adding a tracker integration would let Pnevma pull work from Linear, GitHub Issues, Jira, or any external system, making it usable in team workflows where work is already tracked externally. The agent can work unattended while the team manages priorities in their existing tools.

**Estimated complexity**: **Medium**. Pnevma's `pnevma-core` already has a task model with status, priority, and dependencies. The adapter pattern is straightforward: a new `pnevma-tracker` crate implementing a polling loop that creates `TaskContract`s from external issues. The normalization layer (blockers, labels, state mapping) and the blocker-gating logic (`Todo` blocked by non-terminal) are well-specified in Symphony's SPEC.md §4 and §8.2.

**Where it fits**: New `pnevma-tracker` crate, invoked by the auto-dispatch loop in `pnevma-commands/src/auto_dispatch.rs`. The tracker adapter would create tasks via the existing `commands::create_task` path, and reconciliation would use `commands::update_task_status`.

### 2.2 Dynamic Workflow Hot-Reload

**What it does**: Symphony's `WorkflowStore` is a GenServer that polls `WORKFLOW.md` every second, compares mtime + size + content hash, and re-applies config (poll interval, concurrency limits, active states, codex settings, prompt template) without restart. On invalid reload, it keeps the last known good config and logs an error.

**Why it matters**: Pnevma loads `pnevma.toml` at project open time and doesn't watch for changes. If you edit agent config, concurrency limits, or workflow steps, you must close and reopen the project. Hot-reload would let operators adjust behavior (e.g., throttle concurrency, change agent model, update workflow steps) without interrupting running agents.

**Estimated complexity**: **Low**. Pnevma's `pnevma-core/src/config.rs` already parses `pnevma.toml`. Adding a file-watcher (via `notify` crate) or a polling task that re-reads the config file and updates the `AppState.current` config would be minimal. The "last known good" fallback pattern from `WorkflowStore` is simple to replicate.

**Where it fits**: Inside `pnevma-commands/src/state.rs` — add a background Tokio task that watches `pnevma.toml` and `.pnevma/workflows/*.yaml` for changes, re-parses, validates, and swaps the config in `AppState.current`.

### 2.3 Workspace Lifecycle Hooks

**What it does**: Symphony defines four hook points (`after_create`, `before_run`, `after_run`, `before_remove`) as shell script strings in the workflow config. Each runs in the workspace directory with a configurable timeout (`hooks.timeout_ms`, default 60s). `after_create` and `before_run` failures are fatal; `after_run` and `before_remove` failures are logged and ignored.

**Why it matters**: Pnevma's worktree lifecycle is fully code-managed — there's no user-extensible hook point for custom setup (install deps, run linters, seed data), teardown (cleanup tmp files, archive logs), or pre-run validation (check env vars, verify access). Hooks would make Pnevma composable with arbitrary project setups without requiring code changes.

**Estimated complexity**: **Low**. This is a shell subprocess call at four well-defined points in `pnevma-git/src/service.rs` (create_worktree, before dispatch, after completion, remove_worktree). The timeout pattern is a standard `tokio::time::timeout` wrapper around `Command::new("sh")`.

**Where it fits**: Config in `pnevma.toml` under a `[hooks]` section; execution in `pnevma-git` for worktree lifecycle and `pnevma-commands` for dispatch lifecycle.

### 2.4 Multi-Turn Agent Sessions with Continuation Logic

**What it does**: Symphony's `AgentRunner.run_codex_turns` keeps the Codex app-server subprocess alive across multiple turns (up to `max_turns`, default 20). After each successful turn, it re-checks the issue state via the tracker. If the issue is still active, it sends continuation guidance to the existing thread rather than re-sending the original prompt. After a normal worker exit, the orchestrator schedules a short 1s continuation retry to re-check eligibility.

**Why it matters**: Pnevma dispatches one task per agent session. If the task partially completes, the agent exits and a new session must be created with a fresh context window. Multi-turn continuation would let long-running tasks proceed iteratively within a single context, avoiding context loss and reducing token usage from re-prompting.

**Estimated complexity**: **Medium**. Pnevma's `AgentAdapter` trait has `spawn`, `send`, `stop` but no concept of a persistent thread with multiple turns. The `TaskPayload` would need an `is_continuation` flag, and the adapter would need to keep the subprocess alive between turns. The orchestrator would need a "re-check and continue" loop similar to Symphony's `do_run_codex_turns`.

**Where it fits**: Inside `pnevma-agents/src/adapters/` — extend the Codex adapter to support multi-turn. The loop logic goes in `pnevma-commands/src/commands/agents.rs` dispatch handler.

### 2.5 Per-State Concurrency Limits

**What it does**: Symphony's `max_concurrent_agents_by_state` config allows setting different concurrency caps per issue state. For example, you might allow 10 concurrent `In Progress` agents but only 2 concurrent `Todo` agents (since Todo tasks may have unresolved blockers). State keys are normalized (trim + lowercase).

**Why it matters**: Pnevma has a single global `max_concurrent` setting. Per-state (or per-priority) limits would enable smarter resource allocation — e.g., reserving slots for high-priority P0 tasks while letting P2/P3 tasks fill remaining capacity.

**Estimated complexity**: **Low**. The `DispatchPool` already tracks active count. Adding a per-priority or per-category counter is straightforward. The check would go in `auto_dispatch.rs` before dispatching.

**Where it fits**: Config in `pnevma.toml` under `[agents]`; enforcement in `pnevma-commands/src/auto_dispatch.rs` and `pnevma-agents/src/pool.rs`.

### 2.6 Exponential Backoff Retry with Continuation Semantics

**What it does**: Symphony distinguishes between two retry types: (1) continuation retries after normal exit (1s fixed delay, attempt=1) and (2) failure retries with exponential backoff (`10s × 2^(attempt-1)`, capped at 5 minutes). The retry entry tracks attempt count, due time, identifier, and error string. Timer handles are stored and cancelled on re-scheduling.

**Why it matters**: Pnevma's `FailurePolicy` (Pause/RetryOnce/Skip) is coarse. It has no backoff, no continuation retry, and no way to distinguish transient failures from hard failures. Exponential backoff prevents hammering a failing agent or rate-limited API, while continuation retries enable the "check and re-dispatch if still needed" pattern.

**Estimated complexity**: **Low-Medium**. The retry logic is self-contained — a scheduled Tokio timer + retry metadata stored alongside the task. The workflow loop mechanism (`LoopConfig`) already has `max_iterations`, so this is an extension of existing concepts.

**Where it fits**: `pnevma-core/src/workflow.rs` for the retry config; `pnevma-commands/src/auto_dispatch.rs` for the timer and re-dispatch logic.

### 2.7 Observability HTTP API

**What it does**: Symphony's optional HTTP server (`/api/v1/state`, `/api/v1/<issue_identifier>`, `POST /api/v1/refresh`) provides JSON endpoints for runtime state inspection — running sessions with turn counts, retry queue with delays, aggregate token totals, and rate limits. A Phoenix LiveView dashboard renders this data in a human-readable format.

**Why it matters**: Pnevma already has `pnevma-remote` with HTTP/WS endpoints, but these serve the native app's RPC protocol. Adding a structured observability API would let external tools (Datadog, Grafana, custom dashboards) monitor agent fleet status, cost burn rate, and error patterns. The `/refresh` endpoint (trigger immediate poll) would be useful for CI integration.

**Estimated complexity**: **Low**. `pnevma-remote` already has the HTTP server infrastructure (Axum, TLS, auth, rate limiting). Adding JSON endpoints that serialize `AppState` is straightforward.

**Where it fits**: New routes in `pnevma-remote/src/routes/`.

---

## 3. Overlapping Components Where Symphony Does It Better

### 3.1 Reconciliation and Issue State Tracking

**Pnevma's approach**: Tasks are locally-owned. Status changes come from the agent's exit code or manual user action. There's no mechanism to check whether the external reality has changed (e.g., a ticket was closed by someone else, a dependency was unblocked).

**Symphony's approach**: Every poll tick, the orchestrator runs `reconcile_running_issues` (orchestrator.ex lines 237–263): it fetches current tracker states for all running issue IDs and acts on the result — terminal state stops the agent and cleans the workspace, active state updates the in-memory snapshot, non-active state stops the agent without cleanup. Failed state refreshes keep workers running (safe default).

**What's better and why**: Symphony's reconciliation loop is a fundamentally more robust design for long-running multi-agent systems. If a task becomes invalid (e.g., the PR was merged by a human, the ticket was moved to "Won't Fix"), Symphony detects and acts on it within one poll interval. Pnevma agents will continue running indefinitely on stale tasks, wasting compute and potentially creating conflicts.

**Specific reference**: `orchestrator.ex` `reconcile_running_issue_states/4` — the three-way branch (terminal → terminate+cleanup, active → refresh, other → terminate) is clean and handles edge cases (e.g., state refresh failures) gracefully.

### 3.2 Config Validation Before Dispatch

**Pnevma's approach**: Config is validated once at project open. Invalid config after a manual edit can leave the system in a broken state until restart.

**Symphony's approach**: `Config.validate!/0` is called at the start of every `maybe_dispatch` cycle (orchestrator.ex line 171). If validation fails (missing API key, unsupported tracker kind, invalid codex settings), dispatch is skipped for that tick but reconciliation still runs. The service stays alive and self-heals when the config is fixed.

**What's better and why**: Per-tick validation is defensive and operationally superior. In a long-running agent fleet, config drift (expired tokens, changed endpoints) is inevitable. Symphony's approach means the operator fixes the config and the system recovers on the next tick, with no restart required.

### 3.3 Workspace Path Safety (Symlink Guard)

**Pnevma's approach**: Worktree paths are constructed from task UUIDs under `.pnevma/worktrees/`. The path structure is predictable but there's no explicit symlink traversal check.

**Symphony's approach**: `Workspace.validate_workspace_path/1` (workspace.ex lines 201–227) not only checks prefix containment but also walks each path component with `File.lstat` to detect symlinks that could escape the workspace root. A symlink at any level triggers `{:error, {:workspace_symlink_escape, ...}}`.

**What's better and why**: The symlink guard closes a real attack surface. If an agent creates a symlink inside its worktree pointing outside the workspace root, a subsequent operation could escape isolation. Pnevma's worktree paths are UUID-based (harder to predict) but don't have this guard.

### 3.4 Stall Detection Granularity

**Pnevma's approach**: `SessionSupervisor.refresh_health()` classifies sessions as Active (recent heartbeat), Idle (>2 min), or Stuck (>10 min) based on `last_heartbeat`. This is PTY-level heartbeat — it detects whether the terminal has produced output, not whether the agent is making progress.

**Symphony's approach**: Stall detection in the orchestrator (orchestrator.ex `reconcile_stalled_running_issues`) uses `last_codex_timestamp` — the timestamp of the last semantic agent event (turn completion, tool use, notification), not raw PTY output. The timeout is configurable (`codex.stall_timeout_ms`, default 5 min). Stalled sessions are killed and retried with backoff.

**What's better and why**: Symphony's approach detects semantic stalls (agent is alive but not making progress) rather than PTY stalls (agent produced no output). An agent could be in a CPU-intensive tool call producing output but not advancing the task — Symphony would correctly not flag this. Conversely, an agent could be waiting on a rate limit with occasional keepalive output — Symphony would catch this via the codex event timestamp.

---

## 4. Pnevma Strengths Symphony Lacks

### 4.1 Native Terminal Embedding (Ghostty)

Pnevma embeds a real terminal emulator (Ghostty via xcframework) with full PTY support. This means users can see agent output in real-time, interact with sessions, send input, and scroll through history — all in a native macOS app. Symphony's agents are headless subprocesses with no interactive access; debugging requires tailing log files.

**Files**: `native/Pnevma/`, `pnevma-session/src/supervisor.rs`, `patches/ghostty/`

### 4.2 Provider-Neutral Agent Abstraction

Pnevma's `AgentAdapter` trait (`pnevma-agents/src/model.rs`) defines a clean interface for any coding agent: `spawn`, `send`, `interrupt`, `stop`, `events`, `parse_usage`. The `AdapterRegistry` allows multiple providers simultaneously. A project can use Claude Code for complex tasks and Codex for simpler ones, selected per-task via `agent_profile_override`.

Symphony is hardcoded to Codex app-server. Switching to a different agent requires rewriting the entire `Codex.AppServer` module.

**Files**: `pnevma-agents/src/model.rs`, `pnevma-agents/src/registry.rs`, `pnevma-agents/src/adapters/`

### 4.3 Git-Native Workspace Isolation

Pnevma's `GitService` (`pnevma-git/src/service.rs`) creates proper git worktrees with branch leases, enforcing the invariant that one task = one branch = one worktree. This means tasks can run concurrently on the same repository without merge conflicts, and completed work is a clean branch ready for PR/merge. The merge queue (`pnevma-git`) serializes merges to prevent conflicts.

Symphony clones the entire repository into a flat directory per issue. There's no branch isolation, no merge queue, and no way for two issues working on the same codebase to avoid stepping on each other. The `after_create` hook does a `git clone --depth 1` — a shallow, disconnected copy.

**Files**: `pnevma-git/src/service.rs`, `pnevma-git/src/lease.rs`

### 4.4 Context Pack Compilation

Pnevma's `ContextCompiler` (`pnevma-context/src/compiler.rs`) builds a structured context pack for each task: task contract, project brief, architecture notes, conventions, rules, relevant file contents (discovered via scope + grep), and prior task summaries — all within a configurable token budget and with secret redaction applied.

Symphony renders a Liquid template with issue fields. There's no file discovery, no architecture context injection, no token budgeting, and no prior-task summarization.

**Files**: `pnevma-context/src/compiler.rs`, `pnevma-context/src/discovery.rs`

### 4.5 Full Secret Redaction Pipeline

Pnevma has a comprehensive redaction system (`pnevma-redaction/src/lib.rs`) that covers pattern-based detection (AWS keys, GitHub tokens, Slack tokens, PEM keys, connection strings, API key assignments, Bearer tokens) plus custom secrets. The `StreamRedactionBuffer` handles secrets split across chunk boundaries — a non-trivial problem when streaming PTY output. Redaction is applied to scrollback files, event payloads, context packs, and review artifacts.

Symphony handles secrets only at the config level (`$VAR` indirection). Agent output, scrollback, and logs are not redacted. A leaked secret in agent output would be visible in logs and any status surface.

**Files**: `pnevma-redaction/src/lib.rs`, `pnevma-session/src/supervisor.rs` (StreamRedactor usage)

### 4.6 Persistent Event Store

Pnevma's `EventStore` with 40+ typed events (`pnevma-core/src/events.rs`) provides a queryable timeline of everything that happened: session spawns/exits, task transitions, agent output/tool use/errors, worktree operations, merge operations, reviews, and workflow stage completions. This enables audit trails, debugging, analytics, and replay.

Symphony has no event store. Observability is structured logging only — useful for tailing but not for querying historical patterns or building dashboards from past data.

**Files**: `pnevma-core/src/events.rs`, `pnevma-db/src/store.rs`

### 4.7 Protected Actions with Risk Levels

Pnevma's `protected_actions.rs` classifies destructive operations into risk levels (Safe/Caution/Danger) with required confirmation phrases for Danger actions (e.g., "merge to target", "delete worktree", "force push"). This prevents accidental destructive operations in a multi-agent environment where mistakes are amplified.

Symphony has no equivalent — all orchestrator actions (workspace cleanup, agent termination) are automatic and unprotected.

**Files**: `pnevma-core/src/protected_actions.rs`

### 4.8 Workflow DAG with Loops and Failure Policies

Pnevma's `WorkflowDef` (`pnevma-core/src/workflow.rs`) supports multi-step workflows with DAG dependencies (`depends_on`), per-step failure policies (`Pause`/`RetryOnce`/`Skip`), loop configurations with configurable max iterations, and two loop modes (`OnFailure` for retry loops, `UntilComplete` for iterative processing). Workflow validation includes cycle detection, forward-reference rejection, and bounds checking.

Symphony has no workflow concept — it's one issue = one agent run. Multi-step processes must be encoded in the prompt or managed externally.

**Files**: `pnevma-core/src/workflow.rs`, `pnevma-commands/src/commands/workflow.rs`

### 4.9 Remote Access and Multi-Machine Operation

Pnevma's `pnevma-remote` crate provides an HTTP/WebSocket server with self-signed TLS, token-based auth (with revocation), rate limiting, CORS, and Tailscale guard rails. Combined with SSH support (`pnevma-ssh`), this enables controlling Pnevma instances across machines — e.g., a headless Mac Mini running agents, controlled from a MacBook.

Symphony is a single-machine process with no remote access story beyond the optional observability HTTP server.

**Files**: `pnevma-remote/src/server.rs`, `pnevma-ssh/src/`, `pnevma-remote/src/middleware/`

### 4.10 Story Detection in Agent Output

Pnevma's `StoryDetector` (`pnevma-core/src/stories.rs`) parses agent output for progress patterns ("Processing file 3 of 8", "[3/8] Linting", "Step 2/5: Running tests") and extracts structured progress data (current/total/title). This feeds into a UI progress indicator.

Symphony has no equivalent — progress is inferred from turn counts and codex event types.

**Files**: `pnevma-core/src/stories.rs`

---

## 5. Recommended Adoption Plan

### Phase 0: Prerequisites (no Symphony code needed)

1. **Config hot-reload** — Add a file-watcher for `pnevma.toml` and workflow YAML files. Re-parse and swap config in `AppState` with last-known-good fallback. This is a prerequisite for several later adoptions.
   - **Files to modify**: `pnevma-commands/src/state.rs`, `pnevma-core/src/config.rs`
   - **Impact**: High (enables iterative config tuning without restart)
   - **Effort**: Low

2. **Workspace lifecycle hooks** — Add `after_create`, `before_run`, `after_run`, `before_remove` hook points with timeout enforcement.
   - **Files to modify**: `pnevma-git/src/service.rs`, `pnevma-core/src/config.rs`
   - **Impact**: High (makes Pnevma composable with any project setup)
   - **Effort**: Low

### Phase 1: Retry and Resilience (port from Symphony)

3. **Exponential backoff retry** — Replace `FailurePolicy::RetryOnce` with proper exponential backoff (`10s × 2^n`, configurable cap). Add continuation retry semantics (1s delay after normal exit for re-check).
   - **Source reference**: `orchestrator.ex` `schedule_issue_retry/4`, `retry_delay/2`
   - **Files to modify**: `pnevma-commands/src/auto_dispatch.rs`, `pnevma-core/src/workflow.rs`
   - **Impact**: High (prevents infinite retry storms and enables graceful recovery)
   - **Effort**: Low-Medium

4. **Per-tick config validation** — Validate config before each auto-dispatch cycle. On failure, skip dispatch but keep running tasks alive.
   - **Source reference**: `orchestrator.ex` `maybe_dispatch/1` → `Config.validate!/0`
   - **Files to modify**: `pnevma-commands/src/auto_dispatch.rs`
   - **Impact**: Medium (prevents dispatch into broken configs)
   - **Effort**: Low

5. **Symlink traversal guard** — Add `lstat`-based path component checking to worktree validation.
   - **Source reference**: `workspace.ex` `ensure_no_symlink_components/2`
   - **Files to modify**: `pnevma-git/src/service.rs`
   - **Impact**: Medium (closes a real security gap)
   - **Effort**: Low

### Phase 2: Multi-Turn and External Work Sources

6. **Multi-turn agent sessions** — Extend `AgentAdapter` with a `continue_turn` method. Keep the subprocess alive between turns. Add `max_turns` config. Send continuation guidance instead of full prompt on subsequent turns.
   - **Source reference**: `agent_runner.ex` `do_run_codex_turns/7`, `build_turn_prompt/4`
   - **Files to modify**: `pnevma-agents/src/model.rs`, `pnevma-agents/src/adapters/`, `pnevma-commands/src/commands/agents.rs`
   - **Impact**: High (reduces token waste, enables long-running iterative tasks)
   - **Effort**: Medium

7. **External tracker adapter** — New `pnevma-tracker` crate with a `TrackerAdapter` trait (`fetch_candidates`, `fetch_states`, `fetch_terminal`). Initial Linear implementation. Map external issues to `TaskContract` creation.
   - **Source reference**: `tracker.ex`, `linear/` modules, SPEC.md §11
   - **Files to modify**: New crate + `pnevma-commands/src/auto_dispatch.rs`
   - **Impact**: High (enables team workflow integration)
   - **Effort**: Medium

8. **Per-state/per-priority concurrency limits** — Extend dispatch pool to track active counts by priority. Add `max_concurrent_by_priority` config.
   - **Source reference**: `orchestrator.ex` `state_slots_available?/2`, `running_issue_count_for_state/2`
   - **Files to modify**: `pnevma-agents/src/pool.rs`, `pnevma-core/src/config.rs`
   - **Impact**: Medium (smarter resource allocation)
   - **Effort**: Low

### Phase 3: Observability and Reconciliation

9. **Active task reconciliation** — Add a periodic reconciliation loop that re-checks running tasks against external state (tracker states, worktree validity, agent health). Terminate tasks whose external state has become terminal or invalid.
   - **Source reference**: `orchestrator.ex` `reconcile_running_issues/1`, `reconcile_issue_state/4`
   - **Files to modify**: `pnevma-commands/src/auto_dispatch.rs`, new reconciliation module
   - **Impact**: High (prevents stale task waste)
   - **Effort**: Medium

10. **Observability JSON API** — Add `/api/v1/state`, `/api/v1/task/:id`, and `POST /api/v1/refresh` routes to `pnevma-remote`.
    - **Source reference**: SPEC.md §13.7, `symphony_elixir_web/controllers/`
    - **Files to modify**: `pnevma-remote/src/routes/`
    - **Impact**: Medium (enables external monitoring and CI integration)
    - **Effort**: Low

### Priority Summary

| Priority | Item | Impact | Effort |
|---|---|---|---|
| P0 | Config hot-reload | High | Low |
| P0 | Workspace lifecycle hooks | High | Low |
| P0 | Exponential backoff retry | High | Low-Medium |
| P1 | Per-tick config validation | Medium | Low |
| P1 | Symlink traversal guard | Medium | Low |
| P1 | Multi-turn agent sessions | High | Medium |
| P1 | Per-priority concurrency limits | Medium | Low |
| P2 | External tracker adapter | High | Medium |
| P2 | Active task reconciliation | High | Medium |
| P2 | Observability JSON API | Medium | Low |

---

## Appendix: Key File References

### Pnevma
- Orchestration: `crates/pnevma-core/src/orchestration.rs`
- Task model: `crates/pnevma-core/src/task.rs`
- Workflow DAG: `crates/pnevma-core/src/workflow.rs`
- Agent adapters: `crates/pnevma-agents/src/model.rs`
- Dispatch pool: `crates/pnevma-agents/src/pool.rs`
- Auto-dispatch: `crates/pnevma-commands/src/auto_dispatch.rs`
- Session supervisor: `crates/pnevma-session/src/supervisor.rs`
- Git worktrees: `crates/pnevma-git/src/service.rs`
- Context compiler: `crates/pnevma-context/src/compiler.rs`
- Event store: `crates/pnevma-core/src/events.rs`
- Secret redaction: `crates/pnevma-redaction/src/lib.rs`
- Remote server: `crates/pnevma-remote/src/server.rs`
- Protected actions: `crates/pnevma-core/src/protected_actions.rs`
- Config: `pnevma.toml`, `crates/pnevma-core/src/config.rs`

### Symphony
- Spec: `SPEC.md` (2111 lines, language-agnostic)
- Orchestrator: `elixir/lib/symphony_elixir/orchestrator.ex` (1457 lines)
- Agent runner: `elixir/lib/symphony_elixir/agent_runner.ex`
- Codex client: `elixir/lib/symphony_elixir/codex/app_server.ex`
- Workspace: `elixir/lib/symphony_elixir/workspace.ex`
- Workflow loader: `elixir/lib/symphony_elixir/workflow.ex`
- Workflow hot-reload: `elixir/lib/symphony_elixir/workflow_store.ex`
- Config: `elixir/lib/symphony_elixir/config.ex`
- Tracker: `elixir/lib/symphony_elixir/tracker.ex`, `elixir/lib/symphony_elixir/linear/`
- HTTP server: `elixir/lib/symphony_elixir/http_server.ex`
- Dashboard: `elixir/lib/symphony_elixir/status_dashboard.ex`
- Prompt builder: `elixir/lib/symphony_elixir/prompt_builder.ex`
- Workflow example: `elixir/WORKFLOW.md`
