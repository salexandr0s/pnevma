# Pnevma Remediation Master Plan

> **Historical note**: This document was authored during the Tauri + React frontend era. The frontend has since been migrated to native Swift/AppKit. Any references to Tauri, React, `frontend/`, `cargo tauri`, `npm`, or `pnevma-app` crate are historical artifacts reflecting the state at the time this plan was written. The Rust backend crates and all remediation items not related to the frontend remain accurate.

Merged and deduplicated from multiple audit sessions. 56 unique items across 7 workstreams.

---

## Priority Legend

| Tag          | Meaning                              | Gate        |
| ------------ | ------------------------------------ | ----------- |
| **BLOCKER**  | Must fix before any external release | Blocks GA   |
| **HIGH**     | Fix before design-partner milestone  | Blocks beta |
| **STANDARD** | Fix before Standard-tier DoD is met  | Blocks v1.0 |
| **LOW**      | Nice-to-have, improve over time      | No gate     |

---

## Workstream A: Security Blockers (6 items)

All BLOCKER. Must land before any build leaves the dev machine.

| ID  | Item                               | File(s)                                                                                 | Action                                                                                                                                                         |
| --- | ---------------------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| A1  | Request body size limit            | `pnevma-remote/src/server.rs`                                                           | Add `RequestBodyLimitLayer::new(2_097_152)` (2 MB) to the axum router                                                                                          |
| A2  | WebSocket message size limit       | `pnevma-remote/src/routes/ws.rs`                                                        | Configure `max_message_size(65_536)` (64 KB) on the WS upgrade                                                                                                 |
| A3  | session.send_input remote exposure | `pnevma-remote/src/routes/rpc_allowlist.rs:14`                                          | Remove `session.send_input` from RPC allowlist OR add project-scoped session ownership validation before input delivery                                        |
| A4  | Query-string token scope           | `pnevma-remote/src/middleware/auth_token.rs:40-51`                                      | Restrict `?token=` fallback to WebSocket upgrade requests only; log a warning when used                                                                        |
| A5  | Secrets in CLI args                | `pnevma-commands/src/commands/mod.rs:1816`                                              | Replace `security add-generic-password -w <value>` shell call with the `security-framework` Rust crate, or pipe password via stdin                             |
| A6  | auto_approve + env stripping       | `pnevma-agents/src/adapters/claude.rs:89`, `pnevma-commands/src/commands/tasks.rs:1520` | Make `auto_approve` configurable in pnevma.toml (default false); strip `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, etc. from agent process environment before spawn |

---

## Workstream B: Security High Priority (8 items)

HIGH priority. Fix before design-partner beta.

| ID  | Item                          | File(s)                                    | Action                                                                                                                             |
| --- | ----------------------------- | ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------- |
| B1  | Token revocation              | `pnevma-remote/src/auth.rs`                | Add `revoke_token(token_id)` to `TokenStore` and expose `DELETE /api/auth/token` route                                             |
| B2  | Secret redaction population   | `pnevma-commands/src/commands/mod.rs:2638` | Populate the secrets list from keychain entries / known env vars and pass it to all `redact_text` callsites instead of `&[]`       |
| B3  | TestCommand validation        | `pnevma-commands/src/commands/mod.rs:1954` | Validate `CheckType::TestCommand` commands against an allowlist of patterns, or block `task.create` from the remote RPC allowlist  |
| B4  | FFI cb_ctx safety             | `pnevma-bridge/src/lib.rs:268-283`         | Add Arc-based reference counting or sentinel canary for `cb_ctx` pointer in `pnevma_call_async`; add `#[safety]` doc comments      |
| B5  | Token TTL precision           | `pnevma-remote/src/auth.rs:65`             | Change token TTL comparison from `num_hours()` to `num_seconds()` or direct `DateTime` comparison to avoid off-by-up-to-59-minutes |
| B6  | Tailscale IPv6 CGNAT          | `pnevma-remote/src/tailscale.rs:51-59`     | Add Tailscale IPv6 CGNAT range (`fd7a:115c:a1e0::/48`) to `is_tailscale_ip`                                                        |
| B7  | SSH keygen comment validation | `pnevma-ssh/src/key_manager.rs:95`         | Validate comment: max 256 chars, printable ASCII only, strip null bytes                                                            |
| B8  | Self-signed cert fingerprint  | `pnevma-remote/src/tls.rs:64-66`           | Emit self-signed certificate fingerprint at startup; add config option to reject self-signed mode; display cert status in UI       |

---

## Workstream C: Documentation Updates (7 items)

STANDARD priority. Parallel-safe — no code deps between items.

