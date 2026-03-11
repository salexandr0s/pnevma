import Cocoa

/// Horizontal tab bar that sits directly above the content area.
/// Positioned by parent constraints to track the sidebar edge.
/// Hidden when there is only one tab.
final class TabBarView: NSView {

    struct Tab {
        let id: UUID
        var title: String
        var isActive: Bool
        var hasNotification: Bool = false
    }

    var tabs: [Tab] = [] {
        didSet { rebuild() }
    }

    var onSelectTab: ((Int) -> Void)?
    var onCloseTab: ((Int) -> Void)?
    var onAddTab: (() -> Void)?

    private var tabButtons: [TabButton] = []
    private var addButton: NSButton?
    private var themeObserver: NSObjectProtocol?

    private static let addButtonWidth: CGFloat = 20
    private static let addButtonGap: CGFloat = 4
    private static let maxTabWidth: CGFloat = 168
    private static let minTabWidth: CGFloat = 76
    private static let tabPadding: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    private func setup() {
        wantsLayer = true
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyTheme()
        }
        applyTheme()
    }

    private func applyTheme() {
        let theme = GhosttyThemeProvider.shared
        layer?.backgroundColor = theme.backgroundColor.cgColor
        addButton?.contentTintColor = theme.foregroundColor.withAlphaComponent(0.64)
        for button in tabButtons {
            button.applyTheme(theme)
        }
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    // MARK: - Rebuild (only on data change)

    private func rebuild() {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        addButton?.removeFromSuperview()

        let theme = GhosttyThemeProvider.shared
        let height = DesignTokens.Layout.tabBarHeight

        for (index, tab) in tabs.enumerated() {
            let button = TabButton(
                frame: NSRect(x: 0, y: 0, width: 100, height: height),
                title: tab.title,
                isActive: tab.isActive,
                showClose: tabs.count > 1,
                hasNotification: tab.hasNotification,
                theme: theme
            )
            button.onSelect = { [weak self] in self?.onSelectTab?(index) }
            button.onClose = { [weak self] in self?.onCloseTab?(index) }
            addSubview(button)
            tabButtons.append(button)
        }

        // "+" button — green on hover, matching sidebar
        let plusBtn = HoverTintButton(
            frame: .zero,
            normalColor: theme.foregroundColor.withAlphaComponent(0.64),
            hoverColor: .systemGreen
        )
        plusBtn.bezelStyle = .inline
        plusBtn.isBordered = false
        plusBtn.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "New tab"
        )?.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        plusBtn.imageScaling = .scaleProportionallyDown
        plusBtn.contentTintColor = theme.foregroundColor.withAlphaComponent(0.64)
        plusBtn.target = self
        plusBtn.action = #selector(addButtonClicked)
        plusBtn.setAccessibilityLabel("New tab")
        addSubview(plusBtn)
        addButton = plusBtn

        needsLayout = true
    }

    @objc private func addButtonClicked() {
        onAddTab?()
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        repositionButtons()
    }

    private func repositionButtons() {
        guard !tabButtons.isEmpty else { return }
        let height = DesignTokens.Layout.tabBarHeight
        let reservedWidth = Self.addButtonWidth + Self.addButtonGap + Self.tabPadding * 2
        let tabWidth = min(Self.maxTabWidth, max(Self.minTabWidth, (bounds.width - reservedWidth) / CGFloat(tabs.count)))

        var x: CGFloat = Self.tabPadding
        for button in tabButtons {
            button.frame = NSRect(x: x, y: 0, width: tabWidth, height: height)
            x += tabWidth
        }
        addButton?.frame = NSRect(x: x + Self.addButtonGap, y: 0, width: Self.addButtonWidth, height: height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let theme = GhosttyThemeProvider.shared
        theme.backgroundColor.setFill()
        bounds.fill()

        // Bottom separator line
        let sep = theme.splitDividerColor ?? NSColor.separatorColor
        sep.withAlphaComponent(0.2).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    // MARK: - Accessibility
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { "Tab bar" }
}

// MARK: - TabButton

private final class TabButton: NSView {
    private enum Metrics {
        static let horizontalInset: CGFloat = 2
        static let verticalInset: CGFloat = 1
        static let cornerRadius: CGFloat = 4
        static let closeSize: CGFloat = 12
        static let horizontalPadding: CGFloat = 7
        static let closeGap: CGFloat = 4
        static let titleHeight: CGFloat = 14
    }

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel: NSTextField
    private let closeButton: NSButton
    private let isActive: Bool
    private let hasNotification: Bool
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, title: String, isActive: Bool, showClose: Bool, hasNotification: Bool, theme: GhosttyThemeProvider) {
        self.isActive = isActive
        self.hasNotification = hasNotification

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 10.5, weight: isActive ? .semibold : .regular)
        titleLabel.textColor = theme.foregroundColor.withAlphaComponent(isActive ? 0.92 : 0.56)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true

        let normalCloseAlpha: CGFloat = isActive ? 0.58 : 0.36
        closeButton = HoverTintButton(
            frame: .zero,
            normalColor: theme.foregroundColor.withAlphaComponent(normalCloseAlpha),
            hoverColor: .systemRed
        )
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close tab"
        )?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = theme.foregroundColor.withAlphaComponent(normalCloseAlpha)
        closeButton.setAccessibilityLabel("Close tab")
        closeButton.isHidden = !showClose

        super.init(frame: frame)

        addSubview(titleLabel)
        addSubview(closeButton)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let closeSize = Metrics.closeSize
        let padding = Metrics.horizontalPadding
        closeButton.frame = NSRect(
            x: bounds.width - closeSize - padding,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
        titleLabel.frame = NSRect(
            x: padding,
            y: (bounds.height - Metrics.titleHeight) / 2,
            width: bounds.width - padding * 2 - (closeButton.isHidden ? 0 : closeSize + Metrics.closeGap),
            height: Metrics.titleHeight
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = GhosttyThemeProvider.shared
        let tabBounds = bounds.insetBy(dx: Metrics.horizontalInset, dy: Metrics.verticalInset)
        let tabPath = NSBezierPath(
            roundedRect: tabBounds,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )

        if isActive {
            theme.foregroundColor.withAlphaComponent(0.08).setFill()
            tabPath.fill()

            let strokeColor = theme.splitDividerColor ?? theme.foregroundColor.withAlphaComponent(0.16)
            strokeColor.withAlphaComponent(0.55).setStroke()
            tabPath.lineWidth = 1
            tabPath.stroke()
        } else if isHovering {
            theme.foregroundColor.withAlphaComponent(0.04).setFill()
            tabPath.fill()
        }

        if hasNotification && !isActive {
            let dotSize: CGFloat = 6
            let dotX = min(titleLabel.frame.maxX + 4, bounds.width - Metrics.horizontalPadding - dotSize)
            let dotY = (bounds.height - dotSize) / 2
            let dotRect = NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)
            NSColor.systemOrange.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }

    @objc private func closeClicked() {
        onClose?()
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
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

    func applyTheme(_ theme: GhosttyThemeProvider) {
        titleLabel.textColor = theme.foregroundColor.withAlphaComponent(isActive ? 0.92 : 0.56)
        needsDisplay = true
    }
}
