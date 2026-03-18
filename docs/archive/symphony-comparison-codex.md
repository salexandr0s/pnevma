# Comparative analysis: Pnevma vs OpenAI Symphony

## Scope reviewed

This comparison is based on the architectural docs and the implementation modules that actually carry orchestration behavior.

**Pnevma** reviewed:

- `README.md`
- `docs/architecture-overview.md`
- `docs/pnevma-toml-reference.md`
- `crates/pnevma-core/src/{task.rs, orchestration.rs, workflow.rs, protected_actions.rs}`
- `crates/pnevma-session/src/{model.rs, supervisor.rs}`
- `crates/pnevma-git/src/{service.rs, lease.rs}`
- `crates/pnevma-context/src/{compiler.rs, discovery.rs}`
- `crates/pnevma-agents/src/{model.rs, pool.rs, registry.rs, adapters/codex.rs}`
- `crates/pnevma-commands/src/{state.rs, auto_dispatch.rs, command_registry.rs}`
- `crates/pnevma-db/src/{store.rs, global_store.rs}`
- `crates/pnevma-remote/src/{server.rs, auth.rs, tls.rs}`

**Symphony** reviewed:

- `README.md`
- `SPEC.md`
- `elixir/README.md`
- `elixir/WORKFLOW.md`
- `elixir/lib/symphony_elixir/{orchestrator.ex, workspace.ex, agent_runner.ex, workflow.ex, workflow_store.ex, config.ex, tracker.ex, prompt_builder.ex, http_server.ex, status_dashboard.ex, log_file.ex}`
- `elixir/lib/symphony_elixir/linear/{adapter.ex, client.ex, issue.ex}`
- `elixir/lib/symphony_elixir/codex/{app_server.ex, dynamic_tool.ex}`

## Executive summary

These systems are solving adjacent but not identical problems.

**Symphony** is a **headless issue-execution daemon**. Its center of gravity is `elixir/lib/symphony_elixir/orchestrator.ex`: poll a tracker, reconcile live state against tracker truth, create deterministic per-issue workspaces, run Codex in app-server mode, and keep enough in-memory runtime state to retry, continue, or stop work cleanly.

**Pnevma** is a **terminal-first agent operating environment**. Its center of gravity is the combination of `crates/pnevma-session/src/supervisor.rs`, `crates/pnevma-git/src/service.rs`, `crates/pnevma-db/src/store.rs`, and `crates/pnevma-commands/src/state.rs`: persistent tmux-backed sessions, one-task-one-worktree isolation, durable SQLite-backed state, review/merge/safety workflows, and local/remote operator surfaces.

The short version:

- Symphony is **architecturally stronger as an unattended automation scheduler**.
- Pnevma is **architecturally stronger as a supervised multi-agent workbench**.
- The best path is **selective adaptation**, not wholesale replacement. In particular, Pnevma should adopt Symphony’s **workflow contract**, **unified coordinator/reconciliation model**, and **Codex app-server integration**, while keeping Pnevma’s **DB/event model**, **interactive sessions**, **review/merge queue**, and **safety controls**.

---

## 1. Architecture comparison

