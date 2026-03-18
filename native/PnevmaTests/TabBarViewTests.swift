import AppKit
import XCTest
@testable import Pnevma

@MainActor
final class TabBarViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
        }
    }

    private func makeTabBar() -> TabBarView {
        let tabBar = TabBarView(
            frame: NSRect(x: 0, y: 0, width: 420, height: DesignTokens.Layout.tabBarHeight)
        )
        tabBar.tabs = [
            .init(id: UUID(), title: "Terminal", isActive: true),
            .init(id: UUID(), title: "Review", isActive: false)
        ]
        return tabBar
    }

    private func makeWindow(with contentView: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func makeMouseEvent(
        window: NSWindow,
        view: NSView,
        point: NSPoint,
        clickCount: Int
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: view.convert(point, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    private func firstTabView(in tabBar: TabBarView) throws -> NSView {
        try XCTUnwrap(tabBar.subviews.first(where: { !($0 is NSButton) }))
    }

    private func visibleRenameField(in tabView: NSView) throws -> NSTextField {
        try XCTUnwrap(
            tabView.subviews.compactMap { $0 as? NSTextField }.first {
                !$0.isHidden && $0.isEditable
            }
        )
    }

    func testDoubleClickOnTabTitleHitsTabInsteadOfLabel() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let hit = try XCTUnwrap(
            tabBar.hitTest(NSPoint(x: 36, y: DesignTokens.Layout.tabBarHeight / 2))
        )

        XCTAssertFalse(hit === tabBar)
        XCTAssertFalse(hit is NSTextField)
        XCTAssertFalse(hit is NSButton)
    }

    func testDoubleClickOnTabBeginsInlineRename() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let point = NSPoint(x: 36, y: DesignTokens.Layout.tabBarHeight / 2)
        let hit = try XCTUnwrap(tabBar.hitTest(point))
        let event = try makeMouseEvent(window: window, view: tabBar, point: point, clickCount: 2)

        hit.mouseDown(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let renameField = try visibleRenameField(in: firstTabView(in: tabBar))
        XCTAssertEqual(renameField.stringValue, "Terminal")
    }

    func testRenameCommitCallsRenameHandler() throws {
        let tabBar = makeTabBar()
        let expectedID = tabBar.tabs[0].id
        var renameCall: (UUID, String)?
        tabBar.onRenameTab = { id, title in
            renameCall = (id, title)
        }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let point = NSPoint(x: 36, y: DesignTokens.Layout.tabBarHeight / 2)
        let hit = try XCTUnwrap(tabBar.hitTest(point))
        let event = try makeMouseEvent(window: window, view: tabBar, point: point, clickCount: 2)

        hit.mouseDown(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let renameField = try visibleRenameField(in: firstTabView(in: tabBar))
        renameField.stringValue = "Build"
        let textView = NSTextView()
        _ = renameField.delegate?.control?(
            renameField,
            textView: textView,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )

        XCTAssertEqual(renameCall?.0, expectedID)
        XCTAssertEqual(renameCall?.1, "Build")
    }
}
