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
                LazyVStack(spacing: 6) {
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

// MARK: - AgentRow

struct AgentRow: View {
    let agent: AgentProfileFullItem
    var viewModel: AgentViewModel
    var onRequestDelete: (String) -> Void = { _ in }

    @State private var isHovering = false

    private var providerLogo: String? {
        switch agent.provider.lowercased() {
        case "anthropic": "anthropic-logo"
        case "openai": "openai-logo"
        default: nil
        }
    }

    private var providerColor: Color {
        switch agent.provider.lowercased() {
        case "anthropic": Color(red: 0.85, green: 0.55, blue: 0.35)
        case "openai": Color(red: 0.3, green: 0.75, blue: 0.45)
        default: .secondary
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(roleColor(for: agent.role))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: roleIcon(for: agent.role))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(agent.name)
                        .font(.system(size: 13, weight: .semibold))
                    RoleBadge(role: agent.role)
                    if let source = agent.source, source != "user" {
                        SourceBadge(source: source)
                    }
                }

                HStack(spacing: 4) {
                    if let logo = providerLogo {
                        Image(logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                            .foregroundStyle(providerColor)
                    }
                    Text(agent.model)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let prompt = agent.systemPrompt, !prompt.isEmpty {
                    Text(String(prompt.prefix(120)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if viewModel.scope == .global {
                    Button("Copy to Project", systemImage: "arrow.down.doc") {
                        viewModel.copyToProject(agent.id)
                    }
                    .help("Copy to Project")
                } else {
                    Button("Copy to Global", systemImage: "arrow.up.doc") {
                        viewModel.copyToGlobal(agent.id)
                    }
                    .help("Copy to Global")
                }
                Button("Edit Agent", systemImage: "pencil") {
                    viewModel.startEditing(agent)
                }
                .help("Edit Agent")
                Button("Delete Agent", systemImage: "trash") {
                    onRequestDelete(agent.id)
                }
                .foregroundStyle(Color.red.opacity(0.7))
                .help("Delete Agent")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: 12))
            .opacity(isHovering ? 1.0 : 0.3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
                if isHovering {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.primary.opacity(0.04))
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(isHovering ? 0.5 : 0.2), lineWidth: 0.5)
        )
        .onHover { isHovering = $0 }
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
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(roleColor(for: agent.role))
                        .frame(width: 32, height: 32)
                        .overlay {
                            Image(systemName: roleIcon(for: agent.role))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                        }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(agent.createdAt == nil ? "New Agent" : "Edit Agent")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Configure agent profile and behavior")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Cancel") { onCancel() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Save") { onSave(agent) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(agent.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Divider()

                // Name
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("Agent name", text: $agent.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                }

                // Provider + Model
                VStack(alignment: .leading, spacing: 4) {
                    Text("Provider & Model")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Picker("", selection: $agent.provider) {
                            Label {
                                Text("Anthropic")
                            } icon: {
                                Image("anthropic-logo")
                                    .foregroundStyle(Color(red: 0.85, green: 0.55, blue: 0.35))
                            }
                            .tag("anthropic")
                            Label {
                                Text("OpenAI")
                            } icon: {
                                Image("openai-logo")
                                    .foregroundStyle(Color(red: 0.3, green: 0.75, blue: 0.45))
                            }
                            .tag("openai")
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        TextField("Model ID", text: $agent.model)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                // System Prompt
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Prompt")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: Binding(
                        get: { agent.systemPrompt ?? "" },
                        set: { agent.systemPrompt = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    )
                }

                // Advanced
                DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 12) {
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
            .padding(20)
        }
    }
}
