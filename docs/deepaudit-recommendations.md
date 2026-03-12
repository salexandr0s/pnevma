# Deep Audit Recommendations — Pnevma

**Date**: 2026-03-09
**Assurance target**: ASVS L2 baseline, L3 on auth/sessions/access-control/crypto/secrets
**Risk lens**: OWASP Top 10 (2021)

---

## Critical (fix before next release)

### C1. WebSocket `SessionInput` bypasses RPC allowlist

**File**: `crates/pnevma-remote/src/routes/ws.rs`
**OWASP**: A01 Broken Access Control
**ASVS**: V4.1.2 (principle of least privilege for every request)

`WsClientMessage::SessionInput` routes directly through the WebSocket handler, not through `rpc_allowlist.rs`. The allowlist explicitly excludes `session.send_input`, yet a remote WebSocket client can write arbitrary bytes to a PTY session via this message type — full user-level RCE over Tailscale.

**Change**: Add an explicit allowlist check (or a dedicated feature gate) for `SessionInput` in the WebSocket message handler. If remote session input is intentionally supported, it must be gated behind an opt-in config flag (`remote.allow_session_input = false` by default) and logged at `warn!` level with the token subject and session ID.

---

### C2. `npx` in agent command allowlist enables arbitrary code execution

**File**: `crates/pnevma-agents/src/claude.rs` (auto_approve allowlist)
**OWASP**: A03 Injection
**ASVS**: V5.3.8 (OS command parameter injection)

The `--allowedTools` allowlist includes `Bash(npm *)` which permits `npm exec` / `npx` to run arbitrary npm packages. This is documented as an accepted risk in `docs/threat-model.md` but has no compensating control.

**Change**: Restrict the npm pattern to `Bash(npm install *),Bash(npm test *),Bash(npm run *)` — exclude `npm exec`, `npm x`, `npx`. If broader npm access is needed, add a per-project opt-in flag in `pnevma.toml` under `[agents]` (e.g., `allow_npx = false`).

---

### C3. `cb_ctx` cast to `usize` for `Send` across async boundary

**File**: `crates/pnevma-bridge/src/lib.rs` — `pnevma_call_async`
**OWASP**: N/A (memory safety)
**ASVS**: V14.2.1 (components use safe coding patterns)

The raw `*mut c_void` callback context is cast to `usize` to satisfy `Send` bounds on the `tokio::spawn` future. If Swift deallocates or reuses the context object before the async callback fires, this is use-after-free. The `LIFETIME CONTRACT` doc comment places responsibility on the Swift caller, but no runtime validation exists.

**Change**: Add a generation counter or `Arc<AtomicBool>` invalidation flag that the Swift side sets on dealloc. In the callback wrapper, check the flag before invoking. Alternatively, wrap `cb_ctx` in a `Pin<Arc<...>>` shared between Swift and Rust so the Rust side holds a strong reference. Document the chosen approach as a `SAFETY` proof in the code.

---

## High (fix within current development cycle)

### H1. Password-file race condition (TOCTOU)

**File**: `crates/pnevma-commands/src/auth_secret.rs`
**OWASP**: A01 Broken Access Control
**ASVS**: V2.1.1 (credential storage security)

The password-file loader checks permissions (mode, uid, symlink) then reads the file in separate syscalls. A local attacker with write access to the parent directory could swap the file between check and read.

**Change**: Open the file first (obtaining an fd), then `fstat` the fd (not the path) to verify owner/mode, then read from the fd. This eliminates the TOCTOU window. Use `std::os::unix::fs::MetadataExt` on the open `File` handle.

```rust
// Before (TOCTOU):
let meta = fs::symlink_metadata(&path)?;  // stat the path
validate_permissions(&meta)?;
let content = fs::read_to_string(&path)?;  // open+read the path

// After (atomic):
let file = fs::File::open(&path)?;
let meta = file.metadata()?;              // fstat the fd
validate_permissions(&meta)?;
let mut content = String::new();
file.read_to_string(&mut content)?;       // read the same fd
```

---

### H2. Remote token stored in `DashMap` without constant-time comparison

