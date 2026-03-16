# Pnevma hardening plan v2

## Re-audit verdict

Pnevma is **materially closer** to the hardening exit bar than it was in the first pass.
A large amount of the earlier release-hardening work appears to have been completed correctly.

However, I would **not** sign this repo off as “100% hardened” yet.
The hardening freeze should stay in place until the remaining code-policy gaps and evidence gaps below are closed.

The practical read after this re-audit is:

- many of the v1 blockers are now genuinely fixed,
- a few release-critical items are still **not fixed correctly**,
- and a few others are **not provable from repository state alone**.

This document is intentionally focused on **what still needs to happen** and on **not sending you back through already-complete work**.

---

## Audit basis and limits

This was a repo re-audit, not a claim that all runtime and release checks were executed in this environment.

What was rechecked:

- release-policy docs and hardening docs,
- GitHub Actions workflows,
- release scripts,
- native app release-critical code and tests,
- Rust release-critical crates and tests,
- security posture docs,
- repo-wide component inventory.

What cannot be proven from source alone:

- 10 consecutive green runs on `main`,
- real sign/notarize dry-run success where Apple secrets exist,
- clean-machine candidate-DMG validation,
- manual smoke/security execution evidence.

Those are still required and remain part of the final closeout plan.

---

## Repo-wide scope inventory

Treat the following as the full hardening scope. Nothing in these areas should be considered “out of scope” for release hardening.

### 1. Root policy, release, and supply-chain control surface

- `README.md`
- `SECURITY.md`
- `Cargo.toml`
- `justfile`
- `pnevma.toml`
- `.github/workflows/*`
- `scripts/*`
- `docs/*`

### 2. Rust backend workspace

#### `crates/pnevma-agents`

- adapters and process spawning
- provider-specific CLI argument construction
- environment shaping
- profiles / routing / resilience
- Claude and Codex adapters

Key files verified or implicated in this pass:

- `crates/pnevma-agents/src/adapters/claude.rs`
- `crates/pnevma-agents/src/adapters/codex.rs`
- `crates/pnevma-agents/src/env.rs`

#### `crates/pnevma-bridge`

- Rust ↔ Swift FFI bridge
- async callback lifecycle
- handle shutdown / generation tracking
- exported bridge coverage

Key files verified or implicated in this pass:

- `crates/pnevma-bridge/src/lib.rs`
- `native/Pnevma/Bridge/PnevmaBridge.swift`
- `native/PnevmaTests/PnevmaBridgeTests.swift`
- `scripts/check-ffi-coverage.sh`

#### `crates/pnevma-commands`

- local control plane
- command routing and task commands
- auth secret sourcing
- remote bridge handoff

Key files verified or implicated in this pass:

- `crates/pnevma-commands/src/control.rs`
- `crates/pnevma-commands/src/auth_secret.rs`
- `crates/pnevma-commands/src/commands/tasks.rs`
- `crates/pnevma-commands/src/remote_bridge.rs`

#### `crates/pnevma-core`

- event model
- task state machine
- workflow model

Representative hardening-relevant files:

- `crates/pnevma-core/src/events.rs`
- `crates/pnevma-core/src/task.rs`
- `crates/pnevma-core/src/workflow.rs`

#### `crates/pnevma-db`

- project/global DB creation
- permissions
- schema / migration integrity
- persistence invariants

Key files verified or implicated in this pass:

- `crates/pnevma-db/src/global_store.rs`
- `crates/pnevma-db/src/store.rs`
- `crates/pnevma-db/src/models.rs`

#### `crates/pnevma-remote`

- remote config validation
- TLS posture
- token auth
- token revocation
- rate limiting
- WebSocket gating
- RPC allowlist
- audit context

Key files verified or implicated in this pass:

- `crates/pnevma-remote/src/config.rs`
- `crates/pnevma-remote/src/tls.rs`
- `crates/pnevma-remote/src/auth.rs`
- `crates/pnevma-remote/src/server.rs`
- `crates/pnevma-remote/src/routes/ws.rs`
- `crates/pnevma-remote/src/routes/rpc_allowlist.rs`
- `crates/pnevma-remote/src/middleware/auth_token.rs`

#### Remaining backend crates still in scope

- `crates/pnevma-context`
- `crates/pnevma-git`
- `crates/pnevma-redaction`
- `crates/pnevma-session`
- `crates/pnevma-ssh`
- `crates/pnevma-tracker`

