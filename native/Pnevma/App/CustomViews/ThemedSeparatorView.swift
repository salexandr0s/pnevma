@preconcurrency import ObjectiveC
import Cocoa

/// A subtle 1pt separator line that follows the system chrome separator color.
final class ThemedSeparatorView: NSView {
    enum Axis { case horizontal, vertical }
    private let axis: Axis
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        updateColor()
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateColor() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    private func updateColor() {
        layer?.backgroundColor = ChromeSurfaceStyle.toolbar.separatorColor.cgColor
    }
}
