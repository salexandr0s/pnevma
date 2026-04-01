# Implementation Status

Pnevma is in the native macOS phase: the Rust workspace, Swift/AppKit shell, Ghostty integration, remote access server, and release/security tooling are all present in-tree.

## Current Priority

The current focus is shipping a polished macOS release while continuing product and maintainability improvements in parallel. Release quality is important, but it is not a standing feature freeze.

Current release target:

- version: `v0.2.0`
- artifact: Developer ID signed `arm64` macOS `.dmg` for the first public cut, with notarization deferred
- evidence: SBOM, entitlement output, effective entitlements, `codesign` output, app and DMG `spctl` output, checksum, packaged launch smoke output, CI green-run report, clean-machine install notes, remote validation evidence when remote ships, and verified first-launch instructions

Primary remaining release work:

- keep native and release-rehearsal lanes green and stable
- record the required consecutive green `main` runs and archive the CI report in the release evidence bundle
- regenerate the canonical signed candidate and evidence bundle from the current release-train head before publish
- validate and document the Finder `Open` / `Open Anyway` first-launch path on a clean machine
- execute manual smoke and security tests against the candidate DMG artifact
- execute remote helper, upgrade, and durable lifecycle validation for the release candidate
- assemble final release evidence bundle and complete sign-off

Most recent local verification:

- April 1, 2026: `just check` green
- April 1, 2026: `just spm-test-clean` green
- April 1, 2026: `just xcode-build-release` green
- April 1, 2026: local Developer ID-signed candidate DMG + evidence bundle generated successfully
- April 1, 2026: signed app launch smoke, Ghostty smoke, DMG packaging, and packaged launch smoke green on the signed candidate
- April 1, 2026: `scripts/probe-disable-library-validation.sh` confirmed the signed candidate works without `com.apple.security.cs.disable-library-validation`, so the checked-in allowlist keeps it removed
- April 1, 2026: effective entitlements on the signed app remained limited to `com.apple.security.network.client`
- March 27, 2026: full release-local verification green:
  - `just xcode-test` green
  - `just ghostty-smoke` green
  - `just xcode-build-release` green
  - `APP_PATH="$PWD/native/build/Release/Pnevma.app" ./scripts/run-packaged-launch-smoke.sh` green
  - `./scripts/check-entitlements.sh` green for the checked-in source allowlist
  - effective entitlements on the app bundle remain a signed-build-only check because unsigned local release builds do not embed them

## Confirmed In-Tree Capabilities

- native Swift/AppKit app linked to Rust through `pnevma-bridge`
- Ghostty-backed terminal embedding and managed Ghostty settings workflow
- remote HTTP/WebSocket server with request size limits, token auth, revocation, rate limiting, and Tailscale guard rails
- CI security gates including `cargo audit`, `cargo deny`, secret scanning, and pinned GitHub Actions
- release preflight, entitlement checks, signing/notarization scripts, and rehearsal workflows
- documented `v0.2.0` release identity, DMG artifact target, and first-launch install guidance for the signed-only initial DMG
- backend-backed global app settings in `~/.config/pnevma/config.toml`

## Source of Truth

- [`macos-website-release-plan.md`](./macos-website-release-plan.md) for release sequencing and ship criteria
- [`release-readiness.md`](./release-readiness.md) for release quality gates and validation checks
- [`design/remediation-master-plan.md`](./design/remediation-master-plan.md) for the remaining security/test/CI backlog
- [`definition-of-done.md`](./definition-of-done.md) for quality gates on individual changes

## See also

- [Documentation Index](./README.md)
- [Getting Started](./getting-started.md)
- [macOS Release Runbook](./macos-release.md)
