import SwiftUI

struct IssuesTabView: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel
    let commandBus: any CommandCalling

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingGitHubStatus || viewModel.isConnectingGitHub {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.issuesAvailable {
                WorkspaceOpenerSearchField(
                    "Search by title, number, or author",
                    text: $viewModel.issueSearchText
                )
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)

                Divider()

                if viewModel.isLoadingIssues {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredIssues.isEmpty {
                    WorkspaceOpenerStateCard(
                        icon: "checklist",
                        title: "No issues found",
                        message: "Try a different search or switch to another project."
                    )
                } else {
                    WorkspaceOpenerListContainer {
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
            } else {
                WorkspaceOpenerStateCard(
                    icon: viewModel.gitHubEmptyStateIcon,
                    title: viewModel.gitHubEmptyStateTitle,
                    message: viewModel.gitHubEmptyStateMessage,
                    actionTitle: viewModel.gitHubActionTitle,
                    action: {
                        viewModel.connectGitHub(using: commandBus)
                    }
                )
            }
        }
    }
}

private struct IssueRow: View {
    let issue: GitHubIssueItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.state == "open"
                    ? "circle.circle" : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(issue.state == "open" ? .green : .purple)

                VStack(alignment: .leading, spacing: 4) {
                    Text(issue.title)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("#\(issue.number)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()

                        Text(issue.author)
                            .lineLimit(1)

                        if let firstLabel = issue.labels.first, !firstLabel.isEmpty {
                            Text(firstLabel)
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.secondary.opacity(0.10)))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : isHovering
                                ? Color.primary.opacity(0.04)
                                : Color.clear
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isSelected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.05),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
