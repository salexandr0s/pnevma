import SwiftUI
import Cocoa

// MARK: - Data Models

/// Matches the backend `ReviewPackView` response from `review.get_pack`.
/// The decoder uses `PnevmaJSON.decoder()` which converts snake_case → camelCase with acronym handling.
struct ReviewPack: Decodable {
    let taskId: String
    let status: String          // "Pending" | "Approved" | "Rejected"
    let reviewPackPath: String
    let reviewerNotes: String?
    let approvedAt: String?
    let pack: JSONValue
}

struct AcceptanceCriterion: Identifiable, Codable {
    var id: String { description }
    let description: String
    var met: Bool
}

// MARK: - Backend param/response helpers (private)

private struct TaskListParams: Encodable {
    let status: String?
}

private struct ReviewGetPackParams: Encodable {
    let taskId: String
}

private struct ReviewActionParams: Encodable {
    let taskId: String
    let note: String?
}

private struct BackendTaskItem: Decodable {
    let id: String
    let title: String
    let status: String
    let priority: String
    let costUsd: Double?
}

// MARK: - ReviewView

struct ReviewView: View {
    @StateObject private var viewModel = ReviewViewModel()

    var body: some View {
        Group {
            if let statusMessage = viewModel.statusMessage {
                EmptyStateView(
                    icon: "checkmark.seal",
                    title: statusMessage
                )
            } else {
                HSplitView {
                    taskListPanel
                    detailPanel
                }
            }
        }
        .onAppear { viewModel.activate() }
    }

    // MARK: Left panel — tasks pending review

    private var taskListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pending Review")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.reviewTasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            if viewModel.reviewTasks.isEmpty {
                Spacer()
                Text("No tasks awaiting review")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding()
                Spacer()
            } else {
                List(viewModel.reviewTasks, selection: $viewModel.selectedTaskID) { task in
                    ReviewTaskRow(task: task)
                        .tag(task.id)
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 200, idealWidth: 240)
    }

    // MARK: Right panel — review details

    @ViewBuilder
    private var detailPanel: some View {
        if let pack = viewModel.reviewPack {
            HSplitView {
                // Pack path / metadata
                VStack(alignment: .leading, spacing: 0) {
                    Text("Review Pack")
                        .font(.headline)
                        .padding(12)
                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Status", value: pack.status)
                            LabeledContent("Path", value: pack.reviewPackPath)
                            if let approvedAt = pack.approvedAt {
                                LabeledContent("Approved At", value: approvedAt)
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                    }
                }

                // Checklist + actions
                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.selectedTaskTitle ?? pack.taskId)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .padding(.top, 12)

                    if !viewModel.criteria.isEmpty {
                        GroupBox("Acceptance Criteria") {
                            ForEach(viewModel.criteria.indices, id: \.self) { idx in
                                Toggle(viewModel.criteria[idx].description,
                                       isOn: $viewModel.criteria[idx].met)
                                    .toggleStyle(.checkbox)
                                    .padding(.vertical, 2)
                            }
                        }
                    }

                    GroupBox("Notes") {
                        TextEditor(text: $viewModel.notes)
                            .font(.body)
                            .frame(minHeight: 80)
                    }

                    if let error = viewModel.actionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Spacer()

                    HStack {
                        Button("Reject") { viewModel.reject() }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isActing)

                        Spacer()

                        Button("Approve") { viewModel.approve() }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isActing || !viewModel.allCriteriaMet)
                    }
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 280)
            }
        } else {
            VStack {
                Spacer()
                if viewModel.isLoadingPack {
                    ProgressView("Loading review pack...")
                } else {
                    Text("Select a task to review")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Task row (left panel)

private struct ReviewTaskRow: View {
    let task: ReviewTaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
                .font(.body)
                .lineLimit(2)
            if let cost = task.costUsd {
                Text(String(format: "$%.2f", cost))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - View model task item

struct ReviewTaskItem: Identifiable, Hashable {
    let id: String
    let title: String
    let costUsd: Double?
}

// MARK: - ViewModel

@MainActor
final class ReviewViewModel: ObservableObject {

    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    // Published state
    @Published var reviewTasks: [ReviewTaskItem] = []
    @Published var selectedTaskID: String? {
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
    @Published var reviewPack: ReviewPack?
    @Published var criteria: [AcceptanceCriterion] = []
    @Published var notes: String = ""
    @Published var isLoadingPack: Bool = false
    @Published var isActing: Bool = false
    @Published var actionError: String?
    @Published private var viewState: ViewState = .waiting("Open a project to load reviews.")

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
    private let commandBus: (any CommandCalling)?
    private let bridgeEventHub: BridgeEventHub
    private let activationHub: ActiveWorkspaceActivationHub
    private var bridgeObserverID: UUID?
    private var activationObserverID: UUID?
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

    func activate() {
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

// MARK: - NSView Wrapper

final class ReviewPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "review"
    let shouldPersist = false
    var title: String { "Review" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(ReviewView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