| ID  | Item                      | File(s)                         | Action                                                                                                                                                                                                                                 |
| --- | ------------------------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| C1  | README.md rewrite         | `README.md`                     | Remove all Tauri 2.x, React, Zustand, xterm.js, Vite, `frontend/`, `cargo tauri dev`, `npm install`, `make frontend-check` references. Rewrite to reflect: Rust backend + native Swift/AppKit + Ghostty terminal + `just` build system |
| C2  | AGENTS.md update          | `AGENTS.md`                     | Remove Tauri, xterm.js, React, `frontend/`, `npx tsc`, `npx eslint` references. Align with native Swift/AppKit reality                                                                                                                 |
| C3  | Architecture overview     | `docs/architecture-overview.md` | Verify crate layout matches reality (no `pnevma-app`, now has `pnevma-bridge`, `pnevma-commands`, `pnevma-remote`). Update diagrams                                                                                                    |
| C4  | Release checklist         | `docs/release-checklist.md`     | Remove `cd frontend && npx tsc --noEmit && npx eslint . && npx vite build`. Replace with `just check` + `just xcode-build`                                                                                                             |
| C5  | Implementation status     | `docs/implementation-status.md` | Remove all "Tauri app shell", "React frontend shell", "Tauri commands/events" references. Update to native Swift/AppKit status                                                                                                         |
| C6  | Create project CLAUDE.md  | `CLAUDE.md` (project root)      | Define verification commands (`just check`, `just test`, `cargo audit`), project-specific conventions, link to DoD                                                                                                                     |
| C7  | Cargo audit accepted risk | (new) `audit.toml` + docs       | Document RUSTSEC-2023-0071 (rsa via sqlx-mysql, unused — SQLite only) as accepted risk with rationale; create `audit.toml` to ignore                                                                                                   |

---

## Workstream D: Test Coverage (12 items)

STANDARD priority. All items are independent — maximum parallelism.

| ID  | Item                              | File(s)                                     | Action                                                                                                                           |
| --- | --------------------------------- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| D1  | pnevma-db roundtrip tests         | `pnevma-db/src/store.rs`                    | Add tests for all 18 row types: insert, query, update, delete roundtrips                                                         |
| D2  | pnevma-context discovery tests    | `pnevma-context/src/discovery.rs`           | Add tests for token budget enforcement, manifest generation, each discovery strategy (scope, claude_md, git_diff, grep)          |
| D3  | pnevma-core events tests          | `pnevma-core/src/events.rs`                 | Add tests covering event serialization, filtering, append-only invariants                                                        |
| D4  | pnevma-agents codex tests         | `pnevma-agents/src/adapters/codex.rs`       | Add tests for adapter construction and command building (mirror claude adapter tests)                                            |
| D5  | pnevma-remote integration tests   | `pnevma-remote/src/routes/*.rs`, middleware | Add tests for auth middleware, rate limiting rejection, CORS headers, WebSocket lifecycle                                        |
| D6  | pnevma-session supervisor tests   | `pnevma-session/src/supervisor.rs`          | Add tests for health state transitions, scrollback append/seek, tmux reconnect path                                              |
| D7  | pnevma-git service tests          | `pnevma-git/src/service.rs`                 | Add tests for worktree create/cleanup, branch naming, merge execution                                                            |
| D8  | Task state machine proptest       | `pnevma-core/src/task.rs`                   | Add proptest: arbitrary transition sequences never reach invalid states                                                          |
| D9  | Workflow transitions proptest     | `pnevma-core/src/workflow.rs`               | Add proptest: step ordering and terminal-state invariants under random inputs                                                    |
| D10 | Swift test expansion              | `native/PnevmaTests/`                       | Add tests for bridge FFI calls, pane state management, sidebar navigation (currently 3 test files for 40 source files)           |
| D11 | Secret redaction integration test | (new test)                                  | End-to-end: inject a secret, run through event emission + scrollback + context + review pack, assert it never appears in output  |
| D12 | ProtectedActionSheet verification | `pnevma-core/src/protected_actions.rs`      | Verify `ProtectedActionSheet.swift` enforces confirmation phrases; add `verify_confirmation()` to Rust side and call from bridge |

---

## Workstream E: Infrastructure & CI (7 items)

STANDARD priority.

| ID  | Item                              | File(s)                                      | Action                                                                                                                                                 |
| --- | --------------------------------- | -------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------ |
| E1  | Wire cargo audit to `just check`  | `justfile`                                   | Add `cargo audit` step to the `check` target                                                                                                           |
| E2  | Add `just test-all` target        | `justfile`                                   | Composite target: Rust tests + Swift tests + E2E smoke + E2E recovery                                                                                  |
| E3  | Pin GitHub Actions to commit SHAs | `.github/workflows/ci.yml`                   | Replace `actions/checkout@v4`, `actions/cache@v4`, `dtolnay/rust-toolchain@stable` with pinned SHAs                                                    |
| E4  | Add cargo-deny                    | `.github/workflows/ci.yml` + new `deny.toml` | License and duplicate dependency checking in CI                                                                                                        |
| E5  | Add secret scanning to CI         | `.github/workflows/ci.yml`                   | Add gitleaks or trufflehog step                                                                                                                        |
| E6  | Fix release-preflight.sh          | `scripts/release-preflight.sh`               | Remove/update frontend checks (`npx tsc`, `npx eslint`, `npx vite build`) that reference the deleted `frontend/` directory                             |
| E7  | unwrap() audit                    | All non-test `.rs` files                     | Review ~15 occurrences; `OnceLock`/regex init is fine, but `cors.rs:14` and `rate_limit.rs:29` should use `.expect()` with context or propagate errors |

