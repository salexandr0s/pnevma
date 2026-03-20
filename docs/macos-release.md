# macOS Release Signing + First-Launch Instructions

Pnevma `v0.2.0` is currently expected to ship as a public `arm64` macOS `.dmg`
that is **Developer ID signed but not notarized yet**.

That has one practical consequence for users on a clean Mac:

- macOS may block first launch even though the app is signed
- users should expect to use Finder `Open` or System Settings `Open Anyway`
- those bypass instructions must be documented anywhere the DMG is linked

The repository still contains notarization and stapling scripts for the follow-up
fully notarized release path, but they are not blocking for this first public
cut.

This repository ships the following release helpers:

- `scripts/release-preflight.sh`
- `scripts/release-macos-sign.sh`
- `scripts/release-macos-package-dmg.sh`
- `scripts/release-macos-notarize.sh` (optional for the later notarized path)
- `scripts/release-macos-staple-verify.sh` (optional for the later notarized path)
- `scripts/check-entitlements.sh`

Pnevma ships real version checking against GitHub releases but does not yet
perform in-app self-update.

## Prerequisites

1. Xcode command line tools installed (`xcode-select --install`).
2. Apple `Developer ID Application` certificate installed in Keychain.
3. `just`, `xcodegen`, Rust, and Zig installed for the local build.
4. `notarytool` credentials only if you are also attempting the deferred notarized path.

## Environment variables

- `APPLE_SIGNING_IDENTITY` (required by the signing script)
- `APP_PATH` (optional override for app bundle path)
- `TARGET_PATH` (optional override for `.app` or `.dmg` sign target)
- `VERSION` (optional override for DMG naming)
- `DMG_PATH` (optional override for DMG output path)
- `CHECKSUM_PATH` (optional override for checksum output path)
- `APPLE_NOTARY_PROFILE`, `APPLE_NOTARY_KEYCHAIN`, and `ZIP_PATH` only if you are also attempting notarization

## Current `v0.2.0` Signed-Only Release Flow

Run preflight first:

```bash
./scripts/release-preflight.sh
```

Build the release app:

```bash
just release
```

Sign the `.app`, verify entitlements, and verify the app signature:

```bash
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID1234)"
export APP_PATH="$PWD/native/build/Release/Pnevma.app"

APP_PATH="$APP_PATH" ./scripts/release-macos-sign.sh
APP_PATH="$APP_PATH" ./scripts/check-entitlements.sh
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
```

Package the DMG and sign it:

```bash
export VERSION="0.2.0"
export DMG_PATH="$PWD/Pnevma-${VERSION}-macos-arm64.dmg"

APP_PATH="$APP_PATH" VERSION="$VERSION" DMG_PATH="$DMG_PATH" \
  ./scripts/release-macos-package-dmg.sh

TARGET_PATH="$DMG_PATH" ./scripts/release-macos-sign.sh
codesign --verify --verbose=2 "$DMG_PATH"
```

Run packaged launch smoke on the actual release artifact:

```bash
DMG_PATH="$DMG_PATH" ./scripts/run-packaged-launch-smoke.sh
```

`spctl` output is still useful to capture for evidence, but for this signed-only
release it is informational rather than a blocking pass condition because the
artifact is not notarized yet:

```bash
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH" || true
```

## User Install Instructions For This Release

These are the instructions that should appear on the release page and anywhere
the DMG is distributed.

1. Mount the DMG and drag `Pnevma.app` into `/Applications`.
2. In Finder, open `/Applications`.
3. Right-click `Pnevma.app` and choose `Open`.
4. Confirm the `Open` dialog.
5. If macOS still blocks the app, open **System Settings → Privacy & Security** and use **Open Anyway**, then launch `Pnevma.app` again.

Do not tell users to remove quarantine manually unless the documented Finder and
Privacy & Security flow has already been proven insufficient.

## Clean-Machine Validation

Before publishing the DMG, validate the actual user-facing install flow on a
fresh macOS user account or a second Mac.

Record:

- whether Finder `Open` alone was enough
- whether `Open Anyway` was required
- any Gatekeeper dialog text or screenshots
- whether subsequent launches worked normally after first approval

The first public `v0.2.0` DMG is not done until those instructions are tested
against the exact artifact being published.

## Remote-Enabled Release Validation

For remote-enabled candidates, also run the packaged helper and durable session
smoke flows against the signed app or signed DMG:

- [`manual-remote-ssh-tests.md`](./manual-remote-ssh-tests.md)
- [`manual-remote-durable-lifecycle-tests.md`](./manual-remote-durable-lifecycle-tests.md)

Real-host remote helper validation for remote-enabled candidates:

```bash
export REMOTE_USER="pnevma"
export REMOTE_PORT="22"
export REMOTE_IDENTITY_FILE="$HOME/.ssh/pnevma-smoke"
export REMOTE_X64_HOST="linux-x64.example.internal"
export REMOTE_ARM64_HOST="linux-arm64.example.internal"
export REMOTE_MAC_STUDIO_HOST="mac-studio.example.internal"

DMG_PATH="$DMG_PATH" \
REMOTE_HOST="$REMOTE_X64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="x86_64-unknown-linux-musl" \
SCENARIO="fresh" \
./scripts/run-packaged-remote-helper-smoke.sh

DMG_PATH="$DMG_PATH" \
REMOTE_HOST="$REMOTE_ARM64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-unknown-linux-musl" \
SCENARIO="fresh" \
./scripts/run-packaged-remote-helper-smoke.sh

DMG_PATH="$DMG_PATH" \
REMOTE_HOST="$REMOTE_MAC_STUDIO_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="fresh" \
./scripts/run-packaged-remote-helper-smoke.sh
```

