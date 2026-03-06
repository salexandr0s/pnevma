# macOS Website Release Plan

This document is the execution plan for shipping Pnevma as a downloadable macOS app from the Pnevma website using Apple's supported distribution path: `Developer ID` signing, hardened runtime, notarization, stapling, and normal Gatekeeper launch.

It is intentionally narrower than the broader product roadmap. This plan is about one thing: getting from the current native app state to a public website release that installs cleanly on a user's Mac without bypass instructions.

## Goal

Ship a public Pnevma macOS release that:

- is downloaded from the Pnevma website rather than the Mac App Store,
- is signed with a `Developer ID Application` certificate,
- is notarized and stapled,
- passes `codesign`, `spctl`, and launch smoke verification,
- launches on a clean Mac without `Open Anyway`, right-click workarounds, or quarantine removal instructions,
- has a repeatable CI-backed release process with preserved evidence.

## Non-goals

This plan does not include:

- Mac App Store submission,
- App Sandbox migration unless independently justified,
- native auto-updater support,
- Windows or Linux distribution,
- feature work unrelated to release hardening.

## Current Baseline

Pnevma already has significant release infrastructure in place:

- hardened runtime enabled in `native/project.yml`,
- a checked-in entitlement allowlist in `native/Pnevma/Pnevma.entitlements`,
- a local signing/notarization runbook in `docs/macos-release.md`,
- a release preflight script in `scripts/release-preflight.sh`,
- release and release-rehearsal workflows in `.github/workflows/`.

Current known gaps:

- the remaining hardened-runtime exception is `com.apple.security.cs.disable-library-validation`; it still needs periodic revalidation against signed release builds,
- the published artifact shape is currently `tar.gz`, which is not the intended final website UX,
- versioning is inconsistent between the Rust workspace and the app bundle,
- the clean-machine website download flow has not yet been validated as a formal release gate,
- rehearsal lanes must be green and stable on `main`.

## Release Principles

- Release hardening takes precedence over feature work until the hardening exit bar is met.
- Every exception in the hardened runtime profile must be justified by observed runtime behavior.
- The final user download should be the same artifact that is tested, signed, notarized, stapled, and published.
- Warnings in signing, notarization, or Gatekeeper validation are treated as blockers until explained and resolved.
- A release is not complete until it succeeds on a clean machine outside the dev environment.

## Support Matrix Decision

The first release must explicitly choose one support target:

### Recommended first release

- architecture: `Apple Silicon (arm64)`
- operating system: `macOS 14.0+`

### Deferred option

- universal binary support (`arm64` + `x86_64`)

Recommendation:

Ship `arm64` first. The repository and current build scripts are already optimized around `aarch64-apple-darwin`, and expanding to universal binaries increases scope across Rust targets, Ghostty artifacts, CI runtime, packaging, and test coverage.

## Phase Plan

### Phase 0: Freeze and scope lock

Objective:

Stop mixing release hardening with unrelated product work.

Tasks:

- declare a release-hardening freeze,
- allow only bug fixes, tests, CI/build hardening, release hardening, and Ghostty/runtime verification changes,
- defer unrelated feature work until release hardening exits,
- treat `docs/hardening-exit-criteria.md` as the controlling policy.

Exit criteria:

- the active branch or milestone is explicitly labeled as release hardening,
- the team agrees that unrelated features do not merge during this period.

### Phase 1: Identity and release metadata

Objective:

Make versioning and product identity internally consistent across the bundle, repository, and public release artifacts.

Tasks:

- choose the first public version number,
- align `Cargo.toml` workspace version with the app release versioning approach,
- align `CFBundleShortVersionString`,
- align `CFBundleVersion` with a monotonically increasing build number or release build sequence,
- verify bundle identifier, app name, copyright, minimum OS, and icon asset,
- decide the canonical public product name and release title format.

Checks:

- Rust workspace version matches the intended release train,
- app bundle metadata matches the release notes and website download page,
- tags, release names, and bundle metadata no longer disagree.

Exit criteria:

- one documented versioning policy exists,
- the next RC can be tagged without any metadata ambiguity.

### Phase 2: Apple credentials and operator setup

Objective:

Set up the real Apple distribution prerequisites on both maintainer machines and CI.

Tasks:

- enroll in the Apple Developer Program if not already enrolled,
- create or confirm access to a `Developer ID Application` certificate,
- store notarization credentials using `xcrun notarytool store-credentials`,
- validate that the certificate can be imported and used non-interactively,
- configure GitHub Actions secrets for:
  - `APPLE_CERTIFICATE`
  - `APPLE_CERTIFICATE_PASSWORD`
  - `APPLE_SIGNING_IDENTITY`
  - `APPLE_NOTARY_PROFILE`
  - `KEYCHAIN_PASSWORD`
