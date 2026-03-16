# Implementation Status

Pnevma is in the native macOS phase: the Rust workspace, Swift/AppKit shell, Ghostty integration, remote access server, and release/security tooling are all present in-tree.

## Current Priority

Release hardening is the active priority until the exit bar in [`hardening-exit-criteria.md`](./hardening-exit-criteria.md) is met.

**Feature work is frozen until the hardening exit bar in hardening-exit-criteria.md is met. No new features merge to main.**

Current release target:

- version: `v0.2.0`
- artifact: notarized, stapled `arm64` macOS `.dmg`
- evidence: SBOM, entitlement output, effective entitlements, `codesign`,
  `spctl`, notarization logs, stapling logs, checksum, and packaged launch
  smoke output

Primary remaining work:

- resolve `disable-library-validation` entitlement story (remove or retain with signed-build evidence)
- achieve 10 consecutive green CI runs across native and release-rehearsal lanes
- execute manual smoke and security tests against the candidate DMG artifact
- assemble final hardening evidence bundle and complete sign-off

## Confirmed In-Tree Capabilities

- native Swift/AppKit app linked to Rust through `pnevma-bridge`
- Ghostty-backed terminal embedding and managed Ghostty settings workflow
- remote HTTP/WebSocket server with request size limits, token auth, revocation, rate limiting, and Tailscale guard rails
- CI security gates including `cargo audit`, `cargo deny`, secret scanning, and pinned GitHub Actions
- release preflight, entitlement checks, signing/notarization scripts, and rehearsal workflows
- documented `v0.2.0` release identity, DMG artifact target, and GitHub notarization secret contract
- backend-backed global app settings in `~/.config/pnevma/config.toml`

## Source of Truth

- [`macos-website-release-plan.md`](./macos-website-release-plan.md) for release sequencing and ship criteria
- [`hardening-exit-criteria.md`](./hardening-exit-criteria.md) for merge policy while hardening is active
- [`design/remediation-master-plan.md`](./design/remediation-master-plan.md) for the remaining security/test/CI backlog
- [`definition-of-done.md`](./definition-of-done.md) for quality gates on individual changes

## See also

- [Documentation Index](./README.md)
- [Getting Started](./getting-started.md)
- [macOS Release Runbook](./macos-release.md)
