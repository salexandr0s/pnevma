# Pnevma × Symphony: Implementation Plan

## Preface

This plan was produced after reading both comparison documents (`symphony-comparison-claude.md` and `symphony-comparison-codex.md`), the existing Codex implementation plan (`upgrade-implementation-plan-codex.md`), and the actual Pnevma source code — specifically `auto_dispatch.rs`, `orchestration.rs`, `pool.rs`, `state.rs`, `config.rs`, `task.rs`, `workflow.rs`, `model.rs`, `service.rs`, `supervisor.rs`, and `adapters/codex.rs`.

Symphony's SPEC.md is not available on this machine. Claims about Symphony are evaluated based on what both comparison documents agree on, cross-referenced against their cited line numbers and module names.

---

## 1. Disagreements Resolved

### 1.1 Start with coordinator vs start with config hot-reload

- **Claude doc**: Start with config hot-reload and workspace hooks (Phase 0), treat them as prerequisites.
- **Codex doc**: Start with `AutomationCoordinator` — everything else depends on having a single runtime owner.
- **Verdict: Codex is right.**

The actual `auto_dispatch.rs` is a 102-line polling loop that reads `state.current` config, lists `Ready` tasks, and dispatches up to `available_slots`. It has no claim tracking, no retry state, no reconciliation, no snapshot. Hot-reloading config into this loop just makes a thin loop more dynamic — it doesn't fix the architectural gap. The coordinator must come first because retry, reconciliation, tracker integration, and observability snapshots all need a single owner. Hot-reload becomes trivial once the coordinator exists (it already needs a config source).

### 1.2 Multi-turn via trait extension vs replace Codex adapter first

- **Claude doc**: Extend `AgentAdapter` with a `continue_turn` method, keep the existing subprocess model.
- **Codex doc**: Replace the Codex adapter with an app-server-backed implementation before adding continuation.
- **Verdict: Codex is right.**

The actual `CodexAdapter::send` (`adapters/codex.rs:52-262`) spawns a bare `codex` binary, writes a prompt to stdin, closes stdin, then regex-parses `(?i)(tokens|input_tokens|usage)[^0-9]*(\d+)` from stdout/stderr for cost tracking. This is fundamentally incompatible with multi-turn — there is no session identity, no structured event stream, no way to send a follow-up message to the same thread. Adding `continue_turn` to the trait while the underlying transport is "write to stdin, close, regex stdout" would be theater.

### 1.3 New observability API vs extend existing surfaces

- **Claude doc**: Add new `/api/v1/state` and `/api/v1/task/:id` routes to `pnevma-remote`.
- **Codex doc**: Expose one canonical automation snapshot through existing UI/API surfaces.
- **Verdict: Codex is right, but the reasoning matters.**

The gap is not "Pnevma has no HTTP server." `pnevma-remote` already has Axum routes with TLS, auth, and rate limiting. The gap is that there is no single automation-state object to serialize. Building new routes before the coordinator exists means inventing a schema with no backing data. Build the coordinator snapshot first; the route is an afternoon of work after that.

### 1.4 Per-priority vs per-state concurrency limits

- **Claude doc**: Add `max_concurrent_by_priority` keyed on Pnevma's `P0`-`P3` priorities.
- **Codex doc**: Implies Symphony's state-based gating is the right concept.
- **Verdict: Neither is right yet.**

Symphony's per-state caps exist because different tracker states (e.g., `Todo` vs `In Progress` vs `Rework`) represent qualitatively different work with different resource needs. Pnevma's `P0`-`P3` is a urgency signal, not a work-type signal. Capping concurrency by urgency is backwards — you'd want P0 to have *more* slots, not fewer. Per-state limits only become meaningful after tracker integration introduces external work states. This should wait.

### 1.5 Hooks in `pnevma.toml` vs repo-owned `WORKFLOW.md`

- **Claude doc**: Put hooks under `[hooks]` in `pnevma.toml`.
- **Codex doc**: Adopt repo-owned `WORKFLOW.md` for automation policy including hooks.
- **Verdict: Split responsibilities. Neither doc got this exactly right.**

`pnevma.toml` is the right home for Pnevma application config (UI prefs, remote server settings, retention policy, branch conventions). Automation behavior that is specific to the *repo being automated* — hooks, active states, prompt template, concurrency caps for automation mode, retry policy — belongs in a repo-owned file like `WORKFLOW.md`. Mixing both in `pnevma.toml` means automation config isn't portable across machines or reviewable in PRs. But putting application config in `WORKFLOW.md` pollutes a repo-level contract with app-level concerns.

