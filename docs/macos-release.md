# macOS Release Signing + Notarization

This repository ships helper scripts for local macOS release packaging and updater feed publication in `scripts/`:

- `scripts/release-preflight.sh`
- `scripts/release-macos-sign.sh`
- `scripts/release-macos-notarize.sh`
- `scripts/release-macos-staple-verify.sh`
- `scripts/release-updater-generate-keys.sh`
- `scripts/release-updater-overlay.sh`
- `scripts/release-updater-sign.sh`
- `scripts/release-updater-feed.sh`

## Prerequisites

1. Xcode command line tools installed (`xcode-select --install`).
2. `cargo-tauri` installed (`cargo install tauri-cli`).
3. Apple Developer Developer ID signing certificate installed in Keychain.
4. Notary tool profile configured in Keychain.
5. Updater keypair generated once for the product (private key kept offline/secret storage).

Example profile setup:

```bash
xcrun notarytool store-credentials "pnevma-notary" \
  --apple-id "you@example.com" \
  --team-id "TEAMID1234" \
  --password "app-specific-password"
```

## Environment variables

- `APPLE_SIGNING_IDENTITY` (required by signing script)
- `APPLE_NOTARY_PROFILE` (required by notarization script)
- `APP_PATH` (optional override for app bundle path)
- `ZIP_PATH` (optional override for notarization zip path)
- `PNEVMA_UPDATER_PRIVATE_KEY_PATH` (required by updater sign script)
- `PNEVMA_UPDATER_PRIVATE_KEY_PASSWORD` (optional if key is unencrypted)
- `PNEVMA_UPDATER_ENDPOINT` (required by updater overlay script)
- `PNEVMA_UPDATER_PUBKEY` (required by updater overlay script)
- `OVERLAY_PATH` (optional updater overlay output path)
- `ARTIFACT_PATH` (required by updater sign/feed scripts)
- `SIGNATURE_PATH` (required by updater feed script; defaults to `$ARTIFACT_PATH.sig` in sign script)
- `VERSION` (required by updater feed script)
- `TARGET_TRIPLE` (required by updater feed script, example: `darwin-aarch64`)
- `BASE_URL` (required by updater feed script; public URL prefix)
- `FEED_PATH` (optional updater feed output path)

## End-to-end flow

Run strict preflight first:

```bash
./scripts/release-preflight.sh
```

Then run packaging/notarization:

```bash
export APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID1234)"
export APPLE_NOTARY_PROFILE="pnevma-notary"

./scripts/release-macos-sign.sh
./scripts/release-macos-notarize.sh
./scripts/release-macos-staple-verify.sh
```

## Updater feed flow (manual)

1. Generate updater keys once (or use your existing key):

```bash
./scripts/release-updater-generate-keys.sh
```

2. Keep `crates/pnevma-app/tauri.conf.json` placeholders in-repo; inject production updater endpoint/pubkey via overlay at release time.
3. Generate updater overlay config from production endpoint/pubkey:

```bash
export PNEVMA_UPDATER_ENDPOINT="https://updates.example.com/pnevma/{{target}}/{{arch}}/{{current_version}}"
export PNEVMA_UPDATER_PUBKEY="$(cat "$HOME/.config/pnevma/updater/private.key.pub")"
./scripts/release-updater-overlay.sh
```

4. Build updater artifact bundle (with overlay):

```bash
cargo tauri build --manifest-path crates/pnevma-app/Cargo.toml -c target/release/updater-overlay.json
```

5. Sign artifact using updater private key.
6. Generate `latest.json`.
7. Publish artifact + signature + `latest.json` to feed host.

Example:

```bash
export ARTIFACT_PATH="target/release/bundle/macos/Pnevma.app.tar.gz"
export PNEVMA_UPDATER_PRIVATE_KEY_PATH="$HOME/.config/pnevma/updater/private.key"
export PNEVMA_UPDATER_PRIVATE_KEY_PASSWORD="your-key-password"   # optional
export VERSION="0.1.0"
export TARGET_TRIPLE="darwin-aarch64"
export BASE_URL="https://updates.example.com/pnevma"

./scripts/release-updater-generate-keys.sh
./scripts/release-updater-sign.sh
export SIGNATURE_PATH="$ARTIFACT_PATH.sig"
./scripts/release-updater-feed.sh
```

## Output locations

Default app path:

- `target/release/bundle/macos/Pnevma.app`

Default notarization archive path:

- `target/release/bundle/macos/Pnevma-notarize.zip`

Default updater manifest path:

- `target/release/bundle/updater/latest.json`

## Notes

- Updater feed publication remains manual-by-design in this phase.
- Keep updater private key outside the repository and CI logs.
