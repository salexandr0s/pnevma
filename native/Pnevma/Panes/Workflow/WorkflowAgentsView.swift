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
                    if let source = agent.source, source != "user" {
                        SourceBadge(source: source)
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
                        Text("Anthropic").tag("anthropic")
                        Text("OpenAI").tag("openai")
                    }
                    .labelsHidden()
                    .frame(width: 120)
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