### 1.6 Reconciliation as a late-stage feature vs prerequisite

- **Claude doc**: Puts reconciliation in Phase 3 (item 9 of 10).
- **Codex doc**: Makes reconciliation part of the coordinator's core responsibilities from the start (item 7 of 9, but described as a coordinator responsibility at item 0).
- **Verdict: Codex is closer. Reconciliation is a coordinator concern, not a bolt-on.**

Without reconciliation, any coordinator is just a fancier version of the current `auto_dispatch.rs`. The point of a single runtime owner is that it can compare "what I think is running" against "what is actually happening" and act. Design the coordinator with reconciliation from day one, even if the initial reconciliation is simple (session alive? worktree valid? task still in-progress?). Don't defer it to Phase 3.

---

## 2. Prioritized Implementation List

### Item 1: Build `AutomationCoordinator` with built-in reconciliation

**What**: A single Tokio task that owns the canonical set of claimed tasks, running sessions, retry queue, and automation runtime snapshot. Replaces `auto_dispatch.rs` for automation-mode dispatch. Runs a reconciliation check every tick: verify running sessions are alive, verify tasks are still in dispatchable states, clean up orphans.

**Why Pnevma needs this**: Today, automation state is fragmented across four locations:
- `DispatchOrchestrator` (`orchestration.rs`) — a priority queue with an active counter, not wired into `AppState` (appears to be dead code)
- `DispatchPool` (`pool.rs`) — the actual concurrency limiter in `AppState`, but it only tracks permits, not what tasks hold them
- `auto_dispatch.rs` — a 102-line loop with no memory between cycles
- `AppState.current` (`state.rs`) — holds the `ProjectContext` behind a single `Mutex`

No component knows "task X is running in session Y with worktree Z and has been retried twice." Every downstream feature (retry, reconciliation, tracker, snapshot) requires this foundation.

**Surfaced by**: Codex doc (item 0); confirmed as the right call after reading the actual code.

