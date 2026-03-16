# Pnevma final hardening plan

## Scope note

- Public repo analyzed: `salexandr0s/pnevma` (the GitHub username uses a zero in `salexandr0s`).
- This plan is **hardening-only**. The repo docs are consistent that release hardening remains the active priority and that new feature work stays queued behind the hardening exit bar.
- “100% hardened” here does **not** mean “mathematically perfect software.” It means: **the repo’s documented hardening exit criteria are met, the release gate is green, there are no unresolved Critical/High risks, evidence is archived, and the team can responsibly unfreeze feature work.**
- I reviewed the hardening/security/release docs directly and inspected the release-critical code paths that were available, plus the crate/module inventory for the full workspace. Where a module path is listed from crate inventory rather than from a file opened line-by-line in this pass, treat it as the exact component/module to verify before editing if the implementation is split between `foo.rs` and `foo/mod.rs`.

---

## Executive decision

**Do not start new feature work yet.**

The repo is close enough that it would be a mistake to pivot back to feature development, but it is **not yet at a defensible hardening-complete state**. The highest-priority blockers are:

1. **Release identity drift** across code and docs (`0.1.x` vs `0.2.0`), which makes the release story internally inconsistent.
2. **Open or not-yet-proven security findings** in the remote plane, local control plane, FFI boundary, and agent execution path.
3. **Incomplete proof, not just incomplete code.** Several hardening items appear implemented in code, but they still need regression tests, CI enforcement, and release evidence.
4. **Exit-bar proof is not complete** until the documented green-run and release rehearsal requirements are met.

The correct move is to finish hardening in the sequence below, archive the evidence bundle, and only then resume the next product step.

---

## What “hardening complete” must mean for this repo

Treat hardening as complete **only when every one of these is true**:

1. **Hardening exit criteria are all satisfied**
   - dispatch, event, and restore integration tests merged and green;
   - Ghostty smoke runs in CI and is green;
   - native warning-free gates enforced for `swift test`, `xcodebuild build`, and `xcodebuild test`;
   - release package preflight is green on `main`;
   - sign/notarize rehearsal is green wherever Apple secrets exist;
   - `main` has at least **10 consecutive green runs** across the required native and release-rehearsal lanes.

2. **Security release gate is satisfied**
   - `just check` green;
   - `cd native && swift test` green;
   - `just xcode-test` green;
   - `./scripts/release-preflight.sh` green;
   - `APP_PATH="native/build/Release/Pnevma.app" ./scripts/check-entitlements.sh` green;
   - any redaction or remote-auth changes have targeted regression evidence.

3. **No unresolved Critical or High findings remain**
   - this includes findings that were partially addressed but not yet proven with tests/evidence.

4. **Version and release metadata are internally consistent**
   - app version, workspace version, docs, SECURITY policy, smoke docs, release scripts, website/release-plan docs all describe the same release train.

5. **Every documented feature flow has an owning automated test path plus a manual validation path**
   - especially launch, project setup, sessions/replay/restore, dispatch, review, merge queue, workflows, notifications, remote auth/TLS, redaction, and release packaging.

6. **Evidence bundle is archived and reproducible**
   - entitlements output, notarization logs, Gatekeeper validation, smoke logs, manual security test results, SBOM/provenance outputs, and CI run links.

7. **Accepted risks are explicit**
   - no App Sandbox remains an accepted product constraint, not an accidental omission;
   - `disable-library-validation` is either minimized away or kept with clear justification and compensating controls.

---

## Source basis used for this plan

### Docs reviewed

- `README.md`
- `SECURITY.md`
- `docs/implementation-status.md`
- `docs/hardening-exit-criteria.md`
- `docs/macos-release.md`
- `docs/manual-smoke-tests.md`
- `docs/manual-security-tests.md`
- `docs/threat-model.md`
- `docs/security-deployment.md`
- `docs/remote-access.md`
- `docs/definition-of-done.md`
- `docs/security-release-gate.md`
- `docs/deepaudit-recommendations.md`
- `docs/remediation-master-plan.md`
- `docs/macos-website-release-plan.md`
- `docs/agent-command-center-gap-analysis.md`

### Code and scripts inspected directly

- Workspace: `Cargo.toml`, `justfile`, `pnevma.toml`, `audit.toml`, `deny.toml`
- Release/build scripts:
  - `scripts/release-preflight.sh`
  - `scripts/release-macos-sign.sh`
  - `scripts/release-macos-notarize.sh`
  - `scripts/release-macos-staple-verify.sh`
  - `scripts/release-macos-package-dmg.sh`
  - `scripts/run-packaged-launch-smoke.sh`
  - `scripts/run-ghostty-smoke.sh`
  - `scripts/check-entitlements.sh`
  - `scripts/bootstrap-dev.sh`
  - `scripts/check-ffi-coverage.sh`
- Native:
  - `native/project.yml`
  - `native/Package.swift`
  - `native/Info.plist`
  - `native/Pnevma/Pnevma.entitlements`
  - `native/Pnevma/Core/SessionPersistence.swift`
  - `native/Pnevma/Core/AppUpdateCoordinator.swift`
- Rust crate entry points and selected internals:
  - all crate `Cargo.toml` files and `src/lib.rs`
  - `crates/pnevma-remote/src/routes/ws.rs`
  - `crates/pnevma-remote/src/routes/rpc_allowlist.rs`
  - `crates/pnevma-remote/src/middleware/auth_token.rs`
  - `crates/pnevma-remote/src/server.rs`
  - `crates/pnevma-remote/src/tls.rs`
  - `crates/pnevma-commands/src/commands/mod.rs`
  - `crates/pnevma-commands/src/commands/tasks.rs`
  - `crates/pnevma-context/src/discovery.rs`
  - `crates/pnevma-core/src/events.rs`
  - `crates/pnevma-core/src/task.rs`
  - `crates/pnevma-core/src/workflow.rs`
  - `crates/pnevma-session/src/supervisor.rs`
- Vendor/runtime:
  - `vendor/README.md`
  - `patches/ghostty/0001-fallback-without-display-link.patch`

### Full workspace surfaces accounted for by crate/module inventory

- `crates/pnevma-agents`
- `crates/pnevma-bridge`
- `crates/pnevma-commands`
- `crates/pnevma-context`
- `crates/pnevma-core`
- `crates/pnevma-db`
- `crates/pnevma-git`
- `crates/pnevma-redaction`
- `crates/pnevma-remote`
- `crates/pnevma-session`
- `crates/pnevma-ssh`
- `crates/pnevma-tracker`

---

## End-to-end repo surface inventory

The point of this section is to make sure hardening does not accidentally skip any user-visible flow or trust boundary.

