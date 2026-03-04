import SwiftUI
import Cocoa

// MARK: - Data Models

struct ReviewPack: Codable {
    let taskID: String
    let taskTitle: String
    let diff: String
    let acceptanceCriteria: [AcceptanceCriterion]
    let reviewerNotes: String?
}

struct AcceptanceCriterion: Identifiable, Codable {
    var id: String { description }
    let description: String
    var met: Bool
}

// MARK: - ReviewView

struct ReviewView: View {
    @StateObject private var viewModel = ReviewViewModel()

    var body: some View {
        HSplitView {
            // Left: diff view
            VStack(alignment: .leading, spacing: 0) {
                Text("Changes")
                    .font(.headline)
                    .padding(12)
                Divider()

                ScrollView {
                    if let diff = viewModel.reviewPack?.diff {
                        Text(diff)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    } else {
                        Text("No review selected")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding()
                    }
                }
            }

            // Right: checklist + actions
            VStack(alignment: .leading, spacing: 16) {
                if let pack = viewModel.reviewPack {
                    Text(pack.taskTitle)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .padding(.top, 12)

                    // Acceptance criteria checklist
                    GroupBox("Acceptance Criteria") {
                        ForEach(viewModel.criteria.indices, id: \.self) { idx in
                            Toggle(viewModel.criteria[idx].description,
                                   isOn: $viewModel.criteria[idx].met)
                                .toggleStyle(.checkbox)
                                .padding(.vertical, 2)
                        }
                    }

                    // Reviewer notes
                    GroupBox("Notes") {
                        TextEditor(text: $viewModel.notes)
                            .font(.body)
                            .frame(minHeight: 80)
                    }

                    Spacer()

                    // Action buttons
                    HStack {
                        Button("Reject") { viewModel.reject() }
                            .buttonStyle(.bordered)

                        Spacer()

                        Button("Approve") { viewModel.approve() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!viewModel.allCriteriaMet)
                    }
                    .padding(.bottom, 12)
                } else {
                    Spacer()
                    Text("Select a task to review")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 280)
        }
        .onAppear { viewModel.load() }
    }
}

// MARK: - ViewModel

final class ReviewViewModel: ObservableObject {
    @Published var reviewPack: ReviewPack?
    @Published var criteria: [AcceptanceCriterion] = []
    @Published var notes: String = ""

    var allCriteriaMet: Bool { criteria.allSatisfy { $0.met } }

    func load() {
        // pnevma_call("task.review_pack", ...)
    }

    func approve() {
        // pnevma_call("task.approve", ...)
    }

    func reject() {
        // pnevma_call("task.reject", ...)
    }
}

// MARK: - NSView Wrapper

final class ReviewPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "review"
    var title: String { "Review" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(ReviewView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
