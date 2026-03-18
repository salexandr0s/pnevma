# Pnevma — Definition of Done

Pnevma uses this checklist as the default quality bar for changes to the repository. Release-sensitive work may require the higher-assurance items below, but the project does not use a standing release-hardening freeze as merge policy.

## Global Checklist

Every change merged to `main` must satisfy all of the following:

- [ ] **Scope is coherent** — the change is one logical task on one branch/worktree, with clear boundaries and reviewable intent.
- [ ] **Boundaries are respected** — workflow logic stays in Rust, Swift remains a thin view
      layer, and any new `unsafe` block includes a `// SAFETY:` explanation.
- [ ] **Required local gates pass for the touched surface**:
  - Rust/backend work: `just check`
  - workflow or shell changes: `just workflow-check`
  - FFI, native, or Ghostty-adjacent work: `just spm-test-clean` and `just xcode-build`
- [ ] **Required CI jobs are green** for the change:
  - `CI / Secret scanning`
  - `CI / Workflow and shell hygiene` when scripts or workflows change
  - `CI / Rust checks`
  - `CI / Native app build` when native, FFI, or runtime surfaces change
  - `Release Rehearsal / Release package preflight` when release packaging is affected
- [ ] **No secrets or signing material are introduced** — gitleaks stays clean, and new output
      paths preserve redaction requirements.
- [ ] **Tests are stable** — no knowingly flaky gating test is added, and any touched behavior has
      proportionate automated coverage.
- [ ] **Observability is sufficient** — new async, failure-prone, or operator-relevant paths emit
      structured `tracing` events with actionable context and no secret leakage.
- [ ] **Docs stay accurate** — update the relevant README, runbook, config reference, or release
      documentation when commands, config, workflows, architecture, or operator guidance change.
- [ ] **Release impact is addressed** — schema, config, packaging, auth, or deployment changes
      include forward-compatibility notes plus rollback or containment guidance.

## Tier 1: MVP

Use for docs-only work, low-risk tooling changes, internal prototypes, and small bug fixes that do
not change release or security posture.

- [ ] Global checklist passes.
- [ ] Happy-path behavior is covered by at least one unit or targeted integration test, unless the
      change is documentation-only.
- [ ] Non-test code does not add unexplained `unwrap()`/`expect()` on fallible paths.
- [ ] If CI, scripts, or workflows changed, `just workflow-check` passes locally before review.
- [ ] The author has reviewed the final diff and removed dead code, debug prints, and temporary
      instrumentation.

## Tier 2: Standard

Use for the default merge bar on backend, native, and FFI changes intended to ship to design
partners.

- [ ] MVP tier passes.
- [ ] Added or changed behavior has unit and/or integration coverage for happy path, edge cases,
      and regression scenarios.
- [ ] Changes to dispatch, workflow, event, restore, merge-queue, DB, or remote flows preserve or
      expand integration coverage for those paths.
- [ ] If `pnevma-bridge` or the Rust-to-Swift surface changed, `just ffi-coverage` passes and
      `just xcode-build` remains green.
- [ ] If config parsing or DB migrations changed, migration checksum validation stays green and the
      downgrade/rollback impact is documented.
- [ ] If redaction, persisted output, auth tokens, or remote-visible data changed, the existing
      security regression coverage called out in
      [`security-release-gate.md`](./security-release-gate.md) is preserved or expanded.
- [ ] New operator-visible flows include enough tracing fields and error messages to diagnose
      failures from CI logs and packaged app logs.
- [ ] Relevant user-facing and operator-facing documentation is updated in the same change.
- [ ] The change has at least one review pass before merge.

## Tier 3: High-Assurance

Use for release candidates and for changes touching remote access, auth, SSH, redaction,
signing/notarization, persistence integrity, restore/recovery, Ghostty runtime, or packaged app
behavior.

- [ ] Standard tier passes.
- [ ] `just test` passes.
- [ ] `just ghostty-smoke` passes for terminal/runtime-affecting changes.
- [ ] `./scripts/release-preflight.sh` passes for release-affecting work and for any candidate
      build.
- [ ] Packaged launch smoke passes with
      `APP_PATH=/path/to/Pnevma.app ./scripts/run-packaged-launch-smoke.sh`.
- [ ] Entitlement checks pass for both the checked-in allowlist and the packaged bundle when a
      candidate app is produced.
- [ ] Release evidence is captured when producing a candidate build: SBOM, entitlement output,
      effective entitlements, `codesign` verification, `spctl` assessment, and notarization or
      stapling logs when applicable.
- [ ] Security-sensitive changes are reviewed against
      [`security-release-gate.md`](./security-release-gate.md) and the threat model; no open
      Critical or High finding remains on a shipped remote-enabled release.
- [ ] Recovery, rollback, or containment steps are documented and tested where practical.
- [ ] The sign/notarize dry run is green anywhere Apple signing secrets are available.

## Flaky Test Policy

- A gating test that flakes must be fixed before merge or explicitly quarantined with an owner,
  tracking issue, and expiry date.
- Quarantine is temporary and must include the compensating control used while the test is out of
  the gate.
- A release candidate cannot rely on an unresolved flake in dispatch, restore, remote auth,
  redaction, Ghostty smoke, or packaged-launch validation.

## Waiver Policy

Waivers are allowed only for tier-specific items that are not on the non-waivable list below.

Every waiver must include all of the following in the PR or release record:

- the exact checklist item being waived
- the reason it is being waived now
- the risk and compensating control
- an owner
- an expiry date or explicit retest trigger
- a follow-up issue or task to close the gap

Approval required:

- MVP or Standard waiver: one project maintainer
- High-Assurance waiver: the project owner plus the maintainer responsible for the affected release
  or security area

The following are **not waivable**:

- no secrets or signing credentials in the diff
- `cargo fmt --check` and `cargo clippy --workspace --all-targets -- -D warnings`
- the required CI jobs for the touched surface
- redaction on new output paths that can expose secrets
- no open Critical or High security finding on a shipped remote-enabled release

## Quick Command Map

```bash
# Rust/backend baseline
just check

# CI parity when scripts or workflows change
just workflow-check

# Native and FFI validation
just spm-test-clean
just xcode-build
just xcode-test
just ffi-coverage

# Runtime and release validation
just ghostty-smoke
./scripts/release-preflight.sh
APP_PATH=/path/to/Pnevma.app ./scripts/run-packaged-launch-smoke.sh
```
