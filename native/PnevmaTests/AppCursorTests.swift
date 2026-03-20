import AppKit
import XCTest
#if canImport(GhosttyKit)
import GhosttyKit
#endif
@testable import Pnevma

@MainActor
final class AppCursorTests: XCTestCase {
    func testCursorRolesMapToExpectedSystemCursors() {
        XCTAssertTrue(AppCursor.cursor(for: .text) === NSCursor.iBeam)
        XCTAssertTrue(AppCursor.cursor(for: .verticalText) === NSCursor.iBeamCursorForVerticalLayout)
        XCTAssertTrue(AppCursor.cursor(for: .defaultControl) === NSCursor.arrow)
        XCTAssertTrue(AppCursor.cursor(for: .linkPointer) === NSCursor.pointingHand)
        XCTAssertTrue(AppCursor.cursor(for: .horizontalResize) === NSCursor.resizeLeftRight)
        XCTAssertTrue(AppCursor.cursor(for: .verticalResize) === NSCursor.resizeUpDown)
        XCTAssertTrue(AppCursor.cursor(for: .dragIdle) === NSCursor.openHand)
        XCTAssertTrue(AppCursor.cursor(for: .dragActive) === NSCursor.closedHand)
    }

    #if canImport(GhosttyKit)
    func testGhosttyCursorShapesMapToExpectedSystemCursors() {
        XCTAssertTrue(AppCursor.cursor(forGhosttyShape: GHOSTTY_MOUSE_SHAPE_TEXT) === NSCursor.iBeam)
        XCTAssertTrue(
            AppCursor.cursor(forGhosttyShape: GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT)
                === NSCursor.iBeamCursorForVerticalLayout
        )
        XCTAssertTrue(AppCursor.cursor(forGhosttyShape: GHOSTTY_MOUSE_SHAPE_POINTER) === NSCursor.pointingHand)
        XCTAssertTrue(AppCursor.cursor(forGhosttyShape: GHOSTTY_MOUSE_SHAPE_GRAB) === NSCursor.openHand)
        XCTAssertTrue(AppCursor.cursor(forGhosttyShape: GHOSTTY_MOUSE_SHAPE_GRABBING) === NSCursor.closedHand)
        XCTAssertTrue(AppCursor.cursor(forGhosttyShape: GHOSTTY_MOUSE_SHAPE_COL_RESIZE) === NSCursor.resizeLeftRight)
        XCTAssertTrue(AppCursor.cursor(forGhosttyShape: GHOSTTY_MOUSE_SHAPE_ROW_RESIZE) === NSCursor.resizeUpDown)
        XCTAssertTrue(AppCursor.cursor(forGhosttyShape: GHOSTTY_MOUSE_SHAPE_HELP) === NSCursor.arrow)
    }
    #endif
}
