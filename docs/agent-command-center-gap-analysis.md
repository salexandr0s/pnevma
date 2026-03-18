# Agent Command Center Gap Analysis

This document answers a simple positioning question:

> Based on the current Pnevma codebase, what is still missing before we can honestly respond to the idea of a proper multi-agent “command center” with “we got this”?

## Bottom line

**Not yet.**

Pnevma already has strong building blocks for a command-center product:

- native macOS workspace UI with split panes and layout persistence,
- real terminal/session supervision,
- task orchestration and one-task-one-worktree isolation,
- notifications, replay, review, diff, daily brief, and usage analytics,
- remote HTTP/WebSocket plumbing.

But today Pnevma is still primarily a **project workspace with agent tooling**, not a true **agent command center**.

The main gap is that agent state is still fragmented across multiple panes (`Task Board`, `Sessions`, `Workflow`, `Notifications`, `Analytics`) instead of being unified into one operator surface.

## What Pnevma already has

These are real assets we should build on, not replace:

- **Pane-based native IDE shell**: split layout engine, pane persistence, tabs, sidebar tools, and command palette (`native/Pnevma/Core/PaneLayoutEngine.swift`, `native/Pnevma/Core/ContentAreaView.swift`, `native/Pnevma/Sidebar/SidebarToolItem.swift`, `native/Pnevma/Chrome/CommandPalette.swift`).
- **Workspace model**: multiple workspaces with per-workspace tabs, metadata, and activation (`native/Pnevma/Core/Workspace.swift`, `native/Pnevma/Core/WorkspaceManager.swift`).
- **Session supervision**: live session inventory, heartbeats, health states, scrollback, replay, kill/restart/reattach plumbing (`crates/pnevma-session/src/supervisor.rs`, `crates/pnevma-commands/src/control.rs`, `native/Pnevma/Core/SessionStore.swift`, `native/Pnevma/Panes/ReplayPane.swift`).
- **Task + workflow orchestration**: dispatch pool, automation coordinator, workflow instances, worktrees, merge queue (`crates/pnevma-core/src/orchestration.rs`, `crates/pnevma-commands/src/automation/coordinator.rs`, `native/Pnevma/Panes/Workflow/`).
- **Operator surfaces that partially overlap the tweet**:
  - Sessions manager (`native/Pnevma/Chrome/SessionManagerView.swift`)
  - Task board (`native/Pnevma/Panes/TaskBoardPane.swift`)
  - Notifications (`native/Pnevma/Panes/NotificationsPane.swift`)
  - Daily brief (`native/Pnevma/Panes/DailyBriefPane.swift`)
  - Usage + provider diagnostics (`native/Pnevma/Panes/AnalyticsPane.swift`, `native/Pnevma/Panes/ProviderUsageUI.swift`)
- **Remote/event plumbing**: local/remote RPC plus WebSocket subscriptions (`crates/pnevma-remote/src/routes/ws.rs`).

That means the command-center story is **adjacent** to what exists already. It is not greenfield.

## Why we cannot say “we got this” yet

### 1. No dedicated agent command-center surface

Right now the closest thing to a command center is a manual combination of:

- `Task Board` for task state,
- `Sessions` for terminal processes,
- `Workflow` for agent/workflow definitions and instances,
- `Notifications` for attention,
- `Analytics` for spend and provider health.

That is powerful, but it is not one coherent operator dashboard.

**Missing:**

- a single “Agents” surface centered on live/queued/recent agents,
- row/card-level state for each agent run,
- fleet filters, sort, grouping, and attention triage,
- a clear “which agents need me right now?” answer in one glance.

### 2. No fleet-wide view across workspaces/projects

Pnevma supports multiple workspaces, but the live metadata refresh path is still centered on the **active** workspace. `WorkspaceManager.applySummary(...)` only applies summaries to the active workspace, and the session/notification stores are scoped to the currently open project (`native/Pnevma/Core/WorkspaceManager.swift`, `native/Pnevma/Core/SessionStore.swift`, `native/Pnevma/Panes/NotificationsViewModel.swift`).

**Missing:**

- a global “all active agents” view across open workspaces,
- background refresh for inactive workspaces,
- a stable cross-project fleet model for local and remote projects.

Without that, Pnevma is a good per-project cockpit, not a real team-of-agents command center.

### 3. Backend has health states, but UI does not surface them well

