import Cocoa

/// A small capsule-shaped view with icon + text label, styled for titlebar use.
/// Handles its own click and hover — works in the titlebar because it's added
/// as a direct subview of windowContent (not nested in a container).
final class CapsuleButton: NSView {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private let label: String
    private let iconImage: NSImage?
    weak var target: AnyObject?
    var action: Selector?

    override var mouseDownCanMoveWindow: Bool { false }
    override var isFlipped: Bool { false }

    init(icon: String, label: String) {
        self.label = label
        self.iconImage = NSImage(
            systemSymbolName: icon,
            accessibilityDescription: label
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityLabel(label)
        toolTip = label
        NotificationCenter.default.addObserver(forName: GhosttyThemeProvider.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let iconWidth: CGFloat = iconImage != nil ? 14 : 0
        return NSSize(width: textSize.width + iconWidth + 16, height: textSize.height + 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)

        // Background
        GhosttyThemeProvider.shared.foregroundColor.withAlphaComponent(isHovering ? 0.12 : 0.06).setFill()
        path.fill()

        // Border
        GhosttyThemeProvider.shared.foregroundColor.withAlphaComponent(isHovering ? 0.2 : 0.1).setStroke()
        path.lineWidth = 0.5
        path.stroke()

        // Content
        let textColor: NSColor = isHovering ? .controlAccentColor : .secondaryLabelColor
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let textSize = (label as NSString).size(withAttributes: [.font: font])

        var x = (bounds.width - textSize.width - (iconImage != nil ? 14 : 0)) / 2

        if let img = iconImage {
            guard let tinted = img.copy() as? NSImage else { return }
            tinted.lockFocus()
            textColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let imgY = (bounds.height - 12) / 2
            tinted.draw(in: NSRect(x: x, y: imgY, width: 12, height: 12))
            x += 14
        }

        let textY = (bounds.height - textSize.height) / 2
        (label as NSString).draw(
            at: NSPoint(x: x, y: textY),
            withAttributes: [.font: font, .foregroundColor: textColor]
        )
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let action, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
    }
}
