import XCTest
@testable import Pnevma

private actor MockVersionChecker: ReleaseVersionChecking {
    var result: Result<(version: String, url: URL), Error>
    private(set) var fetchCount = 0

    init(result: Result<(version: String, url: URL), Error>) {
        self.result = result
    }

    func fetchLatestRelease() async throws -> (version: String, url: URL) {
        fetchCount += 1
        return try result.get()
    }

    func getFetchCount() -> Int { fetchCount }

    func setResult(_ newResult: Result<(version: String, url: URL), Error>) {
        self.result = newResult
    }
}

@MainActor
final class AppUpdateCoordinatorTests: XCTestCase {
    private let releaseURL = URL(string: "https://github.com/salexandr0s/pnevma/releases/tag/v3.0.0")!
    private let defaults = UserDefaults(suiteName: "AppUpdateCoordinatorTests")!

    override func setUp() {
        super.setUp()
        let suiteName = "AppUpdateCoordinatorTests"
        MainActor.assumeIsolated {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
    }

    override func tearDown() {
        let suiteName = "AppUpdateCoordinatorTests"
        MainActor.assumeIsolated {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
            AppRuntimeSettings.shared.apply(.defaults)
        }
        super.tearDown()
    }

    private func makeCoordinator(
        checker: any ReleaseVersionChecking,
        checkInterval: TimeInterval = 0
    ) -> AppUpdateCoordinator {
        AppUpdateCoordinator(
            versionChecker: checker,
            userDefaults: defaults,
            checkInterval: checkInterval
        )
    }

    // MARK: - Automatic checks

    func testAutomaticCheckRunsWhenAutoUpdateEnabled() async throws {
        // Ensure auto_update is true
        AppRuntimeSettings.shared.apply(AppSettingsSnapshot(
            autoSaveWorkspaceOnQuit: true, restoreWindowsOnLaunch: true,
            agentTeamPresentation: AgentTeamPresentationMode.splitPanes.rawValue,
            autoUpdate: true, defaultShell: "", terminalFont: "SF Mono",
            terminalFontSize: 13, scrollbackLines: 10000,
            sidebarBackgroundOffset: 0.05, bottomToolBarAutoHide: false, focusBorderEnabled: true,
            focusBorderOpacity: 0.4, focusBorderWidth: 2.0,
            focusBorderColor: "accent", telemetryEnabled: false,
            crashReports: false, keybindings: []
        ))

        let checker = MockVersionChecker(result: .success(("99.0.0", releaseURL)))
        let coordinator = makeCoordinator(checker: checker)

        coordinator.automaticCheck()
        // Give the async task a moment
        try await Task.sleep(nanoseconds: 200_000_000)

        let count = await checker.getFetchCount()
        XCTAssertEqual(count, 1, "automatic check should fire when auto_update is true")
        if case .updateAvailable(let v, _) = coordinator.state.status {
            XCTAssertEqual(v, "99.0.0")
        } else {
            XCTFail("Expected updateAvailable, got \(coordinator.state.status)")
        }
    }

    func testAutomaticCheckSkippedWhenAutoUpdateDisabled() async throws {
        AppRuntimeSettings.shared.apply(AppSettingsSnapshot(
            autoSaveWorkspaceOnQuit: true, restoreWindowsOnLaunch: true,
            agentTeamPresentation: AgentTeamPresentationMode.splitPanes.rawValue,
            autoUpdate: false, defaultShell: "", terminalFont: "SF Mono",
            terminalFontSize: 13, scrollbackLines: 10000,
            sidebarBackgroundOffset: 0.05, bottomToolBarAutoHide: false, focusBorderEnabled: true,
            focusBorderOpacity: 0.4, focusBorderWidth: 2.0,
            focusBorderColor: "accent", telemetryEnabled: false,
            crashReports: false, keybindings: []
        ))

        let checker = MockVersionChecker(result: .success(("99.0.0", releaseURL)))
        let coordinator = makeCoordinator(checker: checker)

        coordinator.automaticCheck()
        try await Task.sleep(nanoseconds: 200_000_000)

        let count = await checker.getFetchCount()
        XCTAssertEqual(count, 0, "automatic check should NOT fire when auto_update is false")
        XCTAssertEqual(coordinator.state.status, .idle)
    }

    func testManualCheckRunsRegardlessOfAutoUpdate() async throws {
        AppRuntimeSettings.shared.apply(AppSettingsSnapshot(
            autoSaveWorkspaceOnQuit: true, restoreWindowsOnLaunch: true,
            agentTeamPresentation: AgentTeamPresentationMode.splitPanes.rawValue,
            autoUpdate: false, defaultShell: "", terminalFont: "SF Mono",
            terminalFontSize: 13, scrollbackLines: 10000,
            sidebarBackgroundOffset: 0.05, bottomToolBarAutoHide: false, focusBorderEnabled: true,
            focusBorderOpacity: 0.4, focusBorderWidth: 2.0,
            focusBorderColor: "accent", telemetryEnabled: false,
            crashReports: false, keybindings: []
        ))

        let checker = MockVersionChecker(result: .success(("99.0.0", releaseURL)))
        let coordinator = makeCoordinator(checker: checker)

        await coordinator.manualCheck()

        let count = await checker.getFetchCount()
        XCTAssertEqual(count, 1, "manual check should run even when auto_update is false")
    }

    // MARK: - Status transitions

    func testStatusTransitionToUpdateAvailable() async throws {
        let checker = MockVersionChecker(result: .success(("99.0.0", releaseURL)))
        let coordinator = makeCoordinator(checker: checker)

        XCTAssertEqual(coordinator.state.status, .idle)

        await coordinator.manualCheck()

        if case .updateAvailable(let v, _) = coordinator.state.status {
            XCTAssertEqual(v, "99.0.0")
        } else {
            XCTFail("Expected updateAvailable")
        }
    }

    func testStatusTransitionToUpToDate() async throws {
        // Return a version equal to the current bundle version
        let currentVersion = AppVersionInfo.current.shortVersion
        let checker = MockVersionChecker(result: .success((currentVersion, releaseURL)))
        let coordinator = makeCoordinator(checker: checker)

        await coordinator.manualCheck()
        XCTAssertEqual(coordinator.state.status, .upToDate)
    }

    func testStatusTransitionToFailed() async throws {
        let checker = MockVersionChecker(result: .failure(URLError(.notConnectedToInternet)))
        let coordinator = makeCoordinator(checker: checker)

        await coordinator.manualCheck()

        if case .failed = coordinator.state.status {
            // good
        } else {
            XCTFail("Expected failed status")
        }
    }

    // MARK: - Persistence

    func testLastCheckAtPersistedAfterCheck() async throws {
        let checker = MockVersionChecker(result: .success(("1.0.0", releaseURL)))
        let coordinator = makeCoordinator(checker: checker)

        XCTAssertNil(coordinator.state.lastCheckAt)
        await coordinator.manualCheck()
        XCTAssertNotNil(coordinator.state.lastCheckAt)
        XCTAssertNotNil(defaults.object(forKey: "AppUpdateCoordinator.lastCheckAt"))
    }

    // MARK: - Cooldown

    func testAutomaticCheckRespectsInterval() async throws {
        AppRuntimeSettings.shared.apply(AppSettingsSnapshot(
            autoSaveWorkspaceOnQuit: true, restoreWindowsOnLaunch: true,
            agentTeamPresentation: AgentTeamPresentationMode.splitPanes.rawValue,
            autoUpdate: true, defaultShell: "", terminalFont: "SF Mono",
            terminalFontSize: 13, scrollbackLines: 10000,
            sidebarBackgroundOffset: 0.05, bottomToolBarAutoHide: false, focusBorderEnabled: true,
            focusBorderOpacity: 0.4, focusBorderWidth: 2.0,
            focusBorderColor: "accent", telemetryEnabled: false,
            crashReports: false, keybindings: []
        ))

        let checker = MockVersionChecker(result: .success(("1.0.0", releaseURL)))
        // Use a very large interval so the second check should be skipped
        let coordinator = makeCoordinator(checker: checker, checkInterval: 999_999)

        // First check: should run
        coordinator.automaticCheck()
        try await Task.sleep(nanoseconds: 200_000_000)
        let firstCount = await checker.getFetchCount()
        XCTAssertEqual(firstCount, 1)

        // Second check: should be skipped due to interval
        coordinator.automaticCheck()
        try await Task.sleep(nanoseconds: 200_000_000)
        let secondCount = await checker.getFetchCount()
        XCTAssertEqual(secondCount, 1, "automatic check should respect cooldown interval")
    }

    // MARK: - Semantic version comparison

    func testSemanticVersionComparison() {
        XCTAssertTrue(SemanticVersion.isNewer(remote: "2.1.0", than: "2.0.0"))
        XCTAssertTrue(SemanticVersion.isNewer(remote: "3.0.0", than: "2.9.9"))
        XCTAssertTrue(SemanticVersion.isNewer(remote: "2.0.1", than: "2.0.0"))
        XCTAssertFalse(SemanticVersion.isNewer(remote: "2.0.0", than: "2.0.0"))
        XCTAssertFalse(SemanticVersion.isNewer(remote: "1.9.9", than: "2.0.0"))
        XCTAssertTrue(SemanticVersion.isNewer(remote: "2.0.0.1", than: "2.0.0"))
        XCTAssertFalse(SemanticVersion.isNewer(remote: "2.0", than: "2.0.0"))
    }
}