**File**: `crates/pnevma-remote/src/auth.rs` — `TokenStore`
**OWASP**: A02 Cryptographic Failures
**ASVS**: V6.2.2 (timing-safe comparison for secrets)

Token lookup uses `DashMap::get()` which performs a standard `HashMap` key lookup (hash + `eq`). The `eq` on `String` is not constant-time. While the 256-bit token entropy makes timing attacks impractical, ASVS L3 requires constant-time comparison for all secret material.

**Change**: Store tokens hashed (SHA-256) in the `DashMap` key. On validation, hash the presented token and look up the hash. This makes timing on the lookup irrelevant and also avoids storing raw tokens in memory.

```rust
// Token issuance:
let raw_token = generate_token();          // 256-bit hex
let token_hash = Sha256::digest(raw_token.as_bytes());
store.insert(hex::encode(token_hash), token_meta);
return raw_token;  // returned to client once

// Token validation:
let presented_hash = Sha256::digest(presented_token.as_bytes());
store.get(&hex::encode(presented_hash))    // lookup by hash
```

---

### H3. Scrollback log files not permission-restricted on creation

**File**: `crates/pnevma-session/src/supervisor.rs` — scrollback file creation
**OWASP**: A01 Broken Access Control
**ASVS**: V8.1.2 (sensitive data protected at rest)

Scrollback files at `$DATA_DIR/scrollback/{session_id}.log` contain redacted but still potentially sensitive terminal output. The parent directory is created at `0o700`, but individual log files are created with default umask (typically `0o644`), making them world-readable.

**Change**: Create scrollback files with explicit `0o600` permissions using `OpenOptions::new().mode(0o600)` (via `std::os::unix::fs::OpenOptionsExt`).

---

### H4. `self-signed` TLS fallback weakens remote security posture

**File**: `crates/pnevma-remote/src/lib.rs`, `crates/pnevma-remote/src/tls.rs`
**OWASP**: A02 Cryptographic Failures
**ASVS**: V9.1.1 (TLS for all connections)

When `tls_mode = "tailscale"` and Tailscale cert acquisition fails, the server falls back to `rcgen` self-signed certs if `tls_allow_self_signed_fallback = true`. Self-signed certs cannot be verified by clients, enabling MITM on the Tailscale network.

**Change**: Default `tls_allow_self_signed_fallback` to `false` (verify current default). When fallback is used, emit a `warn!` log AND return a header (`X-Pnevma-TLS-Mode: self-signed`) so clients can detect and warn. Add a startup banner visible in the UI when self-signed mode is active.

---

### H5. No rate limiting on Unix socket control plane

**File**: `crates/pnevma-commands/src/control.rs`
**OWASP**: A04 Insecure Design
**ASVS**: V11.1.4 (rate limiting to prevent abuse)

The remote server has `governor`-based rate limiting (5 rpm auth, 60 rpm API), but the local Unix socket has no rate limiting. A compromised local process could flood the control plane with RPC calls.

**Change**: Add a `governor` rate limiter to the Unix socket handler, configurable via `pnevma.toml` `[automation]` section (e.g., `socket_rate_limit_rpm = 300`). Default should be generous but bounded.

---

## Medium (fix in next 1-2 sprints)

### M1. Agent environment denylist may miss new sensitive variables

**File**: `crates/pnevma-agents/src/env.rs`
**OWASP**: A05 Security Misconfiguration
**ASVS**: V8.3.4 (sensitive data not leaked to subprocesses)

Environment sanitization uses an explicit denylist (`DYLD_*`, `LD_*`, `ANTHROPIC_API_KEY`, etc.). New sensitive variables added by future tools/providers will pass through.

**Change**: Invert to an allowlist model. Pass only the documented safe variables (`PATH`, `HOME`, `SHELL`, `TERM`, `USER`, `LANG`, `LC_ALL`, `TMPDIR`) plus any explicitly configured in `pnevma.toml`. Log a `debug!` message for any variable that would have been inherited but was filtered.

---

### M2. `disable-library-validation` entitlement broadens dylib injection surface

**File**: `native/Pnevma/Pnevma.entitlements`
**OWASP**: A08 Software and Data Integrity Failures
**ASVS**: V14.2.3 (application integrity verification)

