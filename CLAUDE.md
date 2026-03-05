# CLAUDE.md — Pnevma Project

Pnevma is a terminal-first execution workspace for AI-agent-driven software delivery, built as a native macOS application backed by a Rust workspace.

See the global workspace conventions at `~/GitHub/CLAUDE.md`. Project rules here take precedence when they conflict.

---

## Stack

| Layer        | Technology                                                       |
| ------------ | ---------------------------------------------------------------- |
| Backend      | Rust 2021 edition, Tokio async, 10-crate workspace               |
| Native app   | Swift 5.9 + AppKit, XcodeGen (`native/project.yml`)              |
| Terminal     | Ghostty (libghostty), compiled with Zig, embedded as xcframework |
| FFI bridge   | `pnevma-bridge` → `libpnevma_bridge.a` (C ABI, linked by Swift)  |
| Database     | SQLite via sqlx (compile-time checked queries)                   |
| Build system | `just` (see `justfile`)                                          |

---

## Verification Commands

```bash
just check          # cargo fmt --check + clippy -D warnings + cargo test --workspace + cargo audit
just test           # cargo test --workspace + xcodebuild test
just xcode-build    # build native app (depends on rust-build)
cargo audit         # vulnerability scan (see audit.toml for accepted risks)
```

Run `just check` before every commit. Run `just xcode-build` after any FFI changes.

---

## Crate Purposes

| Crate             | Purpose                                                                    |
| ----------------- | -------------------------------------------------------------------------- |
| `pnevma-core`     | Task engine, event store, dispatch orchestrator, workflow state machines   |
| `pnevma-session`  | tmux-backed PTY supervisor, scrollback persistence, health tracking        |
| `pnevma-agents`   | Provider-neutral agent adapters (Claude Code, Codex), dispatch pool        |
| `pnevma-git`      | Worktree lifecycle, branch leases, merge queue                             |
| `pnevma-context`  | Context pack compiler — scope/claude_md/git_diff/grep discovery strategies |
| `pnevma-db`       | SQLite schema, migrations, typed query layer (18 row types)                |
| `pnevma-ssh`      | SSH key management, profile builder, Tailscale discovery                   |
| `pnevma-commands` | RPC command router — maps string command IDs to backend handlers           |
| `pnevma-remote`   | HTTP/WS remote access server (TLS, auth, rate limiting, CORS)              |
| `pnevma-bridge`   | C FFI entry point — compiles to `libpnevma_bridge.a` linked by Swift app   |

---

## Key Conventions

- All workflow logic lives in Rust. The Swift app is a thin view layer.
- Error handling: `thiserror` in library crates, `anyhow` in `pnevma-bridge`.
- Logging: `tracing` throughout; structured JSON to local log files.
- Secrets never appear in logs, scrollback, or context packs — redaction middleware covers all output paths.
- One task = one branch = one worktree. Always.

---

## Known Accepted Risks

`RUSTSEC-2023-0071` (rsa crate vulnerability) appears via the `sqlx-mysql` transitive dependency. Pnevma uses SQLite only and never enables the MySQL feature. This advisory is ignored in `audit.toml`.

---

## Definition of Done

See [`docs/definition-of-done.md`](docs/definition-of-done.md) for the full checklist that must pass before a task can be merged.
