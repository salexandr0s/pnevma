import Cocoa

/// A subtle 1pt separator line that follows the ghostty split divider color.
final class ThemedSeparatorView: NSView {
    enum Axis { case horizontal, vertical }
    private let axis: Axis
    private var themeObserver: NSObjectProtocol?

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
            self?.updateColor()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    private func updateColor() {
        let theme = GhosttyThemeProvider.shared
        layer?.backgroundColor = (theme.splitDividerColor ?? NSColor.separatorColor).cgColor
    }
}
