# Pnevma Remote Durable Lifecycle Validation

Run these checks against a packaged `Pnevma.app` or candidate DMG on a real remote host. This is an operator-run release validation step for packaged remote durable session behavior. It is not a GitHub-hosted CI gate in this phase.

This document complements:

- `scripts/run-packaged-remote-durable-lifecycle-smoke.sh` for packaged-app or DMG lifecycle validation
- `scripts/run-packaged-remote-helper-smoke.sh` and [`manual-remote-ssh-tests.md`](./manual-remote-ssh-tests.md) for packaged helper install and upgrade validation
- [`manual-smoke-tests.md`](./manual-smoke-tests.md) for the clean-machine DMG install flow
- [`macos-release.md`](./macos-release.md) for signing, DMG packaging, first-launch instructions, and release evidence

## Scope

This slice validates packaged remote durable lifecycle behavior on the supported Apple Silicon mac-to-mac path:

- local operator machine: packaged Pnevma build on macOS
- canonical remote host: `savorgserver`
- remote target triple: `aarch64-apple-darwin`

The lifecycle harness validates:

- packaged helper/runtime health before session creation
- `ssh.connect` creating a `remote_ssh_durable` row
- detach and reattach flows using the existing remote session/controller
- app quit and relaunch against the same project DB
- relaunch reconnect reusing the original remote durable session instead of duplicating it
- clean disconnect cleanup at the end of the run

Deferred in this phase:

- deterministic network-drop simulation
- Linux lifecycle validation
- Intel remote Mac lifecycle validation
- `remote_restart_recover`

## Prerequisites

- A packaged app bundle or candidate DMG built from the current tree.
- A passing packaged helper smoke on the same artifact first.
- SSH key auth to `savorgserver`.
- A writable remote home directory for the test user.
- Local tools on the macOS operator machine:
  - `git`
  - `jq`
  - `python3`
  - `script`
  - `sqlite3`
  - `ssh`

## Automated / Operator-Run Lifecycle Scenarios

Set the common environment first:

```bash
export APP_PATH="$PWD/native/build/Release/Pnevma.app"
export REMOTE_HOST="savorgserver"
export REMOTE_USER="savorgserver"
export REMOTE_PORT="22"
export EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin"
export REMOTE_IDENTITY_FILE="$HOME/.ssh/pnevma-smoke"
```

If you are validating the candidate DMG instead of a loose app bundle:

```bash
export DMG_PATH="$PWD/Pnevma-0.2.0-macos-arm64.dmg"
unset APP_PATH
```

Run the lifecycle matrix from the repo root.

`disconnect_reconnect`:

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="$EXPECTED_TARGET_TRIPLE" \
SCENARIO="disconnect_reconnect" \
./scripts/run-packaged-remote-durable-lifecycle-smoke.sh
```

`detach_reattach`:

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="$EXPECTED_TARGET_TRIPLE" \
SCENARIO="detach_reattach" \
./scripts/run-packaged-remote-durable-lifecycle-smoke.sh
```

`quit_relaunch_reattach`:

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="$EXPECTED_TARGET_TRIPLE" \
SCENARIO="quit_relaunch_reattach" \
./scripts/run-packaged-remote-durable-lifecycle-smoke.sh
```

The same commands work with `DMG_PATH=...` instead of `APP_PATH=...`.

## Expected Scenario Results

Every passing run must preserve packaged helper metadata:

- `artifact_source = "bundle_relative"`
- `helper_kind = "binary"`
- `target_triple = "aarch64-apple-darwin"`
- `protocol_compatible = true`
- `healthy = true`
- `missing_dependencies = []`

Lifecycle expectations:

- `disconnect_reconnect`:
  - the first session row reaches `complete / exited`
  - the reconnect creates a new live row
  - only one live `type = "ssh"` remote durable row exists for the connection after reconnect
- `detach_reattach`:
  - the session transitions through `waiting / detached` -> `running / attached` -> `waiting / detached`
  - the second attach reuses the same `remote_session_id` and `controller_id`
- `quit_relaunch_reattach`:
  - the original session row survives app quit
  - after relaunch, `session.binding` still returns `mode = "live_attach"`
  - `ssh.connect` after relaunch returns the original `session_id`
  - only one live `type = "ssh"` remote durable row exists for the connection

## Evidence Produced By The Harness

Each run writes evidence under:

- `native/build/logs/remote-durable-lifecycle-<scenario>-<timestamp>/`

Preserve the whole directory for release evidence. It contains:

- `app.log`
- `project-status-*.json`
- `session-list-*.json`
- `session-live-*.json`
- `session-binding-*.json`
- `session-row-*.json`
- `session-restore-log-*.json`
- `session-events-*.json`
- `helper-health-*.json`
- `ensure-helper-*.json`
- attach transcript logs for the attach-based scenarios

When a scenario fails, keep:

- the full run directory
- the app or DMG identity used for the run
- any Console output or crash report captured during the failure

## Manual Clean-Machine DMG Pass

Run one clean-machine validation on a fresh macOS user account or second Mac against the candidate DMG.

1. Mount the candidate DMG.
2. Drag `Pnevma.app` into `/Applications`.
3. Launch from `/Applications` using the documented Finder `Open` or `Open Anyway` flow if macOS blocks first launch, and record which path was required.
4. Open a real workspace.
5. Connect to `savorgserver`.
6. Confirm a `remote_ssh_durable` session exists.
7. Quit Pnevma.
8. Relaunch Pnevma.
9. Reopen the same workspace if it is not restored automatically.
10. Verify the remote durable session is restorable or reattachable without creating a duplicate live session.
11. Disconnect cleanly at the end.
12. If restore or reattach fails, capture macOS Console output and crash logs before retrying.

## Release Requirement

A remote-enabled candidate is not done until all three evidence sets exist:

- packaged helper smoke evidence
- packaged remote durable lifecycle evidence
- clean-machine DMG lifecycle evidence
