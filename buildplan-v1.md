# Pnevma — Final Build Plan

**Agent-Era Terminal Workspace**
February 2026 · Confidential

---

## 1. Executive Summary

Pnevma is a local-first, project-aware terminal workspace for agent-driven software delivery. It is not an AI terminal with extra features. It is an execution system that makes multi-session, multi-agent software work reliable, inspectable, and fast.

The product wedge is narrow and deliberate: persistent terminal sessions, project-aware context, task orchestration, one-task-one-worktree execution, guarded review and merge flow, and searchable history with replay. Everything else is deferred until this core loop proves daily use.

This document is the final build specification. It defines the product, the architecture, every interface contract, and a concrete phased implementation plan written for an AI build agent to execute sequentially. Each phase has explicit entry conditions, deliverables, file-level outputs, and acceptance criteria.

### Core Thesis

The winning sequence is: build the execution core, prove session reliability, prove the task-to-agent-to-worktree flow, prove review and recovery, then expand. If Pnevma delivers that loop well, it becomes the operating system for agent-era development.

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

Build Pnevma around an event-driven Rust core and treat the terminal engine as a replaceable module. The core daemon owns all workflow logic. The UI shell is thin. The agent adapter layer is provider-neutral. The persistence layer uses SQLite for entities and an append-only event log for replay and audit.

### Terminal Engine Decision

Do not commit to a permanent Ghostty fork before validating three conditions:

1. Custom non-terminal panes can coexist cleanly with the terminal surface.
2. Session persistence and replay can be implemented without fighting the renderer.
3. Upstream maintenance cost stays acceptable.

If any condition fails during the feasibility spike, drop Ghostty and build on a thin PTY + GPU renderer (wgpu or similar) or adopt an embeddable base like WezTerm's terminal widget.

### System Components

| Component | Responsibility |
|---|---|
| UI Shell | Windows, panes, command palette, task board, diff view, search, settings. Thin layer that renders state from the daemon. |
| Core Daemon | Projects, sessions, tasks, events, orchestration, health state machine. All workflow logic lives here. |
| Agent Adapter Layer | Starts agents, sends input, captures usage, normalizes events. Provider-neutral contract. |
| Session Supervisor | Owns PTYs, scrollback persistence, replay, lifecycle management, heartbeats. |
| Git and Worktree Service | Branch creation, worktree mapping, task lease enforcement, merge queue, cleanup and garbage collection. |
| Context Compiler | Assembles task-specific prompt packs from project memory, rules, task data, and relevant files within a token budget. |
| Persistence Layer | SQLite for entities. Append-only event log on disk for replay and audit. |
| Secrets Service | OS keychain integration. Stores only references in SQLite. Just-in-time injection into session environments. |
| Search and Indexing | Full-text search over tasks, events, commits, and artifacts within a project. |

### Configuration

**Project-level:** Each project has a `pnevma.toml` at its root containing project metadata, agent preferences, rule paths, convention paths, and default branch policies. This file is version-controlled.

**Global:** A global `~/.config/pnevma/config.toml` stores user preferences: default agent provider, keybindings, theme, secrets backend reference, and telemetry opt-in.

**Rules and conventions:** Stored as markdown files within the project (default: `.pnevma/rules/` and `.pnevma/conventions/`). Referenced by path in `pnevma.toml`. Injected into agent context packs by the context compiler.

---

## 4. Interface Contracts

### Agent Adapter Trait

Every agent provider implements this contract. The system never calls provider-specific APIs directly.

```rust
trait AgentAdapter {
    fn spawn(config: AgentConfig) -> Result<AgentHandle>;
    fn send(handle: &AgentHandle, input: TaskPayload) -> Result<()>;
    fn interrupt(handle: &AgentHandle) -> Result<()>;
    fn stop(handle: &AgentHandle) -> Result<()>;
    fn events(handle: &AgentHandle) -> EventStream<AgentEvent>;
    fn parse_usage(handle: &AgentHandle) -> Result<CostRecord>;
}
```

**AgentConfig** contains: provider name, model identifier, environment variables (with secret refs resolved), working directory, and timeout settings.

**TaskPayload** contains: objective text, constraints, project rules (compiled), worktree path, branch name, acceptance checks, relevant file paths, and prior context summary.

