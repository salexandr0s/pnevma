# Mission: Build ClawControl-Sourced Features for Pnevma

You are implementing 8 new features for **Pnevma**, a terminal-first execution workspace for agent-driven software delivery. These features were identified from ClawControl (a sibling project) and have been integrated into the buildplan at `buildplan-v2.md`.

Read `buildplan-v2.md` thoroughly before starting. It is the source of truth for architecture, conventions, data model, and phase structure.

---

## Project Context

- **What Pnevma is:** A Tauri 2.x desktop app (Rust backend + React frontend) that lets developers dispatch AI coding agents into isolated git worktrees, stream their output in terminal panes, review results, and merge safely.
- **Tech stack:** Rust (tokio, sqlx, thiserror/anyhow, tracing) · SQLite · Tauri 2.x IPC · React 18 · TypeScript (strict) · Zustand · TailwindCSS · xterm.js
- **Codebase layout:**
  - `crates/pnevma-core/` — project model, task engine, events, dispatch, state machines
  - `crates/pnevma-session/` — PTY supervisor, scrollback, health
  - `crates/pnevma-agents/` — adapter trait, Claude Code/Codex adapters, throttle pool
  - `crates/pnevma-git/` — worktree lifecycle, merge queue
  - `crates/pnevma-context/` — context compiler, token budgets
  - `crates/pnevma-db/` — SQLite schema, migrations, typed queries (sqlx)
  - `crates/pnevma-ssh/` — SSH key management
  - `crates/pnevma-app/` — Tauri shell, 100+ IPC commands, control socket, state glue
  - `frontend/src/panes/` — one directory per pane type
  - `frontend/src/components/` — shared UI components
  - `frontend/src/hooks/` — React hooks for Tauri IPC
  - `frontend/src/stores/` — Zustand stores
  - `frontend/src/lib/` — utilities, types

---

## Features to Build (8 total, in dependency order)

### Build Order

Execute in this order. Each group can be parallelized internally, but groups must be sequential.

```
Group A (foundations — no cross-dependencies):
  1. Cost Aggregation Pipeline (enhances existing 2.7)
  2. Kanban Drag-Drop (enhances existing 2.2)
  3. Protected Action Modal (new 3.9)

Group B (depends on cost aggregation):
  4. Error Signature Aggregation (new 4.7)
  5. Operation Stories / Loop Tracking (new 4.8)

Group C (depends on everything above):
  6. Workflow Engine (new 6.1)
  7. Agent Team Hierarchy (new 6.3)

Group D (depends on 6.1 + cost aggregation + error aggregation):
  8. Workflow Visualization Pane (new 6.2)
  9. Usage Analytics Dashboard (new 6.4)
```

---

### Feature 1: Cost Aggregation Pipeline

**Location:** `pnevma-core` + `pnevma-db`
**Enhances:** Phase 2.7 cost tracking (already has `CostRecord` and basic per-task/per-session tracking)

**What to build:**

1. **New DB tables** (add as sqlx migrations in `pnevma-db`):

   ```sql
   CREATE TABLE cost_hourly_aggregates (
     id TEXT PRIMARY KEY,
     project_id TEXT NOT NULL REFERENCES projects(id),
     provider TEXT NOT NULL,
     model TEXT NOT NULL,
     tokens_in INTEGER NOT NULL DEFAULT 0,
     tokens_out INTEGER NOT NULL DEFAULT 0,
     estimated_usd REAL NOT NULL DEFAULT 0.0,
     session_count INTEGER NOT NULL DEFAULT 0,
     period_start TEXT NOT NULL, -- ISO 8601 hour-truncated
     UNIQUE(project_id, provider, model, period_start)
   );

   CREATE TABLE cost_daily_aggregates (
     id TEXT PRIMARY KEY,
     project_id TEXT NOT NULL REFERENCES projects(id),
     provider TEXT NOT NULL,
     model TEXT NOT NULL,
     tokens_in INTEGER NOT NULL DEFAULT 0,
     tokens_out INTEGER NOT NULL DEFAULT 0,
     estimated_usd REAL NOT NULL DEFAULT 0.0,
     session_count INTEGER NOT NULL DEFAULT 0,
     period_start TEXT NOT NULL, -- ISO 8601 date
     UNIQUE(project_id, provider, model, period_start)
   );
   ```

