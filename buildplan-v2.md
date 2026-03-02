# Pnevma — Refined Build Plan

**Agent-Era Terminal Workspace**
February 2026 · Confidential

---

## 1. Executive Summary

Pnevma is a local-first, project-aware terminal workspace for agent-driven software delivery. It is not an AI terminal with extra features. It is an execution system that makes multi-session, multi-agent software work reliable, inspectable, and fast.

The product wedge is narrow and deliberate: persistent terminal sessions, project-aware context, task orchestration, one-task-one-worktree execution, guarded review and merge flow, and searchable history with replay. Everything else is deferred until this core loop proves daily use.

### Core Thesis

The winning sequence is: build the execution core, prove session reliability, prove the task-to-agent-to-worktree flow, prove review and recovery, then expand. If Pnevma delivers that loop well, it becomes the operating system for agent-era development.

### Locked Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Application framework | **Tauri 2.x** | Rust backend, webview frontend. Ships cross-platform later without rewrite. Avoids Swift/FFI complexity and custom widget systems. |
| Terminal rendering | **xterm.js** in webview | Battle-tested, canvas-based, connects to Rust PTY via Tauri IPC. |
| Frontend | **Vite + React + TailwindCSS** | Standard stack, fast iteration, visual density for complex panes (board, diff, review). |
| Async runtime | **tokio** | Tauri depends on it. Don't fight the framework. |
| Database | **SQLite via sqlx** | Compile-time checked queries, async, type-safe. No ORM overhead. |
| IPC (UI) | **Tauri commands + events** | No separate daemon process. Tauri backend IS the orchestrator. |
| External automation | **Optional local Unix socket + `pnevma ctl` CLI** | Script and agent-hook friendly control surface that routes to the same backend services/event log as Tauri commands. |
| Error handling | **thiserror** (library crates) + **anyhow** (app crate) | Typed errors where contracts matter, ergonomic errors in glue code. |
| Logging | **tracing** crate | Structured, async-aware. Spans for request/task/session correlation. |
| Serialization | **serde + serde_json** / **toml** for config | Standard ecosystem choices. |
| License | **MIT + Apache-2.0** dual license | Standard Rust ecosystem dual license. No GPL contamination. Maximum adoption. |

### Build Strategy

Phase 0–2 ship fast. The demo target for Phase 2: dispatch a task to Claude Code in an isolated worktree and see output stream back in a terminal pane while the task board updates. Everything after Phase 2 is hardening and polish, built iteratively.

### Borrowed Patterns (from cmux, adapted to Pnevma)

- Add a local socket + CLI control plane for automation and agent hooks, while keeping Tauri as the primary UI IPC.
- Add an agent attention model: notifications panel, unread state, and jump-to-latest-unread workflow.
- Use handle-based JSON methods for external control (`workspace.*`, `pane.*`, `session.*`, `task.*`, `notification.*`).
- Do **not** adopt cmux's native Swift/AppKit + Ghostty-fork architecture. Pnevma remains Rust + Tauri + xterm.js.

### Target User

Solo builder or senior engineer who already lives in the terminal and actively uses CLI coding agents such as Claude Code or Codex. The user currently duct-tapes together tmux, git worktrees, and manual context management. Pnevma replaces that entire workflow.

---

## 2. Product Definition

### Product Statement

Pnevma is a terminal-first execution workspace that lets a developer plan work, dispatch agents into isolated worktrees, review outcomes, and recover context instantly across sessions and restarts.

### Jobs to Be Done

- Help me turn a project idea into an executable board of work.
- Let me run multiple agent sessions without losing context or control.
- Make branching, worktrees, review, and merge safe enough that I can trust the system daily.
- Let me recover what happened yesterday in under a minute.

### Product Principles

- Terminal-first, not terminal-only.
- Local-first by default. No cloud dependency for core function.
- Every action is attributable and replayable.
- Human approval at high-risk boundaries (branch merge, destructive operations).
- One task maps to one worktree. Always.
- Agents are adapters, not hard-coded assumptions. The system is provider-neutral.
- Fast keyboard-first workflows win over ornamental UI.

### Positioning

Pnevma is not a generic AI terminal. Its differentiated promise is: the project-aware terminal workspace for running agent-driven software delivery without losing control. Launch messaging focuses on persistent context, safe parallel execution, worktree-aware orchestration, fast recovery after interruption, and inspectable review and merge workflow.

---

## 3. Architecture

### Architecture Philosophy

Pnevma is a single Tauri application. The Rust backend owns all workflow logic — project model, task engine, session supervision, agent orchestration, persistence. The React frontend is a thin view layer that renders state from the backend and sends user actions back via Tauri commands. The backend pushes state changes to the frontend via Tauri events.

There is no separate daemon process. The Tauri backend IS the orchestrator. PTY child processes outlive the app via process detachment. On app restart, the backend discovers live PTYs by stored PID and reattaches. Dead processes show restored scrollback with a restart prompt.

The agent adapter layer is provider-neutral. The persistence layer uses SQLite for entities and an append-only event log on disk for replay and audit.

### How Tauri IPC Works

```
Frontend → Backend:  invoke("command_name", { args })    // request-response
Backend → Frontend:  emit("event_name", payload)          // pub-sub events
Terminal input:      invoke("pty_write", { session_id, data })
Terminal output:     listen("pty_output:{session_id}", callback)
State updates:       listen("task_updated", callback)
                     listen("session_health_changed", callback)
CLI/Hook → Backend:  Unix socket JSON request (`pnevma ctl`) -> same command handlers
Backend → CLI/Hook:  JSON response + event-log emission for replay/audit
```

The frontend never mutates state directly. All mutations go through Tauri commands. All state changes arrive as events.

### System Components

| Component | Crate | Responsibility |
|---|---|---|
| Core Engine | `pnevma-core` | Projects, tasks, events, orchestration, state machine, dispatch logic. |
| Session Supervisor | `pnevma-session` | PTY ownership, scrollback persistence, health monitoring, heartbeats, process detachment/reattach. |
| Agent Adapter Layer | `pnevma-agents` | Adapter trait, Claude Code adapter, Codex adapter, throttle pool, event normalization. |
| Git Service | `pnevma-git` | Branch creation, worktree mapping, lease enforcement, merge queue, cleanup, conflict detection. |
| Context Compiler | `pnevma-context` | Task-specific prompt assembly, token budgets, manifest generation. |
| Database Layer | `pnevma-db` | SQLite schema, migrations, typed query functions, connection pool. |
| App Shell | `pnevma-app` | Tauri application, command handlers, event bridge. Thin glue between crates and frontend. |
| UI Shell | `frontend/` | React panes: terminal (xterm.js), task board, review, diff, search, settings. |

### Cargo Workspace Layout