| Surface | Features / flows in scope | Exact code components to harden | “Hardened” means |
|---|---|---|---|
| Native app shell | launch, windowing, panes, command palette, app lifecycle, bridge startup | `native/project.yml`, `native/Package.swift`, `native/Info.plist`, `native/Pnevma/App/AppDelegate.swift`, `native/Pnevma/Bridge/PnevmaBridge.swift`, `native/Pnevma/Pnevma.entitlements` | builds warning-free, launch smoke passes from packaged app, entitlements are minimal and verified, no startup regressions |
| Layout and persistence | workspace layout, sidebar state, inspector state, command center visibility, restored session shell state | `native/Pnevma/Core/SessionPersistence.swift`, `native/Pnevma/Core/Workspace.swift`, `native/Pnevma/Core/WorkspaceManager.swift`, `native/Pnevma/Core/SessionStore.swift` | persistence files/directories are permission-safe, restore paths are deterministic, restore tests are green |
| Session UI and replay | terminal panes, replay pane, session manager, Ghostty embedding | `native/Pnevma/Panes/ReplayPane.swift`, `native/Pnevma/Chrome/SessionManagerView.swift`, `native/Pnevma/Core/ContentAreaView.swift`, `native/Pnevma/Core/PaneLayoutEngine.swift`, `crates/pnevma-session/src/supervisor.rs`, `scripts/run-ghostty-smoke.sh` | session lifecycle, replay, restore, and packaged Ghostty launch all work in CI and manual smoke |
| Task system | task create/edit/state transitions, blocked/looped/review states, protected actions | `crates/pnevma-core/src/task.rs`, `crates/pnevma-core/src/protected_actions.rs`, `crates/pnevma-commands/src/commands/tasks.rs`, `native/Pnevma/Panes/TaskBoardPane.swift` | valid transitions are enforced, impossible transitions rejected, protected actions covered, UI survives restore |
| Agent execution | provider adapters, command construction, env shaping, retries, profile routing, resilience | `crates/pnevma-agents/src/adapters/`, `crates/pnevma-agents/src/env.rs`, `crates/pnevma-agents/src/pool.rs`, `crates/pnevma-agents/src/profiles.rs`, `crates/pnevma-agents/src/reconciler.rs`, `crates/pnevma-agents/src/resilience.rs`, `crates/pnevma-core/src/orchestration.rs` | no arbitrary execution via unsafe allowlist entries, env exposure is minimized, retries are bounded and observable |
| Context compilation | repo discovery, context pack generation, inclusion/exclusion policy | `crates/pnevma-context/src/compiler.rs`, `crates/pnevma-context/src/discovery.rs` | discovery cannot leak excluded content unexpectedly, large repos behave predictably, redaction applies end-to-end |
| Git / review / merge | worktree creation, branch isolation, checks, review artifacts, merge queue | `crates/pnevma-git/src/service.rs`, `crates/pnevma-git/src/hooks.rs`, `crates/pnevma-git/src/lease.rs`, `crates/pnevma-db/src/models.rs`, `native/Pnevma/Panes/Workflow/`, review/merge UI surfaces | one-task-one-worktree is enforced, checks and review artifacts are persisted safely, merge queue is replayable after restart |
| Workflows and automation | workflow definitions, instances, step execution, loop/failure policy, automation coordinator | `crates/pnevma-core/src/workflow.rs`, `crates/pnevma-core/src/workflow_contract.rs`, `crates/pnevma-commands/src/automation/`, `crates/pnevma-db/src/store.rs`, `native/Pnevma/Panes/Workflow/` | state transitions and persistence are correct under crash/restore, loop/failure semantics are tested |
| Events / notifications / analytics | event log, notifications pane, daily brief, analytics, provider usage | `crates/pnevma-core/src/events.rs`, `crates/pnevma-commands/src/event_emitter.rs`, `crates/pnevma-db/src/store.rs`, `native/Pnevma/Panes/NotificationsPane.swift`, `native/Pnevma/Panes/NotificationsViewModel.swift`, `native/Pnevma/Panes/DailyBriefPane.swift`, `native/Pnevma/Panes/AnalyticsPane.swift`, `native/Pnevma/Panes/ProviderUsageUI.swift` | event emission is durable and ordered enough for restore, no secret leakage reaches event/analytics surfaces |
| FFI boundary | sync and async Rust↔Swift calls, callback routing, object lifetime | `crates/pnevma-bridge/src/lib.rs`, `crates/pnevma-bridge/pnevma-bridge.h`, `native/Pnevma/Bridge/PnevmaBridge.swift`, `scripts/check-ffi-coverage.sh` | no use-after-free / double-call / cross-thread lifetime bugs, exported API coverage matches Swift use |
| Local control plane | local control socket, auth secret loading, local RPC | `crates/pnevma-commands/src/control.rs`, `crates/pnevma-commands/src/auth_secret.rs`, `crates/pnevma-commands/src/remote_bridge.rs` | no auth bypass, no password-file race, rate limits and audit logging exist, local-only scope is enforced |
| Remote access | HTTPS/WS server, RPC allowlist, auth tokens, TLS mode, rate limits, origin policy | `crates/pnevma-remote/src/server.rs`, `crates/pnevma-remote/src/routes/ws.rs`, `crates/pnevma-remote/src/routes/rpc_allowlist.rs`, `crates/pnevma-remote/src/auth.rs`, `crates/pnevma-remote/src/middleware/auth_token.rs`, `crates/pnevma-remote/src/config.rs`, `crates/pnevma-remote/src/tls.rs`, `crates/pnevma-remote/src/tailscale.rs` | auth is narrow, session input is off by default, tokens are revocable and stored safely, self-signed fallback is not weakening production posture, origin/rate-limit controls are enforced |
| SSH | profiles, key management, Tailscale discovery, config parsing | `crates/pnevma-ssh/src/key_manager.rs`, `crates/pnevma-ssh/src/profile.rs`, `crates/pnevma-ssh/src/config_parser.rs`, `crates/pnevma-ssh/src/tailscale.rs` | key material handling is safe, comments/metadata are validated, profile parsing is robust |
| Tracker integrations | external task tracker adapter and polling | `crates/pnevma-tracker/src/adapter.rs`, `crates/pnevma-tracker/src/linear.rs`, `crates/pnevma-tracker/src/poll.rs`, `crates/pnevma-tracker/src/types.rs` | external failures are bounded, auth material is redacted, retries and backoff are safe |
| Persistence / DB | project DB, global DB, migrations, row models, cost and telemetry aggregation | `crates/pnevma-db/src/store.rs`, `crates/pnevma-db/src/global_store.rs`, `crates/pnevma-db/src/models.rs`, migration scripts/checksum scripts | DB directories and files are permission-safe, migration integrity is checked, rollback/recovery procedures are documented |
| Redaction | logs, scrollback, context, review artifacts, remote responses | `crates/pnevma-redaction/src/lib.rs`, plus all callers in `session`, `commands`, `context`, `remote`, `db` | provider tokens, env-style secrets, connection strings, PEM blocks, and high-entropy secrets are consistently removed |
| Release/update | update-check UX, DMG packaging, signing, notarization, stapling, website release flow | `native/Pnevma/Core/AppUpdateCoordinator.swift`, `scripts/release-preflight.sh`, `scripts/release-macos-sign.sh`, `scripts/release-macos-notarize.sh`, `scripts/release-macos-staple-verify.sh`, `scripts/release-macos-package-dmg.sh`, `docs/macos-release.md`, `docs/macos-website-release-plan.md` | packaged app and DMG are reproducibly produced, signed/notarized/stapled, Gatekeeper-clean, and website-ready |
| CI / supply chain | Rust/native CI, rehearsal, release, dependency watch, audits, secret scans | `.github/workflows/ci.yml`, `.github/workflows/release-rehearsal.yml`, `.github/workflows/release.yml`, `.github/workflows/dependency-watch.yml`, `justfile`, `audit.toml`, `deny.toml`, scripts such as `run-gitleaks.sh` and migration checksum checks | workflows are stable, dependency/audit scans are scheduled, actions are pinned, artifacts are retained, and there are 10 consecutive green runs |
| Deferred product work | command center / unified agent dashboard and related UX expansion | `docs/agent-command-center-gap-analysis.md`, command-center-related native components | remains frozen until the hardening exit is formally signed off |

