# Agent Command Center Implementation Plan

## Goal

Ship a native macOS Command Center window that lets an operator supervise agent work across open Pnevma workspaces, quickly spot attention-needed runs, and jump into the related terminal, replay, diff, review, or files surface.

## Product scope

### In scope for v1
- Dedicated **Command Center** window
- Toggle from menu, command palette, and shortcut
- Aggregate live command-center snapshots across **open project workspaces**
- Attention-first fleet list with filtering and search
- Per-run actions:
  - open terminal
  - open replay
  - open diff
  - open review
  - open files
  - kill session
  - restart session
  - reattach session
- Persist command-center window frame and visibility across relaunch

### Out of scope for v1
- Remote/shared multi-user operator control plane
- Closed-project fleet discovery
- Rich cross-user presence or collaboration
- New backend global fleet service

## Architecture

### Backend
Use a project-scoped RPC command:
- `project.command_center_snapshot`

The backend snapshot provides:
- project metadata
- summary counters
- run rows derived from:
  - live sessions
  - automation claims
  - retry queue
  - review-needed tasks
  - failed tasks

The native app aggregates one snapshot per open workspace.

### Native app
Use a dedicated native store and window layer:
- `CommandCenterStore`
- `CommandCenterWindowController`
- `CommandCenterView`

The store owns lightweight per-workspace monitor runtimes. Each monitor runtime opens the workspace project through its own bridge/command bus and polls `project.command_center_snapshot`.

This avoids rewriting the main app into a fully per-workspace runtime architecture before v1 while still delivering credible multi-workspace monitoring.

## Implementation phases

### Phase 1 — backend snapshot contract
- Add/finish `project.command_center_snapshot`
- Return:
  - `CommandCenterSnapshotView`
  - `CommandCenterSummaryView`
  - `CommandCenterRunView`
- Derive states:
  - `running`
  - `idle`
  - `stuck`
  - `queued`
  - `retrying`
  - `review_needed`
  - `failed`
  - `completed`
- Include action availability per row
- Cover unmatched live sessions as standalone rows

### Phase 2 — native monitor store
- Add `CommandCenterStore`
- Add per-workspace monitor runtimes with dedicated bridges
- Poll command-center snapshots for all open project workspaces
- Refresh eagerly on relevant backend events:
  - `task_updated`
  - `session_spawned`
  - `session_heartbeat`
  - `session_exited`
  - `notification_created`
  - `notification_updated`
  - `notification_cleared`
  - `cost_updated`
- Aggregate into workspace sections and fleet totals

### Phase 3 — dedicated window
- Add `CommandCenterWindowController`
- Add window lifecycle and persistence
- Support normal macOS move/maximize/fullscreen behavior
- Restore frame and visibility on relaunch

### Phase 4 — operator UI
- Add top summary bar
- Add attention-first grouped list
- Add search and filters:
  - All
  - Attention
  - Active
  - Idle
  - Stuck
  - Queued
  - Review
  - Failed
- Add detail pane with metadata and actions

### Phase 5 — action routing
- Route row actions into existing app surfaces
- Switch to the owning workspace before opening tools
- Reuse existing terminal/replay/diff/review/files flows where possible
- Wire kill/restart/reattach through existing backend commands

### Phase 6 — persistence and polish
- Persist command-center window frame
- Persist command-center visibility
- Restore window on relaunch
- Add docs and shortcut references

## UX defaults
- Shortcut: `⇧⌘C`
- Grouping: workspace
- Sorting: attention first, then most recent activity
- Window target: command-center-on-monitor-2 use case

## Data model expectations

Each run row should expose enough data for triage:
- task id/title/status
- session id/name/status/health
- provider/model/profile
- branch/worktree
- state
- attention reason
- started at / last activity
- retry count / retry after
- cost and tokens
- available actions

## Risks and mitigations

### Risk: active-workspace assumptions in the main app
Mitigation:
- keep main workspace UX unchanged
- isolate command-center monitoring in dedicated monitor runtimes

### Risk: ambiguous global bridge events
Mitigation:
- treat bridge events as invalidation hints
- use polling as the authoritative refresh path for v1

### Risk: existing panes mostly assume the active workspace
Mitigation:
- switch to the owning workspace before opening the related tool
- add targeted deep-linking where needed, especially diff/review selection

## Verification

### Backend
- focused command-center tests for mixed-state snapshots
- unmatched live session coverage
- action availability coverage

### Native
- `just xcode-build`
- manual checks for:
  - toggle shortcut/menu/palette
  - window restore
  - multi-workspace aggregation
  - action routing
  - kill/restart/reattach flow refresh

## Future ideas

Possible follow-on inspiration from systems like Gastown:
- stronger persistent agent identity beyond per-run rows
- hierarchical views for fleet / workspace / agent grouping
- richer handoff and ownership surfaces between agents
- command-center-first orchestration metaphors rather than only project-first navigation
