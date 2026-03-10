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
    private var notificationRingViews: [PaneID: NotificationRingView] = [:]

    /// Called when a pane is closed and the layout becomes empty.
    var onAllPanesClosed: (() -> Void)?

    /// Called when the active pane changes.
    var onActivePaneChanged: ((PaneID?) -> Void)?

    /// Called when a pane updates persisted metadata such as session attachment.
    var onPanePersistenceChanged: (() -> Void)?

    /// Called when a terminal notification fires on a pane.
    var onTerminalNotification: (() -> Void)?

    // MARK: - Init

    private var themeObserver: NSObjectProtocol?

    init(frame: NSRect, rootPaneView: NSView & PaneContent) {
        layoutEngine = PaneLayoutEngine(rootPaneID: rootPaneView.paneID)
        super.init(frame: frame)

        // Give the content area a themed background so tab/workspace transitions
        // don't flash an empty gap while new pane views are being created.
        wantsLayer = true
        updateOwnBackground()

        registerPaneView(rootPaneView)
        rootPaneView.activate()
        installClickMonitor()
        focusBorderObserver = NotificationCenter.default.addObserver(
            forName: .focusBorderPreferencesChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateFocusBorder()
        }
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateOwnBackground()
            self?.updateNonTerminalPaneBackgrounds()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    deinit {
        removeClickMonitor()
        if let focusBorderObserver {
            NotificationCenter.default.removeObserver(focusBorderObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    /// Use flipped coordinate system (top-left origin) so vertical splits
    /// render correctly: first=top, second=bottom.
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Layer may not exist yet during init; apply the background once the
        // view is installed in the window and the backing layer is guaranteed.
        if window != nil { updateOwnBackground() }
    }

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
        if let zoomedID = zoomedPaneID {
            paneViews[zoomedID]?.frame = bounds
            return
        }
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
            let hitPadding = DesignTokens.Layout.dividerHoverWidth - dw
            let expandedRect: NSRect = direction == .horizontal
                ? dividerRect.insetBy(dx: -hitPadding, dy: 0)
                : dividerRect.insetBy(dx: 0, dy: -hitPadding)
            dividerViews[index].frame = expandedRect
            if let dv = dividerViews[index] as? DividerView {
                dv.parentSize = direction == .horizontal ? rect.width : rect.height
            }
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

        let hitPadding = DesignTokens.Layout.dividerHoverWidth - dw
        let expandedRect: NSRect = direction == .horizontal
            ? dividerRect.insetBy(dx: -hitPadding, dy: 0)
            : dividerRect.insetBy(dx: 0, dy: -hitPadding)
        let divider = DividerView(frame: expandedRect, direction: direction)
        divider.parentSize = direction == .horizontal ? rect.width : rect.height
        let firstPaneIDs = Set(first.allPaneIDs)
        divider.onDrag = { [weak self, weak divider] delta in
            guard let self = self, let divider = divider else { return }
            let size = divider.parentSize
            guard size > 0 else { return }
            self.layoutEngine.resizeSplit(firstChildPaneIDs: firstPaneIDs, delta: delta / size, parentSize: size)
            self.repositionPanes()
            self.repositionDividers()
        }
        addSubview(divider)
        dividerViews.append(divider)

        createDividers(node: first, rect: firstRect)
        createDividers(node: second, rect: secondRect)
    }

    // MARK: - Click-to-Focus

    private var clickMonitor: Any?
    private var focusBorderObserver: NSObjectProtocol?

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
        // Non-terminal panes need a themed background so they aren't transparent
        // when the window is non-opaque (for terminal background-opacity support).
        // Terminal panes don't need this — ghostty's Metal layer handles their rendering.
        if view.paneType != "terminal" {
            let theme = GhosttyThemeProvider.shared
            view.wantsLayer = true
            view.layer?.backgroundColor = theme.backgroundColor.withAlphaComponent(theme.backgroundOpacity).cgColor
        }
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

    /// Keep the content area's own background in sync with the terminal theme
    /// so pane transitions don't flash an empty gap.
    private func updateOwnBackground() {
        let theme = GhosttyThemeProvider.shared
        layer?.backgroundColor = theme.backgroundColor.withAlphaComponent(theme.backgroundOpacity).cgColor
    }

    /// Update background color for all non-terminal pane views after a theme change.
    private func updateNonTerminalPaneBackgrounds() {
        let theme = GhosttyThemeProvider.shared
        let bg = theme.backgroundColor.withAlphaComponent(theme.backgroundOpacity).cgColor
        for (_, view) in paneViews where view.paneType != "terminal" {
            view.layer?.backgroundColor = bg
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
        return replacePane(activeID, with: newPaneView)
    }

    /// Replace a specific pane's view without changing the tree structure.
    @discardableResult
    func replacePane(_ paneID: PaneID, with newPaneView: NSView & PaneContent) -> PaneID? {
        let newID = newPaneView.paneID
        guard layoutEngine.replacePane(paneID, with: newID) else { return nil }

        if let oldView = paneViews.removeValue(forKey: paneID) {
            oldView.dispose()
            oldView.removeFromSuperview()
        }
        layoutEngine.removePersistedPane(paneID)

        registerPaneView(newPaneView)
        newPaneView.activate()
        onActivePaneChanged?(newID)
        relayout()
        return newID
    }

    /// Close the given pane.
    func closePane(_ paneID: PaneID) {
        // If the zoomed pane is being closed, unzoom first.
        if zoomedPaneID == paneID {
            zoomedPaneID = nil
            for (_, view) in paneViews { view.isHidden = false }
            dividerViews.forEach { $0.isHidden = false }
        }

        guard layoutEngine.closePane(paneID) else { return }

        dismissNotificationRing(for: paneID)

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

    /// Whether the active pane has a running process that would be killed.
    var activePaneHasActiveProcess: Bool {
        guard let active = layoutEngine.activePaneID else { return false }
        return paneViews[active]?.hasActiveProcess ?? false
    }

    /// Whether any pane in the current layout has a running process.
    var anyPaneHasActiveProcess: Bool {
        paneViews.values.contains { $0.hasActiveProcess }
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
        dismissNotificationRing(for: paneID)
    }

    /// Detach the currently tracked pane views while leaving them on-screen long
    /// enough to install the replacement layout above them.
    private func beginViewSwap() -> [PaneID: NSView & PaneContent] {
        let outgoingPaneViews = paneViews
        paneViews.removeAll()
        dividerViews.forEach { $0.removeFromSuperview() }
        dividerViews.removeAll()
        focusBorderView?.removeFromSuperview()
        focusBorderView = nil
        for (_, ring) in notificationRingViews {
            ring.removeFromSuperview()
        }
        notificationRingViews.removeAll()
        return outgoingPaneViews
    }

    /// Dispose pane views after the new layout is fully registered and laid out.
    private func disposePaneViews(_ views: [PaneID: NSView & PaneContent]) {
        for (_, v) in views {
            v.dispose()
            v.removeFromSuperview()
        }
    }

    /// Remove all pane and divider subviews and clear their tracking collections.
    private func teardownAllViews() {
        syncPersistedPanes()
        let outgoingPaneViews = beginViewSwap()
        disposePaneViews(outgoingPaneViews)
    }

    private func installLayoutEngine(_ engine: PaneLayoutEngine) {
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

    /// Replace the layout engine (used when switching workspaces).
    func setLayoutEngine(_ engine: PaneLayoutEngine) {
        syncPersistedPanes()
        let outgoingPaneViews = beginViewSwap()
        installLayoutEngine(engine)
        disposePaneViews(outgoingPaneViews)
    }

    /// Replace the entire layout with a single root pane.
    /// Used when all panes have been closed and we need a fresh start.
    /// Resets the existing engine in-place to preserve shared references
    /// (e.g. WorkspaceTab.layoutEngine identity).
    func setRootPane(_ view: NSView & PaneContent) {
        syncPersistedPanes()
        let outgoingPaneViews = beginViewSwap()

        layoutEngine.reset(rootPaneID: view.paneID)
        registerPaneView(view)
        view.activate()
        onActivePaneChanged?(view.paneID)
        relayout()
        disposePaneViews(outgoingPaneViews)
    }

    /// The currently active pane view.
    var activePaneView: (NSView & PaneContent)? {
        guard let id = layoutEngine.activePaneID else { return nil }
        return paneViews[id]
    }

    /// Number of panes currently in the layout.
    var paneCount: Int { paneViews.count }

    // MARK: - Pane Cycling

    /// Cycle focus to the next pane in depth-first order.
    func cycleFocusForward() {
        guard let allIDs = layoutEngine.root?.allPaneIDs, allIDs.count > 1,
              let active = layoutEngine.activePaneID,
              let index = allIDs.firstIndex(of: active) else { return }
        let next = allIDs[(index + 1) % allIDs.count]
        focusPane(next)
    }

    /// Cycle focus to the previous pane in depth-first order.
    func cycleFocusBackward() {
        guard let allIDs = layoutEngine.root?.allPaneIDs, allIDs.count > 1,
              let active = layoutEngine.activePaneID,
              let index = allIDs.firstIndex(of: active) else { return }
        let prev = allIDs[(index - 1 + allIDs.count) % allIDs.count]
        focusPane(prev)
    }

    /// Focus the Nth pane (1-based). If n exceeds pane count, does nothing.
    func focusNthPane(_ n: Int) {
        guard let allIDs = layoutEngine.root?.allPaneIDs,
              n > 0, n <= allIDs.count else { return }
        focusPane(allIDs[n - 1])
    }

    /// Focus the last pane in the layout.
    func focusLastPane() {
        guard let allIDs = layoutEngine.root?.allPaneIDs,
              let last = allIDs.last else { return }
        focusPane(last)
    }

    // MARK: - Split Zoom

    private var zoomedPaneID: PaneID?

    /// Whether a pane is currently zoomed to fill the content area.
    var isZoomed: Bool { zoomedPaneID != nil }

    /// Toggle zoom: maximize the active pane to fill the entire content area,
    /// or restore the previous split layout.
    func toggleZoom() {
        if zoomedPaneID != nil {
            // Unzoom
            zoomedPaneID = nil
            for (_, view) in paneViews { view.isHidden = false }
            dividerViews.forEach { $0.isHidden = false }
            relayout()
        } else {
            guard let active = layoutEngine.activePaneID,
                  paneViews.count > 1 else { return }
            zoomedPaneID = active
            for (id, view) in paneViews { view.isHidden = (id != active) }
            dividerViews.forEach { $0.isHidden = true }
            paneViews[active]?.frame = bounds
            updateFocusBorder()
        }
    }

    // MARK: - Equalize Splits

    /// Reset all split ratios to equal (50/50).
    func equalizeSplits() {
        layoutEngine.equalizeSplits()
        relayout()
    }

    func syncPersistedPanes() {
        for view in paneViews.values {
            guard view.shouldPersist else { continue }
            layoutEngine.upsertPersistedPane(view.persistedPane())
        }
    }

    // MARK: - Focus Border

    private func updateFocusBorder() {
        guard FocusBorderPreferences.enabled,
              paneViews.count > 1,
              let activeID = layoutEngine.activePaneID,
              let activeView = paneViews[activeID] else {
            focusBorderView?.removeFromSuperview()
            focusBorderView = nil
            return
        }

        let border: FocusBorderView
        if let existing = focusBorderView as? FocusBorderView {
            border = existing
        } else {
            focusBorderView?.removeFromSuperview()
            border = FocusBorderView(frame: .zero)
            focusBorderView = border
        }

        border.frame = activeView.frame
        border.applyCurrentStyle()

        // Ensure border is the topmost subview so it isn't covered
        // by terminal or other pane views added after it.
        if border.superview != self {
            addSubview(border, positioned: .above, relativeTo: nil)
        } else if subviews.last !== border {
            border.removeFromSuperview()
            addSubview(border, positioned: .above, relativeTo: nil)
        }
    }

    // MARK: - Notification Rings

    /// Show a notification ring around the given pane. Auto-dismisses after 5 seconds
    /// or when the pane gains focus.
    func showNotificationRing(for paneID: PaneID) {
        guard let view = paneViews[paneID] else { return }

        // Don't ring the focused pane
        if paneID == layoutEngine.activePaneID { return }

        if let existing = notificationRingViews[paneID] {
            existing.frame = view.frame
            existing.flash()
            return
        }

        let ring = NotificationRingView(frame: view.frame)
        if ring.superview == nil {
            addSubview(ring, positioned: .above, relativeTo: nil)
        }
        notificationRingViews[paneID] = ring
        ring.flash()

        onTerminalNotification?()

        // Auto-dismiss after 5 seconds
        Task { @MainActor [weak self, weak ring] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, let ring, ring.superview != nil else { return }
            self.dismissNotificationRing(for: paneID)
        }
    }

    private func dismissNotificationRing(for paneID: PaneID) {
        if let ring = notificationRingViews.removeValue(forKey: paneID) {
            ring.removeFromSuperview()
        }
    }

    // MARK: - Pane Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let (paneID, _) = paneViews.first(where: { $0.value.frame.contains(point) }) else {
            return super.menu(for: event)
        }

        let menu = NSMenu()

        let closeItem = NSMenuItem(title: "Close Pane", action: #selector(contextMenuClosePane(_:)), keyEquivalent: "")
        closeItem.target = self
        closeItem.representedObject = paneID
        menu.addItem(closeItem)

        menu.addItem(.separator())

        let splitRightItem = NSMenuItem(title: "Split Right", action: #selector(contextMenuSplitRight(_:)), keyEquivalent: "")
        splitRightItem.target = self
        splitRightItem.representedObject = paneID
        menu.addItem(splitRightItem)

        let splitDownItem = NSMenuItem(title: "Split Down", action: #selector(contextMenuSplitDown(_:)), keyEquivalent: "")
        splitDownItem.target = self
        splitDownItem.representedObject = paneID
        menu.addItem(splitDownItem)

        menu.addItem(.separator())

        let currentType = paneViews[paneID]?.paneType
        let replaceSubmenu = NSMenu()
        let paneTypes: [(label: String, type: String, icon: String)] = [
            ("Terminal",      "terminal",      "terminal"),
            ("Task Board",    "taskboard",     "checklist"),
            ("Replay",        "replay",        "play.rectangle"),
            ("File Browser",  "file_browser",  "folder"),
            ("SSH Manager",   "ssh",           "network"),
            ("Workflow",      "workflow",      "arrow.triangle.branch"),
            ("Review",        "review",        "eye"),
            ("Merge Queue",   "merge_queue",   "arrow.triangle.merge"),
            ("Diff",          "diff",          "doc.text.magnifyingglass"),
            ("Search",        "search",        "magnifyingglass"),
            ("Analytics",     "analytics",     "chart.bar"),
            ("Notifications", "notifications", "bell"),
            ("Daily Brief",   "daily_brief",   "newspaper"),
            ("Rules",         "rules",         "list.bullet.rectangle"),
            ("Browser",       "browser",       "globe"),
        ]
        for entry in paneTypes {
            guard PaneFactory.isPaneTypeAvailable(entry.type, in: PaneFactory.activeWorkspaceProvider?()) else {
                continue
            }
            let item = NSMenuItem(title: entry.label, action: #selector(contextMenuReplacePane(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ["paneID": paneID, "type": entry.type] as [String: Any]
            if entry.type == currentType { item.state = .on }
            if let image = NSImage(systemSymbolName: entry.icon, accessibilityDescription: entry.label) {
                item.image = image
            }
            replaceSubmenu.addItem(item)
        }

        let replaceItem = NSMenuItem(title: "Replace With", action: nil, keyEquivalent: "")
        replaceItem.submenu = replaceSubmenu
        menu.addItem(replaceItem)

        return menu
    }

    @objc private func contextMenuClosePane(_ sender: NSMenuItem) {
        guard let paneID = sender.representedObject as? PaneID else { return }
        closePane(paneID)
    }

    @objc private func contextMenuSplitRight(_ sender: NSMenuItem) {
        guard let paneID = sender.representedObject as? PaneID else { return }
        focusPane(paneID)
        let (_, newPane) = PaneFactory.workspaceAwareTerminal()
        splitActivePane(direction: .horizontal, newPaneView: newPane)
    }

    @objc private func contextMenuSplitDown(_ sender: NSMenuItem) {
        guard let paneID = sender.representedObject as? PaneID else { return }
        focusPane(paneID)
        let (_, newPane) = PaneFactory.workspaceAwareTerminal()
        splitActivePane(direction: .vertical, newPaneView: newPane)
    }

    @objc private func contextMenuReplacePane(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: Any],
              let paneID = info["paneID"] as? PaneID,
              let paneType = info["type"] as? String,
              let (_, newPane) = PaneFactory.make(type: paneType) else { return }
        replacePane(paneID, with: newPane)
    }
}

extension Notification.Name {
    static let focusBorderPreferencesChanged = Notification.Name("focusBorderPreferencesChanged")
}

// MARK: - Focus Border Preferences

enum FocusBorderPreferences {
    private static let defaults = UserDefaults.standard

    static var enabled: Bool {
        get { defaults.object(forKey: "focusBorderEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "focusBorderEnabled") }
    }

    static var opacity: CGFloat {
        get {
            let raw = defaults.object(forKey: "focusBorderOpacity") as? Double
                ?? Double(DesignTokens.Layout.focusBorderOpacity)
            return CGFloat(max(0.1, min(1.0, raw)))
        }
        set { defaults.set(Double(newValue), forKey: "focusBorderOpacity") }
    }

    static var width: CGFloat {
        get {
            let raw = defaults.object(forKey: "focusBorderWidth") as? Double
                ?? Double(DesignTokens.Layout.focusBorderWidth)
            return CGFloat(max(1, min(6, raw)))
        }
        set { defaults.set(Double(newValue), forKey: "focusBorderWidth") }
    }

    /// Stored as hex string. `nil` or "accent" means system accent color.
    static var colorHex: String? {
        get { defaults.string(forKey: "focusBorderColor") }
        set { defaults.set(newValue, forKey: "focusBorderColor") }
    }

    static var resolvedColor: NSColor {
        guard let hex = colorHex, !hex.isEmpty, hex != "accent" else {
            return .controlAccentColor
        }
        return NSColor(hexString: hex) ?? .controlAccentColor
    }
}

// MARK: - FocusBorderView

/// Transparent overlay that draws an accent-colored border around the focused pane.
private final class FocusBorderView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 0
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyCurrentStyle() {
        let color = FocusBorderPreferences.resolvedColor
            .withAlphaComponent(FocusBorderPreferences.opacity)
        layer?.borderColor = color.cgColor
        layer?.borderWidth = FocusBorderPreferences.width
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyCurrentStyle()
    }

    override func accessibilityLabel() -> String? { "Active pane indicator" }
}

// MARK: - DividerView

/// Draggable divider between panes with expanded hover target for easier discovery.
private final class DividerView: NSView {

    let direction: SplitDirection
    var onDrag: ((CGFloat) -> Void)?
    var parentSize: CGFloat = 0
    private var isHovering = false
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, direction: SplitDirection) {
        self.direction = direction
        super.init(frame: frame)
        updateTrackingArea()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let baseColor = GhosttyThemeProvider.shared.splitDividerColor ?? NSColor.separatorColor
        let lineWidth = isHovering ? CGFloat(3) : DesignTokens.Layout.dividerWidth
        let color = isHovering ? NSColor.controlAccentColor.withAlphaComponent(0.6) : baseColor
        color.setFill()
        let lineRect: NSRect
        if direction == .horizontal {
            lineRect = NSRect(x: (bounds.width - lineWidth) / 2, y: 0,
                              width: lineWidth, height: bounds.height)
        } else {
            lineRect = NSRect(x: 0, y: (bounds.height - lineWidth) / 2,
                              width: bounds.width, height: lineWidth)
        }
        lineRect.fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
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
        // Convert in the (flipped) superview's coordinate space so that
        // dragging down produces a positive Y delta matching the layout direction.
        let coordSpace = superview ?? self
        var lastPoint = coordSpace.convert(event.locationInWindow, from: nil)

        while true {
            guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { break }
            let current = coordSpace.convert(next.locationInWindow, from: nil)
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

// MARK: - NotificationRingView

/// Animated colored border overlay shown when a terminal pane receives a notification.
/// Similar to FocusBorderView but with a distinctive notification color and fade animation.
private final class NotificationRingView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 0
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.systemOrange.cgColor
        layer?.opacity = 0
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func flash() {
        // Fade in
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        layer?.opacity = 1.0
        CATransaction.commit()

        // Fade out after delay
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3.0))
            guard let self, self.superview != nil else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.0)
            self.layer?.opacity = 0
            CATransaction.commit()
        }
    }

    override func accessibilityLabel() -> String? { "Notification indicator" }
}