- verify at least one maintainer machine can run the full sign and notarize flow locally.

Checks:

- local signing succeeds,
- local notarization succeeds,
- CI can import the certificate into a temporary keychain,
- the signing identity string used in scripts exactly matches the installed certificate.

Exit criteria:

- local and CI environments can both complete signing and notarization without manual UI interaction.

### Phase 3: Hardened runtime minimization

Objective:

Reduce the current hardened-runtime exception set to the smallest set that still permits correct runtime behavior.

Tasks:

- test Ghostty-linked release builds with `com.apple.security.cs.disable-library-validation` removed,
- record that `com.apple.security.cs.allow-unsigned-executable-memory` and `com.apple.security.cs.allow-jit` are no longer required by the checked-in allowlist,
- record which entitlement removals fail and exactly how they fail,
- update the checked-in allowlist only after a concrete runtime justification exists for each remaining entitlement,
- update `scripts/check-entitlements.sh` to enforce the final minimized set.

Test matrix:

- launch app normally,
- create a terminal session,
- exercise interactive input,
- run long output streams,
- verify session persistence and restore,
- verify side-by-side pane rendering,
- verify packaged launch smoke,
- verify `codesign` and `spctl` on the final signed build.

Evidence to record for each retained entitlement:

- entitlement name,
- runtime dependency requiring it,
- observed failure mode when removed,
- test command or smoke procedure that reproduces the failure.

Exit criteria:

- the entitlement list is minimized,
- every remaining entitlement has a written justification,
- effective entitlements match the checked-in policy on signed release builds.

### Phase 4: Artifact and packaging finalization

Objective:

Replace the current rehearsal artifact shape with a public-facing website artifact that matches Apple's supported distribution workflow and gives users a normal install experience.

Preferred public artifact:

- stapled `.dmg`

Acceptable fallback:

- post-staple ZIP containing the stapled `.app`

Tasks:

- stop treating `tar.gz` as the final public artifact,
- choose `.dmg` or ZIP as the initial website distribution format,
- ensure the published artifact is created after signing, notarization, and stapling,
- verify the artifact preserves bundle integrity after download and extraction,
- update the release workflow to publish the same artifact that was validated during rehearsal,
- preserve a checksum alongside the published artifact.

Checks:

- downloaded artifact extracts or mounts without damaging code signature state,
- stapled ticket remains valid on the final distributed artifact,
- the same packaged artifact passes the launch smoke flow after publication-stage packaging.

Exit criteria:

- the final website artifact is no longer `tar.gz`,
- the published artifact is exactly the tested artifact type used in release automation.

### Phase 5: CI stabilization and release rehearsal

Objective:

Make the release path routine rather than hopeful.

Tasks:

- merge the release-rehearsal workflow to the default branch,
- ensure `main` runs:
  - Rust quality gates,
  - SwiftPM tests,
  - native release build,
  - entitlement checks,
  - packaged launch smoke,
  - sign/notarize dry run where secrets are available,
- ensure artifacts and evidence are uploaded and retained,
- investigate every red or flaky rehearsal run until the lane is stable,
- enforce warning-free native build and test gates.

Required quality gates:

- `just check`
- `cd native && swift test`
- `just xcode-test`
- `./scripts/release-preflight.sh`
- `APP_PATH="native/build/Build/Products/Release/Pnevma.app" ./scripts/check-entitlements.sh`

Stability target:

- at least 10 consecutive green runs across native and release-rehearsal lanes on `main`.

Exit criteria:

- the release rehearsal lane is stable,
- release evidence artifacts are generated automatically,
- the release path does not rely on one-off local fixes.

### Phase 6: Candidate validation on clean machines

Objective:

Validate the actual user experience, not just the developer build environment.

Tasks:

- test a release candidate on at least one clean Apple Silicon machine or fresh user account,
- download the app from the staging or production website,
- mount or extract the published artifact,
- move the app into `/Applications` if that is the documented flow,
- launch by double-clicking,
- validate first launch, reopen, terminal rendering, session creation, long session output, restore behavior, and expected permissions prompts,
- validate remote/auth posture if remote functionality is enabled in the candidate release.

Explicit failures:

- Gatekeeper warns that the app cannot be opened because the developer cannot be verified,
- the user must right-click and choose `Open`,
- the user must remove quarantine manually,
- first launch crashes,
- signature or notarization validation regresses after download packaging,
- terminal rendering or interactive input fails in the packaged build.

Exit criteria:

- the website-delivered artifact launches normally on a clean machine with no bypass steps,
- the candidate build passes real-user install flow verification.

