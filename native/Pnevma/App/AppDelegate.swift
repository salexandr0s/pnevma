import Cocoa
import SwiftUI
import os

enum AppSmokeMode: String {
    case launch
    case ghostty

    static var current: AppSmokeMode? {
        ProcessInfo.processInfo.environment["PNEVMA_SMOKE_MODE"]
            .flatMap(AppSmokeMode.init(rawValue:))
    }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

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
    private var toastController: ToastWindowController?
    private var smokeWindow: NSWindow?
    private var smokeHostView: TerminalHostView?
    private var smokeTimeoutWorkItem: DispatchWorkItem?

    // MARK: - App Lifecycle

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        initializeRuntime()

        let restoredState = persistence?.restore()
        if let smokeMode = AppSmokeMode.current {
            runSmoke(mode: smokeMode, restoredState: restoredState)
            return
        }

        // Create and show main window
        createMainWindow(showWindow: true)

        // Reload ghostty config now that window exists so appearance-conditional
        // themes (e.g. light:X,dark:Y) resolve correctly.
        let reloadedConfig = TerminalConfig()
        TerminalSurface.applyGhosttyConfig(reloadedConfig)
        GhosttyConfigController.shared.updateConfigOwner(reloadedConfig)
        GhosttyThemeProvider.shared.refresh()

        if let restoredState {
            applyRestoredState(restoredState)
        } else {
            workspaceManager?.createWorkspace(name: "Default")
        }

        // Build menu bar
        NSApplication.shared.mainMenu = buildMainMenu()

        // Attach toast overlay
        if let win = window {
            toastController = ToastWindowController()
            toastController?.attach(to: win)
        }

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

    public func applicationWillTerminate(_ notification: Notification) {
        persistence?.save(state: buildSessionState())
        persistence?.stopAutoSave()
        shutdownRuntime()
    }

    private func initializeRuntime() {
        // ghostty_init must be the very first ghostty call.
        #if canImport(GhosttyKit)
        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if initResult != 0 {
            Log.general.error("ghostty_init() failed with code \(initResult)")
        }
        #endif

        bridge = PnevmaBridge()
        if let bridge = bridge {
            commandBus = CommandBus(bridge: bridge)
            CommandBus.shared = commandBus
        }

        DispatchQueue.global(qos: .utility).async { [weak bridge] in
            if let result = bridge?.call(method: "task.list", params: "{}") {
                Log.bridge.info("Bridge test ok=\(result.ok) payload=\(result.payload)")
            }
        }

        TerminalSurface.initializeGhostty()

        if let bridge = bridge, let bus = commandBus {
            workspaceManager = WorkspaceManager(bridge: bridge, commandBus: bus)
            let sessionBridge = SessionBridge(commandBus: bus) { [weak self] in
                self?.workspaceManager?.activeWorkspace?.projectPath
            }
            self.sessionBridge = sessionBridge
            SessionBridge.shared = sessionBridge
            PaneFactory.sessionBridge = sessionBridge
        }
        workspaceManager?.onActiveWorkspaceChanged = { [weak self] engine in
            self?.contentAreaView?.syncPersistedPanes()
            self?.contentAreaView?.setLayoutEngine(engine)
            if let workspace = self?.workspaceManager?.activeWorkspace {
                self?.statusBar?.updateBranch(workspace.gitBranch)
                self?.statusBar?.updateAgents(workspace.activeAgents)
            }
            self?.persistence?.markDirty()
        }

        persistence = SessionPersistence()
    }

