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
    let query: String?
    let limit: Int?
    let recursive: Bool?
}


// MARK: - FileBrowserView

struct FileBrowserView: View {
    @State private var viewModel = FileBrowserViewModel()
    @State private var isReaderMode = false
    @State private var isViewerVisible = true
    @State private var showDiscardAlert = false
    @State private var pendingNode: FileNode?

    private var isMarkdownFile: Bool {
        guard let path = viewModel.selectedFilePath else { return false }
        return (path as NSString).pathExtension.lowercased() == "md"
    }

    private var isBinaryPreview: Bool {
        viewModel.isBinary
    }

    private var isReadOnly: Bool {
        isBinaryPreview || viewModel.isTruncated
    }

    var body: some View {
        NativePaneScaffold(
            title: "Files",
            subtitle: "Browse project content and edit or preview the selected file",
            systemImage: "folder",
            role: .document
        ) {
            Button(action: { viewModel.refresh() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)

            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isViewerVisible.toggle() } }) {
                Image(systemName: "sidebar.right")
                    .foregroundStyle(isViewerVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(isViewerVisible ? "Hide file viewer" : "Show file viewer")
        } content: {
            if isViewerVisible {
                NativeSplitScaffold(
                    sidebarMinWidth: 200,
                    sidebarIdealWidth: 280,
                    sidebarMaxWidth: 320
                ) {
                    sidebarContent
                } detail: {
                    viewerContent
                }
            } else {
                sidebarContent
            }
        }
        .overlay(alignment: .bottom) { ErrorBanner(message: viewModel.actionError) }
        .alert("Unsaved Changes", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                viewModel.discardChanges()
                if let node = pendingNode {
                    pendingNode = nil
                    viewModel.select(node)
                }
            }
            Button("Save") {
                let node = pendingNode
                pendingNode = nil
                viewModel.saveFile {
                    if let node { viewModel.select(node) }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingNode = nil
            }
        } message: {
            Text("You have unsaved changes. What would you like to do?")
        }
        .task { await viewModel.activate() }
        .accessibilityIdentifier("pane.fileBrowser")
    }

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            fileSearchBar
            Divider()

            if let waitingMessage = viewModel.projectStatusMessage {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(waitingMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.isProjectOpen {
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
            } else if viewModel.isSearching && viewModel.visibleRootNodes.isEmpty {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("Searching files...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.hasActiveSearch && viewModel.visibleRootNodes.isEmpty {
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "No matching files",
                    message: "Try a different file name or path"
                )
            } else if viewModel.visibleRootNodes.isEmpty {
                EmptyStateView(
                    icon: "folder",
                    title: "No files found",
                    message: "This directory is empty"
                )
            } else {
                FileTreeList(viewModel: viewModel, onSelect: { node in
                    handleFileSelect(node)
                })
            }
        }
    }

