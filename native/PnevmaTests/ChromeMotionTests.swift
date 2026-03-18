import XCTest
@testable import Pnevma

final class ChromeMotionTests: XCTestCase {
    func testSystemNativeDurationsMatchChromeProfile() {
        XCTAssertEqual(ChromeMotion.duration(for: .sidebar, reducedMotion: false), 0.20, accuracy: 0.001)
        XCTAssertEqual(ChromeMotion.duration(for: .rightInspector, reducedMotion: false), 0.20, accuracy: 0.001)
        XCTAssertEqual(ChromeMotion.duration(for: .bottomDrawerOpen, reducedMotion: false), 0.22, accuracy: 0.001)
        XCTAssertEqual(ChromeMotion.duration(for: .bottomDrawerClose, reducedMotion: false), 0.18, accuracy: 0.001)
        XCTAssertEqual(ChromeMotion.duration(for: .disclosure, reducedMotion: false), 0.14, accuracy: 0.001)
        XCTAssertEqual(ChromeMotion.duration(for: .overlay, reducedMotion: false), 0.18, accuracy: 0.001)
    }

    func testReducedMotionDisablesChromeAnimations() {
        for transition in [
            ChromeMotionTransition.sidebar,
            .rightInspector,
            .bottomDrawerOpen,
            .bottomDrawerClose,
            .disclosure,
            .overlay,
            .hover,
            .tooltip,
        ] {
            XCTAssertEqual(ChromeMotion.duration(for: transition, reducedMotion: true), 0)
            XCTAssertNil(ChromeMotion.timingFunction(for: transition, reducedMotion: true))
        }
    }

    func testToolDockRevealStripMatchesMotionProfile() {
        XCTAssertEqual(ChromeMotion.dockRevealHeight, 6)
        XCTAssertEqual(ChromeMotion.dockCollapsedOpacity, 0.94, accuracy: 0.001)
        XCTAssertEqual(DesignTokens.Layout.toolDockRevealHeight, ChromeMotion.dockRevealHeight)
        XCTAssertLessThan(ChromeMotion.dockRevealHeight, DesignTokens.Layout.toolDockHeight)
    }
}
