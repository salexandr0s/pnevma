import SwiftUI

// MARK: - AgentsSection

struct AgentsSection: View {
    var viewModel: AgentViewModel
    @State private var showDeleteAgentAlert = false
    @State private var agentToDelete: String? = nil

    var body: some View {
        if let editingAgent = viewModel.editingAgent {
            AgentFormCard(agent: Binding(
                get: { editingAgent },
                set: { viewModel.editingAgent = $0 }
            ), onSave: { agent in
                viewModel.save(agent)
            }, onCancel: {
                viewModel.cancelEditing()
            })
        } else if viewModel.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.agents.isEmpty {
            EmptyStateView(
                icon: "person.3",
                title: "No Agent Profiles",
                message: "Create an agent profile to configure AI agent behavior.",
                actionTitle: "Create Agent",
                action: { viewModel.startCreating() }
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.agents) { agent in
                        AgentRow(agent: agent, viewModel: viewModel, onRequestDelete: { id in
                            agentToDelete = id
                            showDeleteAgentAlert = true
                        })
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(12)
            }
            .alert("Delete Agent Profile?", isPresented: $showDeleteAgentAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let id = agentToDelete {
                        viewModel.delete(id)
                    }
                }
            } message: {
                Text("This agent profile will be permanently removed.")
            }
        }
    }
}

struct AgentRow: View {
    let agent: AgentProfileFullItem
    var viewModel: AgentViewModel
    var onRequestDelete: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.headline)
                    RoleBadge(role: agent.role)
                    if let source = agent.source, source != "user" {
                        SourceBadge(source: source)
                    }
                }
                HStack(spacing: 4) {
                    Image(systemName: agent.provider == "anthropic" ? "brain.head.profile" : "sparkle")
                        .font(.caption2)
                        .foregroundStyle(agent.provider == "anthropic"
                            ? Color(red: 0.85, green: 0.55, blue: 0.35)
                            : Color(red: 0.3, green: 0.75, blue: 0.45))
                    Text("\(agent.provider) / \(agent.model)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let prompt = agent.systemPrompt, !prompt.isEmpty {
                    Text(String(prompt.prefix(80)) + (prompt.count > 80 ? "\u{2026}" : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                if viewModel.scope == .global {
                    Button(action: { viewModel.copyToProject(agent.id) }) {
                        Image(systemName: "arrow.down.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy to Project")
                } else {
                    Button(action: { viewModel.copyToGlobal(agent.id) }) {
                        Image(systemName: "arrow.up.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy to Global")
                }
                Button(action: { viewModel.startEditing(agent) }) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                Button(action: { onRequestDelete(agent.id) }) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(.rect(cornerRadius: 8))
    }
}

// MARK: - AgentFormCard

struct AgentFormCard: View {
    @Binding var agent: AgentProfileFullItem
    let onSave: (AgentProfileFullItem) -> Void
    let onCancel: () -> Void
    @State private var showAdvanced = false
    @State private var stationsText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Text(agent.createdAt == nil ? "New Agent" : "Edit Agent")
                        .font(.headline)
                    Spacer()
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.borderless)
                    Button("Save") { onSave(agent) }
                        .buttonStyle(.borderedProminent)
                        .disabled(agent.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // Name
                TextField("Agent name", text: $agent.name)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)

                // Provider + Model
                HStack(spacing: 8) {
                    Picker("", selection: $agent.provider) {
                        Label {
                            Text("Anthropic")
                        } icon: {
                            Image(systemName: "brain.head.profile")
                                .foregroundStyle(Color(red: 0.85, green: 0.55, blue: 0.35))
                        }
                        .tag("anthropic")
                        Label {
                            Text("OpenAI")
                        } icon: {
                            Image(systemName: "sparkle")
                                .foregroundStyle(Color(red: 0.3, green: 0.75, blue: 0.45))
                        }
                        .tag("openai")
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    TextField("Model ID", text: $agent.model)
                        .textFieldStyle(.roundedBorder)
                }

                // System Prompt — always visible, full editor
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Prompt")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { agent.systemPrompt ?? "" },
                        set: { agent.systemPrompt = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                }

                // Advanced
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Role", selection: $agent.role) {
                            Text("Build").tag("build")
                            Text("Plan").tag("plan")
                            Text("Review").tag("review")
                            Text("Ops").tag("ops")
                            Text("Research").tag("research")
                            Text("Test").tag("test")
                            Text("Custom").tag("custom")
                        }
                        HStack {
                            Text("Token Budget")
                            Spacer()
                            TextField("", value: $agent.tokenBudget, format: .number)
                                .frame(width: 100)
                                .multilineTextAlignment(.trailing)
                        }
                        HStack {
                            Text("Timeout (min)")
                            Spacer()
                            TextField("", value: $agent.timeoutMinutes, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }
                        Stepper("Max Concurrent: \(agent.maxConcurrent)", value: $agent.maxConcurrent, in: 1...10)
                        TextField("Stations (comma-separated)", text: $stationsText)
                            .onAppear { stationsText = agent.stations.joined(separator: ", ") }
                            .onChange(of: stationsText) {
                                agent.stations = stationsText
                                    .split(separator: ",")
                                    .map { $0.trimmingCharacters(in: .whitespaces) }
                                    .filter { !$0.isEmpty }
                            }
                        Toggle("Active", isOn: $agent.active)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }
}