| Concern | Pnevma | Symphony | Assessment |
|---|---|---|---|
| **Primary orchestration locus** | Orchestration is split across `crates/pnevma-core/src/orchestration.rs::DispatchOrchestrator`, `crates/pnevma-agents/src/pool.rs::DispatchPool`, `crates/pnevma-commands/src/auto_dispatch.rs::run_cycle`, and `crates/pnevma-commands/src/state.rs::AppState/ProjectContext`. | Orchestration is centralized in `elixir/lib/symphony_elixir/orchestrator.ex`, with a single `State` struct owning `running`, `claimed`, `retry_attempts`, token totals, and poll timing. | Symphony has the cleaner scheduler boundary. Pnevma has the richer operator/runtime stack, but its automation logic is more fragmented. |
| **Work unit** | Internal durable task object: `crates/pnevma-core/src/task.rs::TaskContract`. It carries dependencies, acceptance checks, assigned session/worktree, prompt pack, retries, execution mode, loop metadata. | Normalized tracker issue: `elixir/lib/symphony_elixir/linear/issue.ex::Issue`, derived from Linear via `linear/client.ex`. | Pnevma has the richer internal domain model. Symphony has the stronger external-source-of-truth model. |
| **Source of truth for runtime state** | Rust is authoritative for app state (`docs/architecture-overview.md`), persisted to SQLite/event log/filesystem. Runtime details are also distributed across session supervisor, DB, and pool state. | The orchestrator’s in-memory `State` is authoritative for dispatch/retry/live-run status. `SPEC.md` explicitly makes “single authoritative orchestrator state” a goal and “no DB required” a design choice. | Symphony is more coherent for daemon scheduling; Pnevma is more durable and auditable. |
| **Persistence model** | Strong persistence: `crates/pnevma-db/src/store.rs` persists sessions, tasks, worktrees, reviews, merge queue, workflow instances, costs, and more. `docs/architecture-overview.md` also calls out append-only event log + filesystem artifacts. | Intentionally avoids a required persistent DB. Recovery is expected to come from tracker re-read + workspace inspection + runtime reconciliation (`SPEC.md`, `orchestrator.ex`). | Pnevma is far ahead on durability and forensic traceability. Symphony is lighter-weight operationally. |
| **Workspace isolation model** | Git worktree-centric isolation in `crates/pnevma-git/src/service.rs::GitService`. `create_worktree` reserves a lease before I/O, creates branch `pnevma/{task_id}/{slug}`, and stores a `WorktreeLease`. | Filesystem workspace-per-issue in `elixir/lib/symphony_elixir/workspace.ex`. Workspace path is derived from sanitized issue identifier; hooks (`after_create`, `before_run`, `after_run`, `before_remove`) govern lifecycle. | Pnevma is stronger at Git-native isolation and lease correctness. Symphony is stronger at automation-oriented workspace lifecycle policy. |
| **Workspace safety hardening** | Safety comes mostly from worktree scoping, merge serialization, remote auth/TLS, and redaction. Git cleanup validates canonical paths in `cleanup_persisted_worktree`. | `workspace.ex` adds explicit workspace-root enforcement and symlink-escape checks (`validate_workspace_path`, `ensure_no_symlink_components`) before create/remove. | Symphony is more opinionated about workspace path hardening; Pnevma should copy that. |
| **Agent lifecycle** | Generic adapter trait in `crates/pnevma-agents/src/model.rs::AgentAdapter`; registry auto-detects `claude` and `codex`. Terminal lifecycle is separate via `SessionSupervisor`. The current Codex adapter (`adapters/codex.rs`) is a plain CLI subprocess with stdout/stderr parsing. | `agent_runner.ex` + `codex/app_server.ex` implement a structured agent lifecycle: start app-server session, start turn, stream events, handle tool calls, track session/thread/turn IDs, continue turns while issue stays active. | Symphony’s Codex lifecycle is significantly more orchestration-grade. Pnevma’s abstraction is broader, but the Codex implementation is much thinner. |
| **Human supervision model** | First-class. Review, merge queue, pane system, checkpoints, protected actions, session replay, and reattach are core product features (`protected_actions.rs`, `command_registry.rs`, `session/supervisor.rs`). | Not the focus. `SPEC.md` positions Symphony as an unattended scheduler/runner; ticket writes are generally done by the agent itself. | Pnevma is much stronger for human-in-the-loop operations. |
| **Retry / recovery** | `TaskContract` models `max_retries`, loops, and execution metadata, but the visible runtime scheduler is mostly `auto_dispatch.rs`, which dispatches ready tasks opportunistically by pool capacity. | `orchestrator.ex` implements explicit retry queueing, continuation retry vs failure retry, exponential backoff, stalled-run restart, revalidation before dispatch, and stopping workers when tracker state changes. | Symphony is materially ahead here. |
| **State reconciliation** | Local task graph reconciliation exists (`TaskContract::refresh_blocked_status`), but there is no equivalent visible external reconciliation loop against an issue tracker. | Core design feature. `orchestrator.ex::reconcile_running_issues` and `reconcile_issue_state` continuously compare runtime state with tracker truth and stop/release/retry accordingly. | This is one of Symphony’s clearest advantages. |
| **Configuration / workflow contract** | Project config is `pnevma.toml`; runtime/project/global config are spread across docs and Rust config types. Prompt/context construction is handled separately by `pnevma-context`. | `WORKFLOW.md` is a repo-owned contract with YAML front matter + prompt body. `workflow.ex`, `workflow_store.ex`, and `config.ex` turn it into typed runtime config and hot-reload it. | Symphony’s configuration story is tighter and more portable. |
| **Prompt construction** | Pnevma compiles a task-specific context pack with token budget, manifest, and redaction in `context/compiler.rs`, then passes context into adapters (e.g. via `CLAUDE.md`). | `prompt_builder.ex` renders a Liquid/Solid template from issue data plus retry attempt context. | Pnevma is stronger on context assembly; Symphony is stronger on keeping prompt policy repo-owned and versioned with orchestration config. |
| **Observability** | Pnevma has native panes, remote API/WS, DB-backed history, and event emission. | Symphony has a scheduler-native snapshot API (`Orchestrator.snapshot/0`), a terminal dashboard (`status_dashboard.ex`), structured logs, and optional Phoenix HTTP observability (`http_server.ex`). | Symphony’s observability is more tightly coupled to the scheduler; Pnevma’s is broader and more product-facing. |
| **Remote/control plane** | Strong. `crates/pnevma-remote/src/server.rs` exposes REST/RPC/WS; `auth.rs` uses Argon2id-hashed shared password + bearer tokens; `tls.rs` supports Tailscale or self-signed TLS. | Optional observability HTTP endpoint only; not a general remote control plane. | Pnevma is well ahead. |
| **Workflow engine** | Pnevma has an internal workflow DSL and workflow instances (`crates/pnevma-core/src/workflow.rs`, `crates/pnevma-db/src/store.rs::create_workflow*`). | `SPEC.md` explicitly says Symphony is not meant to be a general-purpose workflow engine. | Pnevma covers a problem Symphony intentionally does not address. |

