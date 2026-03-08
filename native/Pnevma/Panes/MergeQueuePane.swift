import SwiftUI
import Cocoa

// MARK: - Data Models

struct MergeQueueItem: Identifiable, Decodable {
    let id: String
    let taskID: String
    let taskTitle: String
    let status: String
    let blockedReason: String?
    let approvedAt: String
    let startedAt: String?
    let completedAt: String?

    var taskId: String { taskID }
}

// MARK: - MergeQueueView

struct MergeQueueView: View {
    @StateObject private var viewModel = MergeQueueViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Merge Queue")
                    .font(.headline)
                Spacer()
                Button("Refresh") { viewModel.load() }
                    .buttonStyle(.bordered)
            }
            .padding(12)

            Divider()

            Group {
                if let statusMessage = viewModel.statusMessage {
                    EmptyStateView(
                        icon: "arrow.triangle.merge",
                        title: statusMessage
                    )
                } else if viewModel.items.isEmpty {
                    EmptyStateView(
                        icon: "arrow.triangle.merge",
                        title: "Merge queue is empty",
                        message: "Completed tasks will appear here for merging"
                    )
                } else {
                    List {
                        ForEach(viewModel.items) { item in
                            MergeQueueRow(
                                item: item,
                                onMerge: { viewModel.merge(item) },
                                onMoveUp: { viewModel.reorder(taskId: item.taskId, direction: "up") },
                                onMoveDown: { viewModel.reorder(taskId: item.taskId, direction: "down") }
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            }

            if let error = viewModel.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
        .onAppear { viewModel.activate() }
    }
}

// MARK: - MergeQueueRow

struct MergeQueueRow: View {
    let item: MergeQueueItem
    let onMerge: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.taskTitle)
                    .font(.body)
                statusLabel
            }

            Spacer()

            HStack(spacing: 4) {
                Button(action: onMoveUp) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.plain)
                .help("Move up")

                Button(action: onMoveDown) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.plain)
                .help("Move down")
            }

            Button("Merge") { onMerge() }
                .buttonStyle(.bordered)
                .disabled(item.status != "Queued")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch item.status {
        case "Running":
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case "Blocked":
            Label(blockedLabel, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case "Completed":
            Label("Completed", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        default:
            // "Queued" and any unknown values
            Text(item.status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var blockedLabel: String {
        if let reason = item.blockedReason, !reason.isEmpty {
            return "Blocked: \(reason)"
        }
        return "Blocked"
    }
}

// MARK: - ViewModel

@MainActor
final class MergeQueueViewModel: ObservableObject {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    @Published var items: [MergeQueueItem] = []
    @Published var actionError: String?
    @Published private var viewState: ViewState = .waiting("Open a project to load the merge queue.")

    private let commandBus: (any CommandCalling)?
    private let bridgeEventHub: BridgeEventHub
    private let activationHub: ActiveWorkspaceActivationHub
    private var bridgeObserverID: UUID?
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
            guard event.name == "merge_queue_updated" else { return }
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

    func activate() {
        handleActivationState(activationHub.currentState)
    }

    private var loadTask: Task<Void, Never>?

    func load(showLoadingState: Bool = true) {
        guard let bus = commandBus else {
            viewState = .failed("Merge queue loading is unavailable because the command bus is not configured.")
            return
        }
        if showLoadingState, items.isEmpty {
            viewState = .loading("Loading merge queue...")
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let fetched: [MergeQueueItem] = try await bus.call(method: "merge.queue.list", params: nil)
                guard !Task.isCancelled else { return }
                self.items = fetched
                self.viewState = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.handleLoadFailure(error)
            }
        }
    }

    func merge(_ item: MergeQueueItem) {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        actionError = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                struct Params: Encodable { let taskId: String }
                let _: OkResponse = try await bus.call(
                    method: "merge.queue.execute",
                    params: Params(taskId: item.taskId)
                )
                self.refreshAfterMutation()
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func reorder(taskId: String, direction: String) {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                struct Params: Encodable { let taskId: String; let direction: String }
                let updated: [MergeQueueItem] = try await bus.call(
                    method: "merge.queue.reorder",
                    params: Params(taskId: taskId, direction: direction)
                )
                self.items = updated
            } catch {
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
        case .idle:
            viewState = .waiting("Waiting for project activation...")
        case .opening:
            viewState = .waiting("Waiting for project activation...")
        case .open:
            load(showLoadingState: items.isEmpty)
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            items = []
            actionError = nil
            viewState = .waiting("Open a project to load the merge queue.")
        }
    }

    private func refreshIfActive() {
        guard activationHub.currentState.isOpen else { return }
        load(showLoadingState: false)
    }

    private func refreshAfterMutation() {
        guard activationHub.currentState.isOpen else { return }
        load(showLoadingState: false)
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

final class MergeQueuePaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "merge_queue"
    let shouldPersist = false
    var title: String { "Merge Queue" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(MergeQueueView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
