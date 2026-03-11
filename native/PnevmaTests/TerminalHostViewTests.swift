import AppKit
import CoreGraphics
import XCTest
@testable import Pnevma

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
}
