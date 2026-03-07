import Cocoa

/// Hosts the pane split tree in the main window content area.
/// Manages pane view lifecycle, divider rendering, and keyboard shortcuts.
final class ContentAreaView: NSView {

    // MARK: - Properties

    private(set) var layoutEngine: PaneLayoutEngine

    /// All live pane views keyed by their PaneID.
    private var paneViews: [PaneID: NSView & PaneContent] = [:]
    private var dividerViews: [NSView] = []
    private var focusBorderView: NSView?

    /// Called when a pane is closed and the layout becomes empty.
    var onAllPanesClosed: (() -> Void)?

    /// Called when the active pane changes.
    var onActivePaneChanged: ((PaneID?) -> Void)?

    /// Called when a pane updates persisted metadata such as session attachment.
    var onPanePersistenceChanged: (() -> Void)?

    // MARK: - Init

    init(frame: NSRect, rootPaneView: NSView & PaneContent) {
        layoutEngine = PaneLayoutEngine(rootPaneID: rootPaneView.paneID)
        super.init(frame: frame)
        registerPaneView(rootPaneView)
        rootPaneView.activate()
        installClickMonitor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        removeClickMonitor()
    }

    /// Use flipped coordinate system (top-left origin) so vertical splits
    /// render correctly: first=top, second=bottom.
    override var isFlipped: Bool { true }

    // MARK: - Layout

    override func layout() {
        super.layout()
        repositionPanes()
        repositionDividers()
        updateFocusBorder()
    }

    /// Full relayout: reposition panes + rebuild dividers. For structural changes.
    private func relayout() {
        repositionPanes()
        rebuildDividers()
        updateFocusBorder()
    }

    /// Recompute and apply pane frames. Safe to call during drag.
    private func repositionPanes() {
        layoutEngine.layout(in: bounds)
        for (id, frame) in layoutEngine.paneFrames {
            if let view = paneViews[id] {
                view.frame = frame
                view.needsLayout = true
                view.needsDisplay = true
            }
        }
    }

    /// Tear down and recreate all divider views.
    private func rebuildDividers() {
        dividerViews.forEach { $0.removeFromSuperview() }
        dividerViews.removeAll()
        if let root = layoutEngine.root {
            createDividers(node: root, rect: bounds)
        }
    }

    /// Reposition existing divider views without creating/destroying any.
    private func repositionDividers() {
        var index = 0
        if let root = layoutEngine.root {
            repositionDividersInNode(root, rect: bounds, index: &index)
        }
    }

    private func repositionDividersInNode(_ node: SplitNode, rect: NSRect, index: inout Int) {
        guard case .split(let direction, let ratio, let first, let second) = node else { return }

        let dw = DesignTokens.Layout.dividerWidth
        let dividerRect: NSRect
        let firstRect: NSRect
        let secondRect: NSRect

        switch direction {
        case .horizontal:
            let fw = (rect.width - dw) * ratio
            dividerRect = NSRect(x: rect.minX + fw, y: rect.minY, width: dw, height: rect.height)
            firstRect = NSRect(x: rect.minX, y: rect.minY, width: fw, height: rect.height)
            secondRect = NSRect(x: rect.minX + fw + dw, y: rect.minY,
                                width: rect.width - fw - dw, height: rect.height)
        case .vertical:
            let fh = (rect.height - dw) * ratio
            let sh = rect.height - fh - dw
            firstRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: fh)
            dividerRect = NSRect(x: rect.minX, y: rect.minY + fh, width: rect.width, height: dw)
            secondRect = NSRect(x: rect.minX, y: rect.minY + fh + dw, width: rect.width, height: sh)
        }

        if index < dividerViews.count {
            dividerViews[index].frame = dividerRect
        }
        index += 1

