import AppKit
import SwiftUI
import XCTest
@testable import Pnevma

@MainActor
final class FirstMouseHostingViewTests: XCTestCase {
    func testFirstMouseHostingViewAcceptsFirstMouse() {
        let view = FirstMouseHostingView(rootView: AnyView(Text("Tool Dock")))

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    func testToolDockContainerViewAcceptsFirstMouse() {
        let view = ToolDockContainerView(frame: NSRect(x: 0, y: 0, width: 320, height: 48))

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
    }

    func testHoverTintButtonAcceptsFirstMouse() {
        let button = HoverTintButton(
            frame: NSRect(x: 0, y: 0, width: 28, height: 28),
            normalColor: .secondaryLabelColor,
            hoverColor: .systemRed
        )

        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertFalse(button.mouseDownCanMoveWindow)
    }

    func testBottomDrawerOverlayHostingViewAcceptsFirstMouseWhileRemainingPointerGated() {
        let view = BottomDrawerOverlayHostingView(rootView: AnyView(Text("Drawer")))
        view.frame = NSRect(x: 0, y: 0, width: 240, height: 120)

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(view.mouseDownCanMoveWindow)

        view.capturesPointerEvents = false
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testAgentLauncherOverlayViewCapturesHitsInsideBounds() {
        let view = AgentLauncherOverlayView { _ in }
        view.frame = NSRect(x: 0, y: 0, width: 96, height: 32)

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertNil(view.hitTest(NSPoint(x: -1, y: 8)))
        XCTAssertEqual(view.hitTest(NSPoint(x: 12, y: 12)), view)
    }

    func testAgentLauncherOverlayViewTriggersTrackedSelection() throws {
        var selectedAgents: [AgentKind] = []
        let view = AgentLauncherOverlayView { selectedAgents.append($0) }
        view.frame = NSRect(x: 0, y: 0, width: 96, height: 32)
        view.layoutSubtreeIfNeeded()

        let stack = try XCTUnwrap(view.subviews.first as? NSStackView)
        let button = try XCTUnwrap(stack.arrangedSubviews.first)
        let point = view.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), from: button)

        view.beginInteraction(at: point)
        view.endInteraction(at: point)

        XCTAssertEqual(selectedAgents, [.claude])
    }
}
