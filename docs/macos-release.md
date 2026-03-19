# macOS Release Signing + Notarization

Pnevma `v0.2.0` targets a public website release distributed as a notarized,
stapled `arm64` macOS `.dmg`. The release workflow still signs and validates the
inner `.app` first, then packages and notarizes the public DMG artifact.

This repository ships a supported native macOS release flow for the signed app
bundle:

- `scripts/release-preflight.sh`
- `scripts/release-macos-sign.sh`
- `scripts/release-macos-notarize.sh`
- `scripts/release-macos-staple-verify.sh`
- `scripts/check-entitlements.sh`

Pnevma ships real version checking against GitHub releases but does not yet
perform in-app self-update.

## Prerequisites

1. Xcode command line tools installed (`xcode-select --install`).
2. Apple Developer ID Application certificate installed in Keychain.
3. `notarytool` profile stored in Keychain.
4. `just`, `xcodegen`, Rust, and Zig installed for the local build.

Example notary profile setup:

```bash
xcrun notarytool store-credentials "pnevma-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID1234" \
  --password "app-specific-password"
```

## Environment variables

- `APPLE_SIGNING_IDENTITY` (required by signing script)
- `APPLE_NOTARY_PROFILE` (required by notarization script)
- `APPLE_NOTARY_KEYCHAIN` (optional override for the keychain containing the notary profile)
- `APP_PATH` (optional override for app bundle path)
- `ZIP_PATH` (optional override for notarization archive path)

## GitHub Actions secret setup

GitHub Actions needs both signing material and the credentials required to
create a `notarytool` keychain profile on the runner. Configure the repository
secrets below before expecting the release-rehearsal notarization jobs to go
green:

Native GitHub workflows are pinned to the `macos-26` runner image because the
vendored Ghostty `v1.2.0` build requires the Xcode 26/macOS 26 toolchain line.

- `APPLE_CERTIFICATE`: base64-encoded `Developer ID Application` `.p12`
- `APPLE_CERTIFICATE_PASSWORD`: password for the `.p12`
- `APPLE_SIGNING_IDENTITY`: exact identity string, for example
  `Developer ID Application: Your Name (TEAMID1234)`
- `KEYCHAIN_PASSWORD`: password for the temporary runner keychain
- `APPLE_NOTARY_PROFILE`: `pnevma-notary`
- `APPLE_NOTARY_APPLE_ID`: Apple ID used for notarization
- `APPLE_NOTARY_TEAM_ID`: Apple Developer Team ID
- `APPLE_NOTARY_PASSWORD`: app-specific password for the Apple ID above

Recommended setup from a maintainer machine:

```bash
gh secret set APPLE_CERTIFICATE --repo salexandr0s/pnevma < certificate.p12.base64
gh secret set APPLE_CERTIFICATE_PASSWORD --repo salexandr0s/pnevma
gh secret set APPLE_SIGNING_IDENTITY --repo salexandr0s/pnevma
gh secret set KEYCHAIN_PASSWORD --repo salexandr0s/pnevma
gh secret set APPLE_NOTARY_PROFILE --repo salexandr0s/pnevma --body "pnevma-notary"
gh secret set APPLE_NOTARY_APPLE_ID --repo salexandr0s/pnevma
gh secret set APPLE_NOTARY_TEAM_ID --repo salexandr0s/pnevma
gh secret set APPLE_NOTARY_PASSWORD --repo salexandr0s/pnevma
```

The workflow should then run:

```bash
xcrun notarytool store-credentials "$APPLE_NOTARY_PROFILE" \
  --apple-id "$APPLE_NOTARY_APPLE_ID" \
  --team-id "$APPLE_NOTARY_TEAM_ID" \
  --password "$APPLE_NOTARY_PASSWORD" \
  --keychain "$KEYCHAIN_PATH"
```

## End-to-end flow

Run preflight first:

```bash
./scripts/release-preflight.sh
```

Build the release app:

```bash
just release
```

Then sign, notarize, staple, and verify the inner app:

```bash
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID1234)"
export APPLE_NOTARY_PROFILE="pnevma-notary"
export APPLE_NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
export APP_PATH="native/build/Release/Pnevma.app"

APP_PATH="$APP_PATH" ./scripts/release-macos-sign.sh
APP_PATH="$APP_PATH" ./scripts/release-macos-notarize.sh
APP_PATH="$APP_PATH" ./scripts/release-macos-staple-verify.sh
APP_PATH="$APP_PATH" ./scripts/check-entitlements.sh
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
spctl --assess --type exec --verbose=4 "$APP_PATH"
```

Package and validate the public DMG artifact from the stapled app:

```bash
export VERSION="0.2.0"
export DMG_DIR="$PWD/native/build/dmg"
export DMG_STAGING="$DMG_DIR/Pnevma"
export DMG_PATH="$PWD/Pnevma-${VERSION}-macos-arm64.dmg"

mkdir -p "$DMG_STAGING"
rm -rf "$DMG_STAGING/Pnevma.app" "$DMG_PATH"
cp -R "$APP_PATH" "$DMG_STAGING/Pnevma.app"

hdiutil create -volname "Pnevma" \
  -srcfolder "$DMG_STAGING" \
  -ov -format UDZO \
  "$DMG_PATH"

codesign --force --sign "$APPLE_SIGNING_IDENTITY" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$APPLE_NOTARY_PROFILE" \
  --keychain "$APPLE_NOTARY_KEYCHAIN" \
  --wait
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --verbose=4 "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
```

