import SwiftUI
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

// MARK: - FileBrowserView

struct FileBrowserView: View {
    @StateObject private var viewModel = FileBrowserViewModel()

    var body: some View {
        HSplitView {
            // File tree
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
                } else if viewModel.rootNodes.isEmpty {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading files...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.rootNodes, children: \.optionalChildren) { node in
                        FileRow(node: node, isSelected: viewModel.selectedPath == node.path)
                            .onTapGesture { viewModel.select(node) }
                    }
                    .listStyle(.sidebar)
                }
            }
            .frame(minWidth: 200, maxWidth: 300)

            // Preview
            VStack {
                if let content = viewModel.previewContent {
                    ScrollView {
                        Text(content)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if viewModel.selectedPath != nil {
                    Text("Loading...")
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
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .onAppear { viewModel.activate() }
    }
}

// MARK: - FileRow

struct FileRow: View {
    let node: FileNode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(node.name))
                .foregroundStyle(node.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            Text(node.name)
                .font(.body)
                .lineLimit(1)
            Spacer()
            if let size = node.size, !node.isDirectory {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

// MARK: - FileNode helpers

extension FileNode {
    var optionalChildren: [FileNode]? {
        isDirectory ? (children ?? []) : nil
    }
}

// MARK: - ViewModel

@MainActor
final class FileBrowserViewModel: ObservableObject {
    @Published var rootNodes: [FileNode] = []
    @Published var selectedPath: String?
    @Published var previewContent: String?
    @Published var actionError: String?
    @Published private(set) var isProjectOpen = false

    private let activationHub: ActiveWorkspaceActivationHub
    private var activationObserverID: UUID?
    private var isLoadingFiles = false

    init(activationHub: ActiveWorkspaceActivationHub = .shared) {
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

    func activate() {
        handleActivationState(activationHub.currentState)
    }

    func load() {
        guard !isLoadingFiles else { return }
        guard let bus = CommandBus.shared else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        isLoadingFiles = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLoadingFiles = false }
            do {
                struct Params: Encodable { let limit: Int }
                let nodes: [FileNode] = try await bus.call(method: "workspace.files", params: Params(limit: 500))
                self.rootNodes = nodes
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    func refresh() { load() }

    func select(_ node: FileNode) {
        selectedPath = node.path
        if !node.isDirectory {
            loadPreview(path: node.path)
        }
    }

    private func loadPreview(path: String) {
        previewContent = nil
        guard let bus = CommandBus.shared else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                struct Params: Encodable { let path: String; let mode: String }
                struct FilePreview: Decodable { let content: String }
                let preview: FilePreview = try await bus.call(method: "workspace.file.open", params: Params(path: path, mode: "preview"))
                self.previewContent = preview.content
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
            }
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle, .opening, .closed:
            isProjectOpen = false
            rootNodes = []
            selectedPath = nil
            previewContent = nil
        case .open:
            isProjectOpen = true
            load()
        case .failed(_, _, let message):
            isProjectOpen = false
            rootNodes = []
            actionError = message
            scheduleDismissActionError()
        }
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
