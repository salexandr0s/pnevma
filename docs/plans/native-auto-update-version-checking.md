# Native Auto-Update and Version Checking Plan

## Summary

Implement a native `AppUpdateCoordinator` in Swift that performs real version
checks against `https://api.github.com/repos/salexandr0s/pnevma/releases/latest`,
honors the existing backend-persisted `auto_update` setting, and adds a manual
`Check for Updates...` app-menu action that works even when automatic checks
are disabled.

This slice ships real version checking now and a clean manual update handoff,
but not full in-app self-install. That is the correct fit for the current repo
because the checked-in release docs explicitly say there is no supported native
updater yet, the legacy updater scripts are deprecated, and there is no
existing Sparkle/appcast integration or hosted feed to complete a safe
self-update path. Keep the implementation Sparkle-ready by isolating update
logic behind protocols, but do not add Sparkle in this task.

## Implementation Changes

### Native update service

- Add a new Swift service under `native/Pnevma/Core/` with:
  - `AppVersionInfo`: current bundle short version, current build, release page
    URL.
  - `AppUpdateStatus`: `idle`, `checking`, `updateAvailable`, `upToDate`,
    `failed`.
  - `AppUpdateState`: status, `lastCheckAt`, latest release version string,
    current version, and current build.
  - `ReleaseVersionChecking` protocol for the network fetch/parse seam.
  - `GitHubReleaseVersionChecker` implementation using `URLSession` and
    `JSONDecoder`.
- Parse GitHub's latest-release response, read `tag_name` and `html_url`, trim
  an optional leading `v`, and compare against `CFBundleShortVersionString`.
- Use semantic-version comparison for release versions; use `CFBundleVersion`
  only for reporting the current build, not for remote comparison.
- Persist `lastCheckAt` and the last known update state in `UserDefaults`. This
  is runtime metadata, not a backend setting.
- Automatic checks run only when `AppRuntimeSettings.shared.autoUpdate` is
  `true`, and only if the last check is older than 24 hours.
- Manual checks always bypass the `auto_update` gate and the 24-hour cooldown.

### Runtime wiring and menu integration

- Extend `AppRuntimeSettings` with an `autoUpdate` accessor so runtime
  consumers do not reach into the snapshot directly.
- In `AppDelegate`:
  - create and retain a single `AppUpdateCoordinator`,
  - initialize it after settings load completes,
  - react to `.appRuntimeSettingsDidChange` so toggling `auto_update`
    immediately enables or disables automatic checks,
  - trigger the automatic check on launch only when allowed,
  - add `Check for Updates...` to the app menu.
- Manual menu behavior:
  - set state to `checking`,
  - perform a check,
  - if an update is available, present a native alert and open the GitHub
    release page in the default browser,
  - if up to date, show a native "You're up to date" alert,
  - if the check fails, show a native failure alert.
- Automatic checks remain non-modal:
  - they update coordinator state,
  - they do not open the browser or show blocking alerts,
  - menu and settings surfaces reflect the result.

### Settings UI and feedback

- Replace the current placeholder copy in `SettingsPane.swift` with live
  updater state from the coordinator:
  - current version and build,
  - latest available release version when known,
  - last check time,
  - current status: `idle`, `checking`, `update available`, `up to date`,
    `failed`.
- Keep `auto_update` ownership unchanged:
  - Rust backend persists the setting via existing `settings.app.get` and
    `settings.app.set`,
  - Swift runtime consumes that setting,
  - `crash_reports_opt_in` remains untouched and persistence-only.
- No Rust command schema changes are required for this slice.

### Docs and release posture

- Update the native and release docs to say:
  - real version checking exists,
  - automatic checks are controlled by `auto_update`,
  - manual update handoff is available from the app menu,
  - full in-app self-update is still blocked pending packaged-release
    decisions such as hosted feed/appcast and security gate updates.
- Do not change signing or notarization scripts unless implementation reveals a
  harmless metadata hook is needed.

## Public Interfaces and Types

- No changes to Rust command names or payloads.
- New Swift-only interfaces and types:
  - `ReleaseVersionChecking`
  - `AppUpdateCoordinator`
  - `AppUpdateState`
  - `AppUpdateStatus`
  - `AppVersionInfo`
- New native menu action selector for manual update checks.

## Test Plan

- Add `native/PnevmaTests/AppUpdateCoordinatorTests.swift` covering:
  - automatic check runs when `auto_update = true` and last check is older than
    24 hours,
  - no automatic check runs when `auto_update = false`,
  - manual check runs regardless of `auto_update`,
  - status transitions: `idle -> checking -> updateAvailable|upToDate|failed`,
  - persisted `lastCheckAt` is updated after completed checks,
  - automatic checks do not trigger modal or manual handoff behavior.
- Extend `native/PnevmaTests/SettingsViewModelTests.swift` only as needed to
  confirm existing settings load and save behavior remains intact with the
  runtime observer changes.
- Rerun:
  - `cargo fmt --all`
  - `cargo test -p pnevma-core -p pnevma-commands`
  - `cd native && swift build`
  - targeted Swift tests for updater behavior
  - `cd native && swift test --filter SettingsViewModelTests`

## Assumptions and Defaults

- Canonical release source for this slice is `salexandr0s/pnevma`.
- Release tags are stable semantic versions such as `2.0.1` or `v2.0.1`;
  prerelease and beta channels are out of scope.
- Automatic checking cadence is once per 24 hours when enabled.
- Full self-update is intentionally deferred because the repo currently lacks a
  supported native updater path, hosted feed/appcast, and matching
  release-security documentation; this task stops at real version checking plus
  manual update handoff.
- `native/Package.swift` remains aligned because this slice adds no Sparkle
  dependency; SwiftPM verification can fully exercise the chosen path.