### Bottom line on architecture

- **Symphony** is better organized around a **single unattended scheduler**.
- **Pnevma** is better organized around a **durable, interactive, safety-conscious operator environment**.

The gap is not “Pnevma is missing orchestration.” The gap is that Pnevma’s orchestration is currently **local-task-oriented and distributed**, while Symphony’s is **centralized, tracker-aware, and continuously reconciled**.

---

## 2. Symphony components worth adopting

| Component to adopt | What it does in Symphony | Why it matters | Integration complexity | Where it fits in Pnevma |
|---|---|---|---|---|
| **Repo-owned `WORKFLOW.md` contract** | `workflow.ex`, `workflow_store.ex`, and `config.ex` turn `WORKFLOW.md` into typed runtime config + prompt template with hot reload and last-known-good fallback. | Keeps automation behavior versioned with the repo instead of split across app config, docs, and adapter code. It also gives you a clean handoff format for “automation mode.” | **Medium** | Add a new repo-level automation contract beside `pnevma.toml`; map it into `ProjectContext` and `pnevma-context` rather than replacing existing config wholesale. |
| **Unified automation coordinator** | `orchestrator.ex` owns polling, running claims, retries, continuation, stall detection, and snapshots from one place. | Pnevma’s current automation logic is spread across `DispatchOrchestrator`, `DispatchPool`, `auto_dispatch.rs`, and ad hoc runtime state. A unified coordinator would make automation behavior easier to reason about and expose to UI/remote surfaces. | **High** | New service in the Rust backend, probably living next to `ProjectContext` and replacing most of `auto_dispatch.rs` for unattended mode. |
| **Tracker adapter boundary + normalized issue model** | `tracker.ex`, `linear/adapter.ex`, `linear/client.ex`, `linear/issue.ex` separate orchestration from tracker API details. | Pnevma currently has no comparable issue-tracker ingestion layer. If you want issue-driven automation, this is the correct seam. | **High** | New crate, e.g. `pnevma-tracker`, feeding either virtual `TaskContract`s or a parallel `ExternalWorkItem` model into the coordinator. |
| **Codex app-server integration** | `codex/app_server.ex` uses structured session/turn JSON-RPC, sandbox/approval policies, tool calls, token/rate-limit events, and explicit session IDs. | This is a large reliability upgrade over regex-parsing CLI output. It also unlocks dynamic tools and better telemetry. | **High** | Replace or supplement `crates/pnevma-agents/src/adapters/codex.rs` with an app-server-backed adapter; emit structured events into DB/event bus/UI. |
| **Dynamic tool injection** | `codex/dynamic_tool.ex` exposes `linear_graphql` to the agent at runtime. | This is the right pattern for safe, orchestrator-owned capabilities that should not be hard-coded into the prompt. | **Medium–High** | Add a tool-provider layer in `pnevma-agents`; first tool would likely be tracker access, later project search / review metadata / workflow status. |
| **Workspace lifecycle hooks** | `workspace.ex` supports `after_create`, `before_run`, `after_run`, and `before_remove`, with timeout handling and failure semantics. | Pnevma has strong worktree semantics but much weaker “automation lifecycle” hooks. Hooks are a high-leverage way to clone/setup/sync/cleanup unattended runs. | **Medium** | Extend `pnevma-git` / task dispatch flow so worktree creation and teardown can run hook scripts declared in repo config. |
| **Retry/backoff + stall detection + continuation runs** | `orchestrator.ex::schedule_issue_retry`, `retry_delay`, `restart_stalled_issue`; `agent_runner.ex::do_run_codex_turns` continues while the issue remains active. | Pnevma models retries in data, but Symphony actually implements them in the scheduler. This directly improves unattended execution quality. | **Medium–High** | Add to the unified coordinator, backed by DB state and surfaced in UI/remote APIs. |
| **Per-state concurrency caps** | `Config.max_concurrent_agents_for_state/1` lets Symphony cap concurrency differently for different tracker states. | Useful when “Todo” items should fan out aggressively but “Merging/Rework” should stay small. | **Low–Medium** | Extend the pool/coordinator config model; likely complementary to the tracker layer. |
| **Scheduler-native snapshot/status surface** | `Orchestrator.snapshot/0` plus `status_dashboard.ex` expose exactly what the scheduler thinks is happening. | Pnevma has panes and APIs, but not one canonical “automation runtime snapshot” service boundary. | **Low–Medium** | Add snapshot endpoints for the future coordinator; feed both native UI and remote API from the same payload. |

