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

                if viewModel.rootNodes.isEmpty {
                    Spacer()
                    Text("No project open")
                        .foregroundStyle(.secondary)
                    Spacer()
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
        .onAppear { viewModel.load() }
    }
}

// MARK: - FileRow

struct FileRow: View {
    let node: FileNode
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isDirectory ? "folder.fill" : fileIcon(node.name))
                .foregroundStyle(node.isDirectory ? .accentColor : .secondary)
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

final class FileBrowserViewModel: ObservableObject {
    @Published var rootNodes: [FileNode] = []
    @Published var selectedPath: String?
    @Published var previewContent: String?

    func load() {
        // pnevma_call("project.files", "{}")
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
        // pnevma_call("project.open_file", ...) → content
    }
}

// MARK: - NSView Wrapper

final class FileBrowserPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "file_browser"
    var title: String { "Files" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(FileBrowserView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