**Affected files**:
- `crates/pnevma-commands/src/auto_dispatch.rs` — replaced or gutted
- `crates/pnevma-commands/src/state.rs` — `ProjectContext` gains a reference to the coordinator
- `crates/pnevma-agents/src/pool.rs` — coordinator subsumes its scheduling role; `DispatchPool` may become an internal detail
- `crates/pnevma-core/src/orchestration.rs` — likely removable (it's a parallel implementation not wired into `AppState`)
- `crates/pnevma-session/src/supervisor.rs` — coordinator queries session health for reconciliation

**Dependencies**: None. This is the foundation.

**Effort**: L

**Risk if skipped**: Every subsequent item becomes ad-hoc glue bolted onto a 102-line polling loop. Retry logic will race with dispatch. Reconciliation will have no canonical state to reconcile against. The observability snapshot will be a best-effort aggregation rather than a direct serialization of truth.

---

### Item 2: Repo-owned `WORKFLOW.md` with hot-reload

**What**: Define a `WORKFLOW.md` format (YAML front matter + prompt template body) that lives in the automated repo. Parse it into a typed `AutomationConfig` struct. Hot-reload via mtime + content hash polling (1-5s interval) with last-known-good fallback on parse/validation failure.

**Why Pnevma needs this**: `pnevma.toml` is loaded once at project open (`config.rs:539`, `state.rs:23-34`) and frozen in `ProjectContext.config`. Changing `max_concurrent`, `auto_dispatch_interval_seconds`, or agent model requires closing and reopening the project. More importantly, automation behavior should be defined by the repo being automated — not by per-machine application config. A `WORKFLOW.md` checked into the repo makes automation policy reviewable, portable, and branch-specific.

**Surfaced by**: Both docs. The split between `pnevma.toml` (app config) and `WORKFLOW.md` (automation contract) is my addition.

**Affected files**:
- `crates/pnevma-core/src/config.rs` — new `AutomationConfig` type, parser, validator
- `crates/pnevma-commands/src/state.rs` — coordinator consumes `AutomationConfig`
- New file in `pnevma-core` or `pnevma-commands` for the hot-reload watcher

**Dependencies**: Coordinator (item 1) should consume this config, but parsing/validation can be built in parallel.

**Effort**: M

**Risk if skipped**: Automation config stays restart-bound, machine-local, and invisible in code review.

---

### Item 3: Replace Codex CLI adapter with app-server-backed adapter

**What**: Replace the current `CodexAdapter` (`adapters/codex.rs`) with one that talks to Codex in app-server mode via structured JSON-RPC over stdio. Preserve session identity (`thread_id`, `turn_id`), receive structured events (tool calls, token usage, rate limits), and support persistent sessions for multi-turn continuation.

**Why Pnevma needs this**: The current adapter spawns a bare `codex` binary, writes the prompt to stdin, closes stdin, and regex-parses stdout for token counts (`(?i)(tokens|input_tokens|usage)[^0-9]*(\d+)`). This is the weakest operational seam in Pnevma. It cannot support multi-turn sessions, provides no structured observability, has no rate-limit awareness, and produces unreliable cost data. Both comparison docs identify this as the single biggest "same feature, better implementation" gap.

**Surfaced by**: Codex doc (item 2); Claude doc (§3.2 "Codex integration is much more robust"); my own reading of `adapters/codex.rs` confirms.

**Affected files**:
- `crates/pnevma-agents/src/adapters/codex.rs` — rewrite
- `crates/pnevma-agents/src/model.rs` — extend `AgentAdapter` trait with session persistence support (e.g., `continue_turn` or a `SessionMode` enum)
- `crates/pnevma-agents/src/registry.rs` — register the new adapter

**Dependencies**: Items 1-2. The coordinator needs to own session state, and the `WORKFLOW.md` contract should specify sandbox/approval policy passed to the app-server.

**Effort**: L

**Risk if skipped**: Multi-turn continuation (item 4) is impossible. Token/cost tracking remains regex guesswork. Stall detection stays PTY-based rather than semantic-event-based. Unattended Codex runs remain fragile.

---

### Item 4: Coordinator-owned retry, backoff, stall recovery, and continuation

**What**: Implement three retry modes in the coordinator:
1. **Continuation retry** — after normal agent exit, 1s delay, re-check task eligibility, re-dispatch with continuation context if still active
2. **Failure retry** — exponential backoff (`10s × 2^(attempt-1)`, configurable cap), re-validate config and task state before re-dispatch
3. **Stall recovery** — detect agents that haven't produced a semantic event within a configurable timeout, kill and re-queue with backoff

Persist retry metadata (attempt count, last error, next due time) in SQLite so it survives restarts and is visible in UI/API.

**Why Pnevma needs this**: `TaskContract` has `max_retries: Option<i64>` and `loop_iteration`/`loop_context_json` fields (`task.rs:65-90`), and `WorkflowStep` has `on_failure: FailurePolicy` with `RetryOnce` variant (`workflow.rs:10-15`). But nothing in the runtime reads these fields to actually retry. The `auto_dispatch.rs` loop has no retry state — a failed task stays failed until manually re-queued. This is the gap between "data model supports retries" and "runtime actually retries."

**Surfaced by**: Both docs. Claude doc (§2.6); Codex doc (§3.5, items 3-4).

**Affected files**:
- Coordinator module (from item 1)
- `crates/pnevma-core/src/task.rs` — need `FailurePolicy` to actually drive behavior
- `crates/pnevma-core/src/workflow.rs` — reconcile `FailurePolicy` vs `max_retries` semantics
- `crates/pnevma-db/src/store.rs` — persist retry metadata

**Dependencies**: Items 1 and 3. The coordinator owns the retry queue; the app-server adapter provides semantic event timestamps for stall detection.

**Effort**: M

**Risk if skipped**: Pnevma remains an "opportunistic dispatcher" — it fires tasks and hopes they work. Transient failures (rate limits, network blips, stalls) require manual intervention.

---

### Item 5: Workspace lifecycle hooks with symlink hardening

**What**: Add four hook points to the worktree lifecycle — `after_create`, `before_run`, `after_run`, `before_remove` — defined as shell commands in `WORKFLOW.md` with a configurable timeout (default 60s). `after_create` and `before_run` failures abort the dispatch attempt. `after_run` and `before_remove` failures log and continue. Also add `lstat`-based symlink-component validation to `GitService.create_worktree` and `cleanup_worktree`.

**Why Pnevma needs this**: `GitService` (`service.rs`) creates worktrees and manages branches but has no user-extensible setup or teardown. Repos that need `npm install`, environment file creation, database seeding, or custom cleanup after agent runs have no hook point. The symlink gap is real: `cleanup_persisted_worktree` (`service.rs:115`) validates canonical paths but doesn't walk individual path components with `lstat` to catch symlink escapes planted by an agent within the worktree.

**Surfaced by**: Both docs. Claude doc (§2.3, §3.3); Codex doc (§3.4, item 4).

**Affected files**:
- `crates/pnevma-git/src/service.rs` — hook execution at create/remove; symlink validation
- `crates/pnevma-core/src/config.rs` — hook config schema (or `WORKFLOW.md` automation config)
- Coordinator module — hook execution at before_run/after_run dispatch points

**Dependencies**: Item 2 (hooks belong in `WORKFLOW.md`). Can be built in parallel with items 3-4.

**Effort**: M

**Risk if skipped**: Every repo that needs custom setup requires manual pre-configuration or wrapper scripts. The symlink escape surface stays open — low probability but high severity in unattended mode where an agent could craft a malicious worktree path.

---

### Item 6: Tracker abstraction with Linear adapter

**What**: New `pnevma-tracker` crate with a `TrackerAdapter` trait (`fetch_candidates`, `fetch_states`, `update_state`). First implementation: Linear GraphQL. External issues materialize as standard Pnevma `TaskContract`s with persisted source metadata (tracker kind, external ID, external URL), so all existing review/merge/history/UI flows work unchanged.

**Why Pnevma needs this**: Pnevma's work source is entirely local — tasks are created manually or from YAML workflow files. For team adoption, Pnevma needs to pull work from where teams already plan it. The decision to materialize external issues into normal `TaskContract`s (rather than a parallel model) preserves Pnevma's strongest advantage: its durable DB/event model with full audit trail.

**Surfaced by**: Both docs. Claude doc (§2.1); Codex doc (item 5).

**Affected files**:
- New `crates/pnevma-tracker/` crate
- `crates/pnevma-core/src/task.rs` — add optional external source metadata to `TaskContract`
- `crates/pnevma-db/src/store.rs` — persist tracker metadata
- Coordinator module — tracker polling as a dispatch source

**Dependencies**: Items 1, 2, and 4. The coordinator must exist to own tracker polling. Retry/reconciliation should be working before running unattended tracker-driven automation.

**Effort**: L

**Risk if skipped**: Pnevma stays a local task board with auto-dispatch. Team adoption requires duplicate work entry.

---

### Item 7: Per-tick config validation

**What**: Before each coordinator dispatch cycle, run `validate_project_config` (or a lighter automation-specific validator). On failure, skip dispatch but continue reconciliation and monitoring. Log the validation error clearly.

**Why Pnevma needs this**: Config is validated once at project open (`config.rs:539`). In a long-running automation session, credentials expire, endpoints change, or a hot-reloaded `WORKFLOW.md` could introduce invalid values. If validation only happens at load time, the coordinator dispatches into a broken config, agents fail, and retries burn through the backoff budget before anyone notices.

**Surfaced by**: Claude doc (§3.2 "Config Validation Before Dispatch"). My addition to elevate it from a footnote to a concrete item.

**Affected files**:
- Coordinator module — validation gate before dispatch
- `crates/pnevma-core/src/config.rs` — ensure `validate_project_config` is callable independently of load

**Dependencies**: Items 1 and 2.

**Effort**: S

**Risk if skipped**: Stale or broken config causes silent dispatch failures that are only visible in logs. Agents waste cycles on doomed runs.

---

### Item 8: Automation snapshot for UI and remote API

**What**: The coordinator exposes a `snapshot()` method returning a serializable struct: running tasks (with session ID, worktree path, start time, turn count), retry queue (with attempt count, next due time, last error), aggregate token/cost totals, and coordinator health. Expose this through existing `pnevma-remote` routes and native UI surfaces.

**Why Pnevma needs this**: Pnevma has rich surfaces (native panes, remote API/WS, DB-backed history) but no single automation-truth object. Debugging automation currently means correlating DB rows, session events, and pool state across multiple queries. A coordinator snapshot is the single source of "what is the automation system doing right now."

**Surfaced by**: Codex doc (item 7); Claude doc (§2.7). Both identify the gap; Codex correctly identifies that the fix is a coordinator snapshot, not new routes.

**Affected files**:
- Coordinator module — `snapshot()` method
- `crates/pnevma-remote/src/routes/` — new JSON endpoint serving the snapshot
- `crates/pnevma-commands/src/commands/project.rs` — extend `project.status` with automation snapshot

**Dependencies**: Item 1.

**Effort**: M

**Risk if skipped**: Operators debug automation by tailing logs and querying SQLite manually. CI integration and external monitoring tools have no structured access to automation state.

---

### Item 9: Dynamic automation tools for agents

**What**: A tool-provider layer in the coordinator that injects orchestrator-owned capabilities into agent sessions as structured tools (not prompt text). First tool: tracker query/update (e.g., `linear_graphql` or a Pnevma-specific `tracker.query`/`tracker.update`).

**Why Pnevma needs this**: Once tracker-driven automation exists (item 6), agents need to read and update tracker state. Without structured tools, this has to be hacked into the prompt ("use the Linear CLI to...") or the agent needs direct API credentials. Orchestrator-owned tools are safer (scoped permissions), more reliable (no prompt fragility), and auditable (tool calls appear in the event stream).

**Surfaced by**: Codex doc (item 6); Symphony's `dynamic_tool.ex` pattern.

**Affected files**:
- Codex app-server adapter (from item 3) — tool registration
- `crates/pnevma-tracker/` — exposes query/update functions
- Coordinator module — tool provider lifecycle

**Dependencies**: Items 3 and 6.

**Effort**: M

**Risk if skipped**: Tracker-aware agents rely on fragile prompt hacks or direct API key exposure.

---

### Item 10: Clean up dead orchestration code

**What**: Remove or clearly deprecate `DispatchOrchestrator` in `crates/pnevma-core/src/orchestration.rs`. It is a 210-line parallel implementation of `DispatchPool` (`pool.rs`) that is not wired into `AppState` and appears to be dead code. Its tests pass, but it serves no production purpose.

**Why Pnevma needs this**: Two implementations of the same priority-queue-with-concurrency-limit concept creates maintenance confusion. When building the coordinator (item 1), developers will find two nearly identical modules and won't know which to use. The `DispatchOrchestrator` also lacks the RAII permit and queue depth limit that `DispatchPool` has, making it the strictly inferior version.

**Surfaced by**: My own codebase reading. Neither comparison doc flagged this.

**Affected files**:
- `crates/pnevma-core/src/orchestration.rs` — remove or deprecate
- `crates/pnevma-core/src/lib.rs` — remove re-export if present

**Dependencies**: None. Can be done immediately.

**Effort**: S

**Risk if skipped**: Low severity but ongoing confusion. A new contributor will spend time understanding two modules that do the same thing.

---

## 3. Explicitly Rejected Ideas

### 3.1 Port Symphony's no-DB design

Both docs correctly reject this. Pnevma's SQLite persistence (`pnevma-db` with 18 row types) and append-only event log (40+ event types in `events.rs`) are competitive advantages, not accidental complexity. Symphony's in-memory-only approach works for a stateless daemon that recovers from the tracker; it would be a regression for Pnevma's audit trail, crash recovery, and cross-surface consistency.

### 3.2 Replace git worktrees with generic filesystem directories

Pnevma's one-task-one-branch-one-worktree invariant is architecturally superior to Symphony's "clone into a directory" approach. Git worktrees give you branch isolation, atomic merge via the merge queue, and clean PR-ready output. Symphony's `git clone --depth 1` produces disconnected copies with no merge story. Keep Pnevma's model; add hooks and symlink validation to it.

### 3.3 Add per-priority concurrency limits now

Symphony's per-state caps are valuable because tracker states represent qualitatively different work. Pnevma's `P0`-`P3` priorities are an urgency axis, not a work-type axis. Adding `max_concurrent_by_priority` would let you cap P3 tasks, but that's the wrong lever — you want P0 to *always* get a slot, which is already what the priority queue does. Wait for tracker states (item 6) before building state-aware concurrency caps.

### 3.4 Add a separate observability HTTP server or dashboard product

Pnevma already has `pnevma-remote` with authenticated routes, TLS, and WebSocket support. Building a parallel Phoenix-style status dashboard would create two control surfaces to maintain. The right approach is the coordinator snapshot (item 8) exposed through existing infrastructure.

### 3.5 Collapse human review into prompt text

Symphony treats ticket updates and PR behavior as prompt concerns because it's an unattended daemon. Pnevma has explicit review approval/rejection, merge queue serialization, and protected actions with confirmation phrases (`protected_actions.rs`). These are product features that exist for good reasons — multi-agent environments amplify mistakes. Don't regress to "the prompt tells the agent when to merge."

### 3.6 Make `DispatchOrchestrator` the coordinator

It might seem natural to evolve `DispatchOrchestrator` (`orchestration.rs`) into the coordinator. Don't. It's a simpler, less capable version of `DispatchPool` — no RAII permits, no queue depth limit, no `Notify`-based wakeup. Start the coordinator fresh with `DispatchPool` as an internal scheduling primitive, or inline its logic.

### 3.7 Hot-reload `pnevma.toml` for automation config

The Claude doc suggests hot-reloading `pnevma.toml`. This conflates two concerns. `pnevma.toml` should remain the static application config (loaded at project open, restart to change). Automation-specific config that needs hot-reload should live in `WORKFLOW.md`. Hot-reloading application config (UI preferences, remote server settings, retention policy) creates subtle state inconsistencies and is not worth the complexity.

### 3.8 Multi-turn continuation on the current Codex subprocess adapter

The Claude doc proposes extending `AgentAdapter` with `continue_turn` as item 6. This is the right *trait change* but on the wrong *adapter*. The current Codex adapter closes stdin after writing the prompt and exits — there is no subprocess to continue. The app-server adapter (item 3) must land first. Adding `continue_turn` to the trait without the transport is misleading API design.

---

## 4. Architecture Prerequisites

### 4.1 Resolve the dual-orchestrator confusion

`DispatchOrchestrator` (`pnevma-core/src/orchestration.rs`) and `DispatchPool` (`pnevma-agents/src/pool.rs`) are parallel implementations. Only `DispatchPool` is wired into `AppState`. Before building the coordinator, either remove `DispatchOrchestrator` or clearly mark it as deprecated test infrastructure. This is item 10 and should be done first — it's a 30-minute cleanup that prevents days of confusion.

### 4.2 Define the `TaskContract` ↔ external issue mapping

Before the tracker adapter (item 6), decide: do external issues create normal `TaskContract`s with an `external_source: Option<ExternalSource>` field, or do they get a parallel model? The right answer is the former — Pnevma's review, merge, history, and UI flows all operate on `TaskContract`. A parallel model would fork every downstream consumer. Add `external_source` (tracker kind + external ID + URL) to `TaskContract` and the DB schema early so the coordinator can treat all tasks uniformly.

### 4.3 Fix `refresh_blocked_status` bypassing the state machine

`TaskContract::refresh_blocked_status` (`task.rs:139-148`) directly writes `self.status = TaskStatus::Blocked` without going through `transition()`. This means it can set an `InProgress` task to `Blocked` — a transition that `transition()` would reject. Before the coordinator relies on the state machine for reconciliation and retry decisions, this must be fixed. Either add `InProgress→Blocked` as a legal transition or make `refresh_blocked_status` respect the guard.

### 4.4 Resolve bare `git` binary PATH issue

`GitService::git` (`service.rs:169`) calls bare `"git"` without path resolution. `SessionSupervisor` already has `resolve_binary` (`supervisor.rs:83`) that searches `/opt/homebrew/bin`, `/usr/local/bin`, etc. The same pattern needs to apply to git — GUI apps launched from Finder don't have Homebrew on PATH. This is the same class of bug already fixed for `tmux` and `script` (documented in project memory).

---

## Dependency Graph

```
Item 10 (cleanup dead code)          — no deps, do first
Item 1  (coordinator)                — no deps
Item 2  (WORKFLOW.md)                — no deps, parallel with 1
Item 7  (per-tick validation)        — depends on 1, 2
Item 3  (Codex app-server adapter)   — depends on 1, 2
Item 5  (hooks + symlink hardening)  — depends on 2, parallel with 3
Item 4  (retry/backoff/stall)        — depends on 1, 3
Item 8  (automation snapshot)        — depends on 1
Item 6  (tracker adapter)            — depends on 1, 2, 4
Item 9  (dynamic tools)              — depends on 3, 6
```

## Summary Table

| # | Item | Impact | Effort | Source |
|---|------|--------|--------|--------|
| 1 | AutomationCoordinator with reconciliation | Critical | L | Codex doc |
| 2 | WORKFLOW.md with hot-reload | High | M | Both docs + own judgment |
| 3 | Codex app-server adapter | High | L | Both docs |
| 4 | Retry, backoff, stall recovery, continuation | High | M | Both docs |
| 5 | Workspace hooks + symlink hardening | Medium | M | Both docs |
| 6 | Tracker abstraction + Linear adapter | High | L | Both docs |
| 7 | Per-tick config validation | Medium | S | Claude doc |
| 8 | Automation snapshot | Medium | M | Both docs |
| 9 | Dynamic automation tools | Medium | M | Codex doc |
| 10 | Clean up dead orchestration code | Low | S | Own codebase reading |
