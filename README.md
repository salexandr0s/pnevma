# Pnevma

Pnevma is a terminal-first execution workspace for agent-driven software delivery.

## Workspace Layout

- `crates/pnevma-core`: project model, tasks, events, orchestration
- `crates/pnevma-session`: PTY session supervisor and health tracking
- `crates/pnevma-agents`: provider-neutral agent adapters + dispatch throttle pool
- `crates/pnevma-git`: worktree/branch/lease services
- `crates/pnevma-context`: context pack compilation
- `crates/pnevma-db`: SQLite migrations + query layer
- `crates/pnevma-app`: Tauri shell and command/event bridge
- `frontend`: React/Tailwind/xterm.js UI

## Status

This repository is scaffolded to the refined build plan with Phase 1 foundations and core Phase 2 domain contracts.

## Quick Start

1. Install Rust toolchain + Node.js.
2. Run `./scripts/bootstrap-dev.sh`.
3. Run `cargo build --workspace`.
4. Run the Tauri app from `crates/pnevma-app`.
