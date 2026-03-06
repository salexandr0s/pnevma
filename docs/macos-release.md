# macOS Release Signing + Notarization

This repository ships a supported native macOS release flow for the notarized `.app` bundle:

- `scripts/release-preflight.sh`
- `scripts/release-macos-sign.sh`
- `scripts/release-macos-notarize.sh`
- `scripts/release-macos-staple-verify.sh`
- `scripts/check-entitlements.sh`

The legacy `scripts/release-updater-*.sh` helpers are intentionally disabled. Pnevma does not currently ship a supported auto-updater for the Swift/AppKit app.

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

## End-to-end flow

Run preflight first:

```bash
./scripts/release-preflight.sh
```

Build the release app:

```bash
just release
```

Then sign, notarize, staple, and verify:

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

## Evidence bundle

Each release should preserve:

- SBOM output
- `codesign --verify` output
- `spctl --assess` output
- effective entitlements plist
- notarization/stapling logs
- remote/manual security test results

The GitHub release workflow now uploads a `release-security-evidence` artifact containing the entitlement check, effective entitlements, `codesign`, and `spctl` output.
Release SBOM and evidence artifacts are retained for 90 days in GitHub Actions.

If the default keychain on a maintainer machine is not the login keychain, pass
`APPLE_NOTARY_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"` so
`notarytool` reads the saved `APPLE_NOTARY_PROFILE` from the expected store.

## Output locations

Default release app path:

- `native/build/Release/Pnevma.app`

Default notarization archive path:

- `native/build/Pnevma-notarize.zip`

## Auto-updater status

There is no supported native auto-updater at the moment. Distribution is manual:

1. build the native app,
2. sign, notarize, and staple it,
3. publish the notarized archive and release notes.

If updater support is introduced later, it must be documented as a native flow and added to the security release gate before use.