        repositionDividersInNode(first, rect: firstRect, index: &index)
        repositionDividersInNode(second, rect: secondRect, index: &index)
    }

    private func createDividers(node: SplitNode, rect: NSRect) {
        guard case .split(let direction, let ratio, let first, let second) = node else { return }

        let dw = DesignTokens.Layout.dividerWidth
        let dividerRect: NSRect
        let firstRect: NSRect
        let secondRect: NSRect

        switch direction {
        case .horizontal:
            let fw = (rect.width - dw) * ratio
            dividerRect = NSRect(x: rect.minX + fw, y: rect.minY, width: dw, height: rect.height)
            firstRect = NSRect(x: rect.minX, y: rect.minY, width: fw, height: rect.height)
            secondRect = NSRect(x: rect.minX + fw + dw, y: rect.minY,
                                width: rect.width - fw - dw, height: rect.height)
        case .vertical:
            let fh = (rect.height - dw) * ratio
            let sh = rect.height - fh - dw
            // Flipped coordinates: first=top (lower Y), second=bottom (higher Y).
            firstRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: fh)
            dividerRect = NSRect(x: rect.minX, y: rect.minY + fh, width: rect.width, height: dw)
            secondRect = NSRect(x: rect.minX, y: rect.minY + fh + dw, width: rect.width, height: sh)
        }

        let divider = DividerView(frame: dividerRect, direction: direction)
        divider.onDrag = { [weak self] delta in
            guard let self = self else { return }
            let size = direction == .horizontal ? rect.width : rect.height
            guard size > 0 else { return }
            if let targetID = first.allPaneIDs.first {
                self.layoutEngine.resizeSplit(containing: targetID, delta: delta / size)
                self.repositionPanes()
                self.repositionDividers()
            }
        }
        addSubview(divider)
        dividerViews.append(divider)

        createDividers(node: first, rect: firstRect)
        createDividers(node: second, rect: secondRect)
    }

    // MARK: - Click-to-Focus

    private var clickMonitor: Any?

    private func installClickMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleClickToFocus(event)
            return event
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func handleClickToFocus(_ event: NSEvent) {
        guard let eventWindow = event.window, eventWindow == window else { return }
        let point = convert(event.locationInWindow, from: nil)
        for (id, view) in paneViews {
            if view.frame.contains(point), id != layoutEngine.activePaneID {
                focusPane(id)
                break
            }
        }
    }

    // MARK: - Pane Management

    private func registerPaneView(_ view: NSView & PaneContent) {
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = []
        addSubview(view)
        paneViews[view.paneID] = view
        if view.shouldPersist {
            layoutEngine.upsertPersistedPane(view.persistedPane())
        }
        if view.shouldPersist, let observablePane = view as? PanePersistenceObservable {
            observablePane.onPersistedStateChange = { [weak self] pane in
                self?.layoutEngine.upsertPersistedPane(pane)
                self?.onPanePersistenceChanged?()
            }
        }
    }

    /// Split the active pane. The new pane view is added to the layout.
    @discardableResult
    func splitActivePane(direction: SplitDirection, newPaneView: NSView & PaneContent) -> PaneID? {
        guard let activeID = layoutEngine.activePaneID else { return nil }

        let newID = newPaneView.paneID
        guard layoutEngine.splitPane(activeID, direction: direction, newPaneID: newID) != nil else {
            return nil
        }

        registerPaneView(newPaneView)
        paneViews[activeID]?.deactivate()
        newPaneView.activate()
        onActivePaneChanged?(newID)
        relayout()
        return newID
    }

    /// Replace the active pane's view without changing the tree structure.
    @discardableResult
    func replaceActivePane(with newPaneView: NSView & PaneContent) -> PaneID? {
        guard let activeID = layoutEngine.activePaneID else { return nil }

        let newID = newPaneView.paneID
        guard layoutEngine.replacePane(activeID, with: newID) else { return nil }

        if let oldView = paneViews.removeValue(forKey: activeID) {
            oldView.dispose()
            oldView.removeFromSuperview()
        }
        layoutEngine.removePersistedPane(activeID)

        registerPaneView(newPaneView)
        newPaneView.activate()
        onActivePaneChanged?(newID)
        relayout()
        return newID
    }

    /// Close the given pane.
    func closePane(_ paneID: PaneID) {
        guard layoutEngine.closePane(paneID) else { return }

        if let view = paneViews.removeValue(forKey: paneID) {
            view.dispose()
            view.removeFromSuperview()
        }
        layoutEngine.removePersistedPane(paneID)

        if layoutEngine.root == nil {
            onAllPanesClosed?()
        } else if let newActive = layoutEngine.activePaneID {
            paneViews[newActive]?.activate()
            onActivePaneChanged?(newActive)
        }

        relayout()
    }

    /// Close the currently active pane.
    func closeActivePane() {
        guard let active = layoutEngine.activePaneID else { return }
        closePane(active)
    }

    /// Navigate focus in the given direction.
    func navigateFocus(_ direction: NavigationDirection) {
        let oldActive = layoutEngine.activePaneID
        guard let newActive = layoutEngine.navigate(direction) else { return }

        if let old = oldActive { paneViews[old]?.deactivate() }
        paneViews[newActive]?.activate()
        onActivePaneChanged?(newActive)
        updateFocusBorder()
    }

    /// Set focus to a specific pane.
    func focusPane(_ paneID: PaneID) {
        let old = layoutEngine.activePaneID
        if let old = old { paneViews[old]?.deactivate() }
        layoutEngine.setActivePane(paneID)
        paneViews[paneID]?.activate()
        onActivePaneChanged?(paneID)
        updateFocusBorder()
    }

    /// Remove all pane and divider subviews and clear their tracking collections.
    private func teardownAllViews() {
        syncPersistedPanes()
        for (_, v) in paneViews {
            v.dispose()
            v.removeFromSuperview()
        }
        paneViews.removeAll()
        dividerViews.forEach { $0.removeFromSuperview() }
        dividerViews.removeAll()
    }

    /// Replace the layout engine (used when switching workspaces).
    func setLayoutEngine(_ engine: PaneLayoutEngine) {
        syncPersistedPanes()
        teardownAllViews()

        layoutEngine = engine

        if let root = engine.root {
            for paneID in root.allPaneIDs {
                let pane: NSView & PaneContent
                if let persistedPane = engine.persistedPane(for: paneID) {
                    (_, pane) = PaneFactory.make(from: persistedPane)
                } else {
                    (_, pane) = PaneFactory.makeRestoreError(
                        paneID: paneID,
                        message: "Restore metadata for this pane is missing.",
                        detail: "The pane could not be reconstructed and will not be saved back into session state."
                    )
                }
                registerPaneView(pane)
            }
        }

        if let activeID = engine.activePaneID, let view = paneViews[activeID] {
            view.activate()
        }
        relayout()
    }

    /// Replace the entire layout with a single root pane.
    /// Used when all panes have been closed and we need a fresh start.
    func setRootPane(_ view: NSView & PaneContent) {
        syncPersistedPanes()
        teardownAllViews()

        layoutEngine = PaneLayoutEngine(rootPaneID: view.paneID)
        registerPaneView(view)
        view.activate()
        onActivePaneChanged?(view.paneID)
        relayout()
    }

    /// The currently active pane view.
    var activePaneView: (NSView & PaneContent)? {
        guard let id = layoutEngine.activePaneID else { return nil }
        return paneViews[id]
    }

    /// Number of panes currently in the layout.
    var paneCount: Int { paneViews.count }

    func syncPersistedPanes() {
        for view in paneViews.values {
            guard view.shouldPersist else { continue }
            layoutEngine.upsertPersistedPane(view.persistedPane())
        }
    }

    // MARK: - Focus Border

    private func updateFocusBorder() {
        guard paneViews.count > 1,
              let activeID = layoutEngine.activePaneID,
              let activeView = paneViews[activeID] else {
            focusBorderView?.removeFromSuperview()
            focusBorderView = nil
            return
        }

        let border: NSView
        if let existing = focusBorderView {
            border = existing
        } else {
            border = FocusBorderView(frame: .zero)
            addSubview(border, positioned: .above, relativeTo: nil)
            focusBorderView = border
        }

        border.frame = activeView.frame
    }

    // MARK: - Pane Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let (paneID, _) = paneViews.first(where: { $0.value.frame.contains(point) }) else {
            return super.menu(for: event)
        }

        let menu = NSMenu()

        let closeItem = NSMenuItem(title: "Close Pane", action: nil, keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = paneID
        closeItem.action = #selector(contextMenuClosePane(_:))
        menu.addItem(closeItem)

        menu.addItem(.separator())

        let splitRightItem = NSMenuItem(title: "Split Right", action: nil, keyEquivalent: "")
        splitRightItem.target = self
        splitRightItem.representedObject = paneID
        splitRightItem.action = #selector(contextMenuSplitRight(_:))
        menu.addItem(splitRightItem)

        let splitDownItem = NSMenuItem(title: "Split Down", action: nil, keyEquivalent: "")
        splitDownItem.target = self
        splitDownItem.representedObject = paneID
        splitDownItem.action = #selector(contextMenuSplitDown(_:))
        menu.addItem(splitDownItem)

        return menu
    }

    @objc private func contextMenuClosePane(_ sender: NSMenuItem) {
        guard let paneID = sender.representedObject as? PaneID else { return }
        closePane(paneID)
    }

    @objc private func contextMenuSplitRight(_ sender: NSMenuItem) {
        guard let paneID = sender.representedObject as? PaneID else { return }
        focusPane(paneID)
        let (_, newPane) = PaneFactory.makeTerminal()
        splitActivePane(direction: .horizontal, newPaneView: newPane)
    }

    @objc private func contextMenuSplitDown(_ sender: NSMenuItem) {
        guard let paneID = sender.representedObject as? PaneID else { return }
        focusPane(paneID)
        let (_, newPane) = PaneFactory.makeTerminal()
        splitActivePane(direction: .vertical, newPaneView: newPane)
    }
}

