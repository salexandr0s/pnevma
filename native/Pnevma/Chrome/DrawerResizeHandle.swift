import AppKit
import SwiftUI

struct DrawerResizeHandle: NSViewRepresentable {
    let currentHeight: CGFloat
    let availableHeight: CGFloat
    let onHeightChanged: (CGFloat) -> Void

    func makeNSView(context: Context) -> DrawerResizeHandleView {
        let view = DrawerResizeHandleView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: DrawerResizeHandleView, context: Context) {
        nsView.currentHeight = currentHeight
        nsView.availableHeight = availableHeight
        nsView.onHeightChanged = onHeightChanged
    }
}

final class DrawerResizeHandleView: NSView {
    var currentHeight: CGFloat = 0
    var availableHeight: CGFloat = 0
    var onHeightChanged: ((CGFloat) -> Void)?

    private var trackingAreaRef: NSTrackingArea?
    private var isHovering = false {
        didSet { needsDisplay = true }
    }
    private var isDragging = false {
        didSet {
            if oldValue != isDragging {
                needsDisplay = true
                discardCursorRects()
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    private var dragHeight: CGFloat = 0
    private var lastWindowY: CGFloat = 0

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: DrawerSizing.resizeHandleHeight)
    }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityElement(true)
        setAccessibilityIdentifier("bottom.drawer.resize")
        setAccessibilityLabel("Resize drawer")
        setAccessibilityHelp("Drag to resize the bottom drawer.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let capsuleSize = NSSize(width: 46, height: 5)
        let capsuleOrigin = NSPoint(
            x: (bounds.width - capsuleSize.width) / 2,
            y: (bounds.height - capsuleSize.height) / 2
        )
        let capsuleRect = NSRect(origin: capsuleOrigin, size: capsuleSize)
        let capsule = NSBezierPath(
            roundedRect: capsuleRect,
            xRadius: capsuleSize.height / 2,
            yRadius: capsuleSize.height / 2
        )

        let fillOpacity: CGFloat
        if isDragging {
            fillOpacity = 0.82
        } else if isHovering {
            fillOpacity = 0.7
        } else {
            fillOpacity = 0.55
        }
        NSColor.secondaryLabelColor.withAlphaComponent(fillOpacity).setFill()
        capsule.fill()
    }

    override func resetCursorRects() {
        let cursor = isDragging
            ? AppCursor.cursor(for: .dragActive)
            : AppCursor.cursor(for: .dragIdle)
        addCursorRect(bounds, cursor: cursor)
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
        dragHeight = currentHeight
        lastWindowY = event.locationInWindow.y
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }

        let currentWindowY = event.locationInWindow.y
        let delta = currentWindowY - lastWindowY
        lastWindowY = currentWindowY

        let nextHeight = DrawerSizing.clamp(
            dragHeight + delta,
            availableHeight: availableHeight
        )
        guard abs(nextHeight - dragHeight) > 0.5 else { return }

        dragHeight = nextHeight
        onHeightChanged?(nextHeight)
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        isHovering = bounds.contains(convert(event.locationInWindow, from: nil))
    }
}
