import SwiftUI
import Observation

// MARK: - ViewModel

@Observable @MainActor
final class ReviewViewModel {

    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    var reviewTasks: [ReviewTaskItem] = []
    // didSet is used intentionally for side-effects: selecting a task triggers loadReviewPack().
    // In @Observable classes, didSet runs outside observation tracking but the side-effect
    // (a Task that mutates tracked properties) still triggers UI updates correctly.
    var selectedTaskID: String? {
        didSet {
            guard selectedTaskID != oldValue else { return }
            reviewPack = nil
            criteria = []
            notes = ""
            actionError = nil
            if let id = selectedTaskID {
                loadReviewPack(taskId: id)
            }
        }
    }
    var reviewPack: ReviewPack?
    var criteria: [AcceptanceCriterion] = []
    var notes: String = ""
    var isLoadingPack: Bool = false
    var isActing: Bool = false
    var actionError: String?
    private var viewState: ViewState = .waiting("Open a project to load reviews.")

    var allCriteriaMet: Bool {
        criteria.isEmpty || criteria.allSatisfy { $0.met }
    }

    var selectedTaskTitle: String? {
        guard let id = selectedTaskID else { return nil }
        return reviewTasks.first { $0.id == id }?.title
    }

    var statusMessage: String? {
        switch viewState {
        case .waiting(let m), .loading(let m), .failed(let m): return m
        case .ready: return nil
        }
    }

    // Dependencies
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
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?

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

    // MARK: - Public API

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    func load() {
        guard let bus = commandBus else {
            viewState = .failed("Review loading is unavailable because the command bus is not configured.")
            return
        }
        if reviewTasks.isEmpty {
            viewState = .loading("Loading review tasks...")
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tasks: [BackendTaskItem] = try await bus.call(
                    method: "task.list",
                    params: TaskListParams(status: "Review")
                )
                guard !Task.isCancelled else { return }
                let mapped = tasks
                    .filter { $0.status == "Review" }
                    .map { ReviewTaskItem(id: $0.id, title: $0.title, costUsd: $0.costUsd) }
                self.finishLoading(mapped)
            } catch {
                guard !Task.isCancelled else { return }
                self.handleLoadFailure(error)
            }
        }
    }

    private var packTask: Task<Void, Never>?

    func loadReviewPack(taskId: String) {
        guard let bus = commandBus else {
            isLoadingPack = false
            actionError = "Backend connection unavailable"
            return
        }
        packTask?.cancel()
        isLoadingPack = true
        packTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pack: ReviewPack = try await bus.call(
                    method: "review.get_pack",
                    params: ReviewGetPackParams(taskId: taskId)
                )
                guard !Task.isCancelled else { return }
                // Only apply if the user hasn't navigated away.
                guard self.selectedTaskID == taskId else { return }
                self.reviewPack = pack
                self.criteria = pack.pack
                    .acceptanceCriteriaStrings()
                    .map { AcceptanceCriterion(description: $0, met: false) }
                self.notes = pack.reviewerNotes ?? ""
                self.isLoadingPack = false
            } catch {
                guard !Task.isCancelled else { return }
                guard self.selectedTaskID == taskId else { return }
                self.isLoadingPack = false
                self.actionError = error.localizedDescription
            }
        }
    }

    func approve() {
        guard !isActing else { return }
        guard let taskId = selectedTaskID, let bus = commandBus else { return }
        isActing = true
        actionError = nil
        let note = notes.isEmpty ? nil : notes
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await bus.call(
                    method: "review.approve",
                    params: ReviewActionParams(taskId: taskId, note: note)
                )
                self.isActing = false
                self.refreshIfActive()
            } catch {
                self.isActing = false
                self.actionError = error.localizedDescription
            }
        }
    }

    func reject() {
        guard !isActing else { return }
        guard let taskId = selectedTaskID, let bus = commandBus else { return }
        isActing = true
        actionError = nil
        let note = notes.isEmpty ? nil : notes
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await bus.call(
                    method: "review.reject",
                    params: ReviewActionParams(taskId: taskId, note: note)
                )
                self.isActing = false
                self.refreshIfActive()
            } catch {
                self.isActing = false
                self.actionError = error.localizedDescription
            }
        }
    }

    // MARK: - Activation state

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle:
            viewState = .waiting("Waiting for project activation...")
        case .opening:
            viewState = .waiting("Waiting for project activation...")
        case .open:
            load()
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            loadTask?.cancel()
            packTask?.cancel()
            reviewTasks = []
            reviewPack = nil
            selectedTaskID = nil
            viewState = .waiting("Open a project to load reviews.")
        }
    }

    private func refreshIfActive() {
        guard activationHub.currentState.isOpen else { return }
        load()
    }

    private func finishLoading(_ tasks: [ReviewTaskItem]) {
        reviewTasks = tasks
        viewState = .ready
        // Clear stale selection if the selected task is no longer in the review list.
        if let id = selectedTaskID, !tasks.contains(where: { $0.id == id }) {
            selectedTaskID = nil
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
    }
}
