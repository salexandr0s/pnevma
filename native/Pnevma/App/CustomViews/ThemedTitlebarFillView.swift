import Cocoa

/// Covers the titlebar area with the ghostty theme background so the
/// transparent titlebar matches the rest of the chrome instead of being clear.
final class ThemedTitlebarFillView: NSView {
    private var themeObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = true
        updateBackgroundColor()
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateBackgroundColor()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override var isOpaque: Bool { true }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        } else {
            super.mouseUp(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = GhosttyThemeProvider.shared
        theme.backgroundColor.withAlphaComponent(theme.backgroundOpacity).setFill()
        bounds.fill()
    }

    private func updateBackgroundColor() {
        let theme = GhosttyThemeProvider.shared
        layer?.backgroundColor = theme.backgroundColor.withAlphaComponent(theme.backgroundOpacity).cgColor
        needsDisplay = true
    }
}