### Highest-value adoptions

If I had to pick only three Symphony ideas for Pnevma, they would be:

1. **Unified automation coordinator**
2. **`WORKFLOW.md` contract + hot reload**
3. **Codex app-server adapter**

Those three together would move Pnevma from “manual + local auto-dispatch” toward “repeatable unattended automation mode” without discarding its terminal-first strengths.

---

## 3. Overlapping components where Symphony does it better

### 3.1 Scheduler state is better unified and more operationally complete

**Overlap:** both systems schedule work and cap concurrency.

- **Pnevma:**
  - `crates/pnevma-core/src/orchestration.rs::DispatchOrchestrator`
  - `crates/pnevma-agents/src/pool.rs::DispatchPool`
  - `crates/pnevma-commands/src/auto_dispatch.rs::run_cycle`
  - `crates/pnevma-commands/src/state.rs::AppState/ProjectContext`
- **Symphony:**
  - `elixir/lib/symphony_elixir/orchestrator.ex::State`
  - `maybe_dispatch/1`
  - `reconcile_running_issues/1`
  - `dispatch_issue/3`
  - `schedule_issue_retry/4`
  - `snapshot/0`

**What Symphony does better:** it makes one component responsible for the whole automation lifecycle. That matters because dispatch, retries, claims, stop conditions, token totals, per-state concurrency, and status snapshots are all based on the *same* runtime state.

**Why it is better:** Pnevma currently has multiple partial schedulers:

- `DispatchOrchestrator` is a simple priority queue.
- `DispatchPool` is another queue/permit system.
- `auto_dispatch.rs` does a periodic scan of ready tasks and dispatches by available slots.
- session/process state lives elsewhere.

That split is workable for a terminal-first app, but it is weaker for unattended orchestration because no single runtime object owns “what is running, what is claimed, what is retrying, and why.” Symphony’s `Orchestrator` does.

### 3.2 Codex integration is much more robust

**Overlap:** both systems run Codex.

- **Pnevma:** `crates/pnevma-agents/src/adapters/codex.rs`
- **Symphony:** `elixir/lib/symphony_elixir/codex/app_server.ex`

**What Symphony does better:** Symphony uses Codex app-server mode with an explicit session/turn protocol, structured event streaming, tool-call handling, sandbox/approval policy injection, and rate-limit/token tracking.

