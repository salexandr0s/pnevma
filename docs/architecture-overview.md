# Architecture Overview

Pnevma is a native macOS application (Swift/AppKit) backed by a Rust workspace. The Rust crates compile to a static library via `pnevma-bridge`, which the Swift app links directly through a C FFI layer. All workflow logic lives in Rust; the Swift layer is a thin view renderer.

## High-level flow

1. Swift app calls Rust functions through the C FFI bridge (`libpnevma_bridge.a`).
2. Rust backend mutates project/session/task state and persists to SQLite/event log.
3. Rust backend invokes registered Swift callbacks to push state updates (task*updated, session*\*, project_refreshed).
4. Swift app refreshes panes from callback payloads.

Optional external automation uses the same backend through a local Unix socket (`pnevma ctl`).

## Crate boundaries

- `pnevma-core`: task model, state transitions, orchestration, config parsing.
- `pnevma-session`: PTY/tmux session supervision, health, scrollback persistence.
- `pnevma-agents`: provider adapters and dispatch pool.
- `pnevma-git`: worktrees, leases, merge queue mechanics.
- `pnevma-context`: context compiler and manifests.
- `pnevma-db`: SQLx migrations/query layer.
- `pnevma-ssh`: SSH key management, profile builder, Tailscale discovery.
- `pnevma-commands`: RPC command router — maps string command IDs to backend handlers.
- `pnevma-remote`: HTTP/WS remote access server with TLS, auth, rate limiting, and CORS.
- `pnevma-bridge`: FFI entry point — exposes a C ABI, compiles to `libpnevma_bridge.a` linked by the Swift app.

## Build pipeline

The build is three sequential stages:

```
Stage 1 (Zig):   vendor/ghostty  →  Ghostty.xcframework
Stage 2 (Cargo): pnevma-bridge   →  libpnevma_bridge.a
Stage 3 (Xcode): native/         →  Pnevma.app
```

The Xcode project is generated from `native/project.yml` using XcodeGen (`just xcodegen`). Both the Ghostty xcframework and the Rust staticlib are referenced as local framework/library targets in the generated project.

## State ownership rules

- Rust backend owns all workflow state and writes.
- Swift app never mutates authoritative state directly; all mutations go through the FFI bridge.
- Cross-pane synchronization happens through Rust callbacks registered at app startup.

## Persistence model

- SQLite: project/task/session/pane/check/review/telemetry/feedback records.
- Append-only event log: audit/replay timeline.
- Filesystem artifacts: review packs, scrollback, knowledge captures, telemetry exports.

## Security/reliability controls

- One-task-one-worktree invariant.
- Merge queue serialization and pre-merge checks.
- Secret redaction on output paths (events/scrollback/review/context).
- Control socket permissions (`0600`) and optional password mode.
- Remote server TLS with self-signed cert; fingerprint logged at startup.
- Rate limiting and CORS on all remote HTTP/WS endpoints.
