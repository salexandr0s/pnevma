import AppKit
import CoreGraphics
import XCTest
@testable import Pnevma

private final class FocusableTestView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class TerminalHostViewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testScreenRectFromGhosttyRectConvertsTopLeftCoordinatesToScreenSpace() {
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 200, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = contentView

        let hostView = TerminalHostView(frame: NSRect(x: 20, y: 30, width: 200, height: 120))
        contentView.addSubview(hostView)

        let rect = hostView.screenRectFromGhosttyRect(x: 10, y: 15, width: 30, height: 8)
        let expectedViewRect = NSRect(x: 10, y: 105, width: 30, height: 8)
        let expectedWindowRect = hostView.convert(expectedViewRect, to: nil)
        let expectedScreenRect = window.convertToScreen(expectedWindowRect)

        XCTAssertEqual(rect.origin.x, expectedScreenRect.origin.x, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, expectedScreenRect.origin.y, accuracy: 0.01)
        XCTAssertEqual(rect.width, expectedScreenRect.width, accuracy: 0.01)
        XCTAssertEqual(rect.height, expectedScreenRect.height, accuracy: 0.01)
    }

    func testOnlyButtonTwoIsTreatedAsMiddleMouseButton() {
        XCTAssertFalse(TerminalHostView.shouldTreatAsMiddleMouseButton(1))
        XCTAssertTrue(TerminalHostView.shouldTreatAsMiddleMouseButton(2))
        XCTAssertFalse(TerminalHostView.shouldTreatAsMiddleMouseButton(3))
    }

    func testFlagsChangedDoesNotReadCharactersFromModifierOnlyEvent() throws {
        let source = try XCTUnwrap(CGEventSource(stateID: .hidSystemState))
        let cgEvent = try XCTUnwrap(CGEvent(source: source))
        cgEvent.type = .flagsChanged
        cgEvent.flags = .maskCommand
        cgEvent.setIntegerValueField(.keyboardEventKeycode, value: 55)
        let event = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        let hostView = TerminalHostView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))

        XCTAssertEqual(event.type, .flagsChanged)
        XCTAssertNoThrow(hostView.flagsChanged(with: event))
    }

    func testMouseDownClaimsFirstResponder() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentLayoutRect)
        window.contentView = contentView

        let priorResponder = FocusableTestView(frame: NSRect(x: 20, y: 20, width: 120, height: 24))
        let hostView = TerminalHostView(frame: NSRect(x: 20, y: 60, width: 200, height: 120))
        contentView.addSubview(priorResponder)
        contentView.addSubview(hostView)
        window.makeKeyAndOrderFront(nil)

        XCTAssertTrue(window.makeFirstResponder(priorResponder))
        XCTAssertTrue(window.firstResponder === priorResponder)

        let location = hostView.convert(NSPoint(x: 10, y: 10), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))

        hostView.mouseDown(with: event)

        XCTAssertTrue(window.firstResponder === hostView)
    }
}