### 3. Native macOS frontend / shell

Top-level native surfaces in scope:

- `native/Pnevma/App`
- `native/Pnevma/Bridge`
- `native/Pnevma/Chrome`
- `native/Pnevma/CommandCenter`
- `native/Pnevma/Core`
- `native/Pnevma/Panes`
- `native/Pnevma/Resources`
- `native/Pnevma/Shared`
- `native/Pnevma/Sidebar`
- `native/Pnevma/Terminal`
- `native/Info.plist`
- `native/Pnevma/Pnevma.entitlements`
- `native/project.yml`
- `native/Package.swift`

Representative pane / UI surfaces inventoried in this pass:

- `native/Pnevma/Panes/Browser/*`
- `native/Pnevma/Panes/Workflow/*`
- `native/Pnevma/Panes/AnalyticsPane.swift`
- `native/Pnevma/Panes/DailyBriefPane.swift`
- `native/Pnevma/Panes/DiffPane.swift`
- `native/Pnevma/Panes/FileBrowserPane.swift`
- `native/Pnevma/Panes/MergeQueuePane.swift`
- `native/Pnevma/Panes/NotificationsPane.swift`
- `native/Pnevma/Panes/ProviderUsageUI.swift`
- `native/Pnevma/Panes/ReplayPane.swift`
- `native/Pnevma/Panes/ReviewPane.swift`
- `native/Pnevma/Panes/RulesManagerPane.swift`
- `native/Pnevma/Panes/SecretsManagerPane.swift`
- `native/Pnevma/Panes/SettingsPane.swift`
- `native/Pnevma/Panes/SshManagerPane.swift`
- `native/Pnevma/Panes/TaskBoardPane.swift`
- `native/Pnevma/Panes/WorkflowPane.swift`

### 4. Test surfaces

- Rust crate unit/integration tests
- `native/PnevmaTests/*`
- `native/PnevmaUITests/*`
- `docs/manual-smoke-tests.md`
- `docs/manual-security-tests.md`

### 5. CI / release / packaging surfaces

- `.github/workflows/ci.yml`
- `.github/workflows/release-rehearsal.yml`
- `.github/workflows/release.yml`
- `.github/workflows/dependency-watch.yml`
- `scripts/release-preflight.sh`
- `scripts/check-entitlements.sh`
- `scripts/run-ghostty-smoke.sh`
- `scripts/run-packaged-launch-smoke.sh`
- `scripts/release-macos-sign.sh`
- `scripts/release-macos-notarize.sh`
- `scripts/release-macos-staple-verify.sh`
- `scripts/release-macos-package-dmg.sh`
- `scripts/check-migration-checksums.sh`
- `scripts/assert-clean-command-log.sh`

---

## What is now clearly fixed or materially improved

These items should **not** be reopened unless a new regression is found.

### A. Fixed correctly

#### 1. Release/version alignment

Earlier version drift appears resolved.
The repo now reads as `0.2.0` / `v0.2.0` across the release-critical docs and metadata that were rechecked.

Do not spend more hardening time here unless a new mismatch appears.

#### 2. Password-file hardening / TOCTOU mitigation

This looks properly hardened now.

Verified in:

- `crates/pnevma-commands/src/auth_secret.rs`

What is now in place:

- `O_NOFOLLOW` on Unix opens,
- symlink rejection,
- validation on the opened file handle,
- regular-file enforcement,
- owner check,
- mode check rejecting group/other readability,
- tests for secure/insecure cases.

Verdict: **closed in code**.

#### 3. Local control-plane abuse controls

This was previously a real gap and now looks materially addressed.

Verified in:

- `crates/pnevma-commands/src/control.rs`
- `docs/security-deployment.md`

What is now in place:

- per-UID rate limiting,
- payload size limit,
- per-UID auth-failure thresholding,
- enriched audit payloads with `peer_uid` and `auth_mode`,
- log redaction for password auth debug output.

Verdict: **closed in code/docs**.

#### 4. Remote token auth posture

This now looks substantially stronger and no longer belongs on the “obviously open” list.

Verified in:

- `crates/pnevma-remote/src/auth.rs`
- `crates/pnevma-remote/src/server.rs`

What is now in place:

- Argon2id password hash storage,
- SHA-256 lookup keys instead of raw bearer-token keys,
- expiry checks,
- IP binding,
- revocation,
- audit logging with safe token identifiers,
- token audit DB helpers and tests.