---

## Current hardening status: what looks closed, what is still open, what is only partially proven

### Items that appear implemented in code but still need proof

These should **not** be treated as “done” until regression tests and evidence exist.

| Item | Components | Current read | What still has to happen |
|---|---|---|---|
| Request body size limit | `crates/pnevma-remote/src/server.rs` | body limit is present | add explicit integration tests and manual-security evidence for oversize requests |
| WebSocket message size limit | `crates/pnevma-remote/src/routes/ws.rs` | max WS message size is present | add automated and manual abuse tests |
| `session.send_input` RPC allowlist exclusion | `crates/pnevma-remote/src/routes/rpc_allowlist.rs`, `crates/pnevma-remote/src/routes/ws.rs` | code now blocks/guards this path | prove default config is off, add role/subscription regression tests |
| Query token restricted to WS upgrade | `crates/pnevma-remote/src/middleware/auth_token.rs` | restriction is present | add auth bypass regression tests |
| Token revocation route | `crates/pnevma-remote/src/server.rs` | DELETE route exists | prove revoked tokens stop working immediately under concurrent sessions |
| Self-signed TLS fingerprint surfacing | `crates/pnevma-remote/src/tls.rs`, `crates/pnevma-remote/src/server.rs` | fingerprint is surfaced | still need posture tightening so fallback does not weaken production defaults |
| Scrollback permissions | `crates/pnevma-session/src/supervisor.rs` | 0600 creation behavior appears present | add filesystem mode tests and restore-path checks |
| Session persistence permissions | `native/Pnevma/Core/SessionPersistence.swift` | 0700 dir + 0600 file logic appears present | add native tests and upgrade-path validation for existing installs |
| Redaction extra patterns / entropy guard | `crates/pnevma-redaction/src/lib.rs` | features appear implemented | add config docs, tests, and end-to-end proof across all output surfaces |
| Some task state-machine property testing | `crates/pnevma-core/src/task.rs` | proptests exist | extend to workflow/orchestration/restart interactions |

### Items that should still be treated as open until explicitly closed

#### P0 blockers

1. **Release version / metadata drift**
   - `Cargo.toml` reports `0.2.0`.
   - `native/Info.plist` reports `0.2.0`.
   - smoke docs are written for `v0.2.0`.
   - `SECURITY.md` still describes supported versions as `0.1.x`.
   - some release docs still point at `v0.1.1` as the first public target.
   - This must be unified before any public “hardening complete” claim.

2. **Agent command execution allowlist risk (`npx` / npm exec class of escape)**
   - Exact components: `crates/pnevma-agents/src/adapters/claude.rs` and related adapter command-construction code under `crates/pnevma-agents/src/adapters/`.
   - This is still a release blocker until tests prove the adapter command line cannot be turned into a generic arbitrary-execution tunnel.

3. **FFI async callback lifetime safety is not yet proven enough for release**
   - Exact components: `crates/pnevma-bridge/src/lib.rs`, `native/Pnevma/Bridge/PnevmaBridge.swift`.
   - Even if the code has moved away from the earlier obviously unsound shape, this remains an unsafe-boundary release blocker until stress-tested and independently reviewed.

4. **Password-file race / TOCTOU in secret sourcing path**
   - Exact component: `crates/pnevma-commands/src/auth_secret.rs`.
   - This remains open until the file-read path is made race-safe and covered by tests.

5. **Remote token storage / validation posture**
   - Exact component: `crates/pnevma-remote/src/auth.rs`.
   - The release bar should require hashed token storage and constant-time comparison semantics, plus revocation/expiry tests.

6. **Self-signed TLS fallback can still weaken the remote posture**
   - Exact components: `crates/pnevma-remote/src/tls.rs`, `crates/pnevma-remote/src/config.rs`, `docs/security-deployment.md`, `docs/remote-access.md`.
   - It is not enough to expose the fingerprint; the default production posture must remain strict.

7. **No rate limiting on the Unix socket control plane**
   - Exact component: `crates/pnevma-commands/src/control.rs`.
   - The local plane is still a trust boundary and needs abuse controls and logging.

8. **Dispatch / event / restore integration proof is still the top functional exit-bar blocker**
   - Exact components: `crates/pnevma-core/src/events.rs`, `crates/pnevma-core/src/task.rs`, `crates/pnevma-core/src/workflow.rs`, `crates/pnevma-session/src/supervisor.rs`, `crates/pnevma-db/src/store.rs`, `native/PnevmaTests/`, `native/PnevmaUITests/`, IPC E2E scripts.

#### P1 blockers to close before hardening sign-off

1. **`disable-library-validation` entitlement needs stronger justification / compensating control**
   - Exact components: `native/Pnevma/Pnevma.entitlements`, `scripts/check-entitlements.sh`, runtime dylib validation path if added.

2. **Agent environment denylist should become an allowlist**
   - Exact component: `crates/pnevma-agents/src/env.rs`.

3. **Migration integrity and rollback posture must be explicit**
   - Exact components: migration scripts/checksum scripts, `crates/pnevma-db`, release docs.

4. **Local control plane audit logging is missing or insufficient**
   - Exact components: `crates/pnevma-commands/src/control.rs`, event/audit persistence surfaces in `crates/pnevma-db`.

5. **Global DB directory permission verification needs proof**
   - Exact components: `crates/pnevma-db/src/global_store.rs` and any DB bootstrap path.

