import AppKit
import XCTest
@testable import Pnevma

private let sidebarModeDefaultsKey = "sidebarMode"
@MainActor private var savedSidebarModeValue: Any?

@MainActor
final class AppDelegateSidebarTransitionTests: XCTestCase {
    nonisolated(unsafe) private var launchedAppDelegate: AppDelegate?

    override func setUp() {
        super.setUp()
        syncOnMainActor {
            _ = NSApplication.shared
            savedSidebarModeValue = UserDefaults.standard.object(forKey: sidebarModeDefaultsKey)
            UserDefaults.standard.set(SidebarMode.expanded.rawValue, forKey: sidebarModeDefaultsKey)
        }
    }

    override func tearDown() {
        let launchedAppDelegate = launchedAppDelegate
        self.launchedAppDelegate = nil
        syncOnMainActor {
            launchedAppDelegate?.shutdownForTesting()
            if let savedSidebarModeValue {
                UserDefaults.standard.set(savedSidebarModeValue, forKey: sidebarModeDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: sidebarModeDefaultsKey)
            }
        }
        super.tearDown()
    }

    func testSidebarToggleCyclesExpandedCollapsedHiddenAndBackToExpanded() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }

            waitForSidebar(
                in: appDelegate,
                expectedMode: .expanded,
                expectedWidth: SidebarPreferences.sidebarWidth,
                hostHidden: false,
                expandedHidden: false,
                railHidden: true
            )

            toggleSidebar(on: appDelegate)
            waitForSidebar(
                in: appDelegate,
                expectedMode: .collapsed,
                expectedWidth: DesignTokens.Layout.sidebarCollapsedWidth,
                hostHidden: false,
                expandedHidden: true,
                railHidden: false
            )

            toggleSidebar(on: appDelegate)
            waitForSidebar(
                in: appDelegate,
                expectedMode: .hidden,
                expectedWidth: 0,
                hostHidden: true,
                expandedHidden: true,
                railHidden: false
            )

            toggleSidebar(on: appDelegate)
            waitForSidebar(
                in: appDelegate,
                expectedMode: .expanded,
                expectedWidth: SidebarPreferences.sidebarWidth,
                hostHidden: false,
                expandedHidden: false,
                railHidden: true
            )

            toggleSidebar(on: appDelegate)
            waitForSidebar(
                in: appDelegate,
                expectedMode: .collapsed,
                expectedWidth: DesignTokens.Layout.sidebarCollapsedWidth,
                hostHidden: false,
                expandedHidden: true,
                railHidden: false
            )

            toggleSidebar(on: appDelegate)
            waitForSidebar(
                in: appDelegate,
                expectedMode: .hidden,
                expectedWidth: 0,
                hostHidden: true,
                expandedHidden: true,
                railHidden: false
            )

            toggleSidebar(on: appDelegate)
            waitForSidebar(
                in: appDelegate,
                expectedMode: .expanded,
                expectedWidth: SidebarPreferences.sidebarWidth,
                hostHidden: false,
                expandedHidden: false,
                railHidden: true
            )
        }
    }

    private func launchAppDelegate() -> AppDelegate {
        let appDelegate = AppDelegate()
        launchedAppDelegate = appDelegate
        NSApp.delegate = appDelegate
        appDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        return appDelegate
    }

    private func waitForSidebar(
        in appDelegate: AppDelegate,
        expectedMode: SidebarMode,
        expectedWidth: CGFloat,
        hostHidden: Bool,
        expandedHidden: Bool,
        railHidden: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitUntil(file: file, line: line) {
            guard let currentMode = self.currentSidebarMode(from: appDelegate),
                  let renderedMode = self.renderedSidebarMode(from: appDelegate),
                  let widthConstraint = self.sidebarWidthConstraint(from: appDelegate),
                  let hostView = self.sidebarHostView(from: appDelegate),
                  let expandedView = self.sidebarContentView(from: appDelegate),
                  let railView = self.collapsedRailHostView(from: appDelegate) else {
                return false
            }

            return currentMode == expectedMode
                && renderedMode == expectedMode
                && abs(widthConstraint.constant - expectedWidth) < 0.5
                && hostView.isHidden == hostHidden
                && expandedView.isHidden == expandedHidden
                && railView.isHidden == railHidden
        }
    }

    private func toggleSidebar(on appDelegate: AppDelegate) {
        _ = appDelegate.perform(NSSelectorFromString("toggleSidebar"))
    }

    private func currentSidebarMode(from appDelegate: AppDelegate) -> SidebarMode? {
        reflectedValue(named: "currentSidebarMode", from: appDelegate)
    }

    private func renderedSidebarMode(from appDelegate: AppDelegate) -> SidebarMode? {
        reflectedValue(named: "renderedSidebarMode", from: appDelegate)
    }

    private func sidebarWidthConstraint(from appDelegate: AppDelegate) -> NSLayoutConstraint? {
        reflectedValue(named: "sidebarWidthConstraint", from: appDelegate)
    }

    private func sidebarHostView(from appDelegate: AppDelegate) -> NSView? {
        reflectedValue(named: "sidebarHostView", from: appDelegate)
    }

    private func sidebarContentView(from appDelegate: AppDelegate) -> NSView? {
        reflectedValue(named: "sidebarContentView", from: appDelegate)
    }

    private func collapsedRailHostView(from appDelegate: AppDelegate) -> NSView? {
        reflectedValue(named: "collapsedRailHostView", from: appDelegate)
    }

    private func reflectedValue<T>(named label: String, from instance: Any) -> T? {
        Mirror(reflecting: instance)
            .children
            .first(where: { $0.label == label })?
            .value as? T
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), file: file, line: line)
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