**What Pnevma does today:** the current `CodexAdapter::send` spawns `codex`, writes a prompt to stdin, closes stdin, reads stdout/stderr line-by-line, and regexes token/cost fields from text output.

**Why Symphony is better:**

- explicit session identity (`thread_id`, `turn_id`, composed `session_id`)
- structured updates back to the orchestrator
- dynamic tool support
- first-class sandbox/approval config
- better stall detection inputs
- no dependence on fragile textual output parsing

This is the single biggest “same feature, better implementation” gap in the comparison.

### 3.3 Repo-owned automation policy is cleaner in Symphony

**Overlap:** both systems need repo/project-level runtime policy.

- **Pnevma:** `pnevma.toml`, docs, task/context/compiler configuration
- **Symphony:** `WORKFLOW.md`, `workflow.ex`, `workflow_store.ex`, `config.ex`, `prompt_builder.ex`

**What Symphony does better:** it keeps **prompt + scheduler config + workspace hooks + tracker config + Codex runtime settings** in one repo-owned file that hot-reloads safely.

**Why it is better:** in Pnevma, the automation contract is spread across:

- `pnevma.toml`
- global config
- adapter defaults
- context compiler behavior
- task metadata (`TaskContract`)

That makes sense for an application platform, but it is not as portable or reproducible for unattended automation. Symphony’s design makes it very clear what the repo itself expects the automation system to do.

### 3.4 Headless workspace lifecycle is more complete

**Overlap:** both systems create isolated workspaces/worktrees.

- **Pnevma:** `crates/pnevma-git/src/service.rs`
- **Symphony:** `elixir/lib/symphony_elixir/workspace.ex`

**What Symphony does better:** lifecycle policy around workspaces.

Specifically, Symphony has:

- deterministic workspace naming from issue identifier
- `after_create`, `before_run`, `after_run`, `before_remove`
- hook timeout handling
- terminal-state cleanup on startup and reconciliation
- workspace-root and symlink-escape validation

Pnevma’s `GitService` is stronger on **Git correctness** and lease reservation, but it is weaker on **automation lifecycle semantics**. For a scheduler, Symphony’s version is more operationally complete.

### 3.5 Retry/continuation behavior is implemented rather than just represented in data

**Overlap:** both systems know that tasks/runs may need retries or multiple passes.

- **Pnevma:** `TaskContract.max_retries`, `loop_iteration`, `loop_context_json`, plus workflow-loop metadata in `crates/pnevma-core/src/workflow.rs`
- **Symphony:** `orchestrator.ex::schedule_issue_retry`, `retry_delay`, `restart_stalled_issue`; `agent_runner.ex::do_run_codex_turns`

**What Symphony does better:** the scheduler actually uses runtime retry state to keep work moving.

- continuation retries are treated differently from failure retries
- exponential backoff is built in
- stalled runs are restarted
- the issue is revalidated before redispatch
- runs continue across multiple Codex turns while the issue remains active

Pnevma has richer *data structures* for retry/looping than Symphony, but Symphony has the more complete *operational implementation*.

### 3.6 Runtime observability is more tightly coupled to scheduler reality

**Overlap:** both expose runtime state to humans.

- **Pnevma:** panes, DB, event emitters, remote API/WS
- **Symphony:** `Orchestrator.snapshot/0`, `status_dashboard.ex`, optional `http_server.ex`

**What Symphony does better:** it exposes exactly what the scheduler currently believes: running issues, retry queue, token totals, rate limits, poll timing.

Pnevma’s surfaces are broader and richer, but they are not built around one canonical automation-state snapshot because the scheduler itself is not centralized in the same way.

---

## 4. Pnevma strengths Symphony lacks

This section matters just as much as the “adopt from Symphony” section. Symphony is not simply “better”; it is better at a narrower problem.

### 4.1 Persistent tmux-backed terminal sessions are a real differentiator

Relevant code:

- `crates/pnevma-session/src/supervisor.rs`
- `crates/pnevma-session/src/model.rs`

Pnevma has a serious terminal runtime:

- create/rebind tmux sessions
- capture scrollback to files
- reattach to existing sessions
- send input to active sessions
- compute session health (`Active`, `Idle`, `Stuck`, etc.)
- replay scrollback slices/tails
- redact secrets in streamed output before storage/broadcast

