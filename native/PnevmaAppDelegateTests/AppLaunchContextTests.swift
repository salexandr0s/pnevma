import AppKit
import XCTest
@testable import Pnevma

@MainActor
final class AppLaunchContextTests: XCTestCase {
    nonisolated(unsafe) private var launchedAppDelegates: [AppDelegate] = []

    override func setUp() {
        super.setUp()
        syncOnMainActor {
            _ = NSApplication.shared
        }
    }

    override func tearDown() {
        let delegates = launchedAppDelegates
        launchedAppDelegates.removeAll()
        syncOnMainActor {
            delegates.reversed().forEach { $0.shutdownForTesting() }
            AppRuntimeSettings.shared.apply(.defaults)
        }
        super.tearDown()
    }

    func testUnitTestLaunchDisablesRestoreAndAutomaticUpdateChecks() {
        XCTAssertTrue(AppLaunchContext.isTesting)

        AppRuntimeSettings.shared.apply(AppSettingsSnapshot(
            autoSaveWorkspaceOnQuit: true,
            restoreWindowsOnLaunch: true,
            autoUpdate: true,
            defaultShell: "",
            terminalFont: "SF Mono",
            terminalFontSize: 13,
            scrollbackLines: 10000,
            sidebarBackgroundOffset: 0.05,
            bottomToolBarAutoHide: false,
            focusBorderEnabled: true,
            focusBorderOpacity: 0.4,
            focusBorderWidth: 2.0,
            focusBorderColor: "accent",
            telemetryEnabled: false,
            crashReports: false,
            keybindings: []
        ))

        XCTAssertFalse(AppLaunchContext.shouldRestoreWindowsOnLaunch)
        XCTAssertFalse(AppLaunchContext.shouldRunAutomaticUpdateChecks)
    }

    func testAppDelegateDoesNotTerminateAfterLastWindowClosedWhileTesting() {
        let appDelegate = AppDelegate()

        XCTAssertFalse(appDelegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testLightweightTestDelegateDoesNotShutdownOwnedGhosttyAppLifecycle() throws {
        _ = launchAppDelegate()

        XCTAssertTrue(GhosttyRuntime.isProcessInitialized)
        let rendererAvailableBeforeLightweightLaunch = TerminalSurface.isRealRendererAvailable

        try withUITestLightweightEnvironment {
            let lightweightDelegate = launchAppDelegate()
            shutdownTrackedDelegate(lightweightDelegate)
        }

        XCTAssertTrue(GhosttyRuntime.isProcessInitialized)
        XCTAssertEqual(TerminalSurface.isRealRendererAvailable, rendererAvailableBeforeLightweightLaunch)
    }

    private func launchAppDelegate() -> AppDelegate {
        let appDelegate = AppDelegate()
        launchedAppDelegates.append(appDelegate)
        NSApp.delegate = appDelegate
        appDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        return appDelegate
    }

    private func shutdownTrackedDelegate(_ appDelegate: AppDelegate) {
        appDelegate.shutdownForTesting()
        launchedAppDelegates.removeAll { $0 === appDelegate }
    }

    private func withUITestLightweightEnvironment(
        _ body: () throws -> Void
    ) throws {
        let savedUITesting = ProcessInfo.processInfo.environment["PNEVMA_UI_TESTING"]
        let savedLightweight = ProcessInfo.processInfo.environment["PNEVMA_UI_TEST_LIGHTWEIGHT_MODE"]
        setenv("PNEVMA_UI_TESTING", "1", 1)
        setenv("PNEVMA_UI_TEST_LIGHTWEIGHT_MODE", "1", 1)
        defer {
            restoreEnvironmentVariable("PNEVMA_UI_TESTING", to: savedUITesting)
            restoreEnvironmentVariable("PNEVMA_UI_TEST_LIGHTWEIGHT_MODE", to: savedLightweight)
        }
        try body()
    }

    private func restoreEnvironmentVariable(_ name: String, to value: String?) {
        if let value {
            setenv(name, value, 1)
        } else {
            unsetenv(name)
        }
    }

    nonisolated private func syncOnMainActor(_ body: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated(body)
            semaphore.signal()
        }
        semaphore.wait()
    }
}
