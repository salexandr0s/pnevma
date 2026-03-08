import SwiftUI
import Cocoa

struct TaskItem: Identifiable, Equatable {
    let id: String
    var title: String
    var goal: String
    var status: TaskStatus
    var priority: TaskPriority
    var scope: [String]
    var acceptanceCriteria: [String]
    var dependencies: [String]
    var branch: String?
    var worktreeID: String?
    var queuedPosition: Int?
    var cost: Double?
    var executionMode: String?
    var updatedAt: Date
}

enum TaskStatus: String, CaseIterable, Hashable {
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

    var symbolName: String {
        switch self {
        case .planned: return "calendar"
        case .ready: return "checkmark.circle"
        case .inProgress: return "bolt"
        case .review: return "doc.text.magnifyingglass"
        case .done: return "checkmark.seal"
        case .failed: return "exclamationmark.triangle"
        case .blocked: return "lock"
        }
    }

    var tint: Color {
        switch self {
        case .planned: return Color(nsColor: .systemBlue)
        case .ready: return Color(nsColor: .systemMint)
        case .inProgress: return Color(nsColor: .systemOrange)
        case .review: return Color(nsColor: .systemYellow)
        case .done: return Color(nsColor: .systemGreen)
        case .failed: return Color(nsColor: .systemRed)
        case .blocked: return Color(nsColor: .systemGray)
        }
    }
}

enum TaskPriority: String, CaseIterable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"

    var color: Color {
        switch self {
        case .p0: return Color(nsColor: .systemRed)
        case .p1: return Color(nsColor: .systemOrange)
        case .p2: return Color(nsColor: .systemBlue)
        case .p3: return Color(nsColor: .systemGray)
        }
    }

    var sortRank: Int {
        switch self {
        case .p0: return 0
        case .p1: return 1
        case .p2: return 2
        case .p3: return 3
        }
    }
}

private struct BackendCheck: Decodable {
    let description: String
}

private struct BackendTask: Decodable {
    let id: String
    let title: String
    let goal: String
    let status: String
    let priority: String
    let scope: [String]
    let dependencies: [String]
    let acceptanceCriteria: [BackendCheck]
    let branch: String?
    let worktreeID: String?
    let queuedPosition: Int?
    let costUsd: Double?
    let executionMode: String?
    let updatedAt: Date
}

private struct UpdateTaskParams: Encodable {
    let taskID: String
    let status: String
}

private struct CreateTaskParams: Encodable {
    let title: String
    let goal: String
    let scope: [String]
    let acceptanceCriteria: [String]
    let constraints: [String]
    let dependencies: [String]
    let priority: String
}

private struct TaskCreateResponse: Decodable {
    let taskID: String
}

private struct TaskBoardError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct TaskCreationDraft {
    var title = ""
    var goal = ""
    var priority: TaskPriority = .p1
    var scopeText = ""
    var acceptanceCriteriaText = ""
    var constraintsText = ""
    var selectedDependencyIDs = Set<String>()

    mutating func reset() {
        self = TaskCreationDraft()
    }

    var scopeEntries: [String] {
        Self.parseLines(scopeText)
    }

    var acceptanceCriteriaEntries: [String] {
        Self.parseLines(acceptanceCriteriaText)
    }

    var constraintEntries: [String] {
        Self.parseLines(constraintsText)
    }

    var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Title is required."
        }
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Goal is required."
        }
        return nil
    }

    private static func parseLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private enum TaskBoardLayoutMode: Equatable {
    case expanded
    case compact
    case stacked

    static func from(width: CGFloat) -> Self {
        switch width {
        case ..<820:
            return .stacked
        case ..<1180:
            return .compact
        default:
            return .expanded
        }
    }

    var columnWidth: CGFloat {
        switch self {
        case .expanded: return 286
        case .compact: return 242
        case .stacked: return 0
        }
    }

    var cardDensity: TaskCardDensity {
        switch self {
        case .expanded: return .comfortable
        case .compact, .stacked: return .compact
        }
    }

    var spacing: CGFloat {
        switch self {
        case .expanded: return 16
        case .compact: return 12
        case .stacked: return 0
        }
    }
}

private enum TaskCardDensity {
    case comfortable
    case compact

    var titleFont: Font {
        switch self {
        case .comfortable: return .system(size: 15, weight: .semibold)
        case .compact: return .system(size: 14, weight: .semibold)
        }
    }

    var bodyFont: Font {
        switch self {
        case .comfortable: return .system(size: 13)
        case .compact: return .system(size: 12)
        }
    }

    var verticalSpacing: CGFloat {
        switch self {
        case .comfortable: return 10
        case .compact: return 8
        }
    }

