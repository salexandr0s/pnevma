import AppKit
import QuartzCore
import SwiftUI

enum ChromeMotionTransition {
    case sidebar
    case rightInspector
    case bottomDrawerOpen
    case bottomDrawerClose
    case disclosure
    case overlay
    case hover
    case tooltip
}

enum ChromeMotion {
    static let dockHideDelay: TimeInterval = 0.18
    static let dockRevealHeight: CGFloat = 6
    static let dockCollapsedOpacity: CGFloat = 0.94
    static let drawerHiddenOvershoot: CGFloat = 24
    static var disablesAnimationsForLightweightTesting: Bool {
        ProcessInfo.processInfo.environment["PNEVMA_UI_TESTING"] == "1"
            && ProcessInfo.processInfo.environment["PNEVMA_UI_TEST_LIGHTWEIGHT_MODE"] == "1"
    }

    static var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func duration(for transition: ChromeMotionTransition) -> TimeInterval {
        duration(for: transition, reducedMotion: prefersReducedMotion)
    }

    static func duration(
        for transition: ChromeMotionTransition,
        reducedMotion: Bool
    ) -> TimeInterval {
        guard !reducedMotion, !disablesAnimationsForLightweightTesting else { return 0 }

        switch transition {
        case .sidebar, .rightInspector:
            return 0.20
        case .bottomDrawerOpen:
            return 0.22
        case .bottomDrawerClose:
            return 0.18
        case .disclosure:
            return 0.14
        case .overlay:
            return 0.18
        case .hover, .tooltip:
            return 0.12
        }
    }

    static func animation(for transition: ChromeMotionTransition) -> Animation? {
        let duration = duration(for: transition)
        guard duration > 0 else { return nil }

        switch transition {
        case .bottomDrawerOpen:
            return .easeOut(duration: duration)
        case .bottomDrawerClose:
            return .easeIn(duration: duration)
        case .hover, .tooltip:
            return .easeOut(duration: duration)
        case .sidebar, .rightInspector, .disclosure, .overlay:
            return .easeInOut(duration: duration)
        }
    }

    static func timingFunction(for transition: ChromeMotionTransition) -> CAMediaTimingFunction? {
        timingFunction(for: transition, reducedMotion: prefersReducedMotion)
    }

    static func timingFunction(
        for transition: ChromeMotionTransition,
        reducedMotion: Bool
    ) -> CAMediaTimingFunction? {
        guard !reducedMotion else { return nil }

        switch transition {
        case .bottomDrawerOpen, .hover, .tooltip:
            return CAMediaTimingFunction(name: .easeOut)
        case .bottomDrawerClose:
            return CAMediaTimingFunction(name: .easeIn)
        case .sidebar, .rightInspector, .disclosure, .overlay:
            return CAMediaTimingFunction(name: .easeInEaseOut)
        }
    }

    static func drawerHiddenOffset(for containerHeight: CGFloat) -> CGFloat {
        prefersReducedMotion ? 12 : containerHeight + drawerHiddenOvershoot
    }
}
