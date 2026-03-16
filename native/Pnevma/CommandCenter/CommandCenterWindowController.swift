import AppKit
import SwiftUI

@MainActor
final class CommandCenterWindowController: NSWindowController, NSWindowDelegate {
    private let store: CommandCenterStore
    private let onVisibilityChanged: (Bool) -> Void
    private let onFrameChanged: (NSRect) -> Void
    nonisolated(unsafe) private var themeObserver: NSObjectProtocol?

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
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Command Center"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.minSize = NSSize(width: 1180, height: 760)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = GhosttyThemeProvider.shared.backgroundColor
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.contentView = NSHostingView(
            rootView: CommandCenterView(store: store)
                .environment(GhosttyThemeProvider.shared)
        )

        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        window.center()

        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.window?.backgroundColor = GhosttyThemeProvider.shared.backgroundColor
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
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

    private func reportFrame() {
        guard let frame = window?.frame else { return }
        onFrameChanged(frame)
    }
}
