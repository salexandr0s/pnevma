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

    var presentationRole: PanePresentationRole { get }
}

@MainActor
protocol PanePersistenceObservable: AnyObject {
    var onPersistedStateChange: ((PersistedPane) -> Void)? { get set }
}

@MainActor
protocol TerminalPaneControlling: PaneContent {
    var canLoadExistingSessions: Bool { get }
    func loadSession(sessionID: String, workingDirectory: String?)
    func launchAgent(_ agent: AgentKind)
    func requestCloseDecision(_ completion: @escaping (Bool) -> Void)
}

extension TerminalPaneControlling {
    var canLoadExistingSessions: Bool { !hasActiveProcess }

    func requestCloseDecision(_ completion: @escaping (Bool) -> Void) {
        completion(hasActiveProcess)
    }
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
    var presentationRole: PanePresentationRole { PanePresentationRole(paneType: paneType) }

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

extension RestoredPaneContainer: TerminalPaneControlling {
    var canLoadExistingSessions: Bool {
        (wrapped as? any TerminalPaneControlling)?.canLoadExistingSessions ?? false
    }

    func loadSession(sessionID: String, workingDirectory: String?) {
        (wrapped as? any TerminalPaneControlling)?
            .loadSession(sessionID: sessionID, workingDirectory: workingDirectory)
    }

    func launchAgent(_ agent: AgentKind) {
        (wrapped as? any TerminalPaneControlling)?.launchAgent(agent)
    }

    func requestCloseDecision(_ completion: @escaping (Bool) -> Void) {
        (wrapped as? any TerminalPaneControlling)?
            .requestCloseDecision(completion)
            ?? completion(hasActiveProcess)
    }
}

/// Registry of known pane types and their factory methods.
@MainActor
enum PaneFactory {
    static var sessionBridge: (any SessionBridging)?
    static var activeWorkspaceProvider: (() -> Workspace?)?
    static var browserSessionProvider: ((Workspace) -> BrowserWorkspaceSession)?
    /// Set to true during app shutdown so dispose() skips killing durable sessions.
    static var isAppShuttingDown = false

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

