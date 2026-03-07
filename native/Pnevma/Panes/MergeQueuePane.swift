import SwiftUI
import Cocoa

// MARK: - Data Models

struct MergeQueueItem: Identifiable, Codable {
    let id: String
    let taskTitle: String
    let branchName: String
    let conflictStatus: ConflictStatus
    let position: Int
}

enum ConflictStatus: String, Codable {
    case clean, conflicts, unknown
    var color: Color {
        switch self {
        case .clean: return .green
        case .conflicts: return .red
        case .unknown: return .secondary
        }
    }
    var label: String {
        switch self {
        case .clean: return "Clean"
        case .conflicts: return "Conflicts"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - MergeQueueView

struct MergeQueueView: View {
    @StateObject private var viewModel = MergeQueueViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Merge Queue")
                    .font(.headline)
                Spacer()
                Button("Refresh") { viewModel.load() }
                    .buttonStyle(.bordered)
            }
            .padding(12)

            Divider()

            if viewModel.items.isEmpty {
                Spacer()
                Text("Merge queue is empty")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(viewModel.items) { item in
                        MergeQueueRow(item: item, onMerge: { viewModel.merge(item) })
                    }
                    .onMove { viewModel.reorder(from: $0, to: $1) }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { viewModel.load() }
    }
}

// MARK: - MergeQueueRow

struct MergeQueueRow: View {
    let item: MergeQueueItem
    let onMerge: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("#\(item.position)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.taskTitle)
                    .font(.body)
                Text(item.branchName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Conflict status
            Label(item.conflictStatus.label, systemImage:
                    item.conflictStatus == .clean ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(item.conflictStatus.color)

            Button("Merge") { onMerge() }
                .buttonStyle(.bordered)
                .disabled(item.conflictStatus == .conflicts)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - ViewModel

final class MergeQueueViewModel: ObservableObject {
    @Published var items: [MergeQueueItem] = []

    func load() {
        // pnevma_call("merge_queue.list", "{}")
    }

    func merge(_ item: MergeQueueItem) {
        // pnevma_call("merge_queue.execute", ...)
    }

    func reorder(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        // pnevma_call("merge_queue.reorder", ...)
    }
}

// MARK: - NSView Wrapper

final class MergeQueuePaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "merge_queue"
    let shouldPersist = false
    var title: String { "Merge Queue" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(MergeQueueView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