    private func shutdownRuntime() {
        smokeTimeoutWorkItem?.cancel()
        smokeTimeoutWorkItem = nil

        // Free ghostty app singleton before process exit.
        #if canImport(GhosttyKit)
        TerminalSurface.shutdownGhostty()
        #endif

        bridge?.destroy()
        bridge = nil
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Main Window

    private func createMainWindow(showWindow: Bool) {
        let contentRect = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titleVisibility = .hidden
        win.appearance = NSAppearance(named: .darkAqua)
        win.toolbarStyle = .unifiedCompact

        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.showsBaselineSeparator = false
        win.toolbar = toolbar
        win.center()
        win.minSize = NSSize(width: 800, height: 500)

        guard let windowContent = win.contentView else { return }

        // Root placeholder pane
        let (_, rootPane) = PaneFactory.makeWelcome()
        contentAreaView = ContentAreaView(frame: windowContent.bounds, rootPaneView: rootPane)

        contentAreaView?.onActivePaneChanged = { [weak self] _ in
            if let view = self?.contentAreaView?.activePaneView {
                self?.statusBar?.updateActivePane(view.title)
            }
            self?.persistence?.markDirty()
        }
        contentAreaView?.onPanePersistenceChanged = { [weak self] in
            self?.persistence?.markDirty()
        }

        contentAreaView?.onAllPanesClosed = { [weak self] in
            let newPane = self?.makeRootPaneForActiveWorkspace() ?? PaneFactory.makeWelcome().1
            self?.contentAreaView?.setRootPane(newPane)
            self?.persistence?.markDirty()
        }

        // Status bar
        statusBar = StatusBar()

        // Sidebar
        guard let bridge = bridge, let commandBus = commandBus else {
            Log.general.error("bridge or commandBus not initialized — cannot create sidebar")
            return
        }
        let mgr = workspaceManager ?? WorkspaceManager(bridge: bridge, commandBus: commandBus)
        let sidebarView = SidebarView(
            workspaceManager: mgr,
            onAddWorkspace: { [weak self] in self?.openProject() },
            onOpenSettings: { [weak self] in self?.openSettingsPane() },
            onOpenTool: { [weak self] (toolID: String) in self?.openToolPane(toolID) }
        )
        let sidebarHost = NSHostingView(rootView: sidebarView)
        let sidebarBacking = ThemedSidebarBackingView()
        sidebarBacking.addSubview(sidebarHost)
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebarHost.leadingAnchor.constraint(equalTo: sidebarBacking.leadingAnchor),
            sidebarHost.trailingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
            sidebarHost.topAnchor.constraint(equalTo: sidebarBacking.topAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: sidebarBacking.bottomAnchor),
        ])
        self.sidebarHostView = sidebarBacking

