import XCTest
@testable import Pnevma

final class WorkspacePathDisplayFormatterTests: XCTestCase {
    func testShortenedLocalPathKeepsDistinctHomeSegmentsWhenPathIsShortEnough() {
        XCTAssertEqual(
            WorkspacePathDisplayFormatter.shortenedLocalPath("~/dev/claude-code/cc-skills"),
            "~/dev/claude-code/cc-skills"
        )
    }

    func testShortenedLocalPathEllipsizesMiddleForLongerPaths() {
        XCTAssertEqual(
            WorkspacePathDisplayFormatter.shortenedLocalPath("~/dev/acme/client/claude-code/cc-skills"),
            "~/dev/…/claude-code/cc-skills"
        )
    }
}
