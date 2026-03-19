# Release Readiness

Pnevma does not use a standing repo-wide feature freeze as policy. This document tracks the quality bar for the next public macOS release and the checks that should be green before publishing a candidate.

## Release Gate

A release candidate is ready only when all of the following are true:

1. Dispatch, event, and restore integration tests are merged and green.
2. Ghostty smoke runs in CI and is green.
3. Native warning-free gates are enforced in CI for `swift test`, `xcodebuild build`, and `xcodebuild test`.
4. Release package preflight is green on `main`.
5. Sign/notarize rehearsal is green anywhere the Apple signing and `notarytool` credential secrets are available.
6. `main` is stable across the native and release-rehearsal lanes, with recent consecutive green runs before cutting the candidate.
7. For remote-enabled candidates, operator-run real-host remote helper smoke evidence exists for Linux `x86_64`, Linux `aarch64`, Apple Silicon Mac Studio (`aarch64-apple-darwin`), the canonical upgrade scenarios on Linux `x86_64` and the Mac Studio, packaged remote durable lifecycle evidence exists for the Apple Silicon Mac Studio path, and a clean-machine DMG remote lifecycle pass is recorded.

## CI Jobs

- `CI / Rust checks`
- `CI / Native app build`
- `Release Rehearsal / Release package preflight`
- `Release Rehearsal / Release sign/notarize dry run`

The rehearsal lanes are expected to validate the public `v0.2.0` DMG release path, not a legacy `tar.gz` archive path.

## Smoke Commands

- `just ghostty-smoke`
- `APP_PATH=/path/to/Pnevma.app ./scripts/run-packaged-launch-smoke.sh`
- `APP_PATH=/path/to/Pnevma.app REMOTE_HOST=... REMOTE_USER=... EXPECTED_TARGET_TRIPLE=... SCENARIO=... ./scripts/run-packaged-remote-helper-smoke.sh`
- `APP_PATH=/path/to/Pnevma.app REMOTE_HOST=savorgserver REMOTE_USER=savorgserver EXPECTED_TARGET_TRIPLE=aarch64-apple-darwin SCENARIO=... ./scripts/run-packaged-remote-durable-lifecycle-smoke.sh`

## Current Release Focus

Keep these visible while normal product and maintainability work continues:

1. terminal/runtime reliability polish
2. session recovery polish
3. command-center and review-surface usability
4. release evidence capture and clean-machine validation

## See also

- [Implementation Status](./implementation-status.md)
- [macOS Website Release Plan](./macos-website-release-plan.md)
- [macOS Release Runbook](./macos-release.md)
