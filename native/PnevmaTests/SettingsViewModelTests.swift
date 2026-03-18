import XCTest
@testable import Pnevma

actor SettingsCommandBusStub: CommandCalling {
    enum StubError: Error {
        case loadFailed
    }

    var getResult: Result<AppSettingsSnapshot, Error>
    private(set) var setRequests: [AppSettingsSaveRequest] = []
    private var setContinuations: [CheckedContinuation<AppSettingsSnapshot, Error>] = []

    init(getResult: Result<AppSettingsSnapshot, Error>) {
        self.getResult = getResult
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "settings.app.get":
            return try cast(getResult.get())
        case "settings.app.set":
            guard let request = params as? AppSettingsSaveRequest else {
                throw StubError.loadFailed
            }
            setRequests.append(request)
            let snapshot: AppSettingsSnapshot = try await withCheckedThrowingContinuation { continuation in
                setContinuations.append(continuation)
            }
            return try cast(snapshot)
        default:
            throw StubError.loadFailed
        }
    }

    func setRequestCount() -> Int {
        setRequests.count
    }

    func request(at index: Int) -> AppSettingsSaveRequest {
        setRequests[index]
    }

    func completeSet(at index: Int, with snapshot: AppSettingsSnapshot) {
        setContinuations[index].resume(returning: snapshot)
    }

    private func cast<T: Decodable>(_ value: AppSettingsSnapshot) throws -> T {
        guard let typed = value as? T else {
            throw StubError.loadFailed
        }
        return typed
    }
}

@MainActor
final class SettingsViewModelTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            AppRuntimeSettings.shared.apply(.defaults)
        }
        super.tearDown()
    }

    private func waitUntil(
        timeoutNanos: UInt64 = 1_000_000_000,
        pollIntervalNanos: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        XCTFail("Timed out waiting for settings condition", file: file, line: line)
    }

    private func makeSnapshot(
        defaultShell: String = "",
        telemetryEnabled: Bool = false
    ) -> AppSettingsSnapshot {
        AppSettingsSnapshot(
            autoSaveWorkspaceOnQuit: true,
            restoreWindowsOnLaunch: true,
            autoUpdate: true,
            defaultShell: defaultShell,
            terminalFont: "SF Mono",
            terminalFontSize: 13,
            scrollbackLines: 10_000,
            sidebarBackgroundOffset: 0.05,
            bottomToolBarAutoHide: false,
            focusBorderEnabled: true,
            focusBorderOpacity: 0.4,
            focusBorderWidth: 2.0,
            focusBorderColor: "accent",
            telemetryEnabled: telemetryEnabled,
            crashReports: false,
            keybindings: [KeybindingEntry(action: "New Tab", shortcut: "Cmd+T")]
        )
    }

    func testLoadFailurePreventsDefaultOverwriteSaves() async throws {
        let bus = SettingsCommandBusStub(getResult: .failure(SettingsCommandBusStub.StubError.loadFailed))
        let viewModel = SettingsViewModel(commandBus: bus)

        viewModel.load()
        try await Task.sleep(nanoseconds: 100_000_000)

        viewModel.autoUpdate = false
        try await Task.sleep(nanoseconds: 500_000_000)

        let saveCount = await bus.setRequestCount()
        XCTAssertEqual(saveCount, 0, "save should stay disabled until backend load succeeds")
    }

    func testLoadUpdatesSharedRuntimeSettings() async throws {
        let bus = SettingsCommandBusStub(getResult: .success(makeSnapshot(defaultShell: "/bin/bash")))
        let viewModel = SettingsViewModel(commandBus: bus)

        viewModel.load()

        try await waitUntil { AppRuntimeSettings.shared.normalizedDefaultShell == "/bin/bash" }
        XCTAssertEqual(AppRuntimeSettings.shared.normalizedDefaultShell, "/bin/bash")
    }

    func testOlderSaveResponseCannotOverwriteNewerEdit() async throws {
        let bus = SettingsCommandBusStub(getResult: .success(makeSnapshot()))
        let viewModel = SettingsViewModel(commandBus: bus)

        viewModel.load()
        try await Task.sleep(nanoseconds: 100_000_000)

        viewModel.defaultShell = "/bin/zsh"
        try await waitUntil { await bus.setRequestCount() == 1 }
        let firstSaveCount = await bus.setRequestCount()
        let firstRequest = await bus.request(at: 0)
        XCTAssertEqual(firstSaveCount, 1)
        XCTAssertEqual(firstRequest.defaultShell, "/bin/zsh")

        viewModel.defaultShell = "/bin/bash"
        try await waitUntil { await bus.setRequestCount() == 2 }
        let secondSaveCount = await bus.setRequestCount()
        let secondRequest = await bus.request(at: 1)
        XCTAssertEqual(secondSaveCount, 2)
        XCTAssertEqual(secondRequest.defaultShell, "/bin/bash")

        await bus.completeSet(at: 1, with: makeSnapshot(defaultShell: "/bin/bash"))
        try await waitUntil { viewModel.defaultShell == "/bin/bash" }
        XCTAssertEqual(viewModel.defaultShell, "/bin/bash")

        await bus.completeSet(at: 0, with: makeSnapshot(defaultShell: "/bin/zsh"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(viewModel.defaultShell, "/bin/bash", "stale save response must be ignored")
    }

    func testSuccessfulSaveUpdatesSharedRuntimeSettings() async throws {
        let bus = SettingsCommandBusStub(getResult: .success(makeSnapshot()))
        let viewModel = SettingsViewModel(commandBus: bus)

        viewModel.load()
        try await Task.sleep(nanoseconds: 100_000_000)

        viewModel.defaultShell = "/bin/bash"
        try await waitUntil { await bus.setRequestCount() == 1 }
        await bus.completeSet(at: 0, with: makeSnapshot(defaultShell: "/bin/bash"))

        try await waitUntil { AppRuntimeSettings.shared.normalizedDefaultShell == "/bin/bash" }
        XCTAssertEqual(AppRuntimeSettings.shared.normalizedDefaultShell, "/bin/bash")
    }

    func testSuccessfulSaveUpdatesDockAutoHideRuntimeSetting() async throws {
        let bus = SettingsCommandBusStub(getResult: .success(makeSnapshot()))
        let viewModel = SettingsViewModel(commandBus: bus)

        viewModel.load()
        try await Task.sleep(nanoseconds: 100_000_000)

        viewModel.bottomToolBarAutoHide = true
        try await waitUntil { await bus.setRequestCount() == 1 }
        let savedRequest = await bus.request(at: 0)
        XCTAssertTrue(savedRequest.bottomToolBarAutoHide)

        await bus.completeSet(
            at: 0,
            with: AppSettingsSnapshot(
                autoSaveWorkspaceOnQuit: true,
                restoreWindowsOnLaunch: true,
                autoUpdate: true,
                defaultShell: "",
                terminalFont: "SF Mono",
                terminalFontSize: 13,
                scrollbackLines: 10_000,
                sidebarBackgroundOffset: 0.05,
                bottomToolBarAutoHide: true,
                focusBorderEnabled: true,
                focusBorderOpacity: 0.4,
                focusBorderWidth: 2.0,
                focusBorderColor: "accent",
                telemetryEnabled: false,
                crashReports: false,
                keybindings: [KeybindingEntry(action: "New Tab", shortcut: "Cmd+T")]
            )
        )

        try await waitUntil { AppRuntimeSettings.shared.bottomToolBarAutoHide }
        XCTAssertTrue(AppRuntimeSettings.shared.bottomToolBarAutoHide)
    }
}