// MARK: - FocusBorderView

/// Transparent overlay that draws a 2px accent-colored border around the focused pane.
private final class FocusBorderView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = DesignTokens.Layout.focusBorderWidth
        layer?.cornerRadius = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func accessibilityLabel() -> String? { "Active pane indicator" }
}

// MARK: - DividerView

/// Draggable divider between panes with expanded hover target for easier discovery.
private final class DividerView: NSView {

    let direction: SplitDirection
    var onDrag: ((CGFloat) -> Void)?
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, direction: SplitDirection) {
        self.direction = direction
        super.init(frame: frame)
        updateTrackingArea()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let color = isHovering ? NSColor.controlAccentColor.withAlphaComponent(0.6) : NSColor.separatorColor
        color.setFill()
        bounds.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        // Expand tracking rect beyond visual bounds for easier hover target
        let hoverExpansion = DesignTokens.Layout.dividerHoverWidth - DesignTokens.Layout.dividerWidth
        let expandedRect: NSRect
        if direction == .horizontal {
            expandedRect = bounds.insetBy(dx: -hoverExpansion, dy: 0)
        } else {
            expandedRect = bounds.insetBy(dx: 0, dy: -hoverExpansion)
        }
        let area = NSTrackingArea(
            rect: expandedRect,
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
        let cursor: NSCursor = direction == .horizontal ? .resizeLeftRight : .resizeUpDown
        cursor.push()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        needsDisplay = true
        NSCursor.pop()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil, isHovering {
            isHovering = false
            // Reset to arrow instead of pop() to avoid corrupting the global cursor
            // stack if another view also has a pushed cursor.
            NSCursor.arrow.set()
            discardCursorRects()
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor = direction == .horizontal ? .resizeLeftRight : .resizeUpDown
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        var lastPoint = convert(event.locationInWindow, from: nil)

        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let current = convert(next.locationInWindow, from: nil)
            let delta = direction == .horizontal
                ? (current.x - lastPoint.x)
                : (current.y - lastPoint.y)

            if abs(delta) > 0.5 {
                onDrag?(delta)
                lastPoint = current
            }

            if next.type == .leftMouseUp { break }
        }
    }

    // MARK: - Accessibility
    override func accessibilityLabel() -> String? {
        direction == .horizontal ? "Horizontal pane divider" : "Vertical pane divider"
    }
    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }
}
