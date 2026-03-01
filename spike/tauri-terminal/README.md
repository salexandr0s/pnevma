# Phase 0 Spike: Tauri + xterm.js

## Goal
Validate xterm.js in the Tauri webview as the primary terminal renderer and confirm non-terminal pane coexistence.

## What Was Built
- Tauri backend command/event bridge in `crates/pnevma-app`.
- xterm.js terminal pane in `frontend/src/panes/terminal/TerminalPane.tsx`.
- Multi-pane shell with task board + terminal panes in `frontend/src/App.tsx`.
- PTY session runtime and output stream forwarding in `crates/pnevma-session`.

## Data Path
1. Backend spawns/attaches runtime shell session.
2. Output is streamed as `session_output` Tauri events.
3. Frontend terminal pane writes output via xterm.js.
4. Input is sent back via `send_session_input`.

## Validation Status
- Functional coexistence: implemented and exercised in current scaffold.
- Input latency: requires GUI/manual check; not measurable in headless CI shell.

## Manual Verification Procedure
1. Run `cargo tauri dev` from `crates/pnevma-app`.
2. Open a project with `Cmd+K` -> `Open Project`.
3. Create a terminal session and split panes horizontally/vertically.
4. Type continuously for 60s while tailing a large file output (`yes | head -n 20000`).
5. Confirm no perceptible lag beyond normal terminal behavior.
6. Record findings in `latency-notes.md`.
