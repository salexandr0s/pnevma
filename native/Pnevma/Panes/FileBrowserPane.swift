import SwiftUI
import Observation
import Cocoa

// MARK: - Data Models

struct FileNode: Identifiable, Codable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileNode]?
    let size: Int64?
}

private struct FileTreeParams: Encodable {
    let path: String?
}

// MARK: - FileBrowserView

struct FileBrowserView: View {
    @State private var viewModel = FileBrowserViewModel()
    @Environment(GhosttyThemeProvider.self) var theme

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Files")
                        .font(.headline)
                    Spacer()
                    Button(action: { viewModel.refresh() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)

                Divider()

                if !viewModel.isProjectOpen {
                    EmptyStateView(
                        icon: "folder",
                        title: "No project open",
                        message: "Open a project to browse files"
                    )
                } else if viewModel.isLoadingRoot {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading files...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.rootNodes.isEmpty {
                    EmptyStateView(
                        icon: "folder",
                        title: "No files found",
                        message: "This directory is empty"
                    )
                } else {
                    FileTreeList(viewModel: viewModel)
                }
            }
            .frame(minWidth: 200, maxWidth: 300)

            VStack {
                if let content = viewModel.previewContent {
                    ScrollView {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if viewModel.isLoadingPreview {
                    Text("Loading...")
                        .foregroundStyle(.secondary)
                } else if viewModel.selectedFilePath != nil {
                    Text("Preview unavailable")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Select a file to preview")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: theme.backgroundColor))
            }
        }
        .task { await viewModel.activate() }
    }
}

// MARK: - Tree Views

private struct FileTreeList: View {
    var viewModel: FileBrowserViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.rootNodes) { node in
                    FileTreeRow(node: node, depth: 0, viewModel: viewModel)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct FileTreeRow: View {
    let node: FileNode
    let depth: Int
    var viewModel: FileBrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if node.isDirectory {
                    Button(action: { viewModel.toggleDirectory(node) }) {
                        Image(systemName: viewModel.isExpanded(node.path) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear
                        .frame(width: 12, height: 12)
                }

                Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(node.name))
                    .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                    .frame(width: 16)

                Text(node.name)
                    .font(.body)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if viewModel.isLoadingDirectory(node.path) {
                    ProgressView()
                        .controlSize(.small)
                } else if let size = node.size, !node.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .onTapGesture {
                viewModel.select(node)
            }

            if node.isDirectory && viewModel.isExpanded(node.path) {
                if let children = node.children {
                    if children.isEmpty {
                        Text("Empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, CGFloat(depth + 1) * 14 + 42)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(children) { child in
                            FileTreeRow(node: child, depth: depth + 1, viewModel: viewModel)
                        }
                    }
                } else if viewModel.isLoadingDirectory(node.path) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat(depth + 1) * 14 + 24)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var rowBackground: some View {
        Group {
            if viewModel.selectedPath == node.path {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.14))
            } else {
                Color.clear
            }
        }
    }

    private func fileIcon(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "rs": return "doc.text"
        case "ts", "tsx", "js", "jsx": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml": return "doc.badge.gearshape"
        case "md": return "doc.richtext"
        case "png", "jpg", "jpeg", "gif", "svg": return "photo"
        default: return "doc"
        }
    }
}

// MARK: - ViewModel

@Observable @MainActor
final class FileBrowserViewModel {
    var rootNodes: [FileNode] = []
    var expandedPaths: Set<String> = []
    var selectedPath: String?
    private(set) var selectedFilePath: String?
    var previewContent: String?
    var actionError: String?
    private(set) var isProjectOpen = false
    private(set) var isLoadingRoot = false
    private(set) var isLoadingPreview = false
    private(set) var loadingDirectories: Set<String> = []

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private var activationObserverID: UUID?
    @ObservationIgnored
    private var activationGeneration: UInt64 = 0
    @ObservationIgnored
    private var rootLoadToken: UInt64 = 0
    @ObservationIgnored
    private var previewLoadToken: UInt64 = 0
    @ObservationIgnored
    private var rootLoadTask: Task<Void, Never>?
    @ObservationIgnored
    private var previewLoadTask: Task<Void, Never>?
    @ObservationIgnored
    private var directoryLoadTasks: [String: Task<Void, Never>] = [:]

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

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    func refresh() {
        clearContentState()
        loadRoot()
    }

    func select(_ node: FileNode) {
        selectedPath = node.path
        actionError = nil

        if node.isDirectory {
            selectedFilePath = nil
            previewContent = nil
            isLoadingPreview = false
            return
        }

        selectedFilePath = node.path
        loadPreview(path: node.path)
    }

    func toggleDirectory(_ node: FileNode) {
        guard node.isDirectory else { return }
        selectedPath = node.path

        if expandedPaths.contains(node.path) {
            expandedPaths.remove(node.path)
            return
        }

        expandedPaths.insert(node.path)
        guard children(for: node.path) == nil else {
            return
        }
        loadDirectory(path: node.path)
    }

