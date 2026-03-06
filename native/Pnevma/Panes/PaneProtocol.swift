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
    var shouldPersist: Bool { get }

    /// Called when this pane becomes the active (focused) pane.
    func activate()

    /// Called when another pane takes focus.
    func deactivate()

    /// Called before the pane is removed from the layout. Clean up resources.
    func dispose()
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
    var shouldPersist: Bool { wrapped.shouldPersist }

    func activate() { wrapped.activate() }
    func deactivate() { wrapped.deactivate() }
    func dispose() { wrapped.dispose() }
}

extension RestoredPaneContainer: PanePersistenceObservable {
    var onPersistedStateChange: ((PersistedPane) -> Void)? {
        get { (wrapped as? PanePersistenceObservable)?.onPersistedStateChange }
        set { (wrapped as? PanePersistenceObservable)?.onPersistedStateChange = newValue }
    }
}

/// Registry of known pane types and their factory methods.
@MainActor
enum PaneFactory {
    static var sessionBridge: SessionBridge?
    private static func paneTuple(_ view: NSView & PaneContent) -> (PaneID, NSView & PaneContent) {
        (view.paneID, view)
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
        autoStartIfNeeded: Bool = true
    ) -> (PaneID, NSView & PaneContent) {
        paneTuple(TerminalPaneView(
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            autoStartIfNeeded: autoStartIfNeeded
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
        paneTuple(AnalyticsPaneView(frame: .zero))
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

    static func make(from persistedPane: PersistedPane) -> (PaneID, NSView & PaneContent) {
        let inner: (NSView & PaneContent)
        switch persistedPane.type {
        case "terminal":
            inner = TerminalPaneView(
                workingDirectory: persistedPane.workingDirectory,
                sessionID: persistedPane.sessionID,
                autoStartIfNeeded: true
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
            inner = AnalyticsPaneView(frame: .zero)
        case "settings":
            inner = SettingsPaneView(frame: .zero)
        case "notifications":
            inner = NotificationsPaneView(frame: .zero)
        case "daily_brief":
            inner = DailyBriefPaneView(frame: .zero)
        case "rules":
            inner = RulesManagerPaneView(frame: .zero)
        default:
            inner = ReplayPaneView(frame: .zero, sessionID: persistedPane.sessionID)
        }

        let wrapped = RestoredPaneContainer(persisted: persistedPane, wrapped: inner)
        return (wrapped.paneID, wrapped)
    }

    /// Create a pane by type string.
    static func make(type paneType: String) -> (PaneID, NSView & PaneContent)? {
        switch paneType {
        case "welcome":       return makeWelcome()
        case "terminal":      return makeTerminal()
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
        default:              return nil
        }
    }
}

// MARK: - WelcomePaneView

final class WelcomePaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "welcome"
    var title: String { "Welcome" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(
            TerminalStateView(
                title: "Workspace Ready",
                message: "Open a project to start a backend-managed terminal session.",
                detail: nil,
                scrollback: nil,
                actions: []
            )
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
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
                actions: []
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

    let paneID = PaneID()
    let paneType = "terminal"
    var title: String { "Terminal" }

    private var hostView: TerminalHostView?
    private var stateHostView: NSHostingView<TerminalStateView>?
    private let autoStartIfNeeded: Bool
    private var currentWorkingDirectory: String?
    private var currentSessionID: String?
    private var bridgeObserverID: UUID?
    private var loadTask: Task<Void, Never>?
    private var recoveryOptions: [SessionRecoveryOption] = []
    private var awaitingProjectActivation = false
    var onPersistedStateChange: ((PersistedPane) -> Void)?

    init(
        workingDirectory: String? = nil,
        sessionID: String? = nil,
        autoStartIfNeeded: Bool = true
    ) {
        self.autoStartIfNeeded = autoStartIfNeeded
        self.currentWorkingDirectory = workingDirectory
        self.currentSessionID = sessionID
        super.init(frame: .zero)
        showState(
            title: "Terminal",
            message: sessionID == nil && !autoStartIfNeeded
                ? "Open a project to create a backend terminal session."
                : "Connecting to the backend terminal session...",
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
        if let hostView {
            window?.makeFirstResponder(hostView)
        }
    }

    func deactivate() {}

    func dispose() {
        loadTask?.cancel()
        if let bridgeObserverID {
            BridgeEventHub.shared.removeObserver(bridgeObserverID)
        }
        hostView?.terminalSurface?.requestClose()
    }

    var workingDirectory: String? { currentWorkingDirectory }
    var sessionID: String? { currentSessionID }

    var onTerminalClose: (() -> Void)? {
        get { hostView?.onTerminalClose }
        set { hostView?.onTerminalClose = newValue }
    }

    private func retryAfterProjectActivation() {
        guard awaitingProjectActivation else { return }
        awaitingProjectActivation = false
        loadOrRestoreSession()
    }

    private func showProjectActivationFailure(_ event: BridgeEvent) {
        guard awaitingProjectActivation else { return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let payload = event.payloadJSON.data(using: .utf8).flatMap {
            try? decoder.decode(ProjectOpenFailureEventPayload.self, from: $0)
        }
        showState(
            title: "Project Activation Failed",
            message: payload?.message ?? "The workspace project could not be activated.",
            detail: "The terminal will retry automatically after the workspace activates successfully.",
            scrollback: nil,
            actions: []
        )
    }

    private func loadOrRestoreSession() {
        loadTask?.cancel()

        guard let sessionBridge = PaneFactory.sessionBridge else {
            showState(
                title: "Terminal Unavailable",
                message: "Terminal session bridge is not configured.",
                detail: nil,
                scrollback: nil,
                actions: []
            )
            return
        }

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
                    await self.apply(binding: binding)
                } catch {
                    await self.handleSessionLoadFailure(error)
                }
            }
            return
        }

        guard autoStartIfNeeded else {
            showState(
                title: "Terminal",
                message: "Open a project to create a backend terminal session.",
                detail: nil,
                scrollback: nil,
                actions: []
            )
            return
        }

        showState(
            title: "Starting Session",
            message: "Creating a backend-managed terminal session...",
            detail: nil,
            scrollback: nil,
            actions: []
        )
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let binding = try await sessionBridge.createSession(
                    workingDirectory: self.currentWorkingDirectory
                )
                await self.apply(binding: binding)
            } catch {
                await self.handleSessionLoadFailure(error)
            }
        }
    }

    private func handleSessionLoadFailure(_ error: Error) async {
        let message = error.localizedDescription
        if message.contains("no open project") || message.contains("No active project") {
            awaitingProjectActivation = true
            showState(
                title: "Waiting For Project",
                message: "The workspace project is still activating.",
                detail: "The terminal will retry automatically when the backend finishes opening the project.",
                scrollback: nil,
                actions: []
            )
            return
        }

        showState(
            title: "Terminal Error",
            message: message,
            detail: nil,
            scrollback: nil,
            actions: makeFallbackActions()
        )
    }

    private func apply(binding: SessionBindingDescriptor) async {
        currentSessionID = binding.sessionID
        currentWorkingDirectory = binding.cwd
        recoveryOptions = binding.recoveryOptions
        notifyPersistedStateChanged()

        if binding.isLiveAttach {
            showLiveTerminal(binding)
        } else {
            await showArchivedTerminal(binding)
        }
    }

    private func showLiveTerminal(_ binding: SessionBindingDescriptor) {
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
            actions: recoveryActionButtons()
        )

        guard let sessionBridge = PaneFactory.sessionBridge else { return }
        do {
            let scrollback = try await sessionBridge.scrollback(for: binding.sessionID)
            showState(
                title: title,
                message: message,
                detail: detail,
                scrollback: scrollback.data,
                actions: recoveryActionButtons()
            )
        } catch {
            showState(
                title: "Session Ended",
                message: "Unable to load archived scrollback.",
                detail: error.localizedDescription,
                scrollback: nil,
                actions: recoveryActionButtons()
            )
        }
    }

    private func recoveryActionButtons() -> [TerminalStateAction] {
        recoveryOptions.map { option in
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
        guard autoStartIfNeeded else { return [] }
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
                actions: recoveryActionButtons()
            )
        }
    }

    private func notifyPersistedStateChanged() {
        onPersistedStateChange?(persistedPane())
    }

    private func replaceContent(with view: NSView) {
        hostView?.removeFromSuperview()
        stateHostView?.removeFromSuperview()
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
        actions: [TerminalStateAction]
    ) {
        let rootView = TerminalStateView(
            title: title,
            message: message,
            detail: detail,
            scrollback: scrollback,
            actions: actions
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

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 24, weight: .semibold, design: .rounded))
                        Text(message)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        if let detail, !detail.isEmpty {
                            Text(detail)
                                .font(.system(size: 12, weight: .regular, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !actions.isEmpty {
                        HStack(spacing: 10) {
                            ForEach(actions) { action in
                                Button(action.label, action: action.perform)
                                    .buttonStyle(.borderedProminent)
                                    .disabled(!action.enabled)
                            }
                        }
                    }

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
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
