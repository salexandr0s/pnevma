# Threat Model

## Scope

Pnevma is a native macOS application with a Rust backend, a local Unix-socket control plane, and an optional Tailscale-reachable HTTPS/WebSocket remote surface.

Assurance target:

- ASVS L2 baseline across the repo
- L3-depth verification for auth, session access control, secret handling, remote access, and release integrity

## Primary assets

- provider API keys and shared auth passwords
- SSH private keys and profiles
- project source code, review packs, context manifests, and scrollback
- remote auth tokens
- signed macOS release artifacts and notarization evidence

## Trust boundaries

1. Swift/AppKit UI <-> Rust FFI bridge
2. Rust backend <-> spawned CLIs (`tmux`, `git`, `ssh`, agent CLIs)
3. Rust backend <-> SQLite and append-only event log
4. Rust backend <-> Keychain
5. Rust backend <-> same-user or password-authenticated Unix socket clients
6. Rust backend <-> authenticated remote HTTPS/WebSocket clients over Tailscale/TLS
7. CI/release pipeline <-> GitHub secrets, Apple signing identity, notarization service

## Main attack paths

### Remote access misuse

- token theft or replay against `/api/*` or `/ws`
- abusing overly broad RPC exposure
- WebSocket fan-out abuse through excessive subscriptions or oversized traffic

### Local control-plane abuse

- connecting to the Unix socket from an unexpected user
- weak or exposed password-file configuration
- oversized local JSON payloads intended to exhaust memory or bypass parsing assumptions

### Command execution and session supervision

- shell/CLI injection through task/session input
- path escape or repository escape during worktree and file operations
- unsafe command allowlists for spawned sessions

### Data exposure

- secrets leaking into scrollback, event logs, notifications, review packs, or context manifests
- release/debug logging persisting sensitive payloads
- long-lived artifact retention exposing stale project data

### Supply chain and release chain

- unexpected entitlements in the shipped app
- undocumented Ghostty vendor drift
- signing/notarization evidence missing or unverifiable

## Current controls

- same-user socket auth plus optional password mode
- password source precedence of env -> Keychain -> secure file
- fail-closed password-file owner/mode checks
- remote config validation for TLS/origin/rate-limit settings
- token auth, rate limiting, payload limits, and RPC allowlisting on the remote surface
- redaction on event/log/context/review persistence paths, including structured JSON sensitive-key redaction
- CI checks for Rust quality/security, shell/workflow hygiene, and entitlement allowlist drift
- release evidence bundle with SBOM, entitlements, `codesign`, and `spctl` output

## Required verification

- auth bypass, token expiry/revocation, and RPC allowlist tests
- WebSocket size/rate/subscription abuse tests
- password-file hardening tests for remote and socket auth
- end-to-end redaction tests across structured and unstructured outputs
- manual latency validation on release candidates
- sign/notarize/staple/Gatekeeper verification on release builds

## Residual risks to track

- the hardened-runtime exception set is now reduced to `com.apple.security.cs.disable-library-validation`; validate regularly whether GhosttyKit still requires it on signed release builds
- project-level data retention can prune stale review packs, knowledge artifacts, feedback attachments, telemetry exports, and completed session scrollback when enabled in `pnevma.toml`
- no supported native auto-updater exists yet, so release distribution remains manual
