@preconcurrency import ObjectiveC
import Cocoa

/// Horizontal tab bar that sits directly above the content area.
/// Positioned by parent constraints to track the sidebar edge.
/// Hidden when there is only one tab.
final class TabBarView: NSView {
    private enum DeferredClickAction {
        case addTab
        case selectTab(Int)
        case closeTab(Int)
        case beginRename(UUID, Int)
    }

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
    nonisolated(unsafe) private var renamingEventMonitor: Any?
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
        if let renamingEventMonitor {
            NSEvent.removeMonitor(renamingEventMonitor)
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
            if let buttonHit = button.interactiveHitView(at: buttonPoint) {
                return buttonHit
            }
        }

        guard let window else { return self }
        let windowPoint = convert(point, to: nil)
        let threshold: CGFloat = 5
        if windowPoint.x >= window.frame.width - threshold { return nil }
        if windowPoint.y < threshold && windowPoint.x >= window.frame.width - 15 { return nil }
        return self
    }

    // MARK: - Rebuild (only on data change)

    private func rebuild() {
        tabButtons.forEach { $0.removeFromSuperview() }
        tabButtons.removeAll()
        addButton?.removeFromSuperview()

        let theme = GhosttyThemeProvider.shared
        let height = DesignTokens.Layout.tabBarHeight

        for (index, tab) in tabs.enumerated() {
            let button = TabButton(
                tabID: tab.id,
                frame: NSRect(x: 0, y: 0, width: 100, height: height),
                title: tab.title,
                isActive: tab.isActive,
                showClose: tabs.count > 1,
                hasNotification: tab.hasNotification,
                theme: theme
            )
            button.onSelect = { [weak self] in self?.onSelectTab?(index) }
            button.onClose = { [weak self] in self?.onCloseTab?(index) }
            button.onBeginRename = { [weak self] in
                self?.beginRenamingTab(id: tab.id, index: index)
            }
            button.onRename = { [weak self] title in
                self?.endRenamingSession(for: tab.id)
                self?.onRenameTab?(tab.id, title)
            }
            button.onCancelRename = { [weak self] in
                self?.endRenamingSession(for: tab.id)
            }
            addSubview(button)
            tabButtons.append(button)
        }

        // "+" button — green on hover, matching sidebar
        let plusBtn = HoverTintButton(
            frame: .zero,
            normalColor: theme.foregroundColor.withAlphaComponent(0.64),
            hoverColor: GhosttyThemeProvider.shared.foregroundColor.withAlphaComponent(0.5)
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
        focusRenamingTabIfNeeded()
    }

    @objc private func addButtonClicked() {
        onAddTab?()
    }

    private func beginRenamingTab(id: UUID, index: Int) {
        renamingTabID = id
        installRenamingEventMonitorIfNeeded()
        if tabs.indices.contains(index), !tabs[index].isActive {
            onSelectTab?(index)
            DispatchQueue.main.async { [weak self] in
                self?.focusRenamingTabIfNeeded()
            }
        } else {
            focusRenamingTabIfNeeded()
        }
    }

    private func focusRenamingTabIfNeeded() {
        guard let renamingTabID else { return }
        guard let button = tabButtons.first(where: { $0.tabID == renamingTabID }) else { return }
        button.beginRenaming()
    }

    private func endRenamingSession(for tabID: UUID) {
        guard renamingTabID == tabID else { return }
        renamingTabID = nil
        removeRenamingEventMonitor()
    }

    private func deferredClickAction(at point: NSPoint, clickCount: Int) -> DeferredClickAction? {
        guard bounds.contains(point) else { return nil }

        if let addButton, addButton.frame.contains(point) {
            return .addTab
        }

        for (index, button) in tabButtons.enumerated().reversed() {
            let buttonPoint = convert(point, to: button)
            guard let interactionTarget = button.interactionTarget(at: buttonPoint) else { continue }
            switch interactionTarget {
            case .renameField:
                return nil
            case .closeButton:
                return .closeTab(index)
            case .titleSurface, .tabBody:
                if clickCount >= 2 {
                    return .beginRename(button.tabID, index)
                }
                return .selectTab(index)
            }
        }

        return nil
    }

    private func performDeferredClickAction(_ action: DeferredClickAction) {
        switch action {
        case .addTab:
            onAddTab?()
        case let .selectTab(index):
            onSelectTab?(index)
        case let .closeTab(index):
            onCloseTab?(index)
        case let .beginRename(tabID, index):
            beginRenamingTab(id: tabID, index: index)
        }
    }

    private func installRenamingEventMonitorIfNeeded() {
        guard renamingEventMonitor == nil else { return }
        renamingEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  let renamingTabID = self.renamingTabID,
                  let button = self.tabButtons.first(where: { $0.tabID == renamingTabID })
            else {
                return event
            }

            let pointInTabBar = self.convert(event.locationInWindow, from: nil)
            let renameFieldRect = button.renameFieldFrame(in: self)
            if renameFieldRect.contains(pointInTabBar) {
                return event
            }

            let deferredAction = self.deferredClickAction(at: pointInTabBar, clickCount: event.clickCount)
            let committedTitle = button.commitRenameForExternalInteraction()
            self.endRenamingSession(for: renamingTabID)

            guard let deferredAction else {
                if let committedTitle {
                    DispatchQueue.main.async { [weak self] in
                        self?.onRenameTab?(renamingTabID, committedTitle)
                    }
                }
                return event
            }
            DispatchQueue.main.async { [weak self] in
                if let committedTitle {
                    self?.onRenameTab?(renamingTabID, committedTitle)
                }
                self?.performDeferredClickAction(deferredAction)
            }
            return nil
        }
    }

    private func removeRenamingEventMonitor() {
        if let renamingEventMonitor {
            NSEvent.removeMonitor(renamingEventMonitor)
            self.renamingEventMonitor = nil
        }
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
private final class TabTitleHitView: NSView {
    var onSelect: (() -> Void)?
    var onBeginRename: (() -> Void)?
    private var pendingClick: (timestamp: TimeInterval, point: NSPoint)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let localPoint = convert(event.locationInWindow, from: nil)
        let isDoubleClick = event.clickCount >= 2 || {
            guard let pendingClick else { return false }
            let elapsed = event.timestamp - pendingClick.timestamp
            let distance = hypot(localPoint.x - pendingClick.point.x, localPoint.y - pendingClick.point.y)
            return elapsed <= NSEvent.doubleClickInterval && distance <= 6
        }()

        if isDoubleClick {
            pendingClick = nil
            onBeginRename?()
        } else {
            pendingClick = (event.timestamp, localPoint)
            onSelect?()
        }
    }
}

