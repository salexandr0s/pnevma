# CLAUDE.md — Pnevma Project

Pnevma is a terminal-first execution workspace for AI-agent-driven software delivery, built as a native macOS application backed by a Rust workspace.

See the global workspace conventions at `~/GitHub/CLAUDE.md`. Project rules here take precedence when they conflict.

---

## Current Product State

- Pnevma is in the native macOS release phase.
- The current public release target is `v0.2.0`.
- The first public artifact target is a Developer ID-signed `arm64` macOS `.dmg`; notarization is deferred for that first cut.
- Release quality matters, but it is not a standing repo-wide feature freeze.

---

## Stack

| Layer        | Technology                                                       |
| ------------ | ---------------------------------------------------------------- |
| Backend      | Rust 2021 edition, Tokio async, 14-crate workspace               |
| Native app   | Swift 6.1 + AppKit/SwiftUI, XcodeGen (`native/project.yml`)      |
| Terminal     | Ghostty (libghostty), compiled with Zig, embedded as xcframework |
| FFI bridge   | `pnevma-bridge` → `libpnevma_bridge.a` (C ABI, linked by Swift)  |
| Database     | SQLite via sqlx (compile-time checked queries)                   |
| Build system | `just` (see `justfile`)                                          |

---

## Required Reading

- `docs/implementation-status.md`
- `docs/macos-website-release-plan.md`
- `docs/release-readiness.md`
- `docs/design/remediation-master-plan.md`

Use those documents as the source of truth for release-affecting work.

---

## Verification Commands

```bash
just check          # rust-check + rust-test + rust-audit + migration-checksums
just test           # rust-test + xcode-test
just xcode-build    # debug native build (depends on rust-build)
just xcodegen-check # regenerate project and verify it is committed
```

Run `just check` before every commit-worthy handoff. Run `just xcode-build` after FFI changes. Run `just xcodegen-check` after editing `native/project.yml`.

---

## Crate Purposes

| Crate             | Purpose                                                                    |
| ----------------- | -------------------------------------------------------------------------- |
| `pnevma-core`     | Task engine, event store, dispatch orchestrator, workflow state machines   |
| `pnevma-redaction` | Secret redaction and output sanitization                                  |
| `pnevma-session-protocol` | Shared session backend/protocol types                              |
| `pnevma-session`  | Session supervision, PTY backends, scrollback persistence, restore, health |
| `pnevma-agents`   | Provider-neutral agent adapters (Claude Code, Codex), dispatch pool        |
| `pnevma-git`      | Worktree lifecycle, branch leases, merge queue                             |
| `pnevma-context`  | Context pack compiler — scope/claude_md/git_diff/grep discovery strategies |
| `pnevma-db`       | SQLite schema, migrations, typed query layer                               |
| `pnevma-ssh`      | SSH key management, profile builder, Tailscale discovery                   |
| `pnevma-remote-helper` | Remote helper binaries and packaging support                           |
| `pnevma-remote`   | HTTP/WS remote access server (TLS, auth, rate limiting, CORS)              |
| `pnevma-commands` | Backend command router and command handlers                                |
| `pnevma-bridge`   | C FFI entry point — compiles to `libpnevma_bridge.a` linked by Swift app   |
| `pnevma-tracker`  | Issue tracker integration (Linear adapter, state sync, transitions)        |

---

## Key Conventions

- All workflow logic MUST live in Rust. The Swift app MUST remain a thin view layer.
- One task MUST map to one branch and one worktree.
- Significant actions MUST emit structured events to the append-only log.
- Secrets MUST NOT appear in logs, scrollback, review artifacts, or context packs.
- Error handling SHOULD use `thiserror` in library crates; `pnevma-bridge` MAY use `anyhow`.
- Logging MUST use `tracing`.

---

## Known Accepted Risks

`RUSTSEC-2023-0071` (rsa crate vulnerability) appears via the `sqlx-mysql` transitive dependency. Pnevma uses SQLite only and never enables the MySQL feature. This advisory is ignored in `.cargo/audit.toml`.

---

## Definition of Done

See [`docs/definition-of-done.md`](docs/definition-of-done.md) for the full checklist that must pass before a task can be merged.
