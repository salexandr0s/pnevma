import SwiftUI
import Observation

// MARK: - ViewModel

@Observable @MainActor
final class ReviewViewModel {
    private let initialTaskID: String?

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
            diffFiles = []
            selectedDiffFilePath = nil
            diffError = nil
            actionError = nil
            if let id = selectedTaskID {
                loadReviewPack(taskId: id)
                loadReviewDiff(taskId: id)
            }
        }
    }
    var reviewPack: ReviewPack?
    var criteria: [AcceptanceCriterion] = []
    var notes: String = ""
    var diffFiles: [DiffFile] = []
    var selectedDiffFilePath: String?
    var isLoadingPack: Bool = false
    var isLoadingDiff: Bool = false
    var isActing: Bool = false
    var actionError: String?
    var diffError: String?
    private var viewState: ViewState = .waiting("Open a project to load reviews.")

    var allCriteriaMet: Bool {
        criteria.isEmpty || criteria.allSatisfy { $0.met }
    }

    var selectedTaskTitle: String? {
        guard let id = selectedTaskID else { return nil }
        return reviewTasks.first { $0.id == id }?.title
    }

    var selectedDiffFile: DiffFile? {
        guard let path = selectedDiffFilePath else { return nil }
        return diffFiles.first { $0.path == path }
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
    private let notificationCenter: NotificationCenter
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
    private var activationObserverID: UUID?
    @ObservationIgnored
    nonisolated(unsafe) private var deepLinkObserver: NSObjectProtocol?
    @ObservationIgnored
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored
    private var activationGeneration: UInt64 = 0
    @ObservationIgnored
    private var tasksLoadToken: UInt64 = 0
    @ObservationIgnored
    private var packLoadToken: UInt64 = 0
    @ObservationIgnored
    private var diffLoadToken: UInt64 = 0

    init(
        initialTaskID: String? = nil,
        commandBus: (any CommandCalling)? = CommandBus.shared,
        bridgeEventHub: BridgeEventHub = .shared,
        activationHub: ActiveWorkspaceActivationHub = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.initialTaskID = initialTaskID
        self.commandBus = commandBus
        self.bridgeEventHub = bridgeEventHub
        self.activationHub = activationHub
        self.notificationCenter = notificationCenter

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
        if let bridgeObserverID {
            bridgeEventHub.removeObserver(bridgeObserverID)
        }
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
        if let deepLinkObserver {
            notificationCenter.removeObserver(deepLinkObserver)
        }
    }

    // MARK: - Public API

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    func load(reloadSelectionDetail: Bool = false) {
        guard let bus = commandBus else {
            viewState = .failed("Review loading is unavailable because the command bus is not configured.")
            return
        }
        if reviewTasks.isEmpty {
            viewState = .loading("Loading review tasks...")
        }
        loadTask?.cancel()
        tasksLoadToken &+= 1
        let loadToken = tasksLoadToken
        let generation = activationGeneration
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let tasks: [BackendTaskItem] = try await bus.call(
                    method: "task.list",
                    params: TaskListParams(status: "Review")
                )
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.tasksLoadToken == loadToken else { return }
                let mapped = tasks
                    .filter { $0.status == "Review" }
                    .map { ReviewTaskItem(id: $0.id, title: $0.title, costUsd: $0.costUsd) }
                self.finishLoading(mapped, reloadSelectionDetail: reloadSelectionDetail)
            } catch {
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.tasksLoadToken == loadToken else { return }
                self.handleLoadFailure(error)
            }
        }
    }

    func refresh() {
        load(reloadSelectionDetail: true)
    }

    func clearSelection() {
        packTask?.cancel()
        packTask = nil
        diffTask?.cancel()
        diffTask = nil
        packLoadToken &+= 1
        diffLoadToken &+= 1
        isLoadingPack = false
        isLoadingDiff = false
        selectedTaskID = nil
        reviewPack = nil
        criteria = []
        notes = ""
        diffFiles = []
        selectedDiffFilePath = nil
        diffError = nil
        actionError = nil
    }

    private var packTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?

    func loadReviewPack(taskId: String) {
        guard let bus = commandBus else {
            isLoadingPack = false
            actionError = "Backend connection unavailable"
            return
        }
        packTask?.cancel()
        packLoadToken &+= 1
        let loadToken = packLoadToken
        let generation = activationGeneration
        isLoadingPack = true
        packTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pack: ReviewPack = try await bus.call(
                    method: "review.get_pack",
                    params: ReviewGetPackParams(taskId: taskId)
                )
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.packLoadToken == loadToken else { return }
                // Only apply if the user hasn't navigated away.
                guard self.selectedTaskID == taskId else { return }
                self.reviewPack = pack
                self.criteria = pack.pack
                    .acceptanceCriteriaStrings()
                    .map { AcceptanceCriterion(description: $0, met: false) }
                self.notes = pack.reviewerNotes ?? ""
                self.isLoadingPack = false
            } catch {
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.packLoadToken == loadToken else { return }
                guard self.selectedTaskID == taskId else { return }
                self.isLoadingPack = false
                self.actionError = error.localizedDescription
            }
        }
    }

    func loadReviewDiff(taskId: String) {
        guard let bus = commandBus else {
            isLoadingDiff = false
            diffError = "Backend connection unavailable"
            return
        }
        diffTask?.cancel()
        diffLoadToken &+= 1
        let loadToken = diffLoadToken
        let generation = activationGeneration
        isLoadingDiff = true
        diffError = nil
        diffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let response: TaskDiffResponse? = try await bus.call(
                    method: "review.diff",
                    params: ReviewGetPackParams(taskId: taskId)
                )
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.diffLoadToken == loadToken else { return }
                guard self.selectedTaskID == taskId else { return }
                self.diffFiles = response?.files ?? []
                self.selectedDiffFilePath = self.diffFiles.first?.path
                self.isLoadingDiff = false
            } catch {
                guard !Task.isCancelled,
                      self.activationGeneration == generation,
                      self.diffLoadToken == loadToken else { return }
                guard self.selectedTaskID == taskId else { return }
                self.diffFiles = []
                self.selectedDiffFilePath = nil
                self.isLoadingDiff = false
                self.diffError = error.localizedDescription
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
        invalidatePendingLoads()

        switch state {
        case .idle:
            clearContentState()
            viewState = .waiting("Waiting for project activation...")
        case .opening:
            clearContentState()
            viewState = .waiting("Waiting for project activation...")
        case .open:
            clearContentState()
            load()
        case .failed(_, _, let message):
            clearContentState()
            viewState = .failed(message)
        case .closed:
            clearContentState()
            viewState = .waiting("Open a project to load reviews.")
        }
    }

    private func refreshIfActive() {
        guard activationHub.currentState.isOpen else { return }
        load()
    }

    private func finishLoading(_ tasks: [ReviewTaskItem], reloadSelectionDetail: Bool) {
        reviewTasks = tasks
        viewState = .ready
        let availableTaskIDs = Set(tasks.map(\.id))
        if applyPendingDeepLinkIfAvailable(availableTaskIDs: availableTaskIDs) {
            return
        }
        if selectedTaskID == nil,
           let initialTaskID,
           tasks.contains(where: { $0.id == initialTaskID }) {
            selectedTaskID = initialTaskID
            return
        }
        // Preserve local checklist/notes edits for the current selection on background refreshes.
        // Only clear the selection if the task truly disappeared from the list.
        if let id = selectedTaskID, !tasks.contains(where: { $0.id == id }) {
            selectedTaskID = nil
        } else if reloadSelectionDetail, let id = selectedTaskID {
            loadReviewPack(taskId: id)
            loadReviewDiff(taskId: id)
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
    }

    private func invalidatePendingLoads() {
        activationGeneration &+= 1
        tasksLoadToken &+= 1
        packLoadToken &+= 1
        diffLoadToken &+= 1
        loadTask?.cancel()
        loadTask = nil
        packTask?.cancel()
        packTask = nil
        diffTask?.cancel()
        diffTask = nil
        isLoadingPack = false
        isLoadingDiff = false
    }

    private func clearContentState() {
        reviewTasks = []
        reviewPack = nil
        criteria = []
        notes = ""
        diffFiles = []
        selectedDiffFilePath = nil
        actionError = nil
        diffError = nil
        selectedTaskID = nil
    }

    private func handleDeepLinkNotification(_ notification: Notification) {
        handleDeepLinkForTarget(notification.userInfo?["target"] as? String)
    }

    private func handleDeepLinkForTarget(_ target: String?) {
        guard let target,
              target == CommandCenterDeepLinkTarget.review.rawValue else {
            return
        }

        if applyPendingDeepLinkIfAvailable(availableTaskIDs: Set(reviewTasks.map(\.id))) {
            return
        }

        guard activationHub.currentState.isOpen else { return }
        load(reloadSelectionDetail: false)
    }

    @discardableResult
    private func applyPendingDeepLinkIfAvailable(availableTaskIDs: Set<String>) -> Bool {
        guard let taskID = CommandCenterDeepLinkStore.shared.consumePendingTaskID(
            for: .review,
            availableTaskIDs: availableTaskIDs
        ) else {
            return false
        }
        selectedTaskID = taskID
        return true
    }
}
