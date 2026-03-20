import SwiftUI

// MARK: - Main View

struct WorkflowView: View {
    @State private var viewModel = WorkflowViewModel()
    @State private var agentViewModel = AgentViewModel()
    @State private var topLevel: TopLevel = .agents
    @State private var workflowTab: WorkflowTab = .library
    @State private var scope: OrchestrationScope = .global

    enum TopLevel: String, CaseIterable {
        case agents = "Agents"
        case workflows = "Workflows"
    }

    enum WorkflowTab: String, CaseIterable {
        case library = "Library"
        case active = "Active"
        case builder = "Builder"
    }

    var body: some View {
        NativePaneScaffold(
            title: "Workflow & Agents",
            subtitle: "Reusable definitions, active orchestration, and agent registry",
            systemImage: "arrow.triangle.branch",
            role: .manager,
            inlineHeaderIdentifier: "pane.workflow.inlineHeader",
            inlineHeaderLabel: "Workflow inline header"
        ) {
            HStack(spacing: 6) {
                Text("Scope")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Picker("Scope", selection: $scope) {
                    ForEach(OrchestrationScope.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
            }

            Picker("", selection: $topLevel) {
                ForEach(TopLevel.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)

            if topLevel == .workflows {
                Picker("", selection: $workflowTab) {
                    ForEach(WorkflowTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
            }

            if topLevel == .agents {
                Button(action: { agentViewModel.startCreating() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
            } else if workflowTab == .library {
                Button(action: { workflowTab = .builder; viewModel.resetBuilder() }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n", modifiers: .command)
            }
        } content: {
            if topLevel == .agents {
                AgentsSection(viewModel: agentViewModel)
            } else {
                switch workflowTab {
                case .library:
                    LibrarySection(viewModel: viewModel, onEdit: { def in
                        viewModel.loadForEditing(def)
                        workflowTab = .builder
                    })
                case .active:
                    ActiveSection(viewModel: viewModel)
                case .builder:
                    BuilderSection(viewModel: viewModel, onSaved: {
                        workflowTab = .library
                    }, onRun: {
                        workflowTab = .active
                    })
                }
            }
        }
        .task(id: scope) {
            viewModel.scope = scope
            agentViewModel.scope = scope
            viewModel.load()
            agentViewModel.load()
        }
        .accessibilityIdentifier("pane.workflow")
    }
}

// MARK: - Library Section

struct LibrarySection: View {
    var viewModel: WorkflowViewModel
    var onEdit: (WorkflowDefItem) -> Void
    @State private var showDeleteAlert = false
    @State private var workflowToDelete: String? = nil

    var body: some View {
        if viewModel.definitions.isEmpty {
            EmptyStateView(
                icon: "arrow.triangle.branch",
                title: "No workflows defined",
                message: "Create one with the + button"
            )
        } else {
            List(viewModel.definitions) { def in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(def.name).font(.headline)
                        Spacer()
                        Text(def.source)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(def.source == "user" ? Color.blue.opacity(0.15) : Color.gray.opacity(0.15)))
                    }
                    if let desc = def.description {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("\(def.steps?.count ?? 0) steps")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if def.source == "user" {
                            Button("Edit") { onEdit(def) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            Button("Delete") {
                                workflowToDelete = def.dbId
                                showDeleteAlert = true
                            }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .foregroundStyle(.red)
                        }
                        Button("Run") { viewModel.instantiate(def.name) }
                            .buttonStyle(.bordered)
                            .font(.caption)
                    }
                }
                .padding(.vertical, 4)
            }
            .alert("Delete Workflow?", isPresented: $showDeleteAlert) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    if let id = workflowToDelete {
                        viewModel.deleteWorkflow(id)
                    }
                }
            } message: {
                Text("This workflow will be permanently removed.")
            }
        }
    }
}

// MARK: - Active Section

struct ActiveSection: View {
    var viewModel: WorkflowViewModel

    var body: some View {
        if viewModel.instances.isEmpty {
            EmptyStateView(
                icon: "play.circle",
                title: "No active workflow instances",
                message: "Run a workflow from the Library tab"
            )
        } else {
            List(viewModel.instances) { inst in
                Button(action: { viewModel.loadInstanceDetail(inst.id) }) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(inst.workflowName).font(.headline)
                            Spacer()
                            StatusBadge(status: inst.status)
                        }
                        if let desc = inst.description {
                            Text(desc).font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(inst.taskIds.count) tasks")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if let detail = viewModel.selectedDetail {
                Divider()
                InstanceDetailView(detail: detail)
            }
        }
    }
}
