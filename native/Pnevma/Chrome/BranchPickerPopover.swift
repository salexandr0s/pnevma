import SwiftUI

/// Searchable branch list popover for titlebar.
struct BranchPickerPopover: View {
    let branches: [String]
    let currentBranch: String?
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var hoveredBranch: String?

    private var filteredBranches: [String] {
        if searchText.isEmpty { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ToolbarAttachmentScaffold(title: "Switch Branch") {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    TextField("Filter branches…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.5))
                )
                .padding(.horizontal, DesignTokens.Spacing.sm + 2)
                .padding(.top, DesignTokens.Spacing.sm)
                .padding(.bottom, DesignTokens.Spacing.sm)

                Divider()
                    .padding(.horizontal, DesignTokens.Spacing.sm)

                if filteredBranches.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No Matching Branches",
                        message: "Try a different branch name."
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(filteredBranches, id: \.self) { branch in
                                branchRow(branch)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Spacing.sm - 2)
                        .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                }
            }
        }
        .frame(width: 280, height: 340)
        .accessibilityIdentifier("branchPicker")
    }

    @ViewBuilder
    private func branchRow(_ branch: String) -> some View {
        let isCurrent = branch == currentBranch
        let isHovered = branch == hoveredBranch

        Button {
            onSelect(branch)
            onDismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isCurrent ? "checkmark" : "arrow.branch")
                    .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
                    .frame(width: 16, alignment: .center)

                Text(branch)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isCurrent ? Color.primary : Color.primary)

                Spacer(minLength: 0)

                if isCurrent {
                    Text("current")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovered ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.15) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in
            hoveredBranch = isHovered ? branch : nil
        }
        .accessibilityLabel(isCurrent ? "\(branch), current branch" : branch)
    }
}
