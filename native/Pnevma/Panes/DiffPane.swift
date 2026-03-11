import SwiftUI
import Observation
import Cocoa

// MARK: - DiffView

struct DiffView: View {
    @State private var viewModel = DiffViewModel()

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
        .task { await viewModel.activate() }
        .accessibilityIdentifier("pane.diff")
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
                    .accessibilityAddTraits(.isButton)
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
                            .background(Color.secondary.opacity(0.15))

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
                EmptyStateView(icon: "doc.text", title: "Select a file")
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
                .foregroundStyle(contentColor)
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

    private var contentColor: Color {
        switch line.type {
        case .addition: return DiffColors.additionContent
        case .deletion: return DiffColors.deletionContent
        case .context: return .primary
        }
    }

    private var backgroundColor: Color {
        switch line.type {
        case .addition: return DiffColors.additionBackground
        case .deletion: return DiffColors.deletionBackground
        case .context: return .clear
        }
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
