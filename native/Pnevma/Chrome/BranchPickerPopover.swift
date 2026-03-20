import SwiftUI

/// Searchable branch list popover for titlebar.
struct BranchPickerPopover: View {
    let branches: [String]
    let currentBranch: String?
    let onSelect: (String) -> Void
    let onDismiss: () -> Void

    @State private var searchText = ""

    private var filteredBranches: [String] {
        if searchText.isEmpty { return branches }
        return branches.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        ToolbarAttachmentScaffold(title: "Switch Branch") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Filter branches…", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(DesignTokens.Spacing.sm + DesignTokens.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(ChromeSurfaceStyle.groupedCard.color)
                )

                if filteredBranches.isEmpty {
                    EmptyStateView(
                        icon: "magnifyingglass",
                        title: "No Matching Branches",
                        message: "Try a different branch name."
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            ForEach(filteredBranches, id: \.self) { branch in
                                Button {
                                    onSelect(branch)
                                    onDismiss()
                                } label: {
                                    HStack(spacing: DesignTokens.Spacing.sm) {
                                        if branch == currentBranch {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Color.accentColor)
                                                .frame(width: 14)
                                        } else {
                                            Spacer()
                                                .frame(width: 14)
                                        }

                                        Text(branch)
                                            .lineLimit(1)

                                        Spacer()
                                    }
                                    .padding(.horizontal, DesignTokens.Spacing.sm + DesignTokens.Spacing.xs)
                                    .padding(.vertical, DesignTokens.Spacing.sm)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10)
                                            .fill(branch == currentBranch ? ChromeSurfaceStyle.groupedCard.selectionColor : Color.clear)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(branch == currentBranch ? "\(branch), current branch" : branch)
                            }
                        }
                        .padding(.bottom, DesignTokens.Spacing.xs)
                    }
                }
            }
            .padding(DesignTokens.Spacing.md)
        }
        .frame(width: 300, height: 340)
        .accessibilityIdentifier("branchPicker")
    }
}