Verdict: **closed in code, still keep in final verification set**.

#### 5. RPC allowlist / remote session-input posture

Verified in:

- `crates/pnevma-remote/src/server.rs`
- `crates/pnevma-remote/src/routes/ws.rs`
- `crates/pnevma-remote/src/routes/rpc_allowlist.rs`
- `docs/security-deployment.md`

What is now in place:

- `session.new` excluded from remote RPC allowlist / REST route,
- `session.send_input` excluded from REST/RPC allowlist path,
- separate `SessionInput` gating by config, subscription, and operator role,
- `allow_session_input = false` by default.

Verdict: **closed in code/docs, still keep in manual security verification**.

#### 6. Session persistence / local file permission hardening

Verified in:

- `native/Pnevma/Core/SessionPersistence.swift`
- `native/PnevmaTests/SessionPersistenceTests.swift`

What is now in place:

- persistence directory mode hardening,
- session file mode hardening,
- unit coverage for `0600` session-file writes.

Verdict: **closed in code/tests**.

#### 7. Global DB directory/file permissions

Verified in:

- `crates/pnevma-db/src/global_store.rs`

What is now in place:

- global DB directory correction to `0700`,
- DB file correction to `0600`,
- tests for both.

Verdict: **closed in code/tests**.

#### 8. Migration checksum validation

Verified in:

- `.github/workflows/ci.yml`
- `justfile`
- `scripts/check-migration-checksums.sh`

Verdict: **closed in CI**.

#### 9. SBOM / provenance / attestation

Verified in:

- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `docs/threat-model.md`

What is now in place:

- CycloneDX SBOM generation,
- SBOM artifact upload,
- `actions/attest-build-provenance` in release,
- release workflow permissions for attestations / OIDC.

Verdict: **closed in CI/release pipeline**.

#### 10. Scheduled dependency watch

Verified in:

- `.github/workflows/dependency-watch.yml`

What is now in place:

- scheduled advisory scan,
- `cargo audit`,
- `cargo deny`,
- issue creation/commenting on failure.

Verdict: **closed in CI**.

#### 11. Warning-free native gates

Verified in:

- `justfile`
- `scripts/assert-clean-command-log.sh`
- `.github/workflows/ci.yml`

The repo now appears to enforce clean native logs by wrapping `swift test`, `xcodebuild build`, and `xcodebuild test` through `assert-clean-command-log.sh`, which fails on warning/error output outside a tiny explicit allowlist.

Verdict: **closed in local/CI gate design**.

### B. Materially improved, but still keep in the final verification set

#### 12. FFI async callback lifetime safety

Verified in:

- `crates/pnevma-bridge/src/lib.rs`
- `native/Pnevma/Bridge/PnevmaBridge.swift`
- `native/PnevmaTests/PnevmaBridgeTests.swift`

This boundary looks much better than before:

- pending async callbacks are tracked,
- callback generation is tracked,
- stale callbacks are rejected on generation mismatch,
- pending async contexts are released on shutdown/cancel paths,
- tests cover one-shot firing and cancellation behavior.

Verdict: **substantially improved**.
Do not reopen the design casually, but keep it in the final “must stay green” verification set because it is still an unsafe boundary.

#### 13. Self-signed TLS fallback posture

Verified in:

- `crates/pnevma-remote/src/config.rs`
- `crates/pnevma-remote/src/tls.rs`
- `docs/security-deployment.md`

What is now in place:

- production default is `tls_mode = "tailscale"`,
- `tls_allow_self_signed_fallback = false` by default,
- docs explicitly classify self-signed fallback as development-only.

Verdict: **good enough in code/config**, but still requires the normal manual remote validation evidence before sign-off.

---

## What is still wrong or incomplete

These are the remaining blockers from a strict hardening point of view.

### 1. `npx` wildcard fallback is still present

This is the clearest remaining code-level hardening miss.

Exact components:

- `crates/pnevma-agents/src/adapters/claude.rs`
- any config-validation path that constructs `AgentConfig`
- `docs/threat-model.md`
- any user-facing config docs that expose `allow_npx` / `npx_allowed_packages`

What is still wrong:

- `auto_approve_allowed_tools()` still falls back to wildcard `npx` / `npm exec` access when `allow_npx = true` and `npx_allowed_packages` is empty.
- The test suite still codifies that fallback as acceptable behavior.
- `docs/threat-model.md` still documents unrestricted `npx` as an accepted risk / future improvement.

