import AppKit
import XCTest
@testable import Pnevma

@MainActor
final class BrowserReaderFindControllerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testSearchUsesRawQueryWithoutTrimming() {
        let controller = makeBoundController()
        controller.updateMarkdown("foo")

        XCTAssertEqual(controller.search(query: " foo "), 0)
    }

    func testClearRestoresRenderedAttributesAfterHighlighting() {
        let (controller, textView) = makeBoundControllerWithTextView()
        controller.updateMarkdown("This has a [link](https://example.com) and **bold** text.")

        let baseline = NSAttributedString(attributedString: textView.textStorage ?? NSTextStorage())

        XCTAssertEqual(controller.search(query: "text"), 1)
        XCTAssertTrue(containsAttribute(.backgroundColor, in: textView.attributedString()))

        controller.clear()

        XCTAssertEqual(textView.attributedString(), baseline)
    }

    private func makeBoundController() -> BrowserReaderFindController {
        makeBoundControllerWithTextView().0
    }

    private func makeBoundControllerWithTextView() -> (BrowserReaderFindController, NSTextView) {
        let controller = BrowserReaderFindController()
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        let textView = NSTextView(frame: scrollView.bounds)
        textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
        scrollView.documentView = textView
        controller.bind(textView: textView, inside: scrollView)
        return (controller, textView)
    }

    private func containsAttribute(_ key: NSAttributedString.Key, in attributedString: NSAttributedString) -> Bool {
        var found = false
        attributedString.enumerateAttribute(
            key,
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { value, _, stop in
            if value != nil {
                found = true
                stop.pointee = true
            }
        }
        return found
    }
}
