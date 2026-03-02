# IPC Harness (Phase 5.12 MVP)

This repository includes control-plane harness scripts:

- `scripts/ipc-common.sh`
- `scripts/ipc-e2e-smoke.sh`
- `scripts/ipc-e2e-recovery.sh`

## Purpose

- Validate control socket method routing from CLI to backend.
- Exercise a minimal end-to-end sequence:
  - readiness check
  - optional scaffold initialization
  - task create/list
  - daily brief query
  - optional dispatch attempt when adapters are detected
- Exercise session recovery methods:
  - `session.new`
  - `session.timeline`
  - `session.recovery.options`
  - `session.recovery.execute`

## Usage

App must be running with control socket enabled and a project already open.

```bash
export SOCKET_PATH=".pnevma/run/control.sock"
export PROJECT_PATH="/absolute/path/to/project"   # optional but recommended
./scripts/ipc-e2e-smoke.sh
./scripts/ipc-e2e-recovery.sh
```

## Fault-injection coverage in tests

Rust test coverage includes targeted fault-path checks:

- missing session scrollback lookup -> `NotFound`
- missing session input send -> `NotFound`
- restored session with missing scrollback artifact -> `Io` error path
- restored session with directory scrollback path -> `Io` error path
- offset clamp and zero-limit scrollback reads are safe
- invalid UTF-8 scrollback bytes are returned lossily without panic

See `crates/pnevma-session/src/supervisor.rs` tests.
