import SwiftUI

extension DesignTokens.Motion {
    /// Returns nil (instant) when reduced motion is enabled.
    static func resolved(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }

    /// Returns 0 when reduced motion is enabled (for CAAnimation durations).
    static func resolvedDuration(_ base: TimeInterval) -> TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : base
    }
}
