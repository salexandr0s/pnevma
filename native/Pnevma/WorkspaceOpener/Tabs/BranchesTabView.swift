import SwiftUI

struct BranchesTabView: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.selectedProjectPath == nil {
                WorkspaceOpenerStateCard(
                    icon: "arrow.triangle.branch",
                    title: "Select a project",
                    message: "Choose a folder first to browse branches for that workspace."
                )
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                    WorkspaceOpenerSearchField(
                        "Search by branch name",
                        text: $viewModel.branchSearchText
                    ) {
                        BranchFilterToggle(
                            filter: $viewModel.branchFilter,
                            totalCount: viewModel.branches.count,
                            worktreeCount: viewModel.branches.filter(\.hasWorktree).count
                        )
                    }

                    HStack(spacing: 8) {
                        Button {
                            if viewModel.isCreatingNewBranch {
                                viewModel.cancelNewBranchCreation()
                            } else {
                                viewModel.beginNewBranchCreation()
                            }
                        } label: {
                            Label(
                                viewModel.isCreatingNewBranch ? "Cancel New Branch" : "New Branch",
                                systemImage: viewModel.isCreatingNewBranch ? "xmark" : "plus"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        if viewModel.isCreatingNewBranch {
                            Text("Name the branch, then use the primary action below.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }

                    if viewModel.isCreatingNewBranch {
                        NewBranchComposer(viewModel: viewModel)
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)

                Divider()

                if viewModel.isLoadingBranches {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.filteredBranches.isEmpty {
                    WorkspaceOpenerStateCard(
                        icon: "arrow.triangle.branch",
                        title: "No branches found",
                        message: viewModel.isCreatingNewBranch
                            ? "Create a branch above or try a different search."
                            : "Try a different search or open another project."
                    )
                } else {
                    WorkspaceOpenerListContainer {
                        ForEach(viewModel.filteredBranches) { branch in
                            BranchRow(
                                branch: branch,
                                isSelected: viewModel.selectedBranchName == branch.name
                            ) {
                                viewModel.selectBranch(branch.name)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct NewBranchComposer: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("New branch name")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("feature/my-branch", text: $viewModel.newBranchName)
                .textFieldStyle(.roundedBorder)

            Text("Pnevma will create the branch in the selected repository checkout and open the workspace on it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct BranchFilterToggle: View {
    @Binding var filter: BranchFilter
    let totalCount: Int
    let worktreeCount: Int

    var body: some View {
        HStack(spacing: 4) {
            filterButton("All \(totalCount)", for: .all)
            filterButton("Worktrees \(worktreeCount)", for: .worktrees)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func filterButton(_ label: String, for value: BranchFilter) -> some View {
        Button {
            filter = value
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .foregroundStyle(filter == value ? .primary : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(filter == value ? Color.primary.opacity(0.10) : Color.clear)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct BranchRow: View {
    let branch: BranchItem
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: branch.hasWorktree ? "folder.fill" : "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(branch.isDefault ? .blue : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 4) {
                    Text(branch.name)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if branch.isDefault {
                            branchTag("Default", color: .blue)
                        }

                        if branch.hasWorktree {
                            branchTag("Worktree", color: .green)
                        }
                    }
                }

                Spacer()

                if isHovering {
                    Image(systemName: "return")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : isHovering
                                ? Color.primary.opacity(DesignTokens.Opacity.subtle)
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

    private func branchTag(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
