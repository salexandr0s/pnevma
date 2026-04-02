import AppKit
import SwiftUI

@MainActor
final class CommandCenterWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    private enum ToolbarItemID {
        static let search = NSToolbarItem.Identifier("command-center.search")
        static let refresh = NSToolbarItem.Identifier("command-center.refresh")
    }

    private let store: CommandCenterStore
    private let onVisibilityChanged: (Bool) -> Void
    private let onFrameChanged: (NSRect) -> Void

    private lazy var commandToolbar: NSToolbar = {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("command-center.toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        return toolbar
    }()

    private lazy var searchToolbarItem: NSSearchToolbarItem = {
        let item = NSSearchToolbarItem(itemIdentifier: ToolbarItemID.search)
        item.label = "Search"
        item.searchField.placeholderString = "Search runs, branches, models, files"
        item.searchField.sendsSearchStringImmediately = true
        item.searchField.delegate = self
        item.searchField.target = self
        item.searchField.action = #selector(submitSearch(_:))
        return item
    }()

    private lazy var refreshToolbarItem: NSToolbarItem = {
        let item = NSToolbarItem(itemIdentifier: ToolbarItemID.refresh)
        item.label = "Refresh"
        item.paletteLabel = "Refresh"
        item.toolTip = "Refresh Command Center"
        item.image = NSImage(
            systemSymbolName: "arrow.clockwise",
            accessibilityDescription: "Refresh Command Center"
        )
        item.target = self
        item.action = #selector(refreshCommandCenter)
        return item
    }()

    init(
        store: CommandCenterStore,
        onVisibilityChanged: @escaping (Bool) -> Void,
        onFrameChanged: @escaping (NSRect) -> Void
    ) {
        self.store = store
        self.onVisibilityChanged = onVisibilityChanged
        self.onFrameChanged = onFrameChanged

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Command Center"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 1180, height: 760)
        window.backgroundColor = ChromeSurfaceStyle.window.baseColor
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]

        super.init(window: window)

        store.onSearchQueryChanged = { [weak self] query in
            self?.syncSearchField(with: query)
        }

        window.toolbar = commandToolbar
        window.contentViewController = NSHostingController(
            rootView: makeRootView()
        )

        syncSearchField(with: store.searchQuery)
        shouldCascadeWindows = false
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var isWindowVisible: Bool {
        window?.isVisible == true
    }

    func present(makeKey: Bool) {
        showWindow(nil)
        if makeKey {
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
        onVisibilityChanged(true)
        store.activate()
        reportFrame()
    }

    func closeWindow() {
        window?.performClose(nil)
    }

    func applyRestoredFrame(_ frame: NSRect) {
        window?.setFrame(frame, display: false)
    }

    func currentFrame() -> NSRect? {
        window?.frame
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChanged(false)
        store.deactivate()
    }

    func windowDidMove(_ notification: Notification) {
        reportFrame()
    }

    func windowDidResize(_ notification: Notification) {
        reportFrame()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarItemID.search, .flexibleSpace, ToolbarItemID.refresh]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarItemID.search, .flexibleSpace, ToolbarItemID.refresh]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarItemID.search:
            return searchToolbarItem
        case ToolbarItemID.refresh:
            return refreshToolbarItem
        default:
            return nil
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let searchField = notification.object as? NSSearchField,
              searchField == searchToolbarItem.searchField else {
            return
        }
        store.searchQuery = searchField.stringValue
    }

    @objc private func refreshCommandCenter() {
        store.refreshNow()
    }

    @objc private func submitSearch(_ sender: NSSearchField) {
        store.searchQuery = sender.stringValue
        store.selectFirstRun()
    }

    private func makeRootView() -> some View {
        CommandCenterView(
            store: store,
            focusSearchField: { [weak self] in
                self?.focusSearchField()
            },
            isSearchFieldFocused: { [weak self] in
                self?.isSearchFieldFocused() ?? false
            }
        )
        .environment(GhosttyThemeProvider.shared)
    }

    private func focusSearchField() {
        guard let window else { return }
        window.makeFirstResponder(searchToolbarItem.searchField)
        searchToolbarItem.searchField.selectText(nil)
    }

    private func isSearchFieldFocused() -> Bool {
        guard let window else { return false }
        if window.firstResponder === searchToolbarItem.searchField {
            return true
        }
        if let editor = searchToolbarItem.searchField.currentEditor() {
            return window.firstResponder === editor
        }
        return false
    }

    private func syncSearchField(with query: String) {
        guard searchToolbarItem.searchField.stringValue != query else { return }
        searchToolbarItem.searchField.stringValue = query
    }

    private func reportFrame() {
        guard let frame = window?.frame else { return }
        onFrameChanged(frame)
    }
}
