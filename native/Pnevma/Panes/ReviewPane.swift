import SwiftUI
import Observation
import Cocoa

// MARK: - ReviewView

struct ReviewView: View {
    @State private var viewModel = ReviewViewModel()

    var body: some View {
        Group {
            if let statusMessage = viewModel.statusMessage {
                EmptyStateView(
                    icon: "checkmark.seal",
                    title: statusMessage
                )
            } else {
                HSplitView {
                    taskListPanel
                    detailPanel
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.activate() }
    }

    // MARK: Left panel — tasks pending review

    private var taskListPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pending Review")
                    .font(.headline)
                Spacer()
                Text("\(viewModel.reviewTasks.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            if viewModel.reviewTasks.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("No Tasks")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("No tasks awaiting review")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(viewModel.reviewTasks, selection: $viewModel.selectedTaskID) { task in
                    ReviewTaskRow(task: task)
                        .tag(task.id)
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 200, idealWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Right panel — review details

    @ViewBuilder
    private var detailPanel: some View {
        if let pack = viewModel.reviewPack {
            HSplitView {
                // Pack path / metadata
                VStack(alignment: .leading, spacing: 0) {
                    Text("Review Pack")
                        .font(.headline)
                        .padding(12)
                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            LabeledContent("Status", value: pack.status)
                            LabeledContent("Path", value: pack.reviewPackPath)
                            if let approvedAt = pack.approvedAt {
                                LabeledContent("Approved At", value: approvedAt)
                            }
                        }
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                    }
                }

                // Checklist + actions
                VStack(alignment: .leading, spacing: 16) {
                    Text(viewModel.selectedTaskTitle ?? pack.taskId)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .padding(.top, 12)

                    if !viewModel.criteria.isEmpty {
                        GroupBox("Acceptance Criteria") {
                            ForEach(viewModel.criteria.indices, id: \.self) { idx in
                                Toggle(viewModel.criteria[idx].description,
                                       isOn: $viewModel.criteria[idx].met)
                                    .toggleStyle(.checkbox)
                                    .padding(.vertical, 2)
                            }
                        }
                    }

                    GroupBox("Notes") {
                        TextEditor(text: $viewModel.notes)
                            .font(.body)
                            .frame(minHeight: 80)
                    }

                    if let error = viewModel.actionError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Spacer()

                    HStack {
                        Button("Reject") { viewModel.reject() }
                            .buttonStyle(.bordered)
                            .disabled(viewModel.isActing)

                        Spacer()

                        Button("Approve") { viewModel.approve() }
                            .buttonStyle(.borderedProminent)
                            .disabled(viewModel.isActing || !viewModel.allCriteriaMet)
                    }
                    .padding(.bottom, 12)
                }
                .padding(.horizontal, 12)
                .frame(minWidth: 280, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                if viewModel.isLoadingPack {
                    ProgressView("Loading review pack...")
                } else {
                    Image(systemName: "eye.circle")
                        .font(.system(size: 36))
                        .foregroundStyle(.tertiary)
                    Text("Select a task to review")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Task row (left panel)

private struct ReviewTaskRow: View {
    let task: ReviewTaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
                .font(.body)
                .lineLimit(2)
            if let cost = task.costUsd {
                Text(cost, format: .currency(code: "USD"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - NSView Wrapper

final class ReviewPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "review"
    let shouldPersist = false
    var title: String { "Review" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(ReviewView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