2. **Aggregation logic** in `pnevma-core`:
   - `aggregate_costs_hourly(project_id)` — rolls up raw `costs` rows into hourly buckets by (provider, model, hour). Uses `INSERT OR REPLACE` / upsert pattern.
   - `aggregate_costs_daily(project_id)` — same for daily buckets.
   - Trigger aggregation: (a) on every `AgentEvent::Complete`, (b) on a 15-minute background tick via tokio interval.

3. **New Tauri commands** in `pnevma-app`:
   - `get_usage_breakdown(project_id, period)` → `{ by_provider: [...], by_model: [...], total_usd, total_tokens_in, total_tokens_out }`
   - `get_usage_by_model(project_id)` → `[{ provider, model, total_usd, total_tokens_in, total_tokens_out, task_count }]`
   - `get_usage_daily_trend(project_id, days)` → `[{ date, usd, tokens_in, tokens_out }]`

4. **Token efficiency metrics:** tokens_per_task_completed, tokens_per_file_changed. Computed at query time from existing costs + tasks + agent_runs tables.

**Verification:** `cargo test` passes. Aggregation produces correct rollups from seed cost data. Commands return expected shapes.

---

### Feature 2: Kanban Drag-Drop

**Location:** `frontend/src/panes/task-board/`
**Enhances:** Phase 2.2 task board (already has kanban columns + keyboard nav)

**What to build:**

1. **Install dependency:** `npm install @dnd-kit/core @dnd-kit/sortable @dnd-kit/utilities`

2. **Wrap the kanban board** with `DndContext` from `@dnd-kit/core`. Each column is a `useDroppable`. Each card is a `useDraggable` (or `useSortable` for reordering within a column).

3. **On drop across columns:** Extract the target column's status. Invoke the existing `update_task` Tauri command with the new status. If the backend rejects the transition (invalid state machine move), show a toast error and snap the card back to its original position.

4. **Visual feedback:** Drag overlay shows a semi-transparent copy of the card. Drop targets highlight when a valid card is hovering. Invalid drop targets (e.g., "Done" column for a task not in "Review") show a red indicator.

5. **Preserve keyboard-first:** All existing keyboard shortcuts (`n`, `e`, `d`, `Enter`, `x`, arrows) must continue to work. Drag-drop is additive, not a replacement.

6. **Accessibility:** `@dnd-kit` provides built-in keyboard drag support (space to pick up, arrows to move, space to drop). Ensure ARIA attributes are present.

**Verification:** `npx tsc --noEmit` passes. `npx eslint .` passes. Manual test: drag a card from "Planned" to "Ready" → backend updates. Drag a card to "Done" from "Planned" → rejected, card snaps back.

---

### Feature 3: Protected Action Modal

**Location:** `pnevma-core` (Rust) + `frontend/src/components/` (React)

**What to build:**

1. **Rust: Action risk registry** in `pnevma-core/src/actions.rs` (new file):

   ```rust
   #[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
   #[serde(rename_all = "snake_case")]
   pub enum RiskLevel { Safe, Caution, Danger }

   #[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
   #[serde(rename_all = "snake_case")]
   pub enum ActionKind {
       // Danger
       MergeToTarget, DeleteWorktreeWithChanges, ForcePush,
       DeleteTaskWithActiveSession, PurgeScrollback,
       // Caution
       RestartStuckAgent, DiscardReview, RedispatchFailedTask,
       BulkDeleteCompletedTasks,
       // Safe
       CreateTask, DispatchReadyTask, OpenPane, CreateCheckpoint,
   }

   impl ActionKind {
       pub fn risk_level(&self) -> RiskLevel { /* match arms */ }
       pub fn confirmation_phrase(&self, context: &str) -> Option<String> {
           // Only for Danger: returns the phrase the user must type
           // e.g., for MergeToTarget: "merge {branch_name}"
       }
       pub fn description(&self) -> &'static str { /* human-readable */ }
       pub fn consequences(&self) -> &'static str { /* what can't be undone */ }
   }
   ```

