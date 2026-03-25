@preconcurrency import ObjectiveC
import Cocoa

final class TitlebarControlGroupView: NSView {
    private let stackView = NSStackView()
    private var separators: [NSView] = []
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?

    override var mouseDownCanMoveWindow: Bool { false }

    init(arrangedSubviews: [NSView], separatorAfterIndices: Set<Int> = []) {
        super.init(frame: .zero)
        setup(arrangedSubviews: arrangedSubviews, separatorAfterIndices: separatorAfterIndices)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: DesignTokens.Layout.titlebarGroupHeight)
    }

    private func setup(arrangedSubviews: [NSView], separatorAfterIndices: Set<Int>) {
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Layout.titlebarGroupCornerRadius
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stackView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            heightAnchor.constraint(equalToConstant: DesignTokens.Layout.titlebarGroupHeight),
        ])

        for (index, view) in arrangedSubviews.enumerated() {
            stackView.addArrangedSubview(view)
            if separatorAfterIndices.contains(index), index < arrangedSubviews.count - 1 {
                let separator = makeSeparator()
                separators.append(separator)
                stackView.addArrangedSubview(separator)
            }
        }

        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        applyTheme()
    }

    private func makeSeparator() -> NSView {
        let separator = NSView(frame: .zero)
        separator.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            separator.widthAnchor.constraint(equalToConstant: 1),
            separator.heightAnchor.constraint(equalToConstant: 12),
        ])
        return separator
    }

    private func applyTheme() {
        let theme = GhosttyThemeProvider.shared
        let tintAmount = Double(theme.backgroundOpacity) * 0.18
        let background = ChromeSurfaceStyle.toolbar.resolvedColor(
            themeColor: theme.backgroundColor,
            tintAmount: tintAmount
        )
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = theme.foregroundColor.withAlphaComponent(0.09).cgColor
        separators.forEach { separator in
            separator.wantsLayer = true
            separator.layer?.backgroundColor = theme.foregroundColor.withAlphaComponent(0.10).cgColor
        }
    }
}

