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

    private func dispatchClick(
        in tabBar: TabBarView,
        window: NSWindow,
        point: NSPoint,
        clickCount: Int = 1
    ) throws {
        let hitView = try XCTUnwrap(tabBar.hitTest(point))
        let down = try makeMouseEvent(
            window: window,
            view: tabBar,
            point: point,
            clickCount: clickCount,
            type: .leftMouseDown
        )
        hitView.mouseDown(with: down)

        let up = try makeMouseEvent(
            window: window,
            view: tabBar,
            point: point,
            clickCount: clickCount,
            type: .leftMouseUp
        )
        hitView.mouseUp(with: up)
    }

    private func dispatchDoubleClick(
        in tabBar: TabBarView,
        window: NSWindow,
        point: NSPoint
    ) throws {
        try dispatchClick(in: tabBar, window: window, point: point, clickCount: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        try dispatchClick(in: tabBar, window: window, point: point, clickCount: 2)
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
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

    private func currentEditor(for field: TabRenameField) -> NSTextView? {
        field.currentEditor() as? NSTextView
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
        try XCTUnwrap(tabView.subviews.compactMap { $0 as? NSTextField }.first(where: { $0.isEditable == false }))
    }

    private func renameField(in tabView: NSView) -> TabRenameField? {
        tabView.subviews.compactMap { $0 as? TabRenameField }.first(where: { $0.isHidden == false })
    }

    private func closeButton(in tabView: NSView) throws -> NSButton {
        try XCTUnwrap(tabView.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func addButton(in tabBar: TabBarView) throws -> NSButton {
        try XCTUnwrap(tabBar.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func center(of view: NSView, in ancestor: NSView) -> NSPoint {
        ancestor.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
    }

    private func titlePoint(in tabView: NSView, ancestor: NSView) throws -> NSPoint {
        center(of: try titleLabel(in: tabView), in: ancestor)
    }

    func testTabBodyRemainsHitTestTargetAtTitlePoint() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let point = try titlePoint(in: tabView, ancestor: tabBar)
        let hit = tabBar.hitTest(point)

        XCTAssertTrue(hit === tabView)
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
        try dispatchClick(in: tabBar, window: window, point: point)

        XCTAssertEqual(selectedIndex, 0)
    }

    func testDoubleClickOnTabBeginsInlineRename() throws {
        let tabBar = makeTabBar()

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let point = try titlePoint(in: firstTabView(in: tabBar), ancestor: tabBar)
        try dispatchDoubleClick(in: tabBar, window: window, point: point)

        let firstTab = try firstTabView(in: tabBar)
        XCTAssertNotNil(renameField(in: firstTab))
    }

    func testInlineRenameCommitCallsRenameHandler() throws {
        let tabBar = makeTabBar()
        let expectedID = tabBar.tabs[0].id
        var renamed: (UUID, String)?

        tabBar.onRenameTab = { renamed = ($0, $1) }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let point = try titlePoint(in: firstTabView(in: tabBar), ancestor: tabBar)
        try dispatchDoubleClick(in: tabBar, window: window, point: point)

        let firstTab = try firstTabView(in: tabBar)
        let field = try XCTUnwrap(renameField(in: firstTab))
        waitUntil { self.currentEditor(for: field) != nil }
        let editor = try XCTUnwrap(currentEditor(for: field))
        XCTAssertTrue(window.firstResponder === editor)
        field.stringValue = "Build"
        editor.string = "Build"
        field.validateEditing()
        field.commitEditing()

        XCTAssertEqual(renamed?.0, expectedID)
        XCTAssertEqual(renamed?.1, "Build")
    }

    func testCloseButtonHitTargetStillWorksAfterInlineRenameBegins() throws {
        let tabBar = makeTabBar()
        var closedIndex: Int?
        tabBar.onCloseTab = { closedIndex = $0 }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let renamePoint = try titlePoint(in: firstTabView(in: tabBar), ancestor: tabBar)
        try dispatchDoubleClick(in: tabBar, window: window, point: renamePoint)

        let secondTab = try secondTabView(in: tabBar)
        try closeButton(in: secondTab).performClick(nil)

        XCTAssertEqual(closedIndex, 1)
    }
}