Why this still blocks a “100% hardened” sign-off:

- this keeps a generic arbitrary package-execution path available in the most sensitive place: the auto-approved agent command allowlist.

Required fix:

1. In `crates/pnevma-agents/src/adapters/claude.rs`, remove the wildcard fallback block entirely.
2. Make `allow_npx = true` invalid unless `npx_allowed_packages` is non-empty.
3. Fail closed during config validation or adapter spawn, not by warning and continuing.
4. Delete or rewrite the tests that currently bless the wildcard fallback.
5. Update docs so `implementation-status.md`, `threat-model.md`, and any config docs all describe the same post-fix posture.

Exact tests to change:

- replace `npx_empty_packages_falls_back_to_wildcard_with_warning`
  with a failure-path test,
- replace `auto_approve_allowed_tools_gate_npx_patterns`
  with a test that only explicit packages are emitted,
- keep `npx_allowed_packages_restricts_wildcard`,
  because that is the behavior you actually want.

### 2. Agent extra-env policy is still denylist-based, not allowlist-based

Exact components:

- `crates/pnevma-agents/src/env.rs`
- `crates/pnevma-agents/src/adapters/claude.rs`
- `crates/pnevma-agents/src/adapters/codex.rs`
- any config path that accepts custom agent environment entries

What is still wrong:

- the shared environment builder still allows arbitrary extra names unless blocked by exact-name/prefix rules,
- this is better than before, but it is still not a strict “minimal environment by construction” posture.

Why it still matters:

- this is the other half of the agent-execution boundary,
- it is exactly the place where future secret names, vendor-specific credentials, or runtime toggles can slip past a denylist.

Required fix:

1. Convert `extra_env` from a blocklist model to an explicit allowlist model.
2. Keep the base runtime vars minimal (`PATH`, `HOME`, `SHELL`, `TERM`, `USER`, `LANG`, `LC_ALL`, `TMPDIR`) unless there is a hard requirement to add more.
3. Add explicit `ALLOWED_EXTRA_ENV_NAMES` and, only if absolutely necessary, a tiny `ALLOWED_EXTRA_ENV_PREFIXES` list.
4. Reject everything else by default.
5. Document the supported extra-env contract in one place.

Minimum expected test set:

- explicit allowlisted name passes,
- unknown extra name fails,
- reserved base names fail,
- secret-looking names fail,
- provider credentials fail,
- duplicate names fail,
- oversized values fail.

### 3. `disable-library-validation` is still not fully closed out

Exact components:

- `native/Pnevma/Pnevma.entitlements`
- `scripts/check-entitlements.sh`
- `docs/security-deployment.md`
- `docs/macos-website-release-plan.md`
- `docs/threat-model.md`

What is still wrong:

- the entitlement is still present,
- docs still say it requires periodic revalidation and removal testing on signed release builds,
- the repo does not itself prove that this revalidation has happened for the current candidate.

This may still be the correct final answer for `v0.2.0`.
The issue is **not** “remove it at all costs.”
The issue is that the repo still reads as “keep it for now, but the minimization proof is not yet archived.”

Required fix:

Choose one of the two final states and document it cleanly:

#### Option A — remove it

- remove `com.apple.security.cs.disable-library-validation` from `native/Pnevma/Pnevma.entitlements`,
- run the signed-build / packaged-launch / terminal-interaction / restore matrix,
- keep it removed only if GhosttyKit still loads and behaves correctly.

#### Option B — keep it, but close the proof loop

- run the signed-build experiment with the entitlement temporarily removed,
- capture the concrete failure mode,
- restore the entitlement,
- record the exact evidence in release artifacts/docs,
- update docs so the retained exception is clearly documented as a currently validated necessity rather than an open-ended future task.

Until one of those two states is completed, the entitlement story is still “not fully closed.”

### 4. Documentation is still internally inconsistent

This is now a real closeout issue, not a cosmetic issue.

Exact components:

- `docs/implementation-status.md`
- `docs/threat-model.md`
- `docs/macos-website-release-plan.md`
- `README.md` if summary wording needs to be tightened
- `docs/security-deployment.md` once the entitlement decision is finalized

Current inconsistencies found in this pass:

#### A. `implementation-status.md` is more optimistic than the code/docs justify

It frames the primary remaining work as:

