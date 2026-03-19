import SwiftUI

struct WorkspaceOpenerView: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel
    let commandBus: any CommandCalling
    let onPreferredSizeChange: (CGSize) -> Void
    let onSubmit: (WorkspaceOpenerViewModel) -> Void
    let onCancel: () -> Void

    private var titleSubtitle: String {
        switch viewModel.selectedTab {
        case .prompt:
            return "Start from a prompt, an existing folder, or a remote SSH target."
        case .issues:
            return "Open a workspace from a GitHub issue in the selected project."
        case .pullRequests:
            return "Open a workspace from a pull request in the selected project."
        case .branches:
            return "Open a workspace from a branch in the selected project."
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Text(titleSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 10)

                    WorkspaceOpenerProjectPicker(
                        selectedPath: $viewModel.selectedProjectPath,
                        projects: viewModel.availableProjects
                    )
                }

                WorkspaceOpenerTabBar(selectedTab: $viewModel.selectedTab)
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.top, 10)
            .padding(.bottom, 8)

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
            .frame(maxWidth: .infinity, alignment: .top)

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
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            onPreferredSizeChange(viewModel.preferredPanelSize)
        }
        .onChange(of: viewModel.selectedTab) { _, _ in
            onPreferredSizeChange(viewModel.preferredPanelSize)
        }
        .onChange(of: viewModel.showAdvancedOptions) { _, _ in
            onPreferredSizeChange(viewModel.preferredPanelSize)
        }
        .onChange(of: viewModel.sshEnabled) { _, _ in
            onPreferredSizeChange(viewModel.preferredPanelSize)
        }
        .onChange(of: viewModel.errorMessage) { _, _ in
            onPreferredSizeChange(viewModel.preferredPanelSize)
        }
        .onChange(of: viewModel.selectedProjectPath) { _, _ in
            viewModel.onProjectChanged(using: commandBus)
        }
        .accessibilityIdentifier("workspaceOpener")
    }
}
