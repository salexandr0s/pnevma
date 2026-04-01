# Security Release Gate

For the first public `v0.2.0` DMG, notarization and stapling are explicitly
deferred. They remain the target follow-up path, but they are not blocking
conditions for this signed-only release cut.

## Blockers

Do not ship a remote-enabled release if any of the following are true:

- any Critical or High security finding is open
- a required quality gate failed
- app or DMG `codesign` verification failed
- entitlements differ from the checked-in allowlist without explicit review
- required evidence artifacts are missing
- the documented clean-machine Finder `Open` / `Open Anyway` flow has not been validated on the actual candidate DMG
- release notes or operator docs claim unsupported updater behavior

## Required quality gates

1. `just check`
2. `cd native && swift test`
3. `just xcode-test`
4. `./scripts/release-preflight.sh`
5. `APP_PATH="native/build/Release/Pnevma.app" ./scripts/check-entitlements.sh` on the packaged candidate bundle

For security-sensitive changes touching redaction or remote auth, the release candidate must also preserve passing coverage for:

- provider-token and env-assignment redaction in `pnevma-session`, `pnevma-commands`, and `pnevma-context`
- persisted scrollback redaction regressions
- remote auth token issuance/use/revocation audit-context tests in `pnevma-remote`

## Required evidence bundle

Every release candidate must preserve:

- SBOM output
- entitlement check output
- effective entitlements plist
- `codesign --verify --deep --strict --verbose=2` output
- app `spctl --assess --type execute --verbose=4` output
- DMG `spctl --assess --type open --verbose=4` output
- packaged launch smoke output from the candidate artifact
- CI green-run report for the required `main` lanes
- clean-machine install notes showing the documented first-launch flow
- remote/manual security test results
- latency validation notes

Optional for the deferred notarized follow-up path:

- notarization logs
- stapling logs

GitHub Actions retention policy:

- CI artifacts: 30 days
- release evidence and release SBOM artifacts: 90 days

## Manual sign-off areas

- remote auth and deployment posture match `docs/security-deployment.md`
- control-plane auth mode matches intended operator guidance
- provider-token redaction is manually verified in live session output, persisted scrollback/timeline, and remote-visible output
- operator-facing docs still state that worktrees are not an OS sandbox and agents retain user-level filesystem/network access
- long-running dispatch, review, replay, and recovery flows behave correctly on the candidate build
- release documentation matches the shipped architecture

## Exceptions

Medium findings may ship only with a written exception that includes:

- owner
- scope
- compensating control
- expiry date
- explicit retest condition

Low findings may be deferred only if they do not weaken auth, secret handling, or release integrity.
