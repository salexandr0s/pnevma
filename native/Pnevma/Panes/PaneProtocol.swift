import Cocoa
import SwiftUI

/// Unique identifier for a pane instance.
typealias PaneID = UUID

struct PersistedPane: Codable {
    let paneID: PaneID
    let type: String
    let workingDirectory: String?
    let sessionID: String?
    let taskID: String?
    let metadataJSON: String?
}

extension PersistedPane {
    var terminalLaunchMetadata: TerminalLaunchMetadata? {
        guard type == "terminal" else { return nil }
        return TerminalLaunchMetadata.from(json: metadataJSON)
    }
}

/// All pane types must conform to this protocol.
/// Conforming types must be NSView subclasses (enforced by AnyObject + usage as `NSView & PaneContent`).
@MainActor
protocol PaneContent: AnyObject {
    /// Unique identifier for this pane instance.
    var paneID: PaneID { get }

    /// Machine-readable pane type (e.g. "terminal", "taskboard", "review").
    var paneType: String { get }

    /// Human-readable title for display in tabs, palette, etc.
    var title: String { get }

    var workingDirectory: String? { get }
    var sessionID: String? { get }
    var taskID: String? { get }
    var metadataJSON: String? { get }
    /// Whether this pane writes a restore descriptor into the layout engine.
    /// Panes that return `false` cannot survive workspace switches or session restore.
    /// Only placeholders/error shells should opt out.
    var shouldPersist: Bool { get }

    /// Called when this pane becomes the active (focused) pane.
    func activate()

    /// Called when another pane takes focus.
    func deactivate()

    /// Called before the pane is removed from the layout. Clean up resources.
    func dispose()

    /// Whether this pane has a live process that would be killed on close.
    var hasActiveProcess: Bool { get }
}

@MainActor
protocol PanePersistenceObservable: AnyObject {
    var onPersistedStateChange: ((PersistedPane) -> Void)? { get set }
}

/// Default implementations for PaneContent.
extension PaneContent {
    func activate() {}
    func deactivate() {}
    func dispose() {}
    var workingDirectory: String? { nil }
    var sessionID: String? { nil }
    var taskID: String? { nil }
    var metadataJSON: String? { nil }
    var shouldPersist: Bool { true }
    var hasActiveProcess: Bool { false }

    func persistedPane() -> PersistedPane {
        PersistedPane(
            paneID: paneID,
            type: paneType,
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            taskID: taskID,
            metadataJSON: metadataJSON
        )
    }
}

@MainActor
private final class RestoredPaneContainer: NSView, PaneContent {
    let paneID: PaneID
    private let wrapped: NSView & PaneContent
    private let persisted: PersistedPane
    private var persistedStateChangeHandler: ((PersistedPane) -> Void)?

