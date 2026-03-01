# Phase 0 Spike: Agent Adapter

## Goal
Validate feasibility of invoking agent CLIs inside isolated worktrees and normalizing their output into structured events.

## Prototype/Scaffold Outcome
- `AgentAdapter` async trait implemented in `crates/pnevma-agents/src/model.rs`.
- Claude and Codex adapters now spawn real CLI processes, stream stdout/stderr, and emit:
  - `OutputChunk`
  - `UsageUpdate` (best-effort parsed)
  - `Complete`/`Error`
- Adapter registry auto-detects available CLIs via `which`.
- Dispatch wiring now creates a worktree and invokes adapter inside that worktree.

## Manual Verification Procedure
1. Ensure CLI is installed and authenticated (`claude` and/or `codex`).
2. Create a Ready task.
3. Dispatch task from task board.
4. Verify:
   - Worktree created under `.pnevma/worktrees/<task-id>/`.
   - Agent output streams into terminal pane.
   - Files modified only in worktree path.
   - Cost updates appear when usage lines are parseable.