The session supervisor already tracks `Active`, `Idle`, and `Stuck` health (`crates/pnevma-session/src/supervisor.rs`). `session.list_live` already exposes those values (`crates/pnevma-commands/src/control.rs`).

But the visible UI still mostly presents coarse session status like `running` / `waiting` / `error` / `complete` (`native/Pnevma/Chrome/SessionManagerView.swift`).

**Missing:**

- explicit idle/stuck badges in the primary agent UI,
- semantic agent states beyond PTY/session liveness,
- attention rules such as “idle too long”, “stuck”, “waiting on review”, “retrying”, “rate-limited”, or “blocked by dependency”.

The tweet specifically calls out “see if any are idle.” Pnevma has the backend primitive, but not the product surface.

### 4. No first-class “open related tool” workflow from an agent entity

Pnevma has the tools: terminal panes, replay, diff, review, files, notifications, analytics. What it lacks is a strong **relationship model** from one live agent run to all its related artifacts.

Examples of what is currently weak or missing:

- task cards do not expose “open terminal / replay / diff / review” as first-class actions (`native/Pnevma/Panes/TaskBoardPane.swift`),
- notifications show `taskID` / `sessionID`, but tapping a notification only marks it read rather than navigating to the related tool (`native/Pnevma/Panes/NotificationsPane.swift`, `native/Pnevma/Panes/NotificationsViewModel.swift`),
- there is no single agent detail view that binds task, session, worktree, diff, review, logs, and usage together.

**Missing:**

- one-click pivots from agent -> terminal,
- agent -> replay,
- agent -> diff/review,
- agent -> worktree/files,
- agent -> usage and failure diagnostics.

### 5. Stats exist, but not as live per-agent operational stats

Pnevma already has good cost analytics and provider diagnostics. It can show trendlines, top tasks, session/task usage explorers, and provider quota snapshots (`native/Pnevma/Panes/AnalyticsPane.swift`, `native/Pnevma/Panes/ProviderUsageUI.swift`).

But the tweet asks for operator stats in the command-center sense, not just historical analytics.

**Missing:**

- live per-agent runtime cards,
- elapsed time, last activity age, retry count, queue age, active step, and assigned profile,
- live slot utilization vs `max_concurrent`,
- burn-rate style “what is this fleet costing right now?” summaries,
- a compact “healthy / warning / attention” fleet summary.

Current `project.summary` is intentionally small: git branch, active task count, active agent count, cost today, unread notifications (`crates/pnevma-commands/src/commands/project.rs`). That is not yet command-center telemetry.

### 6. Workflow/Agents pane is config-oriented, not operations-oriented

The current `Agents` pane is really a profile and workflow management surface. It is good for defining agents and workflows, but it is not the place you would park on a second monitor to supervise live work (`native/Pnevma/Panes/Workflow/`).

**Missing:**

- live run list,
- queue view,
- status transitions in real time,
- bulk actions,
- operator-oriented triage affordances.

### 7. No monitor-aware / multi-window command-center mode

The tweet explicitly wants something that can be maximized per monitor.

Pnevma today is still fundamentally a **single main window** app, plus specialized settings/smoke windows (`native/Pnevma/App/AppDelegate.swift`). Session persistence stores a single main window frame (`native/Pnevma/Core/SessionPersistence.swift`).

**Missing:**

- separate command-center window(s),
- detachable or pop-out agent dashboards,
- saved monitor-aware layouts,
- fast show/hide/toggle of a dedicated command-center surface,
- “command center on monitor 2, terminals on monitor 1” ergonomics.

This is one of the biggest product gaps relative to the tweet.

### 8. Missing operator actions from one place

Pnevma has useful underlying actions: dispatch, kill session, restart, reattach, replay, review, merge, etc. But they are scattered.

**Missing:**

- a single operator action strip per agent,
- bulk actions across selected agents,
- pause/resume/interrupt/retry semantics at the command-center level,
- queue management controls,
- “show only attention-needed agents” controls.

### 9. No shared/team command-center story yet

Pnevma has remote access plumbing, but not a real shared multi-operator command center.

**Missing:**

- stable remote “fleet status” contracts beyond generic RPC + event channels,
- role-aware shared dashboards (viewer/operator),
- explicit ownership/handoff/presence for agent runs,
- collaborative “someone is already handling this agent” mechanics.

This is optional for v1 of the command center, but it matters if we want to lean into the word **teams** in the market-facing sense.