6. **SBOM / provenance / attestations need to be part of the release lane**
   - Exact components: `.github/workflows/release.yml`, `.github/workflows/release-rehearsal.yml`.

7. **Scheduled dependency re-scan must be enforced**
   - Exact components: `.github/workflows/dependency-watch.yml`, `audit.toml`, `deny.toml`.

---

## Non-goals until the hardening exit bar is met

Do **not** consume release-hardening time on these until the checklist in this document is fully green:

- command center / unified agent dashboard work described in `docs/agent-command-center-gap-analysis.md`;
- additional pane UX expansion not required by existing smoke docs;
- broader product polish that does not directly improve release correctness, runtime reliability, security posture, or release reproducibility.

The freeze should apply to these native surfaces in particular unless a change is needed for hardening or testability:

- `native/Pnevma/Core/PaneLayoutEngine.swift`
- `native/Pnevma/Core/ContentAreaView.swift`
- `native/Pnevma/Sidebar/SidebarToolItem.swift`
- `native/Pnevma/Chrome/CommandPalette.swift`
- `native/Pnevma/Core/Workspace.swift`
- `native/Pnevma/Core/WorkspaceManager.swift`
- `native/Pnevma/Core/SessionStore.swift`
- `native/Pnevma/Panes/ReplayPane.swift`
- `native/Pnevma/Panes/Workflow/`
- `native/Pnevma/Chrome/SessionManagerView.swift`
- `native/Pnevma/Panes/TaskBoardPane.swift`
- `native/Pnevma/Panes/NotificationsPane.swift`
- `native/Pnevma/Panes/NotificationsViewModel.swift`
- `native/Pnevma/Panes/DailyBriefPane.swift`
- `native/Pnevma/Panes/AnalyticsPane.swift`
- `native/Pnevma/Panes/ProviderUsageUI.swift`
- `native/Pnevma/App/AppDelegate.swift`
- `ProtectedActionSheet.swift`

---

## Step-by-step hardening plan

The order below is the sequence I would use to get from “hardening in progress” to “hardening complete.” Some sub-work can run in parallel after Phase 0, but the exit decision should follow this order.

### Phase 0 — Freeze scope and align the release source of truth

**Goal:** remove all ambiguity about what release is being hardened and what counts as done.

**Exact components**

- `Cargo.toml`
- `native/Info.plist`
- `README.md`
- `SECURITY.md`
- `docs/implementation-status.md`
- `docs/hardening-exit-criteria.md`
- `docs/macos-release.md`
- `docs/manual-smoke-tests.md`
- `docs/security-release-gate.md`
- `docs/macos-website-release-plan.md`
- any release filename/version references in `scripts/release-preflight.sh` and packaging scripts

**Tasks**

- [x] Choose the canonical public release train now: unified on `0.2.0`.
- [x] Update `Cargo.toml` workspace version and `native/Info.plist` so Rust, native, packaged app, and docs all describe the same release.
- [x] Update `SECURITY.md` supported-version policy to match the actual release line being shipped.
- [x] Update smoke/security/release docs so screenshots, filenames, DMG names, and examples use the canonical version consistently.
- [x] Update release notes / website release plan docs so the website lane is not publishing a different version identity than the build pipeline.
- [x] Freeze the hardening scope in `docs/implementation-status.md`: explicitly say feature work is blocked until this plan is complete.

**Done when**

- there is exactly **one** release identity in code, docs, and packaging;
- no workflow, script, doc, or policy references a stale version line.

**Evidence**

- one reviewable PR diff touching all versioned sources;
- a packaged artifact whose app metadata matches docs and release notes.

---

### Phase 1 — Lock down the remote plane first

**Goal:** remove the highest-risk externally reachable issues before spending more time on broader test polish.

**Exact components**

- `crates/pnevma-remote/src/server.rs`
- `crates/pnevma-remote/src/routes/ws.rs`
- `crates/pnevma-remote/src/routes/rpc_allowlist.rs`
- `crates/pnevma-remote/src/auth.rs`
- `crates/pnevma-remote/src/middleware/auth_token.rs`
- `crates/pnevma-remote/src/config.rs`
- `crates/pnevma-remote/src/tls.rs`
- `crates/pnevma-remote/src/tailscale.rs`
- `docs/security-deployment.md`
- `docs/remote-access.md`
- `docs/manual-security-tests.md`

**Tasks**

- [ ] Verify and enforce `remote.allow_session_input = false` as the default in config parsing and runtime behavior.
- [ ] Add explicit tests for all `SessionInput` cases:
  - denied when config is off;
  - denied if not subscribed to the matching `session:<id>` channel;
  - denied for insufficient role;
  - allowed only in the narrow intended configuration.
- [ ] Ensure `session.new` and `session.send_input` stay excluded from generic RPC allowlists unless there is a separately justified path.
- [ ] Move token storage/validation to a hardened model in `crates/pnevma-remote/src/auth.rs`:
  - hash stored tokens;
  - use constant-time comparison for presented token vs stored verifier;
  - test expiry, revocation, replay resistance, and concurrent revocation behavior.
- [ ] Confirm bearer-vs-query token precedence is stable and query tokens are accepted only on the WebSocket upgrade path.
- [ ] Expand auth bypass tests to cover: missing token, wrong token, expired token, revoked token, query token on non-WS route, bearer token on WS, and role-restricted methods.
- [ ] Tighten TLS posture:
  - default production docs and config must prefer `tailscale` mode;
  - `tls_allow_self_signed_fallback` should remain **false** by default in release guidance;
  - if fallback is ever used, surface a loud warning in logs/UI/API and make the trust downgrade explicit.
- [ ] Keep origin validation in place and add regression tests for:
  - missing `Origin`;
  - disallowed origin;
  - localhost origin acceptance only when configured;
  - query-token + missing origin rejection.
- [ ] Add burst-abuse tests for per-IP connection caps and message-rate caps.
- [ ] Add over-limit response assertions so rate limiting is observable and supportable.

**Done when**

- all remote Critical/High items are either fixed and tested or explicitly rejected as unsupported configurations;
- the remote plane has deterministic auth, TLS, origin, and abuse behavior.

**Evidence**

- new automated remote integration tests;
- filled-out `docs/manual-security-tests.md` evidence for G7/G8/G9/G10;
- release rehearsal logs showing the configured production posture.

---

### Phase 2 — Harden the local control plane and secret sourcing path

**Goal:** treat the local control socket as a real trust boundary, not an implicitly safe path.

**Exact components**

- `crates/pnevma-commands/src/auth_secret.rs`
- `crates/pnevma-commands/src/control.rs`
- `crates/pnevma-commands/src/remote_bridge.rs`
- `crates/pnevma-db/src/store.rs` or audit/event persistence surfaces
- `docs/security-deployment.md`
- `docs/manual-security-tests.md`

**Tasks**