    init(persisted: PersistedPane, wrapped: NSView & PaneContent) {
        self.paneID = persisted.paneID
        self.persisted = persisted
        self.wrapped = wrapped
        super.init(frame: .zero)

        wrapped.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wrapped)
        NSLayoutConstraint.activate([
            wrapped.leadingAnchor.constraint(equalTo: leadingAnchor),
            wrapped.trailingAnchor.constraint(equalTo: trailingAnchor),
            wrapped.topAnchor.constraint(equalTo: topAnchor),
            wrapped.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    var paneType: String { persisted.type }
    var title: String { wrapped.title }
    var workingDirectory: String? { wrapped.workingDirectory ?? persisted.workingDirectory }
    var sessionID: String? { wrapped.sessionID ?? persisted.sessionID }
    var taskID: String? { wrapped.taskID ?? persisted.taskID }
    var metadataJSON: String? { wrapped.metadataJSON ?? persisted.metadataJSON }
    var shouldPersist: Bool { true }

    var hasActiveProcess: Bool { wrapped.hasActiveProcess }

    func activate() { wrapped.activate() }
    func deactivate() { wrapped.deactivate() }
    func dispose() { wrapped.dispose() }
}

extension RestoredPaneContainer: PanePersistenceObservable {
    var onPersistedStateChange: ((PersistedPane) -> Void)? {
        get { persistedStateChangeHandler }
        set {
            persistedStateChangeHandler = newValue

            guard let observablePane = wrapped as? PanePersistenceObservable else { return }
            guard let newValue else {
                observablePane.onPersistedStateChange = nil
                return
            }

            observablePane.onPersistedStateChange = { [weak self] pane in
                guard let self else { return }
                newValue(
                    PersistedPane(
                        paneID: self.paneID,
                        type: self.paneType,
                        workingDirectory: pane.workingDirectory,
                        sessionID: pane.sessionID,
                        taskID: pane.taskID,
                        metadataJSON: pane.metadataJSON
                    )
                )
            }
        }
    }
}

/// Registry of known pane types and their factory methods.
@MainActor
enum PaneFactory {
    static var sessionBridge: SessionBridge?
    static var activeWorkspaceProvider: (() -> Workspace?)?

    private static func paneTuple(_ view: NSView & PaneContent) -> (PaneID, NSView & PaneContent) {
        (view.paneID, view)
    }

    static func workspaceAwareTerminal(
        startBehavior: TerminalStartBehavior = .immediate
    ) -> (PaneID, NSView & PaneContent) {
        let workspace = activeWorkspaceProvider?()
        let metadata = workspace?.defaultTerminalMetadata(startBehavior: startBehavior)
            ?? TerminalLaunchMetadata(
                launchMode: .localShell,
                startBehavior: startBehavior,
                remoteTarget: nil
            )
        let workingDirectory = workspace?.defaultWorkingDirectory
        return makeTerminal(
            workingDirectory: workingDirectory,
            sessionID: nil,
            autoStartIfNeeded: metadata.shouldAutoStart,
            launchMetadata: metadata
        )
    }

    static func makeWelcome() -> (PaneID, NSView & PaneContent) {
        paneTuple(WelcomePaneView(frame: .zero))
    }

    static func makeRestoreError(
        paneID: PaneID,
        message: String,
        detail: String?
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(RestoreErrorPaneView(
            paneID: paneID,
            message: message,
            detail: detail
        ))
    }

    /// Create a terminal pane.
    static func makeTerminal(
        workingDirectory: String? = nil,
        sessionID: String? = nil,
        autoStartIfNeeded: Bool = true,
        launchMetadata: TerminalLaunchMetadata? = nil
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(TerminalPaneView(
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            autoStartIfNeeded: autoStartIfNeeded,
            launchMetadata: launchMetadata
        ))
    }

    static func makeTaskBoard() -> (PaneID, NSView & PaneContent) {
        paneTuple(TaskBoardPaneView(frame: .zero))
    }

    static func makeReplay() -> (PaneID, NSView & PaneContent) {
        paneTuple(ReplayPaneView(frame: .zero))
    }

    static func makeFileBrowser() -> (PaneID, NSView & PaneContent) {
        paneTuple(FileBrowserPaneView(frame: .zero))
    }

    static func makeSshManager() -> (PaneID, NSView & PaneContent) {
        paneTuple(SshManagerPaneView(frame: .zero))
    }

    static func makeWorkflow() -> (PaneID, NSView & PaneContent) {
        paneTuple(WorkflowPaneView(frame: .zero))
    }

    static func makeReview() -> (PaneID, NSView & PaneContent) {
        paneTuple(ReviewPaneView(frame: .zero))
    }

    static func makeMergeQueue() -> (PaneID, NSView & PaneContent) {
        paneTuple(MergeQueuePaneView(frame: .zero))
    }

    static func makeDiff() -> (PaneID, NSView & PaneContent) {
        paneTuple(DiffPaneView(frame: .zero))
    }

    static func makeSearch() -> (PaneID, NSView & PaneContent) {
        paneTuple(SearchPaneView(frame: .zero))
    }

    static func makeAnalytics() -> (PaneID, NSView & PaneContent) {
        paneTuple(UsagePaneView(frame: .zero))
    }

    static func makeSettings() -> (PaneID, NSView & PaneContent) {
        paneTuple(SettingsPaneView(frame: .zero))
    }

    static func makeNotifications() -> (PaneID, NSView & PaneContent) {
        paneTuple(NotificationsPaneView(frame: .zero))
    }

    static func makeDailyBrief() -> (PaneID, NSView & PaneContent) {
        paneTuple(DailyBriefPaneView(frame: .zero))
    }

    static func makeRulesManager() -> (PaneID, NSView & PaneContent) {
        paneTuple(RulesManagerPaneView(frame: .zero))
    }

    static func makeBrowser(url: URL? = nil) -> (PaneID, NSView & PaneContent) {
        paneTuple(BrowserPaneView(frame: .zero, url: url))
    }

    static func makeHarnessConfig() -> (PaneID, NSView & PaneContent) {
        paneTuple(HarnessConfigPaneView(frame: .zero))
    }

    static func make(from persistedPane: PersistedPane) -> (PaneID, NSView & PaneContent) {
        let inner: (NSView & PaneContent)
        switch persistedPane.type {
        case "terminal":
            let metadata = persistedPane.terminalLaunchMetadata
                ?? TerminalLaunchMetadata(
                    launchMode: persistedPane.sessionID == nil ? .localShell : .managedSession,
                    startBehavior: .immediate,
                    remoteTarget: nil
                )
            inner = TerminalPaneView(
                workingDirectory: persistedPane.workingDirectory,
                sessionID: persistedPane.sessionID,
                autoStartIfNeeded: metadata.shouldAutoStart,
                launchMetadata: metadata
            )
        case "welcome":
            inner = WelcomePaneView(frame: .zero)
        case "taskboard":
            inner = TaskBoardPaneView(frame: .zero)
        case "replay":
            inner = ReplayPaneView(frame: .zero, sessionID: persistedPane.sessionID)
        case "file_browser":
            inner = FileBrowserPaneView(frame: .zero)
        case "ssh":
            inner = SshManagerPaneView(frame: .zero)
        case "workflow":
            inner = WorkflowPaneView(frame: .zero)
        case "review":
            inner = ReviewPaneView(frame: .zero)
        case "merge_queue":
            inner = MergeQueuePaneView(frame: .zero)
        case "diff":
            inner = DiffPaneView(frame: .zero)
        case "search":
            inner = SearchPaneView(frame: .zero)
        case "analytics":
            inner = UsagePaneView(frame: .zero)
        case "settings":
            inner = SettingsPaneView(frame: .zero)
        case "notifications":
            inner = NotificationsPaneView(frame: .zero)
        case "daily_brief":
            inner = DailyBriefPaneView(frame: .zero)
        case "rules":
            inner = RulesManagerPaneView(frame: .zero)
        case "browser":
            inner = BrowserPaneView.fromMetadata(persistedPane.metadataJSON)
        case "harness_config":
            inner = HarnessConfigPaneView(frame: .zero)
        default:
            inner = RestoreErrorPaneView(
                paneID: persistedPane.paneID,
                message: "Unknown pane type: \(persistedPane.type)",
                detail: "This pane could not be restored and will not be saved."
            )
        }

        let wrapped = RestoredPaneContainer(persisted: persistedPane, wrapped: inner)
        return (wrapped.paneID, wrapped)
    }

    /// Create a pane by type string.
    static func make(type paneType: String) -> (PaneID, NSView & PaneContent)? {
        guard isPaneTypeAvailable(paneType, in: activeWorkspaceProvider?()) else {
            return nil
        }
        switch paneType {
        case "welcome":       return makeWelcome()
        case "terminal":      return workspaceAwareTerminal()
        case "taskboard":     return makeTaskBoard()
        case "replay":        return makeReplay()
        case "file_browser":  return makeFileBrowser()
        case "ssh":           return makeSshManager()
        case "workflow":      return makeWorkflow()
        case "review":        return makeReview()
        case "merge_queue":   return makeMergeQueue()
        case "diff":          return makeDiff()
        case "search":        return makeSearch()
        case "analytics":     return makeAnalytics()
        case "settings":      return makeSettings()
        case "notifications": return makeNotifications()
        case "daily_brief":   return makeDailyBrief()
        case "rules":         return makeRulesManager()
        case "browser":        return makeBrowser()
        case "harness_config": return makeHarnessConfig()
        default:              return nil
        }
    }

    static func isPaneTypeAvailable(_ paneType: String, in workspace: Workspace?) -> Bool {
        availablePaneTypes(for: workspace).contains(paneType)
    }

    static func availablePaneTypes(for workspace: Workspace?) -> Set<String> {
        guard let workspace else {
            return ["terminal", "ssh", "workflow", "notifications", "browser", "analytics", "harness_config"]
        }
        if workspace.showsProjectToolsInUI {
            return [
                "terminal",
                "taskboard",
                "workflow",
                "notifications",
                "file_browser",
                "ssh",
                "replay",
                "browser",
                "search",
                "review",
                "merge_queue",
                "diff",
                "analytics",
                "daily_brief",
                "rules",
                "harness_config",
            ]
        }
        return ["terminal", "ssh", "workflow", "notifications", "browser", "analytics", "harness_config"]
    }
}

// MARK: - WelcomePaneView

final class WelcomePaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "welcome"
    let shouldPersist = false
    var title: String { "Welcome" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(WelcomeContentView())
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

private struct WelcomeContentView: View {
    @State private var appeared = false

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // Logo + title
                VStack(spacing: 12) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.primary.opacity(0.25))

                    Text("Pnevma")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary.opacity(0.9))

                    Text("Terminal-first workspace for AI-agent-driven delivery")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 36)

