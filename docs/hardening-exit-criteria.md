# Hardening Exit Criteria

Feature work stays frozen until the runtime hardening bar below is met.

## Exit Bar

Hardening is complete only when all of the following are true:

1. Dispatch, event, and restore integration tests are merged and green.
2. Ghostty smoke runs in CI and is green.
3. Native warning-free gates are enforced in CI for `swift test`, `xcodebuild build`, and `xcodebuild test`.
4. Release package preflight is green on `main`.
5. Sign/notarize rehearsal is green anywhere the Apple signing and `notarytool`
   credential secrets are available.
6. `main` has at least 10 consecutive green runs across the native and release-rehearsal lanes.

## Merge Policy During Hardening

Until the exit bar is met, only the following classes of changes may merge:

- bug fixes
- tests
- CI/build hardening
- release pipeline hardening
- Ghostty/runtime verification changes

The following do not merge during hardening:

- new product features
- unrelated refactors
- speculative architecture changes

## CI Jobs

- `CI / Rust checks`
- `CI / Native app build`
- `Release Rehearsal / Release package preflight`
- `Release Rehearsal / Release sign/notarize dry run`

The rehearsal lanes are expected to validate the public `v0.1.1` DMG release
path, not a legacy `tar.gz` archive path.

## Smoke Commands

- `just ghostty-smoke`
- `APP_PATH=/path/to/Pnevma.app ./scripts/run-packaged-launch-smoke.sh`

## First Queue After Hardening

When the exit bar is met, resume product work in this order:

1. terminal/runtime reliability polish
2. session recovery polish
3. dispatch and replay UX polish

## See also

- [Implementation Status](./implementation-status.md)
- [macOS Website Release Plan](./macos-website-release-plan.md)
- [macOS Release Runbook](./macos-release.md)
