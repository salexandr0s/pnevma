import SwiftUI

struct WorkspaceOpenerGitHubBanner: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel
    let commandBus: any CommandCalling

    private var shouldShow: Bool {
        viewModel.gitHubConnectionLabel != nil || viewModel.gitHubAuthJobRunning || viewModel.gitHubHelperWarning != nil
    }

    var body: some View {
        if shouldShow {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    if let label = viewModel.gitHubConnectionLabel {
                        Label("Connected as \(label)", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 12, weight: .medium))
                    }

                    if viewModel.gitHubAuthJobRunning {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting for GitHub browser sign-in to complete.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let warning = viewModel.gitHubHelperWarning, !warning.isEmpty {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Spacer(minLength: 10)

                VStack(alignment: .trailing, spacing: 8) {
                    Button("Add Account") {
                        viewModel.addGitHubAccount(using: commandBus)
                    }
                    .disabled(viewModel.gitHubAuthJobRunning)

                    if viewModel.gitHubHelperWarning != nil {
                        Button("Fix Git auth") {
                            viewModel.fixGitHubHelper(using: commandBus)
                        }
                    }
                }
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(Color.primary.opacity(0.03))
        }
    }
}
