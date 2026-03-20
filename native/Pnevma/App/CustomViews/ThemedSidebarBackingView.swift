@preconcurrency import ObjectiveC
import Cocoa

/// Container for the tool dock NSHostingView that passes through mouse
/// events near the bottom and bottom-right window edges so the resize
/// handles remain accessible.
final class ToolDockContainerView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }
        let windowPoint = superview?.convert(point, to: nil) ?? point
        let threshold: CGFloat = 5
        let cornerSize: CGFloat = 15
        // Bottom edge
        if windowPoint.y < threshold { return nil }
        // Right edge — let NSThemeFrame handle horizontal resize
        if windowPoint.x >= window.frame.width - threshold { return nil }
        // Bottom-left corner
        if windowPoint.y < cornerSize && windowPoint.x < cornerSize { return nil }
        // Bottom-right corner
        if windowPoint.y < cornerSize && windowPoint.x >= window.frame.width - cornerSize { return nil }
        return super.hitTest(point)
    }
}

/// Sidebar backing view that keeps the shell in a native system surface
/// while allowing a subtle terminal-derived tint.
final class ThemedSidebarBackingView: NSView {
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) var tintObserver: NSObjectProtocol?
    private let rightSeparator = NSView()

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard window != nil else { return super.hitTest(point) }
        let windowPoint = superview?.convert(point, to: nil) ?? point
        let threshold: CGFloat = 5
        // Left edge
        if windowPoint.x < threshold { return nil }
        // Bottom-left corner
        if windowPoint.y < threshold && windowPoint.x < 15 { return nil }
        return super.hitTest(point)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = true
        layer?.masksToBounds = true

        // Right-edge separator matching ghostty split dividers
        rightSeparator.wantsLayer = true
        rightSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rightSeparator)
        NSLayoutConstraint.activate([
            rightSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightSeparator.topAnchor.constraint(equalTo: topAnchor),
            rightSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightSeparator.widthAnchor.constraint(equalToConstant: DesignTokens.Layout.dividerWidth),
        ])

        updateBackgroundColor()
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateBackgroundColor() }
        }
        tintObserver = NotificationCenter.default.addObserver(
            forName: .backgroundTintDidChange,
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
        if let tintObserver {
            NotificationCenter.default.removeObserver(tintObserver)
        }
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let resolved = ChromeSurfaceStyle.sidebar.resolvedColor(
            themeColor: GhosttyThemeProvider.shared.backgroundColor,
            tintAmount: SidebarPreferences.backgroundOffset
        )
        resolved.setFill()
        bounds.fill()
    }

    private func updateBackgroundColor() {
        let resolved = ChromeSurfaceStyle.sidebar.resolvedColor(
            themeColor: GhosttyThemeProvider.shared.backgroundColor,
            tintAmount: SidebarPreferences.backgroundOffset
        )
        layer?.backgroundColor = resolved.cgColor
        rightSeparator.layer?.backgroundColor = ChromeSurfaceStyle.sidebar.separatorColor.cgColor
        needsDisplay = true
    }
}
