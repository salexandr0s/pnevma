import Cocoa

final class HoverTintButton: NSButton {
    private let normalColor: NSColor
    private let hoverColor: NSColor
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(frame: NSRect, normalColor: NSColor, hoverColor: NSColor) {
        self.normalColor = normalColor
        self.hoverColor = hoverColor
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
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
        contentTintColor = hoverColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = normalColor
    }
}
