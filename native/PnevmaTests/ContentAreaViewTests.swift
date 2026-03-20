import AppKit
import XCTest
@testable import Pnevma

@MainActor
private final class CloseDecisionPane: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "test"
    let title = "Test"
    let hasActiveProcess: Bool

    init(hasActiveProcess: Bool = false) {
        self.hasActiveProcess = hasActiveProcess
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }
}

@MainActor
private final class CloseDecisionTerminalPane: NSView, TerminalPaneControlling {
    let paneID = PaneID()
    let paneType = "terminal"
    let title = "Terminal"
    let hasActiveProcess: Bool
    let closeDecision: Bool

    init(hasActiveProcess: Bool, closeDecision: Bool) {
        self.hasActiveProcess = hasActiveProcess
        self.closeDecision = closeDecision
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    func loadSession(sessionID _: String, workingDirectory _: String?) {}
    func launchAgent(_: AgentKind) {}

    func requestCloseDecision(_ completion: @escaping (Bool) -> Void) {
        completion(closeDecision)
    }
}

@MainActor
final class ContentAreaViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            _ = NSApplication.shared
        }
    }

    func testActivePaneCloseConfirmationUsesExplicitTerminalDecision() {
        let pane = CloseDecisionTerminalPane(hasActiveProcess: true, closeDecision: false)
        let contentArea = ContentAreaView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), rootPaneView: pane)
        let expectation = expectation(description: "close decision")
        var result: Bool?

        contentArea.activePaneRequiresCloseConfirmation {
            result = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(result, false)
    }

    func testAnyPaneCloseConfirmationReturnsTrueWhenAnyPaneNeedsIt() {
        let rootPane = CloseDecisionPane()
        let contentArea = ContentAreaView(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            rootPaneView: rootPane
        )
        let terminalPane = CloseDecisionTerminalPane(hasActiveProcess: false, closeDecision: true)
        XCTAssertNotNil(contentArea.splitActivePane(direction: .horizontal, newPaneView: terminalPane))

        let expectation = expectation(description: "any pane close decision")
        var result: Bool?

        contentArea.anyPaneRequiresCloseConfirmation {
            result = $0
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(result, true)
    }

    func testDividerSurvivesHoverRemovalAndRebuildWithoutLosingDragBehavior() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let windowContent = NSView(frame: window.contentLayoutRect)
        window.contentView = windowContent

        let rootPane = CloseDecisionPane()
        let contentArea = ContentAreaView(
            frame: windowContent.bounds,
            rootPaneView: rootPane
        )
        contentArea.autoresizingMask = [.width, .height]
        windowContent.addSubview(contentArea)
        window.makeKeyAndOrderFront(nil)
        windowContent.layoutSubtreeIfNeeded()

        let secondPane = CloseDecisionPane()
        XCTAssertNotNil(contentArea.splitActivePane(direction: .horizontal, newPaneView: secondPane))
        windowContent.layoutSubtreeIfNeeded()

        let divider = try XCTUnwrap(findView(withAccessibilityIdentifier: "content.divider", in: contentArea))
        XCTAssertEqual(divider.accessibilityRole(), .splitter)

        let initialWidth = rootPane.frame.width
        let startPoint = center(of: divider, ancestor: contentArea)
        let draggedPoint = NSPoint(x: startPoint.x + 48, y: startPoint.y)
        try dispatchDrag(on: divider, in: window, ancestor: contentArea, start: startPoint, end: draggedPoint)
        XCTAssertGreaterThan(rootPane.frame.width, initialWidth + 20)

        let hoverEvent = try XCTUnwrap(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: contentArea.convert(startPoint, to: nil),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil
        ))
        divider.mouseEntered(with: hoverEvent)

        let replacementRoot = CloseDecisionPane()
        contentArea.setRootPane(replacementRoot)
        windowContent.layoutSubtreeIfNeeded()
        XCTAssertNil(findView(withAccessibilityIdentifier: "content.divider", in: contentArea))

        let rebuiltSecondPane = CloseDecisionPane()
        XCTAssertNotNil(contentArea.splitActivePane(direction: .horizontal, newPaneView: rebuiltSecondPane))
        windowContent.layoutSubtreeIfNeeded()

        let rebuiltDivider = try XCTUnwrap(findView(withAccessibilityIdentifier: "content.divider", in: contentArea))
        XCTAssertEqual(rebuiltDivider.accessibilityRole(), .splitter)

        let rebuiltInitialWidth = replacementRoot.frame.width
        let rebuiltStartPoint = center(of: rebuiltDivider, ancestor: contentArea)
        let rebuiltDraggedPoint = NSPoint(x: rebuiltStartPoint.x + 40, y: rebuiltStartPoint.y)
        try dispatchDrag(
            on: rebuiltDivider,
            in: window,
            ancestor: contentArea,
            start: rebuiltStartPoint,
            end: rebuiltDraggedPoint
        )
        XCTAssertGreaterThan(replacementRoot.frame.width, rebuiltInitialWidth + 16)
    }

    private func center(of view: NSView, ancestor: NSView) -> NSPoint {
        ancestor.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
    }

    private func dispatchDrag(
        on view: NSView,
        in window: NSWindow,
        ancestor: NSView,
        start: NSPoint,
        end: NSPoint
    ) throws {
        let startLocation = ancestor.convert(start, to: nil)
        let endLocation = ancestor.convert(end, to: nil)

        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: startLocation,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        let dragged = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: endLocation,
            modifierFlags: [],
            timestamp: 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: endLocation,
            modifierFlags: [],
            timestamp: 0.02,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ))

        view.mouseDown(with: down)
        view.mouseDragged(with: dragged)
        view.mouseUp(with: up)
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
}