```
pnevma/
├── Cargo.toml                   # workspace root
├── crates/
│   ├── pnevma-core/             # project model, event log, task engine, state machine, dispatch
│   ├── pnevma-session/          # PTY supervisor, scrollback, health monitoring
│   ├── pnevma-agents/           # adapter trait, Claude Code, Codex, throttle pool
│   ├── pnevma-git/              # worktree service, branch manager, merge queue
│   ├── pnevma-context/          # context compiler, token budgets, manifest
│   ├── pnevma-db/               # schema, migrations, query layer
│   └── pnevma-app/              # Tauri application, commands, event bridge
├── frontend/                    # Vite + React + TailwindCSS + xterm.js
│   ├── src/
│   │   ├── components/          # shared UI components
│   │   │   └── ui/              # primitives (buttons, inputs, badges)
│   │   ├── panes/               # pane-type components
│   │   │   ├── terminal/        # xterm.js terminal pane
│   │   │   ├── task-board/      # kanban board
│   │   │   ├── review/          # review pack display
│   │   │   ├── diff/            # diff viewer
│   │   │   ├── search/          # full-text search
│   │   │   └── settings/        # configuration
│   │   ├── hooks/               # React hooks for Tauri IPC
│   │   ├── stores/              # state management (zustand)
│   │   └── lib/                 # utilities, types
│   ├── index.html
│   ├── package.json
│   ├── tailwind.config.ts
│   ├── tsconfig.json
│   └── vite.config.ts
├── spike/                       # Phase 0 prototypes (temporary)
├── docs/
│   └── decisions/               # ADRs
├── pnevma.toml                  # example project config
└── README.md
```

### Concurrency Model

- **Runtime:** tokio multi-threaded runtime (Tauri default).
- **Agent pool:** Configurable max concurrent sessions (default: 4, set in `pnevma.toml`). When the pool is full, dispatches queue by priority (P0–P3) then FIFO.
- **Event streams:** tokio broadcast channels from agent sessions to the Tauri event bridge. Each agent session has its own channel.
- **PTY I/O:** Separate tokio tasks per PTY for non-blocking reads and writes. Output is chunked and forwarded to both scrollback persistence and the frontend event stream.
- **SQLite:** Single-writer, multiple-reader via sqlx pool. Write operations are serialized through the core engine. Read queries (for UI display) run concurrently.
- **Merge queue:** Serialized by design — one merge at a time. Implemented as a tokio mutex-guarded queue, not concurrent.

### Error Handling Strategy

- **Library crates** (`pnevma-core`, `pnevma-session`, etc.): Use `thiserror` with typed error enums per crate. Each crate defines a `XxxError` enum covering its failure modes.
- **App crate** (`pnevma-app`): Use `anyhow` for command handlers. Convert typed errors into user-facing messages at the Tauri command boundary.
- **Frontend:** Tauri commands return `Result<T, String>`. Frontend displays errors via toast notifications. Errors that require action (conflict, failed check) surface in the relevant pane.
- **Panics:** The Tauri app installs a panic hook that logs the panic, persists current state, and shows a crash recovery dialog on next launch.
- **PTY process death:** The session supervisor detects process exit via tokio signal handling. Stores exit code, marks session as Error or Complete, emits event.

### Logging Strategy

- **Crate:** `tracing` with `tracing-subscriber` for output formatting.
- **Levels:** `error` for unrecoverable failures, `warn` for degraded operation, `info` for lifecycle events (session start, task dispatch, merge), `debug` for detailed flow, `trace` for I/O.
- **Spans:** Nested spans for `project → task → session → agent_run`. Correlation via span IDs.
- **Output:** JSON logs to `~/.local/share/pnevma/logs/` (rotated). Console output in dev mode.
- **Redaction:** Tracing layer that strips known secret patterns before writing. Integrated with the secrets service (Phase 3).

### Configuration

**Project-level:** Each project has a `pnevma.toml` at its root.

```toml
[project]
name = "my-app"
brief = "SaaS dashboard with Stripe billing"

[agents]
default_provider = "claude-code"
max_concurrent = 4

[agents.claude-code]
model = "claude-sonnet-4-6"
token_budget = 80000
timeout_minutes = 30

[agents.codex]
token_budget = 60000
timeout_minutes = 20

[automation]
socket_enabled = true
socket_path = ".pnevma/run/control.sock"
socket_auth = "same-user" # same-user | password

[notifications]
enable_attention_queue = true
osc_sequences = [9, 99, 777]

[branches]
target = "main"
naming = "pnevma/{task_id}/{slug}"

[rules]
paths = [".pnevma/rules/*.md"]

[conventions]
paths = [".pnevma/conventions/*.md"]
```

**Global:** `~/.config/pnevma/config.toml` stores user preferences: default agent provider, keybindings, theme, telemetry opt-in, socket auth mode/password file, and desktop notification preferences.

**Rules and conventions:** Stored as markdown files within the project (default: `.pnevma/rules/` and `.pnevma/conventions/`). Referenced by path in `pnevma.toml`. Injected into agent context packs by the context compiler.

---

## 4. Interface Contracts

### Agent Adapter Trait

Every agent provider implements this contract. The system never calls provider-specific APIs directly. All methods are async.

```rust
#[async_trait]
trait AgentAdapter: Send + Sync {
    async fn spawn(&self, config: AgentConfig) -> Result<AgentHandle, AgentError>;
    async fn send(&self, handle: &AgentHandle, input: TaskPayload) -> Result<(), AgentError>;
    async fn interrupt(&self, handle: &AgentHandle) -> Result<(), AgentError>;
    async fn stop(&self, handle: &AgentHandle) -> Result<(), AgentError>;
    fn events(&self, handle: &AgentHandle) -> broadcast::Receiver<AgentEvent>;
    async fn parse_usage(&self, handle: &AgentHandle) -> Result<CostRecord, AgentError>;
}
```

**AgentConfig** contains: provider name, model identifier, environment variables (with secret refs resolved), working directory, and timeout settings.

**TaskPayload** contains: objective text, constraints, project rules (compiled), worktree path, branch name, acceptance checks, relevant file paths, and prior context summary.

**AgentEvent** is an enum:
- `OutputChunk(String)` — raw terminal output
- `ToolUse { name: String, input: String, output: String }` — structured tool invocation
- `StatusChange(AgentStatus)` — running, paused, waiting
- `Error(String)` — recoverable error
- `UsageUpdate { tokens_in: u64, tokens_out: u64, cost_usd: f64 }` — incremental usage
- `Complete { summary: String }` — agent finished

**CostRecord** contains: provider, model, tokens_in, tokens_out, estimated_cost_usd, timestamp, task_id, session_id.

V1 ships with two adapters: Claude Code and OpenAI Codex CLI. Additional adapters are added post-launch. The adapter contract explicitly accommodates agents without cloud billing (Ollama, llama.cpp) — no cloud-specific assumptions in the trait.

### External Control API (Socket + CLI)

Pnevma exposes an optional local Unix socket API for external scripts, agent hooks, and automation. This API is additive; it does not replace Tauri commands/events.

- Protocol: newline-delimited JSON request/response envelopes.
- Routing: socket methods call the same Rust services used by Tauri command handlers.
- Auditability: every successful and failed method call emits a structured event.
- Security (v1): socket file permissions `0600`, peer-UID validation, optional password mode.

