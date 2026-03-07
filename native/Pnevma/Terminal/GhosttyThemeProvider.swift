import AppKit
import Combine

/// Reactive color provider that reads theme colors from the live ghostty config.
/// Other views observe published properties to stay in sync with the terminal theme.
@MainActor
final class GhosttyThemeProvider: ObservableObject {

    static let shared = GhosttyThemeProvider()

    @Published private(set) var backgroundColor: NSColor = .black
    @Published private(set) var foregroundColor: NSColor = .white
    @Published private(set) var backgroundOpacity: Double = 1.0
    @Published private(set) var splitDividerColor: NSColor?
    @Published private(set) var unfocusedSplitFill: NSColor?
    @Published private(set) var unfocusedSplitOpacity: Double = 0.85

    /// Notification posted when theme colors change.
    static let didChangeNotification = Notification.Name("GhosttyThemeProviderDidChange")

    private init() {
        loadFromConfig()
    }

    /// Re-read all theme colors from the current ghostty config.
    func refresh() {
        loadFromConfig()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func loadFromConfig() {
        let snapshot = GhosttyConfigController.shared.themeSnapshot()

        backgroundColor = snapshot.background.flatMap { NSColor(hexString: $0) } ?? .black
        foregroundColor = snapshot.foreground.flatMap { NSColor(hexString: $0) } ?? .white
        backgroundOpacity = snapshot.backgroundOpacity
        splitDividerColor = snapshot.splitDividerColor.flatMap { NSColor(hexString: $0) }
        unfocusedSplitFill = snapshot.unfocusedSplitFill.flatMap { NSColor(hexString: $0) }
        unfocusedSplitOpacity = snapshot.unfocusedSplitOpacity
    }
}
