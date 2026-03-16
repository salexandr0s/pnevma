import Cocoa

/// System-native design tokens — no custom colors, no hardcoded sizes.
enum DesignTokens {
    // MARK: - Spacing
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // MARK: - Animation
    enum Motion {
        static let fast: TimeInterval = 0.12
        static let normal: TimeInterval = 0.18
        static let slow: TimeInterval = 0.22
        static let toastActionDuration: TimeInterval = 5.0
        static let focusModeTransition: TimeInterval = 0.25
    }

    // MARK: - Severity Colors
    enum SeverityColor {
        static func color(for level: String) -> NSColor {
            switch level {
            case "error", "failed":
                return .systemRed
            case "warning", "attention", "stuck":
                return .systemOrange
            case "success", "pass", "passed":
                return .systemGreen
            case "running", "active":
                return .systemBlue
            default:
                return .secondaryLabelColor
            }
        }
    }

    // MARK: - Layout
    enum Layout {
        static let sidebarWidth: CGFloat = 220
        static let sidebarCollapsedWidth: CGFloat = 52
        static let sidebarMinWidth: CGFloat = 180
        static let sidebarMaxWidth: CGFloat = 380
        static let agentStripHeight: CGFloat = 32
        static let statusDotSize: CGFloat = 8
        static let rightInspectorDefaultWidth: CGFloat = 340
        static let rightInspectorMinWidth: CGFloat = 280
        static let rightInspectorMaxWidth: CGFloat = 520
        static let toolDockHeight: CGFloat = 44
        static let toolDockRevealHeight: CGFloat = 0
        static let statusBarHeight: CGFloat = 28
        static let dividerWidth: CGFloat = 1
        static let dividerHoverWidth: CGFloat = 5
        static let focusBorderWidth: CGFloat = 2
        static let focusBorderOpacity: CGFloat = 0.4
        static let tabBarHeight: CGFloat = 34
        static let paneMinWidth: CGFloat = 200
        static let paneMinHeight: CGFloat = 100
        static let treeIndent: CGFloat = 14
    }

    // MARK: - Opacity
    enum Opacity {
        static let subtle: CGFloat = 0.06
        static let light: CGFloat = 0.10
        static let medium: CGFloat = 0.15
        static let strong: CGFloat = 0.30
        static let prominent: CGFloat = 0.50
    }

    // MARK: - Text Opacity (WCAG AA compliant)
    enum TextOpacity {
        static let primary: CGFloat = 0.92
        static let secondary: CGFloat = 0.70
        static let tertiary: CGFloat = 0.50
    }

    // MARK: - Font Sizes
    enum Font {
        static let mono: CGFloat = 11
        static let caption: CGFloat = 10
        static let body: CGFloat = 13
    }

    // MARK: - Interaction
    enum Interaction {
        static let minTouchTarget: CGFloat = 28
    }
}
