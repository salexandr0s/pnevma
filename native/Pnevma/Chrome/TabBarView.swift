import Cocoa

/// Horizontal tab bar that sits directly above the content area.
/// Positioned by parent constraints to track the sidebar edge.
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
    private static let addButtonGap: CGFloat = 6
    private static let maxTabWidth: CGFloat = 180
    private static let minTabWidth: CGFloat = 80
    private static let tabPadding: CGFloat = 8

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
        plusBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        plusBtn.imageScaling = .scaleProportionallyDown
        plusBtn.contentTintColor = theme.foregroundColor.withAlphaComponent(0.5)
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
        sep.withAlphaComponent(0.3).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
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

    init(frame: NSRect, title: String, isActive: Bool, showClose: Bool, theme: GhosttyThemeProvider) {
        self.isActive = isActive

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
        let theme = GhosttyThemeProvider.shared
        if isActive {
            // Subtle background highlight
            theme.foregroundColor.withAlphaComponent(0.06).setFill()
            bounds.fill()
            // Full-width bottom accent bar
            NSColor.controlAccentColor.withAlphaComponent(0.7).setFill()
            NSRect(x: 0, y: bounds.height - 2, width: bounds.width, height: 2).fill()
        } else if isHovering {
            theme.foregroundColor.withAlphaComponent(0.03).setFill()
            bounds.fill()
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
        closeButton.contentTintColor = GhosttyThemeProvider.shared.foregroundColor.withAlphaComponent(0.6)
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        closeButton.contentTintColor = GhosttyThemeProvider.shared.foregroundColor.withAlphaComponent(0.4)
        needsDisplay = true
    }
}
