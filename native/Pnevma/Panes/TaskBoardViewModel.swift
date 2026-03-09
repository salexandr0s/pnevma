import SwiftUI
import Observation

// MARK: - ViewModel

@Observable @MainActor
final class TaskBoardViewModel {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    var allTasks: [TaskItem] = []
    var actionError: String?
    var creationError: String?
    var isCreating = false
    private var viewState: ViewState = .waiting("Open a project to load tasks.")

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let bridgeEventHub: BridgeEventHub
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
    private var activationObserverID: UUID?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        bridgeEventHub: BridgeEventHub = .shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.bridgeEventHub = bridgeEventHub
        self.activationHub = activationHub

        bridgeObserverID = bridgeEventHub.addObserver { [weak self] event in
            guard event.name == "task_updated" else { return }
            Task { @MainActor [weak self] in
                self?.refreshIfActive()
            }
        }
        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
        if let bridgeObserverID {
            bridgeEventHub.removeObserver(bridgeObserverID)
        }
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
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

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    func tasks(for status: TaskStatus) -> [TaskItem] {
        allTasks
            .filter { $0.status == status }
            .sorted { lhs, rhs in
                if lhs.priority.sortRank != rhs.priority.sortRank {
                    return lhs.priority.sortRank < rhs.priority.sortRank
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    func availableDependencies() -> [TaskItem] {
        allTasks.sorted { $0.updatedAt > $1.updatedAt }
    }

    func clearCreationError() {
        creationError = nil
    }

    func loadTasks(showLoadingState: Bool = true) {
        guard let bus = commandBus else {
            viewState = .failed("Task loading is unavailable because the command bus is not configured.")
            return
        }
        if showLoadingState, allTasks.isEmpty {
            viewState = .loading("Loading tasks...")
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let tasks: [BackendTask] = try await bus.call(method: "task.list", params: nil)
                let mapped = try tasks.map(Self.mapBackendTask)
                self.finishLoading(mapped)
            } catch {
                self.handleLoadFailure(error)
            }
        }
    }

    func createTask(from draft: TaskCreationDraft) async -> Bool {
        if let validationMessage = draft.validationMessage {
            creationError = validationMessage
            return false
        }
        guard let bus = commandBus else {
            creationError = "Backend connection unavailable"
            return false
        }

        creationError = nil
        isCreating = true
        defer { isCreating = false }

        do {
            let _: TaskCreateResponse = try await bus.call(
                method: "task.create",
                params: CreateTaskParams(
                    title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    goal: draft.goal.trimmingCharacters(in: .whitespacesAndNewlines),
                    scope: draft.scopeEntries,
                    acceptanceCriteria: draft.acceptanceCriteriaEntries,
                    constraints: draft.constraintEntries,
                    dependencies: Array(draft.selectedDependencyIDs),
                    priority: draft.priority.rawValue
                )
            )
            refreshAfterMutation()
            return true
        } catch {
            creationError = error.localizedDescription
            return false
        }
    }

    func dispatch(_ task: TaskItem) {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                struct Params: Encodable { let taskID: String }
                let _: TaskDispatchResponse = try await bus.call(
                    method: "task.dispatch",
                    params: Params(taskID: task.id)
                )
                self.refreshAfterMutation()
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func moveTask(_ task: TaskItem, to status: TaskStatus) {
        guard status != task.status else { return }
        let originalTasks = allTasks
        if let idx = allTasks.firstIndex(where: { $0.id == task.id }) {
            allTasks[idx].status = status
            allTasks[idx].updatedAt = Date.now
        }

        guard let bus = commandBus else {
            allTasks = originalTasks
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let updated: BackendTask = try await bus.call(
                    method: "task.update",
                    params: UpdateTaskParams(taskID: task.id, status: status.rawValue)
                )
                if let idx = self.allTasks.firstIndex(where: { $0.id == task.id }) {
                    self.allTasks[idx] = try Self.mapBackendTask(updated)
                }
                self.refreshAfterMutation()
            } catch {
                self.allTasks = originalTasks
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    private func scheduleDismissActionError() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.actionError = nil
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle, .opening:
            viewState = .waiting("Waiting for project activation...")
        case .open:
            loadTasks(showLoadingState: allTasks.isEmpty)
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            allTasks = []
            creationError = nil
            viewState = .waiting("Open a project to load tasks.")
        }
    }

    private func refreshIfActive() {
        guard activationHub.currentState.isOpen else { return }
        loadTasks(showLoadingState: false)
    }

    private func finishLoading(_ tasks: [TaskItem]) {
        allTasks = tasks
        creationError = nil
        viewState = .ready
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
    }

    private func refreshAfterMutation() {
        guard activationHub.currentState.isOpen else { return }
        loadTasks(showLoadingState: false)
    }

    private static func mapBackendTask(_ task: BackendTask) throws -> TaskItem {
        guard let status = TaskStatus(rawValue: task.status) else {
            throw TaskBoardError(message: "Unknown task status '\(task.status)' from backend.")
        }
        guard let priority = TaskPriority(rawValue: task.priority) else {
            throw TaskBoardError(message: "Unknown task priority '\(task.priority)' from backend.")
        }
        return TaskItem(
            id: task.id,
            title: task.title,
            goal: task.goal,
            status: status,
            priority: priority,
            scope: task.scope,
            acceptanceCriteria: task.acceptanceCriteria.map(\.description),
            dependencies: task.dependencies,
            branch: task.branch,
            worktreeID: task.worktreeID,
            queuedPosition: task.queuedPosition,
            cost: task.costUsd,
            executionMode: task.executionMode,
            updatedAt: task.updatedAt
        )
    }
}
