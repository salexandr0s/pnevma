import Cocoa
import XCTest
@testable import Pnevma

@MainActor
final class TerminalSurfaceTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated {
            TerminalSurface.clipboardStringProvider = {
                NSPasteboard.general.string(forType: .string) ?? ""
            }
            TerminalSurface.clipboardStringWriter = { string in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(string, forType: .string)
            }
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

    func testDecodeSelectionUsesExplicitLength() {
        let bytes = Array("hello\0ignored".utf8).map(CChar.init(bitPattern:))
        let selection = bytes.withUnsafeBufferPointer { buffer in
            TerminalSurface.decodeSelectionText(text: buffer.baseAddress, length: 5)
        }

        XCTAssertEqual(selection, "hello")
    }

    func testWriteClipboardStringUsesWriter() {
        var writes: [String] = []
        TerminalSurface.clipboardStringWriter = { writes.append($0) }

        TerminalSurface.writeClipboardString("clipboard-text")

        XCTAssertEqual(writes, ["clipboard-text"])
    }
}
