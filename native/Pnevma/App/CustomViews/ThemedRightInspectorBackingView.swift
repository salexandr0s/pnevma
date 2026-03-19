@preconcurrency import ObjectiveC
import Cocoa

final class ThemedRightInspectorBackingView: NSView {
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?
    nonisolated(unsafe) var tintObserver: NSObjectProtocol?
    private let leftSeparator = NSView()
    private let topSeparator = NSView()
    private let showsTopSeparator: Bool

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }
        // point is in the superview's coordinate system; convert correctly to window coords
        let windowPoint = superview?.convert(point, to: nil) ?? point
        let threshold: CGFloat = 5
        // Bottom edge — allow window resize handle to work
        if windowPoint.y < threshold { return nil }
        // Right edge — allow window resize handle to work
        if windowPoint.x >= window.frame.width - threshold { return nil }
        // Bottom-right corner
        if windowPoint.y < threshold && windowPoint.x >= window.frame.width - 15 { return nil }
        return super.hitTest(point)
    }

    /// Accept clicks even when the window is not key so that the first click
    /// both activates the window and forwards the event to SwiftUI buttons.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame frameRect: NSRect = .zero, showsTopSeparator: Bool = false) {
        self.showsTopSeparator = showsTopSeparator
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isOpaque = true
        layer?.masksToBounds = true

        leftSeparator.wantsLayer = true
        leftSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leftSeparator)
        NSLayoutConstraint.activate([
            leftSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            leftSeparator.topAnchor.constraint(equalTo: topAnchor),
            leftSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            leftSeparator.widthAnchor.constraint(equalToConstant: DesignTokens.Layout.dividerWidth),
        ])

        if showsTopSeparator {
            topSeparator.wantsLayer = true
            topSeparator.translatesAutoresizingMaskIntoConstraints = false
            addSubview(topSeparator)
            NSLayoutConstraint.activate([
                topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
                topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
                topSeparator.topAnchor.constraint(equalTo: topAnchor),
                topSeparator.heightAnchor.constraint(equalToConstant: DesignTokens.Layout.dividerWidth),
            ])
        }

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
        let theme = GhosttyThemeProvider.shared
        let bg = theme.backgroundColor
        let offset = RightInspectorPreferences.backgroundOffset
        if offset == 0 {
            bg.setFill()
        } else {
            bg.blended(withFraction: offset, of: .white)?.setFill() ?? bg.setFill()
        }
        bounds.fill()
    }

    private func updateBackgroundColor() {
        let theme = GhosttyThemeProvider.shared
        let bg = theme.backgroundColor
        let offset = RightInspectorPreferences.backgroundOffset
        let resolved: NSColor
        if offset == 0 {
            resolved = bg
        } else {
            resolved = bg.blended(withFraction: offset, of: .white) ?? bg
        }
        layer?.backgroundColor = resolved.cgColor
        let separatorColor = (theme.splitDividerColor ?? NSColor.separatorColor).cgColor
        leftSeparator.layer?.backgroundColor = separatorColor
        if showsTopSeparator {
            topSeparator.layer?.backgroundColor = separatorColor
        }
        needsDisplay = true
    }
}
