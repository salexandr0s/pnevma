import SwiftUI

struct PullRequestsTabView: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel
    let commandBus: any CommandCalling

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.isLoadingGitHubStatus || viewModel.isConnectingGitHub {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.githubAvailable {
                // Search field
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField(
                        "Search by title or number",
                        text: $viewModel.prSearchText
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)

                Divider()

                if viewModel.isLoadingPRs {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredPRs.isEmpty {
                    Text("No pull requests found")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(viewModel.filteredPRs) { pr in
                                PRRow(
                                    pr: pr,
                                    isSelected: viewModel.selectedPRNumber == pr.number
                                ) {
                                    viewModel.selectedPRNumber = pr.number
                                }
                            }
                        }
                    }
                }
            } else {
                EmptyStateView(
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

private struct PRRow: View {
    let pr: PullRequestItem
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text("#\(pr.number)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .leading)
                Text(pr.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer()
                Text("\(pr.sourceBranch) \u{2192} \(pr.targetBranch)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
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