```json
{"id":"1","method":"task.dispatch","params":{"task_id":"..."}}
{"id":"1","ok":true,"result":{"queued":false}}
{"id":"2","ok":false,"error":{"code":"not_found","message":"task not found"}}
```

Method naming follows noun namespaces and stable handles, e.g.:
- `project.open`, `project.status`
- `workspace.list`, `workspace.select`
- `pane.list`, `pane.focus`
- `session.send_input`, `session.restart`
- `task.list`, `task.dispatch`
- `notification.create`, `notification.list`, `notification.mark_read`

### Task Contract Schema

Every task in the system conforms to this schema. The task board, context compiler, and agent adapter all consume the same shape.

```rust
struct TaskContract {
    id: TaskId,
    title: String,
    goal: String,                        // What to achieve
    scope: Vec<FilePath>,                 // Files in scope
    out_of_scope: Vec<String>,            // Explicit exclusions
    dependencies: Vec<TaskId>,            // Blocked-by refs
    acceptance_criteria: Vec<Check>,      // Pass/fail gates
    constraints: Vec<String>,             // Rules, limits
    priority: Priority,                   // P0–P3
    status: TaskStatus,                   // Planned|Ready|InProgress|Review|Done|Failed|Blocked
    assigned_session: Option<SessionId>,
    branch: Option<String>,
    worktree: Option<WorktreeRef>,
    prompt_pack: Option<ContextPack>,     // Compiled at dispatch time
    handoff_summary: Option<String>,      // Written on pause/fail/handoff
    created_at: Timestamp,
    updated_at: Timestamp,
}
```

**TaskStatus state machine:**
```
Planned → Ready → InProgress → Review → Done
                ↘ Failed    ↗        ↘ Failed
                ↘ Blocked (auto, when deps unmet)
```
Transitions are validated. Invalid transitions are rejected with an error.

**Check** is: `{ description: String, check_type: TestCommand | FileExists | ManualApproval, command: Option<String> }`.

**ContextPack** is: `{ task_contract: TaskContract, project_brief: String, architecture_notes: String, conventions: Vec<String>, rules: Vec<String>, relevant_file_contents: Vec<(FilePath, String)>, prior_task_summaries: Vec<String>, token_budget: usize, actual_tokens: usize }`.

### Context Compiler Specification

The context compiler assembles a ContextPack for each task at dispatch time. It ships in two versions:

**V1 (Phase 2 — simplified):** Assembles task goal, acceptance criteria, constraints, scope file list, and project rules into a markdown file written to the worktree. No token budget enforcement. Good enough for the core demo.

**V2 (Phase 4 — full):** Operates within a strict token budget per provider. Priority ordering (highest to lowest): task contract fields, relevant file contents, project rules and conventions, architecture notes, prior completed-task summaries, project brief. The compiler fills from highest priority down, truncating or omitting lower-priority items when the budget is reached. Every compiled pack includes a context manifest listing exactly what was included and what was omitted with reason. The exact pack is persisted for reproducibility.

### Cost Tracking Specification

V1 tracks costs on a best-effort basis with explicit gaps.

- **Tracked:** Token counts and estimated USD cost where the provider CLI exposes usage data. Claude Code emits usage in its output stream. Codex may require parsing log files.
- **Attribution:** Every CostRecord is linked to a task_id and session_id. Aggregations are available per-task, per-session, and per-project.
- **Display:** Running cost total visible in the task board per task and in the project status bar.
- **Gaps:** When a provider does not expose token counts, the UI shows a clear "tracking unavailable" indicator rather than silently omitting. No silent zeros.

---

## 5. Data Model

All entities live in a per-project SQLite database at `.pnevma/pnevma.db`. Heavy content (scrollback chunks, context packs, review packs) lives on disk at `.pnevma/data/` with path references in SQLite.

| Entity | Key Fields | Notes |
|---|---|---|
| projects | id, name, path, created_at, brief, config_path | One DB per project |
| sessions | id, project_id, name, type, status, pid, cwd, command, branch, worktree_id, started_at, last_heartbeat | PTY-backed processes |
| panes | id, session_id, type, position, label, metadata_json | UI layout state |
| tasks | id, project_id, title, goal, scope_json, dependencies_json, acceptance_json, constraints_json, priority, status, branch, worktree_id, handoff_summary, created_at, updated_at | Full task contract |
| task_dependencies | task_id, depends_on_task_id | Explicit DAG edges |
| worktrees | id, project_id, task_id, path, branch, lease_status, lease_started, last_active | One per active task |
| agent_runs | id, task_id, session_id, provider, model, config_json, context_pack_path, status, started_at, ended_at, summary, cost_json | Full run record |
| artifacts | id, project_id, task_id, type, path, description, created_at | Outputs, briefs, decisions |
| rules | id, project_id, name, path, scope, active | Convention and rule files |
| costs | id, agent_run_id, task_id, session_id, provider, model, tokens_in, tokens_out, estimated_usd, tracked, timestamp | Per-call records |
| notifications | id, project_id, task_id, session_id, pane_id, title, body, source, severity, read_at, created_at | Agent attention queue + notification panel |
| events | id, project_id, trace_id, source, event_type, payload_json, timestamp | Append-only log |
| checkpoints | id, project_id, task_id, git_ref, session_metadata_json, created_at, description | Snapshot before risky ops |
| reviews | id, task_id, status, review_pack_path, reviewer_notes, approved_at | Merge gate records |

**Schema creation is incremental.** All tables are defined in the migration set, but Phase 1 only actively uses projects, sessions, panes, and events. Tables are populated as their features ship.

### Event Log

The event log is the source of truth for replay and debugging. Every significant action emits a structured event: user actions, agent actions, git transitions, session lifecycle changes, acceptance check results, and cost updates. Events carry trace IDs at project, task, and session level for correlated querying.

Event types are defined as a Rust enum in `pnevma-core`:

```rust
enum EventType {
    // Session lifecycle
    SessionSpawned, SessionExited, SessionReattached, SessionHealthChanged,
    // Task lifecycle
    TaskCreated, TaskStatusChanged, TaskDispatched, TaskCompleted, TaskFailed,
    // Agent
    AgentSpawned, AgentOutput, AgentToolUse, AgentError, AgentComplete, AgentUsageUpdate,
    // Git
    WorktreeCreated, WorktreeRemoved, BranchCreated, MergeStarted, MergeCompleted, MergeFailed, ConflictDetected,
    // Review
    AcceptanceCheckRun, ReviewPackGenerated, ReviewApproved, ReviewRejected,
    // Notifications
    NotificationCreated, NotificationRead, NotificationCleared,
    // External automation
    AutomationRequestReceived, AutomationRequestCompleted, AutomationRequestFailed,
    // System
    CheckpointCreated, CheckpointRestored, ProjectOpened, ProjectClosed,
}
```

---

## 6. Development Workflow

### Quality Gates (Run Frequently)