### Phase 7: Public release execution

Objective:

Run the GA release using the same path already proven during rehearsal.

Tasks:

- create a release candidate tag,
- run the full release workflow,
- review release evidence,
- perform one final clean-machine validation on the RC,
- publish the website artifact, checksum, and release notes,
- promote the RC to GA if no blocking issues are found.

Release evidence bundle must include:

- SBOM output,
- entitlement check output,
- effective entitlements plist,
- `codesign --verify --deep --strict --verbose=2` output,
- `spctl --assess --type exec --verbose=4` output,
- notarization logs,
- stapling logs,
- packaged launch smoke logs,
- remote/manual security test results,
- latency validation notes.

Exit criteria:

- the GA release artifact is published,
- website content and GitHub release assets are consistent,
- rollback assets remain available.

## Go/No-Go Checklist

Do not ship if any of the following are true:

- any required quality gate failed,
- `codesign`, notarization, stapling, or `spctl` verification failed,
- entitlements differ from the checked-in allowlist without explicit review,
- the final artifact format differs from the tested artifact format,
- the clean-machine install path has not been validated,
- release notes or website copy mention unsupported updater behavior,
- Critical or High security findings remain open for the shipped configuration,
- version numbers differ across bundle metadata, release notes, tags, or website copy.

Release is go only if:

- the hardening exit bar is met,
- the release gate passes,
- clean-machine validation passes,
- release evidence is preserved,
- rollback assets are prepared and published privately before GA.

## Rollback Plan

If a public release fails after publication:

1. remove or replace the website download link immediately,
2. restore the previous known-good notarized release as the current download,
3. mark the failed release as withdrawn in release notes,
4. preserve all evidence artifacts and crash or verification logs,
5. identify whether the failure was caused by packaging, signing, notarization, Gatekeeper, launch behavior, or runtime behavior,
6. cut a new RC rather than patching the failed public artifact in place.

If Apple credentials are compromised:

1. revoke the affected certificate,
2. issue replacement credentials,
3. rotate CI secrets,
4. rebuild from a clean tag,
5. publish a new release signed with the replacement identity.

## Monitoring Plan

Track these signals for every RC and GA:

- GitHub Actions build, rehearsal, and release workflow status,
- notarization acceptance and log output,
- `codesign` verification output,
- `spctl` assessment output,
- packaged launch smoke logs,
- first-launch crash reports,
- user reports of Gatekeeper failures or launch denial,
- reports of terminal rendering regressions in packaged builds,
- reports of session restore regressions in packaged builds.

Thresholds:

- one reproducible clean-machine Gatekeeper failure blocks release,
- one reproducible first-launch crash blocks release,
- any notarization rejection blocks release,
- any unexplained hardened-runtime warning blocks release,
- any packaging step that changes post-staple launch behavior blocks release.

Primary places to inspect:

- GitHub Actions artifacts,
- local release evidence bundle,
- macOS Console and crash reports on clean-machine tests,
- notary logs from `notarytool`.

## Communications Checklist

Before GA:

- document supported OS and architecture,
- document install steps,
- document whether the app should be moved into `/Applications`,
- document that the app is notarized and downloaded from the official Pnevma site,
- document that auto-update is not currently supported,
- prepare release notes describing known limitations and support matrix,
- prepare internal operator notes for reproducing the release.

After GA:

- publish release notes on the website and GitHub,
- publish checksum values,
- record the final evidence bundle location,
- note the exact tag, bundle version, and artifact filename shipped.

## Day-2 Follow-up

After the first website release:

- evaluate whether universal binaries are worth adding,
- evaluate whether any remaining hardened-runtime exceptions can be removed,
- evaluate whether the website artifact should move from ZIP to `.dmg` or vice versa based on support burden,
- add release metrics and issue categorization for install and launch failures,
- define a supported updater strategy only after it is implemented and hardened,
- review whether bundle metadata and docs should be generated from a single release manifest.

## Immediate Next Actions

Recommended next seven work items:

1. decide the first public support matrix (`arm64` only vs universal),
2. unify app and workspace versioning,
3. verify Apple signing and notarization credentials locally,
4. install the same secrets in GitHub Actions,
5. minimize the Ghostty-related entitlement set,
6. replace `tar.gz` with a stapled `.dmg` or post-staple ZIP in the release path,
7. run one full release candidate through clean-machine testing.

## Source Documents

This plan should be executed alongside:

- `docs/macos-release.md`
- `docs/security-release-gate.md`
- `docs/hardening-exit-criteria.md`
- `.github/workflows/release.yml`
- `.github/workflows/release-rehearsal.yml`
- `scripts/release-preflight.sh`
- `scripts/check-entitlements.sh`