Final packaged-artifact rehearsal:

```bash
export DMG_MOUNT="$(mktemp -d /tmp/pnevma-dmg.XXXXXX)"
hdiutil attach "$DMG_PATH" -mountpoint "$DMG_MOUNT" -nobrowse
cp -R "$DMG_MOUNT/Pnevma.app" "$PWD/native/build/Pnevma-smoke.app"
APP_PATH="$PWD/native/build/Pnevma-smoke.app" ./scripts/run-packaged-launch-smoke.sh
hdiutil detach "$DMG_MOUNT"
```

Real-host remote helper validation for remote-enabled candidates:

```bash
export REMOTE_USER="pnevma"
export REMOTE_PORT="22"
export REMOTE_IDENTITY_FILE="$HOME/.ssh/pnevma-smoke"
export REMOTE_X64_HOST="linux-x64.example.internal"
export REMOTE_ARM64_HOST="linux-arm64.example.internal"
export REMOTE_MAC_STUDIO_HOST="mac-studio.example.internal"

APP_PATH="$PWD/native/build/Pnevma-smoke.app" \
REMOTE_HOST="$REMOTE_X64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="x86_64-unknown-linux-musl" \
SCENARIO="fresh" \
./scripts/run-packaged-remote-helper-smoke.sh

APP_PATH="$PWD/native/build/Pnevma-smoke.app" \
REMOTE_HOST="$REMOTE_ARM64_HOST" \
REMOTE_USER="$REMOTE_USER" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-unknown-linux-musl" \
SCENARIO="fresh" \
./scripts/run-packaged-remote-helper-smoke.sh

APP_PATH="$PWD/native/build/Pnevma-smoke.app" \
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
APP_PATH="$PWD/native/build/Pnevma-smoke.app" \
REMOTE_HOST="savorgserver" \
REMOTE_USER="savorgserver" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="disconnect_reconnect" \
./scripts/run-packaged-remote-durable-lifecycle-smoke.sh

APP_PATH="$PWD/native/build/Pnevma-smoke.app" \
REMOTE_HOST="savorgserver" \
REMOTE_USER="savorgserver" \
REMOTE_PORT="$REMOTE_PORT" \
REMOTE_IDENTITY_FILE="$REMOTE_IDENTITY_FILE" \
EXPECTED_TARGET_TRIPLE="aarch64-apple-darwin" \
SCENARIO="detach_reattach" \
./scripts/run-packaged-remote-durable-lifecycle-smoke.sh

APP_PATH="$PWD/native/build/Pnevma-smoke.app" \
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
- `spctl --assess` output
- effective entitlements plist
- notarization/stapling logs
- DMG checksum output
- DMG mount or extraction smoke logs
- remote helper smoke logs for Linux `x86_64`, Linux `aarch64`, Apple Silicon Mac Studio, and the canonical upgrade scenarios
- remote durable lifecycle logs for the Apple Silicon Mac Studio packaged-app or DMG path
- clean-machine DMG remote lifecycle notes and any Console or crash evidence captured during failures
- remote/manual security test results

For `v0.2.0`, the expected evidence set is:

- entitlement allowlist check output
- effective entitlements plist from the signed app
- `codesign --verify --deep --strict --verbose=2` output for the app
- `spctl --assess --type execute --verbose=4` output for the app
- app notarization submission and stapling logs
- DMG notarization submission and stapling logs
- packaged launch smoke output from a DMG-extracted app
- real-host remote helper smoke logs from the packaged app or DMG on Linux `x86_64`, Linux `aarch64`, and Apple Silicon Mac Studio (`aarch64-apple-darwin`)
- canonical remote helper upgrade scenario logs from the Linux `x86_64` host and the Apple Silicon Mac Studio
- packaged remote durable lifecycle logs for `disconnect_reconnect`, `detach_reattach`, and `quit_relaunch_reattach` on the Apple Silicon Mac Studio
- clean-machine DMG remote lifecycle validation notes and any associated Console or crash evidence
- `Pnevma-0.2.0-macos-arm64.dmg.sha256`
- SBOM artifact(s)

The GitHub release workflow should upload both the public DMG and a release
evidence artifact containing the records above. Release SBOM and evidence
artifacts are retained for 90 days in GitHub Actions.

If the default keychain on a maintainer machine is not the login keychain, pass
`APPLE_NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"` so
`notarytool` reads the saved `APPLE_NOTARY_PROFILE` from the expected store.

## Output locations

Default release app path:

- `native/build/Release/Pnevma.app`

Default notarization archive path:

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
2. sign, notarize, and staple it,
3. publish the notarized DMG, checksum, and release notes on GitHub.

## See also

- [Implementation Status](./implementation-status.md)
- [Release Readiness](./release-readiness.md)
- [macOS Website Release Plan](./macos-website-release-plan.md)
