import Cocoa
#if canImport(GhosttyKit)
import GhosttyKit
#endif
import QuartzCore
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

private struct WorkspaceOpenerTrustParams: Encodable {
    let path: String
}

private struct WorkspaceOpenerInitializeParams: Encodable {
    let path: String
    let projectName: String?
    let projectBrief: String?
    let defaultProvider: String?
}

private struct ToolbarGitCommitParams: Encodable, Sendable {
    let message: String
}

private struct ToolbarGitCommitResult: Decodable, Sendable {
    let success: Bool
    let commitSha: String?
    let errorMessage: String?
}

private struct ToolbarGitPushResult: Decodable, Sendable {
    let success: Bool
    let errorMessage: String?
}

@MainActor
protocol TitlebarGitActionWorkspaceManaging: AnyObject {
    var activeWorkspaceID: UUID? { get }
    func ensureWorkspaceReady(
        _ workspaceID: UUID,
        timeoutNanoseconds: UInt64
    ) async throws -> (workspace: Workspace, runtime: WorkspaceRuntime?)
}

extension WorkspaceManager: TitlebarGitActionWorkspaceManaging {}

@MainActor
func resolveTitlebarGitActionCommandBus(
    workspaceManager: any TitlebarGitActionWorkspaceManaging,
    timeoutNanoseconds: UInt64 = 5_000_000_000
) async throws -> any CommandCalling {
    guard let workspaceID = workspaceManager.activeWorkspaceID else {
        throw WorkspaceActionError.workspaceUnavailable
    }

    let readiness = try await workspaceManager.ensureWorkspaceReady(
        workspaceID,
        timeoutNanoseconds: timeoutNanoseconds
    )
    guard let runtime = readiness.runtime else {
        throw WorkspaceActionError.runtimeNotReady
    }
    return runtime.commandBus
}

struct TitlebarStatusControlAvailability: Equatable {
    let branchEnabled: Bool
    let sessionsEnabled: Bool
}

