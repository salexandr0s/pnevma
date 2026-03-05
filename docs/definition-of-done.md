# Pnevma — Definition of Done

## Global Checklist (applies to ALL work)

Every change merged to `main` must satisfy:

- [ ] **Compiles cleanly** — `cargo build --workspace` with no errors
- [ ] **Formatted** — `cargo fmt --check` passes
- [ ] **Lint-clean** — `cargo clippy --workspace --all-targets -- -D warnings` passes (zero warnings)
- [ ] **Tests pass** — `cargo test --workspace` green, no new flaky tests
- [ ] **No secrets committed** — no `.env`, API keys, credentials, or signing keys in the diff
- [ ] **No `unsafe` without justification** — any new `unsafe` block has a `// SAFETY:` comment explaining the invariant
- [ ] **Commit messages follow convention** — `type(scope): description` format
- [ ] **PR scope is reviewable** — one logical change per PR; split if touching 5+ unrelated files

---

## Tier 1: MVP

Use for: spikes, prototypes, internal-only features, early-phase work.

Everything in the Global Checklist, plus:

- [ ] **Happy path tested** — at least one unit test covering the primary success path
- [ ] **Error paths return typed errors** — `thiserror` in library crates, `anyhow` in `pnevma-bridge`/app glue; no `unwrap()` on fallible operations in non-test code
- [ ] **Tracing instrumented** — key entry points use `tracing::{info,warn,error}` (no `println!` or `eprintln!`)
- [ ] **Diff reviewed by author** — `git diff main...HEAD` checked before opening PR
- [ ] **CI green** — the `rust` job passes (fmt + clippy + test + audit)

### Not required at MVP tier

- Property-based tests
- Swift/Xcode test coverage
- Architecture docs update
- Migration rollback plan
- Performance benchmarks

---

## Tier 2: Standard

Use for: features shipping to design partners, anything touching core data paths (task engine, session supervisor, merge queue, agent dispatch).

Everything in Tier 1, plus:

- [ ] **Edge-case tests** — error paths, boundary conditions, and state transitions covered (not just happy path)
- [ ] **Property-based tests for state machines** — any new/modified state machine in `pnevma-core` (task, workflow, orchestration) has `proptest` coverage
- [ ] **FFI boundary verified** — if touching `pnevma-bridge`, run `just ffi-coverage` and verify the cbindgen header is current
- [ ] **Swift side compiles** — `just xcode-build` or `just spm-build` succeeds if Rust API surface changed
- [ ] **Secret redaction verified** — any new output path (events, scrollback, context packs, logs) passes through redaction middleware
- [ ] **DB migrations are additive** — no destructive schema changes (column drops, table renames) without a migration plan
- [ ] **README/docs updated** — if the change adds a new crate, command, config key, or user-facing concept, update the relevant doc
- [ ] **`cargo audit` clean** — no new advisories introduced
- [ ] **Concurrency safe** — shared state uses `parking_lot` or `tokio::sync` primitives; no bare `RefCell` across await points
- [ ] **Peer-reviewed** — at least one review pass (human or agent reviewer)

---

## Tier 3: High-Assurance

Use for: release candidates, security-sensitive changes (auth, SSH, secret handling, signing), data integrity paths (DB, merge queue, event store).

Everything in Tier 2, plus:

- [ ] **Swift tests pass** — `just xcode-test` or `just spm-test` green
- [ ] **E2E smoke test** — `scripts/ipc-e2e-smoke.sh` passes (control plane round-trip)
- [ ] **Recovery test** — `scripts/ipc-e2e-recovery.sh` passes (crash recovery, session restore)
- [ ] **Dependency audit clean** — `cargo audit` with no ignored advisories
- [ ] **No new `allow(...)` lint suppressions** — each suppression needs a comment justifying why the fix is infeasible
- [ ] **Threat model reviewed** — for security-sensitive changes, review against existing threat model or document new attack surface
- [ ] **Input validation at boundaries** — all external input (IPC commands, config parsing, SSH config, user-provided paths) validated with appropriate bounds
- [ ] **Path traversal checked** — any file path from user input uses containment checks (no `../` escapes)
- [ ] **Rate limiting verified** — new network-facing endpoints (remote access, WebSocket) have `governor` rate limits applied
- [ ] **Migration rollback plan documented** — destructive DB changes include a rollback SQL script or strategy
- [ ] **Release preflight passes** — `scripts/release-preflight.sh` exits 0
- [ ] **Signing and notarization tested** — for release builds, full `sign -> notarize -> staple -> verify` pipeline completes

---

## Flaky Test Policy

- A test that fails intermittently must be fixed or quarantined within 48 hours of first flake
- Quarantined tests are marked with `#[ignore]` and a `// FLAKY:` comment linking to the tracking issue
- Quarantined tests still run in CI on a nightly schedule (not gating PRs)
- No more than 3 quarantined tests at any time — if the cap is hit, fixing flakes takes priority

---

## Observability Expectations

| Tier           | Logging                                                         | Metrics                                                 | Tracing                                               |
| -------------- | --------------------------------------------------------------- | ------------------------------------------------------- | ----------------------------------------------------- |
| MVP            | `tracing` macros at key entry points                            | Not required                                            | Not required                                          |
| Standard       | Structured JSON logs via `tracing-subscriber` with `env-filter` | Not required                                            | Span context on async operations                      |
| High-Assurance | All of Standard + log rotation via `tracing-appender`           | Latency histograms for IPC commands (when infra exists) | Full span tree for agent dispatch + merge queue flows |

---

## Waiver Policy

Any checklist item can be waived if:

1. **The waiver is documented in the PR description** — state what is waived and why
2. **A follow-up issue is filed** — with a concrete plan to close the gap
3. **Approval**: The project owner (or lead agent in team mode) approves the waiver

Items that **cannot be waived** at any tier:

- `cargo fmt --check` passing
- `cargo clippy -- -D warnings` passing
- No secrets in the diff
- CI green on the `rust` job
- Commit message convention

---

## Quick Reference

```
# Run the full Standard-tier check locally:
just check                    # fmt + clippy + test
cargo audit                   # dependency audit
just ffi-coverage             # FFI surface check (if bridge changed)
just xcode-build              # Swift compilation (if API surface changed)

# Run High-Assurance checks:
just test                     # Rust + Xcode tests
./scripts/ipc-e2e-smoke.sh    # E2E smoke
./scripts/ipc-e2e-recovery.sh # Recovery test
./scripts/release-preflight.sh # Full preflight
```
