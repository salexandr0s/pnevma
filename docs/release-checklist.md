# Release Checklist (macOS Beta)

## Preflight (mandatory)

1. `./scripts/release-preflight.sh`
2. Continue only if preflight exits `0`.

## Build + quality gates

Preflight already runs and enforces:

1. `cargo fmt --all -- --check`
2. `cargo clippy --workspace --all-targets -- -D warnings`
3. `cargo test --workspace`
4. `cd frontend && npx tsc --noEmit && npx eslint . && npx vite build`

## Packaging

1. `./scripts/release-macos-sign.sh`
2. `./scripts/release-macos-notarize.sh`
3. `./scripts/release-macos-staple-verify.sh`

## Updater artifacts

1. Generate/load updater keypair (`./scripts/release-updater-generate-keys.sh`).
2. Generate updater overlay (`./scripts/release-updater-overlay.sh`).
3. Build updater artifact (`.app.tar.gz` or configured updater package).
4. `./scripts/release-updater-sign.sh`
5. `./scripts/release-updater-feed.sh`
6. Publish artifact + `.sig` + `latest.json`.

## Validation

1. Fresh install launch on clean machine/account.
2. Auto-update path test from previous build.
3. First-launch setup flow test:
   - readiness
   - initialize global config
   - initialize project scaffold
   - open project

## Go / no-go

Go only if:

- quality gates pass
- notarization passes
- updater manifest and signature are valid
- no blocker defects in onboarding, dispatch, review, merge, or replay flows
