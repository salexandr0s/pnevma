import SwiftUI

// MARK: - AgentsSection

struct AgentsSection: View {
    var viewModel: AgentViewModel

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
            VStack(spacing: 12) {
                Image(systemName: "person.3")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("No agent profiles")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Create an agent profile to configure AI agent behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Create Agent") { viewModel.startCreating() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.agents) { agent in
                        AgentRow(agent: agent, viewModel: viewModel)
                    }
                }
                .padding(12)
            }
        }
    }
}

struct AgentRow: View {
    let agent: AgentProfileFullItem
    var viewModel: AgentViewModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.headline)
                    RoleBadge(role: agent.role)
                    if !agent.active {
                        Text("inactive")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(.rect(cornerRadius: 4))
                    }
                }
                Text("\(agent.provider) / \(agent.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Button(action: { viewModel.delete(agent.id) }) {
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
    @State private var stationsText: String = ""
    @State private var promptExpanded = false

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

                GroupBox("Identity") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Name", text: $agent.name)
                        Picker("Role", selection: $agent.role) {
                            Text("Build").tag("build")
                            Text("Plan").tag("plan")
                            Text("Review").tag("review")
                            Text("Ops").tag("ops")
                            Text("Research").tag("research")
                            Text("Test").tag("test")
                            Text("Custom").tag("custom")
                        }
                    }
                    .padding(4)
                }

                GroupBox("Model") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Provider", selection: $agent.provider) {
                            Text("Anthropic").tag("anthropic")
                            Text("OpenAI").tag("openai")
                        }
                        TextField("Model", text: $agent.model)
                        HStack {
                            Text("Token Budget")
                            Spacer()
                            TextField("", value: $agent.tokenBudget, format: .number)
                                .frame(width: 100)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .padding(4)
                }

                GroupBox("Execution") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Timeout (min)")
                            Spacer()
                            TextField("", value: $agent.timeoutMinutes, format: .number)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                        }
                        Stepper("Max Concurrent: \(agent.maxConcurrent)", value: $agent.maxConcurrent, in: 1...10)
                        Toggle("Active", isOn: $agent.active)
                    }
                    .padding(4)
                }

                GroupBox("Stations") {
                    TextField("Comma-separated station names", text: $stationsText)
                        .onAppear { stationsText = agent.stations.joined(separator: ", ") }
                        .onChange(of: stationsText) {
                            agent.stations = stationsText
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        }
                        .padding(4)
                }

                GroupBox("System Prompt") {
                    VStack(alignment: .leading, spacing: 4) {
                        if promptExpanded {
                            TextEditor(text: Binding(
                                get: { agent.systemPrompt ?? "" },
                                set: { agent.systemPrompt = $0.isEmpty ? nil : $0 }
                            ))
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 120)
                        } else {
                            TextField("Optional system prompt", text: Binding(
                                get: { agent.systemPrompt ?? "" },
                                set: { agent.systemPrompt = $0.isEmpty ? nil : $0 }
                            ))
                        }
                        Button(promptExpanded ? "Collapse" : "Expand") {
                            promptExpanded.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(4)
                }
            }
            .padding(16)
        }
    }
}
