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

    private func closeButton(in tabView: NSView) throws -> NSButton {
        try XCTUnwrap(tabView.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func addButton(in tabBar: TabBarView) throws -> NSButton {
        try XCTUnwrap(tabBar.subviews.compactMap { $0 as? NSButton }.first)
    }

    private func titleHitView(in tabView: NSView) throws -> NSView {
        try XCTUnwrap(
            tabView.subviews.first { !($0 is NSTextField) && !($0 is NSButton) }
        )
    }

    private func center(of view: NSView, in ancestor: NSView) -> NSPoint {
        ancestor.convert(
            NSPoint(x: view.bounds.midX, y: view.bounds.midY),
            from: view
        )
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

    func testTabTitleSurfaceExistsAlongsideLabelAndControls() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        XCTAssertNotNil(try titleHitView(in: tabView))
        XCTAssertNotNil(try closeButton(in: tabView))
    }

    func testAddButtonActionFires() throws {
        let tabBar = makeTabBar()
        var addCount = 0
        tabBar.onAddTab = {
            addCount += 1
        }
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let addButton = try addButton(in: tabBar)
        addButton.performClick(nil)

        XCTAssertEqual(addCount, 1)
    }

    func testHitTestRoutesAddButtonFromTabBarPoint() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let addButton = try addButton(in: tabBar)
        let hit = tabBar.hitTest(center(of: addButton, in: tabBar))

        XCTAssertTrue(hit === addButton || hit?.isDescendant(of: addButton) == true)
    }

    func testCloseButtonActionFires() throws {
        let tabBar = makeTabBar()
        var closedIndex: Int?
        tabBar.onCloseTab = { index in
            closedIndex = index
        }
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let closeButton = try closeButton(in: tabView)
        closeButton.performClick(nil)

        XCTAssertEqual(closedIndex, 0)
    }

    func testHitTestRoutesCloseButtonFromTabBarPoint() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let closeButton = try closeButton(in: tabView)
        let hit = tabBar.hitTest(center(of: closeButton, in: tabBar))

        XCTAssertTrue(hit === closeButton || hit?.isDescendant(of: closeButton) == true)
    }

    func testDoubleClickOnTabBeginsInlineRename() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let titleHitView = try titleHitView(in: tabView)
        let point = center(of: titleHitView, in: tabBar)
        let hit = try XCTUnwrap(tabBar.hitTest(point))
        XCTAssertTrue(hit === titleHitView)

        let localPoint = titleHitView.convert(point, from: tabBar)
        let event = try makeMouseEvent(window: window, view: titleHitView, point: localPoint, clickCount: 2)

        hit.mouseDown(with: event)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let renameField = try visibleRenameField(in: tabView)
        XCTAssertEqual(renameField.stringValue, "Terminal")
        XCTAssertNotNil(renameField.currentEditor())
    }

    func testSequentialMouseDownsBeginInlineRename() throws {
        let tabBar = makeTabBar()
        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let titleHitView = try titleHitView(in: tabView)
        let point = center(of: titleHitView, in: tabBar)
        let hit = try XCTUnwrap(tabBar.hitTest(point))
        let localPoint = titleHitView.convert(point, from: tabBar)

        let firstEvent = try makeMouseEvent(
            window: window,
            view: titleHitView,
            point: localPoint,
            clickCount: 1
        )
        hit.mouseDown(with: firstEvent)

        let secondEvent = try makeMouseEvent(
            window: window,
            view: titleHitView,
            point: localPoint,
            clickCount: 2
        )
        hit.mouseDown(with: secondEvent)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let renameField = try visibleRenameField(in: tabView)
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

        let tabView = try firstTabView(in: tabBar)
        let titleHitView = try titleHitView(in: tabView)
        let point = center(of: titleHitView, in: tabBar)
        let hit = try XCTUnwrap(tabBar.hitTest(point))
        XCTAssertTrue(hit === titleHitView)

        let localPoint = titleHitView.convert(point, from: tabBar)
        let event = try makeMouseEvent(window: window, view: titleHitView, point: localPoint, clickCount: 2)

        hit.mouseDown(with: event)
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

    func testSingleClickOnTabTitleSurfaceSelectsTab() throws {
        let tabBar = makeTabBar()
        var selectedIndex: Int?
        tabBar.onSelectTab = { index in
            selectedIndex = index
        }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let titleHitView = try titleHitView(in: tabView)
        let point = center(of: titleHitView, in: tabBar)
        let hit = try XCTUnwrap(tabBar.hitTest(point))
        let localPoint = titleHitView.convert(point, from: tabBar)
        let event = try makeMouseEvent(window: window, view: titleHitView, point: localPoint, clickCount: 1)

        hit.mouseDown(with: event)

        XCTAssertEqual(selectedIndex, 0)
    }

    func testRenamingThenClickingAddButtonStillAddsTab() throws {
        let tabBar = makeTabBar()
        installLiveRenameRebuildHandler(on: tabBar)
        var addCount = 0
        tabBar.onAddTab = {
            addCount += 1
        }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let titleHitView = try titleHitView(in: tabView)
        let renamePoint = center(of: titleHitView, in: tabBar)
        let renameHit = try XCTUnwrap(tabBar.hitTest(renamePoint))
        let renameLocalPoint = titleHitView.convert(renamePoint, from: tabBar)
        let renameEvent = try makeMouseEvent(
            window: window,
            view: titleHitView,
            point: renameLocalPoint,
            clickCount: 2
        )

        renameHit.mouseDown(with: renameEvent)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        _ = try visibleRenameField(in: tabView)

        let addButton = try addButton(in: tabBar)
        let addPoint = center(of: addButton, in: tabBar)
        try sendClick(to: tabBar, in: window, point: addPoint)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(addCount, 1)
    }

    func testRenamingThenClickingCloseButtonStillClosesTab() throws {
        let tabBar = makeTabBar()
        installLiveRenameRebuildHandler(on: tabBar)
        var closedIndex: Int?
        tabBar.onCloseTab = { index in
            closedIndex = index
        }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let tabView = try firstTabView(in: tabBar)
        let titleHitView = try titleHitView(in: tabView)
        let renamePoint = center(of: titleHitView, in: tabBar)
        let renameHit = try XCTUnwrap(tabBar.hitTest(renamePoint))
        let renameLocalPoint = titleHitView.convert(renamePoint, from: tabBar)
        let renameEvent = try makeMouseEvent(
            window: window,
            view: titleHitView,
            point: renameLocalPoint,
            clickCount: 2
        )

        renameHit.mouseDown(with: renameEvent)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        _ = try visibleRenameField(in: tabView)

        let secondTabView = try XCTUnwrap(
            tabBar.subviews.first { view in
                !(view is NSButton) && view !== tabView
            }
        )
        let closeButton = try closeButton(in: secondTabView)
        let closePoint = center(of: closeButton, in: tabBar)
        try sendClick(to: tabBar, in: window, point: closePoint)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(closedIndex, 1)
    }

    func testRenamingThenClickingAnotherTabStillSelectsIt() throws {
        let tabBar = makeTabBar()
        installLiveRenameRebuildHandler(on: tabBar)
        var selectedIndex: Int?
        tabBar.onSelectTab = { index in
            selectedIndex = index
        }

        let window = makeWindow(with: tabBar)
        defer { window.orderOut(nil) }
        tabBar.layoutSubtreeIfNeeded()

        let firstTabView = try firstTabView(in: tabBar)
        let firstTitleHitView = try titleHitView(in: firstTabView)
        let renamePoint = center(of: firstTitleHitView, in: tabBar)
        let renameHit = try XCTUnwrap(tabBar.hitTest(renamePoint))
        let renameLocalPoint = firstTitleHitView.convert(renamePoint, from: tabBar)
        let renameEvent = try makeMouseEvent(
            window: window,
            view: firstTitleHitView,
            point: renameLocalPoint,
            clickCount: 2
        )

        renameHit.mouseDown(with: renameEvent)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        _ = try visibleRenameField(in: firstTabView)

        let secondTabView = try XCTUnwrap(
            tabBar.subviews.first { view in
                !(view is NSButton) && view !== firstTabView
            }
        )
        let secondTitleHitView = try titleHitView(in: secondTabView)
        let secondPoint = center(of: secondTitleHitView, in: tabBar)
        try sendClick(to: tabBar, in: window, point: secondPoint)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(selectedIndex, 1)
    }
}
