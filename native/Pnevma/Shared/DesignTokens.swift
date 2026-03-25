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
        static let statusDotSize: CGFloat = 8
        static let rightInspectorDefaultWidth: CGFloat = 340
        static let rightInspectorMinWidth: CGFloat = 280
        static let rightInspectorMaxWidth: CGFloat = 520
        static let titlebarGroupHeight: CGFloat = 30
        static let titlebarControlHeight: CGFloat = 28
        static let titlebarIconButtonSize: CGFloat = 28
        static let titlebarGroupCornerRadius: CGFloat = 10
        static let titlebarInnerSpacing: CGFloat = 4
        static let titlebarInterGroupSpacing: CGFloat = 8
        static let toolDockHeight: CGFloat = 54
        static let toolDockRevealHeight: CGFloat = 6
        static let statusBarHeight: CGFloat = 28
        static let dividerWidth: CGFloat = 1
        static let dividerHoverWidth: CGFloat = 5
        static let focusBorderWidth: CGFloat = 2
        static let focusBorderOpacity: CGFloat = 0.4
        static let tabBarHeight: CGFloat = 34
        static let paneMinWidth: CGFloat = 200
        static let paneMinHeight: CGFloat = 100
        static let treeIndent: CGFloat = 14
        static let paneToolbarHeight: CGFloat = 40
        static let groupedCornerRadius: CGFloat = 12
        static let utilityShelfCornerRadius: CGFloat = 0
    }

    // MARK: - Opacity (contrast-aware)
    enum Opacity {
        private static var high: Bool { AccessibilityCheck.prefersHighContrast }
        static var subtle: CGFloat { high ? 0.12 : 0.06 }
        static var light: CGFloat { high ? 0.18 : 0.10 }
        static var medium: CGFloat { high ? 0.25 : 0.15 }
        static var strong: CGFloat { high ? 0.45 : 0.30 }
        static var prominent: CGFloat { high ? 0.65 : 0.50 }
    }

    // MARK: - Text Opacity (WCAG AA compliant, contrast-aware)
    enum TextOpacity {
        private static var high: Bool { AccessibilityCheck.prefersHighContrast }
        static var primary: CGFloat { high ? 1.0 : 0.92 }
        static var secondary: CGFloat { high ? 0.85 : 0.70 }
        static var inactive: CGFloat { high ? 0.70 : 0.50 }
        static var tertiary: CGFloat { high ? 0.70 : 0.50 }
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