    var lineLimit: Int {
        switch self {
        case .comfortable: return 3
        case .compact: return 2
        }
    }
}

struct TaskBoardView: View {
    @StateObject private var viewModel = TaskBoardViewModel()
    @State private var showCreateSheet = false
    @State private var draft = TaskCreationDraft()
    @State private var selectedCompactStatus = TaskStatus.planned

    var body: some View {
        GeometryReader { geometry in
            let layout = TaskBoardLayoutMode.from(width: geometry.size.width)

            VStack(alignment: .leading, spacing: 16) {
                TaskBoardHeader(
                    totalTasks: viewModel.allTasks.count,
                    activeStatuses: TaskStatus.allCases.filter { !viewModel.tasks(for: $0).isEmpty },
                    isCreateEnabled: viewModel.statusMessage == nil,
                    onCreate: openCreateSheet
                )

                if let statusMessage = viewModel.statusMessage {
                    EmptyStateView(
                        icon: "rectangle.stack.badge.person.crop",
                        title: statusMessage
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(TaskBoardSurface(cornerRadius: 28))
                } else if viewModel.allTasks.isEmpty {
                    TaskBoardEmptyState(onCreate: openCreateSheet)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if layout == .stacked {
                    TaskBoardStackedLayout(
                        selectedStatus: $selectedCompactStatus,
                        tasksForStatus: viewModel.tasks(for: selectedCompactStatus),
                        allCounts: TaskStatus.allCases.reduce(into: [TaskStatus: Int]()) { counts, status in
                            counts[status] = viewModel.tasks(for: status).count
                        },
                        density: layout.cardDensity,
                        onCreate: openCreateSheet,
                        onDispatch: viewModel.dispatch,
                        onStatusChange: viewModel.moveTask
                    )
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: layout.spacing) {
                            ForEach(TaskStatus.allCases, id: \.self) { status in
                                TaskLaneColumn(
                                    status: status,
                                    tasks: viewModel.tasks(for: status),
                                    width: layout.columnWidth,
                                    density: layout.cardDensity,
                                    onCreate: status == .planned ? openCreateSheet : nil,
                                    onDispatch: viewModel.dispatch,
                                    onStatusChange: viewModel.moveTask
                                )
                            }
                        }
                        .padding(.bottom, 2)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(TaskBoardBackdrop())
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .systemRed).opacity(0.88))
                    )
                    .padding(.bottom, 14)
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            TaskCreationSheet(
                draft: $draft,
                dependencyOptions: viewModel.availableDependencies(),
                isSubmitting: viewModel.isCreating,
                submissionError: viewModel.creationError,
                onCancel: { showCreateSheet = false },
                onSubmit: submitDraft
            )
        }
        .onAppear { viewModel.activate() }
    }

    private func openCreateSheet() {
        draft.reset()
        viewModel.clearCreationError()
        showCreateSheet = true
    }

    private func submitDraft() {
        Task {
            let created = await viewModel.createTask(from: draft)
            if created {
                draft.reset()
                showCreateSheet = false
                selectedCompactStatus = .planned
            }
        }
    }
}

private struct TaskBoardHeader: View {
    let totalTasks: Int
    let activeStatuses: [TaskStatus]
    let isCreateEnabled: Bool
    let onCreate: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Task Board")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                ForEach(activeStatuses.prefix(3), id: \.self) { status in
                    TaskBoardStatChip(
                        label: status.displayName,
                        value: nil,
                        tint: status.tint
                    )
                }

                if totalTasks > 0 {
                    TaskBoardStatChip(
                        label: "Total",
                        value: "\(totalTasks)",
                        tint: Color(nsColor: .systemBlue)
                    )
                }
            }

            Button(action: onCreate) {
                Label("New Task", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(!isCreateEnabled)
            .opacity(isCreateEnabled ? 1 : 0.55)
            .background(
                Capsule()
                    .fill(Color.accentColor.opacity(0.16))
            )
            .overlay(
                Capsule()
                    .stroke(Color.accentColor.opacity(0.24), lineWidth: 1)
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(TaskBoardSurface(cornerRadius: 26))
    }

    private var subtitle: String {
        if totalTasks == 0 {
            return "Create planned work, then move it through the project lifecycle."
        }
        let laneCount = max(activeStatuses.count, 1)
        return "\(totalTasks) task\(totalTasks == 1 ? "" : "s") across \(laneCount) active lane\(laneCount == 1 ? "" : "s")."
    }
}

private struct TaskBoardStatChip: View {
    let label: String
    let value: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.primary.opacity(0.05))
        )
    }
}

