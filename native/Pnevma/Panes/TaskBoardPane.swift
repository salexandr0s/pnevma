import SwiftUI
import Observation
import Cocoa

private struct WidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
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
    @State private var viewModel = TaskBoardViewModel()
    @State private var showCreateSheet = false
    @State private var draft = TaskCreationDraft()
    @State private var selectedCompactStatus = TaskStatus.planned
    @State private var layout: TaskBoardLayoutMode = .expanded

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TaskBoardHeader(
                totalTasks: viewModel.allTasks.count,
                activeStatuses: TaskStatus.allCases.filter { !viewModel.tasks(for: $0).isEmpty },
                isCreateEnabled: viewModel.statusMessage == nil,
                onCreate: openCreateSheet
            )

            if let statusMessage = viewModel.statusMessage {
                VStack(spacing: 8) {
                    if viewModel.isLoadingState {
                        ProgressView()
                            .controlSize(.small)
                    }
                    EmptyStateView(
                        icon: "rectangle.stack.badge.person.crop",
                        title: statusMessage
                    )
                }
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
                expandedBoard
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(key: WidthPreferenceKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(WidthPreferenceKey.self) { width in
            layout = TaskBoardLayoutMode.from(width: width)
        }
        .background(TaskBoardBackdrop())
        .overlay(alignment: .bottom) {
            ErrorBanner(message: viewModel.actionError)
        }
        // sheet(isPresented:) is intentional: the sheet creates a new task from a blank draft
        // with no pre-existing item, so sheet(item:) does not apply here.
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
        .task { await viewModel.activate() }
        .accessibilityIdentifier("pane.taskBoard")
    }

    @ViewBuilder
    private var expandedBoard: some View {
        let createAction: (() -> Void)? = openCreateSheet
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: layout.spacing) {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    TaskLaneColumn(
                        status: status,
                        tasks: viewModel.tasks(for: status),
                        width: layout.columnWidth,
                        density: layout.cardDensity,
                        onCreate: status == .planned ? createAction : nil,
                        onDispatch: viewModel.dispatch,
                        onStatusChange: viewModel.moveTask
                    )
                }
            }
            .padding(.bottom, 2)
        }
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
    @Environment(\.paneChromeContext) private var paneChromeContext

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if paneChromeContext.showsInlinePaneHeader {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Task Board")
                        .font(.system(size: 15, weight: .semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    AccessibilityMarker(
                        identifier: "pane.taskBoard.inlineHeader",
                        label: "Task Board inline header"
                    )
                    .frame(width: 1, height: 1)
                    .allowsHitTesting(false)
                }
                Spacer()
            }

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
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!isCreateEnabled)
            .opacity(isCreateEnabled ? 1 : 0.55)
            .keyboardShortcut("n", modifiers: .command)
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
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.caption.weight(.semibold))
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
                                    .font(.caption.weight(.semibold))
                                Text(status.displayName)
                                    .font(.callout.weight(.semibold))
                                Text("\(allCounts[status, default: 0])")
                                    .font(.caption.weight(.semibold))
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
            .scrollIndicators(.hidden)

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
                    .font(.body.weight(.semibold))
                    .foregroundStyle(status.tint)
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(status.tint.opacity(0.14))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(status.displayName)
                        .font(.body.weight(.semibold))
                    Text("\(tasks.count) task\(tasks.count == 1 ? "" : "s")")
                        .font(.caption)
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
                    .accessibilityLabel("Create task")
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
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 10) {
                        ForEach(tasks) { task in
                            TaskCard(
                                task: task,
                                density: density,
                                onDispatch: { onDispatch(task) },
                                onStatusChange: { onStatusChange(task, $0) }
                            )
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
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
                .font(.title2.weight(.semibold))
                .foregroundStyle(status.tint.opacity(0.8))
            Text("No \(status.displayName.lowercased()) tasks")
                .font(.body.weight(.semibold))
            Text(message)
                .font(.callout)
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
                .accessibilityLabel("Task actions")
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
                        Text(cost, format: .currency(code: "USD"))
                            .font(.callout.weight(.semibold))
                    }
                    Text(Self.relativeFormatter.localizedString(for: task.updatedAt, relativeTo: Date.now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if task.status == .ready {
                    Button(action: onDispatch) {
                        Label("Dispatch", systemImage: "play.fill")
                            .font(.callout.weight(.semibold))
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
                .font(.caption.weight(.semibold))
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
            .font(.caption2.weight(.medium))
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
        .scrollIndicators(.hidden)
    }
}

private struct TaskBoardEmptyState: View {
    let onCreate: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.3.group.bubble.left")
                .font(.title.weight(.semibold))
                .foregroundStyle(Color.accentColor.opacity(0.75))
            Text("Nothing in the board yet")
                .font(.title2.weight(.semibold))
            Text("Create your first planned task and it will appear here immediately.")
                .font(.body)
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
                        .font(.title2.weight(.semibold))
                    Text("Capture the task now; it stays planned until you move it forward.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    TaskCreationSection(title: "Essentials") {
                        TextField("Title", text: $draft.title)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Goal")
                                .font(.callout.weight(.semibold))
                            TextField("", text: $draft.goal, axis: .vertical)
                                .lineLimit(3...6)
                                .font(.callout)
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
                                .font(.callout.weight(.semibold))
                            TextEditor(text: $draft.scopeText)
                                .frame(minHeight: 72)
                                .font(.callout)
                            Text("One file or path per line.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Acceptance Criteria")
                                .font(.callout.weight(.semibold))
                            TextEditor(text: $draft.acceptanceCriteriaText)
                                .frame(minHeight: 84)
                                .font(.callout)
                            Text("Optional. Leave blank to use the backend default manual review check.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Constraints")
                                .font(.callout.weight(.semibold))
                            TextEditor(text: $draft.constraintsText)
                                .frame(minHeight: 72)
                                .font(.callout)
                            Text("Optional. One constraint per line.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    TaskCreationSection(title: "Dependencies") {
                        if dependencyOptions.isEmpty {
                            Text("No existing tasks are available to depend on yet.")
                                .font(.callout)
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
                                                    .font(.body.weight(.semibold))
                                                    .foregroundStyle(.primary)
                                                    .lineLimit(1)
                                                Text(option.status.displayName)
                                                    .font(.caption)
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
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            if let validationMessage = draft.validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            } else if let submissionError {
                Text(submissionError)
                    .font(.callout)
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
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .background(TaskBoardSurface(cornerRadius: 22))
    }
}

private struct TaskBoardBackdrop: View {
    var body: some View {
        Color.clear.ignoresSafeArea()
    }
}

private struct TaskBoardSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(ChromeSurfaceStyle.groupedCard.color)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(nsColor: ChromeSurfaceStyle.groupedCard.separatorColor).opacity(0.45), lineWidth: 1)
            )
    }
}

final class TaskBoardPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "taskboard"
    let shouldPersist = true
    var title: String { "Task Board" }

    init(frame: NSRect, chromeContext: PaneChromeContext = .standard) {
        super.init(frame: frame)
        _ = addSwiftUISubview(TaskBoardView(), chromeContext: chromeContext)
    }

    required init?(coder: NSCoder) { fatalError() }
}
