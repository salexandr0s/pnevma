import Cocoa
#if canImport(GhosttyKit)
import GhosttyKit
#endif
import SwiftUI
import os

private enum UITestReadinessState: String {
    case terminalReady = "terminal-ready"
    case projectOpening = "project-opening"
    case projectReady = "project-ready"
    case projectOpenFailed = "project-open-failed"
}

private final class UITestReadinessView: NSView {
    var state: String = "launching"
    var detail: String?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityIdentifier() -> String { "ui-test.readiness" }
    override func accessibilityLabel() -> String? { state }
    override func accessibilityValue() -> Any? { detail }
}

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    var window: NSWindow?
    private var bridge: PnevmaBridge?
    private var commandBus: (any CommandCalling)?
    private var fallbackCommandBus: CommandBus?
    private var activeCommandBus: ActiveWorkspaceCommandBus?
    private var sessionBridge: SessionBridge?
    private var sessionStore: SessionStore?
    private var workspaceManager: WorkspaceManager?
    private var commandCenterStore: CommandCenterStore?
    private var commandCenterWindowController: CommandCenterWindowController?
    private var contentAreaView: ContentAreaView?
    private var tabBarView: TabBarView?
    private var titlebarStatusView: TitlebarStatusView?
    private var toolDockHostView: NSView?
    private var toolDockHeightConstraint: NSLayoutConstraint?
    private var sidebarHostView: NSView?
    private var sidebarContentView: NSView?
    private var sidebarTopToTitlebar: NSLayoutConstraint?
    private var sidebarTopToToolbarSep: NSLayoutConstraint?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var rightInspectorHostView: NSView?
    private var rightInspectorWidthConstraint: NSLayoutConstraint?
    private var rightInspectorResizerView: NSView?
    private var rightInspectorOverlayBlockerView: RightInspectorOverlayBlockerView?
    private var rightInspectorOverlayHostView: RightInspectorOverlayHostingView<AnyView>?
    private var browserDrawerOverlayBlockerView: BrowserDrawerOverlayBlockerView?
    private var browserDrawerOverlayHostView: BrowserDrawerOverlayHostingView<AnyView>?
    private var toolDrawerOverlayBlockerView: ToolDrawerOverlayBlockerView?
    private var toolDrawerOverlayHostView: ToolDrawerOverlayHostingView<AnyView>?
    private var uiTestReadinessView: UITestReadinessView?
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var contentMinWidthConstraint: NSLayoutConstraint?
    private var tabBarLeadingConstraint: NSLayoutConstraint?
    private var agentStripTopToTabBar: NSLayoutConstraint?
    private var agentStripTopToToolbarSep: NSLayoutConstraint?
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
    private let agentStripState = AgentStripState()
    private var agentStripHostView: NSView?
    private var agentStripHeightConstraint: NSLayoutConstraint?
    private var persistence: SessionPersistence?
    private var isSidebarVisible = true
    private var currentSidebarMode: SidebarMode = SidebarPreferences.sidebarMode
    private var collapsedRailHostView: NSView?
    private var isFocusMode = false
    private var focusModeEscapeHatchWindow: NSWindow?
    private var focusModeResizeObserver: NSObjectProtocol?
    private var preFocusSidebarVisible = true
    private var preFocusInspectorVisible = false
    private var preFocusSidebarMode: SidebarMode = .expanded
    private var isRightInspectorVisible = true
    private var sidebarTransitionGeneration: UInt64 = 0
    private var rightInspectorTransitionGeneration: UInt64 = 0
    private var rightInspectorStoredWidth = DesignTokens.Layout.rightInspectorDefaultWidth
    private var restoredCommandCenterWindowFrame: NSRect?
    private var restoredCommandCenterVisible = false
    private let rightInspectorChromeState = RightInspectorChromeState()
    private let browserDrawerChromeState = BrowserDrawerChromeState()
    private let browserDrawerPresentationModel = BrowserDrawerPresentationModel()
    private let toolDrawerChromeState = ToolDrawerChromeState()
    private let toolDrawerContentModel = ToolDrawerContentModel()
    private var browserToolBridge: BrowserToolBridge?
    private var terminalOpenURLObserver: NSObjectProtocol?
    private var nativeNotificationBridgeObserverID: UUID?
    private var browserSessions: [UUID: BrowserWorkspaceSession] = [:]
    private var browserSessionPrewarmTask: Task<Void, Never>?
    private weak var browserDrawerPreviousFirstResponder: NSResponder?
    private weak var toolDrawerPreviousFirstResponder: NSResponder?
    private lazy var rightInspectorFileBrowserViewModel = FileBrowserViewModel(
        commandBus: commandBus ?? CommandBus.shared
    )
    private lazy var rightInspectorWorkspaceChangesViewModel = WorkspaceChangesViewModel(
        commandBus: commandBus ?? CommandBus.shared
    )
    private lazy var rightInspectorReviewViewModel = ReviewViewModel(
        commandBus: commandBus ?? CommandBus.shared
    )
    private lazy var rightInspectorMergeQueueViewModel = MergeQueueViewModel(
        commandBus: commandBus ?? CommandBus.shared
    )
    private var closeConfirmed = false
    private var toastController: ToastWindowController?
    private var settingsWindow: NSWindow?
    private var smokeWindow: NSWindow?
    private var smokeHostView: TerminalHostView?
    private var smokeTimeoutWorkItem: DispatchWorkItem?
    private var runtimeSettingsObserver: NSObjectProtocol?
    private var providerUsageStoreObserver: NSObjectProtocol?
    private var openerViewModel: WorkspaceOpenerViewModel?
    private var openerPanel: NSPanel?
    private let toolDockState = ToolDockState()
    private var isToolDockContentHovered = false
    private var isToolDockEdgeHovered = false
    private var isToolDockHovered: Bool { isToolDockContentHovered || isToolDockEdgeHovered }
    private var toolDockCollapseWorkItem: DispatchWorkItem?
    private var toolDockTriggerView: NSView?
    var updateCoordinator: AppUpdateCoordinator?

    private var activeWorkspaceSupportsRightInspector: Bool {
        workspaceManager?.activeWorkspace?.showsProjectToolsInUI == true
    }

    private var isRightInspectorPresented: Bool {
        isRightInspectorVisible && activeWorkspaceSupportsRightInspector
    }

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
            AppRuntimeSettings.shared.startWatchingConfigFile()
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

        // Request notification permission and register delegate
        NativeNotificationManager.shared.setup()

        // Reload ghostty config now that window exists so appearance-conditional
        // themes (e.g. light:X,dark:Y) resolve correctly.
        let reloadedConfig = TerminalConfig()
        TerminalSurface.applyGhosttyConfig(reloadedConfig)
        TerminalSurface.reapplyColorScheme()
        GhosttyConfigController.shared.updateConfigOwner(reloadedConfig)
        GhosttyConfigController.shared.startWatchingConfigFile()
        GhosttyThemeProvider.shared.refresh()

        if let restoredState {
            applyRestoredState(restoredState)
            if restoredCommandCenterVisible {
                showCommandCenter(makeKey: false)
            }
        } else if let uiTestProjectPath = AppLaunchContext.uiTestProjectPath {
            workspaceManager?.ensureTerminalWorkspace(name: AppLaunchContext.initialWorkspaceName)
            setUITestReadiness(.projectOpening)
            Task { @MainActor [weak self] in
                await self?.openUITestProjectWorkspace(path: uiTestProjectPath)
            }
        } else {
            workspaceManager?.ensureTerminalWorkspace(name: AppLaunchContext.initialWorkspaceName)
            setUITestReadiness(.terminalReady)
        }

        // Build menu bar, then apply any custom keybindings from the loaded settings.
        // (AppRuntimeSettings.apply() called applyToMenu before the menu existed.)
        NSApplication.shared.mainMenu = buildMainMenu()
        AppKeybindingManager.shared.applyToMenu(NSApplication.shared.mainMenu!)

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
                    commandCenterWindowFrame: nil,
                    commandCenterVisible: false,
                    workspaces: [],
                    activeWorkspaceID: nil,
                    sidebarVisible: true,
                    rightInspectorVisible: true,
                    rightInspectorWidth: Double(DesignTokens.Layout.rightInspectorDefaultWidth)
                )
            }
            return self.buildSessionState()
        }
        if !AppLaunchContext.isTesting {
            persistence?.startAutoSave()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        ChromeTransitionCoordinator.shared.reset()
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
            let fallbackCommandBus = CommandBus(bridge: bridge)
            self.fallbackCommandBus = fallbackCommandBus
            let activeCommandBus = ActiveWorkspaceCommandBus(
                fallback: fallbackCommandBus,
                activeCommandBusProvider: { [weak self] in
                    self?.workspaceManager?.activeRuntime?.commandBus
                }
            )
            self.activeCommandBus = activeCommandBus
            commandBus = activeCommandBus
            CommandBus.shared = activeCommandBus
        }

        if !AppLaunchContext.uiTestLightweightMode {
            TerminalSurface.initializeGhostty()
        }

        if let fallbackCommandBus {
            workspaceManager = WorkspaceManager()
            if let workspaceManager {
                let commandCenterStore = CommandCenterStore(workspaceManager: workspaceManager)
                commandCenterStore.onPerformAction = { [weak self] action, run in
                    self?.performCommandCenterAction(action, run: run)
                }
                self.commandCenterStore = commandCenterStore
            }
            let sessionBridge = SessionBridge(commandBus: self.commandBus ?? fallbackCommandBus) { [weak self] in
                self?.workspaceManager?.activeWorkspace?.defaultWorkingDirectory
            }
            self.sessionBridge = sessionBridge
            SessionBridge.shared = sessionBridge
            PaneFactory.sessionBridge = sessionBridge
            PaneFactory.activeWorkspaceProvider = { [weak self] in
                self?.workspaceManager?.activeWorkspace
            }
            PaneFactory.browserSessionProvider = { [weak self] workspace in
                self?.browserSession(for: workspace) ?? BrowserWorkspaceSession()
            }
            let sessionStore = SessionStore(commandBus: self.commandBus ?? fallbackCommandBus)
            self.sessionStore = sessionStore
            Task { await sessionStore.activate() }
            _ = NotificationsViewModel.shared // Initialize the singleton early
            if !AppLaunchContext.uiTestLightweightMode {
                _ = ProviderUsageStore.shared
                Task { await ProviderUsageStore.shared.activate() }
            }
            browserToolBridge = BrowserToolBridge(
                sessionProvider: { [weak self] in
                    self?.workspaceManager?.activeWorkspace.flatMap { self?.browserSession(for: $0) }
                },
                commandBusProvider: { [weak self] in
                    self?.workspaceManager?.activeRuntime?.commandBus
                },
                ensureBrowserVisible: { [weak self] url in
                    self?.openBrowserInWorkspace(url: url, source: .automation)
                }
            )
        }
        workspaceManager?.onActiveWorkspaceChanged = { [weak self] engine in
            _ = engine
            self?.contentAreaView?.syncPersistedPanes()
            if let workspace = self?.workspaceManager?.activeWorkspace {
                workspace.ensureActiveTabHasDisplayableRootPane()
                self?.contentAreaView?.setLayoutEngine(workspace.layoutEngine)
            }
            self?.updateTabBar()
            self?.updateToolDockState()
            self?.persistence?.markDirty()
            // After workspace switch, rings were cleared by beginViewSwap — sync the count
            if let workspace = self?.workspaceManager?.activeWorkspace {
                workspace.terminalNotificationCount = self?.contentAreaView?.paneIDsWithNotificationRings.count ?? 0
            }
            self?.syncRightInspectorPresentation(animated: false)
            self?.refreshBrowserDrawerOverlayRootView()
            if let workspace = self?.workspaceManager?.activeWorkspace {
                self?.scheduleBrowserSessionPrewarm(for: workspace)
                self?.titlebarStatusView?.updateBranch(workspace.gitBranch)
                self?.titlebarStatusView?.updateAgents(workspace.activeAgents)
            } else {
                self?.titlebarStatusView?.updateBranch(nil)
                self?.titlebarStatusView?.updateAgents(0)
            }
            self?.updateNotificationBadge()
            self?.refreshAgentStrip()
        }
        workspaceManager?.onNotificationCountChanged = { [weak self] _ in
            self?.updateNotificationBadge()
        }

        terminalOpenURLObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyOpenURL,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let rawURL = notification.userInfo?["url"] as? String,
                  let url = URL(string: rawURL) else { return }
            Task { @MainActor [weak self] in
                self?.openBrowserInWorkspace(url: url, source: .terminal)
            }
        }

        // Forward bridge notification_created events to native macOS notifications
        nativeNotificationBridgeObserverID = BridgeEventHub.shared.addObserver { event in
            guard event.name == "notification_created" else { return }
            struct NotificationPayload: Decodable {
                let title: String?
                let body: String?
            }
            if let data = event.payloadJSON.data(using: .utf8),
               let payload = try? JSONDecoder().decode(NotificationPayload.self, from: data) {
                Task { @MainActor in
                    NativeNotificationManager.shared.postNotification(
                        title: payload.title ?? "Pnevma",
                        body: payload.body ?? ""
                    )
                }
            }
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
        hideFocusModeEscapeHatch()
        smokeTimeoutWorkItem?.cancel()
        smokeTimeoutWorkItem = nil
        browserSessionPrewarmTask?.cancel()
        browserSessionPrewarmTask = nil
        for session in browserSessions.values {
            session.cancelPendingDrawerRestore()
        }
        if let terminalOpenURLObserver {
            NotificationCenter.default.removeObserver(terminalOpenURLObserver)
            self.terminalOpenURLObserver = nil
        }
        if let nativeNotificationBridgeObserverID {
            BridgeEventHub.shared.removeObserver(nativeNotificationBridgeObserverID)
            self.nativeNotificationBridgeObserverID = nil
        }
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
                    Task { @MainActor [weak self] in
                        await self?.workspaceManager?.prepareForShutdown()
                        sender.reply(toApplicationShouldTerminate: true)
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    await self?.workspaceManager?.prepareForShutdown()
                    sender.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }

    private func applyRuntimeSettings() {
        persistence?.isPersistenceEnabled =
            !AppLaunchContext.isTesting && AppRuntimeSettings.shared.autoSaveWorkspaceOnQuit
        sessionBridge?.defaultShell = AppRuntimeSettings.shared.normalizedDefaultShell
        refreshToolDockAutoHide(animated: true)
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
        installUITestReadinessView(in: windowContent)

        // Root placeholder pane
        let (_, rootPane) = PaneFactory.makeWelcome()
        contentAreaView = ContentAreaView(frame: windowContent.bounds, rootPaneView: rootPane)
        contentAreaView?.availableLiveSessionsProvider = { [weak self] in
            self?.sessionStore?.sessions ?? []
        }

        contentAreaView?.onActivePaneChanged = { [weak self] _ in
            // Focusing a pane dismisses its notification ring, so reset the terminal count
            // based on how many rings are still active.
            if let self, let workspace = self.workspaceManager?.activeWorkspace {
                let activeRings = self.contentAreaView?.paneIDsWithNotificationRings.count ?? 0
                workspace.terminalNotificationCount = activeRings
                self.updateNotificationBadge()
                self.updateTabBar()
            }
            self?.updateToolDockState()
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
            self.updateToolDockState()
            self.persistence?.markDirty()
        }

        titlebarStatusView = TitlebarStatusView()
        titlebarStatusView?.onSessionsClicked = { [weak self] in self?.showSessionManager() }
        titlebarStatusView?.onBranchClicked = { [weak self] in self?.showBranchPicker() }
        titlebarStatusView?.onPRClicked = { [weak self] in self?.openLinkedPRInBrowser() }
        if let sessionStore {
            titlebarStatusView?.bindSessionStore(sessionStore)
        }

        // Sidebar
        guard let workspaceManager else {
            Log.general.error("workspaceManager not initialized — cannot create sidebar")
            return
        }
        let sidebarView = SidebarView(
            workspaceManager: workspaceManager,
            onAddWorkspace: { [weak self] in self?.openWorkspace() }
        )
        let sidebarHost = NSHostingView(rootView: sidebarView.environment(GhosttyThemeProvider.shared))
        let sidebarBacking = ThemedSidebarBackingView()
        sidebarBacking.setAccessibilityIdentifier("sidebar.view")
        sidebarBacking.addSubview(sidebarHost)
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            sidebarHost.topAnchor.constraint(equalTo: sidebarBacking.topAnchor),
            sidebarHost.leadingAnchor.constraint(equalTo: sidebarBacking.leadingAnchor),
            sidebarHost.trailingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: sidebarBacking.bottomAnchor),
        ])
        self.sidebarHostView = sidebarBacking
        self.sidebarContentView = sidebarHost

        // Collapsed sidebar rail — icon-only mode
        let collapsedRailView = SidebarCollapsedRailView(
            workspaceManager: workspaceManager,
            onSelectWorkspace: { [weak self] id in
                self?.workspaceManager?.switchToWorkspace(id)
            }
        ).environment(GhosttyThemeProvider.shared)
        let collapsedRailHost = NSHostingView(rootView: AnyView(collapsedRailView))
        collapsedRailHost.translatesAutoresizingMaskIntoConstraints = false
        collapsedRailHost.isHidden = true
        sidebarBacking.addSubview(collapsedRailHost)
        NSLayoutConstraint.activate([
            collapsedRailHost.topAnchor.constraint(equalTo: sidebarBacking.topAnchor),
            collapsedRailHost.leadingAnchor.constraint(equalTo: sidebarBacking.leadingAnchor),
            collapsedRailHost.trailingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
            collapsedRailHost.bottomAnchor.constraint(equalTo: sidebarBacking.bottomAnchor),
        ])
        self.collapsedRailHostView = collapsedRailHost

        let toolDockView = ToolDockBarView(
            workspaceManager: workspaceManager,
            dockState: toolDockState,
            onOpenTool: { [weak self] (toolID: String) in self?.openToolWithDefaultPresentation(toolID) },
            onOpenToolAsTab: { [weak self] (toolID: String) in self?.openToolAsTab(toolID) },
            onOpenToolAsPane: { [weak self] (toolID: String) in self?.openToolAsPane(toolID) },
            onHoverChanged: { [weak self] isHovering in self?.setToolDockContentHovering(isHovering) }
        )
        let toolDockHost = NSHostingView(rootView: toolDockView.environment(GhosttyThemeProvider.shared))
        toolDockHost.setAccessibilityIdentifier("tool-dock.view")
        toolDockHost.wantsLayer = true
        toolDockHost.layer?.masksToBounds = true

        let toolDockContainer = ToolDockContainerView()
        toolDockContainer.wantsLayer = true
        toolDockContainer.addSubview(toolDockHost)
        toolDockHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            toolDockHost.leadingAnchor.constraint(equalTo: toolDockContainer.leadingAnchor),
            toolDockHost.trailingAnchor.constraint(equalTo: toolDockContainer.trailingAnchor),
            toolDockHost.topAnchor.constraint(equalTo: toolDockContainer.topAnchor),
            toolDockHost.bottomAnchor.constraint(equalTo: toolDockContainer.bottomAnchor),
        ])
        self.toolDockHostView = toolDockContainer

        let trigger = BottomEdgeTracker()
        trigger.onHoverChanged = { [weak self] isHovering in
            self?.setToolDockEdgeHovering(isHovering)
        }
        self.toolDockTriggerView = trigger

        let rightInspectorView = RightInspectorView(
            workspaceManager: workspaceManager,
            onStateChanged: { [weak self] in self?.persistence?.markDirty() },
            onClose: { [weak self] in self?.toggleRightInspector() },
            fileBrowserViewModel: rightInspectorFileBrowserViewModel,
            workspaceChangesViewModel: rightInspectorWorkspaceChangesViewModel,
            reviewViewModel: rightInspectorReviewViewModel,
            mergeQueueViewModel: rightInspectorMergeQueueViewModel
        )
        let rightInspectorHost = NSHostingView(
            rootView: rightInspectorView.environment(GhosttyThemeProvider.shared)
        )
        let rightInspectorBacking = ThemedRightInspectorBackingView()
        rightInspectorBacking.addSubview(rightInspectorHost)
        rightInspectorHost.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rightInspectorHost.leadingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor),
            rightInspectorHost.trailingAnchor.constraint(equalTo: rightInspectorBacking.trailingAnchor),
            rightInspectorHost.topAnchor.constraint(equalTo: rightInspectorBacking.topAnchor),
            rightInspectorHost.bottomAnchor.constraint(equalTo: rightInspectorBacking.bottomAnchor),
        ])
        self.rightInspectorHostView = rightInspectorBacking

        let rightInspectorResizer = RightInspectorResizeHandleView()
        rightInspectorResizer.onResize = { [weak self] delta in
            self?.adjustRightInspectorWidth(by: delta)
        }
        self.rightInspectorResizerView = rightInspectorResizer

        let rightInspectorOverlayView = RightInspectorOverlayView(
            workspaceManager: workspaceManager,
            chromeState: rightInspectorChromeState,
            fileBrowserViewModel: rightInspectorFileBrowserViewModel,
            workspaceChangesViewModel: rightInspectorWorkspaceChangesViewModel,
            reviewViewModel: rightInspectorReviewViewModel,
            mergeQueueViewModel: rightInspectorMergeQueueViewModel,
            onVisibilityChanged: { [weak self] isVisible in
                self?.rightInspectorOverlayBlockerView?.capturesPointerEvents = isVisible
                self?.rightInspectorOverlayHostView?.capturesPointerEvents = isVisible
            },
            onHitRectChanged: { [weak self] rect in
                self?.rightInspectorOverlayBlockerView?.overlayHitRect = rect
                self?.rightInspectorOverlayHostView?.overlayHitRect = rect
            }
        )
        let rightInspectorOverlayBlocker = RightInspectorOverlayBlockerView(frame: .zero)
        rightInspectorOverlayBlocker.capturesPointerEvents = false
        self.rightInspectorOverlayBlockerView = rightInspectorOverlayBlocker
        let rightInspectorOverlayHost = RightInspectorOverlayHostingView(
            rootView: AnyView(rightInspectorOverlayView.environment(GhosttyThemeProvider.shared))
        )
        rightInspectorOverlayHost.capturesPointerEvents = false
        self.rightInspectorOverlayHostView = rightInspectorOverlayHost

        let browserDrawerBlocker = BrowserDrawerOverlayBlockerView(frame: .zero)
        browserDrawerBlocker.capturesPointerEvents = false
        self.browserDrawerOverlayBlockerView = browserDrawerBlocker

        let browserSession = workspaceManager.activeWorkspace.flatMap { self.existingBrowserSession(for: $0) }
        browserDrawerPresentationModel.session = browserSession
        let browserDrawerOverlay = BrowserDrawerOverlayView(
            chromeState: browserDrawerChromeState,
            presentationModel: browserDrawerPresentationModel,
            onClose: { [weak self] in self?.closeBrowserDrawer() },
            onPinToPane: { [weak self] in self?.pinBrowserToPane() },
            onOpenAsTab: { [weak self] in self?.openBrowserAsTab() },
            onVisibilityChanged: { [weak self] isVisible in
                self?.browserDrawerOverlayBlockerView?.capturesPointerEvents = isVisible
                self?.browserDrawerOverlayHostView?.capturesPointerEvents = isVisible
            },
            onHitRectChanged: { [weak self] rect in
                self?.browserDrawerOverlayBlockerView?.overlayHitRect = rect
                self?.browserDrawerOverlayHostView?.overlayHitRect = rect
            }
        )
        let browserDrawerHost = BrowserDrawerOverlayHostingView(
            rootView: AnyView(browserDrawerOverlay.environment(GhosttyThemeProvider.shared))
        )
        PerformanceDiagnostics.shared.recordBrowserDrawerRootViewAssignment()
        browserDrawerHost.capturesPointerEvents = false
        self.browserDrawerOverlayHostView = browserDrawerHost

        // Tool drawer overlay — generic drawer for non-browser tools
        let toolDrawerBlocker = ToolDrawerOverlayBlockerView(frame: .zero)
        toolDrawerBlocker.capturesPointerEvents = false
        self.toolDrawerOverlayBlockerView = toolDrawerBlocker
        let toolDrawerOverlay = ToolDrawerOverlayView(
            chromeState: toolDrawerChromeState,
            contentModel: toolDrawerContentModel,
            onClose: { [weak self] () -> Void in self?.closeToolDrawer() },
            onPinToPane: { [weak self] () -> Void in self?.pinToolDrawerToPane() },
            onOpenAsTab: { [weak self] () -> Void in self?.openToolDrawerAsTab() },
            onVisibilityChanged: { [weak self] isVisible in
                self?.toolDrawerOverlayBlockerView?.capturesPointerEvents = isVisible
                self?.toolDrawerOverlayHostView?.capturesPointerEvents = isVisible
            },
            onHitRectChanged: { [weak self] rect in
                self?.toolDrawerOverlayBlockerView?.overlayHitRect = rect
                self?.toolDrawerOverlayHostView?.overlayHitRect = rect
            }
        )
        let toolDrawerHost = ToolDrawerOverlayHostingView(
            rootView: AnyView(toolDrawerOverlay.environment(GhosttyThemeProvider.shared))
        )
        toolDrawerHost.capturesPointerEvents = false
        self.toolDrawerOverlayHostView = toolDrawerHost

        // Titlebar fill: themed background behind the transparent titlebar
        let titlebarFill = ThemedTitlebarFillView()
        titlebarFill.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(titlebarFill)

        guard let contentArea = contentAreaView,
              let titlebarStatus = titlebarStatusView,
              let toolDock = toolDockHostView else {
            Log.general.error("contentAreaView, titlebarStatusView, or toolDockHostView not initialized")
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
        let resourceMonitorBtn = makeTitlebarButton(
            symbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "Resources",
            toolTip: "Resources",
            action: #selector(showResourceMonitorPopover),
            size: titlebarButtonSize,
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemTeal
        )
        resourceMonitorToolbarButton = resourceMonitorBtn
        let addWorkspaceBtn = makeTitlebarButton(
            symbolName: "plus",
            accessibilityDescription: "Open Workspace",
            toolTip: "Open Workspace",
            action: #selector(openWorkspaceAction),
            size: titlebarButtonSize,
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemGreen
        )
        addWorkspaceBtn.setAccessibilityIdentifier("titlebar.openWorkspace")

        let settingsBtn = makeTitlebarButton(
            symbolName: "gearshape",
            accessibilityDescription: "Settings",
            toolTip: "Settings",
            action: #selector(openSettingsAction),
            size: titlebarButtonSize,
            symbolConfig: titlebarSymbolConfig
        )
        settingsBtn.setAccessibilityIdentifier("titlebar.settings")

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

        // Agent strip — horizontal bar of agent chips above content area
        let agentStripView = AgentStripView(
            state: agentStripState,
            selectedSessionID: nil as String?,
            onSelectSession: { _ in
                // Session selection is visual only; terminal focus is managed by pane layout
            }
        ).environment(GhosttyThemeProvider.shared)
        let agentStrip = NSHostingView(rootView: AnyView(agentStripView))
        agentStrip.setAccessibilityIdentifier("agentStrip.host")
        self.agentStripHostView = agentStrip

        for view in [sidebarBacking, tabBar, agentStrip, contentArea, toolDock, toolbarSep,
                      rightInspectorBacking, rightInspectorResizer,
                      sidebarToggleBtn, notificationsBtn, usageBtn, resourceMonitorBtn, settingsBtn, addWorkspaceBtn,
                      templateBtn, titlebarStatus,
                      openBtn, commitBtn, pushBtn] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            windowContent.addSubview(view)
        }
        if let trigger = toolDockTriggerView {
            trigger.translatesAutoresizingMaskIntoConstraints = false
            windowContent.addSubview(trigger)
        }

        rightInspectorOverlayBlocker.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(rightInspectorOverlayBlocker)
        rightInspectorOverlayHost.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(rightInspectorOverlayHost)
        browserDrawerBlocker.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(browserDrawerBlocker)
        browserDrawerHost.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(browserDrawerHost)
        toolDrawerBlocker.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(toolDrawerBlocker)
        toolDrawerHost.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(toolDrawerHost)

        let sidebarWidth = DesignTokens.Layout.sidebarWidth
        let toolDockHeight = DesignTokens.Layout.toolDockHeight
        let tabBarHeight = DesignTokens.Layout.tabBarHeight

        let swc = sidebarBacking.widthAnchor.constraint(equalToConstant: sidebarWidth)
        let rightInspectorWidth = rightInspectorBacking.widthAnchor.constraint(
            equalToConstant: isRightInspectorPresented ? rightInspectorStoredWidth : 0
        )
        let clc = contentArea.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor)
        let tblc = tabBar.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor)
        let toolDockHeightConstraint = toolDock.heightAnchor.constraint(equalToConstant: toolDockHeight)

        // Agent strip height — 0 initially (no active sessions), expanded when sessions exist
        let agentStripHeight = agentStrip.heightAnchor.constraint(equalToConstant: 0)
        self.agentStripHeightConstraint = agentStripHeight

        // Agent strip top: switches between below-tab-bar and directly below toolbar separator.
        // Content area always sits below the agent strip.
        let stripTopToTab = agentStrip.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        let stripTopToSep = agentStrip.topAnchor.constraint(equalTo: toolbarSep.bottomAnchor)
        // Tab bar starts hidden (single tab), so agent strip goes directly below toolbar sep
        stripTopToTab.isActive = false
        stripTopToSep.isActive = true

        sidebarWidthConstraint = swc
        rightInspectorWidthConstraint = rightInspectorWidth
        contentLeadingConstraint = clc
        tabBarLeadingConstraint = tblc
        self.toolDockHeightConstraint = toolDockHeightConstraint
        agentStripTopToTabBar = stripTopToTab
        agentStripTopToToolbarSep = stripTopToSep

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
        let contentMinWidth = contentArea.widthAnchor.constraint(greaterThanOrEqualToConstant: minContentWidth)
        self.contentMinWidthConstraint = contentMinWidth
        NSLayoutConstraint.activate([
            sidebarToggleLeading,
            titlebarFill.topAnchor.constraint(equalTo: windowContent.topAnchor),
            titlebarBottom,
            titlebarFill.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            titlebarFill.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),

            sidebarBacking.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            sidebarBacking.topAnchor.constraint(equalTo: toolbarSep.bottomAnchor),
            swc,

            rightInspectorBacking.topAnchor.constraint(equalTo: toolbarSep.bottomAnchor),
            rightInspectorBacking.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            rightInspectorWidth,

            // Tab bar: flush below toolbar separator, tracks sidebar edge
            tblc,
            tabBar.trailingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor),
            tabBar.topAnchor.constraint(equalTo: toolbarSep.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: tabBarHeight),

            // Agent strip: between tab bar / toolbar sep and content area
            agentStrip.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
            agentStrip.trailingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor),
            agentStripHeight,

            // Content area always sits below agent strip
            contentArea.topAnchor.constraint(equalTo: agentStrip.bottomAnchor),

            clc,
            contentArea.trailingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: toolDock.topAnchor),
            contentMinWidth,

            sidebarBacking.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            rightInspectorBacking.bottomAnchor.constraint(equalTo: toolDock.topAnchor),

            toolDock.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
            toolDock.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            toolDock.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            toolDockHeightConstraint,

            rightInspectorResizer.leadingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor, constant: -DesignTokens.Layout.dividerHoverWidth),
            rightInspectorResizer.trailingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor, constant: DesignTokens.Layout.dividerHoverWidth),
            rightInspectorResizer.topAnchor.constraint(equalTo: toolbarSep.bottomAnchor),
            rightInspectorResizer.bottomAnchor.constraint(equalTo: toolDock.topAnchor),

            // Horizontal separator between titlebar and content — spans full width (Superset-style)
            toolbarSep.topAnchor.constraint(equalTo: titlebarFill.bottomAnchor),
            toolbarSep.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            toolbarSep.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            toolbarSep.heightAnchor.constraint(equalToConstant: DesignTokens.Layout.dividerWidth),

            // Titlebar buttons — vertically centered in titlebar area
            sidebarToggleBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            sidebarToggleWidth,
            sidebarToggleHeight,

            notificationsBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            notificationsBtn.trailingAnchor.constraint(equalTo: settingsBtn.leadingAnchor, constant: -4),
            notificationsBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            notificationsBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

            usageBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            usageBtn.trailingAnchor.constraint(equalTo: resourceMonitorBtn.leadingAnchor, constant: -4),
            usageBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            usageBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

            resourceMonitorBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            resourceMonitorBtn.trailingAnchor.constraint(equalTo: notificationsBtn.leadingAnchor, constant: -4),
            resourceMonitorBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            resourceMonitorBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

            settingsBtn.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            settingsBtn.trailingAnchor.constraint(equalTo: addWorkspaceBtn.leadingAnchor, constant: -4),
            settingsBtn.widthAnchor.constraint(equalToConstant: titlebarButtonSize.width),
            settingsBtn.heightAnchor.constraint(equalToConstant: titlebarButtonSize.height),

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

            titlebarStatus.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            titlebarStatus.leadingAnchor.constraint(greaterThanOrEqualTo: templateBtn.trailingAnchor, constant: 12),
            titlebarStatus.trailingAnchor.constraint(lessThanOrEqualTo: openBtn.leadingAnchor, constant: -12),

            rightInspectorOverlayBlocker.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            rightInspectorOverlayBlocker.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            rightInspectorOverlayBlocker.topAnchor.constraint(equalTo: contentArea.topAnchor),
            rightInspectorOverlayBlocker.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),

            rightInspectorOverlayHost.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            rightInspectorOverlayHost.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            rightInspectorOverlayHost.topAnchor.constraint(equalTo: contentArea.topAnchor),
            rightInspectorOverlayHost.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),

            browserDrawerBlocker.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            browserDrawerBlocker.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            browserDrawerBlocker.topAnchor.constraint(equalTo: contentArea.topAnchor),
            browserDrawerBlocker.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),

            browserDrawerHost.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            browserDrawerHost.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            browserDrawerHost.topAnchor.constraint(equalTo: contentArea.topAnchor),
            browserDrawerHost.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),

            toolDrawerBlocker.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            toolDrawerBlocker.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            toolDrawerBlocker.topAnchor.constraint(equalTo: contentArea.topAnchor),
            toolDrawerBlocker.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),

            toolDrawerHost.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            toolDrawerHost.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            toolDrawerHost.topAnchor.constraint(equalTo: contentArea.topAnchor),
            toolDrawerHost.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),
        ])

        if let trigger = toolDockTriggerView {
            NSLayoutConstraint.activate([
                trigger.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
                // Stop at the inspector leading edge so the tracker never covers the inspector area.
                trigger.trailingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor),
                trigger.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
                trigger.heightAnchor.constraint(equalToConstant: 10),
            ])
        }
        rightInspectorBacking.isHidden = !isRightInspectorPresented
        rightInspectorResizer.isHidden = !isRightInspectorPresented
        let isBrowserDrawerVisible = browserSession?.isDrawerVisible ?? false
        browserDrawerChromeState.isPresented = isBrowserDrawerVisible
        browserDrawerBlocker.capturesPointerEvents = isBrowserDrawerVisible
        browserDrawerHost.capturesPointerEvents = isBrowserDrawerVisible
        updateWindowMinWidth()
        updateRightInspectorOverlayAlignment()
        refreshBrowserDrawerOverlayRootView()
        if let workspace = workspaceManager.activeWorkspace {
            scheduleBrowserSessionPrewarm(for: workspace)
        }
        updateUsageToolbarStatus()
        titlebarStatus.updateBranch(workspaceManager.activeWorkspace?.gitBranch)
        titlebarStatus.updateAgents(workspaceManager.activeWorkspace?.activeAgents ?? 0)
        updateToolDockState()
        refreshToolDockAutoHide(animated: false)

        // For terminal transparency (background-opacity < 1.0), the window must
        // be non-opaque so ghostty's Metal layer alpha reaches the desktop.
        // The sidebar, tool dock, and dividers all paint their own backgrounds.
        let theme = GhosttyThemeProvider.shared
        if theme.backgroundOpacity < 1.0 {
            win.isOpaque = false
            win.backgroundColor = .clear
        } else {
            win.backgroundColor = theme.backgroundColor
        }

        win.delegate = self
        self.window = win
        updateWindowMinWidth()
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
        let quitItem = NSMenuItem(title: "Quit Pnevma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.identifier = NSUserInterfaceItemIdentifier("menu.quit")
        appMenu.addItem(quitItem)
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "t")
        newTabItem.identifier = NSUserInterfaceItemIdentifier("menu.new_tab")
        fileMenu.addItem(newTabItem)
        let newTerminalItem = NSMenuItem(title: "New Terminal", action: #selector(newTerminal), keyEquivalent: "n")
        newTerminalItem.identifier = NSUserInterfaceItemIdentifier("menu.new_terminal")
        fileMenu.addItem(newTerminalItem)
        let openWorkspaceItem = NSMenuItem(title: "Open Workspace...", action: #selector(openWorkspaceAction), keyEquivalent: "o")
        openWorkspaceItem.identifier = NSUserInterfaceItemIdentifier("menu.open_workspace")
        fileMenu.addItem(openWorkspaceItem)
        fileMenu.addItem(.separator())
        let closePaneItem = NSMenuItem(title: "Close Pane", action: #selector(closePaneAction), keyEquivalent: "w")
        closePaneItem.identifier = NSUserInterfaceItemIdentifier("menu.close_pane")
        fileMenu.addItem(closePaneItem)
        let closeWindow = NSMenuItem(title: "Close Window", action: #selector(closeWindowAction), keyEquivalent: "W")
        closeWindow.keyEquivalentModifierMask = [.command, .shift]
        closeWindow.identifier = NSUserInterfaceItemIdentifier("menu.close_window")
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
        let findInPageItem = NSMenuItem(title: "Find in Page", action: #selector(browserFindInPage), keyEquivalent: "f")
        findInPageItem.identifier = NSUserInterfaceItemIdentifier("menu.find_in_page")
        editMenu.addItem(findInPageItem)
        let browserOmnibarItem = NSMenuItem(
            title: "Focus Browser Address Bar",
            action: #selector(focusBrowserOmnibarAction),
            keyEquivalent: "l"
        )
        browserOmnibarItem.identifier = NSUserInterfaceItemIdentifier("menu.focus_browser_address")
        editMenu.addItem(browserOmnibarItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(
            title: "Copy Browser Selection with Source URL",
            action: #selector(copyBrowserSelectionWithSourceAction),
            keyEquivalent: ""
        ))
        editMenu.addItem(NSMenuItem(
            title: "Save Browser Page as Markdown",
            action: #selector(saveBrowserPageAsMarkdownAction),
            keyEquivalent: ""
        ))
        editMenu.addItem(NSMenuItem(
            title: "Copy Browser Link List as Markdown",
            action: #selector(copyBrowserLinkListAction),
            keyEquivalent: ""
        ))
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        toggleSidebarItem.identifier = NSUserInterfaceItemIdentifier("menu.toggle_sidebar")
        viewMenu.addItem(toggleSidebarItem)
        let toggleRightInspectorItem = NSMenuItem(
            title: "Toggle Right Inspector",
            action: #selector(toggleRightInspector),
            keyEquivalent: "B"
        )
        toggleRightInspectorItem.keyEquivalentModifierMask = [.command, .shift]
        toggleRightInspectorItem.identifier = NSUserInterfaceItemIdentifier("menu.toggle_right_inspector")
        viewMenu.addItem(toggleRightInspectorItem)
        let commandCenterItem = NSMenuItem(
            title: "Toggle Command Center",
            action: #selector(toggleCommandCenter),
            keyEquivalent: "C"
        )
        commandCenterItem.keyEquivalentModifierMask = [.command, .shift]
        commandCenterItem.identifier = NSUserInterfaceItemIdentifier("menu.toggle_command_center")
        viewMenu.addItem(commandCenterItem)

        let focusModeItem = NSMenuItem(
            title: "Toggle Focus Mode",
            action: #selector(toggleFocusMode),
            keyEquivalent: "F"
        )
        focusModeItem.keyEquivalentModifierMask = [.command, .shift]
        focusModeItem.identifier = NSUserInterfaceItemIdentifier("menu.toggle_focus_mode")
        viewMenu.addItem(focusModeItem)

        let browserDrawerItem = NSMenuItem(
            title: "Toggle Browser Drawer",
            action: #selector(toggleBrowserDrawerAction),
            keyEquivalent: "b"
        )
        browserDrawerItem.keyEquivalentModifierMask = [.command, .option]
        browserDrawerItem.identifier = NSUserInterfaceItemIdentifier("menu.toggle_browser_drawer")
        viewMenu.addItem(browserDrawerItem)
        let browserDrawerShorterItem = NSMenuItem(
            title: "Make Browser Drawer Shorter",
            action: #selector(makeBrowserDrawerShorterAction),
            keyEquivalent: "-"
        )
        browserDrawerShorterItem.keyEquivalentModifierMask = [.command, .option]
        browserDrawerShorterItem.identifier = NSUserInterfaceItemIdentifier("menu.browser_drawer_shorter")
        viewMenu.addItem(browserDrawerShorterItem)
        let browserDrawerTallerItem = NSMenuItem(
            title: "Make Browser Drawer Taller",
            action: #selector(makeBrowserDrawerTallerAction),
            keyEquivalent: "="
        )
        browserDrawerTallerItem.keyEquivalentModifierMask = [.command, .option]
        browserDrawerTallerItem.identifier = NSUserInterfaceItemIdentifier("menu.browser_drawer_taller")
        viewMenu.addItem(browserDrawerTallerItem)
        let pinBrowserItem = NSMenuItem(
            title: "Pin Browser to Pane",
            action: #selector(pinBrowserToPaneAction),
            keyEquivalent: "\\"
        )
        pinBrowserItem.keyEquivalentModifierMask = [.command, .shift]
        pinBrowserItem.identifier = NSUserInterfaceItemIdentifier("menu.pin_browser")
        viewMenu.addItem(pinBrowserItem)
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: "Layout Templates\u{2026}", action: #selector(titlebarTemplateAction), keyEquivalent: "")
        viewMenu.addItem(NSMenuItem.separator())
        let cmdPalette = NSMenuItem(title: "Command Palette", action: #selector(showCommandPalette), keyEquivalent: "P")
        cmdPalette.keyEquivalentModifierMask = [.command, .shift]
        cmdPalette.identifier = NSUserInterfaceItemIdentifier("menu.command_palette")
        viewMenu.addItem(cmdPalette)

        let quickOpenItem = NSMenuItem(title: "Quick Open File", action: #selector(showFileQuickOpen), keyEquivalent: "p")
        quickOpenItem.identifier = NSUserInterfaceItemIdentifier("menu.quick_open_file")
        viewMenu.addItem(quickOpenItem)

        let shortcutsItem = NSMenuItem(title: "Keyboard Shortcuts", action: #selector(showShortcutSheet), keyEquivalent: "/")
        shortcutsItem.keyEquivalentModifierMask = [.command, .shift]
        shortcutsItem.identifier = NSUserInterfaceItemIdentifier("menu.keyboard_shortcuts")
        viewMenu.addItem(shortcutsItem)

        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Pane menu
        let paneMenu = NSMenu(title: "Pane")
        let splitRightItem = NSMenuItem(title: "Split Right", action: #selector(splitRightAction), keyEquivalent: "d")
        splitRightItem.identifier = NSUserInterfaceItemIdentifier("menu.split_right")
        paneMenu.addItem(splitRightItem)

        let splitDown = NSMenuItem(title: "Split Down", action: #selector(splitDownAction), keyEquivalent: "D")
        splitDown.keyEquivalentModifierMask = [.command, .shift]
        splitDown.identifier = NSUserInterfaceItemIdentifier("menu.split_down")
        paneMenu.addItem(splitDown)

        paneMenu.addItem(.separator())

        let nextPaneItem = NSMenuItem(title: "Next Pane", action: #selector(nextPane), keyEquivalent: "]")
        nextPaneItem.identifier = NSUserInterfaceItemIdentifier("menu.next_pane")
        paneMenu.addItem(nextPaneItem)
        let prevPaneItem = NSMenuItem(title: "Previous Pane", action: #selector(previousPane), keyEquivalent: "[")
        prevPaneItem.identifier = NSUserInterfaceItemIdentifier("menu.previous_pane")
        paneMenu.addItem(prevPaneItem)

        paneMenu.addItem(.separator())

        for (title, action, key, actionID) in [
            ("Navigate Left",  #selector(navigateLeft),  NSLeftArrowFunctionKey,  "menu.navigate_left"),
            ("Navigate Right", #selector(navigateRight), NSRightArrowFunctionKey, "menu.navigate_right"),
            ("Navigate Up",    #selector(navigateUp),    NSUpArrowFunctionKey,    "menu.navigate_up"),
            ("Navigate Down",  #selector(navigateDown),  NSDownArrowFunctionKey,  "menu.navigate_down"),
        ] as [(String, Selector, Int, String)] {
            let item = NSMenuItem(title: title, action: action,
                                  keyEquivalent: String(Character(UnicodeScalar(key)!)))
            item.keyEquivalentModifierMask = [.option, .command]
            item.identifier = NSUserInterfaceItemIdentifier(actionID)
            paneMenu.addItem(item)
        }

        paneMenu.addItem(.separator())

        let zoomItem = NSMenuItem(title: "Toggle Split Zoom", action: #selector(toggleSplitZoom), keyEquivalent: "\r")
        zoomItem.keyEquivalentModifierMask = [.command, .shift]
        zoomItem.identifier = NSUserInterfaceItemIdentifier("menu.toggle_split_zoom")
        paneMenu.addItem(zoomItem)

        let equalizeItem = NSMenuItem(title: "Equalize Splits", action: #selector(equalizeSplitsAction), keyEquivalent: "=")
        equalizeItem.keyEquivalentModifierMask = [.command, .control]
        equalizeItem.identifier = NSUserInterfaceItemIdentifier("menu.equalize_splits")
        paneMenu.addItem(equalizeItem)

        paneMenu.addItem(.separator())

        // Cmd+1–8: jump to Nth pane, Cmd+9: last pane
        for i in 1...8 {
            let item = NSMenuItem(title: "Pane \(i)", action: #selector(gotoPaneByTag(_:)), keyEquivalent: "\(i)")
            item.tag = i
            item.identifier = NSUserInterfaceItemIdentifier("menu.goto_pane_\(i)")
            paneMenu.addItem(item)
        }
        let lastPaneItem = NSMenuItem(title: "Last Pane", action: #selector(gotoLastPane), keyEquivalent: "9")
        lastPaneItem.identifier = NSUserInterfaceItemIdentifier("menu.goto_last_pane")
        paneMenu.addItem(lastPaneItem)

        let paneMenuItem = NSMenuItem()
        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        let minimizeItem = NSMenuItem(title: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        minimizeItem.identifier = NSUserInterfaceItemIdentifier("menu.minimize")
        windowMenu.addItem(minimizeItem)
        windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: ""))
        let fullscreen = NSMenuItem(title: "Toggle Full Screen", action: #selector(toggleFullScreenAction), keyEquivalent: "\r")
        fullscreen.identifier = NSUserInterfaceItemIdentifier("menu.toggle_fullscreen")
        windowMenu.addItem(fullscreen)
        windowMenu.addItem(.separator())

        let nextWS = NSMenuItem(title: "Next Workspace", action: #selector(nextWorkspace), keyEquivalent: "]")
        nextWS.keyEquivalentModifierMask = [.command, .shift]
        nextWS.identifier = NSUserInterfaceItemIdentifier("menu.next_workspace")
        windowMenu.addItem(nextWS)

        let prevWS = NSMenuItem(title: "Previous Workspace", action: #selector(previousWorkspace), keyEquivalent: "[")
        prevWS.keyEquivalentModifierMask = [.command, .shift]
        prevWS.identifier = NSUserInterfaceItemIdentifier("menu.previous_workspace")
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
            agentStripTopToToolbarSep?.isActive = false
            agentStripTopToTabBar?.isActive = true
        } else {
            agentStripTopToTabBar?.isActive = false
            agentStripTopToToolbarSep?.isActive = true
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

    @objc private func toggleBrowserDrawerAction() {
        toggleBrowserDrawer()
    }

    @objc private func focusBrowserOmnibarAction() {
        focusBrowserOmnibar()
    }

    @objc private func copyBrowserSelectionWithSourceAction() {
        Task { @MainActor [weak self] in
            await self?.copyBrowserSelectionWithSource()
        }
    }

    @objc private func saveBrowserPageAsMarkdownAction() {
        Task { @MainActor [weak self] in
            await self?.saveBrowserPageAsMarkdown()
        }
    }

    @objc private func copyBrowserLinkListAction() {
        Task { @MainActor [weak self] in
            await self?.copyBrowserLinkListAsMarkdown()
        }
    }

    @objc private func makeBrowserDrawerShorterAction() {
        resizeBrowserDrawer(by: -DrawerSizing.keyboardStep)
    }

    @objc private func makeBrowserDrawerTallerAction() {
        resizeBrowserDrawer(by: DrawerSizing.keyboardStep)
    }

    @objc private func pinBrowserToPaneAction() {
        pinBrowserToPane()
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
        cycleSidebarMode()
    }

    private func cycleSidebarMode() {
        currentSidebarMode = currentSidebarMode.next
        SidebarPreferences.sidebarMode = currentSidebarMode
        applySidebarMode(animated: true)
    }

    private func applySidebarMode(animated: Bool) {
        rightInspectorChromeState.overlayShouldAnimateAlignment = animated
        sidebarTransitionGeneration &+= 1
        let transitionGeneration = sidebarTransitionGeneration

        let width: CGFloat
        switch currentSidebarMode {
        case .expanded:
            width = SidebarPreferences.sidebarWidth
            isSidebarVisible = true
            sidebarContentView?.isHidden = false
            collapsedRailHostView?.isHidden = true
            sidebarHostView?.isHidden = false
        case .collapsed:
            width = DesignTokens.Layout.sidebarCollapsedWidth
            isSidebarVisible = true
            sidebarContentView?.isHidden = true
            collapsedRailHostView?.isHidden = false
            sidebarHostView?.isHidden = false
        case .hidden:
            width = 0
            isSidebarVisible = false
        }

        let signpost = PerformanceDiagnostics.shared.beginInterval("sidebar.toggle")
        ChromeTransitionCoordinator.shared.begin(.sidebar)

        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = DesignTokens.Motion.normal
                ctx.allowsImplicitAnimation = true
                sidebarWidthConstraint?.animator().constant = width
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    ChromeTransitionCoordinator.shared.end(.sidebar)
                    PerformanceDiagnostics.shared.endInterval("sidebar.toggle", signpost)
                    guard self.sidebarTransitionGeneration == transitionGeneration else { return }
                    if self.currentSidebarMode == .hidden { self.sidebarHostView?.isHidden = true }
                    self.rightInspectorChromeState.overlayShouldAnimateAlignment = false
                }
            })
        } else {
            sidebarWidthConstraint?.constant = width
            ChromeTransitionCoordinator.shared.end(.sidebar)
            PerformanceDiagnostics.shared.endInterval("sidebar.toggle", signpost)
            if currentSidebarMode == .hidden { sidebarHostView?.isHidden = true }
            rightInspectorChromeState.overlayShouldAnimateAlignment = false
        }

        updateWindowMinWidth()
        updateRightInspectorOverlayAlignment()
        persistence?.markDirty()
    }

    @objc private func toggleRightInspector() {
        guard activeWorkspaceSupportsRightInspector else { return }
        setRightInspectorVisible(!isRightInspectorVisible, animated: true)
    }

    @objc private func toggleCommandCenter() {
        if commandCenterWindowController?.isWindowVisible == true {
            commandCenterWindowController?.closeWindow()
        } else {
            showCommandCenter(makeKey: true)
        }
    }

    @objc private func toggleFocusMode() {
        isFocusMode.toggle()
        if isFocusMode {
            // Save current state
            preFocusSidebarVisible = isSidebarVisible
            preFocusInspectorVisible = isRightInspectorVisible
            preFocusSidebarMode = currentSidebarMode
            // Hide chrome
            if currentSidebarMode != .hidden {
                currentSidebarMode = .hidden
                applySidebarMode(animated: true)
            }
            if isRightInspectorVisible { toggleRightInspector() }
            showFocusModeEscapeHatch()
        } else {
            // Restore pre-focus state
            if preFocusSidebarMode != .hidden && currentSidebarMode == .hidden {
                currentSidebarMode = preFocusSidebarMode
                applySidebarMode(animated: true)
            }
            if preFocusInspectorVisible && !isRightInspectorVisible { toggleRightInspector() }
            hideFocusModeEscapeHatch()
        }
    }

    private func showFocusModeEscapeHatch() {
        guard let mainWindow = window else { return }
        let escapeView = FocusModeEscapeHatch(onExitFocusMode: { [weak self] in
            self?.toggleFocusMode()
        })
        let hostingView = NSHostingView(rootView: escapeView)

        let hatchSize = NSSize(width: 120, height: 50)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hatchSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = hostingView
        panel.ignoresMouseEvents = false

        positionFocusModeEscapeHatch(panel, in: mainWindow)
        mainWindow.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        focusModeEscapeHatchWindow = panel

        // Reposition on window resize
        focusModeResizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: mainWindow,
            queue: .main
        ) { [weak self, weak panel, weak mainWindow] _ in
            guard let panel, let mainWindow else { return }
            Task { @MainActor in
                self?.positionFocusModeEscapeHatch(panel, in: mainWindow)
            }
        }
    }

    private func positionFocusModeEscapeHatch(_ panel: NSWindow, in mainWindow: NSWindow) {
        let hatchSize = panel.frame.size
        let mainFrame = mainWindow.frame
        let origin = NSPoint(
            x: mainFrame.maxX - hatchSize.width - 12,
            y: mainFrame.maxY - hatchSize.height - 12
        )
        panel.setFrameOrigin(origin)
    }

    private func hideFocusModeEscapeHatch() {
        if let observer = focusModeResizeObserver {
            NotificationCenter.default.removeObserver(observer)
            focusModeResizeObserver = nil
        }
        if let hatchWindow = focusModeEscapeHatchWindow {
            window?.removeChildWindow(hatchWindow)
            hatchWindow.orderOut(nil)
            focusModeEscapeHatchWindow = nil
        }
    }

    private func showBranchPicker() {
        guard let workspace = workspaceManager?.activeWorkspace,
              workspace.projectPath != nil,
              let bus = commandBus else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let branches: [String] = try await bus.call(method: "git.list_branches")
                let currentBranch = workspace.gitBranch

                let popover = NSPopover()
                popover.behavior = .transient
                popover.contentSize = NSSize(width: 260, height: 340)
                let pickerView = BranchPickerPopover(
                    branches: branches,
                    currentBranch: currentBranch,
                    onSelect: { [weak self] branch in
                        popover.close()
                        self?.switchBranch(branch)
                    },
                    onDismiss: { popover.close() }
                ).environment(GhosttyThemeProvider.shared)
                popover.contentViewController = NSHostingController(rootView: pickerView)

                if let branchButton = self.titlebarStatusView?.subviews.first(where: {
                    $0.accessibilityLabel() == "Git branch"
                }) ?? self.titlebarStatusView {
                    popover.show(
                        relativeTo: branchButton.bounds,
                        of: branchButton,
                        preferredEdge: .maxY
                    )
                }
            } catch {
                ToastManager.shared.show(
                    "Failed to list branches: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle",
                    style: .error
                )
            }
        }
    }

    private func switchBranch(_ branch: String) {
        guard let bus = commandBus else { return }
        struct CheckoutParams: Encodable { let branch: String }
        Task { @MainActor [weak self] in
            do {
                let _: Bool = try await bus.call(
                    method: "git.checkout",
                    params: CheckoutParams(branch: branch)
                )
                self?.workspaceManager?.activeWorkspace?.gitBranch = branch
                self?.titlebarStatusView?.updateBranch(branch)
                ToastManager.shared.show("Switched to \(branch)", icon: "arrow.triangle.branch", style: .success)
            } catch {
                ToastManager.shared.show(
                    "Checkout failed: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle",
                    style: .error
                )
            }
        }
    }

    private func refreshAgentStrip() {
        guard let sessionStore, let commandCenterStore else { return }

        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sessions = sessionStore.sessions.compactMap { session -> LiveSessionEntry? in
            let started = dateFormatter.date(from: session.startedAt) ?? Date()
            let lastActivity = dateFormatter.date(from: session.lastHeartbeat) ?? started
            return LiveSessionEntry(
                id: session.id,
                name: session.name,
                status: session.status,
                startedAt: started,
                lastActivityAt: lastActivity
            )
        }

        let runs = commandCenterStore.workspaceSnapshots.flatMap(\.runs).map { fleetRun in
            CommandCenterRunEntry(
                sessionID: fleetRun.run.sessionID,
                taskTitle: fleetRun.run.taskTitle,
                provider: fleetRun.run.provider,
                model: fleetRun.run.model,
                costUSD: fleetRun.run.costUsd,
                attentionReason: fleetRun.run.attentionReason
            )
        }
        agentStripState.update(from: sessions, runs: runs)

        let targetHeight: CGFloat = agentStripState.hasEntries ? DesignTokens.Layout.agentStripHeight : 0
        if agentStripHeightConstraint?.constant != targetHeight {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = DesignTokens.Motion.fast
                ctx.allowsImplicitAnimation = true
                agentStripHeightConstraint?.animator().constant = targetHeight
            }
        }
    }

    private func openLinkedPRInBrowser() {
        guard let workspace = workspaceManager?.activeWorkspace,
              let prURL = workspace.linkedPRURL,
              let url = URL(string: prURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openRightInspector(section: RightInspectorSection) {
        guard activeWorkspaceSupportsRightInspector else { return }
        workspaceManager?.activeWorkspace?.rightInspectorSection = section
        setRightInspectorVisible(true, animated: true)
        persistence?.markDirty()
    }

    private func setRightInspectorVisible(_ visible: Bool, animated: Bool) {
        isRightInspectorVisible = visible
        syncRightInspectorPresentation(animated: animated)
        persistence?.markDirty()
    }

    private func syncRightInspectorPresentation(animated: Bool) {
        rightInspectorTransitionGeneration &+= 1
        let transitionGeneration = rightInspectorTransitionGeneration
        let shouldPresent = isRightInspectorPresented
        rightInspectorChromeState.isVisible = shouldPresent
        rightInspectorChromeState.overlayShouldAnimateAlignment = animated
        let targetWidth = shouldPresent ? rightInspectorStoredWidth : 0
        let hostView = rightInspectorHostView
        let resizerView = rightInspectorResizerView
        if shouldPresent {
            hostView?.isHidden = false
            resizerView?.isHidden = false
        }
        let updates = { [weak self] in
            self?.rightInspectorWidthConstraint?.animator().constant = targetWidth
        }
        if animated {
            let signpost = PerformanceDiagnostics.shared.beginInterval("right_inspector.toggle")
            ChromeTransitionCoordinator.shared.begin(.rightInspector)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = DesignTokens.Motion.normal
                ctx.allowsImplicitAnimation = true
                updates()
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    ChromeTransitionCoordinator.shared.end(.rightInspector)
                    PerformanceDiagnostics.shared.endInterval("right_inspector.toggle", signpost)
                    guard self.rightInspectorTransitionGeneration == transitionGeneration else { return }
                    self.rightInspectorChromeState.overlayShouldAnimateAlignment = false
                    if !self.isRightInspectorPresented {
                        hostView?.isHidden = true
                        resizerView?.isHidden = true
                    }
                }
            })
        } else {
            rightInspectorChromeState.overlayShouldAnimateAlignment = false
            rightInspectorWidthConstraint?.constant = targetWidth
            if !shouldPresent {
                hostView?.isHidden = true
                resizerView?.isHidden = true
            }
        }
        updateWindowMinWidth()
        updateRightInspectorOverlayAlignment()
    }

    private func adjustRightInspectorWidth(by delta: CGFloat) {
        rightInspectorChromeState.overlayShouldAnimateAlignment = false
        rightInspectorStoredWidth = min(
            max(rightInspectorStoredWidth - delta, DesignTokens.Layout.rightInspectorMinWidth),
            DesignTokens.Layout.rightInspectorMaxWidth
        )
        guard isRightInspectorPresented else { return }
        rightInspectorWidthConstraint?.constant = rightInspectorStoredWidth
        updateWindowMinWidth()
        updateRightInspectorOverlayAlignment()
        persistence?.markDirty()
    }

    private func updateWindowMinWidth() {
        let basePaneMinWidth: CGFloat = 800 - DesignTokens.Layout.sidebarWidth
        let leftWidth: CGFloat = switch currentSidebarMode {
        case .expanded: SidebarPreferences.sidebarWidth
        case .collapsed: DesignTokens.Layout.sidebarCollapsedWidth
        case .hidden: 0
        }
        let rightWidth = isRightInspectorPresented ? rightInspectorStoredWidth : 0
        // Content area minimum shrinks to accommodate the inspector; window minSize stays ~800.
        let minContent = max(basePaneMinWidth - rightWidth, 200)
        window?.minSize.width = leftWidth + minContent + rightWidth
        contentMinWidthConstraint?.constant = minContent
    }

    private func updateRightInspectorOverlayAlignment() {
        rightInspectorChromeState.overlayHorizontalOffset = 0
    }

    @objc private func showCommandPalette() { commandPalette?.show() }

    @objc private func showFileQuickOpen() {
        // TODO: When palette supports prefix mode, pre-fill with ":"
        commandPalette?.show()
    }

    @objc private func showShortcutSheet() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 520),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating

        let sheetView = ShortcutSheetView(
            shortcuts: ShortcutSheetView.defaultShortcuts,
            onDismiss: { panel.close() }
        ).environment(GhosttyThemeProvider.shared)

        panel.contentView = NSHostingView(rootView: sheetView)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
    }

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
            ("Show Rules Manager", "tool", nil, "Show project rules and conventions", "rules"),
            ("Show Secrets", "tool", nil, "Show project secrets and env backends", "secrets"),
            ("Show Workflow", "tool", nil, "Show the workflow state machine", "workflow"),
            ("Show SSH Manager", "tool", nil, "Show SSH keys and remote profiles", "ssh"),
            ("Show Session Replay", "tool", nil, "Show past terminal session replays", "replay"),
            ("Show Browser", "tool", "Opt+Cmd+B", "Show the built-in web browser drawer", "browser"),
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
            CommandItem(id: "view.right_inspector", title: "Toggle Right Inspector", category: "view", shortcut: "Shift+Cmd+B", description: "Show or hide the project inspector") { [weak self] in
                self?.toggleRightInspector()
            },
            CommandItem(id: "view.command_center", title: "Toggle Command Center", category: "view", shortcut: "Shift+Cmd+C", description: "Open the fleet command center window") { [weak self] in
                self?.toggleCommandCenter()
            },
            CommandItem(id: "view.focus_mode", title: "Toggle Focus Mode", category: "view", shortcut: "Shift+Cmd+F", description: "Hide all chrome for distraction-free terminal use") { [weak self] in
                self?.toggleFocusMode()
            },
            CommandItem(id: "inspector.files", title: "Show Files Inspector", category: "view", shortcut: nil, description: "Reveal the right inspector and select Files") { [weak self] in
                self?.openRightInspector(section: .files)
            },
            CommandItem(id: "inspector.changes", title: "Show Changes Inspector", category: "view", shortcut: nil, description: "Reveal the right inspector and select Changes") { [weak self] in
                self?.openRightInspector(section: .changes)
            },
            CommandItem(id: "inspector.review", title: "Show Review Inspector", category: "view", shortcut: nil, description: "Reveal the right inspector and select Review") { [weak self] in
                self?.openRightInspector(section: .review)
            },
            CommandItem(id: "view.layout_templates", title: "Layout Templates", category: "view", shortcut: "", description: "Save or load pane layout templates") { [weak self] in
                self?.titlebarTemplateAction()
            },
            CommandItem(id: "browser.focus_omnibar", title: "Focus Browser Omnibar", category: "view", shortcut: "Cmd+L", description: "Focus the built-in browser address bar") { [weak self] in
                self?.focusBrowserOmnibar()
            },
            CommandItem(id: "browser.copy_selection_with_source", title: "Copy Browser Selection with Source URL", category: "view", shortcut: nil, description: "Copy the current browser selection and append the page URL") { [weak self] in
                Task { @MainActor in
                    await self?.copyBrowserSelectionWithSource()
                }
            },
            CommandItem(id: "browser.save_markdown", title: "Save Browser Page as Markdown", category: "view", shortcut: nil, description: "Write the current page markdown into the workspace scratch capture directory") { [weak self] in
                Task { @MainActor in
                    await self?.saveBrowserPageAsMarkdown()
                }
            },
            CommandItem(id: "browser.copy_link_list", title: "Copy Browser Link List as Markdown", category: "view", shortcut: nil, description: "Copy the current page links as a markdown list") { [weak self] in
                Task { @MainActor in
                    await self?.copyBrowserLinkListAsMarkdown()
                }
            },
            CommandItem(id: "browser.drawer_shorter", title: "Make Browser Drawer Shorter", category: "view", shortcut: "Opt+Cmd+-", description: "Shrink the built-in browser drawer height") { [weak self] in
                self?.resizeBrowserDrawer(by: -DrawerSizing.keyboardStep)
            },
            CommandItem(id: "browser.drawer_taller", title: "Make Browser Drawer Taller", category: "view", shortcut: "Opt+Cmd+=", description: "Expand the built-in browser drawer height") { [weak self] in
                self?.resizeBrowserDrawer(by: DrawerSizing.keyboardStep)
            },
            CommandItem(id: "browser.pin_to_pane", title: "Pin Browser to Pane", category: "view", shortcut: "Shift+Cmd+Return", description: "Promote the browser drawer into a persistent pane") { [weak self] in
                self?.pinBrowserToPane()
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
        let vm = WorkspaceOpenerViewModel()
        if let wm = workspaceManager {
            vm.loadProjects(from: wm)
        }
        openerViewModel = vm

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        openerPanel = panel

        guard let bus = commandBus ?? CommandBus.shared else { return }
        let openerView = WorkspaceOpenerView(
            viewModel: vm,
            commandBus: bus,
            onSubmit: { [weak self] viewModel in
                panel.close()
                self?.handleOpenerSubmit(viewModel)
            },
            onCancel: { [weak self] in
                panel.close()
                self?.openerViewModel = nil
                self?.openerPanel = nil
            }
        ).environment(GhosttyThemeProvider.shared)

        // Clean up if user closes panel via the window close button
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.openerViewModel = nil
                self?.openerPanel = nil
            }
        }

        let hostingView = NSHostingView(rootView: openerView)
        panel.contentView = hostingView
        panel.setContentSize(NSSize(width: 680, height: 500))
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        // Trigger initial data load if a project is already selected
        if vm.selectedProjectPath != nil {
            vm.onProjectChanged(using: bus)
        }
    }

    private func handleOpenerSubmit(_ viewModel: WorkspaceOpenerViewModel) {
        let terminalMode = viewModel.terminalMode

        switch viewModel.selectedTab {
        case .prompt:
            if viewModel.sshEnabled {
                Task { @MainActor [weak self] in
                    await self?.presentOpenRemoteWorkspacePanel(terminalMode: terminalMode)
                }
            } else if let path = viewModel.selectedProjectPath {
                openLocalWorkspace(path: path, terminalMode: terminalMode)
            } else {
                presentOpenLocalWorkspacePanel(terminalMode: terminalMode)
            }

        case .issues:
            guard let path = viewModel.selectedProjectPath else { return }
            openLocalWorkspace(path: path, terminalMode: terminalMode)

        case .pullRequests:
            guard let path = viewModel.selectedProjectPath else { return }
            // TODO: Check out PR head branch after opening workspace
            openLocalWorkspace(path: path, terminalMode: terminalMode)

        case .branches:
            guard let path = viewModel.selectedProjectPath else { return }
            openLocalWorkspace(path: path, terminalMode: terminalMode)
        }

        openerViewModel = nil
        openerPanel = nil
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
            terminalMode: workspaceTerminalMode(for: persistenceToggle.state)
        )
    }

    private func workspaceTerminalMode(for persistenceState: NSControl.StateValue) -> WorkspaceTerminalMode {
        persistenceState == .on ? .persistent : .nonPersistent
    }

    private func makePersistenceToggle() -> NSSwitch {
        let toggle = NSSwitch(frame: .zero)
        toggle.state = .on
        toggle.toolTip = "Persistent workspaces use tmux-backed managed sessions. Unchecked starts a plain shell."
        toggle.setAccessibilityLabel("Enable session persistence")
        toggle.setAccessibilityIdentifier("openWorkspace.persistenceToggle")
        return toggle
    }

    private func makePersistenceHelperLabel() -> NSTextField {
        let label = NSTextField(
            wrappingLabelWithString: "Keeps the workspace running in a tmux-backed managed session so it can be reopened later. Turn it off to start a plain shell."
        )
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makePersistenceAccessory(
        toggle: NSSwitch,
        width: CGFloat
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: "Enable session persistence")
        titleLabel.font = .preferredFont(forTextStyle: .headline)

        let helperLabel = makePersistenceHelperLabel()
        helperLabel.preferredMaxLayoutWidth = width - (DesignTokens.Spacing.lg * 2) - 52

        let copyStack = NSStackView(views: [titleLabel, helperLabel])
        copyStack.orientation = .vertical
        copyStack.alignment = .leading
        copyStack.spacing = DesignTokens.Spacing.xs

        toggle.setContentHuggingPriority(.required, for: .horizontal)
        toggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = NSStackView(views: [copyStack, toggle])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = DesignTokens.Spacing.md
        row.detachesHiddenViews = false

        return makeAlertCard(width: width, views: [row])
    }

    private func makeAlertAccessoryStack(width: CGFloat, views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.md
        stack.edgeInsets = NSEdgeInsets(top: DesignTokens.Spacing.sm, left: 0, bottom: 0, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.layoutSubtreeIfNeeded()
        stack.frame.size = NSSize(width: width, height: stack.fittingSize.height)
        return stack
    }

    private func makeAlertCard(width: CGFloat, views: [NSView]) -> NSView {
        let contentStack = NSStackView(views: views)
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = DesignTokens.Spacing.md
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.addSubview(contentStack)

        // Explicit width constraint survives NSStackView setting
        // translatesAutoresizingMaskIntoConstraints = false on arranged subviews.
        container.widthAnchor.constraint(equalToConstant: width).isActive = true

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: container.topAnchor, constant: DesignTokens.Spacing.md),
            contentStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: DesignTokens.Spacing.md),
            contentStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -DesignTokens.Spacing.md),
            contentStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -DesignTokens.Spacing.md),
        ])

        container.layoutSubtreeIfNeeded()
        container.frame.size = NSSize(width: width, height: container.fittingSize.height)
        return container
    }

    private func installUITestReadinessView(in windowContent: NSView) {
        guard AppLaunchContext.isUITesting else { return }
        guard uiTestReadinessView == nil else { return }

        let readinessView = UITestReadinessView(frame: .zero)
        readinessView.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(readinessView)
        NSLayoutConstraint.activate([
            readinessView.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            readinessView.topAnchor.constraint(equalTo: windowContent.topAnchor),
            readinessView.widthAnchor.constraint(equalToConstant: 1),
            readinessView.heightAnchor.constraint(equalToConstant: 1),
        ])
        uiTestReadinessView = readinessView
    }

    private func setUITestReadiness(_ state: UITestReadinessState, detail: String? = nil) {
        guard AppLaunchContext.isUITesting, let uiTestReadinessView else { return }
        uiTestReadinessView.state = state.rawValue
        uiTestReadinessView.detail = detail
    }

    private func openUITestProjectWorkspace(path: String) async {
        guard let workspace = openLocalWorkspace(path: path, terminalMode: .persistent) else {
            setUITestReadiness(.projectOpenFailed, detail: "workspace manager unavailable")
            return
        }

        do {
            _ = try await workspaceManager?.ensureWorkspaceReady(
                workspace.id,
                timeoutNanoseconds: 15_000_000_000
            )
            setUITestReadiness(.projectReady)
        } catch {
            Log.workspace.error(
                "UI test project bootstrap failed for \(path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            setUITestReadiness(.projectOpenFailed, detail: error.localizedDescription)
        }
    }

    @discardableResult
    private func openLocalWorkspace(path: String, terminalMode: WorkspaceTerminalMode) -> Workspace? {
        guard let workspaceManager else {
            ToastManager.shared.show(
                "Workspace manager unavailable",
                icon: "exclamationmark.triangle",
                style: .error
            )
            return nil
        }

        let name = URL(fileURLWithPath: path).lastPathComponent
        let workspace = workspaceManager.createLocalProjectWorkspace(
            name: name,
            projectPath: path,
            terminalMode: terminalMode
        )
        ToastManager.shared.show(
            "Workspace opened: \(name)",
            icon: "folder.badge.checkmark",
            style: .success
        )
        return workspace
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
        win.isReleasedWhenClosed = false
        win.title = "Settings"
        win.appearance = NSAppearance(named: .darkAqua)
        win.minSize = NSSize(width: 600, height: 400)
        win.contentView = NSHostingView(rootView: SettingsView().environment(GhosttyThemeProvider.shared))
        win.center()
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: win,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.settingsWindow = nil
            }
        }
    }

    private enum BrowserOpenSource {
        case command
        case terminal
        case automation
    }

    private func existingBrowserSession(for workspace: Workspace) -> BrowserWorkspaceSession? {
        browserSessions[workspace.id]
    }

    private func browserSession(for workspace: Workspace) -> BrowserWorkspaceSession {
        if let existing = browserSessions[workspace.id] {
            existing.updateRestoredURL(workspace.browserLastURL.flatMap(URL.init(string:)))
            existing.updateRestoredDrawerHeight(DrawerSizing.storedHeight().map(Double.init))
            existing.updateWorkspaceProjectPath(workspace.projectPath)
            return existing
        }

        let session = BrowserWorkspaceSession(
            workspaceID: workspace.id,
            workspaceProjectPath: workspace.projectPath,
            restoredURL: workspace.browserLastURL.flatMap(URL.init(string:)),
            restoredDrawerHeight: DrawerSizing.storedHeight().map(Double.init),
            onURLChanged: { [weak self, weak workspace] url in
                guard let workspace else { return }
                workspace.browserLastURL = url?.absoluteString
                self?.persistence?.markDirty()
            },
            onDrawerHeightChanged: { [weak self] _ in
                self?.persistence?.markDirty()
            }
        )
        browserSessions[workspace.id] = session
        return session
    }

    private func activeBrowserSession() -> BrowserWorkspaceSession? {
        guard let workspace = workspaceManager?.activeWorkspace else { return nil }
        return browserSession(for: workspace)
    }

    private func existingActiveBrowserSession() -> BrowserWorkspaceSession? {
        guard let workspace = workspaceManager?.activeWorkspace else { return nil }
        return existingBrowserSession(for: workspace)
    }

    private func scheduleBrowserSessionPrewarm(for workspace: Workspace) {
        guard !AppLaunchContext.uiTestLightweightMode else { return }
        browserSessionPrewarmTask?.cancel()
        let workspaceID = workspace.id
        browserSessionPrewarmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self else { return }
            guard self.workspaceManager?.activeWorkspace?.id == workspaceID else { return }
            guard let activeWorkspace = self.workspaceManager?.activeWorkspace else { return }
            guard self.existingBrowserSession(for: activeWorkspace) == nil else { return }
            _ = self.browserSession(for: activeWorkspace)
            self.refreshBrowserDrawerOverlayRootView()
        }
    }

    private func refreshBrowserDrawerOverlayRootView() {
        guard let host = browserDrawerOverlayHostView else { return }
        let previousSession = browserDrawerPresentationModel.session

        guard let workspace = workspaceManager?.activeWorkspace else {
            previousSession?.cancelPendingDrawerRestore()
            browserDrawerPresentationModel.session = nil
            browserDrawerChromeState.isPresented = false
            host.capturesPointerEvents = false
            browserDrawerOverlayBlockerView?.capturesPointerEvents = false
            browserDrawerChromeState.drawerHitRect = .zero
            host.overlayHitRect = .zero
            browserDrawerOverlayBlockerView?.overlayHitRect = .zero
            updateToolDockState()
            return
        }

        let session = existingBrowserSession(for: workspace)
        if let previousSession, previousSession !== session {
            previousSession.cancelPendingDrawerRestore()
        }
        browserDrawerPresentationModel.session = session
        let captures = session?.isDrawerVisible ?? false
        // Enforce single-drawer: dismiss tool drawer when browser drawer presents
        if captures && toolDrawerChromeState.isPresented {
            closeToolDrawer()
        }
        browserDrawerChromeState.isPresented = captures
        host.capturesPointerEvents = captures
        browserDrawerOverlayBlockerView?.capturesPointerEvents = captures
        if !captures {
            browserDrawerChromeState.drawerHitRect = .zero
            host.overlayHitRect = .zero
            browserDrawerOverlayBlockerView?.overlayHitRect = .zero
        }
        updateToolDockState()
    }

    private func focusExistingBrowserPaneIfPresent() -> Bool {
        guard let browserTool = sidebarToolDefinition(id: "browser") else { return false }
        return focusExistingTool(browserTool, scope: .anyTab)
    }

    private func activeWorkspaceHasBrowserPane() -> Bool {
        workspaceManager?.activeWorkspace?.firstPaneLocation(ofType: "browser") != nil
    }

    private func toggleBrowserDrawer() {
        guard workspaceManager?.activeWorkspace != nil else { return }
        if focusExistingBrowserPaneIfPresent() {
            closeBrowserDrawer()
            return
        }

        guard let session = activeBrowserSession() else { return }
        if session.isDrawerVisible {
            closeBrowserDrawer()
        } else {
            if toolDrawerChromeState.isPresented { closeToolDrawer() }
            browserDrawerPreviousFirstResponder = window?.firstResponder as? NSResponder
            session.showDrawer()
            refreshBrowserDrawerOverlayRootView()
            persistence?.markDirty()
        }
    }

    private func closeBrowserDrawer() {
        guard let session = existingActiveBrowserSession(), session.isDrawerVisible else { return }
        session.hideDrawer()
        browserDrawerChromeState.drawerHitRect = .zero
        refreshBrowserDrawerOverlayRootView()
        if let previous = browserDrawerPreviousFirstResponder {
            window?.makeFirstResponder(previous)
        } else if let pane = contentAreaView?.activePaneView {
            window?.makeFirstResponder(pane)
        }
        browserDrawerPreviousFirstResponder = nil
        persistence?.markDirty()
    }

    private func focusBrowserOmnibar() {
        if focusExistingBrowserPaneIfPresent() {
            activeBrowserSession()?.requestOmnibarFocus()
            return
        }

        guard let session = activeBrowserSession() else { return }
        if !session.isDrawerVisible {
            browserDrawerPreviousFirstResponder = window?.firstResponder as? NSResponder
        }
        if toolDrawerChromeState.isPresented { closeToolDrawer() }
        session.showDrawer()
        session.requestOmnibarFocus()
        refreshBrowserDrawerOverlayRootView()
        persistence?.markDirty()
    }

    private func resizeBrowserDrawer(by delta: CGFloat) {
        guard let session = activeBrowserSession() else { return }
        if !session.isDrawerVisible {
            guard !activeWorkspaceHasBrowserPane() else { return }
            if toolDrawerChromeState.isPresented { closeToolDrawer() }
            browserDrawerPreviousFirstResponder = window?.firstResponder as? NSResponder
            session.showDrawer(focusOmnibar: false)
        }

        let availableHeight = browserDrawerOverlayHostView?.bounds.height
            ?? contentAreaView?.bounds.height
            ?? window?.contentView?.bounds.height
            ?? 0
        session.adjustDrawerHeight(by: delta, availableHeight: availableHeight)
        refreshBrowserDrawerOverlayRootView()
        persistence?.markDirty()
    }

    private func openBrowserInWorkspace(url: URL?, source: BrowserOpenSource) {
        guard let workspace = workspaceManager?.activeWorkspace else { return }
        let session = browserSession(for: workspace)

        // Close the generic tool drawer if it's open, carrying height to browser
        if toolDrawerChromeState.isPresented {
            if let h = toolDrawerContentModel.drawerHeight {
                session.setDrawerHeight(h)
            }
            closeToolDrawer()
        }

        if focusExistingBrowserPaneIfPresent() {
            if let url {
                session.navigate(to: url, revealInDrawer: false)
            } else {
                session.restoreIfNeeded()
            }
            persistence?.markDirty()
            return
        }

        if !session.isDrawerVisible {
            browserDrawerPreviousFirstResponder = window?.firstResponder as? NSResponder
        }
        if let url {
            session.navigate(to: url)
        } else {
            session.showDrawer()
        }

        if source == .command && url == nil {
            session.requestOmnibarFocus()
        }

        refreshBrowserDrawerOverlayRootView()
        persistence?.markDirty()
    }

    private func pinBrowserToPane() {
        guard let session = activeBrowserSession() else { return }
        session.hideDrawer()
        refreshBrowserDrawerOverlayRootView()
        Task { @MainActor [weak self] in
            self?.openToolAsPane("browser")
        }
    }

    private func openBrowserAsTab() {
        guard let session = activeBrowserSession() else { return }
        session.hideDrawer()
        refreshBrowserDrawerOverlayRootView()
        Task { @MainActor [weak self] in
            self?.openToolAsTab("browser")
        }
    }

    // MARK: - Generic tool drawer

    private func openToolInDrawer(_ toolID: String) {
        guard let workspace = workspaceManager?.activeWorkspace,
              let tool = sidebarTool(id: toolID, in: workspace) else { return }

        // Close browser drawer if open, carrying height to tool drawer
        if browserDrawerChromeState.isPresented {
            let browserHeight = existingActiveBrowserSession()?.preferredDrawerHeight
            if let session = existingActiveBrowserSession() {
                session.hideDrawer()
            }
            refreshBrowserDrawerOverlayRootView()
            if let h = browserHeight {
                toolDrawerContentModel.drawerHeight = h
            }
        }

        // Same tool — toggle the drawer
        if toolDrawerContentModel.activeToolID == toolID {
            if toolDrawerChromeState.isPresented {
                closeToolDrawer()
            } else {
                toolDrawerPreviousFirstResponder = window?.firstResponder as? NSResponder
                toolDrawerChromeState.isPresented = true
                toolDockState.activeToolID = toolID
            }
            return
        }

        // Different tool while drawer is already open — swap content instantly
        let alreadyPresented = toolDrawerChromeState.isPresented

        // Discard previous pane
        toolDrawerContentModel.activePaneView?.removeFromSuperview()

        // Create a fresh pane for the new tool
        guard PaneFactory.isPaneTypeAvailable(tool.paneType, in: workspace),
              let (paneID, paneView) = PaneFactory.make(type: tool.paneType) else { return }

        if !alreadyPresented {
            toolDrawerPreviousFirstResponder = window?.firstResponder as? NSResponder
        }

        // Swap content without animation when replacing
        if alreadyPresented {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                toolDrawerContentModel.activeToolID = toolID
                toolDrawerContentModel.activeToolTitle = tool.title
                toolDrawerContentModel.activePaneView = paneView
                toolDrawerContentModel.activePaneID = paneID
                // Keep current drawer height — don't reset on tool switch
            }
        } else {
            toolDrawerContentModel.activeToolID = toolID
            toolDrawerContentModel.activeToolTitle = tool.title
            toolDrawerContentModel.activePaneView = paneView
            toolDrawerContentModel.activePaneID = paneID
            toolDrawerContentModel.drawerHeight = DrawerSizing.storedHeight()
            toolDrawerChromeState.isPresented = true
        }
        toolDockState.activeToolID = toolID
    }

    private func closeToolDrawer() {
        toolDrawerChromeState.isPresented = false
        toolDrawerChromeState.drawerHitRect = .zero
        toolDockState.activeToolID = nil
        if let previous = toolDrawerPreviousFirstResponder {
            window?.makeFirstResponder(previous)
        } else if let pane = contentAreaView?.activePaneView {
            window?.makeFirstResponder(pane)
        }
        toolDrawerPreviousFirstResponder = nil
        // Defer cleanup so the dismiss animation can play
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !self.toolDrawerChromeState.isPresented else { return }
            self.toolDrawerContentModel.activePaneView?.removeFromSuperview()
            self.toolDrawerContentModel.activePaneView = nil
            self.toolDrawerContentModel.activePaneID = nil
            self.toolDrawerContentModel.activeToolID = nil
            self.toolDrawerContentModel.activeToolTitle = nil
        }
    }

    private func pinToolDrawerToPane() {
        guard let paneView = toolDrawerContentModel.activePaneView,
              let toolID = toolDrawerContentModel.activeToolID else { return }
        // Detach the pane view from the drawer before moving it
        paneView.removeFromSuperview()
        toolDrawerChromeState.isPresented = false
        toolDockState.activeToolID = nil
        toolDrawerContentModel.activePaneView = nil
        toolDrawerContentModel.activePaneID = nil
        toolDrawerContentModel.activeToolID = nil
        toolDrawerContentModel.activeToolTitle = nil
        Task { @MainActor [weak self] in
            self?.openToolAsPane(toolID)
        }
    }

    private func openToolDrawerAsTab() {
        guard let toolID = toolDrawerContentModel.activeToolID else { return }
        // Detach the pane view from the drawer
        toolDrawerContentModel.activePaneView?.removeFromSuperview()
        toolDrawerChromeState.isPresented = false
        toolDockState.activeToolID = nil
        toolDrawerContentModel.activePaneView = nil
        toolDrawerContentModel.activePaneID = nil
        toolDrawerContentModel.activeToolID = nil
        toolDrawerContentModel.activeToolTitle = nil
        Task { @MainActor [weak self] in
            self?.openToolAsTab(toolID)
        }
    }

    private func copyBrowserSelectionWithSource() async {
        guard let session = existingActiveBrowserSession() else {
            showBrowserCaptureError(BrowserCaptureError.noActivePage)
            return
        }

        do {
            let capture = try await session.copySelectionWithSource()
            ToastManager.shared.show(
                "Copied selection with source from \(capture.sourceURL.host(percentEncoded: false) ?? capture.sourceURL.absoluteString)",
                icon: "doc.on.doc",
                style: .success
            )
        } catch {
            showBrowserCaptureError(error)
        }
    }

    private func saveBrowserPageAsMarkdown() async {
        guard let session = existingActiveBrowserSession() else {
            showBrowserCaptureError(BrowserCaptureError.noActivePage)
            return
        }

        do {
            let saved = try await session.savePageAsMarkdown()
            let message: String
            if let workspace = workspaceManager?.activeWorkspace,
               let projectPath = workspace.projectPath {
                let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
                message = saved.outputURL.path.replacing(projectURL.path + "/", with: "")
            } else {
                message = saved.outputURL.lastPathComponent
            }
            ToastManager.shared.show(
                "Saved markdown to \(message)",
                icon: "square.and.arrow.down",
                style: .success
            )
        } catch {
            showBrowserCaptureError(error)
        }
    }

    private func copyBrowserLinkListAsMarkdown() async {
        guard let session = existingActiveBrowserSession() else {
            showBrowserCaptureError(BrowserCaptureError.noActivePage)
            return
        }

        do {
            let capture = try await session.copyPageLinkListAsMarkdown()
            ToastManager.shared.show(
                "Copied \(capture.links.count) page links as markdown",
                icon: "list.bullet.clipboard",
                style: .success
            )
        } catch {
            showBrowserCaptureError(error)
        }
    }

    private func showBrowserCaptureError(_ error: Error) {
        ToastManager.shared.show(
            error.localizedDescription,
            icon: "exclamationmark.triangle",
            style: .error
        )
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

    private func updateToolDockState() {
        guard let workspace = workspaceManager?.activeWorkspace else {
            toolDockState.activeToolID = nil
            toolDockState.notificationBadgeCount = 0
            return
        }

        if existingBrowserSession(for: workspace)?.isDrawerVisible == true,
           sidebarTool(id: "browser", in: workspace) != nil {
            toolDockState.activeToolID = "browser"
        } else if let paneType = contentAreaView?.activePaneView?.paneType,
                  let tool = sidebarToolDefinition(paneType: paneType),
                  sidebarTool(id: tool.id, in: workspace) != nil {
            toolDockState.activeToolID = tool.id
        } else {
            toolDockState.activeToolID = nil
        }

        toolDockState.notificationBadgeCount = workspace.unreadNotifications + workspace.terminalNotificationCount
    }

    private func setToolDockContentHovering(_ isHovering: Bool) {
        isToolDockContentHovered = isHovering
        evaluateToolDockHover()
    }

    private func setToolDockEdgeHovering(_ isHovering: Bool) {
        isToolDockEdgeHovered = isHovering
        evaluateToolDockHover()
    }

    private func evaluateToolDockHover() {
        toolDockCollapseWorkItem?.cancel()

        guard AppRuntimeSettings.shared.bottomToolBarAutoHide else {
            setToolDockExpanded(true, animated: true)
            return
        }

        if isToolDockHovered {
            setToolDockExpanded(true, animated: true)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.isToolDockHovered, AppRuntimeSettings.shared.bottomToolBarAutoHide else { return }
            self.setToolDockExpanded(false, animated: true)
        }
        toolDockCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

    private func refreshToolDockAutoHide(animated: Bool) {
        toolDockCollapseWorkItem?.cancel()
        let shouldExpand = !AppRuntimeSettings.shared.bottomToolBarAutoHide || isToolDockHovered
        setToolDockExpanded(shouldExpand, animated: animated)
    }

    private func setToolDockExpanded(_ isExpanded: Bool, animated: Bool) {
        guard let toolDockHeightConstraint else { return }
        let targetHeight = isExpanded || !AppRuntimeSettings.shared.bottomToolBarAutoHide
            ? DesignTokens.Layout.toolDockHeight
            : DesignTokens.Layout.toolDockRevealHeight
        guard toolDockHeightConstraint.constant != targetHeight else { return }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = DesignTokens.Motion.normal
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                toolDockHeightConstraint.animator().constant = targetHeight
                window?.contentView?.layoutSubtreeIfNeeded()
            }
        } else {
            toolDockHeightConstraint.constant = targetHeight
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func openToolWithDefaultPresentation(_ toolID: String) {
        if toolID == "settings" {
            openSettingsPane()
            return
        }
        if toolID == "browser" {
            // Close the generic tool drawer if it's open
            if toolDrawerChromeState.isPresented {
                closeToolDrawer()
            }
            openBrowserInWorkspace(url: nil, source: .command)
            return
        }
        openToolInDrawer(toolID)
    }

    private func openPaneTypeWithDefaultPresentation(_ paneType: String) {
        if paneType == "browser" {
            openBrowserInWorkspace(url: nil, source: .command)
            return
        }
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
        if toolID == "browser" {
            activeBrowserSession()?.hideDrawer()
            refreshBrowserDrawerOverlayRootView()
        }
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
        if toolID == "browser" {
            activeBrowserSession()?.hideDrawer()
            refreshBrowserDrawerOverlayRootView()
            if focusExistingTool(tool, scope: .anyTab) {
                return
            }
        }
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

    private func showCommandCenter(makeKey: Bool) {
        let controller = ensureCommandCenterWindowController()
        controller.present(makeKey: makeKey)
    }

    private func ensureCommandCenterWindowController() -> CommandCenterWindowController {
        if let commandCenterWindowController {
            if let restoredCommandCenterWindowFrame {
                commandCenterWindowController.applyRestoredFrame(restoredCommandCenterWindowFrame)
                self.restoredCommandCenterWindowFrame = nil
            }
            return commandCenterWindowController
        }

        let store: CommandCenterStore
        if let commandCenterStore {
            store = commandCenterStore
        } else if let workspaceManager {
            let newStore = CommandCenterStore(workspaceManager: workspaceManager)
            newStore.onPerformAction = { [weak self] action, run in
                self?.performCommandCenterAction(action, run: run)
            }
            commandCenterStore = newStore
            store = newStore
        } else {
            fatalError("Workspace manager must be initialized before Command Center")
        }

        let controller = CommandCenterWindowController(
            store: store,
            onVisibilityChanged: { [weak self] isVisible in
                guard let self else { return }
                self.restoredCommandCenterVisible = isVisible
                if isVisible, let frame = self.commandCenterWindowController?.currentFrame() {
                    self.restoredCommandCenterWindowFrame = frame
                }
                self.persistence?.markDirty()
            },
            onFrameChanged: { [weak self] frame in
                self?.restoredCommandCenterWindowFrame = frame
                self?.persistence?.markDirty()
            }
        )

        if let restoredCommandCenterWindowFrame {
            controller.applyRestoredFrame(restoredCommandCenterWindowFrame)
            self.restoredCommandCenterWindowFrame = nil
        }

        commandCenterWindowController = controller
        return controller
    }

    private func performCommandCenterAction(
        _ action: CommandCenterAction,
        run: CommandCenterFleetRun
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.performCommandCenterUIAction(action, run: run)
            } catch {
                self.presentCommandCenterActionError(error)
            }
        }
    }

    private func performCommandCenterUIAction(
        _ action: CommandCenterAction,
        run: CommandCenterFleetRun
    ) async throws {
        let readiness = try await activateWorkspaceForCommandCenter(run.workspaceID)

        switch action {
        case .openTerminal:
            openCommandCenterTerminal(run, workspace: readiness.workspace)
        case .openReplay:
            openCommandCenterReplay(run)
        case .openDiff:
            openCommandCenterDiff(run)
        case .openReview:
            openCommandCenterReview(run)
        case .openFiles:
            openCommandCenterFiles(run)
        case .killSession:
            guard let runtime = readiness.runtime else {
                throw WorkspaceActionError.runtimeNotReady
            }
            try await killCommandCenterSession(run, runtime: runtime)
        case .restartSession:
            guard let runtime = readiness.runtime else {
                throw WorkspaceActionError.runtimeNotReady
            }
            try await recoverCommandCenterSession(run, action: "restart", runtime: runtime)
        case .reattachSession:
            guard let runtime = readiness.runtime else {
                throw WorkspaceActionError.runtimeNotReady
            }
            try await recoverCommandCenterSession(run, action: "reattach", runtime: runtime)
        }

        commandCenterStore?.refreshNow()
    }

    private func activateWorkspaceForCommandCenter(
        _ workspaceID: UUID
    ) async throws -> (workspace: Workspace, runtime: WorkspaceRuntime?) {
        guard let workspaceManager else {
            throw WorkspaceActionError.workspaceUnavailable
        }
        return try await workspaceManager.ensureWorkspaceReady(workspaceID)
    }

    private func openCommandCenterTerminal(_ run: CommandCenterFleetRun, workspace: Workspace) {
        let pane = PaneFactory.makeTerminal(
            workingDirectory: run.preferredTerminalWorkingDirectory(
                fallback: workspace.defaultWorkingDirectory
            ),
            sessionID: run.run.sessionID,
            autoStartIfNeeded: run.run.sessionID == nil,
            launchMetadata: workspace.defaultTerminalMetadata()
        ).1
        insertCommandCenterPane(pane, title: "Terminal", presentation: .pane)
    }

    private func openCommandCenterReplay(_ run: CommandCenterFleetRun) {
        let pane = ReplayPaneView(frame: .zero, sessionID: run.run.sessionID)
        insertCommandCenterPane(pane, title: "Replay", presentation: .tab)
    }

    private func openCommandCenterDiff(_ run: CommandCenterFleetRun) {
        if let taskID = run.run.taskID {
            CommandCenterDeepLinkStore.shared.setPendingTaskID(taskID, for: .diff)
        }
        let pane = DiffPaneView(frame: .zero, initialTaskID: run.run.taskID)
        insertCommandCenterPane(pane, title: "Diff", presentation: .tab)
    }

    private func openCommandCenterReview(_ run: CommandCenterFleetRun) {
        if let taskID = run.run.taskID {
            CommandCenterDeepLinkStore.shared.setPendingTaskID(taskID, for: .review)
        }
        openRightInspector(section: .review)
    }

    private func openCommandCenterFiles(_ run: CommandCenterFleetRun) {
        let targetPath = run.run.relatedFilesPath
        openRightInspector(section: .files)
        if let targetPath {
            rightInspectorFileBrowserViewModel.openFile(at: targetPath)
        } else {
            rightInspectorFileBrowserViewModel.clearPendingOpenFile()
        }
    }

    private func presentCommandCenterActionError(_ error: Error) {
        Log.workspace.error(
            "Command Center action failed: \(error.localizedDescription, privacy: .public)"
        )
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Command Center Action Failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    private func killCommandCenterSession(
        _ run: CommandCenterFleetRun,
        runtime: WorkspaceRuntime
    ) async throws {
        struct SessionKillParams: Encodable {
            let sessionID: String
        }

        guard let sessionID = run.run.sessionID else { return }
        let _: SessionKillResult = try await runtime.commandBus.call(
            method: "session.kill",
            params: SessionKillParams(sessionID: sessionID)
        )
    }

    private func recoverCommandCenterSession(
        _ run: CommandCenterFleetRun,
        action: String,
        runtime: WorkspaceRuntime
    ) async throws {
        struct SessionRecoveryParams: Encodable {
            let sessionID: String
            let action: String
        }

        struct SessionRecoveryResult: Decodable {
            let ok: Bool
            let action: String
            let newSessionID: String?
        }

        guard let sessionID = run.run.sessionID else { return }
        let _: SessionRecoveryResult = try await runtime.commandBus.call(
            method: "session.recovery.execute",
            params: SessionRecoveryParams(sessionID: sessionID, action: action)
        )
    }

    private func insertCommandCenterPane(
        _ pane: NSView & PaneContent,
        title: String,
        presentation: SidebarToolDefaultPresentation
    ) {
        switch presentation {
        case .pane:
            if contentAreaView?.splitActivePane(direction: .horizontal, newPaneView: pane) == nil,
               contentAreaView?.activePaneView == nil {
                contentAreaView?.setRootPane(pane)
            }
        case .tab:
            guard let workspace = workspaceManager?.activeWorkspace else { return }
            contentAreaView?.syncPersistedPanes()
            _ = workspace.addTab(title: title)
            workspace.ensureActiveTabHasDisplayableRootPane()
            contentAreaView?.setLayoutEngine(workspace.layoutEngine)
            updateTabBar()
            if contentAreaView?.replaceActivePane(with: pane) == nil {
                contentAreaView?.setRootPane(pane)
            }
        case .drawer:
            openBrowserInWorkspace(url: nil, source: .command)
        }
        persistence?.markDirty()
    }

    private func buildSessionState() -> SessionPersistence.SessionState {
        contentAreaView?.syncPersistedPanes()
        let frame = window.map { SessionPersistence.CodableRect($0.frame) }
        return SessionPersistence.SessionState(
            windowFrame: frame,
            commandCenterWindowFrame: commandCenterWindowController?.currentFrame().map(SessionPersistence.CodableRect.init)
                ?? restoredCommandCenterWindowFrame.map(SessionPersistence.CodableRect.init),
            commandCenterVisible: commandCenterWindowController?.isWindowVisible ?? restoredCommandCenterVisible,
            workspaces: workspaceManager?.workspaces.map { $0.snapshot() } ?? [],
            activeWorkspaceID: workspaceManager?.activeWorkspaceID,
            sidebarVisible: isSidebarVisible,
            rightInspectorVisible: isRightInspectorVisible,
            rightInspectorWidth: Double(rightInspectorStoredWidth)
        )
    }

    private func applyRestoredState(_ state: SessionPersistence.SessionState) {
        // Restore sidebar mode from persisted preferences; fall back to visible/hidden boolean
        currentSidebarMode = SidebarPreferences.sidebarMode
        if !state.sidebarVisible && currentSidebarMode != .hidden {
            currentSidebarMode = .hidden
        }
        applySidebarMode(animated: false)
        isRightInspectorVisible = state.rightInspectorVisible
        restoredCommandCenterWindowFrame = state.commandCenterWindowFrame?.nsRect
        restoredCommandCenterVisible = state.commandCenterVisible
        rightInspectorChromeState.isVisible = isRightInspectorPresented
        rightInspectorStoredWidth = min(
            max(
                CGFloat(state.rightInspectorWidth ?? DesignTokens.Layout.rightInspectorDefaultWidth),
                DesignTokens.Layout.rightInspectorMinWidth
            ),
            DesignTokens.Layout.rightInspectorMaxWidth
        )
        rightInspectorWidthConstraint?.constant = isRightInspectorPresented ? rightInspectorStoredWidth : 0
        rightInspectorHostView?.isHidden = !isRightInspectorPresented
        rightInspectorResizerView?.isHidden = !isRightInspectorPresented
        updateWindowMinWidth()
        updateRightInspectorOverlayAlignment()

        if let frame = state.windowFrame?.nsRect,
           let minSize = window?.minSize,
           frame.width >= minSize.width, frame.height >= minSize.height {
            window?.setFrame(frame, display: true)
        }

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
        syncRightInspectorPresentation(animated: false)
        refreshBrowserDrawerOverlayRootView()
        updateTabBar()
    }

    private func makeRootPaneForActiveWorkspace() -> (NSView & PaneContent) {
        PaneFactory.workspaceAwareTerminal().1
    }

    private var notificationsPopover: NSPopover?
    private var usagePopover: NSPopover?
    private var resourceMonitorPopover: NSPopover?
    private var sessionsPopover: NSPopover?
    private weak var notificationToolbarButton: NSButton?
    private weak var notificationBadge: BadgeOverlayView?
    private weak var usageToolbarButton: NSButton?
    private weak var usageStatusDot: StatusDotOverlayView?
    private weak var resourceMonitorToolbarButton: NSButton?

    private func startSessionFromSessionManager() {
        sessionsPopover?.performClose(nil)
        newTerminal()
    }

    private func showSessionManager() {
        if let popover = sessionsPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let titlebarStatusView, let sessionStore else { return }
        let button = titlebarStatusView.sessionsButton

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
        updateToolDockState()
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
        popover.contentSize = NSSize(width: 430, height: 440)
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

    @objc private func showResourceMonitorPopover() {
        if let popover = resourceMonitorPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = resourceMonitorToolbarButton else { return }

        ResourceMonitorStore.shared.setInteractiveMode(true)
        Task { await ResourceMonitorStore.shared.activate() }

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 460)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: ResourceMonitorPopoverView(onOpenMonitor: { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.openResourceMonitorPane()
            })
            .environment(GhosttyThemeProvider.shared)
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        resourceMonitorPopover = popover
        NotificationCenter.default.addObserver(
            forName: NSPopover.willCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                ResourceMonitorStore.shared.setInteractiveMode(false)
                self?.resourceMonitorPopover = nil
            }
        }
    }

    private func openResourceMonitorPane() {
        openToolWithDefaultPresentation("resource_monitor")
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
                Task { @MainActor [weak self] in
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


// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    public func windowDidResize(_ notification: Notification) {
        contentAreaView?.needsLayout = true
    }

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
        window?.contentView?.layoutSubtreeIfNeeded()
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
        window?.contentView?.layoutSubtreeIfNeeded()
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

// MARK: - ResizableWindowContentView

/// Window content view that yields ALL edge hits to NSThemeFrame for resize.
/// With fullSizeContentView, subviews cover the resize handles. We must check
/// edges BEFORE traversing subviews — otherwise any subview at the edge steals
/// the hit and resize breaks.
private final class ResizableWindowContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }
        let windowPoint = superview?.convert(point, to: nil) ?? point
        let edge: CGFloat = 5
        if windowPoint.x < edge || windowPoint.x >= window.frame.width - edge { return nil }
        if windowPoint.y < edge || windowPoint.y >= window.frame.height - edge { return nil }
        return super.hitTest(point)
    }
}

// MARK: - BottomEdgeTracker

/// Invisible view at the bottom window edge that reliably detects mouse hover
/// via NSTrackingArea, bypassing the window resize handle that interferes with
/// SwiftUI's .onHover on very small views in windowed mode.
private final class BottomEdgeTracker: NSView {
    var onHoverChanged: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        guard !bounds.isEmpty else { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil // pass through all clicks to views behind
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }
}
