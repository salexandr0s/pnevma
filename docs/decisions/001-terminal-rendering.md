# ADR 001: Native Terminal Rendering With Ghostty

## Status

Accepted

## Decision

Use embedded Ghostty (`libghostty` xcframework) for interactive terminal rendering inside the native Swift/AppKit app. Rust remains the source of truth for PTY/tmux supervision, scrollback persistence, and task/session orchestration.

## Context

Pnevma needs terminal rendering that can keep up with long-lived CLI sessions, coexist with dense AppKit panes, and avoid the latency and lifecycle mismatch of a webview bridge. The earlier Tauri/xterm.js spike is now historical and no longer describes the shipped product.

## Consequences

- Positive: native Metal-backed rendering, no webview IPC for terminal I/O, better fit for session restore and multi-pane desktop workflows.
- Positive: Ghostty behavior is close to the terminal experience users already trust.
- Negative: macOS build complexity increases because the app now depends on Zig-built Ghostty artifacts, XcodeGen, and a C FFI bridge into Rust.
- Negative: release entitlements must be reviewed regularly because Ghostty currently requires a small hardened-runtime exception set.

## Follow-up

Validate perceived input latency under the target threshold (<50ms perceived) on real hardware before each external release milestone.

## Evidence Snapshot (March 6, 2026)

- The shipped app is Swift/AppKit plus `libpnevma_bridge.a`, not Tauri.
- Interactive terminal panes are backed by Ghostty, while Rust owns session lifecycle, scrollback, and event persistence.
- CI and release automation now validate the checked-in entitlement allowlist for the native app bundle.

## Remaining Manual Verification

- Build a native release app via Xcode or `just xcode-build-release`.
- Measure typing latency while a terminal pane and at least one non-terminal pane are both visible.
- Record the result in the release evidence bundle or the associated release ticket.