- [ ] Rewrite the password-file read path in `auth_secret.rs` so it is race-safe and not vulnerable to symlink/swap TOCTOU tricks.
  - Validate file type before trust.
  - Use secure open/read semantics.
  - Re-check metadata if required by implementation.
- [ ] Add tests for file, symlink, replacement, and permission edge cases.
- [ ] Add local control-plane request rate limiting in `control.rs`.
- [ ] Add local-plane audit logging for authentication attempts, privileged operations, and repeated failures.
- [ ] Make sure local audit events are persisted or surfaced in a way operators can inspect after the fact.
- [ ] Confirm password source precedence remains exactly as documented:
  - env first;
  - Keychain second;
  - file fallback last.
- [ ] Add regression tests proving env/Keychain sources prevent password leakage into CLI args or logs.

**Done when**

- secret sourcing is race-safe and documented;
- the local control plane has abuse controls and auditable traces;
- manual security tests cover the local path, not just the remote path.

**Evidence**

- targeted unit/integration tests for `auth_secret.rs` and `control.rs`;
- local audit log examples in the release evidence bundle.

---

### Phase 3 — Finish the unsafe-boundary review for the Rust↔Swift bridge

**Goal:** eliminate the last “maybe unsound” concern at the FFI edge.

**Exact components**

- `crates/pnevma-bridge/src/lib.rs`
- `crates/pnevma-bridge/pnevma-bridge.h`
- `native/Pnevma/Bridge/PnevmaBridge.swift`
- `scripts/check-ffi-coverage.sh`
- `native/Pnevma/App/AppDelegate.swift`
- `native/Pnevma/Panes/` surfaces that consume bridge callbacks

**Tasks**

- [ ] Perform an explicit unsafe-code review of `crates/pnevma-bridge/src/lib.rs`.
  - Every `unsafe` block must have a current `SAFETY:` explanation that matches the implementation.
  - Every `unsafe impl Send/Sync` must be justified against actual callback/lifetime behavior.
- [ ] Add stress tests for `pnevma_call_async` covering:
  - callback after cancellation;
  - callback after `pnevma_destroy`;
  - multiple concurrent async calls;
  - callback ordering under contention;
  - repeated create/destroy cycles.
- [ ] Add negative tests to prove the bridge never double-frees callback context, never invokes a stale pointer, and never leaks pending callbacks on shutdown.
- [ ] Add Swift-side tests for callback registration, threading assumptions, and teardown behavior.
- [ ] Run `scripts/check-ffi-coverage.sh` in CI and fail when exported Rust symbols drift from the Swift bridge or command-surface expectations.
- [ ] If any lifetime contract still depends on caller discipline alone, redesign it so the Rust side owns enough state to make misuse harder.

**Done when**

- bridge async behavior is stress-tested and independently reviewed;
- no open “unsafe but probably okay” concerns remain.

**Evidence**

- dedicated FFI test suite output;
- unsafe-code review checklist attached to the release evidence bundle.

---

### Phase 4 — Close the agent execution and environment-hardening gaps

**Goal:** make sure the “agent adapter” layer cannot become a generic arbitrary-execution or secret-leak path.

**Exact components**

- `crates/pnevma-agents/src/adapters/claude.rs`
- `crates/pnevma-agents/src/adapters/codex.rs`
- `crates/pnevma-agents/src/adapters/`
- `crates/pnevma-agents/src/env.rs`
- `crates/pnevma-agents/src/pool.rs`
- `crates/pnevma-agents/src/profiles.rs`
- `crates/pnevma-agents/src/reconciler.rs`
- `crates/pnevma-agents/src/resilience.rs`
- `crates/pnevma-core/src/orchestration.rs`
- `crates/pnevma-commands/src/commands/tasks.rs`

**Tasks**

- [ ] Remove any `npx` / `npm exec`-style allowance from adapter command construction unless there is a very narrowly justified, testable, non-shelling path.
- [ ] Add command-construction tests proving only expected provider binaries and argument shapes can be launched.
- [ ] Convert env propagation from denylist to allowlist in `crates/pnevma-agents/src/env.rs`.
- [ ] Create a definitive list of environment variables that are allowed to flow into provider subprocesses.
- [ ] Add tests proving disallowed env vars do not reach agent processes.
- [ ] Verify `auto_approve` remains configurable but safe by default.
- [ ] Confirm retries/backoff do not duplicate destructive actions or obscure operator visibility.
- [ ] Add structured logging around adapter launch failures that is useful but redacted.

**Done when**

- the adapter layer is narrow, deterministic, and minimally privileged;
- environment exposure is explicit rather than incidental.

**Evidence**

- adapter launch tests;
- env filtering tests;
- updated operator docs describing what can and cannot be executed.

---

### Phase 5 — Finish data-at-rest hardening and redaction proof

**Goal:** ensure files, DBs, event logs, session logs, and generated artifacts are permission-safe and secret-clean.

**Exact components**

- `crates/pnevma-session/src/supervisor.rs`
- `native/Pnevma/Core/SessionPersistence.swift`
- `crates/pnevma-redaction/src/lib.rs`
- `crates/pnevma-context/src/compiler.rs`
- `crates/pnevma-context/src/discovery.rs`
- `crates/pnevma-db/src/store.rs`
- `crates/pnevma-db/src/global_store.rs`
- `crates/pnevma-db/src/models.rs`
- migration checksum scripts such as `scripts/check-migration-checksums.sh` and update/checksum helpers
- review artifact generation surfaces in commands/git/core layers

**Tasks**

- [ ] Add tests proving scrollback/log files are created with `0600`, not merely chmod’d after creation.
- [ ] Add tests proving config/session directories are created with `0700` and existing overly-permissive directories are corrected or rejected.
- [ ] Verify global DB directory and DB file permissions at bootstrap and on upgrade.
- [ ] Add migration-integrity enforcement to release preflight if not already included end-to-end.
- [ ] Add or finish rollback/recovery docs for failed migrations and packaged-app upgrade paths.
- [ ] Build an end-to-end redaction matrix covering:
  - provider tokens;
  - bearer/auth headers;
  - `.env`-style key-value secrets;
  - PEM blocks;
  - connection strings;
  - high-entropy random strings;
  - provider-specific key formats.
- [ ] Test redaction at every output surface:
  - live session output;
  - replay/scrollback;
  - event log;
  - context packs;
  - review artifacts;
  - remote responses;
  - diagnostics/log files.
- [ ] Document and test `extra_patterns` and entropy-guard configuration so operators can close gaps without patching code.

**Done when**

- no sensitive file is left world/group-readable by default;
- all persistence surfaces are covered by redaction tests;
- migration integrity is enforced and recoverable.

**Evidence**

- filesystem-mode test outputs;
- redaction regression corpus and results;
- migration checksum and rollback evidence.

---

### Phase 6 — Complete the domain correctness test matrix