                // Action cards
                HStack(spacing: 12) {
                    WelcomeCard(
                        accessibilityID: "welcome.openProject",
                        icon: "folder.badge.plus",
                        title: "Open Workspace",
                        subtitle: "Create a local or remote workspace",
                        accentColor: .blue
                    ) {
                        NSApp.sendAction(#selector(AppDelegate.openWorkspaceAction), to: nil, from: nil)
                    }

                    WelcomeCard(
                        accessibilityID: "welcome.newTerminal",
                        icon: "terminal",
                        title: "New Terminal",
                        subtitle: "Launch a standalone shell",
                        accentColor: .green
                    ) {
                        NSApp.sendAction(#selector(AppDelegate.newTerminal), to: nil, from: nil)
                    }
                }
                .padding(.bottom, 32)

                // Keyboard shortcuts grid
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        WelcomeShortcut(keys: ["Cmd", "T"], label: "New Tab")
                        WelcomeShortcut(keys: ["Shift", "Cmd", "P"], label: "Command Palette")
                        WelcomeShortcut(keys: ["Cmd", "D"], label: "Split Right")
                    }
                    Divider().opacity(0.3)
                    HStack(spacing: 0) {
                        WelcomeShortcut(keys: ["Cmd", "]"], label: "Next Pane")
                        WelcomeShortcut(keys: ["Cmd", "B"], label: "Toggle Sidebar")
                        WelcomeShortcut(keys: ["Cmd", "Enter"], label: "Full Screen")
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.primary.opacity(0.03))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.primary.opacity(0.06), lineWidth: 1)
                )

                Spacer()
                Spacer()
            }
            .frame(maxWidth: 520)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
        }
        .onAppear {
            withAnimation(DesignTokens.Motion.resolved(.easeOut(duration: 0.4).delay(0.05))) {
                appeared = true
            }
        }
        .accessibilityIdentifier("welcome.root")
    }
}

