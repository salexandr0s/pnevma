# Pnevma × Symphony Implementation Plan

## Summary

Adopt Symphony’s unattended-execution strengths as an **automation mode inside Pnevma**, not as a replacement architecture. The codebase already proves this is the right boundary: Pnevma’s durable DB/event model, worktree discipline, review/merge controls, remote API, and tmux/Ghostty session layer are stronger than Symphony’s, while Symphony is stronger specifically at **centralized automation coordination**.

## Disagreements Resolved

- **Coordinator-first vs hot-reload-first**
  - **Claude:** start with config hot-reload and hooks.
  - **Codex:** start with a single `AutomationCoordinator`.
  - **Decision:** **Codex is right.**
  - **Why:** today’s scheduler is a thin polling loop in `crates/pnevma-commands/src/auto_dispatch.rs:1`, started globally from `crates/pnevma-bridge/src/lib.rs:267`, while concurrency state lives separately in `crates/pnevma-agents/src/pool.rs:1`. Hot-reloading config before there is one runtime owner just makes a fragmented scheduler more dynamic.

- **Add `continue_turn` to the current adapter vs replace Codex integration first**
  - **Claude:** extend `AgentAdapter` with continuation support.
  - **Codex:** replace the current Codex adapter with an app-server-backed adapter first.
  - **Decision:** **Codex is right.**
  - **Why:** the current Codex integration in `crates/pnevma-agents/src/adapters/codex.rs:1` is a one-shot CLI subprocess that writes a prompt to stdin, parses stdout/stderr heuristically, and exits. Multi-turn continuation on top of that is the wrong layer; the transport must change first.

- **New observability API vs reuse existing remote surface**
  - **Claude:** add new observability JSON routes.
  - **Codex:** expose one canonical automation snapshot through existing UI/API surfaces.
  - **Decision:** **Codex is right.**
  - **Why:** Pnevma already has authenticated remote routes in `crates/pnevma-remote/src/server.rs:1` and `project.status` in `crates/pnevma-commands/src/commands/project.rs:3503`. The gap is not “missing HTTP”; it is “no scheduler-native snapshot exists to expose.”

- **Per-priority concurrency limits vs Symphony-style per-state limits**
  - **Claude:** add `max_concurrent_by_priority`.
  - **Codex:** implies Symphony’s state-based gating is the important idea.
  - **Decision:** **Neither is fully right.**
  - **Why:** Symphony’s value is not generic priority bucketing; it is **work-source-state-aware gating**. Pnevma should add concurrency caps by **automation state/source state** only after tracker-backed automation exists. Doing this by existing task priority alone would copy the wrong abstraction.

- **Bolt tracker integration into current auto-dispatch vs wait for coordinator**
  - **Claude:** invoke a new tracker from `auto_dispatch.rs`.
  - **Codex:** coordinator and workflow contract must come first.
  - **Decision:** **Codex is right.**
  - **Why:** the current auto-dispatcher only lists `Ready` tasks and calls `dispatch_task`; it has no claims, retry registry, reconciliation loop, or canonical running-set ownership. Tracker polling on top of that will race and drift.

- **Put automation hooks in `pnevma.toml` vs introduce repo-owned `WORKFLOW.md`**
  - **Claude:** put hooks under `pnevma.toml`.
  - **Codex:** adopt repo-owned `WORKFLOW.md`.
  - **Decision:** **Neither as stated; split responsibilities.**
  - **Why:** `pnevma.toml` should remain product/project config, while repo-specific automation behavior belongs in `WORKFLOW.md`. Hooks, active states, tracker rules, continuation/retry policy, and automation caps should live in the repo-owned contract; app defaults stay in `pnevma.toml`.

## Architecture Prerequisites

- **Introduce a single coordinator-owned automation runtime** before any tracker, retry, or observability work. It should own claims, running runs, retry queue, reconciliation, and the canonical runtime snapshot instead of spreading that state across `AppState`, `DispatchPool`, and ad hoc background tasks.
- **Define a typed automation config model** loaded from repo-owned `WORKFLOW.md`, with last-known-good hot reload. `pnevma.toml` remains for project defaults and non-automation settings.
- **Decide task identity mapping now:** external issues should materialize into normal Pnevma tasks, with persisted external-source metadata, so review/merge/history/UI continue to work on one task model.

## Prioritized Implementation List

1. **Build `AutomationCoordinator` as the only runtime owner for claims, running runs, retries, reconciliation, and snapshots.**
   - **Why Pnevma needs this:** today Pnevma has durable state but no single live owner of automation truth, so unattended behavior is bolted onto manual dispatch instead of being a first-class runtime.
   - **Surfaced by:** Codex, confirmed by code review.
   - **Affected files/modules:** `crates/pnevma-commands/src/auto_dispatch.rs:1`, `crates/pnevma-commands/src/state.rs:1`, `crates/pnevma-agents/src/pool.rs:1`, `crates/pnevma-core/src/orchestration.rs:1`.
   - **Dependencies:** none; this is the foundation.
   - **Effort:** L
   - **Risk if skipped:** every later feature becomes scheduler glue code with race conditions and no canonical state.