**Goal:** satisfy the repo’s explicit requirement that dispatch, event, and restore flows are proven before new feature work resumes.

**Exact components**

- `crates/pnevma-core/src/events.rs`
- `crates/pnevma-core/src/task.rs`
- `crates/pnevma-core/src/workflow.rs`
- `crates/pnevma-core/src/orchestration.rs`
- `crates/pnevma-core/src/protected_actions.rs`
- `crates/pnevma-core/src/workflow_contract.rs`
- `crates/pnevma-commands/src/commands/mod.rs`
- `crates/pnevma-commands/src/commands/tasks.rs`
- `crates/pnevma-commands/src/state.rs`
- `crates/pnevma-db/src/store.rs`
- `crates/pnevma-session/src/supervisor.rs`
- `crates/pnevma-git/src/service.rs`
- `native/PnevmaTests/`
- `native/PnevmaUITests/`
- app-level E2E helpers such as `scripts/ipc-e2e-smoke.sh`, `scripts/ipc-e2e-recovery.sh`, `scripts/run-app-smoke.sh`

**Tasks**

- [ ] Finish the dispatch integration suite:
  - task creation → agent selection → worktree setup → subprocess launch → event emission → terminal output → completion/failure persistence.
- [ ] Finish the event integration suite:
  - events emitted in expected order/shape;
  - events survive restart;
  - notifications/UI surfaces rebuild correctly from persisted data.
- [ ] Finish the restore integration suite:
  - app restart after active session;
  - app restart after failed session;
  - task/workflow restore after crash;
  - replay pane still consistent after restore.
- [ ] Extend state-machine/property tests from `task.rs` into workflow and orchestration interactions.
- [ ] Add DB round-trip tests for critical row families:
  - sessions;
  - tasks;
  - worktrees;
  - reviews/checks;
  - workflow instances;
  - notifications/events;
  - costs/telemetry aggregates.
- [ ] Add protected-action tests so risky operations remain gated after restart and across UI/CLI/remote entry points.
- [ ] Add failure-injection tests for partial worktree creation, git failures, provider CLI failures, and DB write failures.

**Done when**

- the exact hardening-exit requirement for dispatch/event/restore is unambiguously met;
- correctness is proven across restart and failure paths, not only happy paths.

**Evidence**

- CI-visible integration suite names and green runs;
- release evidence bundle includes links/logs for the dispatch/event/restore suites.

---

### Phase 7 — Finish native and Ghostty runtime hardening

**Goal:** make the macOS app itself release-safe, not just the Rust backend.

**Exact components**

- `native/project.yml`
- `native/Package.swift`
- `native/Info.plist`
- `native/Pnevma/Pnevma.entitlements`
- `native/Pnevma/Core/SessionPersistence.swift`
- `native/Pnevma/Core/AppUpdateCoordinator.swift`
- `native/PnevmaTests/`
- `native/PnevmaUITests/`
- `scripts/run-ghostty-smoke.sh`
- `scripts/run-packaged-launch-smoke.sh`
- `scripts/check-entitlements.sh`
- `vendor/README.md`
- `patches/ghostty/0001-fallback-without-display-link.patch`

**Tasks**

- [ ] Enforce warning-free native gates in CI for:
  - `swift test`;
  - `xcodebuild build`;
  - `xcodebuild test`.
- [ ] Add `run-ghostty-smoke.sh` to CI and make it non-optional for hardening exit.
- [ ] Make sure packaged-app launch smoke, not just dev build launch, runs in CI or release rehearsal.
- [ ] Review `disable-library-validation` in `Pnevma.entitlements`.
  - If it can be removed, remove it.
  - If it cannot be removed because Ghostty/runtime packaging requires it, add a runtime dylib/library allowlist check and document the justification.
- [ ] Keep `check-entitlements.sh` strict: it should fail on unexpected entitlements and capture effective entitlements from the signed app.
- [ ] Add native tests for `SessionPersistence.swift` upgrade and corruption handling.
- [ ] Verify update-check UX in `AppUpdateCoordinator.swift` does not mislead users about install/update state.
- [ ] Re-validate the Ghostty vendor patch and record why it remains safe and necessary for release.

**Done when**

- native lanes are clean, deterministic, and warning-free;
- Ghostty runtime is exercised in automation;
- entitlement posture is minimized and justified.

**Evidence**

- green native CI lanes with warnings treated as failures;
- entitlements report and effective entitlements plist in the evidence bundle;
- Ghostty smoke logs attached.

---

### Phase 8 — Make release packaging, signing, notarization, and website delivery boring

**Goal:** turn release from an artisanal procedure into a reproducible lane.

**Exact components**

- `scripts/release-preflight.sh`
- `scripts/release-macos-package-dmg.sh`
- `scripts/release-macos-sign.sh`
- `scripts/release-macos-notarize.sh`
- `scripts/release-macos-staple-verify.sh`
- `scripts/check-entitlements.sh`
- `.github/workflows/release-rehearsal.yml`
- `.github/workflows/release.yml`
- `docs/macos-release.md`
- `docs/macos-website-release-plan.md`
- `docs/security-release-gate.md`

**Tasks**

- [ ] Keep `release-preflight.sh` as the canonical local/CI packaging gate and ensure it runs:
  - Rust checks/tests/audit;
  - native build/tests;
  - entitlement validation;
  - DMG packaging;
  - packaged-app launch smoke.
- [ ] Ensure release rehearsal produces the same artifact shape as the real release lane.
- [ ] Add artifact checks for:
  - DMG checksum;
  - signed app validity;
  - notarization success;
  - staple success;
  - `spctl` / Gatekeeper acceptance.
- [ ] Add clean-machine installation validation from the website-distributed DMG, not only from CI workspace artifacts.
- [ ] Include SBOM generation and artifact publication in the release lane.
- [ ] Add provenance/attestation/signing for SBOM and release artifacts if not already present.
- [ ] Retain the logs/artifacts needed for post-release investigation.
- [ ] Make sure the website release plan is not a separate manual branch of reality: it must consume the same hardened artifact built by the release lane.

**Done when**

- the release lane is reproducible and evidence-rich;
- a clean machine can install and launch the exact website-shipped DMG without surprises.

**Evidence**

- rehearsal logs;
- notarization IDs/logs;
- stapling output;
- `codesign` and `spctl` output;
- checksum/SBOM/provenance outputs.

---

### Phase 9 — Stabilize CI and supply-chain policy until 10 green runs is easy

**Goal:** meet the explicit “10 consecutive green runs” exit requirement and keep it from being a one-off fluke.

**Exact components**

- `.github/workflows/ci.yml`
- `.github/workflows/release-rehearsal.yml`
- `.github/workflows/release.yml`
- `.github/workflows/dependency-watch.yml`
- `justfile`
- `audit.toml`
- `deny.toml`
- scripts such as `run-gitleaks.sh`, migration checksum checks, Ghostty build helpers, shellcheck/actionlint hooks

