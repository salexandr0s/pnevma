import Cocoa

/// Horizontal tab bar that sits above the content area.
/// Each tab represents a terminal/pane layout within the active workspace.
/// Hidden when there is only one tab.
final class TabBarView: NSView {

    struct Tab {
        let id: UUID
        var title: String
        var isActive: Bool
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

    private static let addButtonWidth: CGFloat = 24
    private static let addButtonGap: CGFloat = 4
    private static let maxTabWidth: CGFloat = 180
    private static let minTabWidth: CGFloat = 80

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
            for btn in self?.tabButtons ?? [] { btn.needsDisplay = true }
        }
        applyTheme()
    }

    private func applyTheme() {
        layer?.backgroundColor = GhosttyThemeProvider.shared.backgroundColor.cgColor
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
                theme: theme
            )
            button.onSelect = { [weak self] in self?.onSelectTab?(index) }
            button.onClose = { [weak self] in self?.onCloseTab?(index) }
            addSubview(button)
            tabButtons.append(button)
        }

        // "+" button
        let plusBtn = NSButton(frame: .zero)
        plusBtn.bezelStyle = .inline
        plusBtn.isBordered = false
        plusBtn.title = "+"
        plusBtn.font = .systemFont(ofSize: 14, weight: .light)
        plusBtn.contentTintColor = theme.foregroundColor.withAlphaComponent(0.5)
        plusBtn.target = self
        plusBtn.action = #selector(addButtonClicked)
        plusBtn.setAccessibilityLabel("New tab")
        addSubview(plusBtn)
        addButton = plusBtn

        repositionButtons()
    }

    @objc private func addButtonClicked() {
        onAddTab?()
    }

    // MARK: - Layout (frame updates only)

    override func layout() {
        super.layout()
        repositionButtons()
    }

    /// Reposition existing buttons without destroying/recreating them.
    private func repositionButtons() {
        guard !tabButtons.isEmpty else { return }
        let height = DesignTokens.Layout.tabBarHeight
        let reservedWidth = Self.addButtonWidth + Self.addButtonGap
        let tabWidth = min(Self.maxTabWidth, max(Self.minTabWidth, (bounds.width - reservedWidth) / CGFloat(tabs.count)))

        var x: CGFloat = 0
        for button in tabButtons {
            button.frame = NSRect(x: x, y: 0, width: tabWidth, height: height)
            x += tabWidth
        }
        addButton?.frame = NSRect(x: x + Self.addButtonGap, y: 0, width: Self.addButtonWidth, height: height)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        GhosttyThemeProvider.shared.backgroundColor.setFill()
        bounds.fill()
        // Bottom border
        let borderColor = GhosttyThemeProvider.shared.splitDividerColor ?? NSColor.separatorColor
        borderColor.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: DesignTokens.Layout.tabBarHeight)
    }

    // MARK: - Accessibility
    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { "Tab bar" }
}

// MARK: - TabButton

private final class TabButton: NSView {

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?

    private let titleLabel: NSTextField
    private let closeButton: NSButton
    private let isActive: Bool
    private var isHovering = false
    private var trackingArea: NSTrackingArea?
    private weak var theme: GhosttyThemeProvider?

    init(frame: NSRect, title: String, isActive: Bool, showClose: Bool, theme: GhosttyThemeProvider) {
        self.isActive = isActive
        self.theme = theme

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 11, weight: isActive ? .medium : .regular)
        titleLabel.textColor = theme.foregroundColor.withAlphaComponent(isActive ? 0.9 : 0.5)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true

        closeButton = NSButton(frame: .zero)
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = theme.foregroundColor.withAlphaComponent(0.4)
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
        let closeSize: CGFloat = 16
        let padding: CGFloat = 8
        closeButton.frame = NSRect(
            x: bounds.width - closeSize - padding,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )
        titleLabel.frame = NSRect(
            x: padding,
            y: (bounds.height - 16) / 2,
            width: bounds.width - padding * 2 - (closeButton.isHidden ? 0 : closeSize + 4),
            height: 16
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let theme else { return }
        if isActive {
            let activeColor = theme.foregroundColor.withAlphaComponent(0.08)
            activeColor.setFill()
            bounds.fill()
            // Bottom highlight for active tab
            theme.foregroundColor.withAlphaComponent(0.3).setFill()
            NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
        } else if isHovering {
            theme.foregroundColor.withAlphaComponent(0.04).setFill()
            bounds.fill()
        }
        // Right separator
        let sepColor = theme.splitDividerColor ?? NSColor.separatorColor
        sepColor.withAlphaComponent(0.3).setFill()
        NSRect(x: bounds.width - 1, y: 4, width: 1, height: bounds.height - 8).fill()
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
        closeButton.contentTintColor = theme?.foregroundColor.withAlphaComponent(0.6)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        closeButton.contentTintColor = theme?.foregroundColor.withAlphaComponent(0.4)
        needsDisplay = true
    }
}