## Product bar: what must exist before we can say “we got this”

The following is the minimum bar for a credible command-center claim.

### Goals

- Let an operator supervise multiple live agents from one place.
- Make idle/stuck/attention-needed agents obvious within seconds.
- Make jumping from an agent to its terminal, replay, diff, review, and files a one-click action.
- Support a dedicated full-window/full-monitor command-center mode.
- Preserve Pnevma’s existing advantages: native UI, real terminals, worktree isolation, and durable state.

### Non-goals

- Replacing the existing task board, notifications pane, or analytics pane.
- Building a multi-user SaaS control plane in the first iteration.
- Reworking release priorities before the current release-readiness work is settled.

### Functional requirements

#### A. Fleet overview

- **MUST:** Add a dedicated command-center surface for live/queued/recent agent runs.
- **MUST:** Show agent state, task title, workspace/project, provider/model, elapsed time, and last activity age.
- **MUST:** Support filters for all / active / idle / stuck / failed / queued / review-needed.
- **SHOULD:** Support grouping by workspace, workflow, provider, or priority.
- **SHOULD:** Support sorting by last activity, priority, cost, duration, or attention level.

#### B. Attention and liveness

- **MUST:** Surface backend health states (`active`, `idle`, `stuck`) in the primary UI.
- **MUST:** Elevate agents that need attention into a visible queue.
- **MUST:** Distinguish “working”, “idle”, “stuck”, “retrying”, and “done” at a glance.
- **SHOULD:** Add semantic reasons such as blocked-on-dependency, blocked-on-review, or rate-limited when available.

#### C. Related tool pivots

- **MUST:** From each agent row/card, open the attached terminal.
- **MUST:** From each agent row/card, open replay if the live terminal is gone.
- **MUST:** From each agent row/card, open related diff/review/files when present.
- **SHOULD:** Support split-open vs tab-open vs pop-out behavior.

#### D. Operational stats

- **MUST:** Show live fleet stats: active, queued, idle, stuck, failed, retrying.
- **MUST:** Show live slot utilization against configured concurrency.
- **MUST:** Show spend/usage summaries relevant to active work, not only historical charts.
- **SHOULD:** Show per-agent token/cost burn and retry history.

#### E. Control plane actions

- **MUST:** Support dispatch/open/jump-to/kill/restart/reattach from the command center.
- **SHOULD:** Support retry/requeue/bulk-select actions.
- **SHOULD:** Support pause or hold semantics if/when the backend gains them.

#### F. Windowing and layout

- **MUST:** Add a dedicated command-center window mode.
- **MUST:** Support show/hide/toggle via menu, shortcut, and command palette.
- **MUST:** Persist command-center layout independently from the main workspace layout.
- **SHOULD:** Support monitor-aware restore.

#### G. Remote/team readiness

- **SHOULD:** Add a first-class remote fleet status stream/API.
- **SHOULD:** Support read-only remote viewers before adding mutating remote controls.
- **COULD:** Add operator presence/ownership annotations for shared supervision.

### Non-functional requirements

- **MUST:** Refresh visible fleet state within 1 second of relevant backend events.
- **MUST:** Never expose secrets in command-center tiles, logs, or usage surfaces.
- **MUST:** Recover cleanly after relaunch and reconstruct active agent cards from persisted state.
- **MUST:** Be keyboard navigable.
- **SHOULD:** Remain useful at the current default of 4 concurrent agents and not degrade badly if more are configured.
- **SHOULD:** Reuse existing event streams and persistence paths where possible.

### Data and event requirements

The command center needs a first-class agent/fleet contract instead of stitching together several partial views.

#### Minimum backend contract

- **MUST:** Expose a stable live fleet snapshot that includes:
  - agent/run id,
  - workspace/project id,
  - task id/title/status,
  - session id/status/health,
  - workflow instance/step if present,
  - provider/model/profile,
  - started at / last activity at,
  - queue or retry state,
  - accumulated cost/tokens,
  - available actions.
- **MUST:** Expose incremental events for changes to those fields.
- **SHOULD:** Expose attention reason enums rather than forcing UI inference.

### User stories and acceptance criteria

#### Story 1 — Scan the fleet

**As an operator, I want one dashboard for all active agents, so that I can immediately see what is healthy and what needs attention.**

Acceptance criteria:

- Given multiple active/queued runs across open workspaces, when I open the command center, then I see them in one list/grid.
- Given one run becomes idle or stuck, when its state changes, then the command center reflects that change without a manual refresh.
- Given no runs exist, when I open the command center, then I see an empty state that explains how to dispatch work.

DoD:

- [ ] UI implemented
- [ ] backend snapshot contract implemented
- [ ] event-driven refresh implemented
- [ ] tests for empty, active, idle, and stuck states
- [ ] docs updated

#### Story 2 — Jump to the right tool

**As an operator, I want to open the related terminal, replay, diff, or review from an agent card, so that I can investigate without hunting through panes.**

Acceptance criteria:

- Given a live run with an attached session, when I click “Open Terminal”, then the related session opens.
- Given a completed run with replay data, when I click “Replay”, then the replay pane opens for that session.
- Given a run with review/diff artifacts, when I click those actions, then the correct pane opens in context.

DoD:

- [ ] deep-link actions implemented
- [ ] pane routing supports split/tab/pop-out behavior
- [ ] tests cover terminal/replay/diff/review navigation
- [ ] docs updated

#### Story 3 — See idle and stuck agents fast

**As an operator, I want idle and stuck agents to stand out, so that I can intervene quickly.**

Acceptance criteria:

- Given a run is idle beyond the configured threshold, when I view the command center, then it is marked idle.
- Given a run is stuck beyond the configured threshold, when I view the command center, then it is marked stuck and promoted into attention-needed views.
- Given a healthy active run, when I view the command center, then it is not mixed visually with attention-needed runs.

DoD:

- [ ] backend health states mapped into UI state
- [ ] attention styling implemented
- [ ] thresholds documented
- [ ] tests for idle/stuck transitions

#### Story 4 — Operate from one place

**As an operator, I want common actions on each agent from the command center, so that I do not need to bounce between panes.**

Acceptance criteria:

- Given a running agent, when I choose kill/restart/reattach, then the action succeeds or shows an actionable error.
- Given a queued or failed run, when I choose the relevant action, then the command center updates accordingly.
- Given multiple selected runs, when I invoke a supported bulk action, then it applies safely to all selected runs.

DoD:

- [ ] action menu implemented
- [ ] protected actions wired where needed
- [ ] failure states surfaced cleanly
- [ ] tests for individual actions

#### Story 5 — Use a dedicated monitor

**As an operator, I want a dedicated command-center window, so that I can keep the fleet overview visible while using terminals elsewhere.**

Acceptance criteria:

- Given I toggle the command center window, when it opens, then it can be moved and maximized independently.
- Given I quit and relaunch Pnevma, when session restore runs, then the command-center window/layout is restored.
- Given I use the command palette or menu shortcut, when I toggle the command center, then the expected window shows/hides.

DoD:

- [ ] separate window implemented
- [ ] persistence implemented
- [ ] menu + command palette + shortcut wiring added
- [ ] restore behavior tested

## Suggested delivery phases

### Phase 1 — Honest MVP

Ship the smallest thing that makes the tweet materially true:

- dedicated command-center pane/window,
- live fleet list,
- explicit idle/stuck surfacing,
- one-click terminal/replay open,
- live fleet counters.

At that point we can reasonably say:

**“Pnevma already gives you a native agent command center with live status, idle/stuck detection, and one-click pivots into the underlying terminals and artifacts.”**

### Phase 2 — Strong operator UX

- attention queue,
- diff/review/files pivots,
- richer per-agent stats,
- bulk actions,
- saved layouts and monitor-aware restore.

### Phase 3 — Team/remote depth

- remote fleet status contract,
- shared read-only dashboards,
- operator presence/ownership,
- deeper semantic state reasons.

## Recommended sequencing

This should be treated as a phased product plan that can proceed alongside release-quality work, not as a proposal blocked on a standing freeze.

The practical message is:

- keep shipping reliability, session recovery, dispatch, replay, and release quality work that strengthens the command-center story;
- start with Phase 1 above when the team is ready to prioritize it.

## Final verdict

Pnevma has enough underlying machinery to plausibly become the thing described in the tweet.

What it does **not** yet have is the unifying product layer that turns “agent tooling spread across panes” into a true **agent command center**.

So the honest answer today is:

- **Foundation:** yes
- **Command-center claim:** not yet
- **Path to “we got this”:** clear and relatively near, but still missing a dedicated fleet surface, richer live state modeling, fast pivots, and multi-window/monitor ergonomics
