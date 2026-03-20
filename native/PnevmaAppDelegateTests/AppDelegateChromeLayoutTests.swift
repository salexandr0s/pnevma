import AppKit
import XCTest
@testable import Pnevma

@MainActor
final class AppDelegateChromeLayoutTests: XCTestCase {
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
        }
        super.tearDown()
    }

    func testSingleTabLayoutSitsFlushUnderTitlebar() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)
            let titlebarFill = try XCTUnwrap(findSubview(ofType: ThemedTitlebarFillView.self, in: contentView))
            let tabBar = try XCTUnwrap(findSubview(ofType: TabBarView.self, in: contentView))
            let contentArea = try XCTUnwrap(findSubview(ofType: ContentAreaView.self, in: contentView))
            let sidebar = try XCTUnwrap(
                waitForView(withAccessibilityIdentifier: "sidebar.view", in: contentView)
            )

            waitUntil {
                contentView.layoutSubtreeIfNeeded()
                return tabBar.isHidden
                    && abs(titlebarBoundaryY(for: titlebarFill) - contentArea.frame.maxY) < 0.5
                    && abs(titlebarBoundaryY(for: titlebarFill) - sidebar.frame.maxY) < 0.5
            }

            XCTAssertTrue(tabBar.isHidden)
            XCTAssertEqual(titlebarBoundaryY(for: titlebarFill), contentArea.frame.maxY, accuracy: 0.5)
            XCTAssertEqual(titlebarBoundaryY(for: titlebarFill), sidebar.frame.maxY, accuracy: 0.5)
        }
    }

    func testTabBarSitsFlushUnderTitlebarWhenMultipleTabsAreOpen() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)
            let titlebarFill = try XCTUnwrap(findSubview(ofType: ThemedTitlebarFillView.self, in: contentView))
            let tabBar = try XCTUnwrap(findSubview(ofType: TabBarView.self, in: contentView))
            let contentArea = try XCTUnwrap(findSubview(ofType: ContentAreaView.self, in: contentView))

            appDelegate.newTab()

            waitUntil {
                contentView.layoutSubtreeIfNeeded()
                return tabBar.isHidden == false
                    && tabBar.tabs.count == 2
                    && abs(titlebarBoundaryY(for: titlebarFill) - tabBar.frame.maxY) < 0.5
                    && abs(tabBar.frame.minY - contentArea.frame.maxY) < 0.5
            }

            XCTAssertFalse(tabBar.isHidden)
            XCTAssertEqual(titlebarBoundaryY(for: titlebarFill), tabBar.frame.maxY, accuracy: 0.5)
            XCTAssertEqual(tabBar.frame.minY, contentArea.frame.maxY, accuracy: 0.5)
        }
    }

    func testTitlebarGroupsStaySeparatedFromCenteredStatusView() throws {
        try withUITestLightweightEnvironment {
            let appDelegate = launchAppDelegate()

            waitUntil { appDelegate.window != nil }
            let window = try XCTUnwrap(appDelegate.window)
            let contentView = try XCTUnwrap(window.contentView)
            let titlebarStatus = try XCTUnwrap(findSubview(ofType: TitlebarStatusView.self, in: contentView))

            waitUntil {
                contentView.layoutSubtreeIfNeeded()
                let groups = findSubviews(ofType: TitlebarControlGroupView.self, in: contentView)
                    .sorted { $0.frame.minX < $1.frame.minX }
                return groups.count == 3
                    && titlebarStatus.frame.width > 0
                    && groups.allSatisfy { $0.frame.width > 0 }
            }

            let groups = findSubviews(ofType: TitlebarControlGroupView.self, in: contentView)
                .sorted { $0.frame.minX < $1.frame.minX }
            XCTAssertEqual(groups.count, 3)

            let leadingGroup = try XCTUnwrap(groups.first)
            let primaryGroup = try XCTUnwrap(groups.dropFirst().first)
            let utilityGroup = try XCTUnwrap(groups.last)

            XCTAssertLessThanOrEqual(leadingGroup.frame.maxX, titlebarStatus.frame.minX + 0.5)
            XCTAssertLessThanOrEqual(titlebarStatus.frame.maxX, primaryGroup.frame.minX + 0.5)
            XCTAssertLessThanOrEqual(primaryGroup.frame.maxX, utilityGroup.frame.minX + 0.5)
        }
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

    private func titlebarBoundaryY(for titlebarFill: NSView) -> CGFloat {
        titlebarFill.frame.minY
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
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

    private func findSubview<T: NSView>(ofType type: T.Type, in root: NSView) -> T? {
        if let root = root as? T {
            return root
        }
        for subview in root.subviews {
            if let match = findSubview(ofType: type, in: subview) {
                return match
            }
        }
        return nil
    }

    private func findSubviews<T: NSView>(ofType type: T.Type, in root: NSView) -> [T] {
        var matches: [T] = []
        if let root = root as? T {
            matches.append(root)
        }
        for subview in root.subviews {
            matches.append(contentsOf: findSubviews(ofType: type, in: subview))
        }
        return matches
    }

    private func waitForView(
        withAccessibilityIdentifier identifier: String,
        in root: NSView,
        timeout: TimeInterval = 2
    ) -> NSView? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            root.layoutSubtreeIfNeeded()
            if let view = findView(withAccessibilityIdentifier: identifier, in: root) {
                return view
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return findView(withAccessibilityIdentifier: identifier, in: root)
    }

    private func findView(withAccessibilityIdentifier identifier: String, in root: NSView) -> NSView? {
        if root.accessibilityIdentifier() == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = findView(withAccessibilityIdentifier: identifier, in: subview) {
                return match
            }
        }
        return nil
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
