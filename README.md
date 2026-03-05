<h1 align="center">Pnevma</h1>

<p align="center">
  <strong>Terminal-first execution workspace for agent-driven software delivery.</strong>
</p>

<p align="center">
  <a href="#features">Features</a>&nbsp;&nbsp;&bull;&nbsp;&nbsp;
  <a href="#quick-start">Quick Start</a>&nbsp;&nbsp;&bull;&nbsp;&nbsp;
  <a href="#architecture">Architecture</a>&nbsp;&nbsp;&bull;&nbsp;&nbsp;
  <a href="#documentation">Docs</a>&nbsp;&nbsp;&bull;&nbsp;&nbsp;
  <a href="#license">License</a>
</p>

<p align="center">
  <img alt="CI" src="https://github.com/pnevma/pnevma/actions/workflows/ci.yml/badge.svg" />
  <img alt="License" src="https://img.shields.io/badge/license-MIT%2FApache--2.0-blue" />
  <img alt="Rust" src="https://img.shields.io/badge/rust-2021_edition-orange" />
  <img alt="Swift" src="https://img.shields.io/badge/swift-5.9-FA7343" />
</p>

---

Pnevma gives developers a single desktop workspace to run, supervise, and review work produced by CLI coding agents like **Claude Code** and **Codex**. It wraps persistent terminal sessions, task orchestration, one-task-one-worktree isolation, and a guarded review/merge flow into a keyboard-driven native macOS app.

## Features

- **Persistent PTY sessions** &mdash; tmux-backed terminals that survive app restarts, with indexed scrollback and replay
- **Task orchestration** &mdash; contracts, status machines, dependency graphs, and priority-based dispatch
- **Agent dispatch** &mdash; provider-neutral adapter layer with throttling, supporting Claude Code and Codex out of the box
- **One-task-one-worktree** &mdash; strict git isolation so agents never step on each other
- **Review & merge queue** &mdash; acceptance checks, review packs, approve/reject flow, serialized merge execution
- **Context compiler** &mdash; builds token-budgeted context packs from scope, `CLAUDE.md`, git diffs, and grep results
- **Multi-pane UI** &mdash; terminal, task board, review inspector, diff viewer, file browser, search, replay, and more
- **Keyboard-first UX** &mdash; command palette, custom bindings, pane layout templates
- **SSH manager** &mdash; key management, profile builder, Tailscale device discovery
- **Control plane** &mdash; local Unix socket for `pnevma ctl` scripting and automation
- **Secret redaction** &mdash; middleware that scrubs sensitive values across events, scrollback, reviews, and context packs

## Quick Start

### Prerequisites