**AgentEvent** is an enum: `OutputChunk(text)`, `ToolUse(name, input, output)`, `StatusChange(status)`, `Error(message)`, `UsageUpdate(tokens_in, tokens_out, cost_usd)`, `Complete(summary)`.

**CostRecord** contains: provider, model, tokens_in, tokens_out, estimated_cost_usd, timestamp, task_id, session_id.

V1 ships with two adapters: Claude Code and OpenAI Codex CLI. Additional adapters are added post-launch.

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

**Check** is: `{ description: String, check_type: TestCommand | FileExists | ManualApproval, command: Option<String> }`.

**ContextPack** is: `{ task_contract: TaskContract, project_brief: String, architecture_notes: String, conventions: Vec<String>, rules: Vec<String>, relevant_file_contents: Vec<(FilePath, String)>, prior_task_summaries: Vec<String>, token_budget: usize, actual_tokens: usize }`.

### Context Compiler Specification

The context compiler assembles a ContextPack for each task at dispatch time. It operates within a strict token budget per provider.

**Priority ordering** (highest to lowest): task contract fields (goal, scope, criteria, constraints), relevant file contents, project rules and conventions, architecture notes, prior completed-task summaries, project brief.

**Token budget:** Configurable per provider in `pnevma.toml`. Default: 80,000 tokens for Claude, 60,000 for Codex. The compiler fills from highest priority down, truncating or omitting lower-priority items when the budget is reached.

**Context manifest:** Every compiled pack includes a manifest listing exactly what was included and what was omitted with reason (budget exceeded, not relevant, excluded by rule). This manifest is stored with the agent run record and visible in the review pack.

**Recording:** The exact context pack sent to each agent run is persisted. This makes outcomes explainable and reproducible.

### Cost Tracking Specification

V1 tracks costs on a best-effort basis with explicit gaps.

- **Tracked:** Token counts and estimated USD cost where the provider CLI or API exposes usage data. Claude Code emits usage in its output stream. Codex may require parsing log files.
- **Attribution:** Every CostRecord is linked to a task_id and session_id. Aggregations are available per-task, per-session, and per-project.
- **Display:** Running cost total visible in the task board per task and in the project status bar.
- **Gaps:** When a provider does not expose token counts, the UI shows a clear "tracking unavailable" indicator rather than silently omitting. No silent zeros.

---

## 5. Data Model

All entities live in a per-project SQLite database. Heavy content (scrollback chunks, recordings, large logs) lives on disk with path references in SQLite.

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
| events | id, project_id, trace_id, source, event_type, payload_json, timestamp | Append-only log |
| checkpoints | id, project_id, task_id, git_ref, session_metadata_json, created_at, description | Snapshot before risky ops |
| reviews | id, task_id, status, review_pack_path, reviewer_notes, approved_at | Merge gate records |

### Event Log

The event log is the source of truth for replay and debugging. Every significant action emits a structured event: user actions, agent actions, git transitions, session lifecycle changes, acceptance check results, and cost updates. Events carry trace IDs at project, task, and session level for correlated querying.

---

## 6. Phased Build Plan

This plan is structured for sequential execution by an AI build agent. Each phase has explicit entry conditions, a task list with file-level deliverables, and acceptance criteria that must pass before proceeding. Phases are not time-estimated because the build is agent-driven. They are ordered by dependency.

---

### Phase 0: Feasibility Spike

**Goal:** De-risk three critical unknowns: terminal engine integration, PTY session persistence, and agent adapter feasibility. Produce a binary go/no-go decision on the terminal engine approach.

#### Entry Conditions

- Development environment set up: Rust toolchain, macOS target, SQLite, git.
- Ghostty source or libghostty available for evaluation.

#### Tasks

**0.1 — Terminal engine evaluation**

- Attempt to embed Ghostty or libghostty as a terminal surface within a custom Tauri or native macOS window.
- Attempt to render a non-terminal custom pane (simple task list view) alongside the terminal surface in the same window.
- **Decision gate:** If custom panes cannot coexist cleanly with the terminal surface, abandon Ghostty. Fall back to building on a PTY + wgpu renderer or WezTerm's terminal widget. Document the decision and rationale.

