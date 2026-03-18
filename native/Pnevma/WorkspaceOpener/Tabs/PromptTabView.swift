import SwiftUI

struct PromptTabView: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel

    private var promptHeightRange: ClosedRange<CGFloat> {
        if viewModel.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 68...68
        }
        return 120...220
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Agent picker
            HStack {
                Text("Agent")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("No agent") { viewModel.selectedAgentID = nil }
                    Divider()
                    Button(AgentKind.claude.label) {
                        viewModel.selectedAgentID = AgentKind.claude.rawValue
                    }
                    Button(AgentKind.codex.label) {
                        viewModel.selectedAgentID = AgentKind.codex.rawValue
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(
                            viewModel.selectedAgentID
                                .flatMap { AgentKind(rawValue: $0)?.label } ?? "No agent"
                        )
                        .font(.system(size: 12))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // Prompt text area
            TextEditor(text: $viewModel.promptText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(DesignTokens.Opacity.subtle))
                )
                .frame(
                    minHeight: promptHeightRange.lowerBound,
                    maxHeight: promptHeightRange.upperBound,
                    alignment: .top
                )
                .overlay(alignment: .topLeading) {
                    if viewModel.promptText.isEmpty {
                        Text("What do you want to do?")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }

            // Advanced options
            DisclosureGroup(isExpanded: $viewModel.showAdvancedOptions) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Terminal")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Picker("", selection: $viewModel.terminalMode) {
                            Text("Persistent").tag(WorkspaceTerminalMode.persistent)
                            Text("Non-Persistent").tag(WorkspaceTerminalMode.nonPersistent)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                    }

                    Toggle("Remote SSH", isOn: $viewModel.sshEnabled)
                        .font(.system(size: 12))

                    if viewModel.sshEnabled {
                        sshFields
                    }

                    HStack {
                        Text("Name")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        TextField("Auto", text: $viewModel.workspaceNameOverride)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Advanced")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignTokens.Spacing.md)
    }

    @ViewBuilder
    private var sshFields: some View {
        Group {
            LabeledContent("Host") {
                TextField("hostname or IP", text: $viewModel.sshHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            LabeledContent("User") {
                TextField("username", text: $viewModel.sshUser)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            LabeledContent("Port") {
                TextField("22", text: $viewModel.sshPort)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 80)
            }
            LabeledContent("Path") {
                TextField("~/project", text: $viewModel.sshRemotePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
        }
        .font(.system(size: 12))
    }
}