Packaged remote durable lifecycle validation on the Apple Silicon Mac Studio:

```bash
DMG_PATH="$DMG_PATH" \
REMOTE_HOST="savorgserver" \
REMOTE_USER="savorgserver" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="disconnect_reconnect" \
./scripts/run-packaged-remote-durable-lifecycle-smoke.sh

DMG_PATH="$DMG_PATH" \
REMOTE_HOST="savorgserver" \
REMOTE_USER="savorgserver" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="detach_reattach" \
./scripts/run-packaged-remote-durable-lifecycle-smoke.sh

DMG_PATH="$DMG_PATH" \
REMOTE_HOST="savorgserver" \
REMOTE_USER="savorgserver" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="quit_relaunch_reattach" \
./scripts/run-packaged-remote-durable-lifecycle-smoke.sh
```

Run the canonical upgrade scenarios on the Linux `x86_64` host as documented in
[`manual-remote-ssh-tests.md`](./manual-remote-ssh-tests.md), and run the
mac-to-mac upgrade scenarios on the Apple Silicon Mac Studio using the same
harness. Then run the packaged remote durable lifecycle scenarios and the
clean-machine DMG lifecycle pass documented in
[`manual-remote-durable-lifecycle-tests.md`](./manual-remote-durable-lifecycle-tests.md).
This validation is required for remote-enabled release candidates, but it is
currently an operator-run evidence step rather than a GitHub-hosted blocking
workflow gate.

## Evidence bundle

Each release should preserve:

- SBOM output
- `codesign --verify` output
- effective entitlements plist
- DMG checksum output
- DMG mount or extraction smoke logs
- clean-machine install notes showing the documented first-launch flow worked
- any Gatekeeper screenshots captured during the clean-machine pass
- remote helper smoke logs for Linux `x86_64`, Linux `aarch64`, Apple Silicon Mac Studio, and the canonical upgrade scenarios
- remote durable lifecycle logs for the Apple Silicon Mac Studio packaged-app or DMG path
- clean-machine DMG remote lifecycle notes and any Console or crash evidence captured during failures
- remote/manual security test results

Optional when attempted:

- `spctl --assess` output
- notarization logs
- stapling logs

For `v0.2.0`, the expected evidence set is:

- entitlement allowlist check output
- effective entitlements plist from the signed app
- `codesign --verify --deep --strict --verbose=2` output for the app
- `codesign --verify --verbose=2` output for the DMG
- DMG checksum output
- packaged launch smoke output from a DMG-extracted app
- clean-machine notes confirming the documented Finder `Open` or `Open Anyway` flow
- real-host remote helper smoke logs from the packaged app or DMG on Linux `x86_64`, Linux `aarch64`, and Apple Silicon Mac Studio (`aarch64-apple-darwin`)
- canonical remote helper upgrade scenario logs from the Linux `x86_64` host and the Apple Silicon Mac Studio
- packaged remote durable lifecycle logs for `disconnect_reconnect`, `detach_reattach`, and `quit_relaunch_reattach` on the Apple Silicon Mac Studio
- clean-machine DMG remote lifecycle validation notes and any associated Console or crash evidence

## Deferred Notarized Path

Once Apple notarization is unblocked and no longer too slow to hold up the
release, the in-tree scripts still support the intended follow-up path:

```bash
APP_PATH="$APP_PATH" ./scripts/release-macos-notarize.sh
APP_PATH="$APP_PATH" ./scripts/release-macos-staple-verify.sh

TARGET_PATH="$DMG_PATH" ./scripts/release-macos-notarize.sh
TARGET_PATH="$DMG_PATH" ./scripts/release-macos-staple-verify.sh
```

That follow-up path is tracked in
[`macos-website-release-plan.md`](./macos-website-release-plan.md).

The GitHub release workflow should upload both the public DMG and a release
evidence artifact containing the records above. Release SBOM and evidence
artifacts are retained for 90 days in GitHub Actions.

If the default keychain on a maintainer machine is not the login keychain, pass
`APPLE_NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"` so
`notarytool` reads the saved `APPLE_NOTARY_PROFILE` from the expected store.

## Output locations

Default release app path:

- `native/build/Release/Pnevma.app`

Optional notarization archive path:

- `native/build/Pnevma-notarize.zip`

Default public artifact path:

- `Pnevma-0.2.0-macos-arm64.dmg`

## Version checking and update status

Pnevma includes real version checking via `AppUpdateCoordinator`, which queries
`https://api.github.com/repos/salexandr0s/pnevma/releases/latest` and compares
the remote `tag_name` against `CFBundleShortVersionString` using semantic version
comparison.

- **Automatic checks** run on launch and when the `auto_update` setting is
  toggled on, subject to a 24-hour cooldown. They are non-modal and update
  coordinator state silently.
- **Manual checks** are available from the app menu via
  `Pnevma > Check for Updates...`. They always run regardless of the
  `auto_update` setting or cooldown, and present a native alert with the result.
- When an update is available, the manual check offers to open the GitHub
  release page in the default browser.

**Blocked: full in-app self-update.** The app does not download or install
updates itself. This requires a hosted feed/appcast, Sparkle integration, and
matching security gate updates. The implementation is Sparkle-ready (update
checks, semantic version comparison, release-page handoff), but the release
process intentionally stops at discovery and operator-directed download. Update
logic is isolated behind the `ReleaseVersionChecking` protocol, but Sparkle is
not added in this release. Distribution remains manual:

1. build the native app,
2. sign the app and the DMG,
3. publish the signed DMG, checksum, release notes, and first-launch instructions on GitHub.

## See also

- [Implementation Status](./implementation-status.md)
- [Release Readiness](./release-readiness.md)
- [macOS Website Release Plan](./macos-website-release-plan.md)
