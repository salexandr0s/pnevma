import AppKit
import Observation

/// Reactive color provider that reads theme colors from the live ghostty config.
/// Other views observe published properties to stay in sync with the terminal theme.
@Observable
@MainActor
final class GhosttyThemeProvider {

    static let shared = GhosttyThemeProvider()

    private(set) var backgroundColor: NSColor = GhosttyThemeProvider.defaultBackground()
    private(set) var foregroundColor: NSColor = GhosttyThemeProvider.defaultForeground()
    private(set) var backgroundOpacity: Double = 1.0
    private(set) var splitDividerColor: NSColor?
    private(set) var unfocusedSplitFill: NSColor?
    private(set) var unfocusedSplitOpacity: Double = 0.85

    /// Notification posted when theme colors change.
    static let didChangeNotification = Notification.Name("GhosttyThemeProviderDidChange")

    private init() {
        loadFromConfig()
        // Observe system appearance changes to update fallback colors.
        // No deinit needed — this singleton lives for the app's lifetime.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Re-read all theme colors from the current ghostty config.
    func refresh() {
        loadFromConfig()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Appearance-aware default background: dark in dark mode, light in light mode.
    private static func defaultBackground() -> NSColor {
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .black : .white
    }

    /// Appearance-aware default foreground: white in dark mode, black in light mode.
    private static func defaultForeground() -> NSColor {
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? .white : .black
    }

    private func loadFromConfig() {
        let snapshot = GhosttyConfigController.shared.themeSnapshot()

        backgroundColor = snapshot.background.flatMap { NSColor(hexString: $0) }
            ?? GhosttyThemeProvider.defaultBackground()
        foregroundColor = snapshot.foreground.flatMap { NSColor(hexString: $0) }
            ?? GhosttyThemeProvider.defaultForeground()
        backgroundOpacity = snapshot.backgroundOpacity
        splitDividerColor = snapshot.splitDividerColor.flatMap { NSColor(hexString: $0) }
        unfocusedSplitFill = snapshot.unfocusedSplitFill.flatMap { NSColor(hexString: $0) }
        unfocusedSplitOpacity = snapshot.unfocusedSplitOpacity
    }
}
