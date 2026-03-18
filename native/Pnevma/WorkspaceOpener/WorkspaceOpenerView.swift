import SwiftUI

struct WorkspaceOpenerView: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel
    let commandBus: any CommandCalling
    let onSubmit: (WorkspaceOpenerViewModel) -> Void
    let onCancel: () -> Void

    @Environment(GhosttyThemeProvider.self) private var theme

    var body: some View {
        VStack(spacing: 0) {
            // Header: tab bar + project picker
            HStack {
                WorkspaceOpenerTabBar(selectedTab: $viewModel.selectedTab)
                Spacer()
                WorkspaceOpenerProjectPicker(
                    selectedPath: $viewModel.selectedProjectPath,
                    projects: viewModel.availableProjects
                )
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)

            Divider()

            // Tab content
            Group {
                switch viewModel.selectedTab {
                case .prompt:
                    PromptTabView(viewModel: viewModel)
                case .issues:
                    IssuesTabView(viewModel: viewModel, commandBus: commandBus)
                case .pullRequests:
                    PullRequestsTabView(viewModel: viewModel, commandBus: commandBus)
                case .branches:
                    BranchesTabView(viewModel: viewModel)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Error message
            if let error = viewModel.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.bottom, DesignTokens.Spacing.sm)
            }

            // Action bar
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Workspace") { onSubmit(viewModel) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canSubmit || viewModel.isLoading)
            }
            .padding(DesignTokens.Spacing.md)
        }
        .frame(width: 680, height: 500)
        .onChange(of: viewModel.selectedProjectPath) { _, _ in
            viewModel.onProjectChanged(using: commandBus)
        }
        .accessibilityIdentifier("workspaceOpener")
    }
}
