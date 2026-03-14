# Agent Command Center Gap Analysis

> Tweet prompt: “tmux grids are awesome, but i feel a need to have a proper ‘agent command center’ IDE for teams of them, which I could maximize per monitor. E.g. I want to see/hide toggle them, see if any are idle, pop open related tools (e.g. terminal), stats (usage), etc.”

## Bottom line

Pnevma already has strong building blocks for this story: native split panes, workspace tabs, backend-managed sessions, task/worktree orchestration, replay, notifications, and usage analytics.

Pnevma **cannot yet honestly say “we got this”** for the tweet as written.

The biggest gaps are:

1. **No first-class live agent roster/dashboard**
2. **Only one backend-bound workspace is active at a time**
3. **No multi-window / per-monitor command-center model**
4. **Idle / stuck / waiting state exists in the backend but is not surfaced as an operator UI**
5. **No agent-centric deep links from “agent card” → terminal / diff / review / files / worktree**
6. **Stats exist mostly as historical analytics, not as live fleet telemetry and alerts**

## What Pnevma already covers

Pnevma is not starting from zero.

### Existing strengths

- **Native pane/grid foundation exists** via `native/Pnevma/Core/PaneLayoutEngine.swift` and `native/Pnevma/Core/ContentAreaView.swift`.
- **Show/hide/toggle primitives exist** for sidebar, right inspector, split zoom, full screen, and pane commands in `native/Pnevma/App/AppDelegate.swift`.
- **Terminal session management exists** via `native/Pnevma/Chrome/SessionManagerView.swift`, `native/Pnevma/Core/SessionStore.swift`, and `native/Pnevma/Core/SessionBridge.swift`.
- **Agent/task/worktree model exists** via `native/Pnevma/Panes/TaskBoardPane.swift`, `crates/pnevma-commands/src/commands/tasks.rs`, and the one-task-one-worktree rule.
- **Tool surfaces already exist** for task board, replay, files, review, diff, analytics, notifications, workflow/agents, browser, and SSH in `native/Pnevma/Panes/PaneProtocol.swift`.
- **Usage and provider data exists** via `native/Pnevma/Panes/AnalyticsPane.swift`, `native/Pnevma/Panes/ProviderUsageUI.swift`, and `crates/pnevma-commands/src/commands/analytics.rs`.
- **Session replay / recovery exists** via `native/Pnevma/Panes/ReplayPane.swift` and `crates/pnevma-session/src/supervisor.rs`.
- **Workspace metadata already tracks useful summaries** like branch, active tasks, active agents, cost today, and notifications in `native/Pnevma/Core/Workspace.swift` and `native/Pnevma/Core/WorkspaceManager.swift`.

That means the gap is not “build panes and terminals.” The gap is turning those parts into a **real-time operator console for many agents**.

## Why the current product falls short of the tweet

### 1. The UI is workspace-centric, not agent-centric

Today the main organizing object is the **workspace** (`native/Pnevma/Core/Workspace.swift`), with tools opened inside that workspace.

What the tweet asks for is an **agent command center** where the primary unit is an agent tile/card/slot with:

- live state,
- idle/busy indication,
- attached task/worktree,
- quick actions,
- related tools,
- stats,
- visibility controls.

Pnevma has agent-related data, but it does **not** yet expose a dedicated agent roster model in the app shell.

### 2. Only one backend project is live at a time

`native/Pnevma/Core/WorkspaceManager.swift` explicitly says:

- “**Only the selected workspace is bound to the backend at any time.**”

That is a major mismatch with a true command-center promise. A team-of-agents UI needs to monitor multiple active contexts without losing live state whenever the operator switches focus.

### 3. The session manager is not a command center

`native/Pnevma/Chrome/SessionManagerView.swift` gives a useful list of sessions, but it is still a lightweight manager:

- shows count,
- lists sessions,
- allows refresh,
- allows kill / kill all.

What is missing:

- jump to the related pane,
- jump to the related task/worktree,
- pin/favorite/focus an agent,
- see agent/provider/model/task in one row,
- bulk filters,
- bulk actions,
- alerting,
- “open related tools” shortcuts.

### 4. Idle/stuck state is implemented, but not operationalized

The backend session supervisor already tracks richer health in `crates/pnevma-session/src/supervisor.rs`:

- waiting,
- active,
- idle,
- stuck,
- complete.

But the main session UI mostly renders **status**, not **health**:

- `native/Pnevma/Core/SessionStore.swift` decodes `health`,
- `native/Pnevma/Chrome/SessionManagerView.swift` currently presents rows around `status` and killability,
- there is no strong “idle too long”, “stuck”, or “attention needed” command-center treatment.

So one of the tweet’s clearest asks — “see if any are idle” — is only partially solved in the backend, not in the product experience.

### 5. Stats exist, but mostly as analytics rather than live operator telemetry

Pnevma already has a strong analytics surface:

- historical usage,
- provider breakdowns,
- session/task explorers,
- diagnostics,
- quota/credit context.

See `native/Pnevma/Panes/AnalyticsPane.swift` and `native/Pnevma/Panes/ProviderUsageUI.swift`.

But that is different from the tweet’s desired “command center” stats. Missing operator-facing telemetry includes:

- live per-agent burn rate,
- live token/cost counters during a run,
- queue pressure and pool occupancy in the shell,
- idle duration,
- time since last output,
- retry/backoff state,
- blocked/waiting-on-human state,
- per-agent error banners.

The backend already has automation/pool state in `crates/pnevma-commands/src/commands/project.rs`, but there is no dedicated command-center UI built around it.

### 6. There is no multi-monitor shell model

The tweet explicitly says “maximize per monitor.”