**Tasks**

- [ ] Audit all workflows for flake sources, especially native build environment prep, Ghostty/vendor fetching, and packaged launch smoke timing.
- [ ] Pin third-party GitHub Actions to commit SHAs if not already pinned.
- [ ] Ensure dependency-watch, `cargo audit`, and `cargo deny` scans run on a schedule in addition to PR/push.
- [ ] Add or keep secret scanning (`gitleaks`) in the workflow check lane.
- [ ] Keep shell scripts under `shellcheck` and GitHub Actions under `actionlint` in CI.
- [ ] Run migration checksum verification in CI and release preflight.
- [ ] Track flaky tests/builds until there are **10 consecutive green runs** on `main` across:
  - Rust checks lane;
  - native app build/test lane;
  - release package preflight lane;
  - sign/notarize rehearsal lane where secrets are available.
- [ ] Do not count reruns of the same broken commit as part of the 10-run streak.

**Done when**

- the 10-run streak is achieved without waivers;
- CI results are stable enough that failure usually means a real regression.

**Evidence**

- a release sign-off table listing the 10 qualifying runs by commit and workflow.

---

### Phase 10 — Run the full manual smoke and security matrix against the release candidate

**Goal:** prove the product the user downloads behaves correctly across all documented feature flows.

**Exact components / docs**

- `docs/manual-smoke-tests.md`
- `docs/manual-security-tests.md`
- `docs/threat-model.md`
- packaged app and DMG built by the release lane
- any supporting E2E scripts used to accelerate manual validation

**Tasks**

- [ ] Execute the full manual smoke script against the candidate DMG:
  - launch and first run;
  - project setup and persistence;
  - terminal and session lifecycle;
  - task create/persist;
  - agent dispatch/live output/cost tracking;
  - git worktree/branch/diff/checks/review pack;
  - merge queue;
  - workflow creation/persistence;
  - notifications/event log;
  - documented edge cases/cleanup.
- [ ] Execute the manual security script against the same candidate:
  - latency validation;
  - password source hardening;
  - redaction regression;
  - sign/notarize/staple validation;
  - auth bypass testing;
  - rate-limit burst testing;
  - RPC allowlist testing;
  - body and WS size-limit testing.
- [ ] Record exact observations, not just pass/fail labels.
- [ ] File and fix every hardening bug found during this pass before counting the candidate as release-ready.

**Done when**

- both manual docs have fully filled evidence sections for the candidate build;
- no unresolved manual-test findings remain in hardening scope.

**Evidence**

- completed manual test records attached to the release evidence bundle.

---

### Phase 11 — Formal hardening exit and feature-freeze lift

**Goal:** make the “we can move on now” decision explicit, reviewable, and hard to backslide from.

**Exact components / docs**

- `docs/hardening-exit-criteria.md`
- `docs/security-release-gate.md`
- `docs/implementation-status.md`
- `README.md`
- release evidence bundle location and CI run references

**Tasks**

- [ ] Create a final sign-off checklist that copies every hardening gate into one place.
- [ ] Mark every Critical and High issue as fixed, rejected with documented rationale, or impossible to reproduce with attached evidence. There should be **zero** unresolved Critical/High items.
- [ ] Confirm all P1 items above are fixed or explicitly accepted with narrow rationale.
- [ ] Confirm the 10-green-run streak and attach the list.
- [ ] Confirm the candidate DMG is signed, notarized, stapled, Gatekeeper-valid, and website-install tested.
- [ ] Confirm docs are current and no hardening doc still describes an outdated release train.
- [ ] Only after all of that, update `docs/implementation-status.md` and `README.md` to state that the hardening exit bar is met and feature work may resume.

**Done when**

- there is a single sign-off artifact any reviewer can inspect to understand why the freeze is lifted.

**Evidence**

- signed hardening-exit checklist plus linked CI/release artifacts.

---

## Exact feature-by-feature hardening checklist

This is the practical “don’t miss anything” list by user-facing feature.

### 1) Launch, onboarding, and project selection

**Components**

- `native/Pnevma/App/AppDelegate.swift`
- `native/Pnevma/Core/WorkspaceManager.swift`
- `native/Pnevma/Core/SessionPersistence.swift`
- `crates/pnevma-db/src/global_store.rs`
- `crates/pnevma-commands/src/state.rs`

**Must be true before exit**

- [ ] app launches from packaged DMG on a clean machine;
- [ ] recent projects/global state persist and restore correctly;
- [ ] global state files/directories are permission-safe;
- [ ] corrupt/partial session state fails safely.

### 2) Terminal sessions, replay, and restore

**Components**

- `crates/pnevma-session/src/supervisor.rs`
- `native/Pnevma/Panes/ReplayPane.swift`
- `native/Pnevma/Chrome/SessionManagerView.swift`
- `native/Pnevma/Core/SessionStore.swift`
- `scripts/run-ghostty-smoke.sh`

**Must be true before exit**

- [ ] sessions survive expected restarts;
- [ ] replay content is consistent with redaction rules;
- [ ] scrollback files are created with safe permissions;
- [ ] stuck/idle/waiting/error/complete states are observable and correct.

### 3) Task lifecycle and protected actions

**Components**

- `crates/pnevma-core/src/task.rs`
- `crates/pnevma-core/src/protected_actions.rs`
- `crates/pnevma-commands/src/commands/tasks.rs`
- `native/Pnevma/Panes/TaskBoardPane.swift`
- `ProtectedActionSheet.swift`

**Must be true before exit**

- [ ] task transitions are valid and property-tested;
- [ ] protected actions remain gated across UI, local control, and remote paths;
- [ ] blocked/looped/review flows persist correctly across restart.

### 4) Agent dispatch and provider execution

**Components**

- `crates/pnevma-agents/src/adapters/`
- `crates/pnevma-agents/src/env.rs`
- `crates/pnevma-core/src/orchestration.rs`
- `crates/pnevma-commands/src/commands/tasks.rs`

**Must be true before exit**

- [ ] no unsafe generic execution path like `npx` remains;
- [ ] env propagation is allowlist-based;
- [ ] retries are bounded and observable;
- [ ] redaction covers provider failures and command logging.

### 5) Git worktrees, review artifacts, checks, and merge queue

**Components**

- `crates/pnevma-git/src/service.rs`
- `crates/pnevma-git/src/hooks.rs`
- `crates/pnevma-git/src/lease.rs`
- `crates/pnevma-db/src/models.rs`
- review/check/merge queue UI surfaces

**Must be true before exit**

- [ ] worktree isolation is preserved;
- [ ] checks/reviews/merge queue survive restart;
- [ ] generated artifacts do not leak secrets;
- [ ] failure paths clean up correctly.

### 6) Workflow engine and automation

