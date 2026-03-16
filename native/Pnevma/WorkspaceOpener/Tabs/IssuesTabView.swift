import SwiftUI

struct IssuesTabView: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.issuesAvailable {
                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField(
                        "Search by title, number, or author",
                        text: $viewModel.issueSearchText
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)

                Divider()

                if viewModel.isLoadingIssues {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredIssues.isEmpty {
                    Text("No issues found")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.filteredIssues) { issue in
                                IssueRow(
                                    issue: issue,
                                    isSelected: viewModel.selectedIssueNumber == issue.number
                                ) {
                                    viewModel.selectedIssueNumber = issue.number
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyStateView(
                    icon: "exclamationmark.bubble",
                    title: "Connect GitHub",
                    message: "Link a GitHub repository to browse issues",
                    actionTitle: "Connect"
                )
            }
        }
    }
}

private struct IssueRow: View {
    let issue: GitHubIssueItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: issue.state == "open"
                    ? "circle.circle" : "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(issue.state == "open" ? .green : .purple)
                Text("#\(issue.number)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                Text(issue.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
                if !issue.labels.isEmpty {
                    Text(issue.labels.first ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.12))
                        )
                }
                Text(issue.author)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