```bash
# Rust
cargo fmt --check                        # Formatting
cargo clippy -- -D warnings              # Lints — treat warnings as errors
cargo test                               # Unit + integration tests
cargo build --release                    # Verify release build compiles

# Frontend
cd frontend
npx tsc --noEmit                         # TypeScript strict mode
npx eslint .                             # ESLint
npx vite build                           # Production build
```

Run Rust checks after every 3–5 file changes. Run frontend checks after every component change. Never accumulate more than 20 file changes without verifying.

### Test Strategy

| Level | Tool | Scope | When |
|---|---|---|---|
| Unit | `#[test]` in each crate | Pure functions, state machines, parsers | Every change |
| Property-based | `proptest` | Merge queue ordering, task state transitions, event log integrity, worktree lease invariants | After state machine or queue changes |
| Integration | Custom test harness | Spawns the Tauri backend and drives it over IPC (Tauri commands). Tests full subsystem flows: session restore, agent dispatch, worktree lifecycle, merge queue. | After subsystem changes |
| System | Custom test harness | End-to-end scenarios: create project → dispatch task → review → merge. Exercises Rust backend through the same command interface the frontend uses. | Before phase gate |

No Vitest or Playwright. The frontend is tested indirectly through the IPC test harness — if the backend commands return correct state, the frontend renders it. Frontend-specific bugs are caught during dogfooding.

### Spike-to-Production Transition

Per-spike decision after Phase 0:

- **PTY supervisor spike:** Likely refactorable. Clean systems code. Migrate core logic into `pnevma-session` crate.
- **Agent adapter spike:** Likely rewrite. The `AgentAdapter` trait design will mature during Phase 1 scaffolding. Keep the parsing logic, rewrite the structure.
- **Tauri + xterm.js spike:** Throwaway. The Phase 1 app scaffold replaces it entirely. Keep the xterm.js configuration and IPC patterns.

### Git Workflow for Pnevma Development

Pnevma dogfoods itself from Phase 2 onward. Before that:

- `main` — stable, always builds
- `feat/phase-N-task` — feature branches per task
- Commit format: `type(crate): description` (e.g., `feat(session): add PTY health state machine`)
- No force pushes to main. Squash merge feature branches.

---

## 7. Phased Build Plan

This plan is structured for sequential execution. Each phase has explicit entry conditions, a task list with file-level deliverables, and acceptance criteria that must pass before proceeding. Phases 0–2 are optimized for speed to reach the core demo. Phases 3–5 harden and polish.

---

### Phase 0: Feasibility Spike

**Goal:** De-risk three unknowns: xterm.js terminal rendering in a Tauri webview (latency, pane coexistence), PTY session persistence across app restarts, and Claude Code adapter feasibility. Produce working prototypes, not production code.

#### Entry Conditions

- Rust toolchain (stable) installed, macOS target.
- Node.js 20+ and npm installed.
- Tauri CLI installed (`cargo install tauri-cli`).
- SQLite available (macOS ships it).
- Git installed. Claude Code CLI installed and authenticated.

#### Tasks

**0.1 — Tauri + xterm.js terminal spike**

- Create a minimal Tauri 2.x app with a React frontend.
- Embed xterm.js in the webview, connected to a PTY spawned in the Rust backend.
- Data flow: Rust spawns PTY → tokio task reads output → Tauri `emit("pty_output", data)` → xterm.js `terminal.write(data)`. Reverse for input.
- Render a second non-terminal pane alongside the terminal (simple HTML task list). Verify both coexist without layout issues.
- **Latency test:** Type interactively in the terminal. Measure perceived input latency. Target: indistinguishable from a native terminal for typing and scrolling. If latency exceeds ~50ms perceived, evaluate alternatives (Tauri native window for terminal, WezTerm widget embedded via FFI).
- **Decision gate:** If xterm.js latency is unacceptable AND no alternative resolves it within a reasonable effort, reconsider the Tauri approach and document the decision.

**0.2 — PTY session persistence prototype**

- Spawn a shell via PTY in the Rust backend (use `portable-pty` or raw `nix::pty`).
- Persist session metadata (pid, cwd, command, status) to a SQLite row.
- Append terminal output to a chunked scrollback file on disk (one file per session, append-only).
- Kill and relaunch the Tauri app. Restore scrollback in xterm.js from the stored chunks. Check if the shell process is still alive by PID — if so, reattach PTY. If not, show restored scrollback with a "Session ended — restart?" prompt.

**0.3 — Agent adapter proof of concept**

- Implement a minimal Claude Code adapter: spawn the CLI process in a specified directory, send a simple task prompt via stdin, capture stdout/stderr line by line, parse a usage/cost line from the output.
- Run the adapter inside a worktree created by `git worktree add`.
- Emit at least `OutputChunk` and `Complete` as structured Rust types.
- Verify: the agent writes files in the worktree. The worktree is isolated from the main branch.

#### Deliverables

- `spike/tauri-terminal/` — Working Tauri app with xterm.js + PTY + side pane.
- `spike/pty-persist/` — Session persistence prototype with restore.
- `spike/agent-adapter/` — Minimal Claude Code adapter with structured events.
- `docs/decisions/001-terminal-rendering.md` — ADR documenting xterm.js viability and latency findings.

#### Acceptance Criteria

- Terminal pane in Tauri webview with acceptable input latency (< 50ms perceived). A non-terminal pane coexists alongside it.
- App kill → relaunch restores session scrollback and reattaches to live processes.
- Agent adapter spawns Claude Code in a worktree and emits `OutputChunk` and `Complete` events.

---

### Phase 1: Foundation

**Goal:** Production-quality persistence, session management, and UI shell. After this phase, Pnevma is a functional terminal app with persistent named sessions, project-aware workspaces, pane management, and a command palette.

#### Entry Conditions

- Phase 0 complete. Terminal rendering approach validated and documented.

#### Tasks

**1.1 — Project scaffolding**

- Set up the cargo workspace with all seven crates: `pnevma-core`, `pnevma-session`, `pnevma-agents`, `pnevma-git`, `pnevma-context`, `pnevma-db`, `pnevma-app`.
- Set up the frontend: Vite + React + TailwindCSS + xterm.js. Configure TypeScript strict mode.
- Wire Tauri: `pnevma-app` as the Tauri Rust backend, `frontend/` as the Tauri frontend source.
- Establish error handling patterns: `thiserror` error enums in each library crate, `anyhow` in `pnevma-app` command handlers.
- Establish logging: `tracing` crate with `tracing-subscriber`. JSON output to log files, console output in dev mode.
- CI script (shell script or Makefile): runs fmt, clippy, test, build for Rust; lint, type-check, test, build for frontend.
- **Deliverable:** `cargo build` and `npm run build` both succeed. `cargo test` passes (trivial initial tests). Tauri dev mode launches an empty app window.

**1.2 — Database layer** (`pnevma-db`)