private struct TaskBoardStackedLayout: View {
    @Binding var selectedStatus: TaskStatus
    let tasksForStatus: [TaskItem]
    let allCounts: [TaskStatus: Int]
    let density: TaskCardDensity
    let onCreate: () -> Void
    let onDispatch: (TaskItem) -> Void
    let onStatusChange: (TaskItem, TaskStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button {
                            selectedStatus = status
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: status.symbolName)
                                    .font(.system(size: 11, weight: .semibold))
                                Text(status.displayName)
                                    .font(.system(size: 12, weight: .semibold))
                                Text("\(allCounts[status, default: 0])")
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectedStatus == status ? status.tint.opacity(0.18) : Color.primary.opacity(0.05))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(selectedStatus == status ? status.tint.opacity(0.3) : Color.primary.opacity(0.05), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }

            TaskLaneColumn(
                status: selectedStatus,
                tasks: tasksForStatus,
                width: nil,
                density: density,
                onCreate: selectedStatus == .planned ? onCreate : nil,
                onDispatch: onDispatch,
                onStatusChange: onStatusChange
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct TaskLaneColumn: View {
    let status: TaskStatus
    let tasks: [TaskItem]
    let width: CGFloat?
    let density: TaskCardDensity
    let onCreate: (() -> Void)?
    let onDispatch: (TaskItem) -> Void
    let onStatusChange: (TaskItem, TaskStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: status.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(status.tint)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(status.tint.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(status.displayName)
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(tasks.count) task\(tasks.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let onCreate {
                    Button(action: onCreate) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .background(
                        Circle()
                            .fill(Color.accentColor.opacity(0.14))
                    )
                }
            }

            Divider()

            if tasks.isEmpty {
                TaskLaneEmptyState(status: status, onCreate: onCreate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        ForEach(tasks) { task in
                            TaskCard(
                                task: task,
                                density: density,
                                onDispatch: { onDispatch(task) },
                                onStatusChange: { onStatusChange(task, $0) }
                            )
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .frame(width: width, alignment: .topLeading)
        .frame(maxWidth: width == nil ? .infinity : width, maxHeight: .infinity, alignment: .topLeading)
        .background(TaskBoardSurface(cornerRadius: 24))
    }
}

private struct TaskLaneEmptyState: View {
    let status: TaskStatus
    let onCreate: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: status.symbolName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(status.tint.opacity(0.8))
            Text("No \(status.displayName.lowercased()) tasks")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)

            if let onCreate {
                Button("Create in Planned", action: onCreate)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }

    private var message: String {
        if status == .planned {
            return "Create a task here and shape it before dispatch."
        }
        return "Tasks will appear here as work progresses."
    }
}

private struct TaskCard: View {
    let task: TaskItem
    let density: TaskCardDensity
    let onDispatch: () -> Void
    let onStatusChange: (TaskStatus) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: density.verticalSpacing) {
            HStack(alignment: .top, spacing: 10) {
                TaskPriorityPill(priority: task.priority)

                Spacer(minLength: 0)

                if let queue = task.queuedPosition {
                    TaskMetaBadge(text: "Queue \(queue)")
                }

                Menu {
                    if task.status == .ready {
                        Button("Dispatch", action: onDispatch)
                    }
                    Divider()
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button("Move to \(status.displayName)") {
                            onStatusChange(status)
                        }
                        .disabled(status == task.status)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(density.titleFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(task.goal)
                    .font(density.bodyFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(density.lineLimit)
            }

            if !task.scope.isEmpty || !task.acceptanceCriteria.isEmpty || !task.dependencies.isEmpty {
                FlowingTagRow(tags: metadataTags)
            }

            HStack(spacing: 8) {
                if let executionMode = task.executionMode {
                    TaskMetaBadge(text: executionMode.capitalized)
                }
                if let branch = task.branch {
                    TaskMetaBadge(text: branch)
                }
                if task.worktreeID != nil {
                    TaskMetaBadge(text: "Worktree")
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    if let cost = task.cost {
                        Text(String(format: "$%.2f", cost))
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    Text(Self.relativeFormatter.localizedString(for: task.updatedAt, relativeTo: Date()))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if task.status == .ready {
                    Button(action: onDispatch) {
                        Label("Dispatch", systemImage: "play.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(task.status.tint.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 14, y: 8)
        .contextMenu {
            if task.status == .ready {
                Button("Dispatch", action: onDispatch)
                Divider()
            }
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button("Move to \(status.displayName)") {
                    onStatusChange(status)
                }
                .disabled(status == task.status)
            }
        }
    }

    private var metadataTags: [String] {
        var tags: [String] = []
        if !task.scope.isEmpty {
            tags.append("\(task.scope.count) scoped")
        }
        if !task.acceptanceCriteria.isEmpty {
            tags.append("\(task.acceptanceCriteria.count) checks")
        }
        if !task.dependencies.isEmpty {
            tags.append("\(task.dependencies.count) deps")
        }
        return tags
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct TaskPriorityPill: View {
    let priority: TaskPriority

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(priority.color)
                .frame(width: 7, height: 7)
            Text(priority.rawValue)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(priority.color.opacity(0.12))
        )
    }
}

private struct TaskMetaBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.primary.opacity(0.05))
            )
    }
}

private struct FlowingTagRow: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    TaskMetaBadge(text: tag)
                }
            }
        }
    }
}

private struct TaskBoardEmptyState: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.3.group.bubble.left")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.accentColor.opacity(0.75))
            Text("Nothing in the board yet")
                .font(.system(size: 20, weight: .semibold, design: .rounded))
            Text("Create your first planned task and it will appear here immediately.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Button(action: onCreate) {
                Label("Create Planned Task", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TaskBoardSurface(cornerRadius: 28))
    }
}

private struct TaskCreationSheet: View {
    @Binding var draft: TaskCreationDraft
    let dependencyOptions: [TaskItem]
    let isSubmitting: Bool
    let submissionError: String?
    let onCancel: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New Planned Task")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                    Text("Capture the task now; it stays planned until you move it forward.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    TaskCreationSection(title: "Essentials") {
                        TextField("Title", text: $draft.title)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Goal")
                                .font(.system(size: 12, weight: .semibold))
                            TextEditor(text: $draft.goal)
                                .frame(minHeight: 84)
                                .font(.system(size: 12))
                        }
                        Picker("Priority", selection: $draft.priority) {
                            ForEach(TaskPriority.allCases, id: \.self) { priority in
                                Text(priority.rawValue).tag(priority)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    TaskCreationSection(title: "Scope and Checks") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Scope")
                                .font(.system(size: 12, weight: .semibold))
                            TextEditor(text: $draft.scopeText)
                                .frame(minHeight: 72)
                                .font(.system(size: 12))
                            Text("One file or path per line.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Acceptance Criteria")
                                .font(.system(size: 12, weight: .semibold))
                            TextEditor(text: $draft.acceptanceCriteriaText)
                                .frame(minHeight: 84)
                                .font(.system(size: 12))
                            Text("Optional. Leave blank to use the backend default manual review check.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Constraints")
                                .font(.system(size: 12, weight: .semibold))
                            TextEditor(text: $draft.constraintsText)
                                .frame(minHeight: 72)
                                .font(.system(size: 12))
                            Text("Optional. One constraint per line.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    TaskCreationSection(title: "Dependencies") {
                        if dependencyOptions.isEmpty {
                            Text("No existing tasks are available to depend on yet.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(dependencyOptions) { option in
                                    Button {
                                        toggleDependency(option.id)
                                    } label: {
                                        HStack(alignment: .center, spacing: 10) {
                                            Image(systemName: draft.selectedDependencyIDs.contains(option.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(draft.selectedDependencyIDs.contains(option.id) ? Color.accentColor : .secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(option.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text(option.status.displayName)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .padding(.vertical, 4)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Text("Tasks with unmet dependencies may appear in Blocked after creation.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let validationMessage = draft.validationMessage {
                Text(validationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            } else if let submissionError {
                Text(submissionError)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button(action: onSubmit) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Create Task")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting || draft.validationMessage != nil)
            }
        }
        .padding(22)
        .frame(minWidth: 640, idealWidth: 680, minHeight: 720, idealHeight: 760)
        .background(TaskBoardBackdrop())
    }

    private func toggleDependency(_ id: String) {
        if draft.selectedDependencyIDs.contains(id) {
            draft.selectedDependencyIDs.remove(id)
        } else {
            draft.selectedDependencyIDs.insert(id)
        }
    }
}

private struct TaskCreationSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .background(TaskBoardSurface(cornerRadius: 22))
    }
}

private struct TaskBoardBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(nsColor: .underPageBackgroundColor),
                Color(nsColor: .controlBackgroundColor)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .fill(Color.white.opacity(0.02))
        )
        .ignoresSafeArea()
    }
}

private struct TaskBoardSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 18, y: 10)
    }
}

@MainActor
final class TaskBoardViewModel: ObservableObject {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    @Published var allTasks: [TaskItem] = []
    @Published var actionError: String?
    @Published var creationError: String?
    @Published var isCreating = false
    @Published private var viewState: ViewState = .waiting("Open a project to load tasks.")

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

    func activate() {
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
            allTasks[idx].updatedAt = Date()
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

final class TaskBoardPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "taskboard"
    let shouldPersist = false
    var title: String { "Task Board" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(TaskBoardView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