**0.2 — PTY session persistence prototype**

- Spawn a shell in a supervised PTY.
- Persist session metadata (pid, cwd, command, status) to a SQLite row.
- Append terminal output to a chunked scrollback file on disk.
- Kill and restart the app. Restore the pane with scrollback history visible. Reconnect to the shell process if still alive, or show the restored scrollback with a restart prompt.

**0.3 — Agent adapter proof of concept**

- Implement a minimal Claude Code adapter that: spawns the CLI, sends a simple task prompt, captures stdout/stderr, parses a usage/cost line from the output.
- Run the adapter inside a worktree created by a simple `git worktree add` command.
- Emit at least one structured AgentEvent from the adapter.

#### Deliverables

- `spike/terminal-eval/` — Prototype code and written evaluation of Ghostty integration viability.
- `spike/pty-persist/` — Working PTY supervisor with scrollback persistence and restore.
- `spike/agent-adapter/` — Minimal Claude Code adapter with event emission.
- `docs/decisions/001-terminal-engine.md` — ADR documenting the terminal engine decision.

#### Acceptance Criteria

- A custom non-terminal pane renders alongside a terminal session, OR a documented decision to use an alternative engine with working prototype of that alternative.
- App restart restores session metadata and scrollback from disk.
- Agent adapter spawns Claude Code in a worktree and emits at least OutputChunk and Complete events.

---

### Phase 1: Foundation

**Goal:** Establish the project model, persistence layer, event system, pane manager, command palette, and basic session UI. After this phase, Pnevma is a functional terminal with persistent named sessions and project-aware workspaces.

#### Entry Conditions

- Phase 0 complete. Terminal engine decision made and documented.

#### Tasks

**1.1 — Project model and persistence**

- Implement `pnevma.toml` parser for project configuration (project name, agent preferences, rule paths, convention paths, branch policies).
- Implement global config parser for `~/.config/pnevma/config.toml`.
- Create the SQLite schema for all entities defined in the data model section: projects, sessions, panes, tasks, task_dependencies, worktrees, agent_runs, artifacts, rules, costs, events, checkpoints, reviews.
- Implement the append-only event log writer with trace ID support (project, task, session scopes).
- Implement the event query API: filter by project, task, session, event_type, and time range.

**1.2 — Core daemon skeleton**

- Implement the daemon process that owns all workflow state.
- Expose an IPC interface (Unix socket or similar) for the UI shell to subscribe to state changes and send commands.
- Implement the project lifecycle: open project (load DB, load config), close project (flush state), list recent projects.

**1.3 — Session supervisor**

- Implement the PTY supervisor: spawn shell sessions, assign to projects, track pid/cwd/command/status.
- Implement session health state machine: Active, Idle, Waiting, Stuck, Error, Complete.
- Implement heartbeat emission on activity, idle timeout (configurable), exit, restart, and failure.
- Implement incremental scrollback persistence: chunked writes to disk, indexed for fast seek.
- Implement session restore on app restart: reload metadata from DB, restore scrollback, reconnect to live processes or prompt for restart.

**1.4 — UI shell: pane manager**

- Implement the window and pane layout system. Panes are typed (terminal, task-board, review, search, settings).
- Implement pane metadata model: id, session binding, type, position, label.
- Implement split, resize, close, swap, and focus operations via keyboard shortcuts.
- Persist pane layout to DB. Restore layout on app restart.

**1.5 — UI shell: command palette**

- Implement a fuzzy-search command palette triggered by a global keyboard shortcut.
- Commands include: new session, switch pane, open project, create task, search events, settings.
- Command palette is extensible: commands are registered by subsystems, not hard-coded.

**1.6 — Secrets service**

- Implement OS keychain integration (macOS Keychain) for storing secret material.
- Store only secret references (name, scope, keychain item ID) in SQLite.
- Implement just-in-time secret injection into session environments.
- Implement redaction middleware: any log write, replay output, or transcript export strips values matching known secret patterns.

#### Deliverables

- `src/core/` — Daemon, project model, event log, IPC interface.
- `src/session/` — PTY supervisor, scrollback persistence, health state machine.
- `src/ui/` — Pane manager, command palette, layout persistence.
- `src/secrets/` — Keychain integration, reference store, redaction.
- `src/db/` — SQLite schema, migrations, query layer.
- `pnevma.toml` — Example project config.
- `~/.config/pnevma/config.toml` — Example global config.