    private var viewerContent: some View {
        VStack(spacing: 0) {
            if viewModel.previewContent != nil {
                editorToolbar

                Divider()

                if isReaderMode && isMarkdownFile {
                    MarkdownReaderView(content: viewModel.editableContent)
                } else if isBinaryPreview {
                    Text(viewModel.previewContent ?? "")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.isTruncated {
                    ScrollView {
                        Text(viewModel.previewContent ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    TextEditor(text: $viewModel.editableContent)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                }
            } else if viewModel.isLoadingPreview {
                Text("Loading...")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.selectedFilePath != nil {
                Text("Preview unavailable")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(
                    icon: "doc.text",
                    title: "Select a file to preview"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: viewModel.selectedFilePath) {
            isReaderMode = false
        }
    }

    // MARK: Editor Toolbar

    private var editorToolbar: some View {
        HStack(spacing: 8) {
            if viewModel.isDirty {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 6, height: 6)
                Text("Modified")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.isTruncated {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                Text("Truncated — read only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isMarkdownFile {
                Button {
                    isReaderMode.toggle()
                } label: {
                    Label(
                        isReaderMode ? "Source" : "Reader",
                        systemImage: isReaderMode ? "chevron.left.forwardslash.chevron.right" : "doc.richtext"
                    )
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if viewModel.isDirty {
                Button("Discard") {
                    viewModel.discardChanges()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                viewModel.saveFile()
            } label: {
                if viewModel.isSaving {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Save")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!viewModel.isDirty || viewModel.isSaving || isReadOnly)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var fileSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search files...", text: $viewModel.searchQuery)
                .textFieldStyle(.plain)
                .onChange(of: viewModel.searchQuery) {
                    viewModel.searchQueryDidChange()
                }
                .onSubmit {
                    viewModel.searchQueryDidChange(immediate: true)
                }

            if viewModel.isSearching {
                ProgressView()
                    .controlSize(.small)
            }

            if viewModel.hasActiveSearch {
                Button("Clear search", systemImage: "xmark.circle.fill", action: clearSearch)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    // MARK: File Selection with Dirty Guard

    private func handleFileSelect(_ node: FileNode) {
        if viewModel.isDirty && !node.isDirectory {
            pendingNode = node
            showDiscardAlert = true
        } else {
            viewModel.select(node)
        }
    }

    private func clearSearch() {
        viewModel.clearSearch()
    }
}

// MARK: - Tree Views

private struct FileTreeList: View {
    var viewModel: FileBrowserViewModel
    var onSelect: (FileNode) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.visibleRootNodes) { node in
                    FileTreeRow(node: node, depth: 0, viewModel: viewModel, onSelect: onSelect)
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
    var onSelect: (FileNode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if node.isDirectory && !viewModel.hasActiveSearch {
                    Button(action: { viewModel.toggleDirectory(node) }) {
                        Image(systemName: viewModel.isExpanded(node.path) ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                } else if node.isDirectory {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 12, height: 12)
                        .accessibilityHidden(true)
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
            .padding(.leading, CGFloat(depth) * DesignTokens.Layout.treeIndent + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
            .accessibilityAddTraits(.isButton)
            .onTapGesture(count: 2) {
                if node.isDirectory && !viewModel.hasActiveSearch {
                    viewModel.toggleDirectory(node)
                }
            }
            .onTapGesture {
                onSelect(node)
            }

            if node.isDirectory && viewModel.shouldShowChildren(for: node) {
                if let children = node.children {
                    if children.isEmpty {
                        Text("Empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, CGFloat(depth + 1) * DesignTokens.Layout.treeIndent + 42)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(children) { child in
                            FileTreeRow(node: child, depth: depth + 1, viewModel: viewModel, onSelect: onSelect)
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
                    .padding(.leading, CGFloat(depth + 1) * DesignTokens.Layout.treeIndent + 24)
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
    var searchQuery = ""
    var expandedPaths: Set<String> = []
    var selectedPath: String?
    private(set) var selectedFilePath: String?
    var previewContent: String?
    /// The original content as loaded — used for dirty tracking.
    private(set) var originalContent: String?
    var editableContent: String = ""
    private(set) var isBinary = false
    private(set) var isTruncated = false
    private(set) var isSaving = false
    var actionError: String?
    private(set) var isProjectOpen = false
    private(set) var projectStatusMessage: String?
    private(set) var isLoadingRoot = false
    private(set) var isLoadingPreview = false
    private(set) var isSearching = false
    private(set) var loadingDirectories: Set<String> = []
    private(set) var searchResults: [FileNode] = []

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private let searchDebounceDuration: Duration
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
    @ObservationIgnored
    private var searchLoadToken: UInt64 = 0
    @ObservationIgnored
    private var searchLoadTask: Task<Void, Never>?
    @ObservationIgnored
    private var deepLinkTask: Task<Void, Never>?
    @ObservationIgnored
    private var pendingDeepLinkPath: String?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        activationHub: ActiveWorkspaceActivationHub = .shared,
        searchDebounceDuration: Duration = .milliseconds(250)
    ) {
        self.commandBus = commandBus
        self.activationHub = activationHub
        self.searchDebounceDuration = searchDebounceDuration
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
        if hasActiveSearch {
            searchQueryDidChange(immediate: true)
        }
    }

    func openFile(at path: String) {
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !normalizedPath.isEmpty else { return }
        pendingDeepLinkPath = normalizedPath

        deepLinkTask?.cancel()
        deepLinkTask = Task { [weak self] in
            await self?.openFileWhenReady(at: normalizedPath)
        }
    }

    func clearPendingOpenFile() {
        deepLinkTask?.cancel()
        deepLinkTask = nil
        pendingDeepLinkPath = nil
    }

    func select(_ node: FileNode) {
        selectedPath = node.path
        actionError = nil

        if node.isDirectory {
            selectedFilePath = nil
            previewContent = nil
            originalContent = nil
            editableContent = ""
            isBinary = false
            isTruncated = false
            isLoadingPreview = false
            return
        }

        selectedFilePath = node.path
        loadPreview(path: node.path)
    }

    func clearSelection() {
        previewLoadTask?.cancel()
        previewLoadToken &+= 1
        selectedPath = nil
        selectedFilePath = nil
        previewContent = nil
        originalContent = nil
        editableContent = ""
        isBinary = false
        isTruncated = false
        isLoadingPreview = false
        actionError = nil
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

    var isDirty: Bool {
        editableContent != (originalContent ?? "")
    }

    func isExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path)
    }

    func isLoadingDirectory(_ path: String) -> Bool {
        loadingDirectories.contains(path)
    }

    var hasActiveSearch: Bool {
        !trimmedSearchQuery.isEmpty
    }

    var visibleRootNodes: [FileNode] {
        hasActiveSearch ? searchResults : rootNodes
    }

    func shouldShowChildren(for node: FileNode) -> Bool {
        guard node.isDirectory else { return false }
        return hasActiveSearch || isExpanded(node.path)
    }

    func searchQueryDidChange(immediate: Bool = false) {
        searchLoadTask?.cancel()
        searchLoadTask = nil
        searchLoadToken &+= 1

        guard hasActiveSearch else {
            isSearching = false
            searchResults = []
            return
        }

        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            isSearching = false
            searchResults = []
            return
        }

        guard isProjectOpen else {
            isSearching = false
            searchResults = []
            return
        }

        let query = trimmedSearchQuery
        let generation = activationGeneration
        let loadToken = searchLoadToken
        isSearching = true

        searchLoadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activationGeneration == generation && self.searchLoadToken == loadToken {
                    self.isSearching = false
                }
            }

            if !immediate {
                try? await Task.sleep(for: self.searchDebounceDuration)
            }

            guard !Task.isCancelled else { return }

            do {
                let matches: [FileNode] = try await bus.call(
                    method: "workspace.files.tree",
                    params: FileTreeParams(
                        path: nil,
                        query: query,
                        limit: 5_000,
                        recursive: true
                    )
                )
                guard self.activationGeneration == generation,
                      self.searchLoadToken == loadToken,
                      self.trimmedSearchQuery == query else {
                    return
                }
                self.searchResults = matches
                self.actionError = nil
            } catch {
                guard self.activationGeneration == generation,
                      self.searchLoadToken == loadToken,
                      self.trimmedSearchQuery == query else {
                    return
                }
                self.searchResults = []
                self.handleLoadFailure(error)
            }
        }
    }

    func clearSearch() {
        searchQuery = ""
        searchLoadTask?.cancel()
        searchLoadTask = nil
        searchLoadToken &+= 1
        isSearching = false
        searchResults = []
    }

    func saveFile(onComplete: (() -> Void)? = nil) {
        guard let path = selectedFilePath, isDirty else {
            onComplete?()
            return
        }
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            onComplete?()
            return
        }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            defer {
                self.isSaving = false
                onComplete?()
            }
            do {
                struct Params: Encodable {
                    let path: String
                    let content: String
                }
                struct WriteResult: Decodable {
                    let path: String
                    let bytes_written: UInt64
                }
                let _: WriteResult = try await bus.call(
                    method: "workspace.file.write",
                    params: Params(path: path, content: self.editableContent)
                )
                self.originalContent = self.editableContent
                self.previewContent = self.editableContent
                self.actionError = nil
            } catch {
                self.actionError = "Save failed: \(error.localizedDescription)"
                self.scheduleDismissActionError()
            }
        }
    }

    func discardChanges() {
        if let original = originalContent {
            editableContent = original
        }
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
                self.deepLinkTask = Task { [weak self] in
                    await self?.retryPendingDeepLinkSelectionIfNeeded()
                }
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
                    params: FileTreeParams(path: path, query: nil, limit: nil, recursive: nil)
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
                    let truncated: Bool?
                    let is_binary: Bool?  // swiftlint:disable:this identifier_name
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
                self.originalContent = preview.content
                self.editableContent = preview.content
                self.isBinary = preview.is_binary ?? false
                self.isTruncated = preview.truncated ?? false
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
        case .idle, .opening:
            isProjectOpen = false
            projectStatusMessage = "Waiting for project activation..."
            clearContentState()
        case .closed:
            isProjectOpen = false
            projectStatusMessage = nil
            clearContentState()
        case .open:
            isProjectOpen = true
            projectStatusMessage = nil
            clearContentState()
            loadRoot()
            if hasActiveSearch {
                searchQueryDidChange(immediate: true)
            }
        case .failed(_, _, let message):
            isProjectOpen = false
            projectStatusMessage = nil
            clearContentState()
            actionError = message
            scheduleDismissActionError()
        }
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            isProjectOpen = false
            projectStatusMessage = "Waiting for project activation..."
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
        searchLoadToken &+= 1

        rootLoadTask?.cancel()
        rootLoadTask = nil

        previewLoadTask?.cancel()
        previewLoadTask = nil

        searchLoadTask?.cancel()
        searchLoadTask = nil

        for task in directoryLoadTasks.values {
            task.cancel()
        }
        directoryLoadTasks.removeAll()

        isLoadingRoot = false
        isLoadingPreview = false
        isSearching = false
        loadingDirectories.removeAll()
        deepLinkTask?.cancel()
        deepLinkTask = nil
        pendingDeepLinkPath = nil
    }

    private func clearContentState() {
        rootNodes = []
        searchResults = []
        expandedPaths = []
        selectedPath = nil
        selectedFilePath = nil
        previewContent = nil
        originalContent = nil
        editableContent = ""
        isBinary = false
        isTruncated = false
        isSaving = false
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private func retryPendingDeepLinkSelectionIfNeeded() async {
        guard let path = pendingDeepLinkPath else { return }
        await openFileWhenReady(at: path)
    }

    private func openFileWhenReady(at path: String) async {
        guard isProjectOpen else {
            actionError = "Waiting for project activation..."
            scheduleDismissActionError()
            return
        }

        if rootNodes.isEmpty {
            loadRoot()
        }

        for _ in 0..<60 {
            guard !Task.isCancelled else { return }
            if isLoadingRoot {
                try? await Task.sleep(for: .milliseconds(50))
                continue
            }
            break
        }

        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty else { return }

        var currentPath = ""
        for parent in components.dropLast() {
            currentPath = currentPath.isEmpty ? parent : "\(currentPath)/\(parent)"
            guard !Task.isCancelled else { return }
            if children(for: currentPath) == nil {
                loadDirectory(path: currentPath)
            }
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                if !isLoadingDirectory(currentPath) {
                    break
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
            expandedPaths.insert(currentPath)
        }

        guard let node = findNode(path, in: rootNodes), !node.isDirectory else {
            actionError = "File not found: \(path)"
            scheduleDismissActionError()
            return
        }

        pendingDeepLinkPath = nil
        select(node)
    }

    private func findNode(_ path: String, in nodes: [FileNode]) -> FileNode? {
        for node in nodes {
            if node.path == path {
                return node
            }
            if let children = node.children,
               let match = findNode(path, in: children) {
                return match
            }
        }
        return nil
    }
}

// MARK: - Markdown Reader

private enum MarkdownBlock {
    case header(text: String, level: Int)
    case codeBlock(String)
    case bullet(text: String, ordered: Bool, raw: String?)
    case blockquote(String)
    case tableRow(String)
    case paragraph(String)
    case divider
    case spacer
}

private struct IndexedBlock: Identifiable {
    let id: Int
    let block: MarkdownBlock
}

struct MarkdownReaderView: View {
    let content: String
    @State private var parsedBlocks: [IndexedBlock] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(parsedBlocks) { item in
                    renderBlock(item.block)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .task(id: content) {
            parsedBlocks = buildBlocks()
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MarkdownBlock) -> some View {
        switch block {
        case .header(let text, let level): headerView(text, level: level)
        case .codeBlock(let code): codeBlockView(code)
        case .bullet(let text, let ordered, let raw): bulletView(text, ordered: ordered, raw: raw)
        case .blockquote(let text): blockquoteView(text)
        case .tableRow(let line): tableRowView(line)
        case .paragraph(let text): paragraphView(text)
        case .divider: Divider().padding(.vertical, 8)
        case .spacer: Spacer().frame(height: 8)
        }
    }

    private func buildBlocks() -> [IndexedBlock] {
        var result: [IndexedBlock] = []
        var codeBlock: [String] = []
        var inCode = false

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    result.append(IndexedBlock(id: result.count, block: .codeBlock(codeBlock.joined(separator: "\n"))))
                    codeBlock = []
                    inCode = false
                } else {
                    inCode = true
                }
                continue
            }

            if inCode {
                codeBlock.append(line)
                continue
            }

            if line.hasPrefix("# ") {
                result.append(IndexedBlock(id: result.count, block: .header(text: String(line.dropFirst(2)), level: 1)))
            } else if line.hasPrefix("## ") {
                result.append(IndexedBlock(id: result.count, block: .header(text: String(line.dropFirst(3)), level: 2)))
            } else if line.hasPrefix("### ") {
                result.append(IndexedBlock(id: result.count, block: .header(text: String(line.dropFirst(4)), level: 3)))
            } else if line.hasPrefix("#### ") {
                result.append(IndexedBlock(id: result.count, block: .header(text: String(line.dropFirst(5)), level: 4)))
            } else if line.hasPrefix("---") || line.hasPrefix("***") || line.hasPrefix("___") {
                result.append(IndexedBlock(id: result.count, block: .divider))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(IndexedBlock(id: result.count, block: .bullet(text: String(line.dropFirst(2)), ordered: false, raw: nil)))
            } else if let match = line.wholeMatch(of: /^\d+\.\s+(.*)/) {
                result.append(IndexedBlock(id: result.count, block: .bullet(text: String(match.1), ordered: true, raw: line)))
            } else if line.hasPrefix("| ") {
                result.append(IndexedBlock(id: result.count, block: .tableRow(line)))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(IndexedBlock(id: result.count, block: .spacer))
            } else if line.hasPrefix("> ") {
                result.append(IndexedBlock(id: result.count, block: .blockquote(String(line.dropFirst(2)))))
            } else {
                result.append(IndexedBlock(id: result.count, block: .paragraph(line)))
            }
        }

        // Flush any unterminated code block
        if inCode && !codeBlock.isEmpty {
            result.append(IndexedBlock(id: result.count, block: .codeBlock(codeBlock.joined(separator: "\n"))))
        }

        return result
    }

    private func headerView(_ text: String, level: Int) -> some View {
        let font: Font = switch level {
        case 1: .title.bold()
        case 2: .title2.bold()
        case 3: .title3.bold()
        default: .headline
        }
        return Text(inlineMarkdown(text))
            .font(font)
            .padding(.top, level == 1 ? 12 : 8)
            .padding(.bottom, 4)
    }

    private func codeBlockView(_ code: String) -> some View {
        Text(code)
            .font(.system(.callout, design: .monospaced))
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.vertical, 4)
    }

    private func bulletView(_ text: String, ordered: Bool = false, raw: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if ordered, let raw {
                let prefix = raw.prefix(while: { $0.isNumber || $0 == "." })
                Text(prefix)
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
            } else {
                Text("\u{2022}")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .trailing)
            }
            Text(inlineMarkdown(text))
                .font(.body)
        }
        .padding(.leading, 4)
        .padding(.vertical, 1)
    }

    private func blockquoteView(_ text: String) -> some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
            Text(inlineMarkdown(text))
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.leading, 10)
        }
        .padding(.vertical, 2)
    }

    private func tableRowView(_ line: String) -> some View {
        let cells = line
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // Skip separator rows like |---|---|
        let isSeparator = cells.allSatisfy { $0.allSatisfy({ $0 == "-" || $0 == ":" }) }
        return Group {
            if isSeparator {
                Divider().padding(.vertical, 1)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                        Text(inlineMarkdown(cell))
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func paragraphView(_ text: String) -> some View {
        Text(inlineMarkdown(text))
            .font(.body)
            .padding(.vertical, 1)
    }

    private func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

// MARK: - NSView Wrapper

final class FileBrowserPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "file_browser"
    let shouldPersist = true
    var title: String { "Files" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(FileBrowserView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