**Components**

- `crates/pnevma-core/src/workflow.rs`
- `crates/pnevma-core/src/workflow_contract.rs`
- `crates/pnevma-commands/src/automation/`
- workflow UI surfaces in `native/Pnevma/Panes/Workflow/`

**Must be true before exit**

- [ ] workflow state transitions and loop/failure policy are tested;
- [ ] workflow instances restore correctly after restart;
- [ ] automation retries do not duplicate destructive effects silently.

### 7) Notifications, events, analytics, and provider usage UI

**Components**

- `crates/pnevma-core/src/events.rs`
- `crates/pnevma-commands/src/event_emitter.rs`
- `crates/pnevma-db/src/store.rs`
- `native/Pnevma/Panes/NotificationsPane.swift`
- `native/Pnevma/Panes/NotificationsViewModel.swift`
- `native/Pnevma/Panes/DailyBriefPane.swift`
- `native/Pnevma/Panes/AnalyticsPane.swift`
- `native/Pnevma/Panes/ProviderUsageUI.swift`

**Must be true before exit**

- [ ] events are durable enough for restore and auditability;
- [ ] analytics/provider usage never expose secrets;
- [ ] UI rebuilds correctly from persisted event state.

### 8) FFI bridge and native/Rust control path

**Components**

- `crates/pnevma-bridge/src/lib.rs`
- `native/Pnevma/Bridge/PnevmaBridge.swift`
- `scripts/check-ffi-coverage.sh`

**Must be true before exit**

- [ ] async callbacks are lifetime-safe under load and teardown;
- [ ] exported bridge API and Swift usage are in sync;
- [ ] there are no crash-on-quit or callback-after-free paths.

### 9) Local control socket

**Components**

- `crates/pnevma-commands/src/control.rs`
- `crates/pnevma-commands/src/auth_secret.rs`

**Must be true before exit**

- [ ] auth secret loading is race-safe;
- [ ] local requests are rate-limited;
- [ ] local admin actions are auditable.

### 10) Remote HTTP/WebSocket access

**Components**

- `crates/pnevma-remote/src/server.rs`
- `crates/pnevma-remote/src/routes/ws.rs`
- `crates/pnevma-remote/src/routes/rpc_allowlist.rs`
- `crates/pnevma-remote/src/auth.rs`
- `crates/pnevma-remote/src/middleware/auth_token.rs`
- `crates/pnevma-remote/src/tls.rs`

**Must be true before exit**

- [ ] auth bypass tests are exhaustive;
- [ ] session input remains narrow and off by default;
- [ ] origin and rate-limit defenses are proven;
- [ ] production TLS posture cannot silently degrade.

### 11) SSH and tracker integrations

**Components**

- `crates/pnevma-ssh/src/key_manager.rs`
- `crates/pnevma-ssh/src/profile.rs`
- `crates/pnevma-ssh/src/config_parser.rs`
- `crates/pnevma-ssh/src/tailscale.rs`
- `crates/pnevma-tracker/src/linear.rs`
- `crates/pnevma-tracker/src/poll.rs`

**Must be true before exit**

- [ ] key handling and profile parsing are covered;
- [ ] external auth material is redacted;
- [ ] polling/backoff cannot overload external services or the app.

### 12) Release packaging and update checks

**Components**

- `native/Pnevma/Core/AppUpdateCoordinator.swift`
- release scripts under `scripts/`
- release workflows under `.github/workflows/`

**Must be true before exit**

- [ ] users can install the DMG and launch cleanly;
- [ ] update checks report accurately;
- [ ] signing/notarization/stapling are reproducible.

---

## Recommended implementation order for the team

If multiple people are working in parallel, split the work like this **after Phase 0 is complete**:

### Lane A — Security boundary closure

- Remote plane: `pnevma-remote`
- Local plane: `auth_secret.rs`, `control.rs`
- Agent execution: `pnevma-agents`
- Deliverable: zero open Critical/High findings

### Lane B — Correctness and restore proof

- `pnevma-core`, `pnevma-session`, `pnevma-db`, `pnevma-git`
- native restore/state tests
- IPC/app-level E2E scripts
- Deliverable: dispatch/event/restore integration suites green

### Lane C — Native/runtime/release lane

- `native/` tests and warnings
- Ghostty smoke in CI
- entitlements review
- release rehearsal / notarization / DMG packaging
- Deliverable: green release package and sign/notarize rehearsal lanes

### Lane D — Evidence and policy closure

- docs alignment
- version drift fix
- release evidence bundle assembly
- 10-green-run tracking
- Deliverable: sign-off package and hardening-exit update

---

## Final hardening exit checklist

Do **not** lift the freeze until every line below is checked.

### Release identity and docs

- [ ] `Cargo.toml` version matches `native/Info.plist`
- [ ] `SECURITY.md` supported versions match reality
- [ ] `README.md` and hardening docs describe the same release target
- [ ] smoke/security/release docs use the same version and artifact names

### Security findings

- [ ] `npx` / generic adapter execution path removed or narrowly justified and tested
- [ ] FFI async callback lifetime issue closed with tests/review
- [ ] password-file TOCTOU issue closed
- [ ] remote token storage/validation hardened
- [ ] self-signed TLS fallback cannot silently weaken production posture
- [ ] local control-plane rate limiting added
- [ ] no unresolved Critical or High findings remain

### Automated gates

- [ ] `just check`
- [ ] `cd native && swift test`
- [ ] `just xcode-test`
- [ ] dispatch/event/restore integration suites
- [ ] Ghostty smoke in CI
- [ ] release package preflight on `main`
- [ ] sign/notarize rehearsal green
- [ ] 10 consecutive green runs on required lanes

### Manual gates

- [ ] full manual smoke test complete on candidate DMG
- [ ] full manual security test complete on candidate DMG
- [ ] clean-machine website DMG validation complete

### Release evidence

- [ ] entitlements report archived
- [ ] effective entitlements plist archived
- [ ] `codesign` output archived
- [ ] `spctl` output archived
- [ ] notarization/stapling logs archived
- [ ] SBOM archived
- [ ] provenance/attestation outputs archived
- [ ] remote/auth/redaction/manual-security notes archived

### Feature freeze lift

- [ ] `docs/implementation-status.md` updated to state hardening exit is met
- [ ] command-center / post-hardening roadmap work can begin only after this point

---

## Bottom line

The repo is **not** at the “resume features” point yet.

The shortest safe path to that point is:

1. unify release identity,
2. close the remaining remote/local/FFI/agent security blockers,
3. finish dispatch/event/restore proof,
4. harden native/Ghostty/release lanes,
5. collect the evidence bundle,
6. achieve the 10-green-run streak,
7. then lift the freeze.

If the team executes the phases above in order, the result will be a release-hardened repo with a defensible sign-off boundary instead of an informal “probably good enough.”