    func isExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path)
    }

    func isLoadingDirectory(_ path: String) -> Bool {
        loadingDirectories.contains(path)
    }

    private func loadRoot() {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }

        rootLoadTask?.cancel()
        rootLoadToken &+= 1
        let loadToken = rootLoadToken
        let generation = activationGeneration

        isLoadingRoot = true
        rootLoadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activationGeneration == generation && self.rootLoadToken == loadToken {
                    self.isLoadingRoot = false
                }
            }

            do {
                let nodes: [FileNode] = try await bus.call(
                    method: "workspace.files.tree",
                    params: nil
                )
                guard self.activationGeneration == generation, self.rootLoadToken == loadToken else {
                    return
                }
                self.rootNodes = nodes
                self.expandedPaths = []
                self.actionError = nil
            } catch {
                guard self.activationGeneration == generation, self.rootLoadToken == loadToken else {
                    return
                }
                self.handleLoadFailure(error)
            }
        }
    }

    private func loadDirectory(path: String) {
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        guard directoryLoadTasks[path] == nil else { return }

        let generation = activationGeneration
        loadingDirectories.insert(path)
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activationGeneration == generation {
                    self.loadingDirectories.remove(path)
                    self.directoryLoadTasks.removeValue(forKey: path)
                }
            }

            do {
                let children: [FileNode] = try await bus.call(
                    method: "workspace.files.tree",
                    params: FileTreeParams(path: path)
                )
                guard self.activationGeneration == generation else {
                    return
                }
                self.setChildren(children, for: path)
                self.actionError = nil
            } catch {
                guard self.activationGeneration == generation else {
                    return
                }
                self.handleLoadFailure(error)
            }
        }
        directoryLoadTasks[path] = task
    }

    private func loadPreview(path: String) {
        previewContent = nil
        isLoadingPreview = true

        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            isLoadingPreview = false
            return
        }

        previewLoadTask?.cancel()
        previewLoadToken &+= 1
        let previewToken = previewLoadToken
        let generation = activationGeneration

        previewLoadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activationGeneration == generation && self.previewLoadToken == previewToken {
                    self.isLoadingPreview = false
                }
            }

            do {
                struct Params: Encodable {
                    let path: String
                    let mode: String
                }

                struct FilePreview: Decodable {
                    let content: String
                }

                let preview: FilePreview = try await bus.call(
                    method: "workspace.file.open",
                    params: Params(path: path, mode: "preview")
                )
                guard self.activationGeneration == generation,
                      self.previewLoadToken == previewToken,
                      self.selectedFilePath == path else {
                    return
                }
                self.previewContent = preview.content
                self.actionError = nil
            } catch {
                guard self.activationGeneration == generation,
                      self.previewLoadToken == previewToken,
                      self.selectedFilePath == path else {
                    return
                }
                self.handleLoadFailure(error)
            }
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        invalidatePendingLoads()

        switch state {
        case .idle, .opening, .closed:
            isProjectOpen = false
            clearContentState()
        case .open:
            isProjectOpen = true
            clearContentState()
            loadRoot()
        case .failed(_, _, let message):
            isProjectOpen = false
            clearContentState()
            actionError = message
            scheduleDismissActionError()
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            isProjectOpen = false
            clearContentState()
            actionError = nil
            return
        }

        actionError = error.localizedDescription
        scheduleDismissActionError()
    }

    private func invalidatePendingLoads() {
        activationGeneration &+= 1
        rootLoadToken &+= 1
        previewLoadToken &+= 1

        rootLoadTask?.cancel()
        rootLoadTask = nil

        previewLoadTask?.cancel()
        previewLoadTask = nil

        for task in directoryLoadTasks.values {
            task.cancel()
        }
        directoryLoadTasks.removeAll()

        isLoadingRoot = false
        isLoadingPreview = false
        loadingDirectories.removeAll()
    }

    private func clearContentState() {
        rootNodes = []
        expandedPaths = []
        selectedPath = nil
        selectedFilePath = nil
        previewContent = nil
    }

    private func children(for path: String) -> [FileNode]? {
        Self.children(for: path, in: rootNodes)
    }

    private func setChildren(_ children: [FileNode], for path: String) {
        _ = Self.setChildren(children, for: path, in: &rootNodes)
    }

    private static func children(for path: String, in nodes: [FileNode]) -> [FileNode]? {
        for node in nodes {
            if node.path == path {
                return node.children
            }

            if let childNodes = node.children,
               let loadedChildren = children(for: path, in: childNodes) {
                return loadedChildren
            }
        }
        return nil
    }

    private static func setChildren(
        _ children: [FileNode],
        for path: String,
        in nodes: inout [FileNode]
    ) -> Bool {
        for index in nodes.indices {
            if nodes[index].path == path {
                nodes[index].children = children
                return true
            }

            if var childNodes = nodes[index].children,
               setChildren(children, for: path, in: &childNodes) {
                nodes[index].children = childNodes
                return true
            }
        }
        return false
    }

    private func scheduleDismissActionError() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.actionError = nil
        }
    }
}

// MARK: - NSView Wrapper

final class FileBrowserPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "file_browser"
    let shouldPersist = false
    var title: String { "Files" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(FileBrowserView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