private struct WelcomeCard: View {
    let accessibilityID: String
    let icon: String
    let title: String
    let subtitle: String
    let accentColor: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(accentColor.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(accentColor.opacity(0.1))
                    )

                VStack(spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.9))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.primary.opacity(isHovering ? 0.06 : 0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.primary.opacity(isHovering ? 0.12 : 0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
        .accessibilityIdentifier(accessibilityID)
    }
}

private struct WelcomeShortcut: View {
    let keys: [String]
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(.primary.opacity(0.06))
                        )
                }
            }
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(keys.joined(separator: " "))")
    }
}

// MARK: - EmptyStateView (shared component)

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String?
    let actionTitle: String?
    let action: (() -> Void)?

    init(icon: String, title: String, message: String? = nil, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.secondary.opacity(0.5))
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

final class RestoreErrorPaneView: NSView, PaneContent {
    let paneID: PaneID
    let paneType = "restore_error"
    let shouldPersist = false
    var title: String { "Restore Error" }

    init(paneID: PaneID, message: String, detail: String?) {
        self.paneID = paneID
        super.init(frame: .zero)
        _ = addSwiftUISubview(
            TerminalStateView(
                title: "Pane Restore Failed",
                message: message,
                detail: detail,
                scrollback: nil,
                actions: [],
                isLoadingOverride: false
            )
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
}

// MARK: - TerminalPaneView

private struct ProjectOpenFailureEventPayload: Decodable {
    let workspaceID: UUID?
    let generation: UInt64?
    let message: String
}

/// Wraps TerminalHostView to conform to PaneContent.
final class TerminalPaneView: NSView, PaneContent, PanePersistenceObservable {
    private static let maxManagedSessionProjectNotReadyRetries = 5
    private static let managedSessionRetryDelayNanos: UInt64 = 250_000_000

    let paneID = PaneID()
    let paneType = "terminal"
    var title: String { "Terminal" }

    private var hostView: TerminalHostView?
    private var stateHostView: NSHostingView<TerminalStateView>?
    private var agentLauncherView: NSHostingView<AgentLauncherOverlay>?
    private var agentLauncherKeyMonitor: Any?
    private let autoStartIfNeeded: Bool
    private var launchMetadata: TerminalLaunchMetadata
    private var currentWorkingDirectory: String?
    private var currentSessionID: String?
    private var bridgeObserverID: UUID?
    private var activationObserverID: UUID?
    private var loadTask: Task<Void, Never>?
    private var recoveryOptions: [SessionRecoveryOption] = []
    private var awaitingProjectActivation = false
    private var projectNotReadyRetryCount = 0
    private let activationHub: ActiveWorkspaceActivationHub
    var onPersistedStateChange: ((PersistedPane) -> Void)?

    init(
        workingDirectory: String? = nil,
        sessionID: String? = nil,
        autoStartIfNeeded: Bool = true,
        launchMetadata: TerminalLaunchMetadata? = nil,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.autoStartIfNeeded = autoStartIfNeeded
        self.launchMetadata = launchMetadata
            ?? TerminalLaunchMetadata(
                launchMode: autoStartIfNeeded ? .managedSession : .localShell,
                startBehavior: autoStartIfNeeded ? .immediate : .deferUntilActivate,
                remoteTarget: nil
            )
        self.currentWorkingDirectory = workingDirectory
        self.currentSessionID = sessionID
        self.activationHub = activationHub
        super.init(frame: .zero)
        showState(
            title: initialStateTitle,
            message: initialStateMessage,
            detail: nil,
            scrollback: nil,
            actions: []
        )
        bridgeObserverID = BridgeEventHub.shared.addObserver { [weak self] event in
            switch event.name {
            case "project_opened":
                Task { @MainActor [weak self] in
                    self?.retryAfterProjectActivation()
                }
            case "project_open_failed":
                Task { @MainActor [weak self] in
                    self?.showProjectActivationFailure(event)
                }
            default:
                break
            }
        }
        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, self.awaitingProjectActivation else { return }
                switch state {
                case .open:
                    self.retryAfterProjectActivation()
                case .failed(_, _, let message):
                    self.showProjectActivationFailureMessage(message)
                default:
                    break
                }
            }
        }
        loadOrRestoreSession()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard let hostView else {
            return super.becomeFirstResponder()
        }
        return window?.makeFirstResponder(hostView) ?? false
    }

