import Foundation

enum AppSmokeMode: String {
    case launch
    case ghostty

    static var current: AppSmokeMode? {
        ProcessInfo.processInfo.environment["PNEVMA_SMOKE_MODE"]
            .flatMap(AppSmokeMode.init(rawValue:))
    }
}

@MainActor
enum AppLaunchContext {
    static var isUnitTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    static var smokeMode: AppSmokeMode? {
        AppSmokeMode.current
    }

    static var isUITesting: Bool {
        ProcessInfo.processInfo.environment["PNEVMA_UI_TESTING"] == "1"
    }

    static var isTesting: Bool {
        isUITesting || isUnitTesting
    }

    static var shouldRestoreWindowsOnLaunch: Bool {
        !isTesting && AppRuntimeSettings.shared.restoreWindowsOnLaunch
    }

    static var shouldRunAutomaticUpdateChecks: Bool {
        !isTesting && AppRuntimeSettings.shared.autoUpdate
    }

    static var initialWorkspaceName: String {
        isUITesting ? "UI Test Workspace" : "Default"
    }
}
