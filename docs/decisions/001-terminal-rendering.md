# ADR 001: Terminal Rendering in Tauri

## Status
Accepted

## Decision
Use xterm.js in the Tauri webview for terminal rendering.

## Context
Pnevma needs a terminal renderer that supports high throughput output, keyboard interaction, and coexistence with rich UI panes.

## Consequences
- Positive: battle-tested terminal emulator, straightforward frontend integration, no platform-specific FFI layer.
- Negative: webview performance constraints must be watched and benchmarked.

## Follow-up
Validate perceived input latency under target threshold (<50ms perceived) during Phase 0 and phase-gate progression on benchmark results.

## Evidence Snapshot (March 1, 2026)
- Rust backend and frontend integration is now production scaffolding (`pnevma-app` + `frontend`) with xterm.js wiring and PTY event stream.
- Session restart and reattach flows are implemented with tmux-backed runtime supervision.
- Scrollback persistence is append-only with indexed offsets and seek-based retrieval.
- In this headless environment, interactive typing latency cannot be directly measured; GUI/manual verification is still required on a local desktop run.

## Remaining Manual Verification
- Launch `cargo tauri dev` and measure interactive keypress-to-render response in the xterm pane.
- Confirm side-pane coexistence under active stream load.
- Record observed latency in `spike/tauri-terminal/latency-notes.md`.