    func activate() {
        if hostView == nil, currentSessionID == nil, !launchMetadata.shouldAutoStart {
            launchMetadata = TerminalLaunchMetadata(
                launchMode: launchMetadata.launchMode,
                startBehavior: .immediate,
                remoteTarget: launchMetadata.remoteTarget
            )
            notifyPersistedStateChanged()
            loadOrRestoreSession()
            return
        }
        if let hostView {
            window?.makeFirstResponder(hostView)
            hostView.setPaneFocused(true)
        }
    }

    func deactivate() {
        if let hostView {
            if window?.firstResponder === hostView {
                window?.makeFirstResponder(nil)
            }
            hostView.setPaneFocused(false)
        }
    }

    /// A terminal pane has an active process if it has a live surface.
    var hasActiveProcess: Bool {
        hostView?.terminalSurface?.isAlive ?? false
    }

    func dispose() {
        loadTask?.cancel()
        removeAgentLauncher()
        if let bridgeObserverID {
            BridgeEventHub.shared.removeObserver(bridgeObserverID)
        }
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
        hostView?.terminalSurface?.requestClose()
    }

    var workingDirectory: String? { currentWorkingDirectory }
    var sessionID: String? { currentSessionID }
    var metadataJSON: String? { launchMetadata.encodedJSON() }

    var onTerminalClose: (() -> Void)? {
        get { hostView?.onTerminalClose }
        set { hostView?.onTerminalClose = newValue }
    }

    private var initialStateTitle: String {
        launchMetadata.remoteTarget == nil ? "Terminal" : "Remote Terminal"
    }

    private var initialStateMessage: String {
        if currentSessionID != nil {
            return "Connecting to the backend terminal session..."
        }
        if !launchMetadata.shouldAutoStart {
            return deferredLaunchMessage
        }
        switch launchMetadata.launchMode {
        case .managedSession:
            return launchMetadata.remoteTarget == nil
                ? "Connecting to the backend terminal session..."
                : "Preparing a managed remote terminal session..."
        case .localShell:
            return "Starting a local terminal..."
        case .remoteShell:
            return "Starting a remote shell..."
        }
    }

    private var deferredLaunchMessage: String {
        switch launchMetadata.launchMode {
        case .managedSession:
            return "Activate this pane to start a backend-managed terminal session."
        case .localShell:
            return "Local terminal will start when this pane becomes active."
        case .remoteShell:
            return "Remote shell will start when this pane becomes active."
        }
    }

    private var usesManagedSessions: Bool {
        launchMetadata.launchMode == .managedSession
    }

    private var managedSessionCommand: String? {
        launchMetadata.remoteTarget?.remoteShellCommand
    }

    private var shellWorkingDirectory: String? {
        if launchMetadata.remoteTarget != nil {
            return NSHomeDirectory()
        }
        return currentWorkingDirectory ?? NSHomeDirectory()
    }

    private var shellCommand: String? {
        if let remoteTarget = launchMetadata.remoteTarget {
            return remoteTarget.remoteShellCommand
        }
        return AppRuntimeSettings.shared.normalizedDefaultShell
    }

    private func retryAfterProjectActivation() {
        guard awaitingProjectActivation else { return }
        awaitingProjectActivation = false
        loadOrRestoreSession()
    }

    private func showProjectActivationFailure(_ event: BridgeEvent) {
        guard awaitingProjectActivation else { return }
        let decoder = PnevmaJSON.decoder()
        let payload = event.payloadJSON.data(using: .utf8).flatMap {
            try? decoder.decode(ProjectOpenFailureEventPayload.self, from: $0)
        }
        guard projectOpenFailureMatchesCurrentActivation(payload) else { return }
        showProjectActivationFailureMessage(
            payload?.message ?? "The workspace project could not be activated."
        )
    }

    private func projectOpenFailureMatchesCurrentActivation(
        _ payload: ProjectOpenFailureEventPayload?
    ) -> Bool {
        guard let payload else { return true }

        switch activationHub.currentState {
        case .opening(let workspaceID, let generation),
             .failed(let workspaceID, let generation, _):
            return payload.workspaceID == workspaceID && payload.generation == generation
        default:
            return false
        }
    }

    private func showProjectActivationFailureMessage(_ message: String) {
        projectNotReadyRetryCount = 0
        awaitingProjectActivation = true
        showState(
            title: "Project Activation Failed",
            message: message,
            detail: "The terminal will retry automatically after the workspace activates successfully.",
            scrollback: nil,
            actions: [],
            isLoading: false
        )
    }

