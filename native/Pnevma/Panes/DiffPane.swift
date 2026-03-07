import SwiftUI
import Cocoa

// MARK: - Data Models

struct DiffFile: Identifiable, Codable {
    var id: String { path }
    let path: String
    let status: String  // added, modified, deleted
    let hunks: [DiffHunk]
}

struct DiffHunk: Identifiable, Codable {
    let id = UUID()
    let header: String
    let lines: [DiffLine]

    private enum CodingKeys: String, CodingKey { case header, lines }
}

struct DiffLine: Identifiable, Codable {
    let id = UUID()
    let type: DiffLineType
    let content: String
    let oldLineNo: Int?
    let newLineNo: Int?

    private enum CodingKeys: String, CodingKey { case type, content, oldLineNo, newLineNo }
}

enum DiffLineType: String, Codable {
    case context, addition, deletion
}

// MARK: - DiffView

struct DiffView: View {
    @StateObject private var viewModel = DiffViewModel()

    var body: some View {
        HSplitView {
            // File tree
            VStack(alignment: .leading, spacing: 0) {
                Text("Files")
                    .font(.headline)
                    .padding(12)
                Divider()

                List(viewModel.files, selection: $viewModel.selectedFile) { file in
                    HStack(spacing: 6) {
                        Image(systemName: fileIcon(file.status))
                            .foregroundStyle(fileColor(file.status))
                            .frame(width: 16)
                        Text(file.path)
                            .font(.body)
                            .lineLimit(1)
                    }
                    .tag(file.id)
                }
                .listStyle(.plain)
            }
            .frame(minWidth: 180, maxWidth: 260)

            // Diff content
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
                } else {
                    Text("Select a file to view diff")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                }
            }
        }
        .onAppear { viewModel.load() }
    }

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
            // Line numbers
            Text(line.oldLineNo.map { "\($0)" } ?? "")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
            Text(line.newLineNo.map { "\($0)" } ?? "")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)

            // Prefix
            Text(prefix)
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

    private var prefix: String {
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

final class DiffViewModel: ObservableObject {
    @Published var files: [DiffFile] = []
    @Published var selectedFile: String?

    var selectedDiffFile: DiffFile? {
        guard let sel = selectedFile else { return nil }
        return files.first { $0.id == sel }
    }

    func load() {
        // pnevma_call("task.diff", ...)
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
