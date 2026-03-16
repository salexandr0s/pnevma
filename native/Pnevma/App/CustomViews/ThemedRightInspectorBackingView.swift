import Cocoa

final class ThemedRightInspectorBackingView: NSView {
    private var themeObserver: NSObjectProtocol?
    private var tintObserver: NSObjectProtocol?
    private let leftSeparator = NSView()

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }
        let windowPoint = convert(point, to: nil)
        let threshold: CGFloat = 5
        // Right edge
        if windowPoint.x > window.frame.width - threshold { return nil }
        // Bottom-right corner
        if windowPoint.y < threshold && windowPoint.x > window.frame.width - 15 { return nil }
        return super.hitTest(point)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
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

        updateBackgroundColor()
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateBackgroundColor()
        }
        tintObserver = NotificationCenter.default.addObserver(
            forName: .backgroundTintDidChange,
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
        leftSeparator.layer?.backgroundColor = (theme.splitDividerColor ?? NSColor.separatorColor).cgColor
        needsDisplay = true
    }
}