    private func showProjectActivationPending() {
        awaitingProjectActivation = true
        showState(
            title: "Waiting For Project",
            message: "The workspace project is still activating.",
            detail: "The terminal will retry automatically once activation completes.",
            scrollback: nil,
            actions: []
        )
    }

    private func scheduleManagedSessionRetryAfterProjectNotReady() {
        loadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.managedSessionRetryDelayNanos)
            } catch {
                return
            }
            guard let self, self.awaitingProjectActivation else { return }
            self.retryAfterProjectActivation()
        }
    }

    private func loadOrRestoreSession() {
        loadTask?.cancel()

        guard let sessionBridge = PaneFactory.sessionBridge else {
            showState(
                title: "Terminal Unavailable",
                message: "Terminal session bridge is not configured.",
                detail: nil,
                scrollback: nil,
                actions: [],
                isLoading: false
            )
            return
        }

        if usesManagedSessions, launchMetadata.remoteTarget == nil {
            switch activationHub.currentState {
            case .opening:
                showProjectActivationPending()
                return
            case .failed(_, _, let message):
                showProjectActivationFailureMessage(message)
                return
            default:
                break
            }
        }

        awaitingProjectActivation = false

        if let sessionID = currentSessionID {
            showState(
                title: "Restoring Session",
                message: "Reattaching to session \(sessionID)...",
                detail: nil,
                scrollback: nil,
                actions: []
            )
            loadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let binding = try await sessionBridge.binding(for: sessionID)
                    await self.apply(binding: binding, isNewSession: false)
                } catch {
                    await self.handleSessionLoadFailure(error)
                }
            }
            return
        }

        guard autoStartIfNeeded, launchMetadata.shouldAutoStart else {
            showDeferredLaunchState()
            return
        }

        switch launchMetadata.launchMode {
        case .managedSession:
            showState(
                title: launchMetadata.remoteTarget == nil ? "Starting Session" : "Starting Remote Session",
                message: launchMetadata.remoteTarget == nil
                    ? "Creating a backend-managed terminal session..."
                    : "Creating a backend-managed remote terminal session...",
                detail: nil,
                scrollback: nil,
                actions: []
            )
            loadTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let binding = try await sessionBridge.createSession(
                        name: self.launchMetadata.remoteTarget == nil ? "Terminal" : "Remote Terminal",
                        workingDirectory: self.shellWorkingDirectory,
                        command: self.managedSessionCommand
                    )
                    await self.apply(binding: binding, isNewSession: true)
                } catch {
                    await self.handleSessionLoadFailure(error)
                }
            }
        case .localShell, .remoteShell:
            showEphemeralTerminal()
        }
    }

    private func handleSessionLoadFailure(_ error: Error) async {
        if launchMetadata.remoteTarget == nil, PnevmaError.isProjectNotReady(error) {
            switch activationHub.currentState {
            case .opening:
                showProjectActivationPending()
            case .failed(_, _, let message):
                showProjectActivationFailureMessage(message)
            case .idle, .closed:
                projectNotReadyRetryCount = 0
                awaitingProjectActivation = false
                showEphemeralTerminal()
            case .open:
                projectNotReadyRetryCount += 1
                if projectNotReadyRetryCount > Self.maxManagedSessionProjectNotReadyRetries {
                    awaitingProjectActivation = false
                    showState(
                        title: "Terminal Error",
                        message: "The project backend is still not ready.",
                        detail: "Try again in a moment.",
                        scrollback: nil,
                        actions: makeFallbackActions(),
                        isLoading: false
                    )
                } else {
                    showProjectActivationPending()
                    scheduleManagedSessionRetryAfterProjectNotReady()
                }
            }
            return
        }
        projectNotReadyRetryCount = 0
        let message = error.localizedDescription

        showState(
            title: "Terminal Error",
            message: message,
            detail: nil,
            scrollback: nil,
            actions: makeFallbackActions(),
            isLoading: false
        )
    }

    private func showDeferredLaunchState() {
        showState(
            title: launchMetadata.remoteTarget == nil ? "Terminal" : "Remote Terminal",
            message: deferredLaunchMessage,
            detail: "Nothing is running in this pane until it becomes active.",
            scrollback: nil,
            actions: [],
            isLoading: false
        )
    }

    private func showEphemeralTerminal() {
        projectNotReadyRetryCount = 0
        let hostView = TerminalHostView()
        hostView.launchConfiguration = .shell(
            workingDirectory: shellWorkingDirectory,
            command: shellCommand
        )
        hostView.onTerminalClose = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleEphemeralTerminalExit()
            }
        }
        hostView.onSurfaceReady = { [weak self] in
            self?.installAgentLauncher()
        }
        hostView.onDesktopNotification = { [weak self] _, _ in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .paneNeedsAttention,
                object: nil,
                userInfo: ["paneID": self.paneID]
            )
        }
        hostView.onBell = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .paneNeedsAttention,
                object: nil,
                userInfo: ["paneID": self.paneID]
            )
        }
        replaceContent(with: hostView)
        self.hostView = hostView
        hostView.ensureSurfaceCreated()
    }

    private func handleEphemeralTerminalExit() {
        launchMetadata = TerminalLaunchMetadata(
            launchMode: launchMetadata.launchMode,
            startBehavior: .deferUntilActivate,
            remoteTarget: launchMetadata.remoteTarget
        )
        notifyPersistedStateChanged()
        showDeferredLaunchState()
    }

    private func apply(binding: SessionBindingDescriptor, isNewSession: Bool) async {
        projectNotReadyRetryCount = 0
        currentSessionID = binding.sessionID
        currentWorkingDirectory = binding.cwd
        recoveryOptions = binding.recoveryOptions
        notifyPersistedStateChanged()

        if binding.isLiveAttach {
            showLiveTerminal(binding, isNewSession: isNewSession)
        } else {
            await showArchivedTerminal(binding)
        }
    }

    private func showLiveTerminal(_ binding: SessionBindingDescriptor, isNewSession: Bool) {
        let hostView = TerminalHostView()
        hostView.launchConfiguration = binding.makeLaunchConfiguration()
        hostView.attachedSessionID = binding.sessionID
        hostView.onTerminalClose = { [weak self] in
            Task { @MainActor [weak self] in
                self?.loadOrRestoreSession()
            }
        }
        let sessionBridge = PaneFactory.sessionBridge
        let boundSessionID = binding.sessionID
        hostView.onTerminalResize = { columns, rows in
            Task {
                await sessionBridge?.sendResize(
                    sessionID: boundSessionID,
                    columns: columns,
                    rows: rows
                )
            }
        }
        if isNewSession {
            hostView.onSurfaceReady = { [weak self] in
                self?.installAgentLauncher()
            }
        }
        hostView.onDesktopNotification = { [weak self] _, _ in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .paneNeedsAttention,
                object: nil,
                userInfo: ["paneID": self.paneID]
            )
        }
        hostView.onBell = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(
                name: .paneNeedsAttention,
                object: nil,
                userInfo: ["paneID": self.paneID]
            )
        }
        replaceContent(with: hostView)
        self.hostView = hostView
        hostView.ensureSurfaceCreated()
    }

    private func showArchivedTerminal(_ binding: SessionBindingDescriptor) async {
        let title = "Session Ended"
        let message = "This terminal session is no longer live."
        let detail = "Restored scrollback is available below. Use a recovery action to restart or reattach the backend session."
        showState(
            title: title,
            message: message,
            detail: detail,
            scrollback: nil,
            actions: recoveryActionButtons(),
            isLoading: false
        )

        guard let sessionBridge = PaneFactory.sessionBridge else { return }
        do {
            let scrollback = try await sessionBridge.scrollback(for: binding.sessionID)
            showState(
                title: title,
                message: message,
                detail: detail,
                scrollback: scrollback.data,
                actions: recoveryActionButtons(),
                isLoading: false
            )
        } catch {
            showState(
                title: "Session Ended",
                message: "Unable to load archived scrollback.",
                detail: error.localizedDescription,
                scrollback: nil,
                actions: recoveryActionButtons(),
                isLoading: false
            )
        }
    }

    private func recoveryActionButtons() -> [TerminalStateAction] {
        guard usesManagedSessions else { return [] }
        return recoveryOptions.map { option in
            TerminalStateAction(
                id: option.id,
                label: option.label,
                enabled: option.enabled
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.performRecoveryAction(option.id)
                }
            }
        } + makeFallbackActions()
    }

    private func makeFallbackActions() -> [TerminalStateAction] {
        guard autoStartIfNeeded, usesManagedSessions else { return [] }
        return [
            TerminalStateAction(id: "new-session", label: "Start New Session", enabled: true) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.currentSessionID = nil
                    self?.notifyPersistedStateChanged()
                    self?.loadOrRestoreSession()
                }
            }
        ]
    }

    private func performRecoveryAction(_ action: String) async {
        guard let sessionID = currentSessionID,
              let sessionBridge = PaneFactory.sessionBridge else {
            return
        }

        showState(
            title: "Recovering Session",
            message: "Running \(action)...",
            detail: nil,
            scrollback: nil,
            actions: []
        )

        do {
            let result = try await sessionBridge.recover(sessionID: sessionID, action: action)
            if let newSessionID = result.newSessionID {
                currentSessionID = newSessionID
                notifyPersistedStateChanged()
            }
            loadOrRestoreSession()
        } catch {
            showState(
                title: "Recovery Failed",
                message: error.localizedDescription,
                detail: nil,
                scrollback: nil,
                actions: recoveryActionButtons(),
                isLoading: false
            )
        }
    }

    private func notifyPersistedStateChanged() {
        onPersistedStateChange?(persistedPane())
    }

    // MARK: - Agent Launcher Overlay

    private func installAgentLauncher() {
        removeAgentLauncher()
        let overlay = AgentLauncherOverlay { [weak self] agent in
            self?.launchAgent(agent)
        }
        let hosting = NSHostingView(rootView: overlay)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        agentLauncherView = hosting

        agentLauncherKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.agentLauncherView != nil,
                  self.window?.firstResponder === self.hostView else { return event }
            self.removeAgentLauncher()
            return event
        }
    }

    private func removeAgentLauncher() {
        agentLauncherView?.removeFromSuperview()
        agentLauncherView = nil
        if let monitor = agentLauncherKeyMonitor {
            NSEvent.removeMonitor(monitor)
            agentLauncherKeyMonitor = nil
        }
    }

    func launchAgent(_ agent: AgentKind) {
        removeAgentLauncher()
        let surface = hostView?.terminalSurface
        surface?.sendText(agent.command)
        surface?.sendReturn()
    }

    private func replaceContent(with view: NSView) {
        hostView?.removeFromSuperview()
        stateHostView?.removeFromSuperview()
        removeAgentLauncher()
        hostView = nil
        stateHostView = nil

        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func showState(
        title: String,
        message: String,
        detail: String?,
        scrollback: String?,
        actions: [TerminalStateAction],
        isLoading: Bool? = nil
    ) {
        let rootView = TerminalStateView(
            title: title,
            message: message,
            detail: detail,
            scrollback: scrollback,
            actions: actions,
            isLoadingOverride: isLoading
        )
        hostView?.removeFromSuperview()
        hostView = nil

        if let stateHostView {
            stateHostView.rootView = rootView
            return
        }

        let stateHostView = NSHostingView(rootView: rootView)
        replaceContent(with: stateHostView)
        self.stateHostView = stateHostView
    }
}