Required for GhosttyKit.xcframework, but allows any unsigned dylib to be loaded into the process via `DYLD_INSERT_LIBRARIES` (mitigated by hardened runtime blocking `DYLD_*` env vars for non-root, but not for processes launched by the user themselves).

**Change**: No code change possible (entitlement is required). Add a runtime check at app launch that verifies no unexpected dylibs are loaded:

```swift
// In AppDelegate.applicationDidFinishLaunching:
for i in 0..<_dyld_image_count() {
    let name = String(cString: _dyld_get_image_name(i))
    if !isExpectedLibrary(name) {
        NSLog("[SECURITY] Unexpected dylib loaded: \(name)")
        // Optionally: alert user and exit
    }
}
```

Also add this check to `check-entitlements.sh` as a CI-time verification that no new entitlements have been added.

---

### M3. `session.json` persistence can encode workspace paths containing sensitive info

**File**: `native/Pnevma/Core/SessionPersistence.swift`
**OWASP**: A01 Broken Access Control
**ASVS**: V8.1.1 (sensitive data identified and classified)

`session.json` stores workspace paths and pane metadata in plaintext at `~/.config/pnevma/session.json` with default umask.

**Change**: Create `session.json` with `0o600` permissions. Apply the same `FileManager` permission enforcement used for config files.

---

### M4. SQL migration files not integrity-checked

**File**: `crates/pnevma-store/migrations/`
**OWASP**: A08 Software and Data Integrity Failures
**ASVS**: V14.2.4 (integrity of third-party components)

SQLx migrations are embedded at compile time but there's no checksum verification that migration files haven't been tampered with in the repo.

**Change**: Add a `scripts/check-migration-checksums.sh` that computes SHA-256 of each migration file and compares against a checked-in `migrations/checksums.sha256`. Run this in CI as part of `just check`.

---

### M5. Redaction engine regex patterns may miss novel secret formats

**File**: `crates/pnevma-redaction/src/lib.rs`
**OWASP**: A04 Insecure Design
**ASVS**: V8.3.1 (sensitive data not logged)

The redaction engine uses hardcoded regex patterns for known secret formats (Bearer, AKIA, ghp_, sk-, xox*, PEM headers). New provider key formats will pass through until patterns are updated.

**Change**: Add a configurable `[redaction.extra_patterns]` section in `pnevma.toml` for user-defined regex patterns. Also add a high-entropy detector as a catch-all: flag any string of 32+ hex/base64 characters adjacent to assignment operators or JSON keys matching `*key*`, `*token*`, `*secret*`.

---

### M6. No audit logging for local control plane operations

**File**: `crates/pnevma-commands/src/control.rs`
**OWASP**: A09 Security Logging and Monitoring Failures
**ASVS**: V7.1.1 (security-relevant events logged)

The remote server logs token issuance/use/revocation with subject and safe token ID, but the local Unix socket logs no RPC calls. A compromised local process could invoke sensitive commands without trace.

**Change**: Add structured `tracing` logging for all socket RPC calls: method name, peer UID (from `SO_PEERCRED`), timestamp, success/failure. Exclude params from logs (may contain secrets). Use `info!` for mutations, `debug!` for reads.

---

## Low (backlog / hardening)

### L1. SBOM not signed or attested

**File**: `.github/workflows/release.yml`
**OWASP**: A08 Software and Data Integrity Failures

CycloneDX SBOM is generated and uploaded as a GitHub artifact but not cryptographically signed or attested via Sigstore.

**Change**: Add `actions/attest-build-provenance` after SBOM generation. Requires adding `id-token: write` to workflow permissions. Already noted in `docs/threat-model.md` as future work.

---

### L2. No CSP or origin validation on WebSocket upgrade

**File**: `crates/pnevma-remote/src/routes/ws.rs`
**OWASP**: A07 Cross-Site Request Forgery

WebSocket upgrade requests are auth-token protected but don't validate the `Origin` header. A malicious web page on the same Tailscale network could attempt cross-origin WebSocket connections if the user's browser has the token cached.

**Change**: Validate `Origin` header against `allowed_origins` from config during WebSocket upgrade. Reject connections with no `Origin` header unless the request comes from a non-browser client (check for `Sec-WebSocket-Key` without `Origin`).

