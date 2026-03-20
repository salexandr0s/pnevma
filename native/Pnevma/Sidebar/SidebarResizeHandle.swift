import AppKit
import SwiftUI

struct SidebarResizeHandle: NSViewRepresentable {
    let onResize: (CGFloat) -> Void

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        let view = SidebarResizeHandleView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {
        nsView.onResize = onResize
    }
}

final class SidebarResizeHandleView: NSView {
    var onResize: ((CGFloat) -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false {
        didSet { updateHighlight() }
    }
    private var isDragging = false {
        didSet { updateHighlight() }
    }
    private var lastWindowX: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityIdentifier("sidebar.resize")
        setAccessibilityLabel("Resize sidebar")
        setAccessibilityHelp("Drag left or right to resize the workspace sidebar.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: AppCursor.cursor(for: .horizontalResize))
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
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        guard !isDragging else { return }
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        isDragging = true
        lastWindowX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }

        let currentWindowX = event.locationInWindow.x
        let delta = currentWindowX - lastWindowX
        lastWindowX = currentWindowX

        guard abs(delta) > 0.5 else { return }
        onResize?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        isHovering = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    private func updateHighlight() {
        let alpha: CGFloat
        if isDragging {
            alpha = 0.18
        } else if isHovering {
            alpha = 0.12
        } else {
            alpha = 0
        }
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
    }
}
