# Implementation Status

Pnevma is in the native macOS phase: the Rust workspace, Swift/AppKit shell, Ghostty integration, remote access server, and release/security tooling are all present in-tree.

## Current Priority

The current focus is shipping a polished macOS release while continuing product and maintainability improvements in parallel. Release quality is important, but it is not a standing feature freeze.

Current release target:

- version: `v0.2.0`
- artifact: Developer ID signed `arm64` macOS `.dmg` for the first public cut, with notarization deferred
- evidence: SBOM, entitlement output, effective entitlements, `codesign` output, checksum, packaged launch smoke output, clean-machine install notes, and verified first-launch instructions

Primary remaining release work:

- resolve `disable-library-validation` entitlement story (remove or retain with signed-build evidence)
- keep native and release-rehearsal lanes green and stable
- validate and document the Finder `Open` / `Open Anyway` first-launch path on a clean machine
- execute manual smoke and security tests against the candidate DMG artifact
- assemble final release evidence bundle and complete sign-off

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