        for view in [sidebarBacking, contentAreaView!, statusBar!] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            windowContent.addSubview(view)
        }

        let sidebarWidth = DesignTokens.Layout.sidebarWidth
        let statusHeight = DesignTokens.Layout.statusBarHeight

        let swc = sidebarBacking.widthAnchor.constraint(equalToConstant: sidebarWidth)
        let clc = contentAreaView!.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor)
        let slc = statusBar!.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor)

        sidebarWidthConstraint = swc
        contentLeadingConstraint = clc
        statusLeadingConstraint = slc

        let minContentWidth = win.minSize.width - sidebarWidth
        NSLayoutConstraint.activate([
            sidebarBacking.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            sidebarBacking.topAnchor.constraint(equalTo: windowContent.topAnchor),
            sidebarBacking.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            swc,

            clc,
            contentAreaView!.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            contentAreaView!.topAnchor.constraint(equalTo: windowContent.topAnchor),
            contentAreaView!.bottomAnchor.constraint(equalTo: statusBar!.topAnchor),
            contentAreaView!.widthAnchor.constraint(greaterThanOrEqualToConstant: minContentWidth),

            slc,
            statusBar!.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            statusBar!.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            statusBar!.heightAnchor.constraint(equalToConstant: statusHeight),
        ])

        // For terminal transparency (background-opacity < 1.0), the window must
        // be non-opaque so ghostty's Metal layer alpha reaches the desktop.
        // The sidebar, status bar, and dividers all paint their own backgrounds.
        let theme = GhosttyThemeProvider.shared
        if theme.backgroundOpacity < 1.0 {
            win.isOpaque = false
            win.backgroundColor = .clear
        } else {
            win.backgroundColor = theme.backgroundColor
        }

        self.window = win
        if showWindow {
            win.makeKeyAndOrderFront(nil)
        } else {
            win.orderOut(nil)
        }

        // Focus the terminal
        if showWindow, let pane = contentAreaView?.activePaneView {
            win.makeFirstResponder(pane)
        }
    }

    private func runSmoke(
        mode: AppSmokeMode,
        restoredState: SessionPersistence.SessionState?
    ) {
        switch mode {
        case .launch:
            createMainWindow(showWindow: false)
            if let restoredState {
                applyRestoredState(restoredState)
            } else {
                workspaceManager?.createWorkspace(name: "Default")
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishSmoke(success: true, message: "launch smoke ready")
            }

        case .ghostty:
            guard TerminalSurface.isRealRendererAvailable else {
                finishSmoke(success: false, message: "Ghostty runtime unavailable")
                return
            }

            let timeoutWorkItem = DispatchWorkItem { [weak self] in
                self?.finishSmoke(success: false, message: "ghostty smoke timed out")
            }
            smokeTimeoutWorkItem = timeoutWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeoutWorkItem)

            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 960, height: 640)
            let win = NSWindow(
                contentRect: NSRect(
                    x: screenFrame.midX - 480,
                    y: screenFrame.midY - 320,
                    width: 960,
                    height: 640
                ),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            win.title = "Pnevma Smoke"
            let hostView = TerminalHostView(frame: win.contentView?.bounds ?? .zero)
            hostView.autoresizingMask = [.width, .height]
            hostView.onSurfaceReady = { [weak self] in
                self?.finishSmoke(success: true, message: "ghostty surface ready")
            }

            if let contentView = win.contentView {
                hostView.frame = contentView.bounds
                contentView.addSubview(hostView)
            }

            smokeHostView = hostView
            smokeWindow = win
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                hostView.ensureSurfaceCreated()
            }
        }
    }

    private func finishSmoke(success: Bool, message: String) {
        smokeTimeoutWorkItem?.cancel()
        smokeTimeoutWorkItem = nil
        smokeHostView?.teardownSurface()
        smokeHostView?.removeFromSuperview()
        smokeHostView = nil
        smokeWindow?.orderOut(nil)
        smokeWindow = nil

        let smokeMessage = "Smoke \(success ? "passed" : "failed"): \(message)\n"
        if let data = smokeMessage.data(using: .utf8) {
            FileHandle.standardError.write(data)
        }

        if success {
            Log.general.info("Smoke passed: \(message)")
        } else {
            Log.general.error("Smoke failed: \(message)")
        }

        if AppSmokeMode.current == .ghostty {
            _exit(Int32(success ? 0 : 1))
        }

        shutdownRuntime()
        exit(success ? 0 : 1)
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
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Find in Page", action: #selector(browserFindInPage), keyEquivalent: "f"))
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
        windowMenu.addItem(.separator())

        let nextWS = NSMenuItem(title: "Next Workspace", action: #selector(nextWorkspace), keyEquivalent: "]")
        nextWS.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(nextWS)

        let prevWS = NSMenuItem(title: "Previous Workspace", action: #selector(previousWorkspace), keyEquivalent: "[")
        prevWS.keyEquivalentModifierMask = [.command, .shift]
        windowMenu.addItem(prevWS)

        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        // Help menu
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(NSMenuItem(title: "Keyboard Shortcuts", action: #selector(showKeyboardShortcuts), keyEquivalent: ""))
        helpMenu.addItem(.separator())
        helpMenu.addItem(NSMenuItem(title: "Pnevma Documentation", action: #selector(openDocumentation), keyEquivalent: ""))
        let helpMenuItem = NSMenuItem()
        helpMenuItem.submenu = helpMenu
        mainMenu.addItem(helpMenuItem)

        return mainMenu
    }

    // MARK: - Menu Actions

    @objc func newTerminal() {
        let projectPath = workspaceManager?.activeWorkspace?.projectPath
        let (_, pane) = PaneFactory.makeTerminal(workingDirectory: projectPath)
        contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane)
    }

    @objc func closePaneAction() { contentAreaView?.closeActivePane() }
    @objc func openProjectAction() { openProject() }
    @objc private func openSettingsAction() { openSettingsPane() }

    @objc private func browserFindInPage() {
        NotificationCenter.default.post(name: .browserToggleFind, object: nil)
    }

    @objc private func splitRightAction() { newTerminal() }

    @objc private func splitDownAction() {
        let projectPath = workspaceManager?.activeWorkspace?.projectPath
        let (_, pane) = PaneFactory.makeTerminal(workingDirectory: projectPath)
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
        persistence?.markDirty()
    }

    @objc private func showCommandPalette() { commandPalette?.show() }

    @objc private func nextWorkspace() {
        guard let mgr = workspaceManager, !mgr.workspaces.isEmpty else { return }
        let ids = mgr.workspaces.map(\.id)
        guard let currentIndex = ids.firstIndex(of: mgr.activeWorkspaceID ?? UUID()) else {
            mgr.switchToWorkspace(ids[0])
            return
        }
        let next = ids[(currentIndex + 1) % ids.count]
        mgr.switchToWorkspace(next)
    }

    @objc private func previousWorkspace() {
        guard let mgr = workspaceManager, !mgr.workspaces.isEmpty else { return }
        let ids = mgr.workspaces.map(\.id)
        guard let currentIndex = ids.firstIndex(of: mgr.activeWorkspaceID ?? UUID()) else {
            mgr.switchToWorkspace(ids[0])
            return
        }
        let prev = ids[(currentIndex - 1 + ids.count) % ids.count]
        mgr.switchToWorkspace(prev)
    }

    @objc private func showKeyboardShortcuts() {
        // Open command palette pre-filtered — doubles as keyboard shortcut reference
        commandPalette?.show()
    }

    @objc private func openDocumentation() {
        if let url = URL(string: "https://pnevma.dev/docs") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Command Palette Registration

    private func registerPaletteCommands() {
        let paneCommands: [(String, String, String?, String?, () -> NSView & PaneContent)] = [
            ("Open Task Board", "pane", nil, "Kanban board for task management", { TaskBoardPaneView() }),
            ("Open Analytics", "pane", nil, "Cost and usage analytics dashboard", { AnalyticsPaneView() }),
            ("Open Daily Brief", "pane", nil, "Daily summary of tasks, costs, and events", { DailyBriefPaneView() }),
            ("Open Notifications", "pane", nil, "View project notifications and alerts", { NotificationsPaneView() }),
            ("Open Review", "pane", nil, "Review task diffs and acceptance criteria", { ReviewPaneView() }),
            ("Open Merge Queue", "pane", nil, "Manage branch merge order and conflicts", { MergeQueuePaneView() }),
            ("Open Diff Viewer", "pane", nil, "View file-level diffs for tasks", { DiffPaneView() }),
            ("Open Search", "pane", nil, "Search across project files", { SearchPaneView() }),
            ("Open File Browser", "pane", nil, "Browse and preview project files", { FileBrowserPaneView() }),
            ("Open Rules Manager", "pane", nil, "Manage project rules and conventions", { RulesManagerPaneView() }),
            ("Open Workflow", "pane", nil, "Visual workflow state machine", { WorkflowPaneView() }),
            ("Open SSH Manager", "pane", nil, "Manage SSH keys and remote profiles", { SshManagerPaneView() }),
            ("Open Session Replay", "pane", nil, "Replay past terminal sessions", { ReplayPaneView(frame: .zero) }),
            ("Open Browser", "pane", nil, "Built-in web browser", { BrowserPaneView(frame: .zero, url: nil) }),
            ("Open Settings", "pane", "Cmd+,", "Configure Pnevma preferences", { SettingsPaneView() }),
        ]

        var commands: [CommandItem] = [
            CommandItem(id: "terminal.new", title: "New Terminal", category: "pane", shortcut: "Cmd+N", description: "Open a new terminal in the active workspace") { [weak self] in
                self?.newTerminal()
            },
            CommandItem(id: "pane.split_right", title: "Split Right", category: "pane", shortcut: "Cmd+D", description: "Split the active pane horizontally") { [weak self] in
                self?.splitRightAction()
            },
            CommandItem(id: "pane.split_down", title: "Split Down", category: "pane", shortcut: "Shift+Cmd+D", description: "Split the active pane vertically") { [weak self] in
                self?.splitDownAction()
            },
            CommandItem(id: "pane.close", title: "Close Pane", category: "pane", shortcut: "Cmd+W", description: "Close the currently active pane") { [weak self] in
                self?.closePaneAction()
            },
            CommandItem(id: "view.sidebar", title: "Toggle Sidebar", category: "view", shortcut: "Cmd+B", description: "Show or hide the sidebar") { [weak self] in
                self?.toggleSidebar()
            },
            CommandItem(id: "workspace.next", title: "Next Workspace", category: "view", shortcut: "Shift+Cmd+]", description: "Switch to the next workspace") { [weak self] in
                self?.nextWorkspace()
            },
            CommandItem(id: "workspace.prev", title: "Previous Workspace", category: "view", shortcut: "Shift+Cmd+[", description: "Switch to the previous workspace") { [weak self] in
                self?.previousWorkspace()
            },
        ]

        for (idx, (title, cat, shortcut, desc, factory)) in paneCommands.enumerated() {
            commands.append(CommandItem(
                id: "pane.open_\(idx)",
                title: title,
                category: cat,
                shortcut: shortcut,
                description: desc
            ) { [weak self] in
                let pane = factory()
                if self?.contentAreaView?.replaceActivePane(with: pane) == nil {
                    self?.contentAreaView?.setRootPane(pane)
                }
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
        ToastManager.shared.show("Project opened: \(url.lastPathComponent)", icon: "folder.badge.checkmark", style: .success)
    }

    private func openSettingsPane() {
        let pane = SettingsPaneView()
        if contentAreaView?.replaceActivePane(with: pane) == nil {
            contentAreaView?.setRootPane(pane)
        }
    }

    private func openToolPane(_ toolID: String) {
        let pane: (NSView & PaneContent)?
        switch toolID {
        case "terminal":
            let projectPath = workspaceManager?.activeWorkspace?.projectPath
            pane = PaneFactory.makeTerminal(workingDirectory: projectPath).1
        case "tasks":
            pane = TaskBoardPaneView()
        case "workflow":
            pane = WorkflowPaneView()
        case "review":
            pane = ReviewPaneView()
        case "merge":
            pane = MergeQueuePaneView()
        case "diff":
            pane = DiffPaneView()
        case "search":
            pane = SearchPaneView()
        case "files":
            pane = FileBrowserPaneView()
        case "analytics":
            pane = AnalyticsPaneView()
        case "brief":
            pane = DailyBriefPaneView()
        case "notifications":
            pane = NotificationsPaneView()
        case "rules":
            pane = RulesManagerPaneView()
        case "ssh":
            pane = SshManagerPaneView()
        case "replay":
            pane = ReplayPaneView(frame: .zero)
        case "browser":
            pane = BrowserPaneView(frame: .zero, url: nil)
        default:
            return
        }
        if let pane {
            if contentAreaView?.replaceActivePane(with: pane) == nil {
                contentAreaView?.setRootPane(pane)
            }
        }
    }

    private func buildSessionState() -> SessionPersistence.SessionState {
        contentAreaView?.syncPersistedPanes()
        let frame = window.map { SessionPersistence.CodableRect($0.frame) }
        return SessionPersistence.SessionState(
            windowFrame: frame,
            workspaces: workspaceManager?.workspaces.map { $0.snapshot() } ?? [],
            activeWorkspaceID: workspaceManager?.activeWorkspaceID,
            sidebarVisible: isSidebarVisible
        )
    }

    private func applyRestoredState(_ state: SessionPersistence.SessionState) {
        if let frame = state.windowFrame?.nsRect,
           let minSize = window?.minSize,
           frame.width >= minSize.width, frame.height >= minSize.height {
            window?.setFrame(frame, display: true)
        }

        isSidebarVisible = state.sidebarVisible
        let width = isSidebarVisible ? DesignTokens.Layout.sidebarWidth : 0
        sidebarWidthConstraint?.constant = width

        workspaceManager?.restore(
            snapshots: state.workspaces,
            activeWorkspaceID: state.activeWorkspaceID
        )

        if let activeWorkspace = workspaceManager?.activeWorkspace {
            contentAreaView?.syncPersistedPanes()
            contentAreaView?.setLayoutEngine(activeWorkspace.layoutEngine)
        } else {
            workspaceManager?.createWorkspace(name: "Default")
        }
    }

    private func makeRootPaneForActiveWorkspace() -> (NSView & PaneContent) {
        if let projectPath = workspaceManager?.activeWorkspace?.projectPath {
            return PaneFactory.makeTerminal(workingDirectory: projectPath).1
        }
        return PaneFactory.makeWelcome().1
    }

    private var notificationsPopover: NSPopover?
    private weak var notificationToolbarButton: NSButton?

    @objc private func showNotifications() {
        if let popover = notificationsPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = notificationToolbarButton else { return }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 340, height: 280)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: NotificationsPopoverView())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        notificationsPopover = popover
    }
}

// MARK: - NSToolbarDelegate

extension AppDelegate: NSToolbarDelegate {
    static let sidebarToggleIdentifier = NSToolbarItem.Identifier("sidebarToggle")
    static let notificationsIdentifier = NSToolbarItem.Identifier("notifications")
    static let addWorkspaceIdentifier = NSToolbarItem.Identifier("addWorkspace")

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.sidebarToggleIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: "Toggle Sidebar")
            item.label = "Sidebar"
            item.toolTip = "Toggle Sidebar"
            item.target = self
            item.action = #selector(toggleSidebar)
            item.isBordered = true
            return item
        case Self.notificationsIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 22))
            button.bezelStyle = .texturedRounded
            button.image = NSImage(systemSymbolName: "bell", accessibilityDescription: "Notifications")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(showNotifications)
            button.toolTip = "Notifications"
            item.view = button
            item.label = "Notifications"
            notificationToolbarButton = button
            return item
        case Self.addWorkspaceIdentifier:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Workspace")
            item.label = "New"
            item.toolTip = "Open Project"
            item.target = self
            item.action = #selector(openProjectAction)
            item.isBordered = true
            return item
        default:
            return nil
        }
    }

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleIdentifier, .flexibleSpace, Self.notificationsIdentifier, Self.addWorkspaceIdentifier]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.sidebarToggleIdentifier, Self.notificationsIdentifier, Self.addWorkspaceIdentifier, .flexibleSpace]
    }
}

