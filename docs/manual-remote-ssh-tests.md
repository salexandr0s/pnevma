# Pnevma Remote SSH Helper Smoke Tests

Run these checks from a packaged `Pnevma.app` or release DMG against real remote hosts. This is an operator-run release validation step for the packaged remote helper path. It is not a GitHub-hosted CI gate in this phase.

This document complements:

- `scripts/run-packaged-remote-helper-smoke.sh` for packaged-app remote helper validation
- `scripts/run-packaged-remote-durable-lifecycle-smoke.sh` and [`manual-remote-durable-lifecycle-tests.md`](./manual-remote-durable-lifecycle-tests.md) for packaged remote durable reconnect, relaunch, and reattach validation
- `scripts/seed-remote-helper-fixture.sh` for deterministic upgrade fixture setup
- `docs/macos-release.md` for signing, DMG packaging, first-launch instructions, and release evidence

## Supported Remote Matrix

Packaged remote helper support in this phase covers:

- `x86_64-unknown-linux-musl`
- `aarch64-unknown-linux-musl`
- `x86_64-apple-darwin`
- `aarch64-apple-darwin`

The expected first-class mac-to-mac validation host in this slice is an Apple Silicon Mac Studio using `aarch64-apple-darwin`.

## Prerequisites

- A packaged app bundle or DMG built from the current tree.
- Real SSH-accessible hosts for the targets you are validating:
  - Linux `x86_64`
  - Linux `aarch64`
  - Apple Silicon Mac Studio (`aarch64-apple-darwin`)
- SSH key auth to those hosts.
- A writable remote home directory for the test user.
- Local tools on the macOS operator machine:
  - `git`
  - `jq`
  - `python3`
  - `sqlite3`
  - `ssh`
- Remote helper dependencies available on the validated hosts:
  - `sh`
  - `mkfifo`
  - `script`
  - `nohup`
  - `tail`
  - `kill`

The smoke harness seeds the remote host automatically for each scenario. Run the commands below against dedicated smoke hosts or smoke-only user accounts.

## Common Setup

```bash
export APP_PATH="$PWD/native/build/Release/Pnevma.app"
export REMOTE_USER="pnevma"
export REMOTE_PORT="22"
export REMOTE_IDENTITY_FILE="$HOME/.ssh/pnevma-smoke"
export REMOTE_X64_HOST="linux-x64.example.internal"
export REMOTE_ARM64_HOST="linux-arm64.example.internal"
export REMOTE_MAC_STUDIO_HOST="mac-studio.example.internal"
```

If you are validating a candidate DMG instead of a loose app bundle, replace `APP_PATH=...` with:

```bash
export DMG_PATH="$PWD/Pnevma-0.2.0-macos-arm64.dmg"
unset APP_PATH
```

## Fresh Install Matrix

Run fresh install smoke on the supported targets you have available.

Linux `x86_64`:

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_X64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="x86_64-unknown-linux-musl" \
SCENARIO="fresh" \
./scripts/run-packaged-remote-helper-smoke.sh
```

Linux `aarch64`:

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_ARM64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-unknown-linux-musl" \
SCENARIO="fresh" \
./scripts/run-packaged-remote-helper-smoke.sh
```

Apple Silicon Mac Studio:

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_MAC_STUDIO_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="fresh" \
./scripts/run-packaged-remote-helper-smoke.sh
```

If an Intel remote Mac becomes available later, validate it with:

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_INTEL_MAC_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="x86_64-apple-darwin" \
SCENARIO="fresh" \
./scripts/run-packaged-remote-helper-smoke.sh
```

## Upgrade and Reinstall Matrix

Run the existing canonical Linux upgrade scenarios on the Linux `x86_64` host:

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_X64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="x86_64-unknown-linux-musl" \
SCENARIO="legacy_shell" \
./scripts/run-packaged-remote-helper-smoke.sh
```

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_X64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="x86_64-unknown-linux-musl" \
SCENARIO="legacy_binary_version_mismatch" \
./scripts/run-packaged-remote-helper-smoke.sh
```

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_X64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="x86_64-unknown-linux-musl" \
SCENARIO="legacy_binary_digest_mismatch" \
./scripts/run-packaged-remote-helper-smoke.sh
```

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_X64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="x86_64-unknown-linux-musl" \
SCENARIO="legacy_binary_protocol_mismatch" \
./scripts/run-packaged-remote-helper-smoke.sh
```

Run the mac-to-mac upgrade scenarios on the Apple Silicon Mac Studio:

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_MAC_STUDIO_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="legacy_shell" \
./scripts/run-packaged-remote-helper-smoke.sh
```

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_MAC_STUDIO_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="legacy_binary_version_mismatch" \
./scripts/run-packaged-remote-helper-smoke.sh
```

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_MAC_STUDIO_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="legacy_binary_digest_mismatch" \
./scripts/run-packaged-remote-helper-smoke.sh
```

```bash
APP_PATH="$APP_PATH" \
REMOTE_HOST="$REMOTE_MAC_STUDIO_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="legacy_binary_protocol_mismatch" \
./scripts/run-packaged-remote-helper-smoke.sh
```

## Expected Result Fields

For every passing scenario, `ssh.runtime.ensure_helper` must report:

- `artifact_source = "bundle_relative"`
- `helper_kind = "binary"`
- `install_kind = "binary_artifact"`
- `target_triple` equal to the expected remote target
- `protocol_compatible = true`
- `healthy = true`
- `missing_dependencies = []`

After install, `ssh.runtime.health` must report the same packaged metadata, including the bundled helper SHA from `Contents/Resources/remote-helper/manifest.json`.

The smoke harness also verifies that:

- `ssh.connect` creates a `remote_ssh_durable` session row
- `ssh.disconnect` transitions that row to a completed/exited state

Logs and JSON responses are written under `native/build/logs/remote-helper-smoke-*`.

## Expected Failure Modes

- Unsupported platform:
  `ssh.runtime.ensure_helper` fails with an explicit unsupported-platform error listing the supported target matrix.
- Missing packaged artifact:
  `ssh.runtime.ensure_helper` fails without fallback unless compatibility mode is explicitly enabled.
- Missing remote dependencies:
  `ssh.runtime.ensure_helper` or `ssh.runtime.health` reports `healthy = false` and a non-empty `missing_dependencies` list.
- Version, digest, or protocol mismatch:
  the seeded legacy helper is replaced and the final health result matches the packaged helper from the app bundle.

`PNEVMA_REMOTE_HELPER_ALLOW_SHELL_COMPAT=1` is an escape hatch for unsupported or missing packaged artifacts only. It is not the expected release path for the supported targets above.

## Evidence to Preserve

For remote-enabled release candidates, preserve:

- fresh-install smoke logs for Linux `x86_64`
- fresh-install smoke logs for Linux `aarch64`
- fresh-install smoke logs for Apple Silicon Mac Studio (`aarch64-apple-darwin`)
- upgrade scenario logs for the canonical Linux `x86_64` host
- upgrade scenario logs for the Apple Silicon Mac Studio
- remote durable lifecycle logs for the Apple Silicon Mac Studio packaged-app or DMG path
- the packaged app or DMG identity used for the run
- any remote dependency or platform failures encountered during validation
