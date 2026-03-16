import SwiftUI

struct NewWorkspaceWizard: View {
    @Bindable var viewModel: NewWorkspaceWizardViewModel
    let onSubmit: (NewWorkspaceWizardViewModel) -> Void
    let onCancel: () -> Void

    @Environment(GhosttyThemeProvider.self) private var theme

    var body: some View {
        HStack(spacing: 0) {
            // Source picker (left)
            WizardSourceList(viewModel: viewModel)
                .frame(width: 200)
                .background(Color(nsColor: theme.backgroundColor).opacity(0.5))

            Divider()

            // Detail form (right)
            VStack(alignment: .leading, spacing: 0) {
                detailForm
                    .padding(DesignTokens.Spacing.md)

                Spacer()

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

                    Button("Create") { onSubmit(viewModel) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!viewModel.canSubmit || viewModel.isLoading)
                }
                .padding(DesignTokens.Spacing.md)
            }
        }
        .frame(width: 620, height: 420)
        .accessibilityIdentifier("newWorkspaceWizard")
    }

    @ViewBuilder
    private var detailForm: some View {
        switch viewModel.selectedSource {
        case .localFolder:
            WizardLocalFolderForm(viewModel: viewModel)
        case .remoteSSH:
            WizardRemoteSSHForm(viewModel: viewModel)
        case .fromBranch:
            WizardFromBranchForm(viewModel: viewModel)
        case .fromPR:
            WizardFromPRForm(viewModel: viewModel)
        case .fromIssue:
            WizardFromIssueForm(viewModel: viewModel)
        case .importWorktree:
            WizardImportWorktreeForm(viewModel: viewModel)
        }
    }
}

// MARK: - Source List

struct WizardSourceList: View {
    @Bindable var viewModel: NewWorkspaceWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("NEW WORKSPACE")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 4)

            ForEach(WorkspaceIntakeSource.allCases) { source in
                Button {
                    viewModel.selectedSource = source
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: source.icon)
                            .frame(width: 16)
                            .foregroundStyle(viewModel.selectedSource == source ? .primary : .secondary)
                        Text(source.rawValue)
                            .font(.body)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(viewModel.selectedSource == source ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("wizard.source.\(source.rawValue)")
            }

            Spacer()
        }
        .padding(DesignTokens.Spacing.sm)
    }
}

// MARK: - Form Views

struct WizardLocalFolderForm: View {
    @Bindable var viewModel: NewWorkspaceWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Local Folder")
                .font(.headline)

            HStack {
                TextField("Project path", text: $viewModel.projectPath)
                    .textFieldStyle(.roundedBorder)

                Button("Browse\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.projectPath = url.path
                    }
                }
            }

            WizardTerminalModePicker(viewModel: viewModel)
        }
    }
}

struct WizardRemoteSSHForm: View {
    @Bindable var viewModel: NewWorkspaceWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Remote SSH")
                .font(.headline)

            LabeledContent("Host") {
                TextField("hostname or IP", text: $viewModel.sshHost)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("User") {
                TextField("username", text: $viewModel.sshUser)
                    .textFieldStyle(.roundedBorder)
            }
            LabeledContent("Port") {
                TextField("22", text: $viewModel.sshPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            LabeledContent("Remote Path") {
                TextField("~/project", text: $viewModel.sshRemotePath)
                    .textFieldStyle(.roundedBorder)
            }

            WizardTerminalModePicker(viewModel: viewModel)
        }
    }
}

struct WizardFromBranchForm: View {
    @Bindable var viewModel: NewWorkspaceWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create from Branch")
                .font(.headline)

            HStack {
                TextField("Project path", text: $viewModel.projectPath)
                    .textFieldStyle(.roundedBorder)

                Button("Browse\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.projectPath = url.path
                    }
                }
            }

            if viewModel.availableBranches.isEmpty {
                TextField("Branch name", text: $viewModel.branchName)
                    .textFieldStyle(.roundedBorder)
            } else {
                Picker("Branch", selection: $viewModel.branchName) {
                    Text("Select branch\u{2026}").tag("")
                    ForEach(viewModel.availableBranches, id: \.self) { branch in
                        Text(branch).tag(branch)
                    }
                }
            }

            WizardTerminalModePicker(viewModel: viewModel)
        }
    }
}

struct WizardFromPRForm: View {
    @Bindable var viewModel: NewWorkspaceWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From GitHub PR")
                .font(.headline)

            HStack {
                TextField("PR URL or number", text: $viewModel.prURL)
                    .textFieldStyle(.roundedBorder)

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Fetch") {
                        // Caller wires CommandBus
                    }
                }
            }

            if let title = viewModel.prTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.body.weight(.medium))
                    if let head = viewModel.prHeadBranch, let base = viewModel.prBaseBranch {
                        Text("\(head) \u{2192} \(base)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            }

            WizardTerminalModePicker(viewModel: viewModel)
        }
    }
}

struct WizardFromIssueForm: View {
    @Bindable var viewModel: NewWorkspaceWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From Issue URL")
                .font(.headline)

            HStack {
                TextField("Issue URL or number", text: $viewModel.issueURL)
                    .textFieldStyle(.roundedBorder)

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Fetch") {
                        // Caller wires CommandBus
                    }
                }
            }

            if let title = viewModel.issueTitle {
                Text(title)
                    .font(.body.weight(.medium))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
            }

            TextField("Project path", text: $viewModel.projectPath)
                .textFieldStyle(.roundedBorder)

            WizardTerminalModePicker(viewModel: viewModel)
        }
    }
}

struct WizardImportWorktreeForm: View {
    @Bindable var viewModel: NewWorkspaceWizardViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Worktree")
                .font(.headline)

            HStack {
                TextField("Worktree path", text: $viewModel.worktreePath)
                    .textFieldStyle(.roundedBorder)

                Button("Browse\u{2026}") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        viewModel.worktreePath = url.path
                    }
                }
            }

            WizardTerminalModePicker(viewModel: viewModel)
        }
    }
}

// MARK: - Shared Components

struct WizardTerminalModePicker: View {
    @Bindable var viewModel: NewWorkspaceWizardViewModel

    var body: some View {
        Picker("Terminal Mode", selection: $viewModel.terminalMode) {
            Text("Persistent").tag(WorkspaceTerminalMode.persistent)
            Text("Non-Persistent").tag(WorkspaceTerminalMode.nonPersistent)
        }
        .pickerStyle(.segmented)
        .frame(width: 200)
    }
}
