import SwiftUI
import Cocoa

// MARK: - Data Models

struct DiffFile: Identifiable, Decodable {
    var id: String { path }
    let path: String
    let hunks: [DiffHunk]

    /// Inferred status based on hunk content — used for the file-tree icon/color.
    var inferredStatus: String {
        let allLines = hunks.flatMap { $0.lines }
        let hasAdditions = allLines.contains { $0.type == .addition }
        let hasDeletions = allLines.contains { $0.type == .deletion }
        switch (hasAdditions, hasDeletions) {
        case (true, false): return "added"
        case (false, true): return "deleted"
        default: return "modified"
        }
    }
}

struct DiffHunk: Identifiable, Decodable {
    let id = UUID()
    let header: String
    /// Raw line strings from the backend, decoded into DiffLine objects.
    let lines: [DiffLine]

    private enum CodingKeys: String, CodingKey { case header, lines }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        header = try container.decode(String.self, forKey: .header)
        let rawLines = try container.decode([String].self, forKey: .lines)
        lines = rawLines.map(DiffLine.init(rawString:))
    }
}

struct DiffLine: Identifiable {
    let id = UUID()
    let type: DiffLineType
    /// The line content without the leading prefix character.
    let content: String

    /// Parse a raw line string (e.g. "+foo", "-bar", " baz") into a DiffLine.
    init(rawString: String) {
        switch rawString.first {
        case "+":
            type = .addition
            content = String(rawString.dropFirst())
        case "-":
            type = .deletion
            content = String(rawString.dropFirst())
        default:
            type = .context
            // Drop the leading space when present; keep content as-is otherwise.
            content = rawString.hasPrefix(" ") ? String(rawString.dropFirst()) : rawString
        }
    }
}

enum DiffLineType {
    case context, addition, deletion
}

/// Top-level response from the `review.diff` backend command.
private struct TaskDiffResponse: Decodable {
    let taskId: String
    let diffPath: String
    let files: [DiffFile]
}

/// A task item carrying just the fields needed for the diff task selector.
struct DiffTaskItem: Identifiable {
    let id: String
    let title: String
    let status: String
}

private struct BackendDiffTask: Decodable {
    let id: String
    let title: String
    let status: String
    let priority: String
}

// MARK: - DiffView

struct DiffView: View {
    @StateObject private var viewModel = DiffViewModel()

    var body: some View {
        Group {
            if let message = viewModel.statusMessage {
                EmptyStateView(
                    icon: "doc.text.magnifyingglass",
                    title: message
                )
            } else {
                HSplitView {
                    taskAndFileSidebar
                    diffContent
                }
            }
        }
        .onAppear { viewModel.activate() }
    }

    // MARK: Sidebar

    private var taskAndFileSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Task picker
            Text("Task")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            Picker("", selection: $viewModel.selectedTaskId) {
                Text("Select a task").tag(Optional<String>.none)
                ForEach(viewModel.tasks) { task in
                    Text(task.title)
                        .tag(Optional(task.id))
                }
            }
            .labelsHidden()
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            Divider()

            // File list
            Text("Files")
                .font(.headline)
                .padding(12)

            Divider()

            if viewModel.isLoadingDiff {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(viewModel.files, selection: $viewModel.selectedFile) { file in
                    HStack(spacing: 6) {
                        Image(systemName: fileIcon(file.inferredStatus))
                            .foregroundStyle(fileColor(file.inferredStatus))
                            .frame(width: 16)
                        Text(file.path)
                            .font(.body)
                            .lineLimit(1)
                    }
                    .tag(file.id)
                }
                .listStyle(.plain)
            }
        }
        .frame(minWidth: 180, maxWidth: 260)
    }

    // MARK: Diff content

    private var diffContent: some View {
        ScrollView {
            if let file = viewModel.selectedDiffFile {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(file.hunks) { hunk in
                        Text(hunk.header)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08))

                        ForEach(hunk.lines) { line in
                            DiffLineView(line: line)
                        }
                    }
                }
            } else if let error = viewModel.diffError {
                Text(error)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else if viewModel.selectedTaskId == nil {
                Text("Select a task to view its diff")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                Text("Select a file to view diff")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
    }

    // MARK: Helpers

    private func fileIcon(_ status: String) -> String {
        switch status {
        case "added": return "plus.circle.fill"
        case "deleted": return "minus.circle.fill"
        default: return "pencil.circle.fill"
        }
    }

    private func fileColor(_ status: String) -> Color {
        switch status {
        case "added": return .green
        case "deleted": return .red
        default: return .orange
        }
    }
}

// MARK: - DiffLineView

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            // Prefix symbol
            Text(prefixChar)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(prefixColor)
                .frame(width: 16)

            // Content
            Text(line.content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .background(backgroundColor)
    }

    private var prefixChar: String {
        switch line.type {
        case .addition: return "+"
        case .deletion: return "-"
        case .context: return " "
        }
    }

    private var prefixColor: Color {
        switch line.type {
        case .addition: return .green
        case .deletion: return .red
        case .context: return .secondary
        }
    }

    private var backgroundColor: Color {
        switch line.type {
        case .addition: return .green.opacity(0.08)
        case .deletion: return .red.opacity(0.08)
        case .context: return .clear
        }
    }
}

// MARK: - ViewModel

@MainActor
final class DiffViewModel: ObservableObject {
    @Published var tasks: [DiffTaskItem] = []
    @Published var files: [DiffFile] = []
    @Published var selectedFile: String?
    @Published var isLoadingDiff = false
    @Published var diffError: String?

    @Published var selectedTaskId: String? = nil {
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

    @Published private var viewState: ViewState = .waiting("Open a project to load diffs.")

    private let commandBus: (any CommandCalling)?
    private let activationHub: ActiveWorkspaceActivationHub
    private var activationObserverID: UUID?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.activationHub = activationHub

        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
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

    var selectedDiffFile: DiffFile? {
        guard let sel = selectedFile else { return nil }
        return files.first { $0.id == sel }
    }

    /// Called from `.onAppear` to sync with the current activation state immediately.
    func activate() {
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
}

// MARK: - NSView Wrapper

final class DiffPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "diff"
    let shouldPersist = false
    var title: String { "Diff" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(DiffView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