- Full SQLite schema with all 13 tables from the data model section. Use sqlx migrations.
- Typed query functions for the tables actively used in Phase 1: projects, sessions, panes, events.
- Connection pool via sqlx. Single writer, multiple reader pattern.
- Database created per-project at `.pnevma/pnevma.db`.
- **Deliverable:** Migration runs cleanly. Query functions compile with sqlx compile-time checks.

**1.3 — Event log** (`pnevma-core`)

- Append-only event writer. Events carry: id, project_id, trace_id, source, event_type (Rust enum), payload (JSON), timestamp.
- Trace ID support: project scope, task scope, session scope. Events can be correlated by any scope.
- Event query API: filter by project, task, session, event_type, and time range. Returns a stream of events.
- **Deliverable:** Events can be written and queried. Unit tests verify filtering and ordering.

**1.4 — Project model** (`pnevma-core`)

- `pnevma.toml` parser using the `toml` crate. Validate required fields, provide defaults for optional ones.
- Global config parser for `~/.config/pnevma/config.toml`.
- Project lifecycle commands (Tauri commands): `open_project(path)`, `close_project()`, `list_recent_projects()`.
- Open project: locate `pnevma.toml`, open/create `.pnevma/pnevma.db`, load config.
- Close project: flush state, close DB connection.
- **Deliverable:** Tauri app can open a project directory, load its config, and display the project name.

**1.5 — Session supervisor** (`pnevma-session`)

- Production PTY supervisor built on Phase 0 learnings. Spawn shell sessions bound to a project.
- Track per-session: pid, cwd, command, status, branch, worktree_id, started_at, last_heartbeat.
- Health state machine: Active → Idle (after configurable timeout) → Stuck (after extended inactivity). Also: Waiting, Error, Complete.
- Heartbeat: emit on activity (output received), on idle timeout, on exit. Store last_heartbeat in DB.
- Incremental scrollback persistence: chunk terminal output to disk files (one per session, append-only, indexed by byte offset for fast seek).
- Session restore on app restart: query DB for sessions, check PIDs, reattach live processes, restore scrollback for dead ones.
- PTY detachment: on app close, child processes are not killed. On restart, reattach.
- **Deliverable:** Sessions persist across app restarts. Health state transitions emit events.

**1.6 — UI shell** (`pnevma-app` + `frontend/`)

- Pane manager: typed panes (terminal, placeholder for task-board/review/search/settings). Each pane has an id, session binding (for terminals), type, position, and label.
- Layout system: split horizontal, split vertical, resize, close, swap, focus. All operations via keyboard shortcuts.
- Pane layout persistence: store pane tree in DB (panes table). Restore on app restart.
- Terminal pane: xterm.js connected to a session's PTY via Tauri events. One xterm instance per terminal pane.
- Command palette: React component, fuzzy-search, triggered by `Cmd+K` (configurable).
- Initial commands: new session, switch pane, open project, close pane, settings.
- Command registration: subsystems register commands via a registry pattern, not hard-coded.
- Status bar: project name, active session count, connection status.
- **Deliverable:** Multi-pane terminal app with command palette, persistent layout.

#### Deliverables

- All crates scaffolded with proper module structure and initial types.
- Working Tauri app: terminal panes, command palette, pane management.
- SQLite persistence with migrations and typed queries.
- Event log writing and querying.
- Session restore across app restarts.

#### Acceptance Criteria

- User can open a project, create named terminal sessions, split panes, and use the command palette.
- Quitting and relaunching Pnevma restores: pane layout, session scrollback, and session metadata.
- Events are written to the append-only log and queryable by project and session.
- All CI gates pass: cargo fmt, clippy, test, build; frontend lint, type-check, build.

---

### Phase 2: Core Execution Loop

**Goal:** The demo. User creates a task, dispatches it to Claude Code in an isolated worktree, sees output stream in a terminal pane, and the task board updates on completion. This is the "holy shit" moment.

#### Entry Conditions

- Phase 1 complete. Persistent terminal sessions and pane management working.

#### Tasks

**2.1 — Task model** (`pnevma-core`)

- Implement the full `TaskContract` struct as defined in the interface contracts section.
- Task state machine with validated transitions (enforced in code, invalid transitions return errors).
- Task CRUD operations exposed as Tauri commands: `create_task`, `update_task`, `delete_task`, `list_tasks`, `get_task`.
- Validation on creation: title non-empty, goal non-empty. Validation on transition to Ready: acceptance_criteria has at least one check, scope files exist.
- Task dependency DAG via `task_dependencies` table. When a dependency is unmet, task auto-transitions to Blocked. When all deps resolve, auto-transition to Planned.
- **Deliverable:** Tasks can be created, updated, and queried. State machine enforces valid transitions.

**2.2 — Task board pane** (`frontend/`)

- React pane component backed by the tasks table. Reads state via Tauri commands, subscribes to `task_updated` events for reactive updates.
- Kanban columns: Planned, Ready, In Progress, Review, Done, Failed, Blocked.
- Keyboard-driven operations: `n` new task, `e` edit, `d` dispatch (on Ready task), `Enter` open details, `x` delete (with confirmation), arrow keys to navigate.
- Dependency indicators: blocked tasks show which deps are unmet.
- Inline task editor: edit title, goal, scope, acceptance criteria in a form overlay.
- Queue indicator: when agent pool is full, show queue position on task card.
- Cost badge: per-task cost displayed on card (from cost tracking).
- **Deliverable:** Working kanban board that updates reactively.

**2.3 — Git worktree service** (`pnevma-git`)

- `create_worktree(task_id, base_branch)`: creates branch `pnevma/<task-id>/<slug>` and worktree at `.pnevma/worktrees/<task-id>/`.
- Worktree lease manager: each worktree row in DB is locked to exactly one task. Lease includes: task_id, started timestamp, last_active timestamp.
- Stale lease detection: warn after configurable inactivity (default: 2 hours). Surface in task board.
- `cleanup_worktree(task_id)`: remove worktree from disk, optionally delete branch, update DB.
- `list_worktrees(project_id)`: return all active worktrees with lease status.
- All operations emit events to the event log.
- **Deliverable:** Worktrees are created, leased, and cleaned up automatically. Lease violations are prevented.

**2.4 — Agent adapter layer** (`pnevma-agents`)

- Implement the `AgentAdapter` async trait as defined in interface contracts.
- **Claude Code adapter:** Spawn the CLI process in a worktree directory. Write the task context to a file in the worktree. Pass the file path or initial prompt via stdin/args. Capture stdout/stderr line by line. Parse output into `AgentEvent` variants using regex/pattern matching. Detect completion. Parse usage/cost from Claude Code's output format.
- **Codex CLI adapter:** Same contract, different output parsing.
- Adapter registry: at startup, detect which agent CLIs are available (`which claude`, `which codex`). Register available adapters. User selects per-task or project default from `pnevma.toml`.
- **Deliverable:** Both adapters implement the trait. Claude Code adapter tested against a real invocation.

**2.5 — Agent throttle pool** (`pnevma-agents`)

