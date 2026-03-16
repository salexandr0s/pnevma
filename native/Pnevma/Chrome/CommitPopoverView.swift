import SwiftUI

struct CommitPopoverView: View {
    let branch: String?
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var commitMessage = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Commit Message")
                .font(.headline)

            if let branch {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(branch)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            TextField("Describe your changes\u{2026}", text: $commitMessage, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(3 ... 6)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                .focused($isFocused)
                .onSubmit {
                    let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !msg.isEmpty { onCommit(msg) }
                }

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Button("Commit") {
                    let msg = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !msg.isEmpty { onCommit(msg) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 320)
        .onAppear { isFocused = true }
    }
}
