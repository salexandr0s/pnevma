# Hardening Exit Checklist

This checklist must be fully satisfied before the hardening freeze can be lifted and feature work resumes.

## 1. Version Alignment

- [ ] All `Cargo.toml` workspace members: `0.2.0`
- [ ] `Info.plist` / `CFBundleShortVersionString`: `0.2.0`
- [ ] `SECURITY.md`: `0.2.x`
- [ ] `docs/implementation-status.md`: `v0.2.0`
- [ ] `docs/hardening-exit-criteria.md`: `v0.2.0`
- [ ] `docs/macos-release.md`: `v0.2.0` (all references)
- [ ] `docs/macos-website-release-plan.md`: `v0.2.0` (all references)

## 2. Security Findings

- [ ] All Critical severity findings: closed with test evidence
- [ ] All High severity findings: closed with test evidence
- [ ] Remote plane (Phase 1): 32 controls implemented, 50+ tests
- [ ] Local control plane (Phase 2): symlink protection, permissions, rate limiting, auth
- [ ] Agent execution (Phase 4): no-shell, env allowlist, prompt sanitization, bounded retries
- [ ] Data-at-rest (Phase 5): scrollback 0600, DB 0700/0600, 16+ redaction patterns

## 3. CI Green Runs

- [ ] 10 consecutive green runs recorded
  - Run IDs:
    1. _____
    2. _____
    3. _____
    4. _____
    5. _____
    6. _____
    7. _____
    8. _____
    9. _____
    10. _____
  - Lanes verified:
    - [ ] `CI / Rust checks`
    - [ ] `CI / Native app build`
    - [ ] `Release Rehearsal / Release package preflight`
    - [ ] `Release Rehearsal / Release sign/notarize dry run` (where secrets available)

## 4. Integration Tests

- [ ] `dispatch_lifecycle` tests green (4 tests: dispatch+stream, launch failure, dependent unblock, DB reconnect)
- [ ] `ws_event_flow` tests green
- [ ] FFI bridge stress tests green (concurrent calls, create/destroy cycles, destroy race, ordering)
- [ ] Scrollback permission tests green (open_append_only 0600, open_scrollback_rw 0600)
- [ ] Redaction e2e matrix green (AWS key, GitHub PAT, PEM key, connection string, env var assignment)

## 5. Manual Test Evidence

- [ ] Smoke tests executed against candidate DMG (see `docs/manual-smoke-tests.md`)
  - Date: _____
  - Result: _____
- [ ] Security tests executed against candidate DMG (see `docs/manual-security-tests.md`)
  - Date: _____
  - Result: _____

## 6. Release Evidence

- [ ] Entitlement allowlist check output
- [ ] Effective entitlements plist from signed app
- [ ] `codesign --verify --deep --strict --verbose=2` output
- [ ] `spctl --assess --type exec --verbose=4` output
- [ ] App notarization submission and stapling logs
- [ ] DMG notarization submission and stapling logs
- [ ] Packaged launch smoke output from DMG-extracted app
- [ ] `Pnevma-0.2.0-macos-arm64.dmg.sha256`
- [ ] SBOM artifact(s)

## 7. Accepted Risks

- [ ] `com.apple.security.cs.disable-library-validation`: justified for GhosttyKit (Ghostty's own app retains the same exception)
- [ ] `RUSTSEC-2023-0071` (rsa crate via sqlx-mysql): Pnevma uses SQLite only, MySQL feature never enabled; ignored in `.cargo/audit.toml`

## 8. Sign-Off

- [ ] Project owner: _____ (date: _____)
- [ ] Security reviewer: _____ (date: _____)