---

### L3. `cargo-audit` only ignores one advisory — no scheduled re-scan

**File**: `.github/workflows/ci.yml`
**OWASP**: A06 Vulnerable and Outdated Components

`cargo audit` runs on every CI build, but there's no scheduled workflow to catch new advisories between commits.

**Change**: Add a `schedule` trigger to CI (e.g., weekly cron `0 9 * * 1`) that runs `cargo audit` and `cargo deny check` and opens an issue on failure.

---

### L4. Global DB directory created without checking existing permissions

**File**: `crates/pnevma-store/src/global.rs`
**OWASP**: A01 Broken Access Control

`create_dir_all` at `~/.local/share/pnevma` sets `0o700` on creation but doesn't verify permissions if the directory already exists. A prior misconfiguration could leave it world-readable.

**Change**: After `create_dir_all`, stat the directory and warn (or fix) if mode is not `0o700`.

---

## Verification Plan Summary

| Phase | Activity | Tools / Method |
|-------|----------|---------------|
| **Planning** | Confirm scope, assurance level, test environment | This document |
| **Execution — Static** | Code review of all files listed above | Manual review + `cargo clippy`, `cargo audit`, `cargo deny` |
| **Execution — SAST** | Run `cargo-geiger` for unsafe code inventory | `cargo geiger --output-format=json` |
| **Execution — Secrets** | Verify gitleaks config covers all secret patterns | Review `.gitleaks.toml` (if present) or default ruleset |
| **Execution — Dynamic** | Exercise Unix socket auth (same-user + password modes) | `scripts/ipc-e2e-*.sh` + manual `socat` testing |
| **Execution — Dynamic** | Exercise remote server (token lifecycle, RPC allowlist, rate limits) | `curl` + `websocat` against local Tailscale instance |
| **Execution — Dynamic** | Fuzz FFI boundary (malformed JSON, oversized params, null pointers) | Custom harness or `cargo-fuzz` on `pnevma-bridge` |
| **Execution — Dynamic** | Verify redaction coverage (known secret formats + edge cases) | Unit tests in `pnevma-redaction` + manual scrollback inspection |
| **Execution — Release** | Validate entitlements, codesign, notarization on built artifact | `check-entitlements.sh`, `codesign --verify`, `spctl --assess` |
| **Post-Execution** | Findings report, retest after fixes, evidence archive | This template |

## Findings Template

For each finding, record:

| Field | Content |
|-------|---------|
| **ID** | `{severity}-{number}` (e.g., C1, H3, M5) |
| **Title** | One-line description |
| **Severity** | Critical / High / Medium / Low |
| **OWASP** | Applicable OWASP Top 10 category |
| **ASVS** | Applicable ASVS requirement ID |
| **File(s)** | Exact file paths and line ranges |
| **Evidence** | Steps to reproduce, code snippets, screenshots |
| **Impact** | What an attacker gains; blast radius |
| **Fix** | Exact code change or configuration change |
| **Owner** | Person or team responsible |
| **Retest** | How to verify the fix works (test command, manual check) |
| **Status** | Open / In Progress / Fixed / Verified / Accepted Risk |

## Go/No-Go Release Criteria

**Green bar** (all must pass):

- [ ] Zero open Critical findings
- [ ] Zero open High findings (or each has a written exception with compensating control)
- [ ] `just check` passes (fmt + clippy + tests + audit + deny)
- [ ] `swift test` + `just xcode-test` pass
- [ ] `check-entitlements.sh` shows no unexpected entitlements
- [ ] `codesign --verify --deep --strict` passes on packaged `.app`
- [ ] `spctl --assess --type execute` passes
- [ ] Notarization + stapling succeed
- [ ] SBOM generated and archived (90-day retention)
- [ ] Redaction unit tests pass for all known secret formats
- [ ] Remote auth tests pass (token lifecycle, rate limiting, RPC allowlist)
- [ ] No new `cargo-geiger` unsafe blocks without `SAFETY` justification
- [ ] Evidence bundle collected and archived

**Exception policy**: Medium findings may ship with documented exception (owner, scope, compensating control, expiry date, retest condition). Low findings may be deferred unless they weaken auth, secrets, or release integrity.