// MARK: - ThemedSidebarBackingView

/// Sidebar backing view that uses the ghostty theme background color
/// instead of the system NSVisualEffectView blur, so the sidebar matches
/// the terminal's color scheme.
private final class ThemedSidebarBackingView: NSView {
    private var themeObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = true
        updateBackgroundColor()
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateBackgroundColor()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let theme = GhosttyThemeProvider.shared
        let bg = theme.backgroundColor
        let offset = SidebarPreferences.backgroundOffset
        if offset == 0 {
            bg.setFill()
        } else {
            bg.blended(withFraction: offset, of: .white)?.setFill() ?? bg.setFill()
        }
        bounds.fill()
    }

    private func updateBackgroundColor() {
        let theme = GhosttyThemeProvider.shared
        let bg = theme.backgroundColor
        let offset = SidebarPreferences.backgroundOffset
        let resolved: NSColor
        if offset == 0 {
            resolved = bg
        } else {
            resolved = bg.blended(withFraction: offset, of: .white) ?? bg
        }
        layer?.backgroundColor = resolved.cgColor
        needsDisplay = true
    }
}

// MARK: - Notifications Popover

struct NotificationsPopoverView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Spacer()

            VStack(spacing: 10) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary.opacity(0.5))
                Text("No notifications yet")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text("Desktop notifications will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

