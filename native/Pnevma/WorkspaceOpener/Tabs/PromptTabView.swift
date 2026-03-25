import SwiftUI

struct PromptTabView: View {
    @Bindable var viewModel: WorkspaceOpenerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
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

                TextEditor(text: $viewModel.promptText)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(DesignTokens.Opacity.subtle))
                    )
                    .frame(height: viewModel.promptEditorHeight, alignment: .top)
                    .overlay(alignment: .topLeading) {
                        if viewModel.promptText.isEmpty {
                            Text("What do you want to do?")
                                .font(.system(size: 13))
                                .foregroundStyle(.tertiary)
                                .padding(12)
                                .allowsHitTesting(false)
                        }
                    }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(DesignTokens.Motion.resolved(.easeInOut(duration: 0.2))) {
                        viewModel.showAdvancedOptions.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(viewModel.showAdvancedOptions ? 90 : 0))
                            .animation(DesignTokens.Motion.resolved(.easeInOut(duration: 0.2)), value: viewModel.showAdvancedOptions)
                        Text("Advanced")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                if viewModel.showAdvancedOptions {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Terminal")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Picker("", selection: $viewModel.terminalMode) {
                                Text("Persistent").tag(WorkspaceTerminalMode.persistent)
                                Text("Non-Persistent").tag(WorkspaceTerminalMode.nonPersistent)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 188)
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
                }
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.top, 12)
        .padding(.bottom, DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
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