final class TitlebarIconButton: NSButton {
    private let normalTintColor: NSColor
    private let hoverTintColor: NSColor
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isPressing = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    init(
        symbolName: String,
        accessibilityDescription: String,
        toolTip: String,
        symbolConfig: NSImage.SymbolConfiguration,
        hoverTintColor: NSColor? = nil
    ) {
        self.normalTintColor = .secondaryLabelColor
        self.hoverTintColor = hoverTintColor ?? .labelColor
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        isBordered = false
        focusRingType = .none
        bezelStyle = .inline
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(symbolConfig)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        self.toolTip = toolTip
        setAccessibilityLabel(accessibilityDescription)
        setAccessibilityHelp(toolTip)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override var intrinsicContentSize: NSSize {
        let side = DesignTokens.Layout.titlebarIconButtonSize
        return NSSize(width: side, height: side)
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
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
        isHovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressing = true
        updateAppearance()
        super.mouseDown(with: event)
        isPressing = false
        updateAppearance()
    }

    private func updateAppearance() {
        let tint: NSColor
        if !isEnabled {
            tint = .tertiaryLabelColor
        } else if isHovering || isPressing {
            tint = hoverTintColor
        } else {
            tint = normalTintColor
        }
        contentTintColor = tint

        let backgroundAlpha: CGFloat
        if !isEnabled {
            backgroundAlpha = 0
        } else if isPressing {
            backgroundAlpha = 0.12
        } else if isHovering {
            backgroundAlpha = 0.075
        } else {
            backgroundAlpha = 0
        }
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(backgroundAlpha).cgColor
    }
}

/// A compact titlebar action control with icon + label and optional menu affordance.
enum CapsuleButtonInteractionSegment: Equatable {
    case primary
    case menu
}

final class CapsuleButton: NSView {
    private var trackingArea: NSTrackingArea?
    private var isHovering = false
    private var isPressing = false
    private var pressedSegment: CapsuleButtonInteractionSegment?
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?
    private let label: String
    private let iconImage: NSImage?
    var onMenuRequested: ((CapsuleButton) -> Void)? {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var showsDropdownIndicator = false {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }
    var isEnabled = true {
        didSet { needsDisplay = true }
    }
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
        setAccessibilityHelp("Activates \(label)")
        toolTip = label
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    private var isSplitButton: Bool {
        showsDropdownIndicator && onMenuRequested != nil
    }

    private var menuSegmentWidth: CGFloat {
        isSplitButton ? 22 : 0
    }

    override var intrinsicContentSize: NSSize {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let iconWidth: CGFloat = iconImage != nil ? 16 : 0
        let indicatorWidth: CGFloat = showsDropdownIndicator ? (isSplitButton ? menuSegmentWidth : 12) : 0
        return NSSize(
            width: textSize.width + iconWidth + indicatorWidth + 24,
            height: DesignTokens.Layout.titlebarControlHeight
        )
    }

    var menuHitRect: NSRect {
        guard isSplitButton else { return .zero }
        return NSRect(
            x: bounds.maxX - menuSegmentWidth - 1,
            y: 1,
            width: menuSegmentWidth,
            height: bounds.height - 2
        )
    }

    var primaryHitRect: NSRect {
        guard isSplitButton else { return bounds.insetBy(dx: 1, dy: 1) }
        return NSRect(
            x: 1,
            y: 1,
            width: max(0, bounds.width - menuSegmentWidth - 2),
            height: bounds.height - 2
        )
    }

    func interactionSegment(at point: NSPoint) -> CapsuleButtonInteractionSegment {
        if isSplitButton && menuHitRect.contains(point) {
            return .menu
        }
        return .primary
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = GhosttyThemeProvider.shared
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            xRadius: 8,
            yRadius: 8
        )

        if isEnabled {
            let fillAlpha: CGFloat
            switch (isHovering, isPressing) {
            case (_, true):
                fillAlpha = 0.12
            case (true, _):
                fillAlpha = 0.075
            default:
                fillAlpha = 0
            }

            if fillAlpha > 0 {
                theme.foregroundColor.withAlphaComponent(fillAlpha).setFill()
                path.fill()
            }
        }

        let textColor: NSColor
        if !isEnabled {
            textColor = .tertiaryLabelColor
        } else if isHovering || isPressing {
            textColor = .labelColor
        } else {
            textColor = .secondaryLabelColor
        }
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        let indicatorWidth: CGFloat = showsDropdownIndicator && !isSplitButton ? 12 : 0
        let contentWidth = textSize.width + (iconImage != nil ? 16 : 0) + indicatorWidth
        let primaryBounds = primaryHitRect
        var x = floor(primaryBounds.midX - (contentWidth / 2))

        if let img = iconImage {
            guard let tinted = img.copy() as? NSImage else { return }
            tinted.lockFocus()
            textColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let imgY = floor((bounds.height - 12) / 2)
            tinted.draw(in: NSRect(x: x, y: imgY, width: 12, height: 12))
            x += 16
        }

        let textY = floor((bounds.height - textSize.height) / 2)
        (label as NSString).draw(
            at: NSPoint(x: x, y: textY),
            withAttributes: [.font: font, .foregroundColor: textColor]
        )

        if isSplitButton {
            let separatorX = floor(menuHitRect.minX)
            let separatorRect = NSRect(
                x: separatorX,
                y: floor((bounds.height - 12) / 2),
                width: 1,
                height: 12
            )
            theme.foregroundColor.withAlphaComponent(isEnabled ? 0.10 : 0.06).setFill()
            separatorRect.fill()
        }

        if showsDropdownIndicator,
           let chevron = NSImage(
               systemSymbolName: "chevron.down",
               accessibilityDescription: "Show menu"
           )?.withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)),
           let tinted = chevron.copy() as? NSImage {
            tinted.lockFocus()
            textColor.set()
            NSRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let chevronX: CGFloat
            if isSplitButton {
                chevronX = floor(menuHitRect.midX - 4)
            } else {
                chevronX = x + textSize.width + 4
            }
            let chevronY = floor((bounds.height - 8) / 2)
            tinted.draw(in: NSRect(x: chevronX, y: chevronY, width: 8, height: 8))
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        let segment = interactionSegment(at: point)
        pressedSegment = segment
        isPressing = true
        needsDisplay = true
        defer {
            pressedSegment = nil
            isPressing = false
            needsDisplay = true
        }

        if segment == .menu, let onMenuRequested {
            onMenuRequested(self)
            return
        }

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
        isPressing = false
        needsDisplay = true
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}

extension NSView {
    func toolbarAttachmentAnchorRect(
        widthRatio: CGFloat = 0.5,
        minWidth: CGFloat = 28,
        maxWidth: CGFloat = 56
    ) -> NSRect {
        layoutSubtreeIfNeeded()
        let anchorWidth = min(max(bounds.width * widthRatio, minWidth), maxWidth)
        return NSRect(
            x: floor(bounds.midX - (anchorWidth / 2)),
            y: -DesignTokens.Spacing.xs,
            width: anchorWidth,
            height: DesignTokens.Spacing.xs
        )
    }
}