private struct TerminalStateAction: Identifiable {
    let id: String
    let label: String
    let enabled: Bool
    let perform: () -> Void
}

private struct TerminalStateView: View {
    let title: String
    let message: String
    let detail: String?
    let scrollback: String?
    let actions: [TerminalStateAction]
    var isLoadingOverride: Bool? = nil

    private var isLoading: Bool {
        if let override = isLoadingOverride { return override }
        let lower = message.lowercased()
        return lower.contains("connecting") || lower.contains("creating") ||
               lower.contains("reattaching") || lower.contains("loading") ||
               lower.contains("running") || lower.contains("waiting")
    }

    private var hasScrollback: Bool {
        if let scrollback, !scrollback.isEmpty { return true }
        return false
    }

    var body: some View {
        let theme = GhosttyThemeProvider.shared
        ZStack {
            Color(nsColor: theme.backgroundColor).ignoresSafeArea()

            if hasScrollback {
                // Left-aligned scrollable layout for error states with logs
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        stateContent(centered: false)
                        stateActions
                        stateScrollback
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Centered layout for loading/waiting states
                VStack(spacing: 0) {
                    Spacer()
                    VStack(spacing: 18) {
                        stateContent(centered: true)
                        stateActions
                    }
                    .frame(maxWidth: 520)
                    Spacer()
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func stateContent(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 8) {
            Text(title)
                .font(.title.weight(.semibold))
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(message)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var stateActions: some View {
        if !actions.isEmpty {
            HStack(spacing: 10) {
                ForEach(actions) { action in
                    Button(action.label, action: action.perform)
                        .buttonStyle(.borderedProminent)
                        .disabled(!action.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private var stateScrollback: some View {
        if let scrollback, !scrollback.isEmpty {
            ScrollView(.horizontal) {
                Text(scrollback)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black.opacity(0.82))
                    )
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
    }
}

// MARK: - Agent Launcher

enum AgentKind: String {
    case claude
    case codex

    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    var label: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var logoAsset: String {
        switch self {
        case .claude: return "anthropic-logo"
        case .codex: return "openai-logo"
        }
    }
}

private struct AgentLauncherOverlay: View {
    let onSelect: (AgentKind) -> Void

    var body: some View {
        HStack(spacing: 4) {
            AgentLogoButton(agent: .claude, onSelect: onSelect)
            AgentLogoButton(agent: .codex, onSelect: onSelect)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.ultraThinMaterial)
        )
    }
}

private struct AgentLogoButton: View {
    let agent: AgentKind
    let onSelect: (AgentKind) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            onSelect(agent)
        } label: {
            Image(agent.logoAsset)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 14, height: 14)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isHovered ? Color.white.opacity(0.15) : Color.clear)
                )
                .scaleEffect(isHovered ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in isHovered = hovering }
        .help("Launch \(agent.label)")
    }
}