---

## Workstream F: Hardening & Code Quality (5 items)

STANDARD priority.

| ID  | Item                                 | File(s)                                        | Action                                                                                                                                                                                                                        |
| --- | ------------------------------------ | ---------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| F1  | Concurrency safety review            | All crates using `parking_lot` / `tokio::sync` | Audit all usage; confirm no `RefCell` held across `.await`                                                                                                                                                                    |
| F2  | Path containment audit               | `pnevma-commands/src/commands/*.rs`            | `implementation-status.md` says `open_file_target` and `export_telemetry_bundle` are covered; audit for any other commands that accept user-input paths                                                                       |
| F3  | DB migration rollback scripts        | `pnevma-db/migrations/`                        | Create rollback SQL for each existing migration so a bad deploy can be reversed                                                                                                                                               |
| F4  | Condense: remaining code-level items | Various                                        | 9 remaining code condensation items from the condense audit (ContentAreaView teardown, ws.rs RpcResult helper, api.rs param-merging, TerminalHostView mouse helpers, lib.rs params parsing, release-preflight.sh dedup, etc.) |
| F5  | Code condense: already applied       | Various                                        | 4 items already applied this session: CommandBus unused decoder, AppDelegate splitRightAction dedup, tls.rs return simplification, TerminalHostView extractText helper (15 lines saved)                                       |

---

## Workstream G: E2E Validation & Manual Testing (10 items)

HIGH-ASSURANCE priority. Sequential — requires a running app instance.

| ID  | Item                               | Action                                                                                                 |
| --- | ---------------------------------- | ------------------------------------------------------------------------------------------------------ |
| G1  | Validate ipc-e2e-smoke.sh          | Run end-to-end; fix any breakage from Tauri-to-Swift migration                                         |
| G2  | Validate ipc-e2e-recovery.sh       | Run end-to-end; verify crash recovery works with native app                                            |
| G3  | Validate check-ffi-coverage.sh     | Confirm it correctly maps bridge exports to Swift call sites                                           |
| G4  | Manual latency validation          | Follow protocol in `docs/latency-validation.md` on actual hardware; record results                     |
| G5  | Activate updater production config | Replace endpoint/pubkey placeholders in config with real values (or document process)                  |
| G6  | Full sign/notarize/staple pipeline | End-to-end on a release build to confirm nothing broke in the rewrite                                  |
| G7  | Auth bypass testing                | Send requests with no token, expired token, malformed token — verify rejection                         |
| G8  | Rate limit testing                 | Burst 60+ req/min to API, 5+ to auth — verify 429 responses                                            |
| G9  | RPC allowlist testing              | Attempt blocked commands (`session.new`, `project.delete`) via `/api/rpc` — verify rejection           |
| G10 | Body/WS size testing               | POST 10 MB JSON to `/api/rpc` (verify 413 after A1); send >1 MB WS message (verify rejection after A2) |

---

## Execution Order & Dependencies

```
Phase 1 (parallel):  A1-A6  |  C1-C7  |  E1-E7
                      |
Phase 2 (parallel):  B1-B8  |  D1-D12 |  F1-F4
                      |
Phase 3 (sequential): G1-G10 (requires running app + Phase 1-2 fixes)
```

Phase 1 workstreams are fully independent.
Phase 2 starts once security blockers (A) land — B builds on the same files.
Phase 3 is manual/E2E and requires a working build with all fixes applied.

---

## Agent Team Assignment

| Agent              | Workstream(s)                          | Mode               |
| ------------------ | -------------------------------------- | ------------------ |
| `coder-security`   | A (blockers)                           | worktree isolation |
| `coder-docs`       | C (documentation)                      | worktree isolation |
| `coder-infra`      | E (CI/infrastructure)                  | worktree isolation |
| `coder-tests-1`    | D1-D4 (Rust core tests)                | worktree isolation |
| `coder-tests-2`    | D5-D7 (integration tests)              | worktree isolation |
| `coder-tests-3`    | D8-D12 (proptests + Swift + E2E tests) | worktree isolation |
| `coder-security-2` | B (high priority security)             | worktree isolation |
| `coder-hardening`  | F (hardening + condense)               | worktree isolation |
| `reviewer`         | Review all PRs before merge            | read-only          |

---

## Totals

| Category          | Items  | Estimated Files Touched |
| ----------------- | ------ | ----------------------- |
| Security Blockers | 6      | ~8                      |
| Security High     | 8      | ~10                     |
| Documentation     | 7      | ~8                      |
| Test Coverage     | 12     | ~15                     |
| Infrastructure    | 7      | ~6                      |
| Hardening         | 5      | ~12                     |
| E2E Validation    | 10     | 0 (testing only)        |
| **Total**         | **55** | **~59**                 |