Symphony does not attempt to solve this. Its workers are agent subprocesses, not operator-grade interactive terminals.

### 4.2 Pnevma’s persistence and audit model is much stronger

Relevant code:

- `crates/pnevma-db/src/store.rs`
- `docs/architecture-overview.md`

Pnevma persists a large portion of operational reality: tasks, sessions, worktrees, reviews, merge queue, workflow instances, costs, notifications, and more. Symphony intentionally avoids a required DB.

That means Pnevma is better suited for:

- audit trails
- resumability after app restart
- postmortems
- product-level history views
- cross-surface consistency (native UI, remote API, background jobs)

### 4.3 Human review / merge / safety controls are productized in Pnevma

Relevant code:

- `crates/pnevma-core/src/protected_actions.rs`
- `crates/pnevma-git/src/service.rs::MergeQueue`
- `crates/pnevma-commands/src/command_registry.rs`

Pnevma has explicit concepts for:

- review approval/rejection
- merge queue serialization
- checkpoints
- destructive-action confirmation phrases
- protected operations like force push / delete active task / purge scrollback

Symphony deliberately does not go deep here. Its spec treats ticket updates and PR behavior as workflow/prompt concerns rather than built-in product features.

### 4.4 Pnevma is provider-neutral; Symphony is effectively Codex-centric

Relevant code:

- `crates/pnevma-agents/src/model.rs::AgentAdapter`
- `crates/pnevma-agents/src/registry.rs`

Pnevma’s adapter trait and registry make “multiple agent runtimes” a first-class design decision. Today that means Claude and Codex, but the abstraction is there.

Symphony’s implementation is intentionally centered on Codex app-server mode. That gives it a better Codex integration, but a less general provider story.

### 4.5 Context compilation/discovery/redaction is much stronger in Pnevma

Relevant code:

- `crates/pnevma-context/src/compiler.rs`
- `crates/pnevma-context/src/discovery.rs`

Pnevma does real pre-execution context assembly:

- token budgeting
- manifest of included/excluded context sections
- file discovery strategies (`scope`, `claude_md`, `git_diff`)
- redaction of known secrets in both markdown and pack structures

Symphony’s `prompt_builder.ex` is elegant, but it is much simpler: issue data + template rendering. It does not solve the same context-engineering problem.

### 4.6 Pnevma already has a secure remote control plane

Relevant code:

- `crates/pnevma-remote/src/server.rs`
- `crates/pnevma-remote/src/auth.rs`
- `crates/pnevma-remote/src/tls.rs`

Pnevma ships infrastructure Symphony does not:

- REST/RPC/WS control surface
- token issuance and revocation
- Argon2id password verification
- per-IP rate limiting
- Tailscale guard
- TLS modes with cert handling

Symphony’s HTTP surface is observability-oriented; it is not a full remote operations plane.

### 4.7 Pnevma has a workflow engine; Symphony explicitly does not

Relevant code:

- `crates/pnevma-core/src/workflow.rs`
- `crates/pnevma-db/src/store.rs::create_workflow`, `create_workflow_instance`

Pnevma can represent reusable workflows, validate dependency ordering, and persist workflow instances. Symphony explicitly lists “general-purpose workflow engine” as a non-goal.

This is a meaningful strategic difference: Pnevma can grow into an automation platform, while Symphony is intentionally a narrower scheduler/runner.

---

## 5. Recommended adoption plan

### Guiding principle

Do **not** port Symphony wholesale.

Port the parts that improve **unattended automation**, but keep Pnevma’s strengths:

- SQLite/event durability
- tmux-backed interactive sessions
- provider-neutral adapter layer
- review/merge/safety model
- remote/native operator surfaces

In practice, Symphony should become a **mode inside Pnevma**, not a replacement architecture.

### Prioritized plan

