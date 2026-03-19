@preconcurrency import ObjectiveC
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
    var onRenameTab: ((UUID, String) -> Void)?

    private var tabButtons: [TabButton] = []
    private var addButton: NSButton?
    private var renamingTabID: UUID?
    nonisolated(unsafe) var themeObserver: NSObjectProtocol?

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
        MainActor.assumeIsolated { setup() }
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
            MainActor.assumeIsolated { self?.applyTheme() }
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
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }

        if let addButton, addButton.frame.contains(point) {
            return addButton
        }

        for button in tabButtons.reversed() {
            let buttonPoint = convert(point, to: button)
            if let hit = button.hitTest(buttonPoint) {
                return hit
            }
        }

        guard let window else { return self }
        let windowPoint = superview?.convert(point, to: nil) ?? point
        let threshold: CGFloat = 5
        if windowPoint.x >= window.frame.width - threshold { return nil }
        if windowPoint.y < threshold && windowPoint.x >= window.frame.width - 15 { return nil }
        return self
    }

    private func rebuild() {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        addButton?.removeFromSuperview()

        if let renamingTabID, tabs.contains(where: { $0.id == renamingTabID }) == false {
            self.renamingTabID = nil
        }

        let theme = GhosttyThemeProvider.shared
        let height = DesignTokens.Layout.tabBarHeight

        for (index, tab) in tabs.enumerated() {
            let button = TabButton(
                tabID: tab.id,
                frame: NSRect(x: 0, y: 0, width: 100, height: height),
                title: tab.title,
                isActive: tab.isActive,
                isRenaming: renamingTabID == tab.id,
                showClose: tabs.count > 1,
                hasNotification: tab.hasNotification,
                theme: theme
            )
            button.onSelect = { [weak self] in self?.onSelectTab?(index) }
            button.onClose = { [weak self] in self?.onCloseTab?(index) }
            button.onBeginRename = { [weak self] in
                self?.beginRenamingTab(id: tab.id, index: index)
            }
            button.onCommitRename = { [weak self] title in
                self?.commitRenameTab(id: tab.id, title: title)
            }
            button.onCancelRename = { [weak self] in
                self?.cancelRenameTab(id: tab.id)
            }
            addSubview(button)
            tabButtons.append(button)
        }

        let plusBtn = HoverTintButton(
            frame: .zero,
            normalColor: theme.foregroundColor.withAlphaComponent(0.64),
            hoverColor: theme.foregroundColor.withAlphaComponent(0.5)
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
        window?.makeFirstResponder(nil)
        onAddTab?()
    }

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

    override func draw(_ dirtyRect: NSRect) {
        let theme = GhosttyThemeProvider.shared
        theme.backgroundColor.setFill()
        bounds.fill()

        let sep = theme.splitDividerColor ?? NSColor.separatorColor
        sep.withAlphaComponent(0.2).setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .tabGroup }
    override func accessibilityLabel() -> String? { "Tab bar" }

    private func beginRenamingTab(id: UUID, index: Int) {
        renamingTabID = id
        if tabs.indices.contains(index), tabs[index].isActive == false {
            onSelectTab?(index)
        } else {
            tabButtons.first(where: { $0.tabID == id })?.beginRenaming()
        }
    }

    private func commitRenameTab(id: UUID, title: String) {
        renamingTabID = nil
        tabButtons.first(where: { $0.tabID == id })?.endRenaming()

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            onRenameTab?(id, trimmed)
        }
    }

    private func cancelRenameTab(id: UUID) {
        guard renamingTabID == id else { return }
        renamingTabID = nil
        tabButtons.first(where: { $0.tabID == id })?.endRenaming()
    }
}