- Configurable max concurrent sessions (default: 4, from `pnevma.toml` `agents.max_concurrent`).
- Priority queue for pending dispatches: P0 before P1 before P2 before P3, FIFO within priority.
- When pool is full: task stays in Ready status with a "queued (position N)" indicator. Dispatch starts automatically when a slot opens.
- Pool state exposed via Tauri command for frontend display.
- **Deliverable:** Concurrent agent limit enforced. Queue drains automatically.

**2.6 — Dispatch orchestration** (`pnevma-core`)

- Dispatch flow triggered by user action (keyboard shortcut on Ready task):
  1. Check agent pool capacity. If full, enqueue and return.
  2. Transition task to InProgress.
  3. Create worktree via git service.
  4. Compile context (v1 — simplified): assemble task goal + acceptance criteria + constraints + scope file list + project rules. Write to `.pnevma/task-context.md` in the worktree.
  5. Spawn agent via adapter in the worktree directory.
  6. Create a new terminal pane bound to the agent's PTY output. Focus the pane.
  7. Stream agent events to: event log, frontend (via Tauri events), cost tracker.
- Completion handling: on `AgentEvent::Complete`, update task status (stays InProgress — acceptance checks in Phase 3 will gate the transition to Review). Write cost record.
- Failure handling: on agent error or timeout, transition task to Failed, write handoff summary (agent's last output), emit event.
- **Deliverable:** End-to-end dispatch working. User triggers dispatch, sees agent working in a new pane.

**2.7 — Cost tracking** (`pnevma-core`)

- On `AgentEvent::UsageUpdate`: write incremental `CostRecord` to costs table.
- On `AgentEvent::Complete`: write final cost record.
- Tauri commands: `get_task_cost(task_id)`, `get_project_cost(project_id)`.
- Task board card shows running cost badge.
- Status bar shows project total cost.
- When adapter returns "tracking unavailable," show indicator on card instead of $0.
- **Deliverable:** Costs tracked and displayed.

**2.8 — External automation control plane** (`pnevma-app` + `pnevma-core`)

- Add optional Unix socket server in the Tauri backend process (no daemon split).
- Add `pnevma ctl` CLI wrapper for local scripting and agent hook integration.
- Implement JSON request/response envelope and stable method namespace.
- Initial method set: `project.status`, `task.list`, `task.dispatch`, `session.send_input`, `notification.create`.
- Security: file mode `0600`, same-user (peer UID) check, optional password mode in config.
- All requests (success/failure) emit structured events for replay and audit.
- **Deliverable:** External scripts can dispatch tasks and post notifications without direct frontend involvement.

#### Deliverables

- `pnevma-core`: task model, state machine, dispatch orchestration, cost tracking.
- `pnevma-agents`: adapter trait, Claude Code adapter, Codex adapter, throttle pool.
- `pnevma-git`: worktree service, lease manager, cleanup.
- `pnevma-app`: local socket server + `pnevma ctl` integration + audit event wiring.
- `frontend/`: task board pane with reactive updates, cost badges, queue indicators.

#### Acceptance Criteria

- User can create a task with a goal and acceptance criteria, see it on the board.
- Dispatching a Ready task: creates a worktree, spawns Claude Code, opens a terminal pane streaming agent output.
- Task board updates reactively: card moves to In Progress, cost badge updates.
- On agent completion: task card updates, cost recorded.
- Worktrees are leased to tasks and cleaned up on task Done/Failed.
- Agent pool enforces concurrent limit. Excess dispatches queue.
- Local scripts can dispatch tasks and create notifications through `pnevma ctl` and the socket API.
- **Demo scenario:** Create a task "Add a hello world endpoint to the Express server." Dispatch to Claude Code. Watch it work in a worktree. See the board update.

---

### Phase 3: Review & Trust

**Goal:** The safety layer. Acceptance checks gate review entry. Review packs make outcomes inspectable. Merge queue serializes integration. Humans approve every merge. Secrets are protected.

#### Entry Conditions

- Phase 2 complete. Dispatch → stream → complete flow working end to end.

#### Tasks

**3.1 — Acceptance checks** (`pnevma-core`)

- Check runner: for each `Check` on a task contract, execute it:
  - `TestCommand`: run the shell command in the worktree, check exit code.
  - `FileExists`: verify path exists in the worktree.
  - `ManualApproval`: flag for human review (shown on task card).
- Checks run automatically when agent reports `Complete`.
- Results stored as events. Pass/fail displayed on task card.
- Gate: task cannot transition to Review unless all automated checks pass. Failed checks keep task in InProgress with a "checks failed" indicator and details.

**3.2 — Review pack generation** (`pnevma-core`)

- When task transitions to Review (all checks passed), generate a review pack:
  - Changed files list (from `git diff` against base branch).
  - Diff summary (insertions, deletions, file count).
  - Full diff content (stored on disk, referenced by path).
  - Acceptance check results.
  - Risk notes (heuristic): flag files > 500 lines changed, new dependencies added, config file modifications.
  - Agent rationale: from `Complete` event summary.
  - Context manifest: what was sent to the agent (from context v1 file).
  - Cost summary.
- Store as JSON + diff files at `.pnevma/data/reviews/<task-id>/`.
- Link from reviews table.

**3.3 — Review pane** (`frontend/`)

- Dedicated pane type for reviewing a task's output.
- Displays review pack contents in sections: summary → diff → tests → risks → costs.
- Diff displayed inline (full diff pane comes in Phase 5).
- Approve button → task enters merge queue. Reject button → task back to InProgress with notes.
- Keyboard: `a` approve, `r` reject, `Tab` switch sections, `j/k` scroll.

**3.4 — Merge queue** (`pnevma-core` + `frontend/`)

- Merge queue pane: lists tasks in Review-approved status, ordered by approval time.
- Merges are serialized: tokio mutex ensures one merge at a time.
- Merge flow:
  1. Rebase worktree branch on target branch.
  2. Re-run acceptance checks in rebased state.
  3. If checks pass: fast-forward or merge commit into target. Clean up worktree. Task → Done.
  4. If rebase conflicts: surface in review pane, block merge (see 3.5).
  5. If checks fail after rebase: block merge, notify user.
- Human must click "merge" to initiate. No auto-merge.

**3.5 — Conflict resolution** (`pnevma-git`)

- Detect rebase conflicts. List conflicting files in the review pane.
- Resolution options:
  - Manual: open conflicting files in a terminal pane with the user's editor.
  - Re-dispatch: send the task back to an agent with conflict context (file list, conflict markers).
- Merge queue blocks on unresolved conflicts. Does not proceed to next item.
- Dirty worktree detector: before merge attempt, verify worktree is clean. If dirty, warn and require user action.

**3.6 — Secrets service** (`pnevma-core`)

- macOS Keychain integration via `security-framework` crate.
- SQLite stores only secret references: name, scope (project or global), keychain item identifier.
- Just-in-time injection: when spawning a session or agent, resolve secret references and inject as environment variables.
- Redaction middleware: a `tracing` layer that strips values matching known secret patterns before writing to logs or event payloads.
- Redaction also applies to: scrollback persistence, replay output, and context pack export.
- **Note:** Moved from Phase 1 because it's not blocking for the core demo. Sessions work without secrets in Phase 1–2 (user sets env vars manually). Phase 3 adds managed secrets.

**3.7 — Checkpoints** (`pnevma-core` + `pnevma-git`)

- Auto-checkpoint before risky operations: rebase, merge. Checkpoint = git tag (`pnevma/checkpoint/<id>`) + session metadata snapshot (JSON).
- Manual checkpoint via command palette: `Create Checkpoint` with user-provided description.
- Checkpoint restore: reset to the git tag, restore session metadata from snapshot. List available checkpoints with descriptions and timestamps.
- Checkpoints table in DB tracks all checkpoints per project/task.

**3.8 — Agent attention notifications** (`pnevma-core` + `pnevma-app` + `frontend/`)

- Parse terminal output for common agent notification OSC sequences (`9`, `99`, `777`) and normalize into structured notification events.
- Add notifications table + query commands for unread/read state.
- Build a notification panel with keyboard flow: open panel, mark read, jump to latest unread, jump to associated pane/session/task.
- Surface lightweight attention signals in pane chrome (badge/ring) when unread notifications exist.
- Add socket/CLI methods: `notification.create`, `notification.list`, `notification.mark_read`, `notification.clear`.
- Redaction applies to notification payloads before persistence/event emission.
- **Deliverable:** Users can reliably see and navigate "agent needs attention" signals across multiple active sessions.

#### Deliverables

- `pnevma-core`: acceptance checker, review pack generator, merge queue, secrets service, checkpoints, notification normalization.
- `pnevma-git`: conflict detection, resolution flow, dirty worktree checks.
- `pnevma-app`: notification socket/CLI command routing.
- `frontend/`: review pane, merge queue pane, notification panel + unread indicators.

#### Acceptance Criteria

- Acceptance checks run on agent completion and gate entry to Review.
- Review packs show diffs, test results, risk notes, and cost summaries.
- Merges serialize, require human approval, and block on conflicts or failing checks.
- Rebase conflicts surface with clear resolution options (manual or re-dispatch).
- Secrets stored in macOS Keychain. Secret values redacted from all output paths.
- Checkpoints created before risky ops and restorable.
- Notification panel shows unread agent attention events and can jump to the originating pane/session.

---

### Phase 4: Recovery & Intelligence

**Goal:** The "what happened" layer. Replay any session. Detect stuck agents. Recover from interruptions. Get a daily brief. Full context compiler with token budgets.

#### Entry Conditions

- Phase 3 complete. Review and merge flow working.

#### Tasks

**4.1 — Session replay timeline** (`frontend/` + `pnevma-core`)

- Timeline pane for any past session: scrollable view showing terminal output chunks interleaved with structured events (tool use, status changes, cost updates, git operations).
- Navigable by time (scrub bar) and by event type (filter toggles).
- Reconstructed from the append-only event log plus scrollback chunk files.
- Click any event to see full details.

**4.2 — Stuck detection and recovery** (`pnevma-session`)

- Heuristics (all configurable):
  - Prolonged inactivity: no output for N minutes (default: 10).
  - Loop detection: repeated identical tool calls (same name + input > 3 times).
  - Error loop: same error message > 3 times.
  - Token burn: excessive usage without meaningful file changes.
- When stuck detected: transition session health to Stuck, emit event, surface recovery panel in UI.
- Recovery options: retry from last good state, interrupt and handoff to different provider, narrow scope and retry, restore from checkpoint.

**4.3 — Handoff summaries** (`pnevma-core`)

- On task pause, fail, or owner change: generate or request a handoff summary.
- Auto-generated: extract last N lines of agent output + summary of files changed.
- Stored on the task's `handoff_summary` field.
- Included in future context packs for the same task (enables agent-to-agent handoff).

**4.4 — Full context compiler** (`pnevma-context`)

- Priority-ordered assembly per the V2 spec in interface contracts.
- Token budget enforcement: configurable per provider in `pnevma.toml`.
- Context manifest: what included, what omitted, why. Stored with agent run record.
- Replaces the simplified V1 context from Phase 2.
- Manifest visible in review packs.

**4.5 — Daily brief** (`frontend/` + `pnevma-core`)

- On project open: display a brief pane showing:
  - Changes since last active session.
  - Task progress (which moved, which are blocked).
  - Cost incurred since last session.
  - Recommended next actions (ready tasks, pending reviews, unresolved conflicts).
- Generated from event log queries + task state.
- Links to jump directly to relevant tasks, reviews, or replay timelines.

**4.6 — AI-assisted task drafting** (`pnevma-core` + `pnevma-agents`)

- User describes work in natural language via command palette or task board.
- System dispatches a short agent call to draft a `TaskContract` (goal, scope, acceptance criteria, constraints).
- User reviews and edits the draft before saving.
- Uses the configured default agent provider.

#### Deliverables

- `pnevma-context`: full context compiler with token budgets and manifest.
- `pnevma-session`: stuck detection heuristics and recovery actions.
- `frontend/`: replay timeline, daily brief, AI task drafting UI, recovery panel.

#### Acceptance Criteria

- Replay shows navigable timeline of output + events for any session.
- Stuck detection triggers within configured timeout. Recovery options offered.
- Handoff summaries persist across task reassignment.
- Context compiler enforces token budgets. Manifest is accurate and visible.
- Daily brief renders accurate status on project open with actionable links.
- AI task drafting produces editable contracts from natural language.

---

### Phase 5: Polish, Packaging & Beta

**Goal:** Make Pnevma faster than the duct-tape workflow. Package for distribution. Ship to design partners for structured feedback.

#### Entry Conditions

- Phase 4 complete. Daily dogfooding on the Pnevma project itself confirms the tool is usable.

#### Tasks

**5.1 — Full-text search pane.** Project-wide search across tasks, events, commit messages, artifacts, scrollback. Results link to source. Keyboard-driven. Target: < 500ms for projects up to 100k events.

**5.2 — File browser pane.** Project file tree with git status indicators (modified, staged, conflicted). Fuzzy filename search. File selection opens in configured editor or read-only preview.

**5.3 — Diff review pane.** Dedicated diff viewer with side-by-side and inline views. Navigable by file and hunk with keyboard shortcuts. Replaces the inline diff in the review pane.

**5.4 — Layout templates.** Named pane arrangements: Solo Focus (terminal + board), Review Mode (board + diff + merge queue), Debug (terminal + replay + events). Users can create, save, and apply custom templates.

**5.5 — Rule and convention manager.** Pane for viewing, creating, editing, and toggling project rules and conventions. Shows which context packs include each rule.

**5.6 — Knowledge capture.** Post-merge prompt to promote findings: ADRs, changelog entries, updated conventions. Stored as artifacts, included in future context packs.

**5.7 — Keyboard UX audit.** Every flow audited for keyboard-first operation. All primary actions reachable within 2 keystrokes from command palette. Customizable keybindings.

**5.8 — macOS packaging.** Signed .app bundle with notarization. Auto-update via Tauri's built-in updater. First-launch setup: check for git, check for agent CLIs, create global config, offer project init.

**5.9 — Onboarding flow.** Guided first-project experience: create project → create task → dispatch → review → merge. Contextual hints for command palette, shortcuts, key concepts.

**5.10 — Documentation.** Getting-started guide. `pnevma.toml` reference. Keyboard shortcut reference. Architecture overview for contributors.

**5.11 — Opt-in telemetry.** Anonymous: session counts, feature usage, crash reports, performance. No code or content transmitted. Off by default, explicit opt-in.

**5.12 — Testing and quality gates.** Custom IPC test harness for integration tests: session restore under fault injection (process crash, disk full, corrupt scrollback). `proptest` for merge queue invariants (concurrent merges, conflicting branches, failed checks) and worktree lease enforcement. Secret redaction verified across all output paths. End-to-end system test: create project → plan tasks → dispatch agents → review → merge → replay — all driven over IPC.

**5.13 — Design partner program.** Recruit 5–10 target users. In-app feedback, weekly surveys, direct channel. Biweekly feedback sessions. Track retention, daily active use, and friction.

#### Acceptance Criteria

- Search returns results within 500ms across 100k events.
- All primary workflows keyboard-operable.
- macOS .app installs, launches, auto-updates.
- New user completes onboarding and dispatches first agent within 10 minutes.
- Session restore > 95% success rate under fault injection.
- Secret redaction 100% pass rate.
- Merge queue catches all pre-merge failures in property-based tests.
- 5–10 design partners actively using Pnevma.

---

## 8. Risks and Mitigations

| Risk | Why It Matters | Mitigation |
|---|---|---|
| xterm.js latency in webview | If typing feels sluggish, power users will reject Pnevma | Phase 0 spike with hard latency threshold (< 50ms). Fallback to native terminal widget if needed. |
| Tauri webview limitations | Platform webview inconsistencies, limited native access | macOS-first (WebKit is consistent). Defer Linux/Windows until Tauri 2.x stabilizes cross-platform. |
| Scope creep | Too many pane types and workflows dilute the wedge | V1 scope frozen around execution loop. No new pane types without proven daily-use need. |
| Provider churn | Agent CLIs change rapidly | Thin adapter trait. Minimize provider-specific assumptions. Pin CLI versions in tests. |
| Merge chaos | Parallel agent work increases conflict risk | One-task-one-worktree. Serialized merge queue. Pre-merge rebase + re-check. |
| Low trust in automation | Users abandon if outcomes feel unsafe | Human approval at every merge. Review packs. Checkpoints. Replay for auditability. |
| Secret leakage | A single incident damages adoption permanently | macOS Keychain. Reference-only DB storage. Redaction middleware on all output paths. |
| Context quality | Bad context packs produce bad agent work | Token-budgeted compiler (v2) with priority ordering. Visible manifest. User override. |
| Conflict recovery | Rebase conflicts block the workflow | Dedicated conflict resolution flow. Re-dispatch to agent with conflict context. |
| Unbounded agent costs | Concurrent agents burn money without user awareness | Configurable pool limit (default 4). Per-task cost display. "Tracking unavailable" honesty. |
| Local control socket abuse | External automation API expands attack surface | Unix socket `0600`, peer UID validation, optional password mode, full request audit events, kill-switch in config. |
| Notification overload | Too many alerts create fatigue and are ignored | Scope notifications to agent attention events, unread queue, per-source mute controls, and keyboard triage flow. |
| Local model support gap | Power users want offline/local agents | Adapter trait accommodates billing-less agents. Ollama adapter is post-v1. |
| Frontend complexity | React panes (board, diff, review) become the majority of code | Keep panes independent. Each pane is a self-contained component with its own hooks. Don't share state between panes except through the backend. |

---

## 9. Success Metrics

### Product Metrics

- Time to restore a project workspace after restart: under 10 seconds.
- Time from task dispatch to live agent session in terminal: under 5 seconds.
- Time from agent attention signal to visible unread notification in UI: under 1 second.
- Percentage of tasks completed without manual context reconstruction: rising month over month.
- Design partner retention after 4 weeks: target 70% or higher.

### Engineering Metrics

- Session restore success rate: above 95%.
- Merge queue failures caught before merge: above 90%.
- Secret redaction test pass rate: 100%.
- Median UI response time for pane switches: under 100ms.
- Full-text search response time: under 500ms for projects up to 100k events.
- Terminal input latency (typing in xterm.js): under 50ms perceived.
- Local socket API median request latency: under 100ms for non-streaming commands.

---

## 10. Deferred Capabilities

The following are explicitly out of scope for v1. Documented to prevent scope creep.

- Team collaboration and shared agent pools.
- Cloud sync across machines.
- Theme marketplace and plugin marketplace.
- Design contract visual tooling.
- Semantic search with local embeddings.
- Agent-to-agent messaging.
- Full SSH manager depth.
- Windows and Linux support (Linux is second priority after macOS is solid, Windows later).
- Local model adapters (Ollama, llama.cpp) — adapter contract supports this, but implementation is post-v1.
- Auto-merge (always human-approved in v1).
- Multi-repo projects (one project = one git repo in v1).
- In-app browser pane and browser automation APIs (explicitly deferred; terminal/task execution loop stays primary in v1).

---

## 11. Potential Features (Optional Backlog)

These are optional candidates identified from external implementation review and are **not** part of the locked v1 scope unless explicitly promoted into a phase.

| Feature | Why It May Help | Suggested Timing |
|---|---|---|
| Control-plane auth hardening (constant-time password comparison) | Reduces timing side-channel risk in socket password mode; aligns with high-trust local automation surface | Phase 5 hardening follow-up |
| Control-plane auth regression suite | Add explicit unauthorized/authorized route checks for local socket methods to prevent silent security regressions | Phase 5.12 extension |
| Event-delta frontend updates (reduce full refresh fan-out) | Replace frequent full `refreshProjectData()` calls with targeted store updates for task/session/notification events to improve UI responsiveness under high event volume | Phase 5 performance pass |
| Visibility-aware fallback polling with backoff | Keeps UI state fresh when event streams are interrupted while avoiding unnecessary polling when hidden/offline | Phase 5 reliability pass |
| List/search/export limit-cap contract tests | Enforce bounded result sizes across command and control surfaces to prevent accidental unbounded queries and latency spikes | Phase 5.12 extension |
| Machine-readable control API manifest + contract tests | Publish a generated method/params manifest for `pnevma ctl`; test that registered commands/methods stay in sync and documented | Phase 5 docs + quality |
| IPC harness shared fixture helpers | Reusable test helpers for creating projects/tasks/sessions and cleanup to speed up integration coverage growth | Phase 5.12 extension |
| Integration event sink (webhook-style export, local-first) | Optional structured event forwarding for partner analytics and incident tooling without changing core local-first execution loop | Post-beta |
