import XCTest
@testable import Pnevma

final class TerminalArchivedScrollbackFormatterTests: XCTestCase {
    func testFormatterStripsTerminalControlSequencesIntoReadableTranscript() {
        let raw = "\u{001B}[?1049h\u{001B}[2Jpnevma on main\r\n\u{001B}[32m❯\u{001B}[m ls\r\nfile.txt\r\n^D\u{0008}\u{0008}[exited]"

        let presentation = TerminalArchivedScrollbackFormatter.presentation(for: raw)

        XCTAssertTrue(presentation.didNormalizeOutput)
        XCTAssertEqual(
            presentation.text,
            """
            pnevma on main
            ❯ ls
            file.txt
            [exited]
            """
        )
        XCTAssertEqual(presentation.omittedRepeatedLineCount, 0)
        XCTAssertEqual(presentation.omittedBlankLineCount, 0)
    }

    func testFormatterCollapsesRepeatedLinesAndBlankRuns() {
        let raw = "prompt\nprompt\nprompt\n\n\n\nstatus\nstatus\n"

        let presentation = TerminalArchivedScrollbackFormatter.presentation(for: raw)

        XCTAssertEqual(
            presentation.text,
            """
            prompt
            ... 2 repeated lines omitted

            status
            ... 1 repeated line omitted
            """
        )
        XCTAssertEqual(presentation.omittedRepeatedLineCount, 3)
        XCTAssertEqual(presentation.omittedBlankLineCount, 2)
    }
}