- 10 consecutive green runs,
- manual smoke/security tests,
- formal sign-off.

But the code and threat model still show unresolved hardening work around unrestricted `npx` fallback and the extra-env policy.

#### B. `threat-model.md` still treats unrestricted `npx` as a future improvement

That means the repo itself is still admitting an open hardening risk on the agent boundary.

#### C. `macos-website-release-plan.md` still talks like DMG replacement for legacy `tar.gz` rehearsal is unfinished

But the workflows now already package and validate DMGs in both rehearsal and release automation.
That means the doc’s “current known gaps” section is stale.

Required fix:

- normalize all release/hardening/security docs to the actual current state,
- do not leave one doc saying “only evidence remains” while another still documents an unresolved command-allowlist risk.

### 5. Final hardening evidence is still not provable from repo state

This is the biggest remaining non-code gap.

Exact required evidence:

- 10 consecutive green `main` runs across the required native and release-rehearsal lanes,
- sign/notarize dry run green anywhere Apple secrets are configured,
- manual smoke pass against the candidate DMG,
- manual security pass against the candidate remote/Tailscale setup,
- preserved release-evidence artifacts.

Why this still blocks sign-off:

- the hardening exit bar is evidence-driven,
- source alone cannot prove that the release candidate was signed, notarized, stapled, mounted, launched, and manually exercised on the actual tested artifact.

### 6. Clean-machine website flow is still an evidence task, not a code-complete task

Exact components:

- `docs/macos-website-release-plan.md`
- `docs/macos-release.md`
- release evidence artifacts

The repo now has the DMG path and release evidence plumbing.
What is still missing is proof that the real website-delivered artifact has passed the intended clean-machine install flow.

This stays open until run and archived.

---

## Final step-by-step closeout plan

This is the shortest correct path to “hardening complete.”
Do these in order.

### Step 1 — fail closed on `npx`

**Goal:** remove the last obvious agent allowlist escape hatch.

Files to touch:

- `crates/pnevma-agents/src/adapters/claude.rs`
- the `AgentConfig` validation path
- `docs/threat-model.md`
- `docs/implementation-status.md`

Todo:

- [ ] remove wildcard `npx` / `npm exec` fallback logic
- [ ] require explicit `npx_allowed_packages` whenever `allow_npx = true`
- [ ] fail closed if config is invalid
- [ ] update tests accordingly
- [ ] update docs accordingly

Exit condition for Step 1:

- there is no code path that expands empty `npx_allowed_packages` into wildcard command permission.

### Step 2 — convert agent extra-env to explicit allowlist semantics

**Goal:** harden the second half of the agent execution boundary.

Files to touch:

- `crates/pnevma-agents/src/env.rs`
- `crates/pnevma-agents/src/adapters/claude.rs`
- `crates/pnevma-agents/src/adapters/codex.rs`
- any config docs that expose agent env entries

Todo:

- [ ] add `ALLOWED_EXTRA_ENV_NAMES`
- [ ] add `ALLOWED_EXTRA_ENV_PREFIXES` only if strictly necessary
- [ ] reject all other extra env names by default
- [ ] keep secret-looking and provider credential blocks in place as defense-in-depth
- [ ] expand tests for pass/fail cases

Exit condition for Step 2:

- extra env injection is allowlist-driven rather than denylist-driven.

### Step 3 — close the entitlement story, one way or the other

**Goal:** finish hardened-runtime minimization instead of carrying an open-ended exception note.

Files to touch:

- `native/Pnevma/Pnevma.entitlements`
- `scripts/check-entitlements.sh`
- `docs/security-deployment.md`
- `docs/macos-website-release-plan.md`
- `docs/threat-model.md`

Todo:

- [ ] temporarily test a signed build with `disable-library-validation` removed
- [ ] run packaged launch smoke and interactive Ghostty validation on that signed build
- [ ] either keep it removed or restore it with recorded failure evidence
- [ ] update entitlement docs to the final validated state
- [ ] keep `scripts/check-entitlements.sh` aligned with the final approved set

Exit condition for Step 3:

- the entitlement is either removed or retained with current signed-build evidence and no stale “needs periodic revalidation” ambiguity left in docs.

### Step 4 — repair documentation drift

**Goal:** make the repo say one consistent thing about hardening status.

Files to touch:

- `docs/implementation-status.md`
- `docs/threat-model.md`
- `docs/macos-website-release-plan.md`
- `README.md` if needed

