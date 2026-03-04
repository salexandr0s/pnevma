import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    var window: NSWindow?
    private var bridge: PnevmaBridge?
    private var commandBus: CommandBus?
    private var sessionBridge: SessionBridge?
    private var workspaceManager: WorkspaceManager?
    private var contentAreaView: ContentAreaView?
    private var statusBar: StatusBar?
    private var sidebarHostView: NSView?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var statusLeadingConstraint: NSLayoutConstraint?
    private var commandPalette: CommandPalette?
    private var persistence: SessionPersistence?
    private var isSidebarVisible = true

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ghostty_init must be the very first ghostty call.
        #if canImport(GhosttyKit)
        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if initResult != 0 {
            print("[Pnevma] ERROR: ghostty_init() failed with code \(initResult)")
        }
        #endif

        // Initialize Rust bridge
        bridge = PnevmaBridge()
        if let bridge = bridge {
            commandBus = CommandBus(bridge: bridge)
        }

        // Verify bridge works
        if let result = bridge?.call(method: "task.list", params: "{}") {
            print("[Pnevma] Bridge test: \(result)")
        }

        // Initialize ghostty app singleton
        TerminalSurface.initializeGhostty()

        // Session coordinator
        sessionBridge = SessionBridge()

        // Workspace manager
        if let bridge = bridge, let bus = commandBus {
            workspaceManager = WorkspaceManager(bridge: bridge, commandBus: bus)
        }

        // Persistence
        persistence = SessionPersistence()

        // Create main window
        createMainWindow()

        // Build menu bar
        NSApplication.shared.mainMenu = buildMainMenu()

        // Build command palette
        commandPalette = CommandPalette()
        registerPaletteCommands()

        // Start auto-save with state provider
        persistence?.stateProvider = { [weak self] in
            guard let self = self else {
                return SessionPersistence.SessionState(
                    windowFrame: nil, workspaces: [], activeWorkspaceID: nil, sidebarVisible: true)
            }
            return self.buildSessionState()
        }
        persistence?.startAutoSave()
    }

    func applicationWillTerminate(_ notification: Notification) {
        persistence?.save(state: buildSessionState())
        persistence?.stopAutoSave()

        // Free ghostty app singleton before process exit.
        #if canImport(GhosttyKit)
        if let app = TerminalSurface.ghosttyApp {
            ghostty_app_free(app)
            TerminalSurface.ghosttyApp = nil
        }
        #endif

        bridge?.destroy()
        bridge = nil
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Main Window

    private func createMainWindow() {
        let contentRect = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Pnevma"
        win.center()
        win.minSize = NSSize(width: 800, height: 500)

        guard let windowContent = win.contentView else { return }

        // Root terminal pane
        let (_, rootPane) = PaneFactory.makeTerminal()
        contentAreaView = ContentAreaView(frame: windowContent.bounds, rootPaneView: rootPane)

        contentAreaView?.onActivePaneChanged = { [weak self] _ in
            if let view = self?.contentAreaView?.activePaneView {
                self?.statusBar?.updateActivePane(view.title)
            }
            self?.persistence?.markDirty()
        }

        contentAreaView?.onAllPanesClosed = { [weak self] in
            let (_, newPane) = PaneFactory.makeTerminal()
            self?.contentAreaView?.setRootPane(newPane)
            self?.persistence?.markDirty()
        }

        // Status bar
        statusBar = StatusBar()

        // Sidebar
        guard let bridge = bridge, let commandBus = commandBus else {
            print("[Pnevma] ERROR: bridge or commandBus not initialized — cannot create sidebar")
            return
        }
        let mgr = workspaceManager ?? WorkspaceManager(bridge: bridge, commandBus: commandBus)
        let sidebarView = SidebarView(
            workspaceManager: mgr,
            onOpenProject: { [weak self] in self?.openProject() },
            onOpenSettings: { [weak self] in self?.openSettingsPane() }
        )
        let sidebarHost = NSHostingView(rootView: sidebarView)
        let sidebarEffect = NSVisualEffectView()
        sidebarEffect.material = .sidebar
        sidebarEffect.blendingMode = .behindWindow
        sidebarEffect.addSubview(sidebarHost)
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarHost.leadingAnchor.constraint(equalTo: sidebarEffect.leadingAnchor),
            sidebarHost.trailingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor),
            sidebarHost.topAnchor.constraint(equalTo: sidebarEffect.topAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: sidebarEffect.bottomAnchor),
        ])
        self.sidebarHostView = sidebarEffect

        // Layout
        for view in [sidebarEffect, contentAreaView!, statusBar!] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            windowContent.addSubview(view)
        }

        let sidebarWidth = DesignTokens.Layout.sidebarWidth
        let statusHeight = DesignTokens.Layout.statusBarHeight

        let swc = sidebarEffect.widthAnchor.constraint(equalToConstant: sidebarWidth)
        let clc = contentAreaView!.leadingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor)
        let slc = statusBar!.leadingAnchor.constraint(equalTo: sidebarEffect.trailingAnchor)

        sidebarWidthConstraint = swc
        contentLeadingConstraint = clc
        statusLeadingConstraint = slc

        NSLayoutConstraint.activate([
            sidebarEffect.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            sidebarEffect.topAnchor.constraint(equalTo: windowContent.topAnchor),
            sidebarEffect.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            swc,

            clc,
            contentAreaView!.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            contentAreaView!.topAnchor.constraint(equalTo: windowContent.topAnchor),
            contentAreaView!.bottomAnchor.constraint(equalTo: statusBar!.topAnchor),

            slc,
            statusBar!.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            statusBar!.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            statusBar!.heightAnchor.constraint(equalToConstant: statusHeight),
        ])

        win.makeKeyAndOrderFront(nil)
        self.window = win

        // Focus the terminal
        if let pane = contentAreaView?.activePaneView {
            win.makeFirstResponder(pane)
        }

        // Create default workspace
        workspaceManager?.createWorkspace(name: "Default")
    }

    // MARK: - Menu Bar

    private func buildMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Pnevma", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettingsAction), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Pnevma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Terminal", action: #selector(newTerminal), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "Open Project...", action: #selector(openProjectAction), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Pane", action: #selector(closePaneAction), keyEquivalent: "w"))
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        viewMenu.addItem(withTitle: "Command Palette", action: #selector(showCommandPalette), keyEquivalent: "k")
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Pane menu
        let paneMenu = NSMenu(title: "Pane")
        paneMenu.addItem(NSMenuItem(title: "Split Right", action: #selector(splitRightAction), keyEquivalent: "d"))

        let splitDown = NSMenuItem(title: "Split Down", action: #selector(splitDownAction), keyEquivalent: "D")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(splitDown)

        paneMenu.addItem(.separator())

        for (title, action, key) in [
            ("Navigate Left",  #selector(navigateLeft),  NSLeftArrowFunctionKey),
            ("Navigate Right", #selector(navigateRight), NSRightArrowFunctionKey),
            ("Navigate Up",    #selector(navigateUp),    NSUpArrowFunctionKey),
            ("Navigate Down",  #selector(navigateDown),  NSDownArrowFunctionKey),
        ] as [(String, Selector, Int)] {
            let item = NSMenuItem(title: title, action: action,
                                  keyEquivalent: String(Character(UnicodeScalar(key)!)))
            item.keyEquivalentModifierMask = [.option, .command]
            paneMenu.addItem(item)
        }

        let paneMenuItem = NSMenuItem()
        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        return mainMenu
    }

    // MARK: - Menu Actions

    @objc private func newTerminal() {
        let (_, pane) = PaneFactory.makeTerminal()
        contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane)
    }

    @objc private func closePaneAction() { contentAreaView?.closeActivePane() }
    @objc private func openProjectAction() { openProject() }
    @objc private func openSettingsAction() { openSettingsPane() }

    @objc private func splitRightAction() {
        let (_, pane) = PaneFactory.makeTerminal()
        contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane)
    }

    @objc private func splitDownAction() {
        let (_, pane) = PaneFactory.makeTerminal()
        contentAreaView?.splitActivePane(direction: .vertical, newPaneView: pane)
    }

    @objc private func navigateLeft()  { contentAreaView?.navigateFocus(.left) }
    @objc private func navigateRight() { contentAreaView?.navigateFocus(.right) }
    @objc private func navigateUp()    { contentAreaView?.navigateFocus(.up) }
    @objc private func navigateDown()  { contentAreaView?.navigateFocus(.down) }

    @objc private func toggleSidebar() {
        isSidebarVisible.toggle()
        let width = isSidebarVisible ? DesignTokens.Layout.sidebarWidth : 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.normal
            sidebarWidthConstraint?.animator().constant = width
        }
    }

    @objc private func showCommandPalette() { commandPalette?.show() }

    // MARK: - Command Palette Registration

    private func registerPaletteCommands() {
        let paneCommands: [(String, String, String?, () -> NSView & PaneContent)] = [
            ("Open Task Board", "pane", nil, { TaskBoardPaneView() }),
            ("Open Analytics", "pane", nil, { AnalyticsPaneView() }),
            ("Open Daily Brief", "pane", nil, { DailyBriefPaneView() }),
            ("Open Notifications", "pane", nil, { NotificationsPaneView() }),
            ("Open Review", "pane", nil, { ReviewPaneView() }),
            ("Open Merge Queue", "pane", nil, { MergeQueuePaneView() }),
            ("Open Diff Viewer", "pane", nil, { DiffPaneView() }),
            ("Open Search", "pane", nil, { SearchPaneView() }),
            ("Open File Browser", "pane", nil, { FileBrowserPaneView() }),
            ("Open Rules Manager", "pane", nil, { RulesManagerPaneView() }),
            ("Open Workflow", "pane", nil, { WorkflowPaneView() }),
            ("Open SSH Manager", "pane", nil, { SshManagerPaneView() }),
            ("Open Session Replay", "pane", nil, { ReplayPaneView() }),
            ("Open Settings", "pane", "Cmd+,", { SettingsPaneView() }),
        ]

        var commands: [CommandItem] = [
            CommandItem(id: "terminal.new", title: "New Terminal", category: "pane", shortcut: "Cmd+N") { [weak self] in
                self?.newTerminal()
            },
            CommandItem(id: "pane.split_right", title: "Split Right", category: "pane", shortcut: "Cmd+D") { [weak self] in
                self?.splitRightAction()
            },
            CommandItem(id: "pane.split_down", title: "Split Down", category: "pane", shortcut: "Shift+Cmd+D") { [weak self] in
                self?.splitDownAction()
            },
            CommandItem(id: "pane.close", title: "Close Pane", category: "pane", shortcut: "Cmd+W") { [weak self] in
                self?.closePaneAction()
            },
            CommandItem(id: "view.sidebar", title: "Toggle Sidebar", category: "view", shortcut: "Cmd+B") { [weak self] in
                self?.toggleSidebar()
            },
        ]

        for (idx, (title, cat, shortcut, factory)) in paneCommands.enumerated() {
            commands.append(CommandItem(
                id: "pane.open_\(idx)",
                title: title,
                category: cat,
                shortcut: shortcut
            ) { [weak self] in
                let pane = factory()
                self?.contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane)
            })
        }

        commandPalette?.registerCommands(commands)
    }

    // MARK: - Helpers

    private func openProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a project directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaceManager?.createWorkspace(name: url.lastPathComponent, projectPath: url.path)
    }

    private func openSettingsPane() {
        let pane = SettingsPaneView()
        contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane)
    }

    private func buildSessionState() -> SessionPersistence.SessionState {
        let frame = window.map { SessionPersistence.CodableRect($0.frame) }
        return SessionPersistence.SessionState(
            windowFrame: frame,
            workspaces: workspaceManager?.workspaces.map { $0.snapshot() } ?? [],
            activeWorkspaceID: workspaceManager?.activeWorkspaceID,
            sidebarVisible: isSidebarVisible
        )
    }
}