final class TabRenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private var didFinishEditing = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = true
        isSelectable = true
        isBordered = false
        isBezeled = false
        drawsBackground = false
        backgroundColor = .clear
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        delegate = self
        target = self
        action = #selector(commitFromAction)
    }

    required init?(coder: NSCoder) { fatalError() }

    func activate(in window: NSWindow?) {
        guard let window, self.window === window else { return }
        didFinishEditing = false
        window.makeFirstResponder(self)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectedRange = NSRange(
                location: 0,
                length: (self.stringValue as NSString).length
            )
        }
    }

    func commitEditing() {
        finishEditing(commitTitle: currentEditingTitle())
    }

    func cancelEditing() {
        finishEditing(cancel: true)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            finishEditing(commitTitle: textView.string)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditing()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitEditing()
    }

    @objc private func commitFromAction() {
        commitEditing()
    }

    private func currentEditingTitle() -> String {
        if let editorText = currentEditor()?.string {
            return editorText
        }
        validateEditing()
        return stringValue
    }

    private func finishEditing(commitTitle: String? = nil, cancel: Bool = false) {
        guard didFinishEditing == false else { return }
        let resolvedTitle = commitTitle ?? currentEditingTitle()
        didFinishEditing = true
        window?.endEditing(for: self)

        if cancel {
            onCancel?()
        } else {
            onCommit?(resolvedTitle)
        }
    }
}

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

    let tabID: UUID

    var onSelect: (() -> Void)?
    var onClose: (() -> Void)?
    var onBeginRename: (() -> Void)?
    var onCommitRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    private let titleLabel: NSTextField
    private let renameField: TabRenameField
    private let closeButton: NSButton
    private let isActive: Bool
    private let showsCloseButton: Bool
    private let hasNotification: Bool
    private var isRenaming: Bool
    private var isHovering = false
    private var didActivateRenameField = false
    private var trackingArea: NSTrackingArea?

    init(
        tabID: UUID,
        frame: NSRect,
        title: String,
        isActive: Bool,
        isRenaming: Bool,
        showClose: Bool,
        hasNotification: Bool,
        theme: GhosttyThemeProvider
    ) {
        self.tabID = tabID
        self.isActive = isActive
        self.showsCloseButton = showClose
        self.isRenaming = isRenaming
        self.hasNotification = hasNotification

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: DesignTokens.Font.caption, weight: isActive ? .semibold : .regular)
        titleLabel.textColor = theme.foregroundColor.withAlphaComponent(
            isActive ? DesignTokens.TextOpacity.primary : DesignTokens.TextOpacity.secondary
        )
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
        closeButton.isHidden = !showClose || isRenaming

        renameField = TabRenameField(frame: .zero)
        renameField.stringValue = title
        renameField.font = titleLabel.font
        renameField.textColor = titleLabel.textColor
        renameField.placeholderString = "Tab"

        super.init(frame: frame)

        addSubview(titleLabel)
        titleLabel.isHidden = isRenaming
        renameField.isHidden = !isRenaming
        renameField.onCommit = { [weak self] title in
            self?.onCommitRename?(title)
        }
        renameField.onCancel = { [weak self] in
            self?.onCancelRename?()
        }
        addSubview(renameField)
        addSubview(closeButton)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        let closeSize = Metrics.closeSize
        let padding = Metrics.horizontalPadding
        let touchTarget = DesignTokens.Interaction.minTouchTarget
        closeButton.frame = NSRect(
            x: bounds.width - touchTarget - padding + (touchTarget - closeSize) / 2,
            y: (bounds.height - touchTarget) / 2,
            width: touchTarget,
            height: touchTarget
        )
        titleLabel.frame = NSRect(
            x: padding,
            y: (bounds.height - Metrics.titleHeight) / 2,
            width: bounds.width - padding * 2 - (closeButton.isHidden ? 0 : touchTarget + Metrics.closeGap),
            height: Metrics.titleHeight
        )
        renameField.frame = titleLabel.frame.insetBy(dx: -1, dy: -2)
        if isRenaming {
            activateRenameFieldIfNeeded()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }

        if renameField.isHidden == false {
            let renamePoint = convert(point, to: renameField)
            if renameField.bounds.contains(renamePoint) {
                return renameField
            }
        }

        if !closeButton.isHidden {
            let closePoint = convert(point, to: closeButton)
            if closeButton.bounds.contains(closePoint) {
                return closeButton
            }
        }

        return self
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
        if isRenaming == false {
            window?.makeFirstResponder(nil)
        }
        if isRenaming {
            onSelect?()
        } else if event.clickCount >= 2 {
            onBeginRename?()
        } else {
            onSelect?()
        }
    }

    @objc private func closeClicked() {
        window?.makeFirstResponder(nil)
        onClose?()
    }

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
        titleLabel.textColor = theme.foregroundColor.withAlphaComponent(
            isActive ? DesignTokens.TextOpacity.primary : DesignTokens.TextOpacity.secondary
        )
        renameField.textColor = titleLabel.textColor
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activateRenameFieldIfNeeded()
    }

    private func activateRenameFieldIfNeeded() {
        guard isRenaming, didActivateRenameField == false else { return }
        didActivateRenameField = true
        renameField.activate(in: window)
    }

    func beginRenaming() {
        guard isRenaming == false else { return }
        isRenaming = true
        didActivateRenameField = false
        renameField.stringValue = titleLabel.stringValue
        titleLabel.isHidden = true
        renameField.isHidden = false
        closeButton.isHidden = true
        needsLayout = true
        layoutSubtreeIfNeeded()
        activateRenameFieldIfNeeded()
    }

    func endRenaming() {
        guard isRenaming else { return }
        isRenaming = false
        didActivateRenameField = false
        renameField.isHidden = true
        titleLabel.isHidden = false
        closeButton.isHidden = !showsCloseButton
        needsLayout = true
    }
}