Todo:

- [ ] stop `implementation-status.md` from implying only evidence/sign-off remains if code-policy gaps still exist
- [ ] remove stale wording in `macos-website-release-plan.md` that treats DMG replacement as still pending when the workflows already use DMG
- [ ] move the `npx` item out of accepted-risk/future-improvement language once Step 1 is done
- [ ] ensure docs all describe the same remaining backlog

Exit condition for Step 4:

- repo docs no longer disagree about what is still open.

### Step 5 — prove the CI/rehearsal bar on `main`

**Goal:** satisfy the documented exit criteria with evidence, not inference.

Workflows to verify:

- `.github/workflows/ci.yml`
- `.github/workflows/release-rehearsal.yml`

Todo:

- [ ] collect the last 10 consecutive green `main` runs for:
  - `CI / Rust checks`
  - `CI / Native app build`
  - `Release Rehearsal / Release package preflight`
  - `Release Rehearsal / Release sign/notarize dry run` where secrets exist
- [ ] archive run URLs / run numbers in the release evidence bundle
- [ ] ensure no flaky failure is being hand-waved away

Exit condition for Step 5:

- the 10-run green window is explicit and archived.

### Step 6 — execute the manual candidate-DMG validation

**Goal:** verify the actual shipped artifact, not just the source tree.

Use:

- `docs/manual-smoke-tests.md`
- `docs/manual-security-tests.md`
- the candidate `Pnevma-0.2.0-macos-arm64.dmg`

Todo:

- [ ] run the full manual smoke test doc against the DMG
- [ ] run the full manual security test doc against the DMG / Tailscale remote surface
- [ ] archive outputs, logs, screenshots, run notes, and any command transcripts
- [ ] record exact candidate version, checksum, and test machine/account context

Exit condition for Step 6:

- manual smoke and security evidence exist for the actual candidate artifact.

### Step 7 — assemble the final hardening evidence bundle

**Goal:** make sign-off reproducible.

Bundle must contain at minimum:

- [ ] SBOM
- [ ] attestation/provenance evidence
- [ ] entitlements check output
- [ ] effective entitlements plist
- [ ] `codesign` verification output
- [ ] `spctl` verification output
- [ ] notarization logs
- [ ] stapling logs
- [ ] packaged launch smoke logs
- [ ] manual smoke/security evidence
- [ ] CI run URLs / run IDs for the green-run window
- [ ] DMG checksum

Recommended artifact names to preserve:

- `release-package-preflight`
- `release-sign-notarize-dry-run`
- `release-security-evidence`

Exit condition for Step 7:

- an independent reviewer can re-check hardening status from preserved artifacts without guessing.

### Step 8 — only now lift the feature freeze

Files to update after all prior steps are complete:

- `docs/implementation-status.md`
- `README.md`
- any milestone / release tracking docs

Todo:

- [ ] explicitly mark the hardening exit bar as met
- [ ] explicitly state that new feature work may resume
- [ ] queue post-hardening work in the order defined by the hardening docs

Exit condition for Step 8:

- the repo no longer claims release hardening is the active blocker.

---

## Things that should NOT be reopened unless they regress

To avoid churn, do **not** spend more time re-fixing these unless new evidence says they broke:

- version alignment for `v0.2.0`
- password-file TOCTOU mitigation
- local control-plane rate limiting / auth-threshold audit logging
- remote token hashing / expiry / revocation / audit path
- session persistence permission hardening
- global DB permission hardening
- migration checksum validation in CI
- SBOM/provenance/attestation plumbing
- scheduled dependency watch
- warning-free native gate plumbing
- DMG packaging path in release and release-rehearsal workflows

---

## Final go / no-go

### No-go right now

Do **not** declare hardening complete today because at least these items remain open:

1. wildcard `npx` fallback,
2. denylist-based extra-env policy,
3. unresolved / unarchived `disable-library-validation` minimization proof,
4. documentation drift around actual remaining work,
5. missing hard evidence for the 10-green-run / manual-candidate gates.

### Go only when all of the following are simultaneously true

- `npx` is explicit-package-only,
- agent extra env is allowlist-based,
- the entitlement story is finalized and evidenced,
- repo docs are internally consistent,
- 10 consecutive green `main` runs are archived,
- manual smoke/security candidate evidence is archived,
- release evidence bundle is complete.

At that point, and not before that point, it is reasonable to say the repo is hardened enough to move on.
