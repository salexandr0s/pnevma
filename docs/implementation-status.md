# Implementation Status

Pnevma is in the native macOS phase: the Rust workspace, Swift/AppKit shell, Ghostty integration, remote access server, and release/security tooling are all present in-tree.

## Current Priority

Release hardening is the active priority until the exit bar in [`hardening-exit-criteria.md`](./hardening-exit-criteria.md) is met.

Primary remaining work:

- stabilize native and release-rehearsal CI so `main` can reach 10 consecutive green runs
- complete clean-machine install and launch validation for the website artifact
- finish any remaining remediation-plan items that still apply to the current codebase

## Confirmed In-Tree Capabilities

- native Swift/AppKit app linked to Rust through `pnevma-bridge`
- Ghostty-backed terminal embedding and managed Ghostty settings workflow
- remote HTTP/WebSocket server with request size limits, token auth, revocation, rate limiting, and Tailscale guard rails
- CI security gates including `cargo audit`, `cargo deny`, secret scanning, and pinned GitHub Actions
- release preflight, entitlement checks, signing/notarization scripts, and rehearsal workflows
- backend-backed global app settings in `~/.config/pnevma/config.toml`

## Source of Truth

- [`macos-website-release-plan.md`](./macos-website-release-plan.md) for release sequencing and ship criteria
- [`hardening-exit-criteria.md`](./hardening-exit-criteria.md) for merge policy while hardening is active
- [`design/remediation-master-plan.md`](./design/remediation-master-plan.md) for the remaining security/test/CI backlog
- [`definition-of-done.md`](./definition-of-done.md) for quality gates on individual changes
