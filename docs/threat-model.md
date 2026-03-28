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
- a shared redaction engine on session/event/log/context/review persistence paths, including structured JSON sensitive-key redaction plus provider-token and env-assignment coverage
- remote audit context for issued, used, and revoked tokens using a safe token identifier and subject attribution fallback
- CI checks for Rust quality/security, shell/workflow hygiene, and entitlement allowlist drift
- release evidence bundle with SBOM, entitlements, `codesign`, and `spctl` output

## Required verification

- auth bypass, token expiry/revocation, and RPC allowlist tests
- WebSocket size/rate/subscription abuse tests
- password-file hardening tests for remote and socket auth
- end-to-end redaction tests across structured and unstructured outputs
- provider-token and env-assignment regression tests across stream buffering, persisted scrollback, event payloads, and compiled context output
- manual latency validation on release candidates
- sign/notarize/staple/Gatekeeper verification on release builds

## Accepted risks and design decisions

### No App Sandbox

Pnevma spawns `tmux`, `git`, `ssh-keygen`, and agent CLIs that require unrestricted filesystem and network access. App Sandbox is architecturally incompatible with this execution model. Mitigation: hardened runtime with minimal entitlements, code signing, and notarization.

### No process isolation for Ghostty

The embedded terminal (libghostty/GhosttyKit) runs in-process. A vulnerability in the terminal renderer would have full process access. Mitigation: Ghostty is vendored at a pinned commit with hash verification; updates are deliberate and reviewed.

### OSC 52 clipboard writes

The terminal supports OSC 52 (clipboard write escape sequence), consistent with terminal emulator norms. A malicious program running in the terminal can write to the system clipboard. This is standard terminal behavior; users who run untrusted code in terminals accept this risk.

### `$EDITOR` spawned with path validation

When opening files in an external editor, the `$EDITOR` environment variable is resolved to an absolute path and verified to exist before spawning. Shell metacharacters are not evaluated. This remains a local-user-only risk — the user controls their own `$EDITOR` value.

### Prompt injection sanitizer gaps

Secret redaction now covers provider-token and env-assignment formats in addition to the legacy patterns, but it still relies on regex heuristics. This is defense-in-depth, not a complete solution. Iterative improvement of redaction patterns is expected.

### Shared remote password model

Remote auth now records a subject and safe token identifier for issued, used, and revoked tokens, but the default subject remains `shared-password`. This is weaker than per-user identity and should be treated as acceptable only for single-operator or tightly shared admin use.

### `npx` in agent command allowlist

The `npx` binary can execute arbitrary npm packages. Agent access to `npx` requires explicit package names in `npx_allowed_packages`; wildcard access is rejected at config validation time. When `allow_npx` is true but `npx_allowed_packages` is empty, the config is rejected with an `InvalidConfig` error — no wildcard fallback exists.

### SBOM attestation

Release SBOMs are generated (CycloneDX JSON) and attested via GitHub Actions build provenance (`actions/attest-build-provenance@v2.2.3`). Attestation includes both the release archive and SBOM artifact. The release workflow uses `id-token: write` permission for OIDC-based signing.

## Residual risks to track

- the checked-in hardened-runtime entitlement allowlist currently keeps only `com.apple.security.network.client`; `disable-library-validation` remains a signed-build Ghostty validation decision before public release
- project-level data retention can prune stale review packs, knowledge artifacts, feedback attachments, telemetry exports, and completed session scrollback when enabled in `pnevma.toml`
- no supported native auto-updater exists yet, so release distribution remains manual
