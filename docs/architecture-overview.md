# Architecture Overview

Pnevma is a native macOS application built with Swift/AppKit and backed by a Rust workspace. The Swift app is the view and interaction layer. The Rust backend owns workflow logic, persistence, automation, remote access, SSH/session behavior, and safety-sensitive rules.

The bridge between them is `pnevma-bridge`, which compiles to `libpnevma_bridge.a` and exposes a C ABI consumed by the app.

## System Shape

At a high level, the product is made of four layers:

1. **Native macOS UI** in `native/` for panes, chrome, workspace management, and operator interactions.
2. **FFI bridge** in `crates/pnevma-bridge` for Swift-to-Rust calls and callback delivery.
3. **Rust workflow services** for tasks, sessions, worktrees, review, automation, tracking, remote access, SSH, and redaction.
4. **Persistence and artifacts** in SQLite, the append-only event log, and filesystem outputs such as review packs and scrollback.

## Primary Runtime Paths

### Local operator path

1. The Swift app invokes backend commands through the FFI bridge.
2. `pnevma-commands` routes those calls into the relevant Rust subsystem.
3. The backend mutates task, session, project, and review state.
4. Updated state is persisted and pushed back to Swift through registered callbacks.

This is the core path behind the task board, terminal panes, review surfaces, settings, and most day-to-day operator workflows.

### Remote durable SSH path

Remote durable SSH sessions follow a separate execution path:

1. The app or command layer invokes SSH/session commands through the same backend.
2. `pnevma-ssh` manages profiles, key handling, Tailscale discovery, and remote helper lifecycle.
3. A packaged `pnevma-remote-helper` binary is installed or reused on the remote host.
4. The helper owns remote session attach, reattach, health, and compatibility behavior while Pnevma persists the local control state.

This is the path behind the current packaged remote helper validation and durable reconnect or relaunch documentation.

### External control paths

Two optional control surfaces reuse the same backend command model:

- a local Unix socket control plane (`pnevma ctl`)
- an HTTPS and WebSocket remote server with TLS, auth, rate limits, and CORS controls

They do not create a separate workflow engine. They expose the existing one.

## Workspace Crates

- `pnevma-core`: task model, orchestration, config parsing, workflow state
- `pnevma-redaction`: secret detection and redaction utilities
- `pnevma-session`: local session supervision, health, replay, scrollback
- `pnevma-agents`: provider adapters and dispatch behavior
- `pnevma-git`: worktrees, leases, merge queue mechanics
- `pnevma-context`: context compilation and manifests
- `pnevma-db`: schema, migrations, and query layer
- `pnevma-ssh`: SSH profiles, Tailscale discovery, remote durable session support
- `pnevma-remote-helper`: packaged helper binary for supported remote targets
- `pnevma-remote`: HTTPS and WebSocket remote access server
- `pnevma-commands`: command router and backend-facing application surface
- `pnevma-tracker`: issue tracker integration support
- `pnevma-bridge`: FFI entry point for the macOS app

## State Ownership

- Rust owns authoritative workflow state and all persistent writes.
- Swift does not mutate authoritative state directly.
- Cross-pane synchronization happens through backend callbacks and explicit reloads from Rust-owned state.
- Safety-sensitive behavior such as worktree isolation, session control, redaction, and remote policy stays out of UI-only code.

## Persistence

- **SQLite** stores project, task, session, pane, review, notification, telemetry, and related records.
- **Append-only event log** preserves audit and replay history.
- **Filesystem artifacts** hold review packs, scrollback, knowledge captures, telemetry exports, and related outputs.

This persistence model is what lets Pnevma recover state across relaunch instead of treating every session as disposable.

## Build Pipeline

The shipping native build is a three-stage pipeline:

```text
Stage 1 (Zig):   vendor/ghostty        -> GhosttyKit.xcframework
Stage 2 (Cargo): crates/pnevma-bridge  -> libpnevma_bridge.a
Stage 3 (Xcode): native/               -> Pnevma.app
```

The Xcode project is generated from `native/project.yml` with XcodeGen. The generated project links the local Ghostty xcframework and Rust static library into the native app target.

## Design Boundaries

- One task maps to one git worktree.
- Review and merge controls stay explicit.
- Secret redaction applies across logs, scrollback, context, and review artifacts.
- Remote access is optional and guarded by TLS, auth, rate limits, and policy controls.
- Worktrees are the isolation boundary for repository changes, not a replacement for OS sandboxing.

## See also

- [Product Tour](./product-tour.md)
- [Getting Started](./getting-started.md)
- [`pnevma.toml` Reference](./pnevma-toml-reference.md)
- [Security Deployment Guide](./security-deployment.md)