2. **Add repo-owned `WORKFLOW.md` automation config with hot reload and last-known-good fallback, while keeping `pnevma.toml` for project/app settings.**
   - **Why Pnevma needs this:** unattended automation should be defined by the repo being automated, not by app-local config loaded once at project-open time.
   - **Surfaced by:** both docs; final split is my addition.
   - **Affected files/modules:** `crates/pnevma-core/src/config.rs:1`, `crates/pnevma-commands/src/commands/project.rs:164`, `crates/pnevma-commands/src/state.rs:1`.
   - **Dependencies:** coordinator must consume the typed runtime config.
   - **Effort:** M
   - **Risk if skipped:** automation policy stays opaque, restart-bound, and harder to reproduce across machines and branches.

3. **Replace the one-shot Codex CLI path with an app-server-backed Codex adapter and extend `AgentAdapter` for persistent automation sessions.**
   - **Why Pnevma needs this:** the current Codex adapter is brittle for unattended work and cannot support continuation, structured tool telemetry, or scheduler-aware rate-limit handling.
   - **Surfaced by:** Codex; Claude’s multi-turn idea depends on it.
   - **Affected files/modules:** `crates/pnevma-agents/src/model.rs:1`, `crates/pnevma-agents/src/adapters/codex.rs:1`, `crates/pnevma-agents/src/registry.rs:1`, `crates/pnevma-commands/src/commands/tasks.rs:1304`.
   - **Dependencies:** items 1–2.
   - **Effort:** L
   - **Risk if skipped:** continuation/retry logic will be fake, token/cost telemetry stays guessy, and Codex automation remains unreliable.

4. **Implement coordinator-owned continuation, retry backoff, and stall recovery with persisted retry metadata.**
   - **Why Pnevma needs this:** Pnevma already stores retry-ish fields on tasks and workflows, but the runtime does not actually keep work moving after normal exits, stalls, or transient failures.
   - **Surfaced by:** both docs.
   - **Affected files/modules:** `crates/pnevma-commands/src/auto_dispatch.rs:1`, `crates/pnevma-commands/src/commands/tasks.rs:1304`, `crates/pnevma-core/src/workflow.rs:1`, `crates/pnevma-core/src/task.rs:1`.
   - **Dependencies:** items 1 and 3.
   - **Effort:** M
   - **Risk if skipped:** automation remains opportunistic instead of resilient, especially for long-running Codex work.

5. **Add tracker abstraction with a Linear adapter first, mapping external items into normal Pnevma tasks plus source metadata.**
   - **Why Pnevma needs this:** the product is already strong at executing and auditing tasks; the missing piece is letting teams keep their source of truth in an external tracker instead of duplicating planning inside Pnevma.
   - **Surfaced by:** both docs.
   - **Affected files/modules:** new `crates/pnevma-tracker/`, `crates/pnevma-commands/src/commands/tasks.rs:977`, `crates/pnevma-db/src/store.rs:331`, `crates/pnevma-core/src/task.rs:65`.
   - **Dependencies:** items 1–2; item 4 should land before unattended tracker-driven runs.
   - **Effort:** L
   - **Risk if skipped:** Pnevma remains mostly a local task board with auto-dispatch, not a team automation system.

6. **Add automation worktree lifecycle hooks and harden workspace path validation, including symlink-component rejection and explicit workspace reuse policy.**
   - **Why Pnevma needs this:** Pnevma’s Git worktree model is stronger than Symphony’s, but it still lacks repo-defined setup/cleanup semantics and stronger path hardening for unattended runs.
   - **Surfaced by:** both docs.
   - **Affected files/modules:** `crates/pnevma-git/src/service.rs:1`, `crates/pnevma-core/src/config.rs:1`, `crates/pnevma-commands/src/commands/tasks.rs:1304`.
   - **Dependencies:** item 2, because hook policy belongs in `WORKFLOW.md`.
   - **Effort:** M
   - **Risk if skipped:** automation stays brittle across real repos and retains avoidable workspace-escape risk.

7. **Add reconciliation loops for running automation against tracker state, session health, and workspace validity, with startup cleanup of invalid terminal states.**
   - **Why Pnevma needs this:** Pnevma already persists rich state, but it does not continuously prove that running work is still legitimate; that wastes agent time and leaves stale worktrees/sessions behind.
   - **Surfaced by:** both docs.
   - **Affected files/modules:** `crates/pnevma-session/src/supervisor.rs:1`, `crates/pnevma-commands/src/commands/project.rs:164`, `crates/pnevma-commands/src/commands/tasks.rs:1685`, new coordinator module.
   - **Dependencies:** items 1, 4, and 5.
   - **Effort:** M
   - **Risk if skipped:** long-running automation will drift from external truth and require manual cleanup.

