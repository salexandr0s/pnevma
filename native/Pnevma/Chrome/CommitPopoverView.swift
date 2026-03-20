import SwiftUI

struct CommitPopoverView: View {
    let branch: String?
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var commitMessage = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ToolbarAttachmentScaffold(title: "Commit Message") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                if let branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                TextField("Describe your changes\u{2026}", text: $commitMessage, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(4 ... 6)
                    .padding(DesignTokens.Spacing.sm + DesignTokens.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(ChromeSurfaceStyle.groupedCard.color)
                    )
                    .focused($isFocused)
                    .onSubmit {
                        commitIfPossible()
                    }
            }
            .padding(DesignTokens.Spacing.md)
        } footer: {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Spacer()

                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Button("Commit") {
                    commitIfPossible()
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedCommitMessage.isEmpty)
            }
        }
        .frame(width: 340)
        .onAppear { isFocused = true }
    }

    private var trimmedCommitMessage: String {
        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commitIfPossible() {
        guard trimmedCommitMessage.isEmpty == false else { return }
        onCommit(trimmedCommitMessage)
    }
}
