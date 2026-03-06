import SwiftUI
import Cocoa

struct TaskItem: Identifiable {
    let id: String
    var title: String
    var status: TaskStatus
    var priority: TaskPriority
    var agentName: String?
    var cost: Double?
    var storyProgress: Double?
}

enum TaskStatus: String, CaseIterable {
    case planned = "Planned"
    case ready = "Ready"
    case inProgress = "InProgress"
    case review = "Review"
    case done = "Done"
    case failed = "Failed"
    case blocked = "Blocked"

    var displayName: String {
        switch self {
        case .planned: return "Planned"
        case .ready: return "Ready"
        case .inProgress: return "In Progress"
        case .review: return "Review"
        case .done: return "Done"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        }
    }

    var isBoardColumn: Bool {
        true
    }
}

enum TaskPriority: String {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"

    var color: Color {
        switch self {
        case .p0: return .red
        case .p1: return .orange
        case .p2: return .blue
        case .p3: return .secondary
        }
    }
}

private struct BackendTask: Decodable {
    let id: String
    let title: String
    let status: String
    let priority: String
    let costUsd: Double?
}

private struct UpdateTaskParams: Encodable {
    let taskID: String
    let status: String
}

struct TaskBoardView: View {
    @StateObject private var viewModel = TaskBoardViewModel()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskStatus.allCases.filter(\.isBoardColumn), id: \.self) { status in
                    KanbanColumn(
                        status: status,
                        tasks: viewModel.tasks(for: status),
                        onDispatch: { viewModel.dispatch($0) },
                        onStatusChange: { task, newStatus in
                            viewModel.moveTask(task, to: newStatus)
                        }
                    )
                }
            }
            .padding(16)
        }
        .onAppear { viewModel.loadTasks() }
    }
}

struct KanbanColumn: View {
    let status: TaskStatus
    let tasks: [TaskItem]
    let onDispatch: (TaskItem) -> Void
    let onStatusChange: (TaskItem, TaskStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(status.displayName)
                    .font(.headline)
                Spacer()
                Text("\(tasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 6) {
                    ForEach(tasks) { task in
                        TaskCard(
                            task: task,
                            onDispatch: { onDispatch(task) },
                            onStatusChange: { onStatusChange(task, $0) }
                        )
                    }
                }
            }
        }
        .frame(width: 240)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

struct TaskCard: View {
    let task: TaskItem
    let onDispatch: () -> Void
    let onStatusChange: (TaskStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(task.priority.color)
                    .frame(width: 8, height: 8)
                Text(task.title)
                    .font(.body)
                    .lineLimit(2)
            }

            HStack {
                if let agent = task.agentName {
                    Text(agent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let cost = task.cost {
                    Text(String(format: "$%.2f", cost))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = task.storyProgress {
                ProgressView(value: progress)
                    .tint(.accentColor)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .textBackgroundColor))
                .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
        )
        .contextMenu {
            Button("Dispatch") { onDispatch() }
            Divider()
            ForEach(TaskStatus.allCases.filter(\.isBoardColumn), id: \.self) { status in
                Button("Move to \(status.displayName)") {
                    onStatusChange(status)
                }
                .disabled(status == task.status)
            }
        }
    }
}

final class TaskBoardViewModel: ObservableObject {
    @Published var allTasks: [TaskItem] = []

    private var bridgeObserverID: UUID?

    init() {
        bridgeObserverID = BridgeEventHub.shared.addObserver { [weak self] event in
            guard event.name == "task_updated" else { return }
            self?.loadTasks()
        }
    }

    deinit {
        if let bridgeObserverID {
            BridgeEventHub.shared.removeObserver(bridgeObserverID)
        }
    }

    func tasks(for status: TaskStatus) -> [TaskItem] {
        allTasks.filter { $0.status == status }
    }

    func loadTasks() {
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                let tasks: [BackendTask] = try await bus.call(method: "task.list")
                let mapped = tasks.compactMap(Self.mapBackendTask)
                await MainActor.run { self.allTasks = mapped }
            } catch {
                // Keep the current board state if refresh fails.
            }
        }
    }

    func dispatch(_ task: TaskItem) {
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                struct Params: Encodable { let taskID: String }
                let _: TaskDispatchResponse = try await bus.call(
                    method: "task.dispatch",
                    params: Params(taskID: task.id)
                )
                loadTasks()
            } catch {
                // Keep existing state when dispatch fails.
            }
        }
    }

    func moveTask(_ task: TaskItem, to status: TaskStatus) {
        if let idx = allTasks.firstIndex(where: { $0.id == task.id }) {
            allTasks[idx].status = status
        }
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                let _: BackendTask = try await bus.call(
                    method: "task.update",
                    params: UpdateTaskParams(taskID: task.id, status: status.rawValue)
                )
                loadTasks()
            } catch {
                loadTasks()
            }
        }
    }

    private static func mapBackendTask(_ task: BackendTask) -> TaskItem? {
        guard let status = TaskStatus(rawValue: task.status),
              let priority = TaskPriority(rawValue: task.priority) else {
            return nil
        }
        return TaskItem(
            id: task.id,
            title: task.title,
            status: status,
            priority: priority,
            agentName: nil,
            cost: task.costUsd,
            storyProgress: nil
        )
    }
}

final class TaskBoardPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "taskboard"
    var title: String { "Task Board" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(TaskBoardView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
