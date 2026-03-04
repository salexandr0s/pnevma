import SwiftUI
import Cocoa

// MARK: - Data Models

struct TaskItem: Identifiable, Codable {
    let id: String
    var title: String
    var status: TaskStatus
    var priority: TaskPriority
    var agentName: String?
    var cost: Double?
    var storyProgress: Double?  // 0.0–1.0
}

enum TaskStatus: String, Codable, CaseIterable {
    case planned, ready, inProgress = "in_progress", review, done
    var displayName: String {
        switch self {
        case .planned: return "Planned"
        case .ready: return "Ready"
        case .inProgress: return "In Progress"
        case .review: return "Review"
        case .done: return "Done"
        }
    }
}

enum TaskPriority: String, Codable {
    case low, medium, high, critical
    var color: Color {
        switch self {
        case .low: return .secondary
        case .medium: return .blue
        case .high: return .orange
        case .critical: return .red
        }
    }
}

// MARK: - TaskBoardPane (SwiftUI)

struct TaskBoardView: View {
    @StateObject private var viewModel = TaskBoardViewModel()

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
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

// MARK: - KanbanColumn

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
                        TaskCard(task: task, onDispatch: { onDispatch(task) })
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

// MARK: - TaskCard

struct TaskCard: View {
    let task: TaskItem
    let onDispatch: () -> Void

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
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button("Move to \(status.displayName)") {}
            }
        }
    }
}

// MARK: - ViewModel

final class TaskBoardViewModel: ObservableObject {
    @Published var allTasks: [TaskItem] = []

    func tasks(for status: TaskStatus) -> [TaskItem] {
        allTasks.filter { $0.status == status }
    }

    func loadTasks() {
        // Will call pnevma_call("task.list", "{}") via CommandBus.
        // For now, empty state.
    }

    func dispatch(_ task: TaskItem) {
        // pnevma_call("task.dispatch", ...)
    }

    func moveTask(_ task: TaskItem, to status: TaskStatus) {
        if let idx = allTasks.firstIndex(where: { $0.id == task.id }) {
            allTasks[idx].status = status
        }
    }
}

// MARK: - NSView Wrapper

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
