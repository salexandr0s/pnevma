@preconcurrency import ObjectiveC
import Cocoa

/// Covers the titlebar area with the ghostty theme background so the
/// transparent titlebar matches the rest of the chrome instead of being clear.
final class ThemedTitlebarFillView: NSView {
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?

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
            MainActor.assumeIsolated { self?.updateBackgroundColor() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override var isOpaque: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }
        let windowPoint = convert(point, to: nil)
        let threshold: CGFloat = 5
        // Top edge — let NSThemeFrame handle resize
        if windowPoint.y > window.frame.height - threshold { return nil }
        // Left edge
        if windowPoint.x < threshold { return nil }
        // Right edge
        if windowPoint.x > window.frame.width - threshold { return nil }
        // Top-left / top-right corners
        if windowPoint.y > window.frame.height - 15
            && (windowPoint.x < 15 || windowPoint.x > window.frame.width - 15) {
            return nil
        }
        return super.hitTest(point)
    }

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