- [Rust](https://rustup.rs/) (stable, `aarch64-apple-darwin` target)
- [Zig](https://ziglang.org/) (version pinned in `.zig-version`) — for Ghostty xcframework build
- [just](https://github.com/casey/just) — task runner (`brew install just`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — project file generator (`brew install xcodegen`)
- Xcode 15+ with macOS SDK
- Git
- A coding agent CLI (Claude Code or Codex)

### Setup

```bash
# Clone the repository
git clone https://github.com/pnevma/pnevma.git
cd pnevma

# Install toolchains and dependencies
./scripts/bootstrap-dev.sh

# Generate the Xcode project
just xcodegen

# Full debug build (Rust staticlib + native macOS app)
just build
```

### First project

1. Open Pnevma and create a new project pointing to your repo
2. Define a task with acceptance criteria
3. Dispatch it to an agent &mdash; Pnevma creates a worktree, streams the terminal, and tracks progress
4. Review the diff, approve or reject, and merge when ready

See [Getting Started](docs/getting-started.md) for a full walkthrough.

## Architecture

Pnevma is a **native macOS app** (Swift/AppKit) backed by a **Rust workspace**. The Rust crates compile to a static library (`libpnevma_bridge.a`) via `pnevma-bridge`, which is linked directly into the Swift app through a C FFI layer. Terminal rendering is provided by **Ghostty** (libghostty), compiled with Zig and embedded as an xcframework.

```
┌────────────────────────────────────────────────────────┐
│  Native macOS App  (Swift 5.9 · AppKit · XcodeGen)     │
├────────────────────────────────────────────────────────┤
│  C FFI bridge  (pnevma-bridge → libpnevma_bridge.a)    │
├──────────┬─────────┬──────────┬──────────┬─────────────┤
│  core    │ session │ agents   │   git    │  context    │
│  tasks   │ PTY sup.│ adapters │ worktree │  compiler   │
│  events  │ health  │ dispatch │ merge Q  │  budget     │
├──────────┴─────────┴──────────┴──────────┴─────────────┤
│  pnevma-commands  (RPC command router)                  │
├────────────────────────────────────────────────────────┤
│  pnevma-remote  (HTTP/WS remote access server)         │
├────────────────────────────────────────────────────────┤
│  pnevma-db  (SQLite · sqlx · migrations)               │
├────────────────────────────────────────────────────────┤
│  pnevma-ssh  (keys · profiles · Tailscale)             │
└────────────────────────────────────────────────────────┘
                      ↑
         Ghostty xcframework (libghostty · Zig)
```

### Workspace crates

| Crate             | Purpose                                                                              |
| ----------------- | ------------------------------------------------------------------------------------ |
| `pnevma-core`     | Project model, task engine, event store, dispatch orchestrator, workflow definitions |
| `pnevma-session`  | tmux-backed PTY supervisor, scrollback persistence, health tracking                  |
| `pnevma-agents`   | Provider-neutral agent adapters, throttled dispatch pool, adapter registry           |
| `pnevma-git`      | Worktree lifecycle, branch management, lease tracking, merge queue                   |
| `pnevma-context`  | Context pack compiler with scope/claude_md/git_diff/grep discovery strategies        |
| `pnevma-db`       | SQLite schema, migrations, typed query layer (18 row types)                          |
| `pnevma-ssh`      | SSH key management, profile builder, Tailscale discovery, config parsing             |
| `pnevma-commands` | RPC command router — maps command IDs to backend handlers                            |
| `pnevma-remote`   | HTTP/WS remote access server with TLS, auth, rate limiting, and CORS                 |
| `pnevma-bridge`   | FFI entry point — compiles to `libpnevma_bridge.a` linked by the Swift app           |

### Native app

The `native/` directory contains the Swift/AppKit application. The project file is generated from `native/project.yml` using XcodeGen. UI is organized into **13 pane types** (terminal, task board, review, merge queue, replay, daily brief, diff, search, file browser, settings, rules manager, notifications, SSH manager) rendered in a configurable multi-pane grid.

## Configuration

Projects are configured via `pnevma.toml` in the project root:

```toml
[project]
name = "my-project"
brief = "What this project does"

[agents]
default_provider = "claude-code"
max_concurrent = 4

[agents.claude-code]
model = "claude-sonnet-4-6"
token_budget = 80000
timeout_minutes = 30

[branches]
target = "main"
naming = "pnevma/{task_id}/{slug}"
```

See the full [pnevma.toml reference](docs/pnevma-toml-reference.md).

## Development

```bash
# Run all checks (cargo fmt + clippy + Rust tests)
just check

# Run all tests (Rust + Xcode)
just test

# Rust checks only
just rust-check    # fmt --check + clippy -D warnings

# Build the app (debug)
just build

# Build the app (release)
just release
```

### CI

GitHub Actions runs on every push and PR:

- **Rust** &mdash; `cargo fmt --check`, `clippy -D warnings`, `cargo test`, `cargo audit`
- **Xcode** &mdash; `xcodebuild test`

## macOS Release

Pnevma includes a full macOS signing, notarization, and auto-update pipeline:

| Step                  | Script                                     |
| --------------------- | ------------------------------------------ |
| Code signing          | `scripts/release-macos-sign.sh`            |
| Notarization          | `scripts/release-macos-notarize.sh`        |
| Staple & verify       | `scripts/release-macos-staple-verify.sh`   |
| Generate updater keys | `scripts/release-updater-generate-keys.sh` |
| Sign updater artifact | `scripts/release-updater-sign.sh`          |
| Generate update feed  | `scripts/release-updater-feed.sh`          |
| Pre-flight checks     | `scripts/release-preflight.sh`             |

See the full [macOS release runbook](docs/macos-release.md).

## Documentation

| Document                                                     | Description                                              |
| ------------------------------------------------------------ | -------------------------------------------------------- |
| [Getting Started](docs/getting-started.md)                   | Prerequisites, bootstrap, first project                  |
| [Architecture Overview](docs/architecture-overview.md)       | Crate boundaries, FFI flow, state ownership, persistence |
| [pnevma.toml Reference](docs/pnevma-toml-reference.md)       | Configuration file schema                                |
| [Keyboard Shortcuts](docs/keyboard-shortcuts.md)             | Keybinding reference                                     |
| [IPC Test Harness](docs/ipc-harness.md)                      | Control plane socket testing                             |
| [Release Checklist](docs/release-checklist.md)               | Pre-release gating steps                                 |
| [macOS Release Runbook](docs/macos-release.md)               | Signing, notarization, updater distribution              |
| [Implementation Status](docs/implementation-status.md)       | Phase completion tracking                                |
| [Design Partner Readiness](docs/design-partner-readiness.md) | Readiness assessment                                     |

## Security

`RUSTSEC-2023-0071` (rsa crate) appears via the `sqlx-mysql` transitive dependency. Pnevma uses SQLite only and never enables the MySQL feature, so this is accepted risk. See `audit.toml` at the repo root.

## License

Dual-licensed under [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
