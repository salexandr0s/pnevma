import Cocoa
#if canImport(GhosttyKit)
import GhosttyKit
#endif
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
    private var titlebarFillBottomConstraint: NSLayoutConstraint?
    private var titlebarFillMinHeightConstraint: NSLayoutConstraint?
    private var titlebarOpenBtn: CapsuleButton?
    private var titlebarCommitBtn: CapsuleButton?
    private var titlebarPushBtn: CapsuleButton?
    private var titlebarTemplateBtn: NSButton?
    private var sidebarToggleLeadingConstraint: NSLayoutConstraint?
    private var sidebarToggleBtn: NSView?
    private var sidebarToggleWidthConstraint: NSLayoutConstraint?
    private var sidebarToggleHeightConstraint: NSLayoutConstraint?
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
    private var providerUsageStoreObserver: NSObjectProtocol?
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
            _ = NotificationsViewModel.shared // Initialize the singleton early
            _ = ProviderUsageStore.shared
            Task { await ProviderUsageStore.shared.activate() }
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
            // After workspace switch, rings were cleared by beginViewSwap — sync the count
            if let workspace = self?.workspaceManager?.activeWorkspace {
                workspace.terminalNotificationCount = self?.contentAreaView?.paneIDsWithNotificationRings.count ?? 0
            }
            self?.updateNotificationBadge()
        }
        workspaceManager?.onNotificationCountChanged = { [weak self] _ in
            self?.updateNotificationBadge()
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
        providerUsageStoreObserver = NotificationCenter.default.addObserver(
            forName: .providerUsageStoreDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateUsageToolbarStatus()
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
        if let providerUsageStoreObserver {
            NotificationCenter.default.removeObserver(providerUsageStoreObserver)
            self.providerUsageStoreObserver = nil
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
        guard let contentArea = contentAreaView else { return .terminateNow }
        contentArea.anyPaneRequiresCloseConfirmation { [weak self] requiresConfirmation in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }
            if requiresConfirmation {
                self.confirmClose(
                    title: "Quit Pnevma?",
                    message: "The terminal still has a running process. If you quit the process will be killed.",
                    onCancel: {
                        sender.reply(toApplicationShouldTerminate: false)
                    }
                ) {
                    sender.reply(toApplicationShouldTerminate: true)
                }
            } else {
                sender.reply(toApplicationShouldTerminate: true)
            }
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
        contentAreaView?.availableLiveSessionsProvider = { [weak self] in
            self?.sessionStore?.sessions ?? []
        }

        contentAreaView?.onActivePaneChanged = { [weak self] _ in
            if let view = self?.contentAreaView?.activePaneView {
                self?.statusBar?.updateActivePane(view.title)
            }
            // Focusing a pane dismisses its notification ring, so reset the terminal count
            // based on how many rings are still active.
            if let self, let workspace = self.workspaceManager?.activeWorkspace {
                let activeRings = self.contentAreaView?.paneIDsWithNotificationRings.count ?? 0
                workspace.terminalNotificationCount = activeRings
                self.updateNotificationBadge()
                self.updateTabBar()
            }
            self?.persistence?.markDirty()
        }
        contentAreaView?.onPanePersistenceChanged = { [weak self] in
            self?.persistence?.markDirty()
        }

        contentAreaView?.onTerminalNotification = { [weak self] in
            guard let self, let workspace = self.workspaceManager?.activeWorkspace else { return }
            workspace.terminalNotificationCount += 1
            self.updateNotificationBadge()
            self.updateTabBar()
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
            onOpenTool: { [weak self] (toolID: String) in self?.openToolWithDefaultPresentation(toolID) },
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
        self.sidebarToggleBtn = sidebarToggleBtn
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
        let badge = BadgeOverlayView(frame: NSRect(x: 12, y: 0, width: 18, height: 12))
        notificationsBtn.addSubview(badge)
        notificationBadge = badge
        let usageBtn = makeTitlebarButton(
            symbolName: "chart.line.uptrend.xyaxis",
            accessibilityDescription: "Usage",
            toolTip: "Usage",
            action: #selector(showUsagePopover),
            size: titlebarButtonSize,
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemBlue
        )
        usageToolbarButton = usageBtn
        let statusDot = StatusDotOverlayView(frame: NSRect(x: 16, y: 3, width: 8, height: 8))
        usageBtn.addSubview(statusDot)
        usageStatusDot = statusDot
        let addWorkspaceBtn = makeTitlebarButton(
            symbolName: "plus",
            accessibilityDescription: "Open Workspace",
            toolTip: "Open Workspace",
            action: #selector(openWorkspaceAction),
            size: titlebarButtonSize,
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemGreen
        )

        // Layout template button — positioned at the content area leading edge
        let templateBtn = makeTitlebarButton(
            symbolName: "rectangle.split.2x1",
            accessibilityDescription: "Layout Templates",
            toolTip: "Layout Templates",
            action: #selector(titlebarTemplateAction),
            size: titlebarButtonSize,
            symbolConfig: titlebarSymbolConfig
        )
        self.titlebarTemplateBtn = templateBtn

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
                      sidebarToggleBtn, notificationsBtn, usageBtn, addWorkspaceBtn,
                      templateBtn,
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

        // Titlebar fill bottom tracks the safe area in windowed mode but
        // gets a minimum height in fullscreen so buttons don't get clipped.
        let titlebarBottom = titlebarFill.bottomAnchor.constraint(equalTo: windowContent.safeAreaLayoutGuide.topAnchor)
        titlebarBottom.priority = .defaultHigh
        self.titlebarFillBottomConstraint = titlebarBottom

        let titlebarMinHeight = titlebarFill.heightAnchor.constraint(greaterThanOrEqualToConstant: 38)
        titlebarMinHeight.isActive = false
        self.titlebarFillMinHeightConstraint = titlebarMinHeight

        let sidebarToggleLeading = sidebarToggleBtn.leadingAnchor.constraint(
            equalTo: windowContent.leadingAnchor, constant: 76
        )
        self.sidebarToggleLeadingConstraint = sidebarToggleLeading

        let sidebarToggleWidth = sidebarToggleBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width)
        let sidebarToggleHeight = sidebarToggleBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height)
        self.sidebarToggleWidthConstraint = sidebarToggleWidth
        self.sidebarToggleHeightConstraint = sidebarToggleHeight

        let minContentWidth = win.minSize.width - sidebarWidth
        NSLayoutConstraint.activate([
            sidebarToggleLeading,
            titlebarFill.topAnchor.constraint(equalTo: windowContent.topAnchor),
            titlebarBottom,
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
            toolbarSep.topAnchor.constraint(equalTo: titlebarFill.bottomAnchor),
            toolbarSep.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
            toolbarSep.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            toolbarSep.heightAnchor.constraint(equalToConstant: DesignTokens.Layout.dividerWidth),

            // Titlebar buttons — vertically centered in titlebar area
            sidebarToggleBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            sidebarToggleWidth,
            sidebarToggleHeight,

            notificationsBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            notificationsBtn.trailingAnchor.constraint(equalTo: addWorkspaceBtn.leadingAnchor, constant: -4),
            notificationsBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            notificationsBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

            usageBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            usageBtn.trailingAnchor.constraint(equalTo: notificationsBtn.leadingAnchor, constant: -4),
            usageBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            usageBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

            addWorkspaceBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            addWorkspaceBtn.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor, constant: -12),
            addWorkspaceBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            addWorkspaceBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

            // Titlebar actions (Open, Commit, Push) — direct subviews, right of center
            pushBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            pushBtn.trailingAnchor.constraint(equalTo: usageBtn.leadingAnchor, constant: -12),

            commitBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            commitBtn.trailingAnchor.constraint(equalTo: pushBtn.leadingAnchor, constant: -6),

            openBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            openBtn.trailingAnchor.constraint(equalTo: commitBtn.leadingAnchor, constant: -6),

            // Layout template button — right of sidebar toggle (tracks its position)
            templateBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            templateBtn.leadingAnchor.constraint(equalTo: sidebarToggleBtn.trailingAnchor, constant: 4),
            templateBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            templateBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),
        ])
        updateUsageToolbarStatus()

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

        if AppLaunchContext.smokeMode != nil {
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
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Layout Templates\u{2026}", action: #selector(titlebarTemplateAction), keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
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
        guard isActiveTab, let contentArea = contentAreaView else {
            performCloseTab(at: index)
            return
        }
        contentArea.anyPaneRequiresCloseConfirmation { [weak self] requiresConfirmation in
            if requiresConfirmation {
                self?.confirmClose(
                    title: "Close Tab?",
                    message: "The terminal still has a running process. If you close the tab the process will be killed."
                ) {
                    self?.performCloseTab(at: index)
                }
            } else {
                self?.performCloseTab(at: index)
            }
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
        let notifyingPanes = contentAreaView?.paneIDsWithNotificationRings ?? []
        tabBarView?.tabs = workspace.tabs.enumerated().map { (i, tab) in
            let isActive = i == workspace.activeTabIndex
            let hasNotification: Bool
            if isActive {
                hasNotification = false
            } else {
                let tabPaneIDs = Set(tab.layoutEngine.root?.allPaneIDs ?? [])
                hasNotification = !tabPaneIDs.isDisjoint(with: notifyingPanes)
            }
            return TabBarView.Tab(id: tab.id, title: tab.title, isActive: isActive, hasNotification: hasNotification)
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
        contentArea.activePaneRequiresCloseConfirmation { [weak self, weak contentArea] requiresConfirmation in
            guard let contentArea else { return }
            if requiresConfirmation {
                self?.confirmClose(
                    title: "Close Terminal?",
                    message: "The terminal still has a running process. If you close the terminal the process will be killed."
                ) {
                    contentArea.closeActivePane()
                }
            } else {
                contentArea.closeActivePane()
            }
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
        let toolCommands: [(title: String, category: String, shortcut: String?, description: String?, paneType: String)] = [
            ("Show Task Board", "tool", nil, "Show the kanban task board", "taskboard"),
            ("Show Analytics", "tool", nil, "Show the usage analytics dashboard", "analytics"),
            ("Show Daily Brief", "tool", nil, "Show the daily summary dashboard", "daily_brief"),
            ("Show Notifications", "tool", nil, "Show project notifications and alerts", "notifications"),
            ("Show Review", "tool", nil, "Show review diffs and acceptance criteria", "review"),
            ("Show Merge Queue", "tool", nil, "Show branch merge order and conflicts", "merge_queue"),
            ("Show Diff Viewer", "tool", nil, "Show file-level diffs for tasks", "diff"),
            ("Show Search", "tool", nil, "Show project-wide search", "search"),
            ("Show File Browser", "tool", nil, "Show the project file browser", "file_browser"),
            ("Show Rules Manager", "tool", nil, "Show project rules and conventions", "rules"),
            ("Show Workflow", "tool", nil, "Show the workflow state machine", "workflow"),
            ("Show SSH Manager", "tool", nil, "Show SSH keys and remote profiles", "ssh"),
            ("Show Session Replay", "tool", nil, "Show past terminal session replays", "replay"),
            ("Show Browser", "tool", nil, "Show the built-in web browser", "browser"),
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
            CommandItem(id: "view.layout_templates", title: "Layout Templates", category: "view", shortcut: "", description: "Save or load pane layout templates") { [weak self] in
                self?.titlebarTemplateAction()
            },
            CommandItem(id: "workspace.next", title: "Next Workspace", category: "view", shortcut: "Shift+Cmd+]", description: "Switch to the next workspace") { [weak self] in
                self?.nextWorkspace()
            },
            CommandItem(id: "workspace.prev", title: "Previous Workspace", category: "view", shortcut: "Shift+Cmd+[", description: "Switch to the previous workspace") { [weak self] in
                self?.previousWorkspace()
            },
        ]

        for (idx, toolCommand) in toolCommands.enumerated() {
            commands.append(CommandItem(
                id: "tool.show_\(idx)",
                title: toolCommand.title,
                category: toolCommand.category,
                shortcut: toolCommand.shortcut,
                description: toolCommand.description
            ) { [weak self] in
                self?.openPaneTypeWithDefaultPresentation(toolCommand.paneType)
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
        let persistenceToggle = makePersistenceToggle()
        alert.accessoryView = makePersistenceAccessory(
            toggle: persistenceToggle,
            helperLabel: makePersistenceHelperLabel(),
            width: 320
        )
        alert.addButton(withTitle: "Local")
        alert.addButton(withTitle: "Remote")
        alert.addButton(withTitle: "Cancel")

        let terminalMode: WorkspaceTerminalMode = persistenceToggle.state == .on ? .persistent : .nonPersistent

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            presentOpenLocalWorkspacePanel(terminalMode: terminalMode)
        case .alertSecondButtonReturn:
            Task { @MainActor [weak self] in
                await self?.presentOpenRemoteWorkspacePanel(terminalMode: terminalMode)
            }
        default:
            break
        }
    }

    private func presentOpenLocalWorkspacePanel(terminalMode: WorkspaceTerminalMode) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Workspace"
        panel.message = "Select a local project directory"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openLocalWorkspace(
            path: url.path,
            terminalMode: terminalMode
        )
    }

    private func ensureRemoteNativeToolingSupport() -> Bool {
        guard WorkspaceProjectTransportSupport.hasRemoteNativeToolingSupport() else {
            let alert = NSAlert()
            alert.messageText = "sshfs Required"
            alert.informativeText = "Remote native tools require sshfs/macFUSE on this Mac. Install sshfs before creating a remote workspace."
            alert.runModal()
            return false
        }
        return true
    }

    private func presentOpenRemoteWorkspacePanel(terminalMode: WorkspaceTerminalMode) async {
        guard let bus = commandBus else { return }
        guard ensureRemoteNativeToolingSupport() else { return }

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
            alert.informativeText = "Select an SSH preset and enter the remote project path. Native project tools use an sshfs mount of the remote workspace."

            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            profiles.forEach { profile in
                popup.addItem(withTitle: "\(profile.name) (\(profile.user)@\(profile.host):\(profile.port))")
            }

            let pathField = NSTextField(string: "~")
            pathField.placeholderString = "/path/to/project"

            let profileLabel = NSTextField(labelWithString: "SSH Preset")
            let pathLabel = NSTextField(labelWithString: "Remote Project Path")
            let accessory = NSStackView(views: [
                profileLabel,
                popup,
                pathLabel,
                pathField,
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
                terminalMode: terminalMode
            )
        } catch {
            ToastManager.shared.show(
                error.localizedDescription,
                icon: "exclamationmark.triangle",
                style: .error
            )
        }
    }

    func presentOpenRemoteWorkspacePanel(forTailscaleDevice device: TailscaleDevice) {
        guard ensureRemoteNativeToolingSupport() else { return }

        let alert = NSAlert()
        alert.messageText = "Open Remote Workspace"
        alert.informativeText = "Open a remote workspace for this Tailscale device. Native project tools use an sshfs mount of the remote workspace."

        let hostLabel = NSTextField(labelWithString: "Tailscale Device")
        let hostValue = NSTextField(labelWithString: "\(device.hostname) (\(device.ipAddress))")
        hostValue.lineBreakMode = .byTruncatingMiddle

        let userLabel = NSTextField(labelWithString: "SSH User")
        let userField = NSTextField(string: NSUserName())

        let portLabel = NSTextField(labelWithString: "SSH Port")
        let portField = NSTextField(string: "22")

        let pathLabel = NSTextField(labelWithString: "Remote Project Path")
        let pathField = NSTextField(string: "~")
        pathField.placeholderString = "/path/to/project"

        let persistenceToggle = makePersistenceToggle()

        let accessory = NSStackView(views: [
            hostLabel,
            hostValue,
            userLabel,
            userField,
            portLabel,
            portField,
            pathLabel,
            pathField,
            makePersistenceAccessory(
                toggle: persistenceToggle,
                helperLabel: makePersistenceHelperLabel(),
                width: 360
            ),
        ])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        accessory.translatesAutoresizingMaskIntoConstraints = false
        hostValue.widthAnchor.constraint(equalToConstant: 360).isActive = true
        userField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        portField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        pathField.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Open Workspace")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let user = userField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
            ToastManager.shared.show(
                "SSH user is required",
                icon: "exclamationmark.triangle",
                style: .error
            )
            return
        }

        guard let port = Int(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65535).contains(port) else {
            ToastManager.shared.show(
                "SSH port must be between 1 and 65535",
                icon: "exclamationmark.triangle",
                style: .error
            )
            return
        }

        let remotePath = pathField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remotePath.isEmpty else {
            ToastManager.shared.show(
                "Remote path is required",
                icon: "exclamationmark.triangle",
                style: .error
            )
            return
        }

        openRemoteWorkspace(
            target: device.remoteWorkspaceTarget(
                user: user,
                port: port,
                remotePath: remotePath
            ),
            terminalMode: persistenceToggle.state == .on ? .persistent : .nonPersistent
        )
    }

    private func makePersistenceToggle() -> NSButton {
        let toggle = NSButton(
            checkboxWithTitle: "Enable session persistence",
            target: nil,
            action: nil
        )
        toggle.state = .on
        toggle.toolTip = "Persistent workspaces use tmux-backed managed sessions. Unchecked starts a plain shell."
        toggle.setAccessibilityLabel("Enable session persistence")
        return toggle
    }

    private func makePersistenceHelperLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "Persistent workspaces use tmux-backed managed sessions. Unchecked starts a plain shell.")
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func makePersistenceAccessory(
        toggle: NSButton,
        helperLabel: NSTextField,
        width: CGFloat
    ) -> NSView {
        helperLabel.preferredMaxLayoutWidth = width

        let stack = NSStackView(views: [toggle, helperLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        container.layoutSubtreeIfNeeded()
        container.frame.size = container.fittingSize
        return container
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
        guard let workspaceManager else {
            ToastManager.shared.show(
                "Workspace manager unavailable",
                icon: "exclamationmark.triangle",
                style: .error
            )
            return
        }
        workspaceManager.createRemoteWorkspace(
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
        guard let tool = sidebarTool(id: toolID, in: workspaceManager?.activeWorkspace) else {
            return nil
        }
        return PaneFactory.make(type: tool.paneType)?.1
    }

    private func replaceActivePaneWithTool(_ toolID: String) {
        guard sidebarTool(id: toolID, in: workspaceManager?.activeWorkspace) != nil else {
            return
        }
        guard let pane = makeToolPane(toolID) else { return }
        if contentAreaView?.replaceActivePane(with: pane) == nil {
            contentAreaView?.setRootPane(pane)
        }
    }

    private enum ToolReuseScope {
        case activeTab
        case anyTab
    }

    @discardableResult
    private func focusExistingTool(_ tool: SidebarToolItem, scope: ToolReuseScope) -> Bool {
        guard let workspace = workspaceManager?.activeWorkspace else { return false }

        let location: WorkspacePaneLocation?
        switch scope {
        case .activeTab:
            if let paneID = workspace.activeTabPaneID(ofType: tool.paneType) {
                location = WorkspacePaneLocation(tabIndex: workspace.activeTabIndex, paneID: paneID)
            } else {
                location = nil
            }
        case .anyTab:
            location = workspace.preferredPaneLocation(ofType: tool.paneType)
        }

        guard let location else { return false }

        if location.tabIndex != workspace.activeTabIndex {
            workspace.tabs[location.tabIndex].layoutEngine.setActivePane(location.paneID)
            switchToTab(location.tabIndex)
            contentAreaView?.focusPane(location.paneID)
            return true
        }

        contentAreaView?.focusPane(location.paneID)
        persistence?.markDirty()
        return true
    }

    private func openToolWithDefaultPresentation(_ toolID: String) {
        guard let tool = sidebarTool(id: toolID, in: workspaceManager?.activeWorkspace) else {
            return
        }
        switch tool.defaultPresentation {
        case .pane:
            openToolAsPane(toolID)
        case .tab:
            openToolAsTab(toolID)
        }
    }

    private func openPaneTypeWithDefaultPresentation(_ paneType: String) {
        if let tool = sidebarToolDefinition(paneType: paneType) {
            openToolWithDefaultPresentation(tool.id)
            return
        }

        guard let pane = PaneFactory.make(type: paneType)?.1 else { return }
        if contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane) == nil,
           contentAreaView?.activePaneView == nil {
            contentAreaView?.setRootPane(pane)
        }
        persistence?.markDirty()
    }

    private func openToolAsTab(_ toolID: String) {
        guard let workspace = workspaceManager?.activeWorkspace,
              let tool = sidebarTool(id: toolID, in: workspace),
              PaneFactory.isPaneTypeAvailable(tool.paneType, in: workspace) else { return }
        if focusExistingTool(tool, scope: .anyTab) {
            return
        }
        let title = tool.title
        contentAreaView?.syncPersistedPanes()
        _ = workspace.addTab(title: title)
        workspace.ensureActiveTabHasDisplayableRootPane()
        contentAreaView?.setLayoutEngine(workspace.layoutEngine)
        updateTabBar()
        replaceActivePaneWithTool(toolID)
        persistence?.markDirty()
    }

    private func openToolAsPane(_ toolID: String) {
        guard let tool = sidebarTool(id: toolID, in: workspaceManager?.activeWorkspace) else { return }
        if focusExistingTool(tool, scope: .activeTab) {
            return
        }
        guard let pane = makeToolPane(toolID) else { return }
        if contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane) == nil,
           contentAreaView?.activePaneView == nil {
            contentAreaView?.setRootPane(pane)
        }
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
    private var usagePopover: NSPopover?
    private var sessionsPopover: NSPopover?
    private weak var notificationToolbarButton: NSButton?
    private weak var notificationBadge: BadgeOverlayView?
    private weak var usageToolbarButton: NSButton?
    private weak var usageStatusDot: StatusDotOverlayView?

    private func startSessionFromSessionManager() {
        sessionsPopover?.performClose(nil)
        newTerminal()
    }

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
            rootView: SessionManagerPopoverView(
                store: sessionStore,
                onNewSession: { [weak self] in self?.startSessionFromSessionManager() }
            )
                .environment(GhosttyThemeProvider.shared)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        sessionsPopover = popover
    }

    private func updateNotificationBadge() {
        guard let workspace = workspaceManager?.activeWorkspace else {
            notificationBadge?.count = 0
            return
        }
        notificationBadge?.count = workspace.unreadNotifications + workspace.terminalNotificationCount
    }

    private func updateUsageToolbarStatus() {
        guard let usageStatusDot else { return }
        switch ProviderUsageStore.shared.indicatorState {
        case .hidden:
            usageStatusDot.status = .hidden
        case .ok:
            usageStatusDot.status = .ok
        case .warning:
            usageStatusDot.status = .warning
        case .error:
            usageStatusDot.status = .error
        }
    }

    @objc private func showNotifications() {
        if let popover = notificationsPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = notificationToolbarButton else { return }

        // Ensure data is loaded (idempotent if already active)
        Task { await NotificationsViewModel.shared.activate() }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 380, height: 400)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: NotificationsPopoverView(onViewAll: { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.openNotificationsPane()
            })
            .environment(GhosttyThemeProvider.shared)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        notificationsPopover = popover
    }

    private func openNotificationsPane() {
        openToolWithDefaultPresentation("notifications")
    }

    @objc private func showUsagePopover() {
        if let popover = usagePopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = usageToolbarButton else { return }

        Task { await ProviderUsageStore.shared.activate() }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 420)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: ProviderUsagePopoverView(onOpenDashboard: { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.openUsageDashboard()
            })
            .environment(GhosttyThemeProvider.shared)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        usagePopover = popover
    }

    private func openUsageDashboard() {
        AnalyticsNavigationHub.shared.request(segmentRawValue: "providers")
        openToolWithDefaultPresentation("analytics")
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

    // MARK: - Layout Template Actions

    @objc func titlebarTemplateAction() {
        guard let btn = titlebarTemplateBtn else { return }
        let templates = LayoutTemplateStore.list()
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 300, height: min(CGFloat(templates.count) * 48 + 120, 360))
        popover.behavior = .transient
        popover.animates = true
        let view = LayoutTemplatePopoverView(
            templates: templates,
            onSave: { [weak self] name in
                popover.performClose(nil)
                self?.saveCurrentLayoutAsTemplate(name: name)
            },
            onSelect: { [weak self] template in
                popover.performClose(nil)
                self?.applyLayoutTemplate(template)
            },
            onDelete: { [weak self] template in
                LayoutTemplateStore.delete(template)
                popover.performClose(nil)
                DispatchQueue.main.async {
                    self?.titlebarTemplateAction()
                }
            },
            onDismiss: { popover.performClose(nil) }
        )
        popover.contentViewController = NSHostingController(rootView: view)
        popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
    }

    private func saveCurrentLayoutAsTemplate(name: String) {
        guard let contentArea = contentAreaView else { return }
        contentArea.syncPersistedPanes()
        guard let template = LayoutTemplateStore.capture(
            name: name,
            engine: contentArea.layoutEngine
        ) else { return }
        do {
            try LayoutTemplateStore.save(template)
        } catch {
            Log.general.error("Failed to save layout template: \(error)")
        }
    }

    private func applyLayoutTemplate(_ template: LayoutTemplate) {
        guard let contentArea = contentAreaView else { return }
        LayoutTemplateStore.apply(template, to: contentArea)
        persistence?.markDirty()
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
    public func windowDidEnterFullScreen(_ notification: Notification) {
        titlebarFillMinHeightConstraint?.isActive = true
        // Traffic lights are hidden in fullscreen — pull sidebar toggle to the left edge and shrink 10%
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.normal
            ctx.allowsImplicitAnimation = true
            sidebarToggleLeadingConstraint?.animator().constant = 12
            sidebarToggleWidthConstraint?.animator().constant = 23
            sidebarToggleHeightConstraint?.animator().constant = 20
        }
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        titlebarFillMinHeightConstraint?.isActive = false
        // Traffic lights reappear — restore gap and size
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.normal
            ctx.allowsImplicitAnimation = true
            sidebarToggleLeadingConstraint?.animator().constant = 76
            sidebarToggleWidthConstraint?.animator().constant = 26
            sidebarToggleHeightConstraint?.animator().constant = 22
        }
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closeConfirmed {
            closeConfirmed = false
            return true
        }
        guard let contentArea = contentAreaView else { return true }
        contentArea.anyPaneRequiresCloseConfirmation { [weak self] requiresConfirmation in
            guard let self else { return }
            if requiresConfirmation {
                self.confirmClose(
                    title: "Close Window?",
                    message: "The terminal still has a running process. If you close the window the process will be killed."
                ) {
                    self.closeConfirmed = true
                    self.window?.close()
                }
            } else {
                self.closeConfirmed = true
                self.window?.close()
            }
        }
        return false
    }
}