8. **Expose one canonical automation snapshot through existing remote/native surfaces instead of adding a parallel observability stack.**
   - **Why Pnevma needs this:** Pnevma already has UI, WS, and REST plumbing; operators need scheduler truth in those surfaces, not a separate monitoring island.
   - **Surfaced by:** Codex; Claude identified the observability gap.
   - **Affected files/modules:** `crates/pnevma-remote/src/server.rs:1`, `crates/pnevma-remote/src/routes/api.rs:1`, `crates/pnevma-commands/src/commands/project.rs:3503`, `crates/pnevma-commands/src/remote_bridge.rs:1`.
   - **Dependencies:** item 1.
   - **Effort:** M
   - **Risk if skipped:** debugging automation remains split across DB rows, events, and guesses about in-memory state.

9. **Add coordinator-owned dynamic automation tools for tracker operations, starting with Linear GraphQL helpers for Codex automation mode.**
   - **Why Pnevma needs this:** once external issues drive execution, the agent needs a structured way to read/update tracker state without relying on prompt text or shell hacks.
   - **Surfaced by:** Codex, plus Symphony SPEC.
   - **Affected files/modules:** Codex adapter implementation from item 3, new tracker/tool layer near item 5, `crates/pnevma-commands/src/command_registry.rs:1`.
   - **Dependencies:** items 3 and 5.
   - **Effort:** M
   - **Risk if skipped:** tracker-aware automation will remain prompt-fragile and operationally noisy.

## Explicitly Rejected Ideas

- **Do not port Symphony’s no-DB design.**
  - Pnevma’s SQLite + event model is a competitive advantage, not accidental complexity.

- **Do not rewrite Pnevma into a Codex-only product.**
  - Improve Codex automation first, but keep the provider seam in `crates/pnevma-agents/src/model.rs:1`; Pnevma’s multi-provider posture is strategically better.

- **Do not bolt tracker polling directly into the current `auto_dispatch.rs`.**
  - That would hard-code orchestration into the thinnest possible loop and make retries/reconciliation harder to reason about later.

- **Do not add multi-turn continuation to the current one-shot Codex subprocess adapter.**
  - The transport is wrong; fixing the trait without fixing the adapter would create pseudo-continuation with poor observability.

- **Do not add priority-based concurrency limits as an early feature.**
  - Symphony’s useful idea is state-aware gating, not “more buckets.” Priority caps would be a detour until automation states and external source states exist.

- **Do not create a brand-new `/api/v1/state` observability product in parallel with Pnevma’s current remote API.**
  - Extend existing routes and WS events with coordinator snapshots instead of maintaining two control surfaces.

- **Do not replace Git worktrees with generic directories just because Symphony does.**
  - `crates/pnevma-git/src/service.rs:1` is already better for Pnevma’s review/merge workflow; keep it and add lifecycle semantics.

## Test Plan

- **Coordinator correctness**
  - Verify one claim per task/external item, queued/running/retry transitions, restart safety, and deterministic snapshot output across restarts.

- **`WORKFLOW.md` runtime behavior**
  - Verify valid reload applies without restart, invalid reload preserves last-known-good config, and hooks/retry caps/concurrency changes affect only future dispatch decisions.

- **Codex automation session behavior**
  - Verify persistent turn reuse, continuation prompts, structured usage/rate-limit capture, interrupt/stop behavior, and clean failure handling when the app-server drops.

- **Retry/reconciliation**
  - Verify continuation retry after normal exit, exponential backoff after failure, stalled-run recovery, terminal external state cleanup, and “keep running on transient state-refresh failure” semantics.

- **Tracker integration**
  - Verify candidate import, dedup/claim behavior, blocker gating, external-state mapping into task status, and task persistence with external metadata.

- **Workspace/hook safety**
  - Verify `after_create`/`before_run` fatal semantics, `after_run`/`before_remove` best-effort semantics, timeout enforcement, symlink-component rejection, and cleanup of invalid persisted worktrees.

## Assumptions and Defaults

- Automation mode is **additive**; interactive/manual Pnevma workflows remain first-class.
- `WORKFLOW.md` is the repo-owned automation contract; `pnevma.toml` remains the app/project config file.
- External issues become standard Pnevma tasks with persisted source metadata rather than a separate parallel execution object.
- Codex gets first-class unattended automation support first because Symphony’s strongest ideas are Codex-centric and Pnevma’s current Codex adapter is the weakest operational seam.
