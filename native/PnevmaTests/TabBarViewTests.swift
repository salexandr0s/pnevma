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
        clickCount: Int,
        type: NSEvent.EventType = .leftMouseDown
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
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

    private func sendClick(
        to view: NSView,
        in window: NSWindow,
        point: NSPoint,
        clickCount: Int = 1
    ) throws {
        let down = try makeMouseEvent(
            window: window,
            view: view,
            point: point,
            clickCount: clickCount,
            type: .leftMouseDown
        )
        NSApp.sendEvent(down)

        let up = try makeMouseEvent(
            window: window,
            view: view,
            point: point,
            clickCount: clickCount,
            type: .leftMouseUp
        )
        NSApp.sendEvent(up)
    }

    private func tabViews(in tabBar: TabBarView) -> [NSView] {
        tabBar.subviews.filter { !($0 is NSButton) }
    }

    private func firstTabView(in tabBar: TabBarView) throws -> NSView {
        try XCTUnwrap(tabViews(in: tabBar).first)
    }

    private func secondTabView(in tabBar: TabBarView) throws -> NSView {
        try XCTUnwrap(tabViews(in: tabBar).dropFirst().first)
    }

    private func titleLabel(in tabView: NSView) throws -> NSTextField {
        try XCTUnwrap(
            tabView.subviews.compactMap { $0 as? NSTextField }.first { !$0.isEditable }
        )
    }

    private func visibleRenameField(in tabView: NSView) throws -> NSTextField {
        try XCTUnwrap(
            tabView.subviews.compactMap { $0 as? NSTextField }.first {
                !$0.isHidden && $0.isEditable
            }
        )
    }

    private func closeButton(in tabView: NSView) throws -> NSButton {
        try XCTUnwrap(tabView.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func addButton(in tabBar: TabBarView) throws -> NSButton {
        try XCTUnwrap(tabBar.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func center(of view: NSView, in ancestor: NSView) -> NSPoint {
        ancestor.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            from: view
        )
    }

    private func titlePoint(in tabView: NSView, ancestor: NSView) throws -> NSPoint {
        center(of: try titleLabel(in: tabView), in: ancestor)
    }

    private func installLiveRenameRebuildHandler(on tabBar: TabBarView) {
        tabBar.onRenameTab = { [weak tabBar] id, title in
            guard let tabBar else { return }
            tabBar.tabs = tabBar.tabs.map { tab in
                guard tab.id == id else { return tab }
                return .init(
                    id: tab.id,
                    title: title,
                    isActive: tab.isActive,
                    hasNotification: tab.hasNotification
                )
            }
        }
    }

    func testTabBodyRemainsHitTestTargetAtTitlePoint() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let point = try titlePoint(in: tabView, ancestor: tabBar)
        let hit = tabBar.hitTest(point)

        XCTAssertTrue(
            hit === tabView,
            "hit=\(String(describing: hit)) expected=\(tabView) point=\(NSStringFromPoint(point)) frames=\(tabViews(in: tabBar).map { NSStringFromRect($0.frame) })"
        )
    }

    func testAddButtonActionFires() throws {
        let tabBar = makeTabBar()
        var addCount = 0
        tabBar.onAddTab = { addCount += 1 }
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        try addButton(in: tabBar).performClick(nil)

        XCTAssertEqual(addCount, 1)
    }

    func testCloseButtonActionFires() throws {
        let tabBar = makeTabBar()
        var closedIndex: Int?
        tabBar.onCloseTab = { closedIndex = $0 }
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        try closeButton(in: firstTabView(in: tabBar)).performClick(nil)

        XCTAssertEqual(closedIndex, 0)
    }

    func testSingleClickOnTabSelectsTab() throws {
        let tabBar = makeTabBar()
        var selectedIndex: Int?
        tabBar.onSelectTab = { selectedIndex = $0 }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let point = try titlePoint(in: firstTabView(in: tabBar), ancestor: tabBar)
        try sendClick(to: tabBar, in: window, point: point)

        XCTAssertEqual(
            selectedIndex,
            0,
            "point=\(NSStringFromPoint(point)) frames=\(tabViews(in: tabBar).map { NSStringFromRect($0.frame) })"
        )
    }

    func testDoubleClickOnTabBeginsInlineRename() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let point = try titlePoint(in: tabView, ancestor: tabBar)
        try sendClick(to: tabBar, in: window, point: point, clickCount: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let renameField = try visibleRenameField(in: tabView)
        XCTAssertEqual(renameField.stringValue, "Terminal")
        XCTAssertNotNil(renameField.currentEditor())
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

        let tabView = try firstTabView(in: tabBar)
        let point = try titlePoint(in: tabView, ancestor: tabBar)
        try sendClick(to: tabBar, in: window, point: point, clickCount: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let renameField = try visibleRenameField(in: tabView)
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

    func testRenamingThenClickingAddButtonStillAddsTab() throws {
        let tabBar = makeTabBar()
        installLiveRenameRebuildHandler(on: tabBar)
        var addCount = 0
        tabBar.onAddTab = { addCount += 1 }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        try sendClick(
            to: tabBar,
            in: window,
            point: try titlePoint(in: tabView, ancestor: tabBar),
            clickCount: 2
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        _ = try visibleRenameField(in: tabView)

        let addPoint = center(of: try addButton(in: tabBar), in: tabBar)
        try sendClick(to: tabBar, in: window, point: addPoint)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(addCount, 1)
    }

    func testRenamingThenClickingCloseButtonStillClosesTab() throws {
        let tabBar = makeTabBar()
        installLiveRenameRebuildHandler(on: tabBar)
        var closedIndex: Int?
        tabBar.onCloseTab = { closedIndex = $0 }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let firstTab = try firstTabView(in: tabBar)
        try sendClick(
            to: tabBar,
            in: window,
            point: try titlePoint(in: firstTab, ancestor: tabBar),
            clickCount: 2
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        _ = try visibleRenameField(in: firstTab)

        let secondTab = try secondTabView(in: tabBar)
        let closePoint = center(of: try closeButton(in: secondTab), in: tabBar)
        try sendClick(to: tabBar, in: window, point: closePoint)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(closedIndex, 1)
    }

    func testRenamingThenClickingAnotherTabStillSelectsIt() throws {
        let tabBar = makeTabBar()
        installLiveRenameRebuildHandler(on: tabBar)
        var selectedIndex: Int?
        tabBar.onSelectTab = { selectedIndex = $0 }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let firstTab = try firstTabView(in: tabBar)
        try sendClick(
            to: tabBar,
            in: window,
            point: try titlePoint(in: firstTab, ancestor: tabBar),
            clickCount: 2
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        _ = try visibleRenameField(in: firstTab)

        let secondTab = try secondTabView(in: tabBar)
        try sendClick(to: tabBar, in: window, point: try titlePoint(in: secondTab, ancestor: tabBar))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(selectedIndex, 1)
    }
}