Current app state is effectively single-main-window oriented:

- `native/Pnevma/App/AppDelegate.swift` builds a single main window flow,
- `native/Pnevma/Core/SessionPersistence.swift` persists one `windowFrame`, not a window/monitor topology.

Pnevma can do full screen and split zoom, but it does **not** yet have:

- detachable command-center windows,
- monitor-aware layouts,
- saved wallboard/operator layouts,
- “open this agent cluster on monitor 2” behavior.

### 7. Related tools are available, but not linked around the agent entity

Pnevma can already open terminal, diff, review, files, replay, analytics, and more. But the operator flow is still tool-first or workspace-first.

Missing agent-centric linking:

- “open this agent’s terminal”,
- “open this agent’s diff”,
- “open this agent’s review pack”,
- “open this agent’s worktree/files”,
- “open this agent’s usage diagnostics”,
- “compare two agents side by side”.

The parts exist; the **cross-linking model** does not.

### 8. The product lacks a fleet/observability API for team ops

`docs/remote-access.md` shows that remote access currently exposes authenticated HTTPS/WebSocket control for project data and sessions.

That is useful, but it is not the same as a stable observability layer for command-center and team tooling. Missing pieces include:

- structured fleet status endpoints,
- agent/session/task snapshots for dashboards,
- alert/webhook hooks,
- external monitoring integrations,
- read-only operator dashboards.

## Missing capabilities required to say “we got this”

### MUST

#### M1. First-class agent roster model

Pnevma needs a first-class `AgentRuntimeView`-style model that joins:

- session,
- task,
- worktree,
- provider/model/profile,
- health,
- current activity,
- timestamps,
- live cost/usage,
- alert state,
- related pane/tool links.

Without this, the UI will keep feeling like panes plus sessions rather than an agent command center.

#### M2. Agent command center surface

Pnevma needs a dedicated top-level surface optimized for many live agents:

- tile/grid mode,
- compact list mode,
- filter/search mode,
- sort by idle / cost / task / provider / health,
- single-click focus,
- quick actions.

This should be a first-class pane/window, not just a popover or a repurposed session list.

#### M3. Real idle / stuck / attention UX

The UI must visibly surface:

- idle,
- waiting,
- active,
- stuck,
- errored,
- completed,
- needs-human-input.

And it must show:

- last output age,
- last heartbeat age,
- time in current state,
- escalation rules.

#### M4. Agent-centric deep links to related tools

From any agent card/row, operators must be able to open:

- terminal,
- replay,
- diff,
- files/worktree,
- review,
- task details,
- merge queue context,
- usage details.

This is one of the clearest product gaps today.

#### M5. Multi-window / multi-monitor support

To match the tweet, Pnevma needs:

- multiple persisted windows,
- saved window roles/layouts,
- per-monitor placement restore,
- “command center” window presets,
- full-screen wallboard mode.

#### M6. Concurrent live monitoring beyond one selected workspace

Pnevma needs a runtime model that can keep more than one project/workspace live for observation.

Even if write operations remain scoped, command-center credibility requires simultaneous visibility across active agents without rebinding the entire backend on every workspace switch.

#### M7. Live telemetry in the shell

The command center should show live:

- active agent count,
- queued tasks,
- pool saturation,
- token burn,
- cost burn,
- retries/backoffs,
- blocked items,
- warning/error counts.

### SHOULD

#### S1. Bulk controls

- pause/stop selected agents,
- retry failed agents,
- open all related terminals,
- batch reassign / reprioritize tasks,
- clear/acknowledge alerts.

#### S2. Team semantics

- operator ownership,
- notes/handoffs,
- “watching” / “assigned to me”,
- shared annotations on an agent/task,
- audit trail for human interventions.

#### S3. Saved command-center layouts

- on-call layout,
- coding swarm layout,
- review layout,
- wallboard layout.

#### S4. External observability API

- read-only fleet snapshot endpoint,
- per-agent detail endpoint,
- metrics export,
- webhook/event hooks.

### COULD

#### C1. Compare agents side by side

Useful for review, retries, and performance tuning.

#### C2. Fleet playback / incident timeline

Replay not just one session, but the sequence of events across a team of agents.

#### C3. SLA / budget policy automation

- flag agents idle too long,
- stop tasks past spend budget,
- escalate when retries exceed threshold.

## Recommended sequencing

Because `docs/hardening-exit-criteria.md` freezes feature work until release hardening exits, this should be treated as a **post-hardening product track**.

Recommended order after hardening:

1. **Backend live-runtime aggregation**
   - define the agent roster view model
   - unify session/task/worktree/usage/pool signals
2. **Native command-center pane**
   - list + grid modes
   - live status/health/alerts
3. **Agent deep links**
   - terminal / diff / review / files / replay
4. **Multi-window + monitor persistence**
   - saved layouts and wallboard mode
5. **External observability / team ops**
   - read-only APIs, webhooks, shared dashboards

## Bar for saying “we got this”

Pnevma can reasonably say “we got this” only when all of the following are true:

- [ ] There is a dedicated command-center surface for many live agents.
- [ ] Operators can immediately see idle / stuck / active / waiting agents.
- [ ] Every agent exposes one-click links to its terminal and related tools.
- [ ] Live queue/pool/cost/usage telemetry is visible without opening analytics separately.
- [ ] The app supports multi-window / per-monitor command-center layouts.
- [ ] Monitoring multiple active workspaces/projects does not depend on a single selected backend binding.
- [ ] Alerts and attention states make unattended monitoring practical.

Until then, the honest statement is closer to:

> “Pnevma has most of the primitives for an agent command center, but not yet the integrated live operator experience.”