#### Acceptance Criteria

- User can open a project, create named terminal sessions, split panes, and use the command palette.
- Quitting and relaunching Pnevma restores the full workspace: pane layout, session scrollback, and session metadata.
- Events are written to the append-only log and queryable by project and session.
- Secrets stored in keychain are injected into session environments and redacted from log output.

---

### Phase 2: Core Execution Loop

**Goal:** Implement the task board, task contracts, agent dispatch, worktree lifecycle, and cost tracking. After this phase, a user can create a project, plan tasks, dispatch agents into isolated worktrees, and see state sync back to the board.

#### Entry Conditions

- Phase 1 complete. Persistent sessions and pane management working.

#### Tasks

**2.1 — Task board pane**

- Implement the task board as a native pane type backed by the tasks and task_dependencies tables.
- Board displays tasks grouped by status columns: Planned, Ready, In Progress, Review, Done, Failed, Blocked.
- Board updates reactively from events (not direct UI mutation).
- Users can create, edit, split, merge, reorder, and delete tasks via keyboard shortcuts and inline editing.
- Dependency visualization: blocked tasks show which dependencies are unmet.

**2.2 — Task contract enforcement**

- Implement the full TaskContract struct as defined in the interface contracts section.
- Validate task contracts on creation and on transition to Ready status: goal must be non-empty, acceptance_criteria must have at least one check, scope must reference existing files.
- AI-assisted task drafting: user can describe work in natural language, and the system drafts a task contract for human editing and approval.

**2.3 — Agent adapter layer**

- Implement the AgentAdapter trait as defined in the interface contracts section.
- Implement the Claude Code adapter: spawn, send TaskPayload, capture events (OutputChunk, ToolUse, StatusChange, Error, UsageUpdate, Complete), parse usage.
- Implement the Codex CLI adapter with the same contract.
- Implement adapter registration: the system discovers available adapters and lets the user select per-task or use the project default.

**2.4 — Context compiler**

- Implement the context compiler as defined in the interface contracts section.
- Assemble ContextPack from: task contract, relevant file contents, project rules, conventions, architecture notes, prior task summaries, project brief.
- Enforce token budget per provider with priority-ordered truncation.
- Generate and persist the context manifest showing what was included, what was omitted, and why.

**2.5 — Git worktree automation**

- When a task transitions to In Progress, automatically create a branch and git worktree.
- Branch naming convention: `pnevma/<task-id>/<slugified-title>`.
- Implement worktree lease manager: each worktree is locked to exactly one task. Show lease owner, last active time, and reclaim safety status.
- Implement stale lease detection: warn after configurable inactivity period. Offer reclaim.
- Implement worktree cleanup: on task completion or abandonment, remove worktree and optionally delete branch.

**2.6 — Agent dispatch orchestration**

- Implement the dispatch flow: user selects a Ready task, triggers dispatch. System creates worktree, compiles context, spawns agent via adapter, binds agent to a terminal pane, streams events to the event log.
- Implement handoff summary: when a task pauses, fails, or changes owner, the system requests or generates a summary of what was done and what remains. This summary is stored on the task and included in future context packs.

**2.7 — Cost tracking**

- Parse usage data from agent adapters and write CostRecord entries.
- Display per-task running cost in the task board.
- Display per-project total cost in the status bar.
- When a provider does not expose usage data, display a clear "tracking unavailable" indicator.

#### Deliverables

- `src/tasks/` — Task model, board pane, contract validation, dependency graph.
- `src/agents/` — Adapter trait, Claude Code adapter, Codex adapter, dispatch orchestrator.
- `src/context/` — Context compiler, token budget manager, manifest generator.
- `src/git/` — Worktree service, branch manager, lease manager, cleanup.
- `src/costs/` — Cost parser, aggregation, display.

#### Acceptance Criteria

- User can create a project, create tasks with full contracts, and see them on the board.
- Dispatching a task creates a worktree, compiles context, spawns the agent, and streams output to a terminal pane.
- Task board updates reactively as agent events arrive (status changes, completion).
- Context manifest is visible and correctly reflects what was sent to the agent.
- Worktrees are leased to tasks and cleaned up on completion.
- Costs are tracked and displayed per-task where provider data is available.

