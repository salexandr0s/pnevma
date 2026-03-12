# macOS Release Signing + Notarization

Pnevma `v0.1.1` targets a public website release distributed as a notarized,
stapled `arm64` macOS `.dmg`. The release workflow still signs and validates the
inner `.app` first, then packages and notarizes the public DMG artifact.

This repository ships a supported native macOS release flow for the signed app
bundle:

- `scripts/release-preflight.sh`
- `scripts/release-macos-sign.sh`
- `scripts/release-macos-notarize.sh`
- `scripts/release-macos-staple-verify.sh`
- `scripts/check-entitlements.sh`

The legacy `scripts/release-updater-*.sh` helpers are intentionally disabled.
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
export VERSION="0.1.1"
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

## Evidence bundle

Each release should preserve:

- SBOM output
- `codesign --verify` output
- `spctl --assess` output
- effective entitlements plist
- notarization/stapling logs
- DMG checksum output
- DMG mount or extraction smoke logs
- remote/manual security test results

For `v0.1.1`, the expected evidence set is:

- entitlement allowlist check output
- effective entitlements plist from the signed app
- `codesign --verify --deep --strict --verbose=2` output for the app
- `spctl --assess --type execute --verbose=4` output for the app
- app notarization submission and stapling logs
- DMG notarization submission and stapling logs
- packaged launch smoke output from a DMG-extracted app
- `Pnevma-0.1.1-macos-arm64.dmg.sha256`
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

- `Pnevma-0.1.1-macos-arm64.dmg`

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
- [Hardening Exit Criteria](./hardening-exit-criteria.md)
- [macOS Website Release Plan](./macos-website-release-plan.md)
