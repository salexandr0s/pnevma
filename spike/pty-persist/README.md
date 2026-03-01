# Phase 0 Spike: PTY Persistence

## Goal
Prove that session metadata and scrollback survive app restarts, and that live session backends can be reattached.

## Implemented Prototype Path
- Session metadata persistence: `sessions` table in SQLite (`crates/pnevma-db/migrations/0001_initial.sql`).
- Scrollback persistence: append-only files under `.pnevma/data/scrollback/`.
- Indexed offsets: sidecar `.idx` files with progressive byte offsets.
- Restore + liveness reconciliation: `open_project`, `restore_sessions`, `reattach_session`, `restart_session`.

## Current Behavior
- App restart restores session rows from DB.
- Session liveness is checked against tmux session backend.
- Live sessions are reattachable.
- Dead sessions retain scrollback and can be restarted.

## Manual Verification Procedure
1. Open a project and create a session.
2. Run long-lived command (`watch date` or `tail -f`).
3. Close app process.
4. Relaunch and open the same project.
5. Confirm scrollback loads and `reattach` succeeds for live backend.
6. Kill backend, relaunch, and confirm `restart` path works.