private final class TabButton: NSView {
    enum InteractionTarget {
        case renameField
        case closeButton
        case titleSurface
        case tabBody
    }

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
    var onRename: ((String) -> Void)?
    var onCancelRename: (() -> Void)?

    private let titleLabel: NSTextField
    private let titleHitView: TabTitleHitView
    private let renameField: NSTextField
    private let closeButton: NSButton
    private let isActive: Bool
    private let hasNotification: Bool
    private let showsCloseButton: Bool
    private var isHovering = false
    private var isRenaming = false
    private var hasActivatedRenameField = false
    private var trackingArea: NSTrackingArea?
    private var pendingClick: (timestamp: TimeInterval, point: NSPoint)?

    init(tabID: UUID, frame: NSRect, title: String, isActive: Bool, showClose: Bool, hasNotification: Bool, theme: GhosttyThemeProvider) {
        self.tabID = tabID
        self.isActive = isActive
        self.hasNotification = hasNotification
        self.showsCloseButton = showClose

        titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: DesignTokens.Font.caption, weight: isActive ? .semibold : .regular)
        titleLabel.textColor = theme.foregroundColor.withAlphaComponent(isActive ? DesignTokens.TextOpacity.primary : DesignTokens.TextOpacity.secondary)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true

        titleHitView = TabTitleHitView(frame: .zero)