func resolveTitlebarStatusControlAvailability(
    hasProject: Bool,
    hasGitBranch: Bool,
    hasSessionStore: Bool
) -> TitlebarStatusControlAvailability {
    TitlebarStatusControlAvailability(
        branchEnabled: hasProject || hasGitBranch,
        sessionsEnabled: hasSessionStore
    )
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

    /// Read-only accessor for App Intents to query workspace state.
    var workspaceManagerForIntents: WorkspaceManager? { workspaceManager }
    private var commandCenterStore: CommandCenterStore?
    private var commandCenterWindowController: CommandCenterWindowController?
    private var contentAreaView: ContentAreaView?
    private var tabBarView: TabBarView?
    private var titlebarStatusView: TitlebarStatusView?
    private var toolDockHostView: NSView?
    private var toolDockHeightConstraint: NSLayoutConstraint?
    private var sidebarHostView: NSView?
    private var sidebarContentView: NSView?
    private var sidebarWidthConstraint: NSLayoutConstraint?
    private var sidebarResizerView: NSView?
    private var rightInspectorHostView: NSView?
    private var rightInspectorFooterView: NSView?
    private var rightInspectorWidthConstraint: NSLayoutConstraint?
    private var rightInspectorResizerView: NSView?
    private var rightInspectorOverlayBlockerView: RightInspectorOverlayBlockerView?
    private var rightInspectorOverlayHostView: RightInspectorOverlayHostingView<AnyView>?
    private var toolDrawerOverlayBlockerView: ToolDrawerOverlayBlockerView?
    private var toolDrawerOverlayHostView: ToolDrawerOverlayHostingView<AnyView>?
    private var uiTestReadinessView: UITestReadinessView?
    private var contentLeadingConstraint: NSLayoutConstraint?
    private var contentMinWidthConstraint: NSLayoutConstraint?
    private var tabBarLeadingConstraint: NSLayoutConstraint?
    private var contentTopToTabBar: NSLayoutConstraint?
    private var contentTopToTitlebar: NSLayoutConstraint?
    private var titlebarFillBottomConstraint: NSLayoutConstraint?
    private var titlebarFillMinHeightConstraint: NSLayoutConstraint?
    private var titlebarOpenBtn: CapsuleButton?
    private var titlebarCommitBtn: CapsuleButton?
    private var titlebarTemplateBtn: NSButton?
    private var sidebarToggleLeadingConstraint: NSLayoutConstraint?
    private var sidebarToggleBtn: NSView?
    private var titlebarWorkspaceObservationGeneration: UInt64 = 0
    private var commandPalette: CommandPalette?
    private var persistence: SessionPersistence?
    private var isSidebarVisible = true
    private var currentSidebarMode: SidebarMode = SidebarPreferences.sidebarMode
    private var renderedSidebarMode: SidebarMode = .expanded
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
    private let toolDrawerChromeState = ToolDrawerChromeState()
    private let toolDrawerContentModel = ToolDrawerContentModel()
    private var browserToolBridge: BrowserToolBridge?
    private var terminalOpenURLObserver: NSObjectProtocol?
    private var nativeNotificationBridgeObserverID: UUID?
    private var browserSessions: [UUID: BrowserWorkspaceSession] = [:]
    private var browserSessionPrewarmTask: Task<Void, Never>?
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
    private var shouldKeepToolDockExpanded: Bool { toolDrawerChromeState.isPresented }
    private var toolDockCollapseWorkItem: DispatchWorkItem?
    private var toolDrawerCleanupWorkItem: DispatchWorkItem?
    private var toolDockTriggerView: NSView?
    var updateCoordinator: AppUpdateCoordinator?
    private var ownsGhosttyAppLifecycle = false
    private var previousSharedCommandBus: (any CommandCalling)?
    private var previousSharedSessionBridge: (any SessionBridging)?
    private var previousPaneFactorySessionBridge: (any SessionBridging)?
    private var previousPaneFactoryActiveWorkspaceProvider: (() -> Workspace?)?
    private var previousPaneFactoryBrowserSessionProvider: ((Workspace) -> BrowserWorkspaceSession)?

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
        if !AppLaunchContext.isTesting {
            NativeNotificationManager.shared.setup()
        }

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

        // Enforce minimum frame after all restoration paths — catches any external
        // corruption (macOS state restoration, corrupt session data, etc.)
        enforceMinimumWindowFrame()

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

    func shutdownForTesting() {
        ChromeTransitionCoordinator.shared.reset()
        persistence?.stopAutoSave()
        cancelPendingToolDrawerCleanup()
        toolDockCollapseWorkItem?.cancel()
        toolDockCollapseWorkItem = nil
        prepareOwnedChromeForTestingShutdown()
        releaseOwnedWindowsForTesting()
        clearOwnedUIStateForTesting()
        shutdownRuntime()
        if let delegate = NSApp.delegate as AnyObject?, delegate === self {
            NSApp.delegate = nil
        }
    }

    func resetForIntegrationTesting() {
        closeOpenerPanel()
        cancelPendingToolDrawerCleanup()
        toolDockCollapseWorkItem?.cancel()
        toolDockCollapseWorkItem = nil
        toolDrawerPreviousFirstResponder = nil

        toolDrawerChromeState.isPresented = false
        toolDrawerChromeState.drawerHitRect = .zero
        toolDrawerOverlayBlockerView?.capturesPointerEvents = false
        toolDrawerOverlayBlockerView?.overlayHitRect = .zero
        toolDrawerOverlayHostView?.capturesPointerEvents = false
        toolDrawerOverlayHostView?.overlayHitRect = .zero
        clearToolDrawerContent()
        toolDockState.activeToolID = nil

        browserSessions.values.forEach { $0.prepareForTeardown() }
        browserSessions.removeAll()

        if let workspace = workspaceManager?.activeWorkspace {
            contentAreaView?.syncPersistedPanes()
            while workspace.tabs.count > 1 {
                _ = workspace.closeTab(at: workspace.tabs.count - 1)
            }
            workspace.activeTabIndex = 0
            _ = workspace.renameTab(at: 0, to: "Terminal")
            _ = workspace.ensureActiveTabHasDisplayableRootPane()
            contentAreaView?.setLayoutEngine(workspace.layoutEngine)
            updateTabBar()
        }

        refreshToolDockAutoHide(animated: false)
        window?.makeFirstResponder(contentAreaView?.activePaneView)
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func initializeRuntime() {
        // Point ghostty at the Ghostty.app resource directory so it can find
        // built-in themes, terminfo, etc. Without this, the embedded library
        // looks inside Pnevma's own bundle (which doesn't ship these files).
        let ghosttyResources = "/Applications/Ghostty.app/Contents/Resources/ghostty"
        if FileManager.default.fileExists(atPath: ghosttyResources) {
            setenv("GHOSTTY_RESOURCES_DIR", ghosttyResources, 0)
        }

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
            previousSharedCommandBus = CommandBus.shared
            CommandBus.shared = activeCommandBus
        }

        if !AppLaunchContext.uiTestLightweightMode {
            _ = GhosttyRuntime.initializeIfNeeded()
            if GhosttyRuntime.isProcessInitialized {
                ownsGhosttyAppLifecycle = TerminalSurface.initializeGhostty()
            }
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
            previousSharedSessionBridge = SessionBridge.shared
            previousPaneFactorySessionBridge = PaneFactory.sessionBridge
            previousPaneFactoryActiveWorkspaceProvider = PaneFactory.activeWorkspaceProvider
            previousPaneFactoryBrowserSessionProvider = PaneFactory.browserSessionProvider
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
            self?.refreshBottomDrawerBrowserSession()
            if let workspace = self?.workspaceManager?.activeWorkspace {
                self?.scheduleBrowserSessionPrewarm(for: workspace)
            }
            self?.observeActiveWorkspaceForTitlebar()
            self?.refreshTitlebarChromeState()
            self?.updateNotificationBadge()
            // VoiceOver: announce workspace switch
            if let name = self?.workspaceManager?.activeWorkspace?.name,
               NSWorkspace.shared.isVoiceOverEnabled {
                NSAccessibility.post(
                    element: NSApp.mainWindow as Any,
                    notification: .announcementRequested,
                    userInfo: [.announcement: "Switched to workspace \(name)", .priority: NSAccessibilityPriorityLevel.high.rawValue]
                )
            }
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
        toolDockCollapseWorkItem?.cancel()
        toolDockCollapseWorkItem = nil
        toolDrawerCleanupWorkItem?.cancel()
        toolDrawerCleanupWorkItem = nil
        browserSessionPrewarmTask?.cancel()
        browserSessionPrewarmTask = nil
        for session in browserSessions.values {
            session.cancelPendingDrawerRestore()
            session.prepareForTeardown()
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

        workspaceManager?.shutdown()
        workspaceManager = nil
        sessionStore = nil
        browserSessions.removeAll()
        browserToolBridge = nil
        commandCenterStore = nil
        activeCommandBus = nil
        fallbackCommandBus = nil
        commandBus = nil
        CommandBus.shared = previousSharedCommandBus
        previousSharedCommandBus = nil
        SessionBridge.shared = previousSharedSessionBridge
        previousSharedSessionBridge = nil
        PaneFactory.sessionBridge = previousPaneFactorySessionBridge
        previousPaneFactorySessionBridge = nil
        PaneFactory.activeWorkspaceProvider = previousPaneFactoryActiveWorkspaceProvider
        previousPaneFactoryActiveWorkspaceProvider = nil
        PaneFactory.browserSessionProvider = previousPaneFactoryBrowserSessionProvider
        previousPaneFactoryBrowserSessionProvider = nil
        sessionBridge = nil

        if ownsGhosttyAppLifecycle {
            TerminalSurface.teardownAllSurfaces()
            TerminalSurface.shutdownGhostty()
            ownsGhosttyAppLifecycle = false
        }

        bridge?.destroy()
        bridge = nil
    }

    private func releaseOwnedWindowsForTesting() {
        ownedWindowsForTesting.forEach { releaseWindowForTesting($0) }
    }

    private var ownedWindowsForTesting: [NSWindow] {
        [
            commandCenterWindowController?.window,
            openerPanel,
            settingsWindow,
            smokeWindow,
            focusModeEscapeHatchWindow,
            window,
        ]
        .compactMap { $0 }
    }

    private func prepareOwnedChromeForTestingShutdown() {
        toolDrawerChromeState.isPresented = false
        toolDrawerChromeState.drawerHitRect = .zero
        rightInspectorChromeState.isVisible = false
        rightInspectorChromeState.overlayHitRect = .zero

        toolDrawerOverlayBlockerView?.capturesPointerEvents = false
        toolDrawerOverlayBlockerView?.overlayHitRect = .zero
        toolDrawerOverlayHostView?.capturesPointerEvents = false
        toolDrawerOverlayHostView?.overlayHitRect = .zero
        toolDrawerOverlayHostView?.rootView = AnyView(EmptyView())

        rightInspectorOverlayBlockerView?.capturesPointerEvents = false
        rightInspectorOverlayBlockerView?.overlayHitRect = .zero
        rightInspectorOverlayHostView?.capturesPointerEvents = false
        rightInspectorOverlayHostView?.overlayHitRect = .zero
        rightInspectorOverlayHostView?.rootView = AnyView(EmptyView())

        clearToolDrawerContent(markChanged: false)
    }

    private func releaseWindowForTesting(_ window: NSWindow) {
        window.childWindows?.forEach { child in
            window.removeChildWindow(child)
            child.orderOut(nil)
            child.close()
        }
        window.orderOut(nil)
        window.close()
    }

    private func clearOwnedUIStateForTesting() {
        clearToolDrawerContent(markChanged: false)
        toolDrawerChromeState.isPresented = false
        toolDrawerChromeState.drawerHitRect = .zero
        rightInspectorChromeState.isVisible = false
        rightInspectorChromeState.overlayHitRect = .zero
        rightInspectorOverlayBlockerView?.capturesPointerEvents = false
        rightInspectorOverlayHostView?.capturesPointerEvents = false
        toolDrawerOverlayBlockerView?.capturesPointerEvents = false
        toolDrawerOverlayHostView?.capturesPointerEvents = false

        contentAreaView = nil
        tabBarView = nil
        titlebarStatusView = nil
        toolDockHostView = nil
        sidebarHostView = nil
        sidebarContentView = nil
        sidebarResizerView = nil
        rightInspectorHostView = nil
        rightInspectorFooterView = nil
        rightInspectorResizerView = nil
        rightInspectorOverlayBlockerView = nil
        rightInspectorOverlayHostView = nil
        toolDrawerOverlayBlockerView = nil
        toolDrawerOverlayHostView = nil
        uiTestReadinessView = nil
        titlebarOpenBtn = nil
        titlebarCommitBtn = nil
        titlebarTemplateBtn = nil
        sidebarToggleBtn = nil
        collapsedRailHostView = nil
        toolDockTriggerView = nil
        smokeHostView = nil

        contentLeadingConstraint = nil
        contentMinWidthConstraint = nil
        tabBarLeadingConstraint = nil
        contentTopToTabBar = nil
        contentTopToTitlebar = nil
        titlebarFillBottomConstraint = nil
        titlebarFillMinHeightConstraint = nil
        sidebarWidthConstraint = nil
        rightInspectorWidthConstraint = nil
        toolDockHeightConstraint = nil
        sidebarToggleLeadingConstraint = nil

        toolDrawerPreviousFirstResponder = nil
        commandPalette = nil
        toastController = nil
        openerViewModel = nil
        openerPanel = nil
        settingsWindow = nil
        smokeWindow = nil
        window = nil
        commandCenterWindowController = nil
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !AppLaunchContext.isTesting
    }

    // MARK: - Spotlight Continuation (HIG §8.2)

    public func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == "com.apple.corespotlightitem",
              let identifier = userActivity.userInfo?["kCSSearchableItemActivityIdentifier"] as? String,
              identifier.hasPrefix("workspace."),
              let uuidString = identifier.split(separator: ".").last.map(String.init),
              let uuid = UUID(uuidString: uuidString) else {
            return false
        }
        workspaceManager?.switchToWorkspace(uuid)
        return true
    }

    // MARK: - Dock Menu (HIG §8.1)

    public func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Workspace", action: #selector(openWorkspaceAction), keyEquivalent: "")
        menu.addItem(.separator())
        if let workspaces = workspaceManager?.workspaces {
            for workspace in workspaces.prefix(8) {
                let item = NSMenuItem(title: workspace.name, action: #selector(dockMenuSwitchWorkspace(_:)), keyEquivalent: "")
                item.representedObject = workspace.id
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func dockMenuSwitchWorkspace(_ sender: NSMenuItem) {
        guard let workspaceID = sender.representedObject as? UUID else { return }
        workspaceManager?.switchToWorkspace(workspaceID)
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
                    message: "The terminal still has a running process. Managed sessions will try to reattach on next launch if their backends are still running; otherwise Pnevma will fall back to the archived transcript. Unmanaged shells will exit when the app quits.",
                    onCancel: {
                        sender.reply(toApplicationShouldTerminate: false)
                    }
                ) {
                    Task { @MainActor [weak self] in
                        PaneFactory.isAppShuttingDown = true
                        await self?.workspaceManager?.prepareForShutdown()
                        sender.reply(toApplicationShouldTerminate: true)
                    }
                }
            } else {
                Task { @MainActor [weak self] in
                    PaneFactory.isAppShuttingDown = true
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
        win.toolbarStyle = .unifiedCompact
        // Tab bar — added as a content-level view below the titlebar, not a toolbar item
        let tabBar = TabBarView()
        tabBar.onSelectTab = { [weak self] index in self?.switchToTab(index) }
        tabBar.onCloseTab = { [weak self] index in self?.closeTab(at: index) }
        tabBar.onAddTab = { [weak self] in self?.newTab() }
        tabBar.onRenameTab = { [weak self] tabID, title in
            self?.renameTab(id: tabID, to: title)
        }
        tabBar.isHidden = true
        self.tabBarView = tabBar

        win.center()
        win.minSize = NSSize(width: 800, height: 500)
        win.isRestorable = false

        let windowContent = MainWindowContentView(frame: NSRect(origin: .zero, size: contentRect.size))
        windowContent.autoresizingMask = [.width, .height]
        win.contentView = windowContent

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

        contentAreaView?.onDroppedDirectory = { [weak self] url in
            let name = url.lastPathComponent
            self?.workspaceManager?.createWorkspace(name: name, projectPath: url.path)
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
            onAddWorkspace: { [weak self] context in
                self?.openWorkspace(context: context)
            },
            onOpenSettings: { [weak self] in
                self?.openSettingsPane()
            }
        )
        let sidebarHost = NSHostingView(rootView: sidebarView.environment(GhosttyThemeProvider.shared))
        sidebarHost.sizingOptions = []
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

        let sidebarResizer = SidebarResizeHandleView()
        sidebarResizer.onResize = { [weak self] delta in
            self?.adjustSidebarWidth(by: delta)
        }
        sidebarResizer.isHidden = currentSidebarMode != .expanded
        sidebarResizer.alphaValue = currentSidebarMode == .expanded ? 1 : 0
        self.sidebarResizerView = sidebarResizer

        // Collapsed sidebar rail — icon-only mode
        let collapsedRailView = SidebarCollapsedRailView(
            workspaceManager: workspaceManager,
            onSelectWorkspace: { [weak self] id in
                self?.workspaceManager?.switchToWorkspace(id)
            }
        ).environment(GhosttyThemeProvider.shared)
        let collapsedRailHost = NSHostingView(rootView: AnyView(collapsedRailView))
        collapsedRailHost.sizingOptions = []
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
        let toolDockHost = FirstMouseHostingView(
            rootView: toolDockView.environment(GhosttyThemeProvider.shared)
        )
        toolDockHost.sizingOptions = []
        toolDockHost.setAccessibilityIdentifier("tool-dock.view")
        toolDockHost.wantsLayer = true
        toolDockHost.layer?.masksToBounds = false

        let toolDockContainer = ToolDockContainerView()
        toolDockContainer.wantsLayer = true
        toolDockContainer.layer?.masksToBounds = false
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
        rightInspectorHost.sizingOptions = []
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

        let rightInspectorFooter = ThemedRightInspectorBackingView(showsTopSeparator: true)
        self.rightInspectorFooterView = rightInspectorFooter

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
        toolDrawerHost.onBoundsChanged = { [weak self] in
            self?.syncToolDrawerPointerCapture()
        }
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

        let titlebarSymbolConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)

        let sidebarToggleBtn = makeTitlebarButton(
            symbolName: "sidebar.left",
            accessibilityDescription: "Toggle Sidebar",
            toolTip: "Toggle Sidebar",
            action: #selector(toggleSidebar),
            symbolConfig: titlebarSymbolConfig
        )
        sidebarToggleBtn.setAccessibilityIdentifier("titlebar.toggleSidebar")
        self.sidebarToggleBtn = sidebarToggleBtn
        let notificationsBtn = makeTitlebarButton(
            symbolName: "bell",
            accessibilityDescription: "Notifications",
            toolTip: "Notifications",
            action: #selector(showNotifications),
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemYellow
        )
        notificationsBtn.setAccessibilityIdentifier("titlebar.notifications")
        notificationToolbarButton = notificationsBtn
        let badge = BadgeOverlayView(frame: NSRect(x: 12, y: 0, width: 18, height: 12))
        notificationsBtn.addSubview(badge)
        notificationBadge = badge
        let usageBtn = makeTitlebarButton(
            symbolName: "chart.line.uptrend.xyaxis",
            accessibilityDescription: "Usage",
            toolTip: "Usage",
            action: #selector(showUsagePopover),
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemBlue
        )
        usageBtn.setAccessibilityIdentifier("titlebar.usage")
        usageToolbarButton = usageBtn
        let statusDot = StatusDotOverlayView(frame: NSRect(x: 16, y: 3, width: 8, height: 8))
        usageBtn.addSubview(statusDot)
        usageStatusDot = statusDot
        let resourceMonitorBtn = makeTitlebarButton(
            symbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "Resources",
            toolTip: "Resources",
            action: #selector(showResourceMonitorPopover),
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemTeal
        )
        resourceMonitorBtn.setAccessibilityIdentifier("titlebar.resources")
        resourceMonitorToolbarButton = resourceMonitorBtn
        let addWorkspaceBtn = makeTitlebarButton(
            symbolName: "plus",
            accessibilityDescription: "Open Workspace",
            toolTip: "Open Workspace",
            action: #selector(openWorkspaceAction),
            symbolConfig: titlebarSymbolConfig,
            hoverTintColor: .systemGreen
        )
        addWorkspaceBtn.setAccessibilityIdentifier("titlebar.openWorkspace")

        // Layout template button — positioned at the content area leading edge
        let templateBtn = makeTitlebarButton(
            symbolName: "rectangle.split.2x1",
            accessibilityDescription: "Layout Templates",
            toolTip: "Layout Templates",
            action: #selector(titlebarTemplateAction),
            symbolConfig: titlebarSymbolConfig
        )
        templateBtn.setAccessibilityIdentifier("titlebar.layoutTemplates")
        self.titlebarTemplateBtn = templateBtn

        let openBtn = CapsuleButton(icon: "folder", label: "Open")
        openBtn.showsDropdownIndicator = true
        openBtn.target = self
        openBtn.action = #selector(titlebarOpenAction)
        openBtn.setAccessibilityIdentifier("titlebar.open")
        self.titlebarOpenBtn = openBtn

        let commitBtn = CapsuleButton(icon: "point.3.connected.trianglepath.dotted", label: "Commit")
        commitBtn.showsDropdownIndicator = true
        commitBtn.target = self
        commitBtn.action = #selector(titlebarCommitAction)
        commitBtn.onMenuRequested = { [weak self] button in
            self?.showTitlebarGitActionsMenu(from: button)
        }
        commitBtn.setAccessibilityIdentifier("titlebar.commit")
        self.titlebarCommitBtn = commitBtn

        let leadingTitlebarGroup = TitlebarControlGroupView(
            arrangedSubviews: [sidebarToggleBtn, templateBtn],
            separatorAfterIndices: [0]
        )
        let primaryActionGroup = TitlebarControlGroupView(
            arrangedSubviews: [openBtn, commitBtn],
            separatorAfterIndices: [0]
        )
        let utilityActionGroup = TitlebarControlGroupView(
            arrangedSubviews: [resourceMonitorBtn, usageBtn, notificationsBtn, addWorkspaceBtn],
            separatorAfterIndices: [2]
        )

        for view in [sidebarBacking, tabBar, contentArea, sidebarResizer, toolDock,
                      rightInspectorBacking, rightInspectorFooter, rightInspectorResizer,
                      leadingTitlebarGroup, utilityActionGroup, titlebarStatus,
                      primaryActionGroup] as [NSView] {
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
        toolDrawerBlocker.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(toolDrawerBlocker)
        toolDrawerHost.translatesAutoresizingMaskIntoConstraints = false
        windowContent.addSubview(toolDrawerHost)

        // Keep the chrome bands above content/overlay hosts so transparent or
        // zero-height content views cannot steal interaction from the tab bar.
        windowContent.addSubview(toolDock, positioned: .above, relativeTo: rightInspectorOverlayBlocker)
        windowContent.addSubview(toolDock, positioned: .above, relativeTo: rightInspectorOverlayHost)
        windowContent.addSubview(toolDock, positioned: .above, relativeTo: toolDrawerBlocker)
        windowContent.addSubview(toolDock, positioned: .above, relativeTo: toolDrawerHost)
        windowContent.addSubview(tabBar, positioned: .above, relativeTo: toolDrawerHost)

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

        // Content area top: switches between below-tab-bar and directly below the titlebar fill.
        let contentTopToTabConstraint = contentArea.topAnchor.constraint(equalTo: tabBar.bottomAnchor)
        let contentTopToTitlebarConstraint = contentArea.topAnchor.constraint(equalTo: titlebarFill.bottomAnchor)
        // Tab bar starts hidden (single tab), so content starts directly below the titlebar fill.
        contentTopToTabConstraint.isActive = false
        contentTopToTitlebarConstraint.isActive = true

        sidebarWidthConstraint = swc
        rightInspectorWidthConstraint = rightInspectorWidth
        contentLeadingConstraint = clc
        tabBarLeadingConstraint = tblc
        self.toolDockHeightConstraint = toolDockHeightConstraint
        contentTopToTabBar = contentTopToTabConstraint
        contentTopToTitlebar = contentTopToTitlebarConstraint

        // Titlebar fill bottom tracks the safe area in windowed mode but
        // gets a minimum height in fullscreen so buttons don't get clipped.
        let titlebarBottom = titlebarFill.bottomAnchor.constraint(equalTo: windowContent.safeAreaLayoutGuide.topAnchor)
        titlebarBottom.priority = .defaultHigh
        self.titlebarFillBottomConstraint = titlebarBottom

        let titlebarMinHeight = titlebarFill.heightAnchor.constraint(greaterThanOrEqualToConstant: 38)
        titlebarMinHeight.isActive = false
        self.titlebarFillMinHeightConstraint = titlebarMinHeight

        let sidebarToggleLeading = leadingTitlebarGroup.leadingAnchor.constraint(
            equalTo: windowContent.leadingAnchor, constant: 76
        )
        self.sidebarToggleLeadingConstraint = sidebarToggleLeading

        let minContentWidth = win.minSize.width - sidebarWidth
        let contentMinWidth = contentArea.widthAnchor.constraint(greaterThanOrEqualToConstant: minContentWidth)
        // Priority below NSWindow-current-width (500) so this minimum doesn't
        // drive the window's size and prevent horizontal resize. Must be high
        // enough for internal layout to work correctly (> 250).
        contentMinWidth.priority = NSLayoutConstraint.Priority(490)
        self.contentMinWidthConstraint = contentMinWidth

        let titlebarStatusCenterX = titlebarStatus.centerXAnchor.constraint(equalTo: titlebarFill.centerXAnchor)
        titlebarStatusCenterX.priority = .defaultLow

        NSLayoutConstraint.activate([
            sidebarToggleLeading,
            titlebarFill.topAnchor.constraint(equalTo: windowContent.topAnchor),
            titlebarBottom,
            titlebarFill.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            titlebarFill.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),

            sidebarBacking.leadingAnchor.constraint(equalTo: windowContent.leadingAnchor),
            sidebarBacking.topAnchor.constraint(equalTo: titlebarFill.bottomAnchor),
            swc,

            rightInspectorBacking.topAnchor.constraint(equalTo: titlebarFill.bottomAnchor),
            rightInspectorBacking.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor),
            rightInspectorWidth,

            // Tab bar: flush below titlebar fill, tracks sidebar edge
            tblc,
            tabBar.trailingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor),
            tabBar.topAnchor.constraint(equalTo: titlebarFill.bottomAnchor),
            tabBar.heightAnchor.constraint(equalToConstant: tabBarHeight),

            clc,
            contentArea.trailingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: toolDock.topAnchor),
            contentMinWidth,

            sidebarBacking.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            sidebarResizer.leadingAnchor.constraint(
                equalTo: sidebarBacking.trailingAnchor,
                constant: -DesignTokens.Layout.dividerHoverWidth
            ),
            sidebarResizer.trailingAnchor.constraint(
                equalTo: sidebarBacking.trailingAnchor,
                constant: DesignTokens.Layout.dividerHoverWidth
            ),
            sidebarResizer.topAnchor.constraint(equalTo: titlebarFill.bottomAnchor),
            sidebarResizer.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),

            rightInspectorBacking.bottomAnchor.constraint(equalTo: toolDock.topAnchor),
            rightInspectorFooter.leadingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor),
            rightInspectorFooter.trailingAnchor.constraint(equalTo: rightInspectorBacking.trailingAnchor),
            rightInspectorFooter.topAnchor.constraint(equalTo: toolDock.topAnchor),
            rightInspectorFooter.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),

            toolDock.leadingAnchor.constraint(equalTo: sidebarBacking.trailingAnchor),
            toolDock.trailingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor),
            toolDock.bottomAnchor.constraint(equalTo: windowContent.bottomAnchor),
            toolDockHeightConstraint,

            rightInspectorResizer.leadingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor, constant: -DesignTokens.Layout.dividerHoverWidth),
            rightInspectorResizer.trailingAnchor.constraint(equalTo: rightInspectorBacking.leadingAnchor, constant: DesignTokens.Layout.dividerHoverWidth),
            rightInspectorResizer.topAnchor.constraint(equalTo: titlebarFill.bottomAnchor),
            rightInspectorResizer.bottomAnchor.constraint(equalTo: toolDock.topAnchor),

            leadingTitlebarGroup.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),

            utilityActionGroup.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            utilityActionGroup.trailingAnchor.constraint(equalTo: windowContent.trailingAnchor, constant: -12),

            primaryActionGroup.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            primaryActionGroup.trailingAnchor.constraint(
                equalTo: utilityActionGroup.leadingAnchor,
                constant: -DesignTokens.Layout.titlebarInterGroupSpacing
            ),

            titlebarStatus.centerYAnchor.constraint(equalTo: titlebarFill.centerYAnchor),
            titlebarStatus.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingTitlebarGroup.trailingAnchor,
                constant: 12
            ),
            titlebarStatus.trailingAnchor.constraint(
                lessThanOrEqualTo: primaryActionGroup.leadingAnchor,
                constant: -12
            ),
            titlebarStatusCenterX,

            rightInspectorOverlayBlocker.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            rightInspectorOverlayBlocker.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            rightInspectorOverlayBlocker.topAnchor.constraint(equalTo: contentArea.topAnchor),
            rightInspectorOverlayBlocker.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),

            rightInspectorOverlayHost.leadingAnchor.constraint(equalTo: contentArea.leadingAnchor),
            rightInspectorOverlayHost.trailingAnchor.constraint(equalTo: contentArea.trailingAnchor),
            rightInspectorOverlayHost.topAnchor.constraint(equalTo: contentArea.topAnchor),
            rightInspectorOverlayHost.bottomAnchor.constraint(equalTo: contentArea.bottomAnchor),

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
        updateWindowMinWidth()
        refreshBottomDrawerBrowserSession()
        if let workspace = workspaceManager.activeWorkspace {
            scheduleBrowserSessionPrewarm(for: workspace)
        }
        updateUsageToolbarStatus()
        observeActiveWorkspaceForTitlebar()
        refreshTitlebarChromeState()
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
            if AppLaunchContext.isUITesting {
                NSApp.activate(ignoringOtherApps: true)
            }
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
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
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

        // Tab menu
        let tabMenu = NSMenu(title: "Tab")

        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(nextTab), keyEquivalent: "\t")
        nextTabItem.keyEquivalentModifierMask = [.control]
        nextTabItem.identifier = NSUserInterfaceItemIdentifier("menu.next_tab")
        tabMenu.addItem(nextTabItem)

        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(previousTab), keyEquivalent: "\t")
        prevTabItem.keyEquivalentModifierMask = [.control, .shift]
        prevTabItem.identifier = NSUserInterfaceItemIdentifier("menu.previous_tab")
        tabMenu.addItem(prevTabItem)

        tabMenu.addItem(.separator())

        for i in 1...8 {
            let item = NSMenuItem(title: "Tab \(i)", action: #selector(gotoTabByTag(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.control]
            item.tag = i
            item.identifier = NSUserInterfaceItemIdentifier("menu.goto_tab_\(i)")
            tabMenu.addItem(item)
        }
        let lastTabItem = NSMenuItem(title: "Last Tab", action: #selector(gotoLastTab), keyEquivalent: "9")
        lastTabItem.keyEquivalentModifierMask = [.control]
        lastTabItem.identifier = NSUserInterfaceItemIdentifier("menu.goto_last_tab")
        tabMenu.addItem(lastTabItem)

        let tabMenuItem = NSMenuItem()
        tabMenuItem.submenu = tabMenu
        mainMenu.addItem(tabMenuItem)

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

        windowMenu.addItem(.separator())

        for i in 1...8 {
            let item = NSMenuItem(title: "Workspace \(i)", action: #selector(gotoWorkspaceByTag(_:)), keyEquivalent: "\(i)")
            item.keyEquivalentModifierMask = [.command, .shift]
            item.tag = i
            item.identifier = NSUserInterfaceItemIdentifier("menu.goto_workspace_\(i)")
            windowMenu.addItem(item)
        }
        let lastWSItem = NSMenuItem(title: "Last Workspace", action: #selector(gotoLastWorkspace), keyEquivalent: "9")
        lastWSItem.keyEquivalentModifierMask = [.command, .shift]
        lastWSItem.identifier = NSUserInterfaceItemIdentifier("menu.goto_last_workspace")
        windowMenu.addItem(lastWSItem)

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

    private func renameTab(id: UUID, to title: String) {
        guard let workspace = workspaceManager?.activeWorkspace else { return }
        guard let index = workspace.tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard workspace.tabs[index].title != trimmed else { return }
        guard workspace.renameTab(at: index, to: trimmed) else { return }
        updateTabBar()
        persistence?.markDirty()
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
            contentTopToTitlebar?.isActive = false
            contentTopToTabBar?.isActive = true
        } else {
            contentTopToTabBar?.isActive = false
            contentTopToTitlebar?.isActive = true
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

    // MARK: - Menu Item Validation (HIG §1.3)

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let hasPanes = (contentAreaView?.paneCount ?? 0) > 0
        let hasMultiplePanes = (contentAreaView?.paneCount ?? 0) > 1
        let tabCount = workspaceManager?.activeWorkspace?.tabs.count ?? 0
        let workspaceCount = workspaceManager?.workspaces.count ?? 0

        switch menuItem.action {
        case #selector(closePaneAction):
            return hasPanes
        case #selector(splitRightAction), #selector(splitDownAction):
            return hasPanes
        case #selector(nextPane), #selector(previousPane):
            return hasMultiplePanes
        case #selector(equalizeSplitsAction), #selector(toggleSplitZoom):
            return hasMultiplePanes
        case #selector(navigateLeft), #selector(navigateRight),
             #selector(navigateUp), #selector(navigateDown):
            return hasMultiplePanes
        case #selector(nextWorkspace), #selector(previousWorkspace):
            return workspaceCount > 1
        case #selector(nextTab), #selector(previousTab):
            return tabCount > 1
        default:
            return true
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

    private func targetSidebarWidth(for mode: SidebarMode) -> CGFloat {
        switch mode {
        case .expanded:
            SidebarPreferences.sidebarWidth
        case .collapsed:
            DesignTokens.Layout.sidebarCollapsedWidth
        case .hidden:
            0
        }
    }

    private func finalizeSidebarPresentation(for mode: SidebarMode) {
        sidebarWidthConstraint?.constant = targetSidebarWidth(for: mode)
        switch mode {
        case .hidden:
            sidebarHostView?.isHidden = true
            sidebarHostView?.alphaValue = 0
        case .expanded, .collapsed:
            sidebarHostView?.isHidden = false
            sidebarHostView?.alphaValue = 1
            setSidebarContentVisibility(for: mode)
        }
        syncSidebarResizerPresentation(for: mode)
    }

    private func syncSidebarResizerPresentation(for mode: SidebarMode) {
        let shouldShow = mode == .expanded
        sidebarResizerView?.isHidden = !shouldShow
        sidebarResizerView?.alphaValue = shouldShow ? 1 : 0
    }

    private func setSidebarContentVisibility(for mode: SidebarMode) {
        switch mode {
        case .expanded:
            sidebarContentView?.isHidden = false
            sidebarContentView?.alphaValue = 1
            collapsedRailHostView?.alphaValue = 0
            collapsedRailHostView?.isHidden = true
        case .collapsed:
            collapsedRailHostView?.isHidden = false
            collapsedRailHostView?.alphaValue = 1
            sidebarContentView?.alphaValue = 0
            sidebarContentView?.isHidden = true
        case .hidden:
            break
        }
    }

    private func visibleSidebarMode() -> SidebarMode {
        guard let sidebarHostView,
              let sidebarWidthConstraint,
              sidebarHostView.isHidden == false,
              sidebarHostView.alphaValue > 0.01,
              sidebarWidthConstraint.constant > 0.5 else {
            return .hidden
        }

        let contentAlpha = if let sidebarContentView, sidebarContentView.isHidden == false {
            sidebarContentView.alphaValue
        } else {
            CGFloat.zero
        }
        let railAlpha = if let collapsedRailHostView, collapsedRailHostView.isHidden == false {
            collapsedRailHostView.alphaValue
        } else {
            CGFloat.zero
        }

        return railAlpha > contentAlpha ? .collapsed : .expanded
    }

    private final class SidebarAnimationCallbackBox: @unchecked Sendable {
        let run: () -> Void

        init(_ run: @escaping () -> Void) {
            self.run = run
        }
    }

    private func animateSidebarWidth(
        to width: CGFloat,
        hostAlpha: CGFloat,
        animated: Bool,
        completion: @escaping () -> Void
    ) {
        guard animated, ChromeMotion.duration(for: .sidebar) > 0 else {
            sidebarWidthConstraint?.constant = width
            sidebarHostView?.alphaValue = hostAlpha
            completion()
            return
        }

        let completionBox = SidebarAnimationCallbackBox(completion)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ChromeMotion.duration(for: .sidebar)
            context.timingFunction = ChromeMotion.timingFunction(for: .sidebar)
            context.allowsImplicitAnimation = true
            sidebarWidthConstraint?.animator().constant = width
            sidebarHostView?.animator().alphaValue = hostAlpha
        }, completionHandler: {
            completionBox.run()
        })
    }

    private func animateSidebarContentSwapIfNeeded(
        to mode: SidebarMode,
        animated: Bool,
        completion: (() -> Void)? = nil
    ) {
        guard mode != .hidden,
              let sidebarContentView,
              let collapsedRailHostView else {
            completion?()
            return
        }

        let showExpandedContent = mode == .expanded
        let targetContentAlpha: CGFloat = showExpandedContent ? 1 : 0
        let targetRailAlpha: CGFloat = showExpandedContent ? 0 : 1

        sidebarContentView.isHidden = false
        collapsedRailHostView.isHidden = false

        guard animated, ChromeMotion.duration(for: .disclosure) > 0 else {
            if showExpandedContent {
                sidebarContentView.isHidden = false
                sidebarContentView.alphaValue = 1
                collapsedRailHostView.alphaValue = 0
                collapsedRailHostView.isHidden = true
            } else {
                collapsedRailHostView.isHidden = false
                collapsedRailHostView.alphaValue = 1
                sidebarContentView.alphaValue = 0
                sidebarContentView.isHidden = true
            }
            completion?()
            return
        }

        if sidebarContentView.alphaValue == collapsedRailHostView.alphaValue {
            sidebarContentView.alphaValue = showExpandedContent ? 0 : 1
            collapsedRailHostView.alphaValue = showExpandedContent ? 1 : 0
        }

        let finalizeBox = SidebarAnimationCallbackBox { [weak self] in
            self?.setSidebarContentVisibility(for: mode)
            completion?()
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = ChromeMotion.duration(for: .disclosure)
            context.timingFunction = ChromeMotion.timingFunction(for: .disclosure)
            context.allowsImplicitAnimation = true
            sidebarContentView.animator().alphaValue = targetContentAlpha
            collapsedRailHostView.animator().alphaValue = targetRailAlpha
        }, completionHandler: {
            finalizeBox.run()
        })
    }

    private func animateSidebarModeTransition(
        from fromMode: SidebarMode,
        to toMode: SidebarMode,
        animated: Bool,
        generation: UInt64,
        completion: @escaping () -> Void
    ) {
        guard animated else {
            completion()
            return
        }

        let guardCurrentGeneration = { [weak self] in
            self?.sidebarTransitionGeneration == generation
        }

        switch (fromMode, toMode) {
        case (.expanded, .collapsed):
            sidebarHostView?.isHidden = false
            sidebarHostView?.alphaValue = 1
            sidebarWidthConstraint?.constant = targetSidebarWidth(for: .expanded)
            animateSidebarContentSwapIfNeeded(to: .collapsed, animated: true) { [weak self] in
                guard let self else {
                    completion()
                    return
                }
                guard guardCurrentGeneration() else {
                    completion()
                    return
                }
                self.animateSidebarWidth(
                    to: self.targetSidebarWidth(for: .collapsed),
                    hostAlpha: 1,
                    animated: true,
                    completion: completion
                )
            }

        case (.collapsed, .expanded):
            sidebarHostView?.isHidden = false
            sidebarHostView?.alphaValue = 1
            setSidebarContentVisibility(for: .collapsed)
            animateSidebarWidth(
                to: targetSidebarWidth(for: .expanded),
                hostAlpha: 1,
                animated: true
            ) { [weak self] in
                guard let self else {
                    completion()
                    return
                }
                guard guardCurrentGeneration() else {
                    completion()
                    return
                }
                self.animateSidebarContentSwapIfNeeded(to: .expanded, animated: true, completion: completion)
            }

        case (_, .hidden):
            if fromMode != .hidden {
                setSidebarContentVisibility(for: fromMode)
            }
            sidebarHostView?.isHidden = false
            sidebarHostView?.alphaValue = 1
            animateSidebarWidth(to: 0, hostAlpha: 0, animated: true, completion: completion)

        case (.hidden, .expanded), (.hidden, .collapsed):
            sidebarHostView?.isHidden = false
            sidebarHostView?.alphaValue = 0
            setSidebarContentVisibility(for: toMode)
            animateSidebarWidth(
                to: targetSidebarWidth(for: toMode),
                hostAlpha: 1,
                animated: true,
                completion: completion
            )

        default:
            sidebarHostView?.isHidden = false
            sidebarHostView?.alphaValue = 1
            setSidebarContentVisibility(for: toMode)
            animateSidebarWidth(
                to: targetSidebarWidth(for: toMode),
                hostAlpha: toMode == .hidden ? 0 : 1,
                animated: true,
                completion: completion
            )
        }
    }

    private func applySidebarMode(animated: Bool) {
        let fromMode = visibleSidebarMode()
        let toMode = currentSidebarMode
        let shouldAnimate = animated && ChromeMotion.duration(for: .sidebar) > 0
        sidebarTransitionGeneration &+= 1
        let transitionGeneration = sidebarTransitionGeneration
        isSidebarVisible = toMode != .hidden
        syncSidebarResizerPresentation(for: toMode)

        let signpost = PerformanceDiagnostics.shared.beginInterval("sidebar.toggle")
        ChromeTransitionCoordinator.shared.begin(.sidebar)

        let completeTransition = { [weak self] in
            guard let self else { return }
            ChromeTransitionCoordinator.shared.end(.sidebar)
            PerformanceDiagnostics.shared.endInterval("sidebar.toggle", signpost)
            guard self.sidebarTransitionGeneration == transitionGeneration else { return }
            self.finalizeSidebarPresentation(for: toMode)
            self.renderedSidebarMode = toMode
        }

        if shouldAnimate {
            animateSidebarModeTransition(
                from: fromMode,
                to: toMode,
                animated: true,
                generation: transitionGeneration,
                completion: completeTransition
            )
        } else {
            finalizeSidebarPresentation(for: toMode)
            renderedSidebarMode = toMode
            ChromeTransitionCoordinator.shared.end(.sidebar)
            PerformanceDiagnostics.shared.endInterval("sidebar.toggle", signpost)
        }

        updateWindowMinWidth()
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
        if let popover = branchPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let workspace = workspaceManager?.activeWorkspace else {
            Log.general.warning("showBranchPicker: skipped — no active workspace")
            return
        }
        guard let titlebarStatusView else { return }

        let currentBranch = workspace.gitBranch
        let popover = NSPopover()
        configureToolbarAttachmentPopover(
            popover,
            contentSize: NSSize(width: 300, height: 340)
        ) {
            BranchPickerPopover(
                branches: currentBranch.map { [$0] } ?? [],
                currentBranch: currentBranch,
                onSelect: { [weak self, weak popover] branch in
                    popover?.close()
                    self?.switchBranch(branch)
                },
                onDismiss: { [weak popover] in popover?.close() }
            )
        }
        popover.show(
            relativeTo: titlebarStatusView.branchButtonFrame,
            of: titlebarStatusView,
            preferredEdge: .minY
        )
        branchPopover = popover
        NotificationCenter.default.addObserver(
            forName: NSPopover.willCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.branchPopover = nil }
        }

        // Load full branch list in background and update
        Task { @MainActor [weak self, weak popover] in
            guard let self, let popover else { return }
            do {
                guard popover === self.branchPopover else { return }
                guard let workspaceManager = self.workspaceManager else { return }
                let bus = try await resolveTitlebarGitActionCommandBus(
                    workspaceManager: workspaceManager
                )
                let branches: [String] = try await bus.call(method: "git.list_branches")
                guard popover === self.branchPopover, popover.isShown else { return }
                popover.contentViewController = NSHostingController(
                    rootView: BranchPickerPopover(
                        branches: branches,
                        currentBranch: self.workspaceManager?.activeWorkspace?.gitBranch,
                        onSelect: { [weak self, weak popover] branch in
                            popover?.close()
                            self?.switchBranch(branch)
                        },
                        onDismiss: { [weak popover] in popover?.close() }
                    ).environment(GhosttyThemeProvider.shared)
                )
            } catch {
                Log.general.warning("Branch list load failed: \(error.localizedDescription)")
            }
        }
    }

    private func switchBranch(_ branch: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let workspaceManager = self.workspaceManager else {
                    throw WorkspaceActionError.workspaceUnavailable
                }
                let bus = try await resolveTitlebarGitActionCommandBus(
                    workspaceManager: workspaceManager
                )
                guard let projectPath = workspaceManager.activeWorkspace?.projectPath else {
                    throw WorkspaceActionError.workspaceUnavailable
                }
                let launch = try await self.createWorkspaceFromBranch(
                    path: projectPath,
                    branchName: branch,
                    createNew: false,
                    commandBus: bus
                )
                let resolvedBranch = launch.branch ?? branch
                guard self.openLocalWorkspace(
                    path: launch.projectPath,
                    checkoutPath: launch.checkoutPath,
                    terminalMode: workspaceManager.activeWorkspace?.terminalMode ?? .persistent,
                    workspaceName: launch.workspaceName,
                    launchSource: launch.launchSource,
                    workingDirectory: launch.workingDirectory,
                    taskID: launch.taskID
                ) != nil else {
                    throw WorkspaceActionError.workspaceUnavailable
                }
                ToastManager.shared.show(
                    "Switched to \(resolvedBranch)",
                    icon: "arrow.triangle.branch",
                    style: .success
                )
            } catch {
                ToastManager.shared.show(
                    "Switch failed: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle",
                    style: .error
                )
            }
        }
    }

    private func observeActiveWorkspaceForTitlebar() {
        titlebarWorkspaceObservationGeneration &+= 1
        let generation = titlebarWorkspaceObservationGeneration
        observeActiveWorkspaceForTitlebar(generation: generation)
    }

    private func observeActiveWorkspaceForTitlebar(generation: UInt64) {
        withObservationTracking {
            let workspace = workspaceManager?.activeWorkspace
            _ = workspace?.projectPath
            _ = workspace?.gitBranch
            _ = workspace?.activeAgents
            _ = workspace?.linkedPRNumber
            _ = workspace?.linkedPRURL
            _ = workspace?.attentionReason
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.titlebarWorkspaceObservationGeneration == generation else { return }
                self.refreshTitlebarChromeState()
                self.observeActiveWorkspaceForTitlebar(generation: generation)
            }
        }
    }

    private func refreshTitlebarChromeState() {
        let workspace = workspaceManager?.activeWorkspace
        let hasProject = workspace?.projectPath != nil
        let controlAvailability = resolveTitlebarStatusControlAvailability(
            hasProject: hasProject,
            hasGitBranch: workspace?.gitBranch != nil,
            hasSessionStore: sessionStore != nil
        )

        titlebarStatusView?.updateBranch(workspace?.gitBranch)
        titlebarStatusView?.updateAgents(workspace?.activeAgents ?? 0)
        titlebarStatusView?.updatePR(number: workspace?.linkedPRNumber, url: workspace?.linkedPRURL)
        titlebarStatusView?.updateAttentionDot(visible: workspace?.attentionReason != nil)
        titlebarStatusView?.updateBranchEnabled(controlAvailability.branchEnabled)
        titlebarStatusView?.updateSessionsEnabled(controlAvailability.sessionsEnabled)

        titlebarOpenBtn?.isEnabled = hasProject
        titlebarCommitBtn?.isEnabled = hasProject
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
        let shouldAnimate = animated && ChromeMotion.duration(for: .rightInspector) > 0
        let targetWidth = shouldPresent ? rightInspectorStoredWidth : 0
        let hostView = rightInspectorHostView
        let footerView = rightInspectorFooterView
        let resizerView = rightInspectorResizerView
        if shouldPresent {
            let hostWasHidden = hostView?.isHidden == true
            let footerWasHidden = footerView?.isHidden == true
            let resizerWasHidden = resizerView?.isHidden == true
            hostView?.isHidden = false
            footerView?.isHidden = false
            resizerView?.isHidden = false
            if hostWasHidden { hostView?.alphaValue = 0 }
            if footerWasHidden { footerView?.alphaValue = 0 }
            if resizerWasHidden { resizerView?.alphaValue = 0 }
        }
        let updates = { [weak self] in
            self?.rightInspectorWidthConstraint?.animator().constant = targetWidth
            hostView?.animator().alphaValue = shouldPresent ? 1 : 0
            footerView?.animator().alphaValue = shouldPresent ? 1 : 0
            resizerView?.animator().alphaValue = shouldPresent ? 1 : 0
        }
        if shouldAnimate {
            let signpost = PerformanceDiagnostics.shared.beginInterval("right_inspector.toggle")
            ChromeTransitionCoordinator.shared.begin(.rightInspector)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = ChromeMotion.duration(for: .rightInspector)
                ctx.timingFunction = ChromeMotion.timingFunction(for: .rightInspector)
                ctx.allowsImplicitAnimation = true
                updates()
            }, completionHandler: {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    ChromeTransitionCoordinator.shared.end(.rightInspector)
                    PerformanceDiagnostics.shared.endInterval("right_inspector.toggle", signpost)
                    guard self.rightInspectorTransitionGeneration == transitionGeneration else { return }
                    if !self.isRightInspectorPresented {
                        hostView?.isHidden = true
                        footerView?.isHidden = true
                        resizerView?.isHidden = true
                    } else {
                        hostView?.alphaValue = 1
                        footerView?.alphaValue = 1
                        resizerView?.alphaValue = 1
                    }
                }
            })
        } else {
            rightInspectorWidthConstraint?.constant = targetWidth
            if !shouldPresent {
                hostView?.isHidden = true
                footerView?.isHidden = true
                resizerView?.isHidden = true
                hostView?.alphaValue = 0
                footerView?.alphaValue = 0
                resizerView?.alphaValue = 0
            } else {
                hostView?.isHidden = false
                footerView?.isHidden = false
                resizerView?.isHidden = false
                hostView?.alphaValue = 1
                footerView?.alphaValue = 1
                resizerView?.alphaValue = 1
            }
        }
        updateWindowMinWidth()
    }

    private func adjustRightInspectorWidth(by delta: CGFloat) {
        rightInspectorStoredWidth = min(
            max(rightInspectorStoredWidth - delta, DesignTokens.Layout.rightInspectorMinWidth),
            DesignTokens.Layout.rightInspectorMaxWidth
        )
        guard isRightInspectorPresented else { return }
        rightInspectorWidthConstraint?.constant = rightInspectorStoredWidth
        updateWindowMinWidth()
        persistence?.markDirty()
    }

    private func adjustSidebarWidth(by delta: CGFloat) {
        guard currentSidebarMode == .expanded else { return }

        let width = min(
            max(SidebarPreferences.sidebarWidth + delta, DesignTokens.Layout.sidebarMinWidth),
            DesignTokens.Layout.sidebarMaxWidth
        )
        SidebarPreferences.sidebarWidth = width
        sidebarWidthConstraint?.constant = width
        updateWindowMinWidth()
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
        let requiredWidth = leftWidth + minContent + rightWidth
        window?.minSize.width = requiredWidth
        contentMinWidthConstraint?.constant = minContent

        // Auto-expand if narrower than the new minimum.
        guard let win = window, win.frame.width < requiredWidth else { return }
        var newFrame = win.frame
        let deficit = requiredWidth - newFrame.width
        newFrame.size.width = requiredWidth
        newFrame.origin.x -= deficit
        if let visible = (win.screen ?? NSScreen.main)?.visibleFrame {
            newFrame.origin.x = max(newFrame.origin.x, visible.minX)
            if newFrame.maxX > visible.maxX { newFrame.origin.x = visible.maxX - newFrame.width }
            if newFrame.width > visible.width { newFrame.size.width = visible.width; newFrame.origin.x = visible.minX }
        }
        win.setFrame(newFrame, display: true, animate: true)
    }

    /// Startup safety net: if the window frame is below minSize, expand it.
    private func enforceMinimumWindowFrame() {
        guard let win = window else { return }
        let minW = win.minSize.width
        let minH = win.minSize.height
        guard win.frame.width < minW || win.frame.height < minH else { return }
        var frame = win.frame
        if frame.width < minW {
            let deficit = minW - frame.width
            frame.size.width = minW
            frame.origin.x -= deficit
        }
        if frame.height < minH {
            let deficit = minH - frame.height
            frame.size.height = minH
            frame.origin.y -= deficit
        }
        if let visible = (win.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = max(frame.origin.x, visible.minX)
            if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
            if frame.width > visible.width { frame.size.width = visible.width; frame.origin.x = visible.minX }
            frame.origin.y = max(frame.origin.y, visible.minY)
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.height > visible.height { frame.size.height = visible.height; frame.origin.y = visible.minY }
        }
        win.setFrame(frame, display: true)
    }

    @objc private func showCommandPalette() { commandPalette?.show() }

    @objc private func showFileQuickOpen() {
        commandPalette?.show(prefix: ":")
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

    @objc private func gotoWorkspaceByTag(_ sender: NSMenuItem) {
        guard let mgr = workspaceManager,
              sender.tag >= 1, sender.tag <= mgr.workspaces.count else { return }
        mgr.switchToWorkspace(mgr.workspaces[sender.tag - 1].id)
    }

    @objc private func gotoLastWorkspace() {
        guard let mgr = workspaceManager, let last = mgr.workspaces.last else { return }
        mgr.switchToWorkspace(last.id)
    }

    @objc private func nextTab() {
        guard let workspace = workspaceManager?.activeWorkspace,
              workspace.tabs.count > 1 else { return }
        let next = (workspace.activeTabIndex + 1) % workspace.tabs.count
        switchToTab(next)
    }

    @objc private func previousTab() {
        guard let workspace = workspaceManager?.activeWorkspace,
              workspace.tabs.count > 1 else { return }
        let prev = (workspace.activeTabIndex - 1 + workspace.tabs.count) % workspace.tabs.count
        switchToTab(prev)
    }

    @objc private func gotoTabByTag(_ sender: NSMenuItem) {
        guard let workspace = workspaceManager?.activeWorkspace,
              sender.tag >= 1, sender.tag <= workspace.tabs.count else { return }
        switchToTab(sender.tag - 1)
    }

    @objc private func gotoLastTab() {
        guard let workspace = workspaceManager?.activeWorkspace,
              !workspace.tabs.isEmpty else { return }
        switchToTab(workspace.tabs.count - 1)
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
            CommandItem(id: "tab.next", title: "Next Tab", category: "pane", shortcut: "Ctrl+Tab", description: "Switch to the next tab") { [weak self] in
                self?.nextTab()
            },
            CommandItem(id: "tab.prev", title: "Previous Tab", category: "pane", shortcut: "Ctrl+Shift+Tab", description: "Switch to the previous tab") { [weak self] in
                self?.previousTab()
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

    private func openWorkspace(context: WorkspaceOpenerLaunchContext = .generic) {
        presentOpenWorkspacePanel(context: context)
    }

    private func presentOpenWorkspacePanel(context: WorkspaceOpenerLaunchContext = .generic) {
        let vm = WorkspaceOpenerViewModel()
        if let wm = workspaceManager {
            vm.loadProjects(from: wm, preferredProjectPath: context.preferredProjectPath)
        }
        openerViewModel = vm
        let initialPanelSize = vm.preferredPanelSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: initialPanelSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "New Workspace"
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.level = .modalPanel
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentMinSize = WorkspaceOpenerPanelLayout.minimumSize
        openerPanel = panel

        guard let bus = commandBus ?? CommandBus.shared else { return }
        let openerView = WorkspaceOpenerView(
            viewModel: vm,
            commandBus: bus,
            onPreferredSizeChange: { [weak self, weak panel] size in
                guard let self, let panel else { return }
                DispatchQueue.main.async { [weak self, weak panel] in
                    guard let self, let panel else { return }
                    if vm.selectedTab == .prompt,
                       let hostingView = panel.contentView as? NSHostingView<AnyView> {
                        self.resizeOpenerPanel(panel, hostingView: hostingView, to: size)
                    } else {
                        self.resizeOpenerPanel(panel, to: size)
                    }
                }
            },
            onSubmit: { [weak self] viewModel in
                self?.handleOpenerSubmit(viewModel)
            },
            onCancel: { [weak self] in
                self?.closeOpenerPanel()
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

        let hostingView = NSHostingView(rootView: AnyView(openerView))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.setContentSize(initialPanelSize)
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        // Trigger initial data load if a project is already selected
        if vm.selectedProjectPath != nil {
            vm.onProjectChanged(using: bus)
        }
    }

    private func closeOpenerPanel() {
        let panel = openerPanel
        openerViewModel = nil
        openerPanel = nil
        panel?.close()
    }

    private func resizeOpenerPanel(_ panel: NSPanel, to contentSize: CGSize) {
        let maxContentHeight = maximumOpenerContentHeight(for: panel)
        let targetSize = CGSize(
            width: max(contentSize.width, WorkspaceOpenerPanelLayout.minimumSize.width),
            height: min(
                max(contentSize.height, WorkspaceOpenerPanelLayout.minimumSize.height),
                maxContentHeight
            )
        )
        animateOpenerPanel(panel, to: targetSize)
    }

    private func resizeOpenerPanel(
        _ panel: NSPanel,
        hostingView: NSHostingView<AnyView>,
        to contentSize: CGSize
    ) {
        let targetWidth = max(contentSize.width, WorkspaceOpenerPanelLayout.minimumSize.width)
        let measuredHeight = measureOpenerHeight(hostingView, width: targetWidth)
        let unclampedHeight = max(
            contentSize.height,
            measuredHeight,
            WorkspaceOpenerPanelLayout.minimumSize.height
        )
        let maxContentHeight = maximumOpenerContentHeight(for: panel)
        let targetSize = CGSize(
            width: targetWidth,
            height: min(unclampedHeight, maxContentHeight)
        )
        animateOpenerPanel(panel, to: targetSize)
    }

    private func animateOpenerPanel(_ panel: NSPanel, to targetSize: CGSize) {
        guard panel.contentRect(forFrameRect: panel.frame).size != targetSize else { return }

        let currentFrame = panel.frame
        var nextFrame = panel.frameRect(forContentRect: NSRect(origin: .zero, size: targetSize))
        nextFrame.origin.x = currentFrame.midX - (nextFrame.width / 2)
        nextFrame.origin.y = currentFrame.midY - (nextFrame.height / 2)
        nextFrame = clampOpenerFrame(nextFrame, for: panel)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(nextFrame, display: true)
        }
    }

    private func measureOpenerHeight(_ hostingView: NSHostingView<AnyView>, width: CGFloat) -> CGFloat {
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1))
        hostingView.layoutSubtreeIfNeeded()
        return hostingView.fittingSize.height
    }

    private func maximumOpenerContentHeight(for panel: NSPanel) -> CGFloat {
        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let visibleFrame else { return 640 }
        return max(
            WorkspaceOpenerPanelLayout.minimumSize.height,
            visibleFrame.height - 80
        )
    }

    private func clampOpenerFrame(_ frame: NSRect, for panel: NSPanel) -> NSRect {
        guard let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
            return frame
        }

        var clamped = frame
        let horizontalMargin: CGFloat = 20
        let verticalMargin: CGFloat = 20
        clamped.origin.x = min(
            max(clamped.origin.x, visibleFrame.minX + horizontalMargin),
            visibleFrame.maxX - clamped.width - horizontalMargin
        )
        clamped.origin.y = min(
            max(clamped.origin.y, visibleFrame.minY + verticalMargin),
            visibleFrame.maxY - clamped.height - verticalMargin
        )
        return clamped
    }

    private func handleOpenerSubmit(_ viewModel: WorkspaceOpenerViewModel) {
        let terminalMode = viewModel.terminalMode

        switch viewModel.selectedTab {
        case .prompt:
            closeOpenerPanel()
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
            guard let path = viewModel.selectedProjectPath,
                  let issueNumber = viewModel.selectedIssueNumber,
                  let bus = commandBus else { return }
            viewModel.isLoading = true
            viewModel.errorMessage = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { viewModel.isLoading = false }
                do {
                    let launch = try await self.createWorkspaceFromIssue(
                        path: path,
                        issueNumber: issueNumber,
                        createLinkedTaskWorktree: viewModel.createLinkedTaskWorktree,
                        commandBus: bus
                    )
                    guard self.openLocalWorkspace(
                        path: launch.projectPath,
                        checkoutPath: launch.checkoutPath,
                        terminalMode: terminalMode,
                        workspaceName: launch.workspaceName,
                        launchSource: launch.launchSource,
                        workingDirectory: launch.workingDirectory,
                        taskID: launch.taskID
                    ) != nil else { return }
                    self.closeOpenerPanel()
                } catch {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            return

        case .pullRequests:
            guard let path = viewModel.selectedProjectPath,
                  let prNumber = viewModel.selectedPRNumber,
                  let bus = commandBus else { return }
            viewModel.isLoading = true
            viewModel.errorMessage = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { viewModel.isLoading = false }
                do {
                    let launch = try await self.createWorkspaceFromPullRequest(
                        path: path,
                        prNumber: prNumber,
                        createLinkedTaskWorktree: viewModel.createLinkedTaskWorktree,
                        commandBus: bus
                    )
                    guard self.openLocalWorkspace(
                        path: launch.projectPath,
                        checkoutPath: launch.checkoutPath,
                        terminalMode: terminalMode,
                        workspaceName: launch.workspaceName,
                        launchSource: launch.launchSource,
                        workingDirectory: launch.workingDirectory,
                        taskID: launch.taskID
                    ) != nil else { return }
                    self.closeOpenerPanel()
                } catch {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            return

        case .branches:
            guard let path = viewModel.selectedProjectPath,
                  let bus = commandBus else { return }
            let branchName = viewModel.isCreatingNewBranch
                ? viewModel.trimmedNewBranchName
                : viewModel.selectedBranchName
            guard let branchName, !branchName.isEmpty else { return }
            viewModel.isLoading = true
            viewModel.errorMessage = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { viewModel.isLoading = false }
                do {
                    let launch = try await self.createWorkspaceFromBranch(
                        path: path,
                        branchName: branchName,
                        createNew: viewModel.isCreatingNewBranch,
                        commandBus: bus
                    )
                    guard self.openLocalWorkspace(
                        path: launch.projectPath,
                        checkoutPath: launch.checkoutPath,
                        terminalMode: terminalMode,
                        workspaceName: launch.workspaceName,
                        launchSource: launch.launchSource,
                        workingDirectory: launch.workingDirectory,
                        taskID: launch.taskID
                    ) != nil else { return }
                    self.closeOpenerPanel()
                } catch {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
            return
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
        // Remote workspaces no longer require sshfs — file access goes through
        // Rust SSH commands. Always return true.
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
            alert.informativeText = "Select an SSH preset and enter the remote project path."

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
            let accessoryWidth: CGFloat = 360
            popup.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
            pathField.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
            accessory.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
            accessory.layoutSubtreeIfNeeded()
            accessory.frame.size = NSSize(width: accessoryWidth, height: accessory.fittingSize.height)
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
        alert.informativeText = "Open a remote workspace for this Tailscale device."

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
        let accessoryWidth: CGFloat = 360
        hostValue.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
        userField.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
        portField.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
        pathField.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
        accessory.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
        accessory.layoutSubtreeIfNeeded()
        accessory.frame.size = NSSize(width: accessoryWidth, height: accessory.fittingSize.height)
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

    private func createWorkspaceFromIssue(
        path: String,
        issueNumber: Int64,
        createLinkedTaskWorktree: Bool,
        commandBus: any CommandCalling
    ) async throws -> WorkspaceOpenerLaunchResult {
        let params = WorkspaceOpenerIssueLaunchParams(
            path: path,
            issueNumber: issueNumber,
            createLinkedTaskWorktree: createLinkedTaskWorktree
        )

        for _ in 0..<3 {
            do {
                return try await commandBus.call(
                    method: "workspace_opener.create_from_issue",
                    params: params
                )
            } catch {
                try await recoverWorkspaceOpenerProjectIfNeeded(
                    path: path,
                    workspaceName: "Issue #\(issueNumber)",
                    commandBus: commandBus,
                    error: error
                )
            }
        }

        throw NSError(
            domain: "WorkspaceOpener",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Issue workspace launch retries were exhausted."]
        )
    }

    private func createWorkspaceFromPullRequest(
        path: String,
        prNumber: Int64,
        createLinkedTaskWorktree: Bool,
        commandBus: any CommandCalling
    ) async throws -> WorkspaceOpenerLaunchResult {
        let params = WorkspaceOpenerPullRequestLaunchParams(
            path: path,
            prNumber: prNumber,
            createLinkedTaskWorktree: createLinkedTaskWorktree
        )

        for _ in 0..<3 {
            do {
                return try await commandBus.call(
                    method: "workspace_opener.create_from_pr",
                    params: params
                )
            } catch {
                try await recoverWorkspaceOpenerProjectIfNeeded(
                    path: path,
                    workspaceName: "PR #\(prNumber)",
                    commandBus: commandBus,
                    error: error
                )
            }
        }

        throw NSError(
            domain: "WorkspaceOpener",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Pull request workspace launch retries were exhausted."]
        )
    }

    private func createWorkspaceFromBranch(
        path: String,
        branchName: String,
        createNew: Bool,
        commandBus: any CommandCalling
    ) async throws -> WorkspaceOpenerLaunchResult {
        try await commandBus.call(
            method: "workspace_opener.create_from_branch",
            params: WorkspaceOpenerBranchLaunchParams(
                path: path,
                branchName: branchName,
                createNew: createNew
            )
        )
    }

    private func recoverWorkspaceOpenerProjectIfNeeded(
        path: String,
        workspaceName: String,
        commandBus: any CommandCalling,
        error: Error
    ) async throws {
        guard case .backendError(_, let message) = error as? PnevmaError else {
            throw error
        }

        switch message {
        case "workspace_not_initialized":
            guard await promptToInitializeWorkspace(named: workspaceName, path: path) else {
                throw NSError(
                    domain: "WorkspaceOpener",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Workspace initialization was canceled."]
                )
            }
            let trimmedName = URL(fileURLWithPath: path)
                .lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let _: InitializeProjectScaffoldResult = try await commandBus.call(
                method: "project.initialize_scaffold",
                params: WorkspaceOpenerInitializeParams(
                    path: path,
                    projectName: trimmedName.isEmpty ? nil : trimmedName,
                    projectBrief: nil,
                    defaultProvider: nil
                )
            )
        case "workspace_not_trusted", "workspace_config_changed":
            let _: OkResponse = try await commandBus.call(
                method: "project.trust",
                params: WorkspaceOpenerTrustParams(path: path)
            )
        default:
            throw error
        }
    }

    private func promptToInitializeWorkspace(named workspaceName: String, path: String) async -> Bool {
        let displayName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = displayName.isEmpty
            ? URL(fileURLWithPath: path).lastPathComponent
            : displayName
        let alert = NSAlert()
        alert.messageText = "Initialize Project Scaffold?"
        alert.informativeText = "\(subject) is missing pnevma.toml and the .pnevma support directory. Initialize them now to open this workspace?"
        alert.addButton(withTitle: "Initialize")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
    private func openLocalWorkspace(
        path: String,
        checkoutPath: String? = nil,
        terminalMode: WorkspaceTerminalMode,
        workspaceName: String? = nil,
        launchSource: WorkspaceLaunchSource? = nil,
        workingDirectory: String? = nil,
        taskID: String? = nil
    ) -> Workspace? {
        guard let workspaceManager else {
            ToastManager.shared.show(
                "Workspace manager unavailable",
                icon: "exclamationmark.triangle",
                style: .error
            )
            return nil
        }

        let trimmedWorkspaceName = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (trimmedWorkspaceName?.isEmpty == false)
            ? trimmedWorkspaceName!
            : URL(fileURLWithPath: path).lastPathComponent
        let workspace = workspaceManager.createLocalProjectWorkspace(
            name: name,
            projectPath: path,
            checkoutPath: checkoutPath,
            terminalMode: terminalMode,
            launchSource: launchSource,
            initialWorkingDirectory: workingDirectory,
            initialTaskID: taskID
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
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.isReleasedWhenClosed = false
        win.title = ""
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.toolbarStyle = .unifiedCompact
        win.isMovableByWindowBackground = true
        win.minSize = NSSize(width: 840, height: 560)
        let contentContainer = NSView(frame: NSRect(origin: .zero, size: NSSize(width: 960, height: 680)))
        contentContainer.wantsLayer = true
        contentContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentContainer.setAccessibilityIdentifier("settings.window.content")
        let hostingView = NSHostingView(
            rootView: SettingsView()
                .environment(GhosttyThemeProvider.shared)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        win.contentView = contentContainer
        win.setContentSize(NSSize(width: 960, height: 680))
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
            existing.updateWorkspaceProjectPath(workspace.activeProjectPath)
            return existing
        }

        let session = BrowserWorkspaceSession(
            workspaceID: workspace.id,
            workspaceProjectPath: workspace.activeProjectPath,
            restoredURL: workspace.browserLastURL.flatMap(URL.init(string:)),
            restoredDrawerHeight: DrawerSizing.storedHeight().map(Double.init),
            onURLChanged: { [weak self, weak workspace] url in
                guard let workspace else { return }
                workspace.browserLastURL = url?.absoluteString
                self?.persistence?.markDirty()
            },
            onDrawerHeightChanged: { [weak self] _ in
                self?.syncToolDrawerPointerCapture()
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
            self.refreshBottomDrawerBrowserSession()
        }
    }

    private func refreshBottomDrawerBrowserSession() {
        if toolDrawerContentModel.activeToolID == "browser" {
            toolDrawerContentModel.activeBrowserSession = workspaceManager?.activeWorkspace.map {
                browserSession(for: $0)
            }
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

        if toolDrawerChromeState.isPresented, toolDrawerContentModel.activeToolID == "browser" {
            closeBrowserDrawer()
        } else {
            openToolInDrawer("browser")
            persistence?.markDirty()
        }
    }

    private func closeBrowserDrawer() {
        guard toolDrawerChromeState.isPresented,
              toolDrawerContentModel.activeToolID == "browser" else { return }
        closeToolDrawer()
        persistence?.markDirty()
    }

    private func focusBrowserOmnibar() {
        if focusExistingBrowserPaneIfPresent() {
            activeBrowserSession()?.requestOmnibarFocus()
            return
        }

        openToolInDrawer("browser")
        activeBrowserSession()?.requestOmnibarFocus()
        persistence?.markDirty()
    }

    private func resizeBrowserDrawer(by delta: CGFloat) {
        guard let session = activeBrowserSession() else { return }
        if !toolDrawerChromeState.isPresented || toolDrawerContentModel.activeToolID != "browser" {
            guard !activeWorkspaceHasBrowserPane() else { return }
            openToolInDrawer("browser")
        }

        let availableHeight = toolDrawerOverlayHostView?.bounds.height
            ?? contentAreaView?.bounds.height
            ?? window?.contentView?.bounds.height
            ?? 0
        session.adjustDrawerHeight(by: delta, availableHeight: availableHeight)
        persistence?.markDirty()
    }

    private func openBrowserInWorkspace(url: URL?, source: BrowserOpenSource) {
        guard let workspace = workspaceManager?.activeWorkspace else { return }
        let session = browserSession(for: workspace)

        if focusExistingBrowserPaneIfPresent() {
            if let url {
                session.navigate(to: url, revealInDrawer: false)
            } else {
                session.restoreIfNeeded()
            }
            persistence?.markDirty()
            return
        }

        openToolInDrawer("browser")
        if let url {
            session.navigate(to: url, revealInDrawer: false)
        } else {
            session.restoreIfNeeded()
        }

        if source == .command && url == nil {
            session.requestOmnibarFocus()
        }

        persistence?.markDirty()
    }

    private func pinBrowserToPane() {
        if toolDrawerChromeState.isPresented, toolDrawerContentModel.activeToolID == "browser" {
            pinToolDrawerToPane()
            return
        }
        openToolAsPane("browser")
    }

    private func openBrowserAsTab() {
        if toolDrawerChromeState.isPresented, toolDrawerContentModel.activeToolID == "browser" {
            openToolDrawerAsTab()
            return
        }
        openToolAsTab("browser")
    }

    // MARK: - Generic tool drawer

    private func replaceToolDrawerContent(
        toolID: String,
        title: String,
        paneID: PaneID? = nil,
        paneView: (NSView & PaneContent)? = nil,
        browserSession: BrowserWorkspaceSession? = nil
    ) {
        toolDrawerContentModel.activeToolID = toolID
        toolDrawerContentModel.activeToolTitle = title
        toolDrawerContentModel.activePaneView = paneView
        toolDrawerContentModel.activePaneID = paneID
        toolDrawerContentModel.activeBrowserSession = browserSession
        toolDrawerContentModel.markContentChanged()
    }

    private func preserveToolDrawerHeightForCurrentContentIfNeeded() {
        if toolDrawerContentModel.activeToolID == "browser",
           let previousBrowserHeight = toolDrawerContentModel.activeBrowserSession?.preferredDrawerHeight {
            toolDrawerContentModel.drawerHeight = previousBrowserHeight
        }
    }

    private func discardCurrentToolDrawerPaneView() {
        toolDrawerContentModel.activePaneView?.removeFromSuperview()
    }

    private func clearToolDrawerContent(markChanged: Bool = true) {
        discardCurrentToolDrawerPaneView()
        toolDrawerContentModel.activePaneView = nil
        toolDrawerContentModel.activePaneID = nil
        toolDrawerContentModel.activeToolID = nil
        toolDrawerContentModel.activeToolTitle = nil
        toolDrawerContentModel.activeBrowserSession = nil
        if markChanged {
            toolDrawerContentModel.markContentChanged()
        }
    }

    private func openToolInDrawer(_ toolID: String) {
        guard let workspace = workspaceManager?.activeWorkspace,
              let tool = sidebarTool(id: toolID, in: workspace) else { return }
        cancelPendingToolDrawerCleanup()

        // Same tool — toggle the drawer
        if toolDrawerContentModel.activeToolID == toolID {
            if toolDrawerChromeState.isPresented {
                closeToolDrawer()
            } else {
                toolDrawerPreviousFirstResponder = window?.firstResponder as? NSResponder
                toolDrawerChromeState.isPresented = true
                syncToolDrawerPointerCapture()
                toolDockState.activeToolID = toolID
                refreshToolDockAutoHide(animated: true)
                if toolID == "browser" {
                    activeBrowserSession()?.requestOmnibarFocus()
                }
            }
            return
        }

        // Different tool while drawer is already open — swap content instantly
        let alreadyPresented = toolDrawerChromeState.isPresented

        if !alreadyPresented {
            toolDrawerPreviousFirstResponder = window?.firstResponder as? NSResponder
        }

        if toolID == "browser" {
            let session = browserSession(for: workspace)
            if alreadyPresented, let preservedHeight = toolDrawerContentModel.drawerHeight {
                session.setDrawerHeight(preservedHeight)
            }
            preserveToolDrawerHeightForCurrentContentIfNeeded()
            discardCurrentToolDrawerPaneView()

            if alreadyPresented {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    replaceToolDrawerContent(
                        toolID: toolID,
                        title: tool.title,
                        browserSession: session
                    )
                }
                syncToolDrawerPointerCapture()
            } else {
                replaceToolDrawerContent(
                    toolID: toolID,
                    title: tool.title,
                    browserSession: session
                )
                toolDrawerChromeState.isPresented = true
                syncToolDrawerPointerCapture()
                refreshToolDockAutoHide(animated: true)
            }
            toolDockState.activeToolID = toolID
            session.restoreIfNeeded()
            return
        }

        // Create a fresh pane for the new tool
        guard PaneFactory.isPaneTypeAvailable(tool.paneType, in: workspace),
              let (paneID, paneView) = PaneFactory.make(type: tool.paneType, chromeContext: .drawer) else { return }
        preserveToolDrawerHeightForCurrentContentIfNeeded()
        discardCurrentToolDrawerPaneView()

        // Swap content without animation when replacing
        if alreadyPresented {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                replaceToolDrawerContent(
                    toolID: toolID,
                    title: tool.title,
                    paneID: paneID,
                    paneView: paneView
                )
                // Keep current drawer height — don't reset on tool switch
            }
            syncToolDrawerPointerCapture()
        } else {
            replaceToolDrawerContent(
                toolID: toolID,
                title: tool.title,
                paneID: paneID,
                paneView: paneView
            )
            toolDrawerContentModel.drawerHeight = DrawerSizing.storedHeight()
            toolDrawerChromeState.isPresented = true
            syncToolDrawerPointerCapture()
            refreshToolDockAutoHide(animated: true)
        }
        toolDockState.activeToolID = toolID
    }

    private func closeToolDrawer() {
        cancelPendingToolDrawerCleanup()
        toolDockState.activeToolID = nil
        if let previous = toolDrawerPreviousFirstResponder {
            window?.makeFirstResponder(previous)
        } else if let pane = contentAreaView?.activePaneView {
            window?.makeFirstResponder(pane)
        }
        toolDrawerPreviousFirstResponder = nil
        if let animation = ChromeMotion.animation(for: .bottomDrawerClose) {
            withAnimation(animation) {
                toolDrawerChromeState.isPresented = false
                toolDrawerChromeState.drawerHitRect = .zero
            }
        } else {
            toolDrawerChromeState.isPresented = false
            toolDrawerChromeState.drawerHitRect = .zero
        }
        syncToolDrawerPointerCapture()
        refreshToolDockAutoHide(animated: true)
        scheduleToolDrawerCleanupAfterClose()
    }

    private func clearClosedToolDrawerContentIfNeeded() {
        guard !toolDrawerChromeState.isPresented else { return }
        clearToolDrawerContent()
        toolDrawerCleanupWorkItem = nil
    }

    private func cancelPendingToolDrawerCleanup() {
        toolDrawerCleanupWorkItem?.cancel()
        toolDrawerCleanupWorkItem = nil
    }

    private func scheduleToolDrawerCleanupAfterClose() {
        // SwiftUI animation completions were not reliable enough here; keep the
        // drawer content mounted for the close animation, then clear it on a
        // bounded delay unless the drawer has already reopened.
        let cleanup = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.clearClosedToolDrawerContentIfNeeded()
        }
        toolDrawerCleanupWorkItem = cleanup

        let delay = ChromeMotion.duration(for: .bottomDrawerClose)
        if delay <= 0 {
            cleanup.perform()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: cleanup)
    }

    private func pinToolDrawerToPane() {
        guard let toolID = toolDrawerContentModel.activeToolID else { return }
        cancelPendingToolDrawerCleanup()
        toolDrawerChromeState.isPresented = false
        syncToolDrawerPointerCapture()
        toolDockState.activeToolID = nil
        clearToolDrawerContent()
        refreshToolDockAutoHide(animated: true)
        Task { @MainActor [weak self] in
            self?.openToolAsPane(toolID)
        }
    }

    private func openToolDrawerAsTab() {
        guard let toolID = toolDrawerContentModel.activeToolID else { return }
        cancelPendingToolDrawerCleanup()
        toolDrawerChromeState.isPresented = false
        syncToolDrawerPointerCapture()
        toolDockState.activeToolID = nil
        clearToolDrawerContent()
        refreshToolDockAutoHide(animated: true)
        Task { @MainActor [weak self] in
            self?.openToolAsTab(toolID)
        }
    }

    private func syncToolDrawerPointerCapture() {
        let isVisible = toolDrawerChromeState.isPresented
        toolDrawerOverlayBlockerView?.capturesPointerEvents = isVisible
        toolDrawerOverlayHostView?.capturesPointerEvents = isVisible
        let hitRect = resolvedToolDrawerOverlayHitRect()
        toolDrawerChromeState.drawerHitRect = hitRect
        toolDrawerOverlayBlockerView?.overlayHitRect = hitRect
        toolDrawerOverlayHostView?.overlayHitRect = hitRect
    }

    private func resolvedToolDrawerOverlayHitRect() -> CGRect {
        guard toolDrawerChromeState.isPresented else { return .zero }
        guard toolDrawerContentModel.activePaneView != nil || toolDrawerContentModel.activeBrowserSession != nil else {
            return .zero
        }

        let bounds = toolDrawerOverlayHostView?.bounds
            ?? contentAreaView?.bounds
            ?? .zero
        guard bounds.width > 0, bounds.height > 0 else { return .zero }

        let drawerHeight: CGFloat
        if let session = toolDrawerContentModel.activeBrowserSession {
            drawerHeight = session.resolvedDrawerHeight(for: bounds.height)
        } else {
            drawerHeight = DrawerSizing.resolvedHeight(
                storedHeight: toolDrawerContentModel.drawerHeight,
                availableHeight: bounds.height
            )
        }

        let resolvedHeight = min(max(0, drawerHeight), bounds.height)
        guard resolvedHeight > 0 else { return .zero }

        return CGRect(
            x: bounds.minX,
            y: max(bounds.minY, bounds.maxY - resolvedHeight),
            width: bounds.width,
            height: resolvedHeight
        )
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
               let projectPath = workspace.activeProjectPath {
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

    private func openSettingsFromSidebar() {
        guard let settingsTool = sidebarToolDefinition(id: "settings") else {
            openSettingsPane()
            return
        }

        if focusExistingTool(settingsTool, scope: .anyTab) {
            return
        }

        guard let pane = PaneFactory.make(type: settingsTool.paneType)?.1 else {
            openSettingsPane()
            return
        }

        if contentAreaView?.replaceActivePane(with: pane) == nil {
            contentAreaView?.setRootPane(pane)
        }
        persistence?.markDirty()
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

        if toolDrawerChromeState.isPresented,
           let activeToolID = toolDrawerContentModel.activeToolID,
           sidebarTool(id: activeToolID, in: workspace) != nil {
            toolDockState.activeToolID = activeToolID
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

        if shouldKeepToolDockExpanded || isToolDockHovered {
            setToolDockExpanded(true, animated: true)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard !self.shouldKeepToolDockExpanded,
                  !self.isToolDockHovered,
                  AppRuntimeSettings.shared.bottomToolBarAutoHide else { return }
            self.setToolDockExpanded(false, animated: true)
        }
        toolDockCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + ChromeMotion.dockHideDelay, execute: workItem)
    }

    private func refreshToolDockAutoHide(animated: Bool) {
        toolDockCollapseWorkItem?.cancel()
        let shouldExpand = !AppRuntimeSettings.shared.bottomToolBarAutoHide
            || shouldKeepToolDockExpanded
            || isToolDockHovered
        setToolDockExpanded(shouldExpand, animated: animated)
    }

    private func setToolDockExpanded(_ isExpanded: Bool, animated: Bool) {
        guard let toolDockHeightConstraint else { return }
        let targetHeight = isExpanded || !AppRuntimeSettings.shared.bottomToolBarAutoHide
            ? DesignTokens.Layout.toolDockHeight
            : ChromeMotion.dockRevealHeight
        let targetAlpha: CGFloat = isExpanded || !AppRuntimeSettings.shared.bottomToolBarAutoHide
            ? 1
            : ChromeMotion.dockCollapsedOpacity
        let currentAlpha = toolDockHostView?.alphaValue ?? 1
        guard toolDockHeightConstraint.constant != targetHeight || abs(currentAlpha - targetAlpha) > 0.001 else {
            return
        }

        let shouldAnimate = animated && ChromeMotion.duration(for: .overlay) > 0
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ChromeMotion.duration(for: .overlay)
                context.timingFunction = ChromeMotion.timingFunction(for: .overlay)
                toolDockHeightConstraint.animator().constant = targetHeight
                toolDockHostView?.animator().alphaValue = targetAlpha
                window?.contentView?.layoutSubtreeIfNeeded()
            }
        } else {
            toolDockHeightConstraint.constant = targetHeight
            toolDockHostView?.alphaValue = targetAlpha
            window?.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func openToolWithDefaultPresentation(_ toolID: String) {
        if toolID == "settings" {
            openSettingsPane()
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
        if toolID == "browser",
           toolDrawerChromeState.isPresented,
           toolDrawerContentModel.activeToolID == "browser" {
            closeToolDrawer()
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
            if toolDrawerChromeState.isPresented, toolDrawerContentModel.activeToolID == "browser" {
                closeToolDrawer()
            }
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
        let frame: SessionPersistence.CodableRect? = window.flatMap { win in
            let f = win.frame
            guard f.width >= win.minSize.width, f.height >= win.minSize.height else { return nil }
            return SessionPersistence.CodableRect(f)
        }
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
        rightInspectorFooterView?.isHidden = !isRightInspectorPresented
        rightInspectorResizerView?.isHidden = !isRightInspectorPresented
        updateWindowMinWidth()

        if let frame = state.windowFrame?.nsRect, let win = window {
            var restored = frame
            restored.size.width = max(restored.size.width, win.minSize.width)
            restored.size.height = max(restored.size.height, win.minSize.height)
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(restored) }) ?? NSScreen.main {
                let visible = screen.visibleFrame
                if restored.maxX > visible.maxX { restored.origin.x = visible.maxX - restored.width }
                if restored.origin.x < visible.minX { restored.origin.x = visible.minX }
                if restored.width > visible.width { restored.size.width = visible.width; restored.origin.x = visible.minX }
                if restored.maxY > visible.maxY { restored.origin.y = visible.maxY - restored.height }
                if restored.origin.y < visible.minY { restored.origin.y = visible.minY }
                if restored.height > visible.height { restored.size.height = visible.height; restored.origin.y = visible.minY }
            }
            win.setFrame(restored, display: true)
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
        refreshBottomDrawerBrowserSession()
        updateTabBar()
    }

    private func makeRootPaneForActiveWorkspace() -> (NSView & PaneContent) {
        PaneFactory.workspaceAwareTerminal().1
    }

    private var notificationsPopover: NSPopover?
    private var usagePopover: NSPopover?
    private var resourceMonitorPopover: NSPopover?
    private var branchPopover: NSPopover?
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
        guard let titlebarStatusView,
              let sessionStore else {
            Log.general.warning("showSessionManager: skipped — titlebarStatusView=\(self.titlebarStatusView != nil), sessionStore=\(self.sessionStore != nil)")
            return
        }

        let popover = NSPopover()
        configureToolbarAttachmentPopover(
            popover,
            contentSize: NSSize(width: 400, height: 320)
        ) {
            SessionManagerPopoverView(
                store: sessionStore,
                onNewSession: { [weak self] in self?.startSessionFromSessionManager() }
            )
        }
        popover.show(
            relativeTo: titlebarStatusView.sessionsButtonFrame,
            of: titlebarStatusView,
            preferredEdge: .minY
        )
        NotificationCenter.default.addObserver(
            forName: NSPopover.willCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sessionsPopover = nil
            }
        }
        sessionsPopover = popover
    }

    private func updateNotificationBadge() {
        guard let workspace = workspaceManager?.activeWorkspace else {
            notificationBadge?.count = 0
            NSApp.dockTile.badgeLabel = nil
            return
        }
        let count = workspace.unreadNotifications + workspace.terminalNotificationCount
        notificationBadge?.count = count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
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
        configureToolbarAttachmentPopover(
            popover,
            contentSize: NSSize(width: 400, height: 400)
        ) {
            NotificationsPopoverView(onViewAll: { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.openNotificationsPane()
            })
        }
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
        configureToolbarAttachmentPopover(
            popover,
            contentSize: NSSize(width: 380, height: 360)
        ) {
            ProviderUsagePopoverView(onOpenDashboard: { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.openUsageDashboard()
            })
        }
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
        configureToolbarAttachmentPopover(
            popover,
            contentSize: NSSize(width: 400, height: 460)
        ) {
            ResourceMonitorPopoverView(onOpenMonitor: { [weak self, weak popover] in
                popover?.performClose(nil)
                self?.openResourceMonitorPane()
            })
        }
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
        symbolConfig: NSImage.SymbolConfiguration,
        hoverTintColor: NSColor? = nil
    ) -> TitlebarIconButton {
        let button = TitlebarIconButton(
            symbolName: symbolName,
            accessibilityDescription: accessibilityDescription,
            toolTip: toolTip,
            symbolConfig: symbolConfig,
            hoverTintColor: hoverTintColor
        )
        button.target = self
        button.action = action
        return button
    }

    func configureToolbarAttachmentPopover<Content: View>(
        _ popover: NSPopover,
        contentSize: NSSize,
        @ViewBuilder rootView: () -> Content
    ) {
        popover.contentSize = contentSize
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = window?.appearance
        popover.contentViewController = NSHostingController(
            rootView: rootView().environment(GhosttyThemeProvider.shared)
        )
    }

    // MARK: - Layout Template Actions

    @objc func titlebarTemplateAction() {
        guard let btn = titlebarTemplateBtn else { return }
        let templates = LayoutTemplateStore.list()
        let popover = NSPopover()
        configureToolbarAttachmentPopover(
            popover,
            contentSize: NSSize(width: 320, height: min(CGFloat(templates.count) * 52 + 180, 420))
        ) {
            LayoutTemplatePopoverView(
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
        }
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
        guard let path = workspaceManager?.activeWorkspace?.activeProjectPath,
              let openButton = titlebarOpenBtn else { return }
        let menu = OpenInMenuController.buildMenu(for: path, target: nil, primaryAction: nil)
        guard menu.items.isEmpty == false else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: openButton.bounds.height - 2), in: openButton)
    }

    private func showTitlebarGitActionsMenu(from button: CapsuleButton) {
        let workspace = workspaceManager?.activeWorkspace
        let hasProject = workspace?.projectPath != nil
        let canCreateBranch = hasProject && commandBus != nil
        let canCreatePullRequest = hasProject && activeWorkspaceTaskID() != nil && commandBus != nil

        let menu = NSMenu()
        menu.autoenablesItems = false

        let header = NSMenuItem(title: "Git Actions", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        menu.addItem(makeGitActionsMenuItem(
            title: "Commit",
            systemImage: "point.3.connected.trianglepath.dotted",
            action: #selector(titlebarCommitAction),
            enabled: hasProject
        ))
        menu.addItem(makeGitActionsMenuItem(
            title: "Push",
            systemImage: "icloud.and.arrow.up",
            action: #selector(titlebarPushAction),
            enabled: hasProject
        ))

        if workspace?.linkedPRURL?.isEmpty == false {
            menu.addItem(makeGitActionsMenuItem(
                title: "Open PR",
                systemImage: "arrow.up.right.square",
                action: #selector(titlebarOpenLinkedPullRequestAction),
                enabled: true
            ))
        } else {
            menu.addItem(makeGitActionsMenuItem(
                title: "Create PR",
                systemImage: "arrow.up.right.square",
                action: #selector(titlebarCreatePullRequestAction),
                enabled: canCreatePullRequest
            ))
        }

        menu.addItem(makeGitActionsMenuItem(
            title: "Create Branch",
            systemImage: "arrow.triangle.branch",
            action: #selector(titlebarCreateBranchAction),
            enabled: canCreateBranch
        ))

        menu.popUp(
            positioning: nil,
            at: NSPoint(x: button.bounds.maxX - 18, y: button.bounds.height - 2),
            in: button
        )
    }

    private func makeGitActionsMenuItem(
        title: String,
        systemImage: String,
        action: Selector,
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        return item
    }

    private func activeWorkspaceTaskID() -> String? {
        contentAreaView?.syncPersistedPanes()
        guard let workspace = workspaceManager?.activeWorkspace else { return nil }

        if let activePaneID = workspace.layoutEngine.activePaneID,
           let taskID = workspace.layoutEngine.persistedPane(for: activePaneID)?.taskID,
           !taskID.isEmpty {
            return taskID
        }

        return workspace.layoutEngine.root?.allPaneIDs
            .compactMap { paneID in
                workspace.layoutEngine.persistedPane(for: paneID)?.taskID
            }
            .first { !$0.isEmpty }
    }

    @objc func titlebarCommitAction() {
        guard workspaceManager?.activeWorkspace?.projectPath != nil,
              let message = promptForCommitMessage() else { return }
        runGitCommit(message: message)
    }

    private func promptForCommitMessage() -> String? {
        let alert = NSAlert()
        alert.messageText = "Commit Changes"
        alert.informativeText = "Write a commit message for the active project."

        let promptWidth: CGFloat = 360
        let commitField = NSTextField(string: "")
        commitField.placeholderString = "Summarize your changes"
        commitField.frame.size.width = promptWidth
        commitField.setAccessibilityIdentifier("git.commit.message")

        var accessoryViews: [NSView] = []
        if let branch = workspaceManager?.activeWorkspace?.gitBranch,
           branch.isEmpty == false {
            accessoryViews.append(
                makeCommitBranchSummaryView(
                    branch: branch,
                    width: promptWidth
                )
            )
        }
        accessoryViews.append(commitField)

        alert.accessoryView = makeAlertAccessoryStack(
            width: promptWidth,
            views: accessoryViews
        )
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let message = commitField.stringValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard message.isEmpty == false else {
            ToastManager.shared.show(
                "Commit message is required",
                icon: "exclamationmark.triangle",
                style: .error
            )
            return nil
        }

        return message
    }

    private func makeCommitBranchSummaryView(branch: String, width: CGFloat) -> NSView {
        let branchIcon = NSImageView()
        branchIcon.image = NSImage(
            systemSymbolName: "arrow.triangle.branch",
            accessibilityDescription: "Branch"
        )?.withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        branchIcon.contentTintColor = .secondaryLabelColor
        branchIcon.setContentHuggingPriority(.required, for: .horizontal)
        branchIcon.setContentCompressionResistancePriority(.required, for: .horizontal)

        let branchLabel = NSTextField(labelWithString: branch)
        branchLabel.font = .preferredFont(forTextStyle: .headline)
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let branchRow = NSStackView(views: [branchIcon, branchLabel])
        branchRow.orientation = .horizontal
        branchRow.alignment = .centerY
        branchRow.spacing = DesignTokens.Spacing.sm

        return makeAlertCard(width: width, views: [branchRow])
    }

    @objc private func titlebarOpenLinkedPullRequestAction() {
        openLinkedPRInBrowser()
    }

    @objc func titlebarPushAction() {
        guard workspaceManager?.activeWorkspace?.projectPath != nil else { return }
        ToastManager.shared.show(
            "Pushing changes…",
            icon: "icloud.and.arrow.up",
            style: .info
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let workspaceManager = self.workspaceManager else {
                    throw WorkspaceActionError.workspaceUnavailable
                }
                let bus = try await resolveTitlebarGitActionCommandBus(
                    workspaceManager: workspaceManager
                )
                await self.handleTitlebarPush(using: bus)
            } catch {
                ToastManager.shared.show(
                    "Push failed: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle",
                    style: .error
                )
            }
        }
    }

    @objc private func titlebarCreateBranchAction() {
        guard let path = workspaceManager?.activeWorkspace?.projectPath,
              let bus = commandBus,
              let branchName = promptForBranchName(),
              !branchName.isEmpty else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let launch = try await self.createWorkspaceFromBranch(
                    path: path,
                    branchName: branchName,
                    createNew: true,
                    commandBus: bus
                )

                let resolvedBranch = launch.branch ?? branchName
                _ = self.openLocalWorkspace(
                    path: launch.projectPath,
                    checkoutPath: launch.checkoutPath,
                    terminalMode: self.workspaceManager?.activeWorkspace?.terminalMode ?? .persistent,
                    workspaceName: launch.workspaceName,
                    launchSource: launch.launchSource,
                    workingDirectory: launch.workingDirectory,
                    taskID: launch.taskID
                )
                ToastManager.shared.show(
                    "Created \(resolvedBranch)",
                    icon: "arrow.triangle.branch",
                    style: .success
                )
            } catch {
                ToastManager.shared.show(
                    "Failed to create branch: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle",
                    style: .error
                )
            }
        }
    }

    private func promptForBranchName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Create Branch"
        alert.informativeText = "Create and check out a new branch for the active project."

        let branchField = NSTextField(string: "")
        branchField.placeholderString = "feature/my-branch"
        branchField.frame.size.width = 320

        alert.accessoryView = makeAlertAccessoryStack(width: 320, views: [branchField])
        alert.addButton(withTitle: "Create Branch")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let branchName = branchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return branchName.isEmpty ? nil : branchName
    }

    @objc private func titlebarCreatePullRequestAction() {
        guard let bus = commandBus,
              let taskID = activeWorkspaceTaskID(),
              let draft = promptForPullRequestDraft(),
              !draft.title.isEmpty else { return }

        struct PullRequestCreateParams: Encodable {
            let taskID: String
            let title: String
            let body: String?
            let base: String?
        }

        struct PullRequestView: Decodable {
            let number: Int64
            let title: String
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let created: PullRequestView = try await bus.call(
                    method: "pr.create",
                    params: PullRequestCreateParams(
                        taskID: taskID,
                        title: draft.title,
                        body: draft.body,
                        base: nil
                    )
                )

                if let workspace = self.workspaceManager?.activeWorkspace {
                    self.workspaceManager?.refreshMetadata(for: workspace)
                }
                ToastManager.shared.show(
                    "Created PR #\(created.number)",
                    icon: "arrow.up.right.square",
                    style: .success
                )
            } catch {
                ToastManager.shared.show(
                    "Failed to create PR: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle",
                    style: .error
                )
            }
        }
    }

    private func promptForPullRequestDraft() -> (title: String, body: String?)? {
        let alert = NSAlert()
        alert.messageText = "Create Pull Request"
        alert.informativeText = "Create a pull request for the active task workspace."

        let titleField = NSTextField(string: "")
        titleField.placeholderString = "Summarize the change"
        titleField.frame.size.width = 320

        let bodyField = NSTextField(string: "")
        bodyField.placeholderString = "Optional description"
        bodyField.frame.size.width = 320

        alert.accessoryView = makeAlertAccessoryStack(width: 320, views: [titleField, bodyField])
        alert.addButton(withTitle: "Create PR")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let body = bodyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title, body.isEmpty ? nil : body)
    }

    func handleTitlebarPush(using bus: any CommandCalling) async {
        do {
            let result: ToolbarGitPushResult = try await bus.call(method: "workspace.push")
            if result.success {
                refreshActiveWorkspaceMetadata()
                ToastManager.shared.show(
                    "Pushed changes",
                    icon: "icloud.and.arrow.up",
                    style: .success
                )
                return
            }

            ToastManager.shared.show(
                result.errorMessage ?? "Push failed",
                icon: "exclamationmark.triangle",
                style: .error
            )
        } catch {
            ToastManager.shared.show(
                "Push failed: \(error.localizedDescription)",
                icon: "exclamationmark.triangle",
                style: .error
            )
        }
    }

    func handleTitlebarCommit(message: String, using bus: any CommandCalling) async {
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }

        do {
            let result: ToolbarGitCommitResult = try await bus.call(
                method: "workspace.commit",
                params: ToolbarGitCommitParams(message: trimmedMessage)
            )
            if result.success {
                refreshActiveWorkspaceMetadata()
                let commitReference = result.commitSha.map { String($0.prefix(7)) }
                let message = commitReference.map { "Committed \($0)" } ?? "Committed changes"
                ToastManager.shared.show(
                    message,
                    icon: "point.3.connected.trianglepath.dotted",
                    style: .success
                )
                return
            }

            ToastManager.shared.show(
                result.errorMessage ?? "Commit failed",
                icon: "exclamationmark.triangle",
                style: .error
            )
        } catch {
            ToastManager.shared.show(
                "Commit failed: \(error.localizedDescription)",
                icon: "exclamationmark.triangle",
                style: .error
            )
        }
    }

    private func runGitCommit(message: String) {
        guard workspaceManager?.activeWorkspace?.projectPath != nil else { return }
        ToastManager.shared.show(
            "Committing changes…",
            icon: "point.3.connected.trianglepath.dotted",
            style: .info
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let workspaceManager = self.workspaceManager else {
                    throw WorkspaceActionError.workspaceUnavailable
                }
                let bus = try await resolveTitlebarGitActionCommandBus(
                    workspaceManager: workspaceManager
                )
                await self.handleTitlebarCommit(message: message, using: bus)
            } catch {
                ToastManager.shared.show(
                    "Commit failed: \(error.localizedDescription)",
                    icon: "exclamationmark.triangle",
                    style: .error
                )
            }
        }
    }

    private func refreshActiveWorkspaceMetadata() {
        guard let workspace = workspaceManager?.activeWorkspace else { return }
        workspaceManager?.refreshMetadata(for: workspace)
    }
}


// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    public func windowDidResize(_ notification: Notification) {
        contentAreaView?.needsLayout = true
        syncToolDrawerPointerCapture()
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        titlebarFillMinHeightConstraint?.isActive = true

        // Traffic lights are hidden in fullscreen — pull the leading group toward the edge.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.normal
            ctx.allowsImplicitAnimation = true
            sidebarToggleLeadingConstraint?.animator().constant = 12
        }
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        titlebarFillMinHeightConstraint?.isActive = false

        // Traffic lights reappear — restore the normal leading inset.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.normal
            ctx.allowsImplicitAnimation = true
            sidebarToggleLeadingConstraint?.animator().constant = 76
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

#if DEBUG
extension AppDelegate {
    func openToolInDrawerForTesting(_ toolID: String) {
        openToolInDrawer(toolID)
    }

    var toolDrawerContentModelForTesting: ToolDrawerContentModel {
        toolDrawerContentModel
    }

    var toolDrawerChromeStateForTesting: ToolDrawerChromeState {
        toolDrawerChromeState
    }
}
#endif

private final class MainWindowContentView: NSView {}

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