2. **Rust: Tauri command** `check_action_risk(action_kind, context_json)`:
   - Returns `{ risk_level, description, consequences, confirmation_phrase: Option<String> }`.
   - Does NOT execute the action. Frontend uses this to decide which modal to show.

3. **Rust: Event emission** — After any protected action is confirmed and executed, emit `ProtectedActionApproved` or `ProtectedActionRejected` event with actor, action_kind, risk_level, timestamp.

4. **Frontend: `ProtectedActionModal` component** in `frontend/src/components/ui/protected-action-modal.tsx`:
   - Props: `actionKind`, `context`, `onConfirm`, `onCancel`.
   - On mount, calls `check_action_risk` to get risk info.
   - For `caution`: standard modal with description + consequences + "Confirm" / "Cancel" buttons.
   - For `danger`: modal with description + consequences + a text input. User must type the exact `confirmation_phrase`. "Confirm" button is disabled until the input matches exactly. Show a character-by-character match indicator.
   - Keyboard: `Enter` confirms (if enabled), `Escape` cancels.

5. **Integration:** Wire the modal into all existing flows that perform danger/caution actions. Identify these by searching the codebase for direct calls to merge, delete-worktree, force-push, etc. Wrap them with the `ProtectedActionModal` check.

**Verification:** `cargo test` — unit tests for ActionKind risk levels and confirmation phrases. `npx tsc --noEmit` passes. Frontend: typed confirmation input rejects partial matches, accepts exact match.

---

### Feature 4: Error Signature Aggregation

**Location:** `pnevma-core` + `pnevma-db`

**What to build:**

1. **New DB tables:**

   ```sql
   CREATE TABLE error_signatures (
     id TEXT PRIMARY KEY,
     project_id TEXT NOT NULL REFERENCES projects(id),
     signature_hash TEXT NOT NULL,
     canonical_message TEXT NOT NULL,
     first_seen TEXT NOT NULL,
     last_seen TEXT NOT NULL,
     total_count INTEGER NOT NULL DEFAULT 1,
     sample_output TEXT, -- first 500 chars of raw output
     remediation_hint TEXT,
     UNIQUE(project_id, signature_hash)
   );

   CREATE TABLE error_signature_daily (
     id TEXT PRIMARY KEY,
     signature_id TEXT NOT NULL REFERENCES error_signatures(id),
     date TEXT NOT NULL, -- YYYY-MM-DD
     count INTEGER NOT NULL DEFAULT 0,
     UNIQUE(signature_id, date)
   );
   ```

2. **Error normalizer** in `pnevma-core/src/errors/` (new module):
   - `normalize_error(raw: &str) -> String` — Strip timestamps (ISO 8601, Unix epochs), PIDs, UUIDs, file paths with line numbers (`/path/to/file.rs:42:10`), hex addresses. Replace with placeholders (`<TIMESTAMP>`, `<PID>`, `<PATH>`, etc.).
   - `signature_hash(normalized: &str) -> String` — SHA-256 of the normalized message, truncated to 16 hex chars.

3. **Aggregation hook:** In the agent event handler (where `AgentEvent::Error` is processed), call the normalizer, upsert into `error_signatures` (increment `total_count`, update `last_seen`), and upsert into `error_signature_daily`.

