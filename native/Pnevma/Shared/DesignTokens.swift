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
    }

    // MARK: - Layout
    enum Layout {
        static let sidebarWidth: CGFloat = 220
        static let statusBarHeight: CGFloat = 28
        static let dividerWidth: CGFloat = 1
        static let paneMinWidth: CGFloat = 200
        static let paneMinHeight: CGFloat = 100
    }
}
