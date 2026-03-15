import XCTest
@testable import Pnevma

@MainActor
final class AppLaunchContextTests: XCTestCase {
    override func tearDown() {
        AppRuntimeSettings.shared.apply(.defaults)
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
}
