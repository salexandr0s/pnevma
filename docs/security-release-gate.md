# Security Release Gate

## Blockers

Do not ship a remote-enabled release if any of the following are true:

- any Critical or High security finding is open
- a required quality gate failed
- notarization, stapling, `codesign`, or `spctl` verification failed
- entitlements differ from the checked-in allowlist without explicit review
- required evidence artifacts are missing
- release notes or operator docs claim unsupported updater behavior

## Required quality gates

1. `just check`
2. `cd native && swift test`
3. `just xcode-test`
4. `./scripts/release-preflight.sh`
5. `APP_PATH="native/build/Build/Products/Release/Pnevma.app" ./scripts/check-entitlements.sh`

## Required evidence bundle

Every release candidate must preserve:

- SBOM output
- entitlement check output
- effective entitlements plist
- `codesign --verify --deep --strict --verbose=2` output
- `spctl --assess --type exec --verbose=4` output
- notarization and stapling logs
- remote/manual security test results
- latency validation notes

GitHub Actions retention policy:

- CI artifacts: 30 days
- release evidence and release SBOM artifacts: 90 days

## Manual sign-off areas

- remote auth and deployment posture match `docs/security-deployment.md`
- control-plane auth mode matches intended operator guidance
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