4. **Remediation hints:** Pattern-match common error classes:
   - `timeout` / `ETIMEDOUT` → "Increase timeout in pnevma.toml or narrow task scope"
   - `rate limit` / `429` → "Reduce max_concurrent agents or add backoff"
   - `permission denied` / `EACCES` → "Check file permissions in worktree"
   - `test failure` / `FAIL` / `assertion` → "Run tests locally: `npm test` or `cargo test`"
   - `merge conflict` / `CONFLICT` → "Resolve conflicts manually or re-dispatch with conflict context"
   - Store hint on the `error_signatures` row.

5. **Tauri commands:**
   - `list_error_signatures(project_id)` → sorted by total_count desc, top 50
   - `get_error_signature(id)` → full detail including sample_output
   - `get_error_trend(project_id, days)` → `[{ date, total_errors, unique_signatures }]`

**Verification:** Unit tests: normalizer strips timestamps/PIDs/paths correctly. Hash is stable for equivalent messages. Aggregation increments correctly. Remediation hints match expected patterns.

---

### Feature 5: Operation Stories (Loop Tracking)

**Location:** `pnevma-core` + `pnevma-db` + `frontend/src/panes/task-board/`

**What to build:**

1. **New DB table:**

   ```sql
   CREATE TABLE task_stories (
     id TEXT PRIMARY KEY,
     task_id TEXT NOT NULL REFERENCES tasks(id),
     sequence_number INTEGER NOT NULL,
     title TEXT NOT NULL,
     status TEXT NOT NULL DEFAULT 'pending', -- pending|in_progress|done|failed|skipped
     started_at TEXT,
     completed_at TEXT,
     output_summary TEXT,
     UNIQUE(task_id, sequence_number)
   );
   ```

2. **Story model** in `pnevma-core`:
   - `StoryStatus` enum: `Pending`, `InProgress`, `Done`, `Failed`, `Skipped`
   - `TaskStory` struct with all fields from the table.
   - CRUD functions: `create_stories_for_task(task_id, items: Vec<String>)`, `update_story_status(story_id, status, output_summary)`, `list_task_stories(task_id)`.

3. **Story creation paths:**
   - **Manual:** When creating a task, user can provide a list of items (e.g., file paths). Each becomes a story.
   - **Dynamic detection:** In the agent event handler, watch for output patterns like `Processing file 3 of 8: user-profile.tsx` or `[3/8] Linting...`. Regex: `(?:(?:Processing|Running|Checking|Linting|Testing)\s+)?(?:file\s+)?(\d+)\s+(?:of|/)\s+(\d+)[:\s]+(.+)`. On first match, create stories if none exist. On subsequent matches, update story status.

4. **Task board integration:**
   - Task cards with stories show a progress bar: `████░░░░ 3/8` using a thin bar element below the card title.
   - On card expand (Enter), show individual story rows with status icons.
   - Failed stories are highlighted in red with their `output_summary`.

5. **Tauri commands:**
   - `list_task_stories(task_id)` → `Vec<TaskStory>`
   - `create_stories_for_task(task_id, items: Vec<String>)` → creates stories with sequence numbers
   - `update_story_status(story_id, status, output_summary)` → updates one story
   - `get_task_story_progress(task_id)` → `{ total, completed, failed, in_progress }`

**Verification:** Stories are created from items list. Dynamic detection regex matches common patterns. Progress bar renders correctly. Failed stories surface with summaries.

---

### Feature 6: Workflow Engine

**Location:** `pnevma-core` + `pnevma-db` + new file `.pnevma/workflows/`

**This is the largest feature. Read buildplan-v2.md section 6.1 carefully.**

**What to build:**

