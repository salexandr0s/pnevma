import Foundation

enum DrawerSizing {
    static let minHeight: CGFloat = 280
    static let verticalInset: CGFloat = 24
    static let defaultHeightRatio: CGFloat = 0.45
    static let keyboardStep: CGFloat = 72
    static let resizeHandleHeight: CGFloat = 18
    static let resizeHandleTopPadding: CGFloat = 8

    private static let storageKey = "drawerHeight"

    static func maxHeight(for availableHeight: CGFloat) -> CGFloat {
        max(minHeight, availableHeight - verticalInset)
    }

    static func defaultHeight(for availableHeight: CGFloat) -> CGFloat {
        clamp(availableHeight * defaultHeightRatio, availableHeight: availableHeight)
    }

    static func clamp(_ height: CGFloat, availableHeight: CGFloat) -> CGFloat {
        min(max(height, minHeight), maxHeight(for: availableHeight))
    }

    static func storedHeight() -> CGFloat? {
        let raw = UserDefaults.standard.double(forKey: storageKey)
        return raw > 0 ? raw : nil
    }

    static func setStoredHeight(_ height: CGFloat) {
        UserDefaults.standard.set(height, forKey: storageKey)
    }

    static func resolvedHeight(availableHeight: CGFloat) -> CGFloat {
        clamp(storedHeight() ?? defaultHeight(for: availableHeight), availableHeight: availableHeight)
    }

    static func resolvedHeight(storedHeight: CGFloat?, availableHeight: CGFloat) -> CGFloat {
        clamp(storedHeight ?? defaultHeight(for: availableHeight), availableHeight: availableHeight)
    }
}
