import XCTest
@testable import Pnevma

final class NativeChromeTests: XCTestCase {
    func testPanePresentationRoleMapsPrimaryPaneFamilies() {
        XCTAssertEqual(PanePresentationRole(paneType: "terminal"), .document)
        XCTAssertEqual(PanePresentationRole(paneType: "file_browser"), .document)
        XCTAssertEqual(PanePresentationRole(paneType: "secrets"), .manager)
        XCTAssertEqual(PanePresentationRole(paneType: "analytics"), .monitor)
        XCTAssertEqual(PanePresentationRole(paneType: "review"), .inspectorDriven)
        XCTAssertEqual(PanePresentationRole(paneType: "replay"), .utility)
    }

    func testChromeSurfaceStyleResolvedColorUsesBaseWhenNoTintProvided() {
        XCTAssertEqual(
            ChromeSurfaceStyle.window.resolvedColor(),
            ChromeSurfaceStyle.window.baseColor
        )
        XCTAssertEqual(
            ChromeSurfaceStyle.toolbar.resolvedColor(),
            ChromeSurfaceStyle.toolbar.baseColor
        )
    }
}
