# Pnevma — Build Agent Instructions

You are building Pnevma, a terminal-first execution workspace for AI-agent-driven software delivery.

## Read First
- `buildplan-v2.md` — the full specification. This is your source of truth.
- `buildplan-v1.md` — archived original plan. Reference only.

## Tech Stack
- **Language:** Rust (2021 edition)
- **Async:** Tokio
- **Database:** SQLite via sqlx (compile-time checked queries)
- **UI:** Tauri 2.0 (Rust backend + webview frontend)
- **Terminal:** xterm.js in Tauri webview, connected to Rust PTY via Tauri events
- **Frontend:** Vite + React + TailwindCSS
- **IPC:** Tauri commands + events (no separate daemon — Tauri backend IS the orchestrator)
- **Testing:** cargo test + proptest for property-based tests
- **License:** MIT / Apache-2.0 dual

## Cargo Workspace
```
crates/
  pnevma-core/     # Project model, event log, task engine, state machine, dispatch
  pnevma-session/  # PTY supervisor, scrollback persistence, health state
  pnevma-agents/   # Agent adapter trait + provider implementations
  pnevma-git/      # Worktree service, branch manager, lease manager, merge queue
  pnevma-context/  # Context compiler, token budgets, manifest generation
  pnevma-app/      # Tauri application, commands, event bridge (thin glue)
  pnevma-db/       # SQLite schema, migrations, query layer
frontend/          # Vite + React + TailwindCSS + xterm.js
```

## Build Phases — Execute Sequentially
Phases are in `buildplan-v2.md` section 7 (Phases 0–5). Each phase has entry conditions, deliverables, and acceptance criteria. **Do not start a phase until the previous phase's acceptance criteria pass.** Phases 0–2 are optimized for speed to reach the core demo.

## Rules
- One task = one branch = one worktree. Always.
- Never force-push or rewrite git history.
- All workflow logic lives in the Rust backend (Tauri), not the frontend.
- The frontend is a thin view layer — it renders state from the backend via Tauri commands/events.
- Agent adapters implement the async `AgentAdapter` trait. No provider-specific code outside adapters.
- Every significant action emits a structured event to the append-only log.
- Secrets never appear in logs, scrollback, or context packs. Redaction middleware on all output paths.
- Config files: `pnevma.toml` (per-project), `~/.config/pnevma/config.toml` (global).
- Run `cargo fmt`, `cargo clippy`, and `cargo test` before every commit.
- Run `npx tsc --noEmit` and `npx eslint .` in `frontend/` before every commit.
- Error handling: `thiserror` in library crates, `anyhow` in `pnevma-app`. Logging via `tracing`.
- Max 4 concurrent agent sessions (configurable). Excess dispatches queue by priority.

## Phase 0 — Start Here
Begin with the feasibility spike. Three tasks:
1. Tauri + xterm.js terminal spike (embed xterm.js in Tauri webview, connect to Rust PTY, verify <50ms input latency)
2. PTY session persistence prototype (spawn, persist scrollback, kill app, restore)
3. Minimal Claude Code agent adapter (spawn CLI in worktree, send prompt, capture structured events)

Document the terminal rendering decision in `docs/decisions/001-terminal-rendering.md` before proceeding to Phase 1.
