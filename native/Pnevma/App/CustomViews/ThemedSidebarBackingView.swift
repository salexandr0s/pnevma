import Cocoa

/// Sidebar backing view that uses the ghostty theme background color
/// instead of the system NSVisualEffectView blur, so the sidebar matches
/// the terminal's color scheme.
final class ThemedSidebarBackingView: NSView {
    private var themeObserver: NSObjectProtocol?
    private let rightSeparator = NSView()

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

    override func draw(_ dirtyRect: NSRect) {
        let theme = GhosttyThemeProvider.shared
        let bg = theme.backgroundColor
        let offset = SidebarPreferences.backgroundOffset
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
        let offset = SidebarPreferences.backgroundOffset
        let resolved: NSColor
        if offset == 0 {
            resolved = bg
        } else {
            resolved = bg.blended(withFraction: offset, of: .white) ?? bg
        }
        layer?.backgroundColor = resolved.cgColor
        rightSeparator.layer?.backgroundColor = (theme.splitDividerColor ?? NSColor.separatorColor).cgColor
        needsDisplay = true
    }
}

final class ThemedRightInspectorBackingView: NSView {
    private var themeObserver: NSObjectProtocol?
    private let leftSeparator = NSView()

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
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
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

final class RightInspectorResizeHandleView: NSView {
    var onResize: ((CGFloat) -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityLabel("Resize right inspector")
        setAccessibilityHelp("Drag left or right to resize the project inspector.")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let trackingAreaRef = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingAreaRef)
        self.trackingAreaRef = trackingAreaRef
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        var lastX = event.locationInWindow.x
        while let nextEvent = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch nextEvent.type {
            case .leftMouseDragged:
                let currentX = nextEvent.locationInWindow.x
                onResize?(currentX - lastX)
                lastX = currentX
            case .leftMouseUp:
                return
            default:
                break
            }
        }
    }
}
