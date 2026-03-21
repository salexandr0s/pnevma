import SwiftUI

/// Compact task list for the sidebar, grouped by status.
/// Reuses `TaskBoardViewModel` for data fetching and event-driven refresh.
struct SidebarTaskListView: View {
    @State private var viewModel = TaskBoardViewModel()

    /// Status display order: active states first, terminal states last.
    private let statusOrder: [TaskStatus] = [
        .dispatching, .inProgress, .ready, .planned, .review, .blocked, .failed, .done, .looped
    ]

    var body: some View {
        Group {
            if viewModel.allTasks.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await viewModel.activate() }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        EmptyStateView(
            icon: "checklist",
            title: "No tasks yet",
            message: viewModel.statusMessage ?? "Task tracking will appear here."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Task List

    private var taskList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(statusOrder, id: \.self) { status in
                    let tasks = viewModel.tasks(for: status)
                    if !tasks.isEmpty {
                        SidebarSectionHeader(
                            title: status.displayName,
                            count: tasks.count,
                            isCollapsible: false
                        )
                        .padding(.top, 6)

                        ForEach(tasks, id: \.id) { task in
                            SidebarTaskRow(task: task)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }
}