        renameField = NSTextField(string: title)
        renameField.font = .systemFont(ofSize: DesignTokens.Font.caption, weight: .semibold)
        renameField.isBordered = false
        renameField.isBezeled = false
        renameField.drawsBackground = false
        renameField.focusRingType = .none
        renameField.isEditable = true
        renameField.isSelectable = true
        renameField.isHidden = true
        renameField.lineBreakMode = .byTruncatingTail
        renameField.textColor = theme.foregroundColor.withAlphaComponent(DesignTokens.TextOpacity.primary)

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
        addSubview(titleHitView)
        addSubview(renameField)
        addSubview(closeButton)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        renameField.delegate = self
        titleHitView.onSelect = { [weak self] in self?.onSelect?() }
        titleHitView.onBeginRename = { [weak self] in self?.onBeginRename?() }
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
        titleHitView.frame = titleLabel.frame
        renameField.frame = titleLabel.frame
    }

    func interactiveHitView(at point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }

        if isRenaming {
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

        if !titleHitView.isHidden {
            let titlePoint = convert(point, to: titleHitView)
            if titleHitView.bounds.contains(titlePoint) {
                return titleHitView
            }
        }

        return self
    }

    func interactionTarget(at point: NSPoint) -> InteractionTarget? {
        guard bounds.contains(point) else { return nil }

        if isRenaming {
            let renamePoint = convert(point, to: renameField)
            if renameField.bounds.contains(renamePoint) {
                return .renameField
            }
        }

        if !closeButton.isHidden {
            let closePoint = convert(point, to: closeButton)
            if closeButton.bounds.contains(closePoint) {
                return .closeButton
            }
        }

        if !titleHitView.isHidden {
            let titlePoint = convert(point, to: titleHitView)
            if titleHitView.bounds.contains(titlePoint) {
                return .titleSurface
            }
        }

        return .tabBody
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactiveHitView(at: point)
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
        let localPoint = convert(event.locationInWindow, from: nil)
        let isDoubleClick = event.clickCount >= 2 || {
            guard let pendingClick else { return false }
            let elapsed = event.timestamp - pendingClick.timestamp
            let distance = hypot(localPoint.x - pendingClick.point.x, localPoint.y - pendingClick.point.y)
            return elapsed <= NSEvent.doubleClickInterval && distance <= 6
        }()

        if isDoubleClick {
            pendingClick = nil
            onBeginRename?()
        } else {
            pendingClick = (event.timestamp, localPoint)
            onSelect?()
        }
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
        titleLabel.textColor = theme.foregroundColor.withAlphaComponent(isActive ? DesignTokens.TextOpacity.primary : DesignTokens.TextOpacity.secondary)
        renameField.textColor = theme.foregroundColor.withAlphaComponent(DesignTokens.TextOpacity.primary)
        needsDisplay = true
    }

    func beginRenaming() {
        guard !isRenaming else { return }
        isRenaming = true
        hasActivatedRenameField = false
        renameField.stringValue = titleLabel.stringValue
        titleLabel.isHidden = true
        titleHitView.isHidden = true
        renameField.isHidden = false
        closeButton.isHidden = true
        needsLayout = true

        DispatchQueue.main.async { [weak self] in
            self?.activateRenameFieldIfPossible()
        }
    }

    private func activateRenameFieldIfPossible() {
        guard isRenaming else { return }

        layoutSubtreeIfNeeded()

        if let window {
            _ = window.makeFirstResponder(renameField)
        }
        renameField.selectText(nil)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRenaming else { return }
            self.layoutSubtreeIfNeeded()
            if self.renameField.currentEditor() == nil {
                if let window {
                    _ = window.makeFirstResponder(self.renameField)
                }
                self.renameField.selectText(nil)
            }
            self.hasActivatedRenameField = self.renameField.currentEditor() != nil
        }
    }

    private func finishRenaming() {
        isRenaming = false
        hasActivatedRenameField = false
        titleLabel.isHidden = false
        titleHitView.isHidden = false
        renameField.isHidden = true
        closeButton.isHidden = !showsCloseButton
        needsLayout = true
    }

    private func commitRename() {
        guard isRenaming else { return }
        let trimmed = renameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancelRename()
            return
        }
        titleLabel.stringValue = trimmed
        finishRenaming()
        onRename?(trimmed)
    }

    private func cancelRename() {
        guard isRenaming else { return }
        renameField.stringValue = titleLabel.stringValue
        finishRenaming()
        onCancelRename?()
    }

    func renameFieldContains(_ point: NSPoint) -> Bool {
        guard isRenaming else { return false }
        let renamePoint = convert(point, to: renameField)
        return renameField.bounds.contains(renamePoint)
    }

    func renameFieldFrame(in ancestor: NSView) -> NSRect {
        ancestor.convert(renameField.bounds, from: renameField)
    }

    @discardableResult
    func commitRenameForExternalInteraction() -> String? {
        guard isRenaming else { return nil }
        let trimmed = renameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            renameField.stringValue = titleLabel.stringValue
            finishRenaming()
            if let window {
                _ = window.makeFirstResponder(nil)
            }
            return nil
        }
        titleLabel.stringValue = trimmed
        finishRenaming()
        if let window {
            _ = window.makeFirstResponder(nil)
        }
        return trimmed
    }

}

extension TabButton: NSTextFieldDelegate {
    func controlTextDidBeginEditing(_ obj: Notification) {
        if isRenaming {
            hasActivatedRenameField = true
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commitRename()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelRename()
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if isRenaming {
            guard hasActivatedRenameField else { return }
            commitRename()
        }
    }
}
