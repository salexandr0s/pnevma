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
                WorkspaceOpenerSearchField(
                    "Search by title or number",
                    text: $viewModel.prSearchText
                )
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)

                Toggle("Create linked task/worktree", isOn: $viewModel.createLinkedTaskWorktree)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .padding(.horizontal, DesignTokens.Spacing.md)
                    .padding(.bottom, DesignTokens.Spacing.sm)

                Divider()

                if viewModel.isLoadingPRs {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredPRs.isEmpty {
                    WorkspaceOpenerStateCard(
                        icon: "arrow.triangle.pull",
                        title: "No pull requests found",
                        message: "Try a different search or switch to another project."
                    )
                } else {
                    WorkspaceOpenerListContainer {
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

private struct PRRow: View {
    let pr: PullRequestItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.triangle.pull")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 4) {
                    Text(pr.title)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("#\(pr.number)")
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()

                        Text("\(pr.sourceBranch) \u{2192} \(pr.targetBranch)")
                            .lineLimit(1)
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