1. **New DB tables:**

   ```sql
   CREATE TABLE workflows (
     id TEXT PRIMARY KEY,
     project_id TEXT NOT NULL REFERENCES projects(id),
     name TEXT NOT NULL,
     description TEXT,
     definition_yaml TEXT NOT NULL,
     active INTEGER NOT NULL DEFAULT 1,
     created_at TEXT NOT NULL,
     updated_at TEXT NOT NULL,
     UNIQUE(project_id, name)
   );

   CREATE TABLE workflow_runs (
     id TEXT PRIMARY KEY,
     workflow_id TEXT NOT NULL REFERENCES workflows(id),
     project_id TEXT NOT NULL REFERENCES projects(id),
     status TEXT NOT NULL DEFAULT 'pending', -- pending|running|completed|failed|paused
     started_at TEXT,
     completed_at TEXT,
     stage_results_json TEXT -- serialized map of stage_id -> { status, task_id, started_at, completed_at }
   );
   ```

2. **Workflow definition parser** in `pnevma-core/src/workflows/` (new module):
   - Parse YAML into `WorkflowDefinition` struct using `serde_yaml`.
   - Validate: stage IDs unique, `depends_on` references exist, no cycles (topological sort), stations are known.
   - Schema as defined in buildplan section 6.1.

3. **Workflow execution engine:**
   - `dispatch_workflow(workflow_id, params)`:
     1. Parse workflow definition.
     2. Create a `workflow_runs` row (status: running).
     3. For each stage, create a task (via existing task model) with dependencies wired from the stage's `depends_on`.
     4. Kick the dispatch orchestrator — stages with no unmet deps get dispatched immediately (respecting `parallel_limit`).
   - **Stage completion hook:** When a task completes (transitions to Done), check if it's part of a workflow run. If so, update `stage_results_json`, check if all stages are done → mark workflow run as completed. Check if newly-unblocked stages can dispatch.
   - **Conditional execution:** If stage has `when:` clause, evaluate it using simple template substitution (`{{prev.files_changed}}`) against the previous stage's results. Skip if condition is false.
   - **Loop support:** If stage has `for_each:`, create operation stories (Feature 5) for each item.
   - **Failure handling:** Configurable via `on_failure`: `pause` (stop workflow, notify user), `retry_once` (re-dispatch the failed stage once), `skip` (mark stage as skipped, continue).

4. **Built-in templates:** Create 3 YAML files:
   - `feature-pipeline.yaml` — spec → build → qa → ship
   - `bugfix.yaml` — reproduce → fix → verify
   - `compound.yaml` — parallel spec + build, then qa, then ship

5. **Workflow registry:** On project open, load workflows from `.pnevma/workflows/` and DB. Merge built-in + custom. Dedup by name (custom overrides built-in).

6. **Tauri commands:**
   - `list_workflows(project_id)`, `get_workflow(id)`, `create_workflow(name, definition_yaml)`, `update_workflow(id, definition_yaml)`
   - `dispatch_workflow(workflow_id, params_json)` → creates run + tasks
   - `get_workflow_run(run_id)` → full status with per-stage results
   - `list_workflow_runs(project_id)` → recent runs
   - `import_workflow(yaml_string)`, `export_workflow(id)` → YAML string

7. **Events:** `WorkflowDispatched`, `WorkflowStageStarted`, `WorkflowStageCompleted`, `WorkflowStageFailed`, `WorkflowStageSkipped`, `WorkflowCompleted`, `WorkflowFailed`.

**Verification:** YAML parsing validates correctly and rejects cycles. Dispatch creates tasks with correct dependency wiring. Stage completion triggers downstream stages. Conditional skip works. `on_failure: pause` halts the workflow.

---

### Feature 7: Agent Team Hierarchy

**Location:** `pnevma-core` + `pnevma-agents` + `pnevma-db`

**What to build:**

1. **New DB table:**

   ```sql
   CREATE TABLE agent_profiles (
     id TEXT PRIMARY KEY,
     project_id TEXT NOT NULL REFERENCES projects(id),
     name TEXT NOT NULL,
     provider TEXT NOT NULL,
     model TEXT NOT NULL,
     token_budget INTEGER NOT NULL DEFAULT 80000,
     timeout_minutes INTEGER NOT NULL DEFAULT 30,
     max_concurrent INTEGER, -- NULL = inherit global
     stations_json TEXT NOT NULL DEFAULT '[]', -- JSON array of station names
     config_json TEXT, -- extra provider-specific config
     active INTEGER NOT NULL DEFAULT 1,
     UNIQUE(project_id, name)
   );
   ```