---

### Phase 3: Review, Recovery, and Trust

**Goal:** Implement the merge queue, acceptance checks, review packs, checkpointing, replay timeline, handoff summaries, daily brief, and error recovery flows. After this phase, a user can safely review, approve, and merge agent work, recover from interruptions, and understand what happened in any past session.

#### Entry Conditions

- Phase 2 complete. Task-to-agent-to-worktree flow working end to end.

#### Tasks

**3.1 — Acceptance checks**

- Implement acceptance check runner: for each Check on a task contract, execute the check (run test command, verify file exists, or flag for manual approval).
- Checks run automatically when an agent reports Complete.
- Results are stored as events and displayed on the task card.
- A task cannot enter Review status unless all automated checks pass.

**3.2 — Review pack generation**

- When a task enters Review status, generate a review pack: list of changed files, diff summary, tests run and results, risk notes (large file changes, new dependencies, config modifications), agent rationale (extracted from agent's final summary), context manifest, and cost summary.
- Store the review pack as a structured artifact linked to the task.
- Display the review pack in a dedicated review pane.

**3.3 — Merge queue**

- Implement a merge queue pane that lists all tasks in Review status.
- Merges are human-approved. No auto-merge in v1.
- Merges are serialized: only one merge executes at a time to prevent conflicts.
- Before merge, run a pre-merge check: rebase on target branch, re-run acceptance checks. If checks fail, block merge and notify.
- After successful merge, clean up worktree and update task status to Done.

**3.4 — Conflict resolution flow**

- When a rebase produces conflicts, surface the conflicting files in the review pane.
- User can resolve manually (open in terminal pane with editor), or re-dispatch the task to an agent with conflict context.
- The merge queue blocks on unresolved conflicts and does not proceed to the next merge.
- Implement a dirty worktree detector: before any merge attempt, verify the worktree is clean. If dirty, warn and require user action.

**3.5 — Checkpoints and rollback**

- Implement checkpoint creation: before risky operations (rebase, large edit, merge), create a checkpoint consisting of a git ref (tag or branch pointer) plus session metadata snapshot.
- Users can manually create checkpoints at any time via command palette.
- Implement checkpoint restore: reset to the git ref and restore session metadata. List available checkpoints with descriptions and timestamps.

**3.6 — Session replay timeline**

- Implement a timeline view for any past session: scrollable, showing terminal output interleaved with structured events (tool use, status changes, cost updates, git operations).
- The timeline is navigable by time and by event type.
- Replay is reconstructed from the append-only event log plus scrollback chunks.

**3.7 — Stuck detection and recovery**

- Implement stuck detection heuristics: prolonged inactivity (no output for configurable duration), repeated identical tool calls (loop detection), repeated errors, excessive token usage without progress.
- When stuck is detected, transition the session health to Stuck and surface a recovery panel.
- Recovery options: retry from last good state, interrupt and handoff to a different agent/provider, narrow scope and retry, restore from checkpoint.

**3.8 — Daily brief and recovery view**

- When a user opens a project, show a daily brief pane: what changed since last active session, which tasks progressed, which are blocked, total cost incurred, and recommended next actions.
- The brief is generated from the event log and task state. It is the primary answer to "what happened while I was away?"
- The brief includes links to jump directly to relevant tasks, reviews, or replay timelines.

#### Deliverables

- `src/review/` — Acceptance checker, review pack generator, review pane, merge queue.
- `src/checkpoints/` — Checkpoint creation, restore, listing.
- `src/replay/` — Replay timeline view, event reconstruction.
- `src/recovery/` — Stuck detection, recovery actions, daily brief generator.
- `src/git/conflict.rs` — Conflict detection, resolution flow, dirty worktree checks.

#### Acceptance Criteria

- Acceptance checks run automatically on agent completion and gate entry to Review.
- Review packs contain diffs, test results, risk notes, and cost summaries.
- Merges are serialized, human-approved, and blocked on conflicts or failing checks.
- Rebase conflicts surface in the review pane with clear resolution options.
- Checkpoints can be created and restored, returning the project to a known good state.
- Session replay shows a navigable timeline of terminal output and structured events.
- Stuck sessions are detected and recovery options are offered.
- Daily brief renders on project open with accurate status and actionable links.

---

### Phase 4: Power-User Polish

**Goal:** Add the features that make Pnevma feel faster than the existing duct-tape workflow: full-text search, file browser, layout templates, diff review pane, knowledge capture, and stronger keyboard UX.

#### Entry Conditions

- Phase 3 complete. Review, merge, replay, and recovery flows working.

#### Tasks

**4.1 — Full-text search pane**

- Implement project-wide search across tasks, events, commit messages, artifacts, and scrollback history.
- Search pane opens via command palette with keyboard-driven navigation.
- Results link directly to the source: task card, replay timestamp, artifact file.

**4.2 — File browser and search pane**

- Implement a file browser pane showing the project file tree with status indicators (modified, staged, conflicted).
- Integrate file search (fuzzy filename matching) within the browser.
- File selection opens in the user's configured editor or in a read-only preview pane.

**4.3 — Diff review pane**

- Implement a dedicated diff viewer pane for reviewing changes per task.
- Supports side-by-side and inline diff views.
- Navigable by file and by hunk with keyboard shortcuts.

**4.4 — Layout templates**

- Implement savable layout templates: named pane arrangements that can be applied to any project.
- Ship default templates: Solo Focus (terminal + board), Review Mode (board + diff + merge queue), Debug (terminal + replay + events).
- Users can create, edit, and delete custom templates.

**4.5 — Policy and rule manager**

- Implement a rule management pane for viewing, creating, editing, and toggling project rules and conventions.
- Rules are stored as markdown files and referenced in `pnevma.toml`.
- The manager shows which rules are active and which context packs include them.

**4.6 — Knowledge capture**

- When a task is approved and merged, prompt the user to promote findings into project knowledge: architecture decision records, changelog entries, implementation patterns, updated conventions.
- Approved summaries are stored as artifacts and automatically included in future context packs for related work.

**4.7 — Keyboard UX audit**

- Audit every flow for keyboard-first operation: task creation, dispatch, review, merge, search, navigation.
- Ensure all primary actions are reachable within 2 keystrokes from the command palette.
- Implement customizable keybindings stored in global config.

#### Deliverables

- `src/search/` — Full-text indexing, search pane, result navigation.
- `src/ui/file_browser.rs` — File tree pane, status indicators, fuzzy search.
- `src/ui/diff_pane.rs` — Diff viewer with side-by-side and inline modes.
- `src/ui/layouts.rs` — Template system, defaults, save/load.
- `src/rules/` — Rule manager pane, CRUD operations, activation tracking.
- `src/knowledge/` — Knowledge capture flow, artifact promotion.

#### Acceptance Criteria

- Search returns relevant results across tasks, events, and scrollback within 500ms.
- File browser shows accurate git status and supports fuzzy search.
- Diff pane renders correct diffs with keyboard navigation.
- Layout templates save, load, and apply correctly.
- All primary workflows are operable without a mouse.
- Knowledge capture prompts appear after merge and promote content into project context.

---

### Phase 5: Packaging, Onboarding, and Beta

**Goal:** Package Pnevma for distribution, build onboarding flows, write documentation, add telemetry, and ship to design partners for structured feedback.

#### Entry Conditions

- Phase 4 complete. Daily dogfooding on the Pnevma project itself confirms the tool is faster than the duct-tape workflow.

#### Tasks

**5.1 — macOS packaging**

- Build a signed macOS .app bundle with notarization.
- Implement auto-update mechanism (Sparkle or similar).
- Implement first-launch setup: check for git, check for agent CLIs, create global config, offer to initialize a project.

**5.2 — Onboarding flow**

- Implement a guided first-project experience: create project, create first task, dispatch agent, review result, merge.
- Include in-app contextual hints for command palette, keyboard shortcuts, and key concepts (worktrees, task contracts, context packs).

**5.3 — Documentation**

- Write a getting-started guide covering installation, first project, and the core loop.
- Write a reference guide for `pnevma.toml` configuration, global config, keyboard shortcuts, and task contract schema.
- Write an architecture overview for contributors.

**5.4 — Telemetry**

- Implement opt-in anonymous telemetry: session counts, feature usage, crash reports, and performance metrics.
- No content or code is ever transmitted. Only aggregate usage patterns.
- Telemetry is off by default and requires explicit opt-in during setup.

**5.5 — Design partner program**

- Recruit 5–10 target users (solo builders using CLI agents).
- Provide structured feedback mechanisms: in-app feedback button, weekly survey, direct channel.
- Run feedback sessions every 1–2 weeks. Track retention, daily active use, and friction reports.

**5.6 — Testing and quality gates**

- Integration test suite for session restore (kill and restart under various states).
- Property-based tests for merge queue (concurrent merges, conflicting branches, failed checks).
- Fault injection tests for PTY supervisor (process crash, disk full, corrupt scrollback).
- Secret redaction verified across logs, replay, exports, and context packs.
- End-to-end demo: create project, plan tasks, dispatch agents, review, merge, replay, recover — all in one flow.

#### Deliverables

- `dist/` — macOS .app bundle, DMG installer, auto-update configuration.
- `docs/` — Getting started, reference, architecture guides.
- `src/telemetry/` — Opt-in telemetry system.
- `src/onboarding/` — First-project flow, contextual hints.
- `tests/` — Integration, property-based, fault injection, and e2e test suites.

#### Acceptance Criteria

- macOS .app installs, launches, and auto-updates successfully.
- A new user can complete the onboarding flow and dispatch their first agent within 10 minutes.
- Session restore success rate above 95% under fault injection.
- Merge queue catches all pre-merge failures in property-based tests.
- Secret redaction test pass rate at 100%.
- 5–10 design partners actively using Pnevma and providing feedback.

---

## 7. Risks and Mitigations

| Risk | Why It Matters | Mitigation |
|---|---|---|
| Terminal engine fork complexity | A deep fork consumes all available effort | Phase 0 spike with a hard decision gate. If Ghostty fails the test, drop it immediately. |
| Scope creep | Too many pane types and workflows dilute the wedge | V1 scope is frozen around the execution loop. No new pane types without proven daily-use need. |
| Provider churn | Agent CLIs change rapidly | Thin adapter protocol. Minimize provider-specific assumptions. Test adapters against pinned CLI versions. |
| Merge chaos | Parallel agent work increases conflict risk | One-task-one-worktree policy. Serialized merge queue. Pre-merge rebase and re-check. |
| Low trust in automation | Users abandon if outcomes feel unsafe | Human approval at every merge. Review packs. Checkpoints. Replay for auditability. |
| Secret leakage | A single incident damages adoption permanently | OS-native keychain. Reference-only DB storage. Redaction middleware on all output paths. |
| Context quality | Bad context packs produce bad agent work | Token-budgeted compiler with priority ordering. Visible context manifest. User override capability. |
| Conflict recovery | Rebase conflicts block the entire workflow | Dedicated conflict resolution flow. Option to re-dispatch to agent with conflict context. |
| Local model support gap | Power users want offline/local agent support | Adapter contract explicitly accommodates agents without cloud billing. Ollama adapter is post-v1 but the contract supports it from day one. |

---

## 8. Success Metrics

### Product Metrics

- Time to restore a project workspace after restart: under 10 seconds.
- Time from task click to live agent session: under 5 seconds.
- Percentage of tasks completed without manual context reconstruction: rising month over month.
- Design partner retention after 4 weeks: target 70% or higher.

### Engineering Metrics

- Session restore success rate: above 95%.
- Merge queue failures caught before merge: above 90%.
- Secret redaction test pass rate: 100%.
- Median UI response time for pane switches: under 100ms.
- Full-text search response time: under 500ms for projects up to 100k events.

---

## 9. Deferred Capabilities

The following are explicitly out of scope for v1. They are documented here to prevent scope creep and to guide post-launch planning.

- Team collaboration and shared agent pools.
- Cloud sync across machines.
- Theme marketplace and plugin marketplace.
- Design contract visual tooling.
- Semantic search with local embeddings.
- Agent-to-agent messaging.
- Full SSH manager depth.
- Windows and Linux support (Linux is second priority, Windows later).
- Local model adapters (Ollama, llama.cpp) — adapter contract supports this, but implementation is post-v1.