// MARK: - Close Confirmation

extension AppDelegate {
    /// Show a confirmation alert styled like Ghostty's close prompts.
    func confirmClose(
        title: String,
        message: String,
        onCancel: (() -> Void)? = nil,
        onConfirm: @escaping () -> Void
    ) {
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
            } else {
                onCancel?()
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
    @State private var viewModel = NotificationsViewModel.shared
    var onViewAll: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer()
                Button("Mark All Read") { viewModel.markAllRead() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if let statusMessage = viewModel.statusMessage {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else if viewModel.filteredNotifications.isEmpty {
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
            } else {
                List(viewModel.filteredNotifications.prefix(10)) { notification in
                    NotificationRow(notification: notification)
                        .onTapGesture { viewModel.markRead(notification.id) }
                }
                .listStyle(.plain)
            }

            Divider()

            Button(action: { onViewAll?() }) {
                Text("View All")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.plain)
        }
    }
}

private final class BadgeOverlayView: NSView {
    var count: Int = 0 {
        didSet {
            isHidden = count <= 0
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard count > 0 else { return }

        let text = count > 99 ? "99+" : "\(count)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)

        let capsuleWidth = max(textSize.width + 6, 14)
        let capsuleHeight: CGFloat = 12
        let capsuleRect = NSRect(
            x: bounds.width - capsuleWidth,
            y: 0,
            width: capsuleWidth,
            height: capsuleHeight
        )
        let capsulePath = NSBezierPath(roundedRect: capsuleRect, xRadius: capsuleHeight / 2, yRadius: capsuleHeight / 2)
        NSColor.systemRed.setFill()
        capsulePath.fill()

        let textRect = NSRect(
            x: capsuleRect.midX - textSize.width / 2,
            y: capsuleRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        (text as NSString).draw(in: textRect, withAttributes: attributes)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class StatusDotOverlayView: NSView {
    enum Status {
        case hidden
        case ok
        case warning
        case error
    }

    var status: Status = .hidden {
        didSet {
            isHidden = status == .hidden
            needsDisplay = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard status != .hidden else { return }
        let color: NSColor = switch status {
        case .hidden:
            .clear
        case .ok:
            .systemGreen
        case .warning:
            .systemOrange
        case .error:
            .systemRed
        }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        color.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.35).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
