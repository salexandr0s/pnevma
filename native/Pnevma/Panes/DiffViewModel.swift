import SwiftUI
import Observation

// MARK: - ViewModel

@Observable @MainActor
final class DiffViewModel {
    var tasks: [DiffTaskItem] = []
    var files: [DiffFile] = []
    var selectedFile: String?
    var isLoadingDiff = false
    var diffError: String?
    private let initialTaskID: String?

    // didSet is used intentionally for side-effects: selecting a task triggers loadDiff().
    // In @Observable classes, didSet runs outside observation tracking but the side-effect
    // (a Task that mutates tracked properties) still triggers UI updates correctly.
    var selectedTaskId: String? = nil {
        didSet {
            guard selectedTaskId != oldValue else { return }
            files = []
            selectedFile = nil
            diffError = nil
            if let taskId = selectedTaskId {
                loadDiff(taskId: taskId)
            }
        }
    }

    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    private var viewState: ViewState = .waiting("Open a project to load diffs.")

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private var activationObserverID: UUID?
    @ObservationIgnored
    private let notificationCenter: NotificationCenter
    @ObservationIgnored
    nonisolated(unsafe) private var deepLinkObserver: NSObjectProtocol?

    init(
        initialTaskID: String? = nil,
        commandBus: (any CommandCalling)? = CommandBus.shared,
        activationHub: ActiveWorkspaceActivationHub = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.initialTaskID = initialTaskID
        self.commandBus = commandBus
        self.activationHub = activationHub
        self.notificationCenter = notificationCenter

        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }

        deepLinkObserver = notificationCenter.addObserver(
            forName: .commandCenterDeepLinkDidChange,
            object: CommandCenterDeepLinkStore.shared,
            queue: nil
        ) { [weak self] notification in
            let target = notification.userInfo?["target"] as? String
            Task { @MainActor [weak self] in
                self?.handleDeepLinkForTarget(target)
            }
        }
    }

    deinit {
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
        if let deepLinkObserver {
            notificationCenter.removeObserver(deepLinkObserver)
        }
    }

    var statusMessage: String? {
        switch viewState {
        case .waiting(let message), .loading(let message), .failed(let message):
            return message
        case .ready:
            return nil
        }
    }

    var selectedDiffFile: DiffFile? {
        guard let sel = selectedFile else { return nil }
        return files.first { $0.id == sel }
    }

    /// Called from `.task` to sync with the current activation state immediately.
    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    private var loadTask: Task<Void, Never>?
    private var diffLoadTask: Task<Void, Never>?

    /// Load tasks that may have diffs (Review, InProgress, or Done).
    func load(showLoadingState: Bool = true) {
        guard let bus = commandBus else {
            viewState = .failed("Diff loading is unavailable because the command bus is not configured.")
            return
        }
        if showLoadingState, tasks.isEmpty {
            viewState = .loading("Loading tasks...")
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let backendTasks: [BackendDiffTask] = try await bus.call(method: "task.list", params: nil)
                guard !Task.isCancelled else { return }
                let filtered = backendTasks
                    .filter { ["Review", "InProgress", "Done"].contains($0.status) }
                    .map { DiffTaskItem(id: $0.id, title: $0.title, status: $0.status) }
                self.tasks = filtered
                let availableTaskIDs = Set(filtered.map(\.id))
                if self.applyPendingDeepLinkIfAvailable(availableTaskIDs: availableTaskIDs) {
                    self.viewState = .ready
                    return
                }
                if self.selectedTaskId == nil,
                   let initialTaskID = self.initialTaskID,
                   filtered.contains(where: { $0.id == initialTaskID }) {
                    self.selectedTaskId = initialTaskID
                }
                self.viewState = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.handleLoadFailure(error)
            }
        }
    }

    /// Fetch the diff for a specific task from the backend.
    func loadDiff(taskId: String) {
        guard let bus = commandBus else {
            isLoadingDiff = false
            diffError = "Backend connection unavailable"
            return
        }
        diffLoadTask?.cancel()
        isLoadingDiff = true
        diffError = nil
        struct DiffParams: Encodable { let taskId: String }
        diffLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingDiff = false }
            do {
                let response: TaskDiffResponse = try await bus.call(
                    method: "review.diff",
                    params: DiffParams(taskId: taskId)
                )
                guard self.selectedTaskId == taskId else { return }
                self.files = response.files
                self.selectedFile = response.files.first?.id
            } catch {
                guard self.selectedTaskId == taskId else { return }
                self.diffError = error.localizedDescription
            }
        }
    }

    // MARK: Private

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle:
            viewState = .waiting("Waiting for project activation...")
        case .opening:
            viewState = .waiting("Waiting for project activation...")
        case .open:
            load(showLoadingState: tasks.isEmpty)
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            loadTask?.cancel()
            tasks = []
            files = []
            selectedTaskId = nil
            selectedFile = nil
            diffError = nil
            viewState = .waiting("Open a project to load diffs.")
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
    }

    private func handleDeepLinkNotification(_ notification: Notification) {
        handleDeepLinkForTarget(notification.userInfo?["target"] as? String)
    }

    private func handleDeepLinkForTarget(_ target: String?) {
        guard let target,
              target == CommandCenterDeepLinkTarget.diff.rawValue else {
            return
        }

        if applyPendingDeepLinkIfAvailable(availableTaskIDs: Set(tasks.map(\.id))) {
            return
        }

        guard activationHub.currentState.isOpen else { return }
        load(showLoadingState: false)
    }

    @discardableResult
    private func applyPendingDeepLinkIfAvailable(availableTaskIDs: Set<String>) -> Bool {
        guard let taskID = CommandCenterDeepLinkStore.shared.consumePendingTaskID(
            for: .diff,
            availableTaskIDs: availableTaskIDs
        ) else {
            return false
        }
        selectedTaskId = taskID
        return true
    }
}