2. **Profile model** in `pnevma-core/src/agents/profiles.rs` (new file):
   - `AgentProfile` struct.
   - `load_profiles_from_config(project_config)` — parse `[agents.profiles.*]` sections from `pnevma.toml` into `AgentProfile` rows. Upsert into DB on project open.
   - `load_team_config(project_config)` — parse `[agents.team]` section. Store team name, lead profile, member profiles.

3. **Dispatch matching** in `pnevma-agents`:
   - `recommend_profile(task: &TaskContract, profiles: &[AgentProfile]) -> Vec<(AgentProfile, f64)>`:
     1. Filter to active profiles.
     2. Score by: station affinity match (high weight), current pool availability (medium weight), cost preference — cheaper profiles scored higher when multiple match (low weight).
     3. Return ranked list.
   - Integrate into `dispatch_task`: if no profile override specified, use top recommendation. If override specified, use that profile.

4. **Per-profile WIP limits:** In the throttle pool, track concurrent sessions per profile name. A profile with `max_concurrent: 2` blocks new dispatches for that profile when 2 are running, even if the global pool has capacity.

5. **Tauri commands:**
   - `list_agent_profiles(project_id)` → `Vec<AgentProfile>`
   - `get_dispatch_recommendation(task_id)` → `Vec<{ profile_name, score, reason }>`
   - `override_task_profile(task_id, profile_name)` → sets profile for next dispatch
   - `get_agent_team(project_id)` → `{ name, lead, members }`

**Verification:** Profiles load from pnevma.toml. Station affinity matching returns correct rankings. WIP limits enforced per-profile. Override works.

---

### Feature 8: Workflow Visualization Pane

**Location:** `frontend/src/panes/workflow/` (new directory)

**What to build:**

1. **New pane type:** Register `workflow` in the pane type registry.

2. **DAG layout algorithm:**
   - Implement a simplified Sugiyama (layered) layout:
     1. Topological sort stages.
     2. Assign layers (stages with no deps = layer 0, others = max(dep layers) + 1).
     3. Position nodes within layers to minimize edge crossings (simple barycenter heuristic is fine).
   - Output: `{ nodes: [{ id, x, y, width, height }], edges: [{ from, to, points }] }`.

3. **SVG rendering:**
   - Nodes: `<rect>` with rounded corners + `<text>` for stage name + status icon.
   - Edges: `<path>` with arrow markers. Use cubic bezier for smooth curves.
   - Node colors by status: pending (gray-400), in_progress (blue-500 + pulse animation), done (green-500), failed (red-500), skipped (gray-300 + strikethrough text).

4. **Live updates:** Subscribe to workflow events (`WorkflowStageStarted`, `WorkflowStageCompleted`, etc.). Update node status in the Zustand store. SVG re-renders reactively.

5. **Node interaction:** Click a node → side panel or popover showing: task title, agent profile, cost, duration, acceptance check results, link to terminal pane.

6. **Gantt timeline:** Below the DAG, render a horizontal timeline. Each stage is a bar positioned by (started_at, completed_at). Parallel stages overlap visually. Shows total workflow duration.

7. **Static preview mode:** For workflows not yet dispatched, render the DAG from the YAML definition (no live status). Show stage names, dependencies, and estimated station types.

8. **Keyboard:** `Tab`/`Shift-Tab` cycle nodes, `Enter` opens detail, `Esc` closes, `f` fit-to-view, `+`/`-` zoom.

**Verification:** `npx tsc --noEmit` passes. DAG renders correctly for a 4-stage pipeline. Live status updates reflect in node colors. Keyboard navigation works.

---

### Feature 9: Usage Analytics Dashboard

**Location:** `frontend/src/panes/analytics/` (new directory)

