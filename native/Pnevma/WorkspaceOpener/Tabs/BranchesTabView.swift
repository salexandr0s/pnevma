import SwiftUI

struct BranchesTabView: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel

    var body: some View {
        VStack(spacing: 0) {
            // Search + filter
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Search by name", text: $viewModel.branchSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }

                BranchFilterToggle(
                    filter: $viewModel.branchFilter,
                    totalCount: viewModel.branches.count,
                    worktreeCount: viewModel.branches.filter(\.hasWorktree).count
                )
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Divider()

            if viewModel.isLoadingBranches {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredBranches.isEmpty {
                Text("No branches found")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.filteredBranches) { branch in
                            BranchRow(
                                branch: branch,
                                isSelected: viewModel.selectedBranchName == branch.name
                            ) {
                                viewModel.selectedBranchName = branch.name
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct BranchFilterToggle: View {
    @Binding var filter: BranchFilter
    let totalCount: Int
    let worktreeCount: Int

    var body: some View {
        HStack(spacing: 2) {
            filterButton("All \(totalCount)", for: .all)
            filterButton("Worktrees \(worktreeCount)", for: .worktrees)
        }
    }

    private func filterButton(_ label: String, for value: BranchFilter) -> some View {
        Button {
            filter = value
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(filter == value ? .primary : .secondary)
                .background(
                    Capsule().fill(filter == value ? Color.primary.opacity(0.10) : Color.clear)
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
            HStack(spacing: 8) {
                Image(systemName: branch.hasWorktree ? "folder.fill" : "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(branch.isDefault ? .blue : .secondary)
                    .frame(width: 16)
                Text(branch.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if branch.isDefault {
                    Text("default")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.blue.opacity(0.12)))
                }
                Spacer()
                if isHovering {
                    Text("\u{23CE}")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.12)
                            : isHovering
                                ? Color.primary.opacity(DesignTokens.Opacity.subtle)
                                : Color.clear
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