    static func makeTaskBoard(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(TaskBoardPaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makeReplay(
        sessionID: String? = nil,
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(ReplayPaneView(frame: .zero, sessionID: sessionID, chromeContext: chromeContext))
    }

    static func makeFileBrowser() -> (PaneID, NSView & PaneContent) {
        paneTuple(FileBrowserPaneView(frame: .zero))
    }

    static func makeSshManager(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(SshManagerPaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makeWorkflow(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(WorkflowPaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makeReview(initialTaskID: String? = nil) -> (PaneID, NSView & PaneContent) {
        paneTuple(ReviewPaneView(frame: .zero, initialTaskID: initialTaskID))
    }

    static func makeDiff(initialTaskID: String? = nil) -> (PaneID, NSView & PaneContent) {
        paneTuple(DiffPaneView(frame: .zero, initialTaskID: initialTaskID))
    }

    static func makeAnalytics(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(UsagePaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makeResourceMonitor(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(ResourceMonitorPaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makeSettings() -> (PaneID, NSView & PaneContent) {
        paneTuple(SettingsPaneView(frame: .zero))
    }

    static func makeNotifications(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(NotificationsPaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makeDailyBrief(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(DailyBriefPaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makeRulesManager(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(RulesManagerPaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makeSecretsManager(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(SecretsManagerPaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makeBrowser(url: URL? = nil) -> (PaneID, NSView & PaneContent) {
        let workspace = activeWorkspaceProvider?()
        let session = workspace.flatMap { browserSessionProvider?($0) }
            ?? BrowserWorkspaceSession(restoredURL: url)
        if let url {
            session.updateRestoredURL(url)
        }
        return paneTuple(BrowserPaneView(frame: .zero, session: session, url: url))
    }

    static func makeHarnessConfig(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(HarnessConfigPaneView(frame: .zero, chromeContext: chromeContext))
    }

    static func makePorts(
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(PortsPaneView(paneID: PaneID(), chromeContext: chromeContext))
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
        case "diff":
            inner = DiffPaneView(frame: .zero)
        case "analytics":
            inner = UsagePaneView(frame: .zero)
        case "resource_monitor":
            inner = ResourceMonitorPaneView(frame: .zero)
        case "settings":
            inner = SettingsPaneView(frame: .zero)
        case "notifications":
            inner = NotificationsPaneView(frame: .zero)
        case "daily_brief":
            inner = DailyBriefPaneView(frame: .zero)
        case "rules":
            inner = RulesManagerPaneView(frame: .zero)
        case "secrets":
            inner = SecretsManagerPaneView(frame: .zero)
        case "browser":
            inner = BrowserPaneView.fromMetadata(persistedPane.metadataJSON)
        case "harness_config":
            inner = HarnessConfigPaneView(frame: .zero)
        case "ports":
            inner = PortsPaneView(paneID: persistedPane.paneID)
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
    static func make(
        type paneType: String,
        chromeContext: PaneChromeContext = .standard
    ) -> (PaneID, NSView & PaneContent)? {
        guard isPaneTypeAvailable(paneType, in: activeWorkspaceProvider?()) else {
            return nil
        }
        switch paneType {
        case "welcome":       return makeWelcome()
        case "terminal":      return workspaceAwareTerminal()
        case "taskboard":     return makeTaskBoard(chromeContext: chromeContext)
        case "replay":        return makeReplay(chromeContext: chromeContext)
        case "file_browser":  return makeFileBrowser()
        case "ssh":           return makeSshManager(chromeContext: chromeContext)
        case "workflow":      return makeWorkflow(chromeContext: chromeContext)
        case "review":        return makeReview()
        case "diff":          return makeDiff()
        case "analytics":     return makeAnalytics(chromeContext: chromeContext)
        case "resource_monitor": return makeResourceMonitor(chromeContext: chromeContext)
        case "settings":      return makeSettings()
        case "notifications": return makeNotifications(chromeContext: chromeContext)
        case "daily_brief":   return makeDailyBrief(chromeContext: chromeContext)
        case "rules":         return makeRulesManager(chromeContext: chromeContext)
        case "secrets":       return makeSecretsManager(chromeContext: chromeContext)
        case "browser":        return makeBrowser()
        case "harness_config": return makeHarnessConfig(chromeContext: chromeContext)
        case "ports":          return makePorts(chromeContext: chromeContext)
        default:              return nil
        }
    }

    static func isPaneTypeAvailable(_ paneType: String, in workspace: Workspace?) -> Bool {
        availablePaneTypes(for: workspace).contains(paneType)
    }

    static func availablePaneTypes(for workspace: Workspace?) -> Set<String> {
        guard let workspace else {
            return ["terminal", "ssh", "workflow", "notifications", "browser", "analytics", "resource_monitor", "harness_config"]
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
                "review",
                "diff",
                "analytics",
                "resource_monitor",
                "daily_brief",
                "rules",
                "secrets",
                "harness_config",
                "ports",
            ]
        }
        return [
            "terminal",
            "ssh",
            "workflow",
            "notifications",
            "browser",
            "analytics",
            "resource_monitor",
            "harness_config",
        ]
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
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            if let message {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
final class TerminalPaneView: NSView, PaneContent, PanePersistenceObservable, TerminalPaneControlling {
    private static let maxManagedSessionProjectNotReadyRetries = 5
    private static let managedSessionRetryDelay: Duration = .milliseconds(250)
    private static let maxLiveAttachStartupRetries = 2
    private static let liveAttachRetryDelay: Duration = .milliseconds(250)
    private static let liveAttachStartupWindow: Duration = .seconds(2)

    let paneID = PaneID()
    let paneType = "terminal"
    var title: String { "Terminal" }

    private struct LiveAttachStartupState {
        let sessionID: String
        var retryCount: Int
        var deadline: ContinuousClock.Instant
    }

    private var hostView: TerminalHostView?
    private var stateHostView: NSHostingView<TerminalStateView>?
    private var agentLauncherView: AgentLauncherOverlayView?
    private var agentLauncherKeyMonitor: Any?
    private var agentLauncherMouseMonitor: Any?
    private var isTrackingAgentLauncherInteraction = false
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
    private var isPaneActive = false
    private let activationHub: ActiveWorkspaceActivationHub
    private(set) var currentStateSnapshot: TerminalStateSnapshot?
    private var liveAttachStartupState: LiveAttachStartupState?
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
        setAccessibilityIdentifier("pane.terminal")
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let agentLauncherView, !agentLauncherView.isHidden, agentLauncherView.frame.contains(point) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard routeAgentLauncherPointerEvent(event, phase: .began) else {
            super.mouseDown(with: event)
            return
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard routeAgentLauncherPointerEvent(event, phase: .changed) else {
            super.mouseDragged(with: event)
            return
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard routeAgentLauncherPointerEvent(event, phase: .ended) else {
            super.mouseUp(with: event)
            return
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncHostViewFocus()
    }

    override func becomeFirstResponder() -> Bool {
        guard let hostView else {
            return super.becomeFirstResponder()
        }
        return window?.makeFirstResponder(hostView) ?? false
    }

    func activate() {
        isPaneActive = true
        if hostView == nil, currentSessionID == nil, !launchMetadata.shouldAutoStart {
            launchMetadata = TerminalLaunchMetadata(
                launchMode: launchMetadata.launchMode,
                startBehavior: .immediate,
                remoteTarget: launchMetadata.remoteTarget,
                backendPaneID: launchMetadata.backendPaneID,
                agentTeamID: launchMetadata.agentTeamID,
                agentTeamRole: launchMetadata.agentTeamRole,
                agentTeamMemberIndex: launchMetadata.agentTeamMemberIndex
            )
            notifyPersistedStateChanged()
            loadOrRestoreSession()
            return
        }
        syncHostViewFocus()
    }

    func deactivate() {
        isPaneActive = false
        if let hostView {
            if window?.firstResponder === hostView {
                window?.makeFirstResponder(nil)
            }
            hostView.setPaneFocused(false)
        }
    }

    /// A terminal pane has an active process while Ghostty reports that the
    /// foreground process has not exited yet.
    var hasActiveProcess: Bool {
        hostView?.terminalSurface.map { !$0.processExited } ?? false
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
        hostView?.closeSurfaceSilently()
        // Kill the backend session on explicit tab close so durable sessions don't pile up.
        // During app quit, sessions are preserved for reattach on relaunch.
        if !PaneFactory.isAppShuttingDown,
           let sessionID = currentSessionID,
           let bridge = PaneFactory.sessionBridge
        {
            Task {
                await bridge.killSession(sessionID: sessionID)
            }
        }
    }

    var workingDirectory: String? { currentWorkingDirectory }
    var sessionID: String? { currentSessionID }
    var metadataJSON: String? { launchMetadata.encodedJSON() }

    var onTerminalClose: (() -> Void)? {
        get {
            guard let hostView else { return nil }
            return {
                hostView.onTerminalClose?(false)
            }
        }
        set {
            hostView?.onTerminalClose = { _ in
                newValue?()
            }
        }
    }

    func requestCloseDecision(_ completion: @escaping (Bool) -> Void) {
        completion(hasActiveProcess)
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
        nil
    }

    private var shellWorkingDirectory: String? {
        if let remoteTarget = launchMetadata.remoteTarget {
            return remoteTarget.remotePath
        }
        return currentWorkingDirectory ?? NSHomeDirectory()
    }

    private var shellCommand: String? {
        if let remoteTarget = launchMetadata.remoteTarget {
            return remoteTarget.remoteShellCommand
        }
        return localInteractiveShellCommand
    }

    private var localInteractiveShellCommand: String {
        let shellPath = AppRuntimeSettings.shared.normalizedDefaultShell?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedShell = (shellPath?.isEmpty == false)
            ? shellPath!
            : (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        return "\(resolvedShell) -i"
    }

    private func resolvedManagedSessionMetadata() -> TerminalLaunchMetadata {
        if let workspace = PaneFactory.activeWorkspaceProvider?() {
            return workspace.defaultTerminalMetadata(startBehavior: .immediate)
        }

        return TerminalLaunchMetadata(
            launchMode: .managedSession,
            startBehavior: .immediate,
            remoteTarget: launchMetadata.remoteTarget,
            backendPaneID: launchMetadata.backendPaneID,
            agentTeamID: launchMetadata.agentTeamID,
            agentTeamRole: launchMetadata.agentTeamRole,
            agentTeamMemberIndex: launchMetadata.agentTeamMemberIndex
        )
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
                try await Task.sleep(for: Self.managedSessionRetryDelay)
            } catch {
                return
            }
            guard let self, self.awaitingProjectActivation else { return }
            self.retryAfterProjectActivation()
        }
    }

    private func loadOrRestoreSession() {
        loadTask?.cancel()

        if AppLaunchContext.uiTestLightweightMode {
            projectNotReadyRetryCount = 0
            awaitingProjectActivation = false
            showState(
                title: initialStateTitle,
                message: "Terminal preview is disabled during UI smoke tests.",
                detail: "Pnevma uses a lightweight placeholder terminal here so UI automation can bootstrap quickly and deterministically.",
                scrollback: nil,
                actions: [],
                isLoading: false
            )
            return
        }

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
                    if PnevmaError.isMissingSession(error) {
                        self.currentSessionID = nil
                        self.notifyPersistedStateChanged()
                        await self.handleSessionLoadFailure(
                            SessionBridgeError.staleSession(sessionID)
                        )
                    } else {
                        await self.handleSessionLoadFailure(error)
                    }
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
                        command: self.managedSessionCommand,
                        remoteTarget: self.launchMetadata.remoteTarget
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
        liveAttachStartupState = nil
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
        liveAttachStartupState = nil
        currentStateSnapshot = nil
        let hostView = TerminalHostView()
        hostView.launchConfiguration = .shell(
            workingDirectory: shellWorkingDirectory,
            command: shellCommand
        )
        hostView.onTerminalClose = { [weak self] _ in
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
        syncHostViewFocus()
        hostView.ensureSurfaceCreated()
    }

    private func handleEphemeralTerminalExit() {
        launchMetadata = TerminalLaunchMetadata(
            launchMode: launchMetadata.launchMode,
            startBehavior: .deferUntilActivate,
            remoteTarget: launchMetadata.remoteTarget,
            backendPaneID: launchMetadata.backendPaneID,
            agentTeamID: launchMetadata.agentTeamID,
            agentTeamRole: launchMetadata.agentTeamRole,
            agentTeamMemberIndex: launchMetadata.agentTeamMemberIndex
        )
        notifyPersistedStateChanged()
        showDeferredLaunchState()
    }

    private func noteLiveAttachAttemptStarted(sessionID: String) {
        if var state = liveAttachStartupState, state.sessionID == sessionID {
            state.deadline = ContinuousClock.now + Self.liveAttachStartupWindow
            liveAttachStartupState = state
            return
        }

        liveAttachStartupState = LiveAttachStartupState(
            sessionID: sessionID,
            retryCount: 0,
            deadline: ContinuousClock.now + Self.liveAttachStartupWindow
        )
    }

    private func handleLiveAttachSurfaceClose(sessionID: String) {
        guard var state = liveAttachStartupState,
              state.sessionID == sessionID,
              ContinuousClock.now <= state.deadline else {
            liveAttachStartupState = nil
            loadOrRestoreSession()
            return
        }

        if state.retryCount < Self.maxLiveAttachStartupRetries {
            state.retryCount += 1
            liveAttachStartupState = state
            showState(
                title: "Reattaching Session",
                message: "Retrying terminal attach for session \(sessionID)...",
                detail: "The live terminal exited before it became stable. Pnevma will retry automatically.",
                scrollback: nil,
                actions: []
            )
            loadTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: Self.liveAttachRetryDelay)
                } catch {
                    return
                }
                guard let self, self.currentSessionID == sessionID else { return }
                self.loadTask = nil
                self.loadOrRestoreSession()
            }
            return
        }

        liveAttachStartupState = nil
        showState(
            title: "Terminal Attach Failed",
            message: "Pnevma couldn't keep the live terminal attached.",
            detail: "The backend session ID was preserved. Retry to reconnect to the existing session, or start a new one if the attach keeps failing.",
            scrollback: nil,
            actions: makeAttachFailureActions(),
            isLoading: false
        )
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
            liveAttachStartupState = nil
            await showArchivedTerminal(binding)
        }
    }

    private func showLiveTerminal(_ binding: SessionBindingDescriptor, isNewSession: Bool) {
        currentStateSnapshot = nil
        noteLiveAttachAttemptStarted(sessionID: binding.sessionID)
        let hostView = TerminalHostView()
        if let config = binding.makeLaunchConfiguration() {
            hostView.launchConfiguration = config
        }
        hostView.attachedSessionID = binding.sessionID
        hostView.onTerminalClose = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleLiveAttachSurfaceClose(sessionID: binding.sessionID)
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
        syncHostViewFocus()
        hostView.ensureSurfaceCreated()
    }

    private func showArchivedTerminal(_ binding: SessionBindingDescriptor) async {
        liveAttachStartupState = nil
        let stateCopy = archivedTerminalStateCopy(for: binding)
        let actions = recoveryActionButtons(preferRestorePrimary: true)
        showState(
            title: stateCopy.title,
            message: stateCopy.message,
            detail: stateCopy.detail,
            scrollback: nil,
            actions: actions,
            isLoading: false
        )

        guard let sessionBridge = PaneFactory.sessionBridge else { return }
        do {
            let scrollback = try await sessionBridge.scrollback(for: binding.sessionID)
            showState(
                title: stateCopy.title,
                message: stateCopy.message,
                detail: stateCopy.detail,
                scrollback: scrollback.data,
                actions: actions,
                isLoading: false
            )
        } catch {
            showState(
                title: "Session Ended",
                message: "Unable to load archived scrollback.",
                detail: error.localizedDescription,
                scrollback: nil,
                actions: actions,
                isLoading: false
            )
        }
    }

    private func archivedTerminalStateCopy(
        for binding: SessionBindingDescriptor
    ) -> (title: String, message: String, detail: String) {
        let canReattach = recoveryOptions.contains(where: { $0.id == "reattach" && $0.enabled })
        let canRestart = recoveryOptions.contains(where: { $0.id == "restart" && $0.enabled })

        if binding.isDetachedRecovery || canReattach {
            let detail: String
            if canRestart {
                detail = "Use Restore Previous Session to reattach if the backend is still running, or restart it if it has already stopped. A cleaned transcript snapshot is shown below when available."
            } else {
                detail = "Use Restore Previous Session to reattach to the preserved backend."
            }
            return (
                title: "Session Detached",
                message: "This terminal session can reconnect.",
                detail: detail
            )
        }

        let detail: String
        if canRestart {
            detail = "A cleaned transcript snapshot is shown below. Use Restore Previous Session to start a replacement managed session, or start a new session."
        } else {
            detail = "A cleaned transcript snapshot is shown below when available."
        }
        return (
            title: "Session Ended",
            message: "This terminal session is no longer live.",
            detail: detail
        )
    }

    private func recoveryActionButtons(preferRestorePrimary: Bool = false) -> [TerminalStateAction] {
        guard usesManagedSessions else { return [] }
        if preferRestorePrimary, let restoreAction = restorePreviousActionButton() {
            return [restoreAction] + makeFallbackActions()
        }
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
            TerminalStateAction(
                id: "new-session",
                label: "Start New Session",
                enabled: true,
                isPrimary: false
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.currentSessionID = nil
                    self?.notifyPersistedStateChanged()
                    self?.loadOrRestoreSession()
                }
            }
        ]
    }

    private func makeAttachFailureActions() -> [TerminalStateAction] {
        [
            TerminalStateAction(
                id: "retry-attach",
                label: "Retry",
                enabled: true
            ) { [weak self] in
                Task { @MainActor [weak self] in
                    self?.loadOrRestoreSession()
                }
            }
        ] + makeFallbackActions()
    }

    private func restorePreviousActionButton() -> TerminalStateAction? {
        guard let actionID = preferredRestoreActionID() else { return nil }
        return TerminalStateAction(
            id: "restore-previous",
            label: "Restore Previous Session",
            enabled: true
        ) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.performRecoveryAction(actionID)
            }
        }
    }

    private func preferredRestoreActionID() -> String? {
        if recoveryOptions.contains(where: { $0.id == "reattach" && $0.enabled }) {
            return "reattach"
        }
        if recoveryOptions.contains(where: { $0.id == "restart" && $0.enabled }) {
            return "restart"
        }
        return nil
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
        let overlay = AgentLauncherOverlayView { [weak self] agent in
            self?.launchAgent(agent)
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
        ])
        agentLauncherView = overlay

        agentLauncherKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.agentLauncherView != nil,
                  self.window?.firstResponder === self.hostView else { return event }
            if !Self.shouldDismissAgentLauncher(for: event) {
                return event
            }
            self.removeAgentLauncher()
            return event
        }

        agentLauncherMouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self, self.agentLauncherView != nil, event.window == self.window else {
                return event
            }
            guard let phase = Self.agentLauncherPointerPhase(for: event.type) else {
                return event
            }
            return self.routeAgentLauncherPointerEvent(event, phase: phase) ? nil : event
        }
    }

    private func removeAgentLauncher() {
        isTrackingAgentLauncherInteraction = false
        agentLauncherView?.cancelInteraction()
        agentLauncherView?.removeFromSuperview()
        agentLauncherView = nil
        if let monitor = agentLauncherKeyMonitor {
            NSEvent.removeMonitor(monitor)
            agentLauncherKeyMonitor = nil
        }
        if let monitor = agentLauncherMouseMonitor {
            NSEvent.removeMonitor(monitor)
            agentLauncherMouseMonitor = nil
        }
    }

    func loadSession(sessionID: String, workingDirectory: String? = nil) {
        guard canLoadExistingSessions else { return }

        loadTask?.cancel()
        currentSessionID = sessionID
        if let workingDirectory {
            currentWorkingDirectory = workingDirectory
        }
        launchMetadata = resolvedManagedSessionMetadata()
        recoveryOptions = []
        notifyPersistedStateChanged()
        loadOrRestoreSession()
    }

    func launchAgent(_ agent: AgentKind) {
        removeAgentLauncher()
        let surface = hostView?.terminalSurface
        surface?.sendText(agent.command)
        surface?.sendReturn()
        syncHostViewFocus()
    }

    static func shouldDismissAgentLauncher(for event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !modifiers.contains(.command)
            && !modifiers.contains(.control)
            && !modifiers.contains(.option)
    }

    var hasAgentLauncherOverlay: Bool {
        agentLauncherView != nil
    }

    func installAgentLauncherForTesting() {
        installAgentLauncher()
    }

    private enum AgentLauncherPointerPhase {
        case began
        case changed
        case ended
    }

    private static func agentLauncherPointerPhase(for eventType: NSEvent.EventType) -> AgentLauncherPointerPhase? {
        switch eventType {
        case .leftMouseDown:
            return .began
        case .leftMouseDragged:
            return .changed
        case .leftMouseUp:
            return .ended
        default:
            return nil
        }
    }

    private func routeAgentLauncherPointerEvent(_ event: NSEvent, phase: AgentLauncherPointerPhase) -> Bool {
        guard let agentLauncherView, !agentLauncherView.isHidden else {
            isTrackingAgentLauncherInteraction = false
            return false
        }

        let point = convert(event.locationInWindow, from: nil)
        let isInsideOverlay = agentLauncherView.frame.contains(point)
        guard isTrackingAgentLauncherInteraction || isInsideOverlay else {
            return false
        }

        let overlayPoint = convert(point, to: agentLauncherView)
        switch phase {
        case .began:
            isTrackingAgentLauncherInteraction = true
            agentLauncherView.beginInteraction(at: overlayPoint)
        case .changed:
            agentLauncherView.continueInteraction(at: overlayPoint)
        case .ended:
            agentLauncherView.endInteraction(at: overlayPoint)
            isTrackingAgentLauncherInteraction = false
        }
        return true
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

    private func syncHostViewFocus() {
        guard let hostView else { return }
        hostView.setPaneFocused(isPaneActive)
        guard isPaneActive, window?.firstResponder !== hostView else { return }
        window?.makeFirstResponder(hostView)
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
        currentStateSnapshot = TerminalStateSnapshot(
            title: title,
            message: message,
            detail: detail,
            scrollback: scrollback,
            actionIDs: actions.map(\.id)
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
    var isPrimary: Bool = true
    let perform: () -> Void
}

struct TerminalStateSnapshot: Equatable {
    let title: String
    let message: String
    let detail: String?
    let scrollback: String?
    let actionIDs: [String]
}

struct TerminalArchivedScrollbackPresentation: Equatable {
    let text: String
    let didNormalizeOutput: Bool
    let omittedRepeatedLineCount: Int
    let omittedBlankLineCount: Int

    var hasReadableContent: Bool { !text.isEmpty }

    var note: String? {
        var parts: [String] = []
        if didNormalizeOutput {
            parts.append("Terminal control sequences were removed for readability.")
        }
        if omittedRepeatedLineCount > 0 {
            parts.append(
                "\(omittedRepeatedLineCount) repeated line\(omittedRepeatedLineCount == 1 ? "" : "s") omitted."
            )
        }
        if omittedBlankLineCount > 0 {
            parts.append(
                "\(omittedBlankLineCount) blank line\(omittedBlankLineCount == 1 ? "" : "s") collapsed."
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

enum TerminalArchivedScrollbackFormatter {
    static func presentation(for raw: String) -> TerminalArchivedScrollbackPresentation {
        let normalized = renderVisibleText(from: raw)
        let collapsed = collapseNoise(in: normalized.text)
        return TerminalArchivedScrollbackPresentation(
            text: collapsed.text.trimmingCharacters(in: .whitespacesAndNewlines),
            didNormalizeOutput: normalized.didNormalizeOutput,
            omittedRepeatedLineCount: collapsed.omittedRepeatedLineCount,
            omittedBlankLineCount: collapsed.omittedBlankLineCount
        )
    }

    private struct RenderedText {
        let text: String
        let didNormalizeOutput: Bool
    }

    private struct CollapsedText {
        let text: String
        let omittedRepeatedLineCount: Int
        let omittedBlankLineCount: Int
    }

    private static func renderVisibleText(from raw: String) -> RenderedText {
        let scalars = Array(raw.unicodeScalars)
        var index = 0
        var lines: [String] = []
        var currentLine = ""
        var didNormalizeOutput = false

        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x1B:
                didNormalizeOutput = true
                index = consumeEscapeSequence(in: scalars, from: index)
            case 0x0D:
                if index + 1 < scalars.count, scalars[index + 1].value == 0x0A {
                    lines.append(currentLine)
                    currentLine.removeAll(keepingCapacity: true)
                    index += 2
                } else {
                    didNormalizeOutput = true
                    currentLine.removeAll(keepingCapacity: true)
                    index += 1
                }
            case 0x0A:
                lines.append(currentLine)
                currentLine.removeAll(keepingCapacity: true)
                index += 1
            case 0x08, 0x7F:
                didNormalizeOutput = true
                if !currentLine.isEmpty {
                    currentLine.removeLast()
                }
                index += 1
            case 0x09:
                currentLine.append("\t")
                index += 1
            default:
                if CharacterSet.controlCharacters.contains(scalar) {
                    didNormalizeOutput = true
                } else {
                    currentLine.unicodeScalars.append(scalar)
                }
                index += 1
            }
        }

        if !currentLine.isEmpty || !lines.isEmpty {
            lines.append(currentLine)
        }

        return RenderedText(text: lines.joined(separator: "\n"), didNormalizeOutput: didNormalizeOutput)
    }

    private static func consumeEscapeSequence(in scalars: [UnicodeScalar], from escapeIndex: Int) -> Int {
        let nextIndex = escapeIndex + 1
        guard nextIndex < scalars.count else { return nextIndex }

        switch scalars[nextIndex].value {
        case 0x5B:
            var index = nextIndex + 1
            while index < scalars.count {
                if (0x40...0x7E).contains(scalars[index].value) {
                    return index + 1
                }
                index += 1
            }
            return index
        case 0x5D, 0x50, 0x58, 0x5E, 0x5F:
            var index = nextIndex + 1
            while index < scalars.count {
                if scalars[index].value == 0x07 {
                    return index + 1
                }
                if scalars[index].value == 0x1B,
                   index + 1 < scalars.count,
                   scalars[index + 1].value == 0x5C {
                    return index + 2
                }
                index += 1
            }
            return index
        case 0x28, 0x29, 0x2A, 0x2B, 0x2D, 0x2E, 0x2F:
            return min(nextIndex + 2, scalars.count)
        default:
            return nextIndex + 1
        }
    }

    private static func collapseNoise(in text: String) -> CollapsedText {
        let inputLines = text.components(separatedBy: "\n")
        var outputLines: [String] = []
        var previousVisibleLine: String?
        var repeatedCount = 0
        var omittedRepeatedLineCount = 0
        var blankRunCount = 0
        var omittedBlankLineCount = 0

        func flushRepeatedLines() {
            guard repeatedCount > 0 else { return }
            outputLines.append(
                "... \(repeatedCount) repeated line\(repeatedCount == 1 ? "" : "s") omitted"
            )
            omittedRepeatedLineCount += repeatedCount
            repeatedCount = 0
        }

        for rawLine in inputLines {
            let line = rawLine.replacingOccurrences(
                of: #"\s+$"#,
                with: "",
                options: .regularExpression
            )
            let isBlank = line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if isBlank {
                flushRepeatedLines()
                blankRunCount += 1
                if blankRunCount == 1 {
                    outputLines.append("")
                } else {
                    omittedBlankLineCount += 1
                }
                previousVisibleLine = nil
                continue
            }

            blankRunCount = 0
            if line == previousVisibleLine {
                repeatedCount += 1
                continue
            }

            flushRepeatedLines()
            outputLines.append(line)
            previousVisibleLine = line
        }

        flushRepeatedLines()

        while outputLines.first?.isEmpty == true {
            outputLines.removeFirst()
        }
        while outputLines.last?.isEmpty == true {
            outputLines.removeLast()
        }

        return CollapsedText(
            text: outputLines.joined(separator: "\n"),
            omittedRepeatedLineCount: omittedRepeatedLineCount,
            omittedBlankLineCount: omittedBlankLineCount
        )
    }
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

    private var archivedScrollback: TerminalArchivedScrollbackPresentation? {
        guard let scrollback, !scrollback.isEmpty else { return nil }
        return TerminalArchivedScrollbackFormatter.presentation(for: scrollback)
    }

    private var hasScrollback: Bool {
        archivedScrollback != nil
    }

    var body: some View {
        let theme = GhosttyThemeProvider.shared
        return GeometryReader { proxy in
            ZStack {
                Color(nsColor: theme.backgroundColor).ignoresSafeArea()

                if hasScrollback {
                    ScrollView {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)

                            VStack(alignment: .leading, spacing: 18) {
                                stateStatusCard
                                stateActionsCard
                                stateScrollbackCard
                            }
                            .frame(maxWidth: 760)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 28)

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height)
                        .accessibilityIdentifier("terminalState.archived")
                    }
                }
                else {
                    VStack(spacing: 0) {
                        Spacer()
                        VStack(spacing: 18) {
                            stateContent(centered: true)
                            stateActionsBody
                        }
                        .frame(maxWidth: 520)
                        Spacer()
                        Spacer()
                    }
                }
            }
        }
    }

    private var stateStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            stateContent(centered: false)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
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
    private var stateActionsCard: some View {
        if !actions.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recovery Actions")
                    .font(.headline)
                stateActionsBody
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    @ViewBuilder
    private var stateActionsBody: some View {
        if !actions.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    stateActionButtons
                }

                VStack(alignment: .leading, spacing: 10) {
                    stateActionButtons
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var stateActionButtons: some View {
        ForEach(actions) { action in
            if action.isPrimary {
                Button(action.label, action: action.perform)
                    .buttonStyle(BorderedProminentButtonStyle())
                    .disabled(!action.enabled)
                    .fixedSize()
            } else {
                Button(action.label, action: action.perform)
                    .buttonStyle(BorderedButtonStyle())
                    .disabled(!action.enabled)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private var stateScrollbackCard: some View {
        if let archivedScrollback {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recovered Transcript")
                            .font(.headline)
                        if let note = archivedScrollback.note {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if archivedScrollback.hasReadableContent {
                        Button("Copy Transcript") {
                            copyTranscriptToPasteboard(archivedScrollback.text)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }

                if archivedScrollback.hasReadableContent {
                    ScrollView(.horizontal) {
                        Text(archivedScrollback.text)
                            .font(.system(.body, design: .monospaced))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                } else {
                    Text("No readable transcript could be recovered from the archived terminal bytes.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(transcriptBackground)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
    }

    private var transcriptBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.black.opacity(0.26))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func copyTranscriptToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

final class AgentLauncherOverlayView: NSVisualEffectView {
    private let claudeButton: AgentLauncherLogoButton
    private let codexButton: AgentLauncherLogoButton
    private var trackedButton: AgentLauncherLogoButton?

    init(onSelect: @escaping (AgentKind) -> Void) {
        claudeButton = AgentLauncherLogoButton(agent: .claude, onSelect: onSelect)
        codexButton = AgentLauncherLogoButton(agent: .codex, onSelect: onSelect)
        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        if AccessibilityCheck.prefersReducedTransparency {
            layer?.backgroundColor = ChromeSurfaceStyle.pane.baseColor.cgColor
        }
        setAccessibilityIdentifier("terminal.agentLauncher.overlay")

        let stack = NSStackView(views: [claudeButton, codexButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        beginInteraction(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        continueInteraction(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        endInteraction(at: convert(event.locationInWindow, from: nil))
    }

    func beginInteraction(at point: NSPoint) {
        trackedButton = button(at: point)
        updateButtonHighlight(at: point)
    }

    func continueInteraction(at point: NSPoint) {
        updateButtonHighlight(at: point)
    }

    func endInteraction(at point: NSPoint) {
        defer { cancelInteraction() }
        guard let trackedButton, trackedButton === button(at: point) else { return }
        trackedButton.triggerSelection()
    }

    func cancelInteraction() {
        trackedButton = nil
        claudeButton.setPressedAppearance(false)
        codexButton.setPressedAppearance(false)
    }

    private func button(at point: NSPoint) -> AgentLauncherLogoButton? {
        [claudeButton, codexButton].first { button in
            let expandedFrame = button.frame.insetBy(dx: -4, dy: -4)
            return expandedFrame.contains(point)
        }
    }

    private func updateButtonHighlight(at point: NSPoint) {
        claudeButton.setPressedAppearance(claudeButton === trackedButton && claudeButton === button(at: point))
        codexButton.setPressedAppearance(codexButton === trackedButton && codexButton === button(at: point))
    }
}

final class AgentLauncherLogoButton: NSButton {
    private let agent: AgentKind
    private let onSelect: (AgentKind) -> Void

    init(agent: AgentKind, onSelect: @escaping (AgentKind) -> Void) {
        self.agent = agent
        self.onSelect = onSelect
        super.init(frame: .zero)

        bezelStyle = .regularSquare
        isBordered = false
        focusRingType = .none
        image = NSImage(named: NSImage.Name(agent.logoAsset))
        image?.size = NSSize(width: 14, height: 14)
        imageScaling = .scaleProportionallyUpOrDown
        imagePosition = .imageOnly
        toolTip = "Launch \(agent.label)"
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityLabel("Launch \(agent.label)")
        setAccessibilityIdentifier("terminal.agentLauncher.\(agent.rawValue)")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setPressedAppearance(_ isPressed: Bool) {
        layer?.backgroundColor = isPressed
            ? NSColor.white.withAlphaComponent(0.15).cgColor
            : NSColor.clear.cgColor
    }

    func triggerSelection() {
        onSelect(agent)
    }
}