**What to build:**

1. **New pane type:** Register `analytics` in the pane type registry.

2. **Data hooks:**
   - `useUsageBreakdown(projectId, period)` — calls `get_usage_breakdown`
   - `useUsageTrend(projectId, days)` — calls `get_usage_daily_trend`
   - `useModelComparison(projectId)` — calls `get_usage_by_model`
   - `useErrorHotspots(projectId)` — calls `list_error_signatures` (top 5)
   - All hooks poll on a 30-second interval or subscribe to relevant events.

3. **Views (tabs or scrollable sections):**
   - **Cost Overview:** Total spend (large number), daily trend bar chart (last 30 days), 7-day rolling average line. Breakdown by provider (stacked bar or horizontal bar chart).
   - **Token Efficiency:** Tokens per task completed, tokens per file changed. Trend sparkline.
   - **Model Comparison:** Table with columns: Profile, Provider, Model, Tasks, Avg Cost, Avg Duration, Success Rate. Sortable by any column.
   - **Error Hotspots:** Top 5 error signatures by frequency. Each row: canonical message (truncated), total count, last seen, remediation hint. Click to expand full detail.
   - **Session Analytics:** Avg duration, completion rate, stuck count, handoff rate. Simple metric cards.

4. **Charts:** Use lightweight SVG. For bar charts: `<rect>` elements positioned in a flex container. For trend lines: `<polyline>` or `<path>`. For sparklines: tiny `<svg>` inline. If SVG complexity is too high, use `recharts` (already common in React ecosystems) — but prefer SVG-only if feasible to avoid new deps.

5. **Time range selector:** Segmented toggle: Today | 7d | 30d | All Time. All charts update when changed.

6. **CSV export:** Button that calls a Tauri command to write aggregated data to a user-selected path.

7. **Keyboard:** `1`-`4` switch time ranges, `Tab` between sections, `e` export.

**Verification:** `npx tsc --noEmit` passes. Charts render with seed data. Time range switching updates all views. Export produces valid CSV.

---

## Conventions & Quality Gates

### Rust

- `thiserror` for typed errors in library crates, `anyhow` in `pnevma-app`
- All new DB tables go as sqlx migrations in `pnevma-db/migrations/`
- All new Tauri commands go in `pnevma-app/src/commands.rs` (or a sub-module if it's getting too large)
- All new event types added to the `EventType` enum in `pnevma-core`
- Use `tracing` for logging. Spans for new subsystems.
- Run after every 3-5 file changes:
  ```
  cargo fmt --check
  cargo clippy -- -D warnings
  cargo test
  ```

### TypeScript / React

- Strict mode. No `any`.
- New pane types go in `frontend/src/panes/<name>/` with an `index.tsx` entry.
- New shared components go in `frontend/src/components/ui/`.
- New hooks go in `frontend/src/hooks/`.
- State changes go through Tauri commands. Frontend never mutates state directly.
- Run after every component change:
  ```
  npx tsc --noEmit
  npx eslint .
  npx vite build
  ```

### Files

- `kebab-case.ts` for files, `PascalCase` for components, `use-` prefix for hooks.
- Named exports only.
- Colocate types with their module. Use `types.ts` only if shared across modules.

### Git

- Commit format: `type(scope): description`
- Examples: `feat(core): add error signature aggregation`, `feat(frontend): add workflow DAG pane`
- One logical unit per commit.

---

## Definition of Done (per feature)

1. Rust compiles clean: `cargo check --workspace && cargo clippy --workspace -- -D warnings`
2. Rust tests pass: `cargo test --workspace`
3. Frontend compiles clean: `npx tsc --noEmit && npx eslint . && npx vite build`
4. New tables have sqlx migrations
5. New Tauri commands are registered and callable from frontend
6. New events are emitted and visible in the event log
7. Feature integrates with existing UI (task board, review pane, etc.) where specified
8. No regressions in existing functionality
