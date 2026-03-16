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
        VStack(alignment: .leading, spacing: 0) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Filter branches…", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)

            Divider()

            // Branch list
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(filteredBranches, id: \.self) { branch in
                        Button {
                            onSelect(branch)
                            onDismiss()
                        } label: {
                            HStack {
                                if branch == currentBranch {
                                    Image(systemName: "checkmark")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                        .frame(width: 14)
                                } else {
                                    Spacer().frame(width: 14)
                                }
                                Text(branch)
                                    .font(.body)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 260)
        .accessibilityIdentifier("branchPicker")
    }
}
