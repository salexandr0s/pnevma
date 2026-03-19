import AppKit
import XCTest
@testable import Pnevma

@MainActor
final class AppDelegateTabBarIntegrationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            NSApp.windows.forEach { $0.orderOut(nil) }
        }
        super.tearDown()
    }

    func testMainWindowTabBarHandlesSelectAddAndInlineRenameFromRealWindow() throws {
        let appDelegate = AppDelegate()
        NSApp.delegate = appDelegate
        appDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        waitUntil { appDelegate.window != nil }
        let window = try XCTUnwrap(appDelegate.window)
        let contentView = try XCTUnwrap(window.contentView)

        appDelegate.newTab()
        waitUntil {
            self.workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count == 2
        }

        let tabBar = try XCTUnwrap(findSubview(ofType: TabBarView.self, in: contentView))
        waitUntil {
            contentView.layoutSubtreeIfNeeded()
            tabBar.layoutSubtreeIfNeeded()
            return tabBar.isHidden == false
        }

        let secondTab = try XCTUnwrap(tabViews(in: tabBar).dropFirst().first)
        let secondTitlePoint = try titlePoint(in: secondTab, ancestor: contentView)
        let secondHit = try XCTUnwrap(contentView.hitTest(secondTitlePoint))
        XCTAssertTrue(
            secondHit.isDescendant(of: tabBar) || secondHit === tabBar,
            "select hit=\(secondHit) point=\(NSStringFromPoint(secondTitlePoint)) tabBar=\(NSStringFromRect(tabBar.frame)) secondTab=\(NSStringFromRect(secondTab.frame)) local=\(NSStringFromPoint(tabBar.convert(secondTitlePoint, from: contentView)))"
        )
        try dispatchClick(in: window, rootView: contentView, point: secondTitlePoint)
        XCTAssertEqual(workspaceManager(from: appDelegate)?.activeWorkspace?.activeTabIndex, 1)

        let addButton = try XCTUnwrap(tabBar.subviews.compactMap { $0 as? NSButton }.first)
        let addPoint = center(of: addButton, ancestor: contentView)
        let addHit = try XCTUnwrap(contentView.hitTest(addPoint))
        XCTAssertTrue(
            addHit === addButton || addHit.isDescendant(of: addButton),
            "add hit=\(addHit) point=\(NSStringFromPoint(addPoint)) addButton=\(NSStringFromRect(addButton.frame)) tabBar=\(NSStringFromRect(tabBar.frame)) local=\(NSStringFromPoint(tabBar.convert(addPoint, from: contentView)))"
        )
        try dispatchClick(in: window, rootView: contentView, point: addPoint)
        waitUntil {
            self.workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count == 3
        }
        XCTAssertEqual(workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count, 3)

        let refreshedFirstTab = try XCTUnwrap(tabViews(in: tabBar).first)
        let firstCloseButton = try closeButton(in: refreshedFirstTab)
        firstCloseButton.performClick(nil)
        waitUntil {
            self.workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count == 2
        }
        XCTAssertEqual(workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.count, 2)

        let firstTab = try XCTUnwrap(tabViews(in: tabBar).first)
        let renamePoint = try titlePoint(in: firstTab, ancestor: contentView)
        let renameHit = try XCTUnwrap(contentView.hitTest(renamePoint))
        XCTAssertTrue(
            renameHit.isDescendant(of: tabBar) || renameHit === tabBar,
            "rename hit=\(renameHit) point=\(NSStringFromPoint(renamePoint)) tabBar=\(NSStringFromRect(tabBar.frame)) firstTab=\(NSStringFromRect(firstTab.frame)) local=\(NSStringFromPoint(tabBar.convert(renamePoint, from: contentView)))"
        )
        try dispatchDoubleClick(in: window, rootView: contentView, point: renamePoint)

        waitUntil { self.visibleRenameField(in: tabBar) != nil }
        let renameField = try XCTUnwrap(visibleRenameField(in: tabBar))
        waitUntil { self.currentEditor(for: renameField) != nil }
        let editor = try XCTUnwrap(currentEditor(for: renameField))
        XCTAssertTrue(window.firstResponder === editor)
        renameField.stringValue = "Build"
        editor.string = "Build"
        renameField.validateEditing()
        renameField.commitEditing()

        waitUntil {
            self.workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.first?.title == "Build"
        }
        XCTAssertEqual(workspaceManager(from: appDelegate)?.activeWorkspace?.tabs.first?.title, "Build")
    }

    private func tabViews(in tabBar: TabBarView) -> [NSView] {
        tabBar.subviews.filter { !($0 is NSButton) }
    }

    private func titleLabel(in tabView: NSView) throws -> NSTextField {
        try XCTUnwrap(tabView.subviews.compactMap { $0 as? NSTextField }.first)
    }

    private func closeButton(in tabView: NSView) throws -> NSButton {
        try XCTUnwrap(tabView.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func center(of view: NSView, ancestor: NSView) -> NSPoint {
        ancestor.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
    }

    private func titlePoint(in tabView: NSView, ancestor: NSView) throws -> NSPoint {
        center(of: try titleLabel(in: tabView), ancestor: ancestor)
    }

    private func dispatchClick(
        in window: NSWindow,
        rootView: NSView,
        point: NSPoint,
        clickCount: Int = 1
    ) throws {
        let location = rootView.convert(point, to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
        window.sendEvent(down)

        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
        window.sendEvent(up)
    }

    private func dispatchDoubleClick(
        in window: NSWindow,
        rootView: NSView,
        point: NSPoint
    ) throws {
        try dispatchClick(in: window, rootView: rootView, point: point, clickCount: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        try dispatchClick(in: window, rootView: rootView, point: point, clickCount: 2)
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

    private func visibleRenameField(in root: NSView) -> TabRenameField? {
        if let field = root as? TabRenameField, field.isHidden == false {
            return field
        }
        for subview in root.subviews {
            if let field = visibleRenameField(in: subview) {
                return field
            }
        }
        return nil
    }

    private func currentEditor(for field: TabRenameField) -> NSTextView? {
        field.currentEditor() as? NSTextView
    }

    private func workspaceManager(from appDelegate: AppDelegate) -> WorkspaceManager? {
        Mirror(reflecting: appDelegate)
            .children
            .first(where: { $0.label == "workspaceManager" })?
            .value as? WorkspaceManager
    }
}