| Priority | Port / adapt | Why this is the right order | Architectural prerequisites |
|---|---|---|---|
| **0** | **Create a single `AutomationCoordinator` in Rust** inspired by `symphony_elixir/orchestrator.ex` | Everything valuable in Symphony assumes one runtime owner for claims, retries, running sessions, stop conditions, and snapshots. Without this, tracker integration and retries will stay bolted on. | Consolidate responsibilities currently split across `DispatchOrchestrator`, `DispatchPool`, `auto_dispatch.rs`, and runtime pieces of `AppState`. Keep DB as durable backing store; do **not** copy Symphony’s no-DB assumption. |
| **1** | **Add repo-owned `WORKFLOW.md` support with hot reload** | High leverage and relatively low-risk. It gives Pnevma a clean automation contract without undoing existing product config. | The new coordinator should consume a typed runtime config view, similar to Symphony’s `workflow.ex` + `config.ex`. |
| **2** | **Replace the current Codex CLI adapter with an app-server-backed adapter** | This is the biggest reliability and observability upgrade for real unattended runs. It removes brittle stdout parsing and unlocks tools, rate-limit telemetry, and structured turn state. | Needs coordinator-owned session state and a runtime config source for sandbox/approval settings. Fit it behind the existing `AgentAdapter` trait so Claude support remains intact. |
| **3** | **Implement retry/backoff/stall detection/continuation in the coordinator** | This converts Pnevma from opportunistic auto-dispatch into an actual unattended executor. | Depends on priorities 0–2. Persist retry metadata in SQLite so UI/remote surfaces can show it even across restarts. |
| **4** | **Add automation-oriented worktree lifecycle hooks** (`after_create`, `before_run`, `after_run`, `before_remove`) | This lets repos define their own clone/setup/cleanup rules, which is essential once Pnevma runs without an operator sitting in the loop. | Extend `pnevma-git` dispatch/cleanup flows. Reuse Symphony’s failure semantics: creation/before-run failures should abort the attempt; after-run/remove failures should log and continue cleanup. Also copy Symphony’s workspace-root and symlink validation. |
| **5** | **Add tracker abstraction and a Linear adapter** | This is the feature that turns Pnevma into an issue-driven automation system instead of a task board with auto-dispatch. | Depends on the coordinator and `WORKFLOW.md` contract. Decide early whether external issues become first-class `TaskContract`s or whether you keep a separate external-work-item model that maps into tasks. |
| **6** | **Add orchestrator-owned dynamic tools** (start with `linear_graphql`) | Once tracker-driven automation exists, the agent should not need fragile prompt hacks to interact with the tracker. | Best done after the app-server Codex adapter exists. The tool system should live next to the adapter/coordinator, not in UI code. |
| **7** | **Expose one canonical automation snapshot to UI and remote APIs** | Pnevma already has good surfaces; what it lacks is one scheduler-native truth payload. | Coordinator must own runtime state first. Then make native panes and `/api/project/status` read from the same snapshot model. |

### Concrete implementation path

1. **Do not start with Linear.** Start by building the coordinator and `WORKFLOW.md` against Pnevma’s existing task board.
2. Swap in **Codex app-server mode** behind the current `AgentAdapter` trait.
3. Once that is stable, move auto-dispatch to the coordinator and add **retry/stall/continuation**.
4. Only then add the **tracker adapter** and dynamic tool layer.

That order minimizes architectural churn and avoids mixing three large refactors at once.

### What not to copy from Symphony

1. **Do not copy the “no persistent DB” stance.** It is a good fit for Symphony’s daemon, but it would throw away one of Pnevma’s strongest advantages.
2. **Do not copy the Codex-only worldview.** Keep the `AgentAdapter` seam; improve Codex through that seam.
3. **Do not replace worktrees with plain filesystem workspaces.** Pnevma’s one-task-one-worktree discipline is one of its strongest operational ideas.
4. **Do not collapse human review into prompt text.** Pnevma’s explicit review/merge/safety model is better than making those concerns implicit in automation prompts.

---

## Final recommendation

The right interpretation is not “Symphony is the better orchestrator, therefore port Symphony.”

The right interpretation is:

- **Symphony has the better unattended scheduler design.**
- **Pnevma has the better interactive product/runtime design.**

So the best move is to make Pnevma a **two-mode system**:

- **Interactive mode** keeps today’s session/review/merge/remote/UI strengths.
- **Automation mode** borrows Symphony’s strongest ideas: repo-owned workflow contract, centralized reconciliation loop, app-server agent integration, and tracker-aware lifecycle management.

If you do that, you get most of Symphony’s upside **without sacrificing the parts of Pnevma that are already more mature than Symphony**.
