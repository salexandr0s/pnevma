import Cocoa
import SwiftUI
import os

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    var window: NSWindow?
    private var bridge: PnevmaBridge?
    private var commandBus: CommandBus?
    private var sessionBridge: SessionBridge?
    private var sessionStore: SessionStore?
    private var workspaceManager: WorkspaceManager?
    private var contentAreaView: ContentAreaView?
    private var tabBarView: TabBarView?
    private var statusBar: StatusBar?
    private var sidebarHostView: NSView?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var statusLeadingConstraint: NSLayoutConstraint?
    private var tabBarLeadingConstraint: NSLayoutConstraint?
    private var contentTopToTabBar: NSLayoutConstraint?
    private var contentTopToSafeArea: NSLayoutConstraint?
    private var toolbarSeparator: NSView?
    private var titlebarOpenBtn: CapsuleButton?
    private var titlebarCommitBtn: CapsuleButton?
    private var titlebarPushBtn: CapsuleButton?
    private var commandPalette: CommandPalette?
    private var persistence: SessionPersistence?
    private var isSidebarVisible = true
    private var closeConfirmed = false
    private var toastController: ToastWindowController?
    private var settingsWindow: NSWindow?
    private var smokeWindow: NSWindow?
    private var smokeHostView: TerminalHostView?
    private var smokeTimeoutWorkItem: DispatchWorkItem?
    private var runtimeSettingsObserver: NSObjectProtocol?
    var updateCoordinator: AppUpdateCoordinator?

    // MARK: - App Lifecycle

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        initializeRuntime()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await AppRuntimeSettings.shared.load(commandBus: self.commandBus)
            self.applyRuntimeSettings()
            self.finishLaunchingAfterSettingsLoad()
        }
    }

    private func finishLaunchingAfterSettingsLoad() {
        let restoredState = persistence?.restore(
            ifEnabled: AppLaunchContext.shouldRestoreWindowsOnLaunch
        )
        if let smokeMode = AppLaunchContext.smokeMode {
            runSmoke(mode: smokeMode, restoredState: restoredState)
            return
        }

        // Create and show main window
        createMainWindow(showWindow: true)

        // Reload ghostty config now that window exists so appearance-conditional
        // themes (e.g. light:X,dark:Y) resolve correctly.
        let reloadedConfig = TerminalConfig()
        TerminalSurface.applyGhosttyConfig(reloadedConfig)
        TerminalSurface.reapplyColorScheme()
        GhosttyConfigController.shared.updateConfigOwner(reloadedConfig)
        GhosttyThemeProvider.shared.refresh()

        if let restoredState {
            applyRestoredState(restoredState)
        } else {
            workspaceManager?.ensureTerminalWorkspace(name: AppLaunchContext.initialWorkspaceName)
        }

        // Build menu bar
        NSApplication.shared.mainMenu = buildMainMenu()

        // Initialize update coordinator
        if !AppLaunchContext.isTesting {
            updateCoordinator = AppUpdateCoordinator()
            if AppLaunchContext.shouldRunAutomaticUpdateChecks {
                updateCoordinator?.automaticCheck()
            }
        }

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
            guard let self else {
                return SessionPersistence.SessionState(
                    windowFrame: nil,
                    workspaces: [],
                    activeWorkspaceID: nil,
                    sidebarVisible: true
                )
            }
            return self.buildSessionState()
        }
        if !AppLaunchContext.isTesting {
            persistence?.startAutoSave()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        persistence?.stopAutoSave()
        if !AppLaunchContext.isTesting {
            persistence?.save(state: buildSessionState())
        }
        shutdownRuntime()
    }

    private func initializeRuntime() {
        // Point ghostty at the Ghostty.app resource directory so it can find
        // built-in themes, terminfo, etc. Without this, the embedded library
        // looks inside Pnevma's own bundle (which doesn't ship these files).
        let ghosttyResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        if FileManager.default.fileExists(atPath: ghosttyResources) {
            setenv("GHOSTTY_RESOURCES_DIR", ghosttyResources, 0)
        }

        // ghostty_init must be the very first ghostty call.
        #if canImport(GhosttyKit)
        let initResult = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if initResult != 0 {
            Log.general.error("ghostty_init() failed with code \(initResult)")
        } else {
            GhosttyRuntime.markInitialized()
        }
        #endif

        bridge = PnevmaBridge()
        if let bridge = bridge {
            commandBus = CommandBus(bridge: bridge)
            CommandBus.shared = commandBus
        }

        Task { [weak bridge] in
            if let result = bridge?.call(method: "task.list", params: "{}") {
                Log.bridge.info("Bridge test ok=\(result.ok) payload=\(result.payload)")
            }
        }

        TerminalSurface.initializeGhostty()

        if let bridge = bridge, let bus = commandBus {
            workspaceManager = WorkspaceManager(bridge: bridge, commandBus: bus)
            let sessionBridge = SessionBridge(commandBus: bus) { [weak self] in
                self?.workspaceManager?.activeWorkspace?.defaultWorkingDirectory
            }
            self.sessionBridge = sessionBridge
            SessionBridge.shared = sessionBridge
            PaneFactory.sessionBridge = sessionBridge
            PaneFactory.activeWorkspaceProvider = { [weak self] in
                self?.workspaceManager?.activeWorkspace
            }
            let sessionStore = SessionStore(commandBus: bus)
            self.sessionStore = sessionStore
            Task { await sessionStore.activate() }
        }
        workspaceManager?.onActiveWorkspaceChanged = { [weak self] engine in
            _ = engine
            self?.contentAreaView?.syncPersistedPanes()
            if let workspace = self?.workspaceManager?.activeWorkspace {
                workspace.ensureActiveTabHasDisplayableRootPane()
                self?.contentAreaView?.setLayoutEngine(workspace.layoutEngine)
                self?.statusBar?.updateBranch(workspace.gitBranch)
                self?.statusBar?.updateAgents(workspace.activeAgents)
            }
            self?.updateTabBar()
            self?.persistence?.markDirty()
        }

        persistence = SessionPersistence()
        persistence?.isPersistenceEnabled = !AppLaunchContext.isTesting
        runtimeSettingsObserver = NotificationCenter.default.addObserver(
            forName: .appRuntimeSettingsDidChange,
            object: AppRuntimeSettings.shared,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyRuntimeSettings()
            }
        }
        applyRuntimeSettings()
    }

    private func shutdownRuntime() {
        smokeTimeoutWorkItem?.cancel()
        smokeTimeoutWorkItem = nil
        if let runtimeSettingsObserver {
            NotificationCenter.default.removeObserver(runtimeSettingsObserver)
            self.runtimeSettingsObserver = nil
        }

        // Free ghostty app singleton before process exit.
        #if canImport(GhosttyKit)
        TerminalSurface.shutdownGhostty()
        GhosttyRuntime.reset()
        #endif

        workspaceManager?.shutdown()
        bridge?.destroy()
        bridge = nil
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard contentAreaView?.anyPaneHasActiveProcess == true else { return .terminateNow }
        confirmClose(
            title: "Quit Pnevma?",
            message: "The terminal still has a running process. If you quit the process will be killed."
        ) {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func applyRuntimeSettings() {
        persistence?.isPersistenceEnabled =
            !AppLaunchContext.isTesting && AppRuntimeSettings.shared.autoSaveWorkspaceOnQuit
        sessionBridge?.defaultShell = AppRuntimeSettings.shared.normalizedDefaultShell
        if AppLaunchContext.shouldRunAutomaticUpdateChecks {
            updateCoordinator?.automaticCheck()
        }
    }

    // MARK: - Main Window

    private func createMainWindow(showWindow: Bool) {
        let contentRect = NSRect(x: 0, y: 0, width: 1400, height: 900)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.appearance = NSAppearance(named: .darkAqua)
        // Tab bar — added as a content-level view below the titlebar, not a toolbar item
        let tabBar = TabBarView()
        tabBar.onSelectTab = { [weak self] index in self?.switchToTab(index) }
        tabBar.onCloseTab = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onAddTab = { [weak self] in self?.newTab() }
        tabBar.isHidden = true
        self.tabBarView = tabBar

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
            guard let self else { return }
            if let workspace = self.workspaceManager?.activeWorkspace, workspace.tabs.count > 1 {
                // Close this tab and switch to adjacent
                self.closeTab(at: workspace.activeTabIndex)
            } else {
                let newPane = self.makeRootPaneForActiveWorkspace()
                self.contentAreaView?.setRootPane(newPane)
            }
            self.persistence?.markDirty()
        }

        // Status bar
        statusBar = StatusBar()
        statusBar?.onSessionsClicked = { [weak self] in self?.showSessionManager() }
        if let sessionStore {
            statusBar?.bindSessionStore(sessionStore)
        }

        // Sidebar
        guard let bridge = bridge, let commandBus = commandBus else {
            Log.general.error("bridge or commandBus not initialized — cannot create sidebar")
            return
        }
        let mgr = workspaceManager ?? WorkspaceManager(bridge: bridge, commandBus: commandBus)
        let sidebarView = SidebarView(
            workspaceManager: mgr,
            onAddWorkspace: { [weak self] in self?.openWorkspace() },
            onOpenSettings: { [weak self] in self?.openSettingsPane() },
            onOpenTool: { [weak self] (toolID: String) in self?.openToolPane(toolID) },
            onOpenToolAsTab: { [weak self] (toolID: String) in self?.openToolAsTab(toolID) },
            onOpenToolAsPane: { [weak self] (toolID: String) in self?.openToolAsPane(toolID) }
        )
        let sidebarHost = NSHostingView(rootView: sidebarView.environment(GhosttyThemeProvider.shared))
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

        // Titlebar fill: themed background behind the transparent titlebar
        let titlebarFill = ThemedTitlebarFillView()
        titlebarFill.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(titlebarFill)

        guard let contentArea = contentAreaView, let statusBarView = statusBar else {
            Log.general.error("contentAreaView or statusBar not initialized")
            return
        }

        // Subtle horizontal separator between titlebar and content area (not over sidebar)
        let toolbarSep = ThemedSeparatorView(axis: .horizontal)
        toolbarSep.translatesAutoresizingMaskIntoConstraints = false
        self.toolbarSeparator = toolbarSep

        // Titlebar buttons — placed directly in the titlebar area (no NSToolbar)
        let titlebarButtonSize = NSSize(width: 26, height: 22)
        let titlebarSymbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

        let sidebarToggleBtn = makeTitlebarButton(
            symbolName: "sidebar.left",
            accessibilityDescription: "Toggle Sidebar",
            toolTip: "Toggle Sidebar",
            action: #selector(toggleSidebar),
            size: titlebarButtonSize,
            symbolConfig: titlebarSymbolConfig
        )
        let notificationsBtn = makeTitlebarButton(
            symbolName: "bell",
            accessibilityDescription: "Notifications",
            toolTip: "Notifications",
            action: #selector(showNotifications),
            size: titlebarButtonSize,
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemYellow
        )
        notificationToolbarButton = notificationsBtn
        let addWorkspaceBtn = makeTitlebarButton(
            symbolName: "plus",
            accessibilityDescription: "Open Workspace",
            toolTip: "Open Workspace",
            action: #selector(openWorkspaceAction),
            size: titlebarButtonSize,
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemGreen
        )

        // Titlebar action buttons (Open, Commit, Push) — direct subviews like the icon buttons
        let openBtn = CapsuleButton(icon: "folder", label: "Open")
        openBtn.target = self
        openBtn.action = #selector(titlebarOpenAction)
        self.titlebarOpenBtn = openBtn

        let commitBtn = CapsuleButton(icon: "point.3.connected.trianglepath.dotted", label: "Commit")
        commitBtn.target = self
        commitBtn.action = #selector(titlebarCommitAction)
        self.titlebarCommitBtn = commitBtn

        let pushBtn = CapsuleButton(icon: "arrow.up.circle", label: "Push")
        pushBtn.target = self
        pushBtn.action = #selector(titlebarPushAction)
        self.titlebarPushBtn = pushBtn

        for view in [sidebarBacking, tabBar, contentArea, statusBarView, toolbarSep,
                      sidebarToggleBtn, notificationsBtn, addWorkspaceBtn,
                      openBtn, commitBtn, pushBtn] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            windowContent.addSubview(view)
        }

        let sidebarWidth = DesignTokens.Layout.sidebarWidth
        let statusHeight = DesignTokens.Layout.statusBarHeight
        let tabBarHeight = DesignTokens.Layout.tabBarHeight

        let swc = sidebarBacking.widthAnchor.constraint(equalToConstant: sidebarWidth)
        let clc = contentArea.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor)
        let slc = statusBarView.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor)
        let tblc = tabBar.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor)

        // Content area top: switches between below-tab-bar and directly below toolbar separator
        let topToTab = contentArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        let topToSafe = contentArea.topAnchor.constraint(equalTo: toolbarSep.bottomAnchor)
        // Tab bar starts hidden (single tab), so content goes to safe area
        topToTab.isActive = false
        topToSafe.isActive = true

        sidebarWidthConstraint = swc
        contentLeadingConstraint = clc
        statusLeadingConstraint = slc
        tabBarLeadingConstraint = tblc
        contentTopToTabBar = topToTab
        contentTopToSafeArea = topToSafe

        let minContentWidth = win.minSize.width - sidebarWidth
        NSLayoutConstraint.activate([
            titlebarFill.topAnchor.constraint(equalTo: windowContent.topAnchor),
            titlebarFill.bottomAnchor.constraint(equalTo: windowContent.safeAreaLayoutGuide.topAnchor),
            titlebarFill.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            titlebarFill.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),

            sidebarBacking.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            sidebarBacking.topAnchor.constraint(equalTo: windowContent.topAnchor),
            sidebarBacking.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            swc,

            // Tab bar: flush below toolbar separator, tracks sidebar edge
            tblc,
            tabBar.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            tabBar.topAnchor.constraint(equalTo: toolbarSep.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: tabBarHeight),

            clc,
            contentArea.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),
            contentArea.widthAnchor.constraint(greaterThanOrEqualToConstant: minContentWidth),

            slc,
            statusBarView.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            statusBarView.heightAnchor.constraint(equalToConstant: statusHeight),

            // Horizontal separator between titlebar and content (not over sidebar)
            toolbarSep.topAnchor.constraint(equalTo: windowContent.safeAreaLayoutGuide.topAnchor),
            toolbarSep.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
            toolbarSep.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            toolbarSep.heightAnchor.constraint(equalToConstant: DesignTokens.Layout.dividerWidth),

            // Titlebar buttons — vertically centered in titlebar area
            sidebarToggleBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            sidebarToggleBtn.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor, constant: 76),
            sidebarToggleBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            sidebarToggleBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

            notificationsBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            notificationsBtn.trailingAnchor.constraint(equalTo: addWorkspaceBtn.leadingAnchor, constant: -4),
            notificationsBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            notificationsBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

            addWorkspaceBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            addWorkspaceBtn.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor, constant: -12),
            addWorkspaceBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            addWorkspaceBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

            // Titlebar actions (Open, Commit, Push) — direct subviews, right of center
            pushBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            pushBtn.trailingAnchor.constraint(equalTo: notificationsBtn.leadingAnchor, constant: -12),

            commitBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            commitBtn.trailingAnchor.constraint(equalTo: pushBtn.leadingAnchor, constant: -6),

            openBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            openBtn.trailingAnchor.constraint(equalTo: commitBtn.leadingAnchor, constant: -6),
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

        win.delegate = self
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
                workspaceManager?.ensureTerminalWorkspace(name: AppLaunchContext.initialWorkspaceName)
            }
            Task { @MainActor [weak self] in
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
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                guard !timeoutWorkItem.isCancelled else { return }
                timeoutWorkItem.perform()
            }

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
            Task { @MainActor in
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

        if AppLaunchContext.smokeMode == .ghostty {
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
        appMenu.addItem(NSMenuItem(title: "Check for Updates\u{2026}", action: #selector(checkForUpdatesAction), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettingsAction), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Pnevma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "t"))
        fileMenu.addItem(NSMenuItem(title: "New Terminal", action: #selector(newTerminal), keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(title: "Open Workspace...", action: #selector(openWorkspaceAction), keyEquivalent: "o"))
        fileMenu.addItem(.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Pane", action: #selector(closePaneAction), keyEquivalent: "w"))
        let closeWindow = NSMenuItem(title: "Close Window", action: #selector(closeWindowAction), keyEquivalent: "W")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(closeWindow)
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
        let cmdPalette = NSMenuItem(title: "Command Palette", action: #selector(showCommandPalette), keyEquivalent: "P")
        cmdPalette.keyEquivalentModifierMask = [.command, .shift]
        viewMenu.addItem(cmdPalette)
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

        paneMenu.addItem(NSMenuItem(title: "Next Pane", action: #selector(nextPane), keyEquivalent: "]"))
        paneMenu.addItem(NSMenuItem(title: "Previous Pane", action: #selector(previousPane), keyEquivalent: "["))

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

        paneMenu.addItem(.separator())

        let zoomItem = NSMenuItem(title: "Toggle Split Zoom", action: #selector(toggleSplitZoom), keyEquivalent: "\r")
        zoomItem.keyEquivalentModifierMask = [.command, .shift]
        paneMenu.addItem(zoomItem)

        let equalizeItem = NSMenuItem(title: "Equalize Splits", action: #selector(equalizeSplitsAction), keyEquivalent: "=")
        equalizeItem.keyEquivalentModifierMask = [.command, .control]
        paneMenu.addItem(equalizeItem)

        paneMenu.addItem(.separator())

        // Cmd+1–8: jump to Nth pane, Cmd+9: last pane
        for i in 1...8 {
            let item = NSMenuItem(title: "Pane \(i)", action: #selector(gotoPaneByTag(_:)), keyEquivalent: "\(i)")
            item.tag = i
            paneMenu.addItem(item)
        }
        let lastPaneItem = NSMenuItem(title: "Last Pane", action: #selector(gotoLastPane), keyEquivalent: "9")
        paneMenu.addItem(lastPaneItem)

        let paneMenuItem = NSMenuItem()
        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        let fullscreen = NSMenuItem(title: "Toggle Full Screen", action: #selector(toggleFullScreenAction), keyEquivalent: "\r")
        windowMenu.addItem(fullscreen)
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

    @objc func newTab() {
        guard let workspace = workspaceManager?.activeWorkspace else { return }
        contentAreaView?.syncPersistedPanes()
        _ = workspace.addTab(title: "Terminal")
        workspace.ensureActiveTabHasDisplayableRootPane()
        contentAreaView?.setLayoutEngine(workspace.layoutEngine)
        updateTabBar()
        persistence?.markDirty()
    }

    private func switchToTab(_ index: Int) {
        guard let workspace = workspaceManager?.activeWorkspace else { return }
        guard index != workspace.activeTabIndex else { return }
        contentAreaView?.syncPersistedPanes()
        workspace.switchToTab(index)
        workspace.ensureActiveTabHasDisplayableRootPane()
        contentAreaView?.setLayoutEngine(workspace.layoutEngine)
        updateTabBar()
        persistence?.markDirty()
    }

    private func closeTab(at index: Int) {
        guard let workspace = workspaceManager?.activeWorkspace else { return }
        guard workspace.tabs.count > 1 else { return }
        let isActiveTab = index == workspace.activeTabIndex

        // If closing the active tab and it has running processes, confirm first.
        if isActiveTab, contentAreaView?.anyPaneHasActiveProcess == true {
            confirmClose(title: "Close Tab?", message: "The terminal still has a running process. If you close the tab the process will be killed.") { [weak self] in
                self?.performCloseTab(at: index)
            }
        } else {
            performCloseTab(at: index)
        }
    }

    private func performCloseTab(at index: Int) {
        guard let workspace = workspaceManager?.activeWorkspace else { return }
        guard workspace.tabs.count > 1 else { return }
        let wasActive = index == workspace.activeTabIndex
        contentAreaView?.syncPersistedPanes()
        workspace.closeTab(at: index)
        if wasActive {
            workspace.ensureActiveTabHasDisplayableRootPane()
            contentAreaView?.setLayoutEngine(workspace.layoutEngine)
        }
        updateTabBar()
        persistence?.markDirty()
    }

    /// Sync the tab bar view with the active workspace's tabs.
    private func updateTabBar() {
        guard let workspace = workspaceManager?.activeWorkspace else {
            tabBarView?.tabs = []
            setTabBarVisible(false)
            return
        }
        let showTabBar = workspace.tabs.count > 1
        setTabBarVisible(showTabBar)
        tabBarView?.tabs = workspace.tabs.enumerated().map { (i, tab) in
            TabBarView.Tab(id: tab.id, title: tab.title, isActive: i == workspace.activeTabIndex)
        }
    }

    private func setTabBarVisible(_ visible: Bool) {
        let currentlyVisible = tabBarView?.isHidden == false
        guard visible != currentlyVisible else { return }
        tabBarView?.isHidden = !visible
        if visible {
            contentTopToSafeArea?.isActive = false
            contentTopToTabBar?.isActive = true
        } else {
            contentTopToTabBar?.isActive = false
            contentTopToSafeArea?.isActive = true
        }
        window?.contentView?.needsLayout = true
    }

    @objc func newTerminal() {
        let (_, pane) = PaneFactory.workspaceAwareTerminal()
        if contentAreaView?.activePaneView?.paneType == "welcome" {
            contentAreaView?.replaceActivePane(with: pane)
        } else {
            contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane)
        }
    }

    @objc func closePaneAction() {
        guard let contentArea = contentAreaView else { return }
        if contentArea.activePaneHasActiveProcess {
            confirmClose(title: "Close Terminal?", message: "The terminal still has a running process. If you close the terminal the process will be killed.") {
                contentArea.closeActivePane()
            }
        } else {
            contentArea.closeActivePane()
        }
    }

    @objc func openWorkspaceAction() { openWorkspace() }
    @objc private func openSettingsAction() { openSettingsPane() }

    @objc private func checkForUpdatesAction() {
        if updateCoordinator == nil {
            updateCoordinator = AppUpdateCoordinator()
        }
        Task { @MainActor [weak self] in
            guard let coordinator = self?.updateCoordinator else { return }
            await coordinator.manualCheck()
            switch coordinator.state.status {
            case .updateAvailable(let version, let url):
                let alert = NSAlert()
                alert.messageText = "Update Available"
                alert.informativeText = "Pnevma \(version) is available. You are running \(coordinator.state.currentVersion)."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open Release Page")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(url)
                }
            case .upToDate:
                let alert = NSAlert()
                alert.messageText = "You're Up to Date"
                alert.informativeText = "Pnevma \(coordinator.state.currentVersion) is the latest version."
                alert.alertStyle = .informational
                alert.addButton(withTitle: "OK")
                alert.runModal()
            case .failed(let message):
                let alert = NSAlert()
                alert.messageText = "Update Check Failed"
                alert.informativeText = "Could not check for updates: \(message)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            default:
                break
            }
        }
    }

    @objc private func browserFindInPage() {
        NotificationCenter.default.post(name: .browserToggleFind, object: nil)
    }

    @objc private func splitRightAction() { newTerminal() }

    @objc private func splitDownAction() {
        let (_, pane) = PaneFactory.workspaceAwareTerminal()
        contentAreaView?.splitActivePane(direction: .vertical, newPaneView: pane)
    }

    @objc private func navigateLeft()  { contentAreaView?.navigateFocus(.left) }
    @objc private func navigateRight() { contentAreaView?.navigateFocus(.right) }
    @objc private func navigateUp()    { contentAreaView?.navigateFocus(.up) }
    @objc private func navigateDown()  { contentAreaView?.navigateFocus(.down) }

    @objc private func nextPane()     { contentAreaView?.cycleFocusForward() }
    @objc private func previousPane() { contentAreaView?.cycleFocusBackward() }

    @objc private func toggleSplitZoom()      { contentAreaView?.toggleZoom() }
    @objc private func equalizeSplitsAction()  { contentAreaView?.equalizeSplits() }

    @objc private func gotoPaneByTag(_ sender: NSMenuItem) {
        contentAreaView?.focusNthPane(sender.tag)
    }
    @objc private func gotoLastPane() { contentAreaView?.focusLastPane() }

    @objc private func closeWindowAction() {
        guard let win = window else { return }
        // Trigger the standard close flow which goes through windowShouldClose
        win.performClose(nil)
    }

    @objc private func toggleFullScreenAction() { window?.toggleFullScreen(nil) }

    @objc private func toggleSidebar() {
        isSidebarVisible.toggle()
        let sidebarWidth = DesignTokens.Layout.sidebarWidth
        let paneMinWidth: CGFloat = 800 - sidebarWidth
        window?.minSize.width = isSidebarVisible ? (sidebarWidth + paneMinWidth) : paneMinWidth
        let width = isSidebarVisible ? sidebarWidth : 0
        if isSidebarVisible { sidebarHostView?.isHidden = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = DesignTokens.Motion.normal
            ctx.allowsImplicitAnimation = true
            sidebarWidthConstraint?.animator().constant = width
        }, completionHandler: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.isSidebarVisible { self.sidebarHostView?.isHidden = true }
            }
        })
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
        let paneCommands: [(title: String, category: String, shortcut: String?, description: String?, paneType: String)] = [
            ("Open Task Board", "pane", nil, "Kanban board for task management", "taskboard"),
            ("Open Analytics", "pane", nil, "Cost and usage analytics dashboard", "analytics"),
            ("Open Daily Brief", "pane", nil, "Daily summary of tasks, costs, and events", "daily_brief"),
            ("Open Notifications", "pane", nil, "View project notifications and alerts", "notifications"),
            ("Open Review", "pane", nil, "Review task diffs and acceptance criteria", "review"),
            ("Open Merge Queue", "pane", nil, "Manage branch merge order and conflicts", "merge_queue"),
            ("Open Diff Viewer", "pane", nil, "View file-level diffs for tasks", "diff"),
            ("Open Search", "pane", nil, "Search across project files", "search"),
            ("Open File Browser", "pane", nil, "Browse and preview project files", "file_browser"),
            ("Open Rules Manager", "pane", nil, "Manage project rules and conventions", "rules"),
            ("Open Workflow", "pane", nil, "Visual workflow state machine", "workflow"),
            ("Open SSH Manager", "pane", nil, "Manage SSH keys and remote profiles", "ssh"),
            ("Open Session Replay", "pane", nil, "Replay past terminal sessions", "replay"),
            ("Open Browser", "pane", nil, "Built-in web browser", "browser"),
        ]

        var commands: [CommandItem] = [
            CommandItem(id: "terminal.new_tab", title: "New Tab", category: "pane", shortcut: "Cmd+T", description: "Open a new terminal tab in the active workspace") { [weak self] in
                self?.newTab()
            },
            CommandItem(id: "terminal.new", title: "New Terminal", category: "pane", shortcut: "Cmd+N", description: "Open a new terminal in the active workspace") { [weak self] in
                self?.newTerminal()
            },
            CommandItem(id: "pane.split_right", title: "Split Right", category: "pane", shortcut: "Cmd+D", description: "Split the active pane horizontally") { [weak self] in
                self?.splitRightAction()
            },
            CommandItem(id: "pane.split_down", title: "Split Down", category: "pane", shortcut: "Shift+Cmd+D", description: "Split the active pane vertically") { [weak self] in
                self?.splitDownAction()
            },
            CommandItem(id: "pane.next", title: "Next Pane", category: "pane", shortcut: "Cmd+]", description: "Cycle focus to the next pane") { [weak self] in
                self?.nextPane()
            },
            CommandItem(id: "pane.prev", title: "Previous Pane", category: "pane", shortcut: "Cmd+[", description: "Cycle focus to the previous pane") { [weak self] in
                self?.previousPane()
            },
            CommandItem(id: "pane.zoom", title: "Toggle Split Zoom", category: "pane", shortcut: "Shift+Cmd+Enter", description: "Maximize the active pane or restore splits") { [weak self] in
                self?.toggleSplitZoom()
            },
            CommandItem(id: "pane.equalize", title: "Equalize Splits", category: "pane", shortcut: "Ctrl+Cmd+=", description: "Reset all split ratios to equal") { [weak self] in
                self?.equalizeSplitsAction()
            },
            CommandItem(id: "pane.close", title: "Close Pane", category: "pane", shortcut: "Cmd+W", description: "Close the currently active pane") { [weak self] in
                self?.closePaneAction()
            },
            CommandItem(id: "window.close", title: "Close Window", category: "window", shortcut: "Shift+Cmd+W", description: "Close the current window") { [weak self] in
                self?.closeWindowAction()
            },
            CommandItem(id: "window.fullscreen", title: "Toggle Full Screen", category: "window", shortcut: "Cmd+Enter", description: "Toggle full screen mode") { [weak self] in
                self?.toggleFullScreenAction()
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

        for (idx, paneCommand) in paneCommands.enumerated() {
            commands.append(CommandItem(
                id: "pane.open_\(idx)",
                title: paneCommand.title,
                category: paneCommand.category,
                shortcut: paneCommand.shortcut,
                description: paneCommand.description
            ) { [weak self] in
                guard let pane = PaneFactory.make(type: paneCommand.paneType)?.1 else { return }
                if self?.contentAreaView?.replaceActivePane(with: pane) == nil {
                    self?.contentAreaView?.setRootPane(pane)
                }
            })
        }

        commands.append(CommandItem(
            id: "app.settings",
            title: "Open Settings",
            category: "app",
            shortcut: "Cmd+,",
            description: "Configure Pnevma preferences"
        ) { [weak self] in
            self?.openSettingsPane()
        })

        commands.append(CommandItem(
            id: "app.sessions",
            title: "Session Manager",
            category: "app",
            shortcut: nil,
            description: "View and manage active terminal sessions"
        ) { [weak self] in
            self?.showSessionManager()
        })

        commandPalette?.registerCommands(commands)
    }

    // MARK: - Helpers

    private func openWorkspace() {
        presentOpenWorkspacePanel()
    }

    private func presentOpenWorkspacePanel() {
        let alert = NSAlert()
        alert.messageText = "Open Workspace"
        alert.informativeText = "Choose whether to create a local project workspace or a remote SSH workspace."
        alert.addButton(withTitle: "Local")
        alert.addButton(withTitle: "Remote")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            presentOpenLocalWorkspacePanel()
        case .alertSecondButtonReturn:
            Task { @MainActor [weak self] in
                await self?.presentOpenRemoteWorkspacePanel()
            }
        default:
            break
        }
    }

    private func presentOpenLocalWorkspacePanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Workspace"
        panel.message = "Select a local project directory"

        let persistenceToggle = NSButton(
            checkboxWithTitle: "Enable session persistence",
            target: nil,
            action: nil
        )
        persistenceToggle.state = .on
        let helper = NSTextField(labelWithString: "Persistent workspaces use tmux-backed managed sessions. Unchecked starts a plain Ghostty shell.")
        helper.textColor = .secondaryLabelColor
        helper.lineBreakMode = .byWordWrapping
        helper.maximumNumberOfLines = 0

        let accessory = NSStackView(views: [persistenceToggle, helper])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 0, right: 0)
        helper.preferredMaxLayoutWidth = 320
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLocalWorkspace(
            path: url.path,
            terminalMode: persistenceToggle.state == .on ? .persistent : .nonPersistent
        )
    }

    private func presentOpenRemoteWorkspacePanel() async {
        guard let bus = commandBus else { return }
        guard WorkspaceProjectTransportSupport.hasRemoteNativeToolingSupport() else {
            let alert = NSAlert()
            alert.messageText = "sshfs Required"
            alert.informativeText = "Remote native tools require sshfs/macFUSE on this Mac. Install sshfs before creating a remote workspace."
            alert.runModal()
            return
        }

        do {
            let profiles: [SshProfile] = try await bus.call(method: "ssh.list_profiles", params: nil)
            guard !profiles.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "No SSH Presets"
                alert.informativeText = "Create an SSH preset in SSH Manager before opening a remote workspace."
                alert.runModal()
                return
            }

            let alert = NSAlert()
            alert.messageText = "Open Remote Workspace"
            alert.informativeText = "Select an SSH preset, enter the remote project path, and choose whether the terminal session should persist. Native project tools use an sshfs mount of the remote workspace."

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            profiles.forEach { profile in
                popup.addItem(withTitle: "\(profile.name) (\(profile.user)@\(profile.host):\(profile.port))")
            }

            let pathField = NSTextField(string: "~")
            pathField.placeholderString = "/path/to/project"
            let persistenceToggle = NSButton(
                checkboxWithTitle: "Enable session persistence",
                target: nil,
                action: nil
            )
            persistenceToggle.state = .on

            let profileLabel = NSTextField(labelWithString: "SSH Preset")
            let pathLabel = NSTextField(labelWithString: "Remote Project Path")
            let accessory = NSStackView(views: [
                profileLabel,
                popup,
                pathLabel,
                pathField,
                persistenceToggle,
            ])
            accessory.orientation = .vertical
            accessory.alignment = .leading
            accessory.spacing = 8
            accessory.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
            accessory.translatesAutoresizingMaskIntoConstraints = false
            popup.widthAnchor.constraint(equalToConstant: 360).isActive = true
            pathField.widthAnchor.constraint(equalToConstant: 360).isActive = true
            alert.accessoryView = accessory
            alert.addButton(withTitle: "Open Workspace")
            alert.addButton(withTitle: "Cancel")

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let selectedProfile = profiles[max(0, popup.indexOfSelectedItem)]
            let remotePath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !remotePath.isEmpty else {
                ToastManager.shared.show(
                    "Remote path is required",
                    icon: "exclamationmark.triangle",
                    style: .error
                )
                return
            }

            let target = WorkspaceRemoteTarget(
                sshProfileID: selectedProfile.id,
                sshProfileName: selectedProfile.name,
                host: selectedProfile.host,
                port: selectedProfile.port,
                user: selectedProfile.user,
                identityFile: selectedProfile.identityFile,
                proxyJump: selectedProfile.proxyJump,
                remotePath: remotePath
            )
            openRemoteWorkspace(
                target: target,
                terminalMode: persistenceToggle.state == .on ? .persistent : .nonPersistent
            )
        } catch {
            ToastManager.shared.show(
                error.localizedDescription,
                icon: "exclamationmark.triangle",
                style: .error
            )
        }
    }

    private func openLocalWorkspace(path: String, terminalMode: WorkspaceTerminalMode) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        workspaceManager?.createLocalProjectWorkspace(
            name: name,
            projectPath: path,
            terminalMode: terminalMode
        )
        ToastManager.shared.show(
            "Workspace opened: \(name)",
            icon: "folder.badge.checkmark",
            style: .success
        )
    }

    private func openRemoteWorkspace(target: WorkspaceRemoteTarget, terminalMode: WorkspaceTerminalMode) {
        workspaceManager?.createRemoteWorkspace(
            name: target.sshProfileName,
            remoteTarget: target,
            terminalMode: terminalMode
        )
        ToastManager.shared.show(
            "Remote workspace opened: \(target.sshProfileName)",
            icon: "network",
            style: .success
        )
    }

    private func openSettingsPane() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        win.appearance = NSAppearance(named: .darkAqua)
        win.minSize = NSSize(width: 600, height: 400)
        win.contentView = NSHostingView(rootView: SettingsView().environment(GhosttyThemeProvider.shared))
        win.center()
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win
    }

    private func makeToolPane(_ toolID: String) -> (NSView & PaneContent)? {
        switch toolID {
        case "terminal":    return PaneFactory.workspaceAwareTerminal().1
        case "tasks":       return TaskBoardPaneView()
        case "workflow":    return WorkflowPaneView()
        case "review":      return ReviewPaneView()
        case "merge":       return MergeQueuePaneView()
        case "diff":        return DiffPaneView()
        case "search":      return SearchPaneView()
        case "files":       return FileBrowserPaneView()
        case "analytics":   return UsagePaneView()
        case "brief":       return DailyBriefPaneView()
        case "notifications": return NotificationsPaneView()
        case "rules":       return RulesManagerPaneView()
        case "ssh":         return SshManagerPaneView()
        case "replay":      return ReplayPaneView(frame: .zero)
        case "browser":     return BrowserPaneView(frame: .zero, url: nil)
        default:            return nil
        }
    }

    private func openToolPane(_ toolID: String) {
        guard sidebarTools(for: workspaceManager?.activeWorkspace).contains(where: { $0.id == toolID }) else {
            return
        }
        guard let pane = makeToolPane(toolID) else { return }
        if contentAreaView?.replaceActivePane(with: pane) == nil {
            contentAreaView?.setRootPane(pane)
        }
    }

    private func openToolAsTab(_ toolID: String) {
        guard let workspace = workspaceManager?.activeWorkspace,
              makeToolPane(toolID) != nil else { return }
        let title = sidebarTools(for: workspace).first(where: { $0.id == toolID })?.title ?? toolID.capitalized
        contentAreaView?.syncPersistedPanes()
        _ = workspace.addTab(title: title)
        workspace.ensureActiveTabHasDisplayableRootPane()
        contentAreaView?.setLayoutEngine(workspace.layoutEngine)
        updateTabBar()
        openToolPane(toolID)
        persistence?.markDirty()
    }

    private func openToolAsPane(_ toolID: String) {
        guard let pane = makeToolPane(toolID) else { return }
        contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane)
        persistence?.markDirty()
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
        sidebarHostView?.isHidden = !isSidebarVisible
        let paneMinWidth: CGFloat = 800 - DesignTokens.Layout.sidebarWidth
        window?.minSize.width = isSidebarVisible ? 800 : paneMinWidth

        workspaceManager?.restore(
            snapshots: state.workspaces,
            activeWorkspaceID: state.activeWorkspaceID
        )

        if let activeWorkspace = workspaceManager?.activeWorkspace {
            contentAreaView?.syncPersistedPanes()
            activeWorkspace.ensureActiveTabHasDisplayableRootPane()
            contentAreaView?.setLayoutEngine(activeWorkspace.layoutEngine)
        } else {
            workspaceManager?.ensureTerminalWorkspace(name: AppLaunchContext.initialWorkspaceName)
        }
        updateTabBar()
    }

    private func makeRootPaneForActiveWorkspace() -> (NSView & PaneContent) {
        PaneFactory.workspaceAwareTerminal().1
    }

    private var notificationsPopover: NSPopover?
    private var sessionsPopover: NSPopover?
    private weak var notificationToolbarButton: NSButton?

    private func showSessionManager() {
        if let popover = sessionsPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let statusBar, let sessionStore else { return }
        let button = statusBar.sessionsButton

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 320)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: SessionManagerPopoverView(store: sessionStore)
                .environment(GhosttyThemeProvider.shared)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        sessionsPopover = popover
    }

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

// MARK: - Titlebar Buttons

extension AppDelegate {
    func makeTitlebarButton(
        symbolName: String,
        accessibilityDescription: String,
        toolTip: String,
        action: Selector,
        size: NSSize,
        symbolConfig: NSImage.SymbolConfiguration,
        hoverTintColor: NSColor? = nil
    ) -> NSButton {
        let button: NSButton
        if let hoverColor = hoverTintColor {
            button = HoverTintButton(
                frame: NSRect(origin: .zero, size: size),
                normalColor: .secondaryLabelColor,
                hoverColor: hoverColor
            )
        } else {
            button = NSButton(frame: NSRect(origin: .zero, size: size))
        }
        button.isBordered = false
        button.focusRingType = .none
        button.bezelStyle = .inline
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(symbolConfig)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = .secondaryLabelColor
        button.target = self
        button.action = action
        button.toolTip = toolTip
        button.setAccessibilityLabel(accessibilityDescription)
        return button
    }

    // MARK: - Titlebar Action Handlers (Open, Commit, Push)

    @objc func titlebarOpenAction() {
        guard let path = workspaceManager?.activeWorkspace?.projectPath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    @objc func titlebarCommitAction() {
        guard workspaceManager?.activeWorkspace?.projectPath != nil,
              let commitBtn = titlebarCommitBtn else { return }
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 180)
        popover.behavior = .transient
        popover.animates = true
        let view = CommitPopoverView(
            branch: workspaceManager?.activeWorkspace?.gitBranch,
            onCommit: { [weak self] message in
                popover.performClose(nil)
                self?.runGitCommit(message: message)
            },
            onCancel: { popover.performClose(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: commitBtn.bounds, of: commitBtn, preferredEdge: .minY)
    }

    @objc func titlebarPushAction() {
        guard let path = workspaceManager?.activeWorkspace?.projectPath else { return }
        let mgr = workspaceManager
        Task.detached {
            let push = Process()
            push.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            push.arguments = ["push"]
            push.currentDirectoryURL = URL(fileURLWithPath: path)
            push.standardOutput = FileHandle.nullDevice
            push.standardError = FileHandle.nullDevice
            try? push.run()
            push.waitUntilExit()
            await MainActor.run {
                if let ws = mgr?.activeWorkspace {
                    mgr?.refreshMetadata(for: ws)
                }
            }
        }
    }

    private func runGitCommit(message: String) {
        guard let path = workspaceManager?.activeWorkspace?.projectPath else { return }
        let mgr = workspaceManager
        Task.detached {
            let add = Process()
            add.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            add.arguments = ["add", "-A"]
            add.currentDirectoryURL = URL(fileURLWithPath: path)
            add.standardOutput = FileHandle.nullDevice
            add.standardError = FileHandle.nullDevice
            try? add.run()
            add.waitUntilExit()

            let commit = Process()
            commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            commit.arguments = ["commit", "-m", message]
            commit.currentDirectoryURL = URL(fileURLWithPath: path)
            commit.standardOutput = FileHandle.nullDevice
            commit.standardError = FileHandle.nullDevice
            try? commit.run()
            commit.waitUntilExit()
            await MainActor.run {
                if let ws = mgr?.activeWorkspace {
                    mgr?.refreshMetadata(for: ws)
                }
            }
        }
    }
}

// MARK: - HoverTintButton

final class HoverTintButton: NSButton {
    private let normalColor: NSColor
    private let hoverColor: NSColor
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, normalColor: NSColor, hoverColor: NSColor) {
        self.normalColor = normalColor
        self.hoverColor = hoverColor
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        contentTintColor = hoverColor
    }

    override func mouseExited(with event: NSEvent) {
        contentTintColor = normalColor
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed {
            closeConfirmed = false
            return true
        }
        guard contentAreaView?.anyPaneHasActiveProcess == true else { return true }
        confirmClose(
            title: "Close Window?",
            message: "The terminal still has a running process. If you close the window the process will be killed."
        ) { [weak self] in
            self?.closeConfirmed = true
            self?.window?.close()
        }
        return false
    }
}

// MARK: - Close Confirmation

extension AppDelegate {
    /// Show a confirmation alert styled like Ghostty's close prompts.
    func confirmClose(title: String, message: String, onConfirm: @escaping () -> Void) {
        guard let win = window, win.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: win) { response in
            if response == .alertFirstButtonReturn {
                onConfirm()
            }
        }
    }
}

// MARK: - ThemedTitlebarFillView

/// Covers the titlebar area with the ghostty theme background so the
/// transparent titlebar matches the rest of the chrome instead of being clear.
private final class ThemedTitlebarFillView: NSView {
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

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.toggleFullScreen(nil)
        } else {
            super.mouseUp(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let theme = GhosttyThemeProvider.shared
        theme.backgroundColor.withAlphaComponent(theme.backgroundOpacity).setFill()
        bounds.fill()
    }

    private func updateBackgroundColor() {
        let theme = GhosttyThemeProvider.shared
        layer?.backgroundColor = theme.backgroundColor.withAlphaComponent(theme.backgroundOpacity).cgColor
        needsDisplay = true
    }
}

// MARK: - ThemedSidebarBackingView

/// Sidebar backing view that uses the ghostty theme background color
/// instead of the system NSVisualEffectView blur, so the sidebar matches
/// the terminal's color scheme.
private final class ThemedSidebarBackingView: NSView {
    private var themeObserver: NSObjectProtocol?
    private let rightSeparator = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.isOpaque = true
        layer?.masksToBounds = true

        // Right-edge separator matching ghostty split dividers
        rightSeparator.wantsLayer = true
        rightSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rightSeparator)
        NSLayoutConstraint.activate([
            rightSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            rightSeparator.topAnchor.constraint(equalTo: topAnchor),
            rightSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            rightSeparator.widthAnchor.constraint(equalToConstant: DesignTokens.Layout.dividerWidth),
        ])

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
        rightSeparator.layer?.backgroundColor = (theme.splitDividerColor ?? NSColor.separatorColor).cgColor
        needsDisplay = true
    }
}

// MARK: - ThemedSeparatorView

/// A subtle 1pt separator line that follows the ghostty split divider color.
private final class ThemedSeparatorView: NSView {
    enum Axis { case horizontal, vertical }
    private let axis: Axis
    private var themeObserver: NSObjectProtocol?

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        wantsLayer = true
        updateColor()
        themeObserver = NotificationCenter.default.addObserver(
            forName: GhosttyThemeProvider.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateColor()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    private func updateColor() {
        let theme = GhosttyThemeProvider.shared
        layer?.backgroundColor = (theme.splitDividerColor ?? NSColor.separatorColor).cgColor
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
