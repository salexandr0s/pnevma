import Cocoa
import XCTest
@testable import Pnevma

final class TerminalSurfaceTests: XCTestCase {
    override func tearDown() {
        TerminalSurface.clipboardStringProvider = {
            NSPasteboard.general.string(forType: .string) ?? ""
        }
        super.tearDown()
    }

    func testClipboardStringForConfirmedRequestUsesProvider() {
        TerminalSurface.clipboardStringProvider = { "confirmed-text" }

        XCTAssertEqual(
            TerminalSurface.clipboardStringForRequest(confirmed: true),
            "confirmed-text"
        )
    }

    func testClipboardStringForUnconfirmedRequestUsesProvider() {
        TerminalSurface.clipboardStringProvider = { "clipboard-text" }

        XCTAssertEqual(
            TerminalSurface.clipboardStringForRequest(confirmed: false),
            "clipboard-text"
        )
    }
}
