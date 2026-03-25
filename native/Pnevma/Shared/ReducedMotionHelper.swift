import SwiftUI

// MARK: - Reduced Motion

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

// MARK: - Bold Text

extension DesignTokens {
    enum AccessibleFont {
        static func weight(_ base: SwiftUI.Font.Weight) -> SwiftUI.Font.Weight {
            guard AccessibilityCheck.prefersBoldText else { return base }
            switch base {
            case .regular: return .medium
            case .medium: return .semibold
            case .semibold: return .bold
            default: return base
            }
        }
    }
}

// MARK: - Reduced Transparency Material

extension View {
    /// Replaces the view's material fill with an opaque fallback when Reduce Transparency is enabled.
    @ViewBuilder
    func opaqueIfReducedTransparency(fallback: Color = ChromeSurfaceStyle.pane.color) -> some View {
        if AccessibilityCheck.prefersReducedTransparency {
            self.hidden()
                .overlay(fallback)
        } else {
            self
        }
    }
}
