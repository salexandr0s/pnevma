# Pnevma

![CI](https://github.com/salexandr0s/pnevma/actions/workflows/ci.yml/badge.svg)
![License](https://img.shields.io/badge/license-MIT%20%2F%20Apache--2.0-blue)
![Rust](https://img.shields.io/badge/rust-2021_edition-orange)
![Swift](https://img.shields.io/badge/swift-5.9-FA7343)

Pnevma is a native macOS workspace for running and supervising CLI coding agents on real software projects. It gives you one place to create tasks, launch agents such as Claude Code and Codex in managed terminal sessions, review what they changed, and decide when that work is ready to merge.

## Status

Pnevma is currently in active release hardening. The native app, Rust backend, Ghostty terminal integration, remote access server, and release tooling are already in the repository. The current priority is stabilizing CI, packaging, and clean-machine validation for a polished macOS release.

Current development target:

- Apple Silicon
- macOS 14+
- Build from source

## What Pnevma Is

Pnevma is designed for developers who want the speed of coding agents without losing control of their repository. Instead of juggling raw terminals, ad hoc branches, and manual review steps, Pnevma wraps agent execution in a structured desktop workflow:

- one task maps to one git worktree
- each task runs in a managed terminal session
- task, session, and review state are persisted
- diffs and merge decisions stay inside a consistent review flow
- workflow logic lives in the Rust backend, not in UI-side scripts

## Features

- Native macOS app built with Swift/AppKit and backed by a Rust workspace
- Embedded Ghostty terminal for managed local terminal sessions
- Persistent sessions with scrollback, replay, and restore support
- Task orchestration with status tracking, dispatch controls, and event history
- Provider-neutral agent adapters with built-in support for Claude Code and Codex
- One-task-one-worktree isolation to keep parallel agent work separated
- Review flow with diffs, checks, review packs, and merge queue mechanics
- Context compiler that assembles repository instructions, diffs, rules, and scoped files before dispatch
- Project configuration in `pnevma.toml` and global configuration in `~/.config/pnevma/config.toml`
- Optional local control socket for automation and scripting
- Optional remote HTTP/WebSocket access with TLS, token auth, rate limits, and CORS guardrails
- SSH manager with key handling, profiles, and Tailscale device discovery
- Secret redaction across logs, scrollback, context packs, and review artifacts

## How It Works

1. Open a repository in Pnevma and initialize its `pnevma.toml` configuration.
2. Create a task with a description, rules, and acceptance criteria.
3. Pnevma creates a dedicated git worktree for that task.
4. The selected agent is launched in a managed terminal session.
5. The Rust backend tracks task state, session state, events, and artifacts in SQLite and the event log.
6. You monitor progress in the app, inspect the resulting diff and review materials, then approve, reject, or merge the work.

The important boundary is that Pnevma isolates agent work by git worktree, not by OS sandbox. Agents still run with the current user's filesystem and network access.

## Architecture

Pnevma is a native macOS application with a thin Swift/AppKit frontend and a Rust backend that owns workflow state.

- `native/`: the macOS app and pane-based user interface
- `crates/pnevma-bridge`: the C FFI bridge compiled into `libpnevma_bridge.a`
- Rust workspace crates: task orchestration, session supervision, git/worktree management, agent adapters, context compilation, database access, SSH utilities, command routing, remote access, and redaction
- `SQLite + event log`: persisted task, session, review, and audit data
- `Ghostty`: embedded terminal runtime compiled as an xcframework

High-level flow:

1. The Swift app calls into the Rust backend through the FFI bridge.
2. The backend manages tasks, sessions, worktrees, persistence, and review state.
3. The backend sends updates back to the UI through registered callbacks.
4. The UI renders current state across terminals, task views, review panes, and supporting tools.

## Build From Source

### Prerequisites

- Rust via `rustup` using the toolchain pinned in `rust-toolchain.toml`
- Zig matching `.zig-version`
- `just`
- XcodeGen
- Xcode 15+
- Git
- At least one supported agent CLI on `PATH` (`claude-code` or `codex`)

### Setup

```bash
git clone https://github.com/salexandr0s/pnevma.git
cd pnevma

./scripts/bootstrap-dev.sh
just build
just ghostty-smoke
```

For interactive development:

```bash
open native/Pnevma.xcodeproj
```

## Configuration

Project-level configuration lives in `pnevma.toml`:

```toml
[project]
name = "my-project"
brief = "Short project description"

[agents]
default_provider = "claude-code"
max_concurrent = 4

[agents.claude-code]
model = "sonnet"
token_budget = 24000
timeout_minutes = 30

[branches]
target = "main"
naming = "task/{{id}}-{{slug}}"
```

See [docs/pnevma-toml-reference.md](docs/pnevma-toml-reference.md) for the full configuration reference.

## Development

Common commands:

```bash
just check
just test
just xcode-build
just xcode-test
just release
```

`just check` runs Rust formatting, `clippy`, tests, dependency audit, and migration checksum verification. `just ghostty-smoke` is the required terminal runtime smoke gate.

## Documentation

- [Getting Started](docs/getting-started.md): bootstrap, local setup, and first project flow
- [Architecture Overview](docs/architecture-overview.md): backend boundaries, FFI flow, and persistence model
- [pnevma.toml Reference](docs/pnevma-toml-reference.md): project configuration schema
- [Security Deployment](docs/security-deployment.md): remote access and credential handling
- [macOS Release Runbook](docs/macos-release.md): signing, notarization, and release steps
- [Hardening Exit Criteria](docs/hardening-exit-criteria.md): merge policy during release hardening
- [Implementation Status](docs/implementation-status.md): current repo status and priorities

## Security Model

- Worktrees isolate repository changes, not operating-system privileges
- Agents run with the current user account's filesystem and network permissions
- Remote access is optional and disabled unless configured
- Sensitive output paths are protected by redaction middleware

## License

Dual-licensed under MIT or Apache-2.0, at your option.
