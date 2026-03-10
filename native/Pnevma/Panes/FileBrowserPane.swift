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
    @State private var isReaderMode = false
    @State private var showDiscardAlert = false
    @State private var pendingNode: FileNode?
    @Environment(GhosttyThemeProvider.self) var theme

    private var isMarkdownFile: Bool {
        guard let path = viewModel.selectedFilePath else { return false }
        return (path as NSString).pathExtension.lowercased() == "md"
    }

    private var isBinaryPreview: Bool {
        viewModel.previewContent == "[Binary file preview unavailable]"
    }

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
                } else if viewModel.rootNodes.isEmpty {
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
            .frame(minWidth: 200, maxWidth: 300)

            VStack(spacing: 0) {
                if viewModel.previewContent != nil {
                    // Editor toolbar
                    editorToolbar

                    Divider()

                    if isReaderMode && isMarkdownFile {
                        MarkdownReaderView(content: viewModel.editableContent)
                    } else if isBinaryPreview {
                        Text(viewModel.previewContent ?? "")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    Text("Select a file to preview")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: viewModel.selectedFilePath) {
                isReaderMode = false
            }
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
        .alert("Unsaved Changes", isPresented: $showDiscardAlert) {
            Button("Discard", role: .destructive) {
                viewModel.discardChanges()
                if let node = pendingNode {
                    pendingNode = nil
                    viewModel.select(node)
                }
            }
            Button("Save") {
                viewModel.saveFile()
                if let node = pendingNode {
                    pendingNode = nil
                    // Delay select slightly so save can finish
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        viewModel.select(node)
                    }
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
            .disabled(!viewModel.isDirty || viewModel.isSaving || isBinaryPreview)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
}

// MARK: - Tree Views

private struct FileTreeList: View {
    var viewModel: FileBrowserViewModel
    var onSelect: (FileNode) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.rootNodes) { node in
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
            .onTapGesture(count: 2) {
                if node.isDirectory {
                    viewModel.toggleDirectory(node)
                }
            }
            .onTapGesture {
                onSelect(node)
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
    /// The original content as loaded — used for dirty tracking.
    private(set) var originalContent: String?
    var editableContent: String = ""
    private(set) var isSaving = false
    var actionError: String?
    private(set) var isProjectOpen = false
    private(set) var projectStatusMessage: String?
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

    var isDirty: Bool {
        editableContent != (originalContent ?? "")
    }

    func isExpanded(_ path: String) -> Bool {
        expandedPaths.contains(path)
    }

    func isLoadingDirectory(_ path: String) -> Bool {
        loadingDirectories.contains(path)
    }

    func saveFile() {
        guard let path = selectedFilePath, isDirty else { return }
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        isSaving = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isSaving = false }
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
                self.originalContent = preview.content
                self.editableContent = preview.content
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
        originalContent = nil
        editableContent = ""
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

// MARK: - Markdown Reader

private struct MarkdownReaderView: View {
    let content: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    block
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
    }

    private var blocks: [AnyView] {
        var result: [AnyView] = []
        var codeBlock: [String] = []
        var inCode = false

        for line in content.components(separatedBy: "\n") {
            if line.hasPrefix("```") {
                if inCode {
                    result.append(AnyView(codeBlockView(codeBlock.joined(separator: "\n"))))
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
                result.append(AnyView(headerView(String(line.dropFirst(2)), level: 1)))
            } else if line.hasPrefix("## ") {
                result.append(AnyView(headerView(String(line.dropFirst(3)), level: 2)))
            } else if line.hasPrefix("### ") {
                result.append(AnyView(headerView(String(line.dropFirst(4)), level: 3)))
            } else if line.hasPrefix("#### ") {
                result.append(AnyView(headerView(String(line.dropFirst(5)), level: 4)))
            } else if line.hasPrefix("---") || line.hasPrefix("***") || line.hasPrefix("___") {
                result.append(AnyView(Divider().padding(.vertical, 8)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(AnyView(bulletView(String(line.dropFirst(2)))))
            } else if let match = line.wholeMatch(of: /^\d+\.\s+(.*)/) {
                result.append(AnyView(bulletView(String(match.1), ordered: true, raw: line)))
            } else if line.hasPrefix("| ") {
                result.append(AnyView(tableRowView(line)))
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(AnyView(Spacer().frame(height: 8)))
            } else if line.hasPrefix("> ") {
                result.append(AnyView(blockquoteView(String(line.dropFirst(2)))))
            } else {
                result.append(AnyView(paragraphView(line)))
            }
        }

        // Flush any unterminated code block
        if inCode && !codeBlock.isEmpty {
            result.append(AnyView(codeBlockView(codeBlock.joined(separator: "\n"))))
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
    let shouldPersist = false
    var title: String { "Files" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(FileBrowserView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
