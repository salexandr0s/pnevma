import SwiftUI
import Cocoa

// MARK: - Data Models

struct WorkflowDefItem: Identifiable, Codable {
    var id: String { dbId ?? name }
    let dbId: String?
    let name: String
    let description: String?
    let source: String
    let steps: [WorkflowStepDef]?

    enum CodingKeys: String, CodingKey {
        case dbId = "id"
        case name, description, source, steps
    }
}

enum LoopMode: String, Codable, CaseIterable {
    case onFailure = "on_failure"
    case untilComplete = "until_complete"
}

struct LoopConfig: Codable {
    var target: Int
    var maxIterations: Int = 5
    var mode: LoopMode = .onFailure
}

struct WorkflowStepDef: Codable {
    var title: String = ""
    var goal: String = ""
    var scope: [String] = []
    var priority: String = "P1"
    var dependsOn: [Int] = []
    var autoDispatch: Bool = true
    var agentProfile: String?
    var executionMode: String = "worktree"
    var timeoutMinutes: Int?
    var maxRetries: Int?
    var acceptanceCriteria: [String] = []
    var constraints: [String] = []
    var onFailure: String = "Pause"
    var loopConfig: LoopConfig?
}

struct WorkflowInstanceItem: Identifiable, Codable {
    let id: String
    let workflowName: String
    let description: String?
    let status: String
    let taskIDs: [String]
    let createdAt: String
    let updatedAt: String

    var taskIds: [String] { taskIDs }
}

struct WorkflowInstanceDetail: Codable {
    let id: String
    let workflowName: String
    let description: String?
    let status: String
    let steps: [WorkflowInstanceStepItem]
    let createdAt: String
    let updatedAt: String
}

struct WorkflowInstanceStepItem: Identifiable, Codable {
    var id: String { "\(taskID)-\(iteration)" }
    let stepIndex: Int
    let iteration: Int
    let taskID: String
    let title: String
    let goal: String
    let status: String
    let priority: String
    let dependsOn: [String]
    let agentProfile: String?
    let executionMode: String
    let branch: String?
    let createdAt: String
    let updatedAt: String

    var taskId: String { taskID }

    var statusColor: Color {
        switch status.lowercased() {
        case "completed", "done": return .green
        case "inprogress", "in_progress", "running": return .blue
        case "failed": return .red
        case "blocked": return .orange
        case "ready": return .cyan
        case "looped": return .purple
        default: return .secondary
        }
    }
}

struct AgentProfileItem: Identifiable, Codable {
    let id: String
    let name: String
    let role: String?
    let provider: String
    let model: String
    let tokenBudget: Int?
    let timeoutMinutes: Int
    let maxConcurrent: Int
    let stations: [String]?
    let systemPrompt: String?
    let active: Bool?
    let scope: String?

    var displayName: String {
        "\(name) (\(provider) / \(model))"
    }

    enum CodingKeys: String, CodingKey {
        case id, name, role, provider, model
        case tokenBudget = "token_budget"
        case timeoutMinutes = "timeout_minutes"
        case maxConcurrent = "max_concurrent"
        case stations
        case systemPrompt = "system_prompt"
        case active, scope
    }
}

struct AgentProfileFullItem: Identifiable, Codable {
    let id: String
    var name: String
    var role: String
    var provider: String
    var model: String
    var tokenBudget: Int
    var timeoutMinutes: Int
    var maxConcurrent: Int
    var stations: [String]
    var configJson: String
    var systemPrompt: String?
    var active: Bool
    let scope: String?
    let createdAt: String?
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, name, role, provider, model
        case tokenBudget = "token_budget"
        case timeoutMinutes = "timeout_minutes"
        case maxConcurrent = "max_concurrent"
        case stations
        case configJson = "config_json"
        case systemPrompt = "system_prompt"
        case active, scope
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

enum OrchestrationScope: String, CaseIterable {
    case global = "Global"
    case project = "Project"
}

// MARK: - Main View

struct WorkflowView: View {
    @StateObject private var viewModel = WorkflowViewModel()
    @StateObject private var agentViewModel = AgentViewModel()
    @State private var selectedTab: Tab = .library
    @State private var scope: OrchestrationScope = .global

    enum Tab: String, CaseIterable {
        case library = "Library"
        case active = "Active"
        case builder = "Builder"
        case agents = "Agents"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Agents")
                    .font(.headline)
                Spacer()
                // Scope selector
                Picker("Scope", selection: $scope) {
                    ForEach(OrchestrationScope.allCases, id: \.self) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .onChange(of: scope) {
                    viewModel.scope = scope
                    agentViewModel.scope = scope
                    viewModel.load()
                    agentViewModel.load()
                }
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 340)
                if selectedTab == .library {
                    Button(action: { selectedTab = .builder; viewModel.resetBuilder() }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                }
                if selectedTab == .agents {
                    Button(action: { agentViewModel.startCreating() }) {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(12)
            Divider()

            // Content
            switch selectedTab {
            case .library:
                LibrarySection(viewModel: viewModel, onEdit: { def in
                    viewModel.loadForEditing(def)
                    selectedTab = .builder
                })
            case .active:
                ActiveSection(viewModel: viewModel)
            case .builder:
                BuilderSection(viewModel: viewModel, onSaved: {
                    selectedTab = .library
                }, onRun: {
                    selectedTab = .active
                })
            case .agents:
                AgentsSection(viewModel: agentViewModel)
            }
        }
        .onAppear {
            viewModel.scope = scope
            agentViewModel.scope = scope
            viewModel.load()
            agentViewModel.load()
        }
    }
}

// MARK: - Library Section

struct LibrarySection: View {
    @ObservedObject var viewModel: WorkflowViewModel
    var onEdit: (WorkflowDefItem) -> Void

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
                                if let dbId = def.dbId { viewModel.deleteWorkflow(dbId) }
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
        }
    }
}

// MARK: - Active Section

struct ActiveSection: View {
    @ObservedObject var viewModel: WorkflowViewModel

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

// MARK: - Instance Detail View (DAG)

struct InstanceDetailView: View {
    let detail: WorkflowInstanceDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(detail.workflowName).font(.headline)
                StatusBadge(status: detail.status)
                Spacer()
                Text("\(detail.steps.count) steps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider().opacity(0.3)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(layers.enumerated()), id: \.offset) { layerIdx, layer in
                        let (_, layerSteps) = layer
                        VStack(spacing: 10) {
                            ForEach(layerSteps) { step in
                                InstanceStepNode(step: step)
                            }
                        }
                        if layerIdx < layers.count - 1 {
                            // Single connector between layers — intentional
                            // simplification; per-node edges would need Canvas.
                            VStack {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary.opacity(0.4))
                            }
                            .frame(width: 28)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var layers: [(Int, [WorkflowInstanceStepItem])] {
        var depths: [String: Int] = [:]
        for step in detail.steps where step.dependsOn.isEmpty {
            depths[step.taskId] = 0
        }
        var changed = true
        var iterations = 0
        while changed && iterations < detail.steps.count {
            changed = false
            iterations += 1
            for step in detail.steps where depths[step.taskId] == nil {
                let depDepths = step.dependsOn.compactMap { depths[$0] }
                if depDepths.count == step.dependsOn.count {
                    depths[step.taskId] = (depDepths.max() ?? 0) + 1
                    changed = true
                }
            }
        }
        for step in detail.steps where depths[step.taskId] == nil {
            depths[step.taskId] = 0
        }
        let grouped = Dictionary(grouping: detail.steps) { depths[$0.taskId] ?? 0 }
        return grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

struct InstanceStepNode: View {
    let step: WorkflowInstanceStepItem

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator
            ZStack {
                Circle()
                    .fill(step.statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Circle()
                    .fill(step.statusColor)
                    .frame(width: 20, height: 20)
                    .overlay {
                        statusIcon
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                    }
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(step.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if step.iteration > 0 {
                        Text("iter \(step.iteration)")
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.purple.opacity(0.15))
                            .cornerRadius(3)
                            .foregroundStyle(.purple)
                    }
                }

                HStack(spacing: 6) {
                    if let profile = step.agentProfile {
                        Text(profile)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.purple.opacity(0.8))
                    }
                    HStack(spacing: 2) {
                        Image(systemName: step.executionMode == "main" ? "house.fill" : "arrow.triangle.branch")
                            .font(.system(size: 8))
                        Text(step.executionMode)
                            .font(.system(size: 9))
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(minWidth: 160, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(step.statusColor.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(step.statusColor.opacity(0.2), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title), \(step.status), \(step.executionMode)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status.lowercased() {
        case "completed", "done": Image(systemName: "checkmark")
        case "inprogress", "in_progress", "running": Image(systemName: "play.fill")
        case "failed": Image(systemName: "xmark")
        case "blocked": Image(systemName: "lock.fill")
        case "ready": Image(systemName: "bolt.fill")
        case "looped": Image(systemName: "arrow.trianglehead.2.clockwise")
        default: Image(systemName: "clock")
        }
    }
}

// MARK: - Builder Section

struct BuilderSection: View {
    @ObservedObject var viewModel: WorkflowViewModel
    var onSaved: () -> Void
    var onRun: () -> Void
    @State private var mode: BuilderMode = .form
    @State private var yamlText: String = ""
    @State private var yamlError: String?

    enum BuilderMode: String, CaseIterable {
        case form = "Form"
        case source = "Source"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Builder header
            HStack {
                TextField("Workflow name", text: $viewModel.builderName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                TextField("Description (optional)", text: $viewModel.builderDescription)
                    .textFieldStyle(.roundedBorder)
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(BuilderMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: mode) {
                    if mode == .source {
                        yamlText = viewModel.serializeToYAML()
                    } else {
                        if !viewModel.parseFromYAML(yamlText) {
                            yamlError = "Invalid YAML — could not parse"
                        } else {
                            yamlError = nil
                        }
                    }
                }
            }
            .padding(12)
            Divider()

            // Content
            switch mode {
            case .form:
                FormBuilder(viewModel: viewModel)
            case .source:
                VStack(spacing: 0) {
                    TextEditor(text: $yamlText)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                    if let err = yamlError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 4)
                    }
                }
            }

            // Live DAG Preview
            if !viewModel.builderSteps.isEmpty {
                Divider().opacity(0.3)
                MiniDagPreview(steps: viewModel.builderSteps)
                    .frame(height: 100)
            }

            Divider().opacity(0.3)
            // Actions
            HStack(spacing: 10) {
                Button("Cancel") {
                    viewModel.resetBuilder()
                    onSaved()
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)

                Spacer()

                if let err = viewModel.error {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                        Text(err)
                            .font(.caption)
                    }
                    .foregroundStyle(.red)
                }

                Button(action: {
                    if mode == .source { _ = viewModel.parseFromYAML(yamlText) }
                    viewModel.save { onSaved() }
                }) {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                Button(action: {
                    if mode == .source { _ = viewModel.parseFromYAML(yamlText) }
                    viewModel.saveAndRun { onRun() }
                }) {
                    Label("Save & Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(12)
        }
    }
}

// MARK: - Form Builder

struct FormBuilder: View {
    @ObservedObject var viewModel: WorkflowViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(viewModel.builderSteps.indices, id: \.self) { idx in
                    StepFormCard(
                        step: $viewModel.builderSteps[idx],
                        index: idx,
                        totalSteps: viewModel.builderSteps.count,
                        profiles: viewModel.availableProfiles,
                        allStepTitles: viewModel.builderSteps.map(\.title),
                        onDelete: { viewModel.removeStep(at: idx) },
                        onMoveUp: idx > 0 ? { viewModel.moveStep(from: idx, to: idx - 1) } : nil,
                        onMoveDown: idx < viewModel.builderSteps.count - 1 ? { viewModel.moveStep(from: idx, to: idx + 1) } : nil
                    )
                }

                Button(action: { viewModel.addStep() }) {
                    HStack {
                        Image(systemName: "plus.circle")
                        Text("Add Step")
                    }
                }
                .buttonStyle(.borderless)
                .padding(.top, 8)
            }
            .padding(16)
        }
    }
}

// MARK: - Step Form Card

struct StepFormCard: View {
    @Binding var step: WorkflowStepDef
    let index: Int
    let totalSteps: Int
    let profiles: [AgentProfileItem]
    let allStepTitles: [String]
    var onDelete: () -> Void
    var onMoveUp: (() -> Void)?
    var onMoveDown: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("Step \(index + 1)")
                    .font(.subheadline.bold())
                Spacer()
                if let up = onMoveUp {
                    Button(action: up) { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless)
                }
                if let down = onMoveDown {
                    Button(action: down) { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless)
                }
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Title").font(.caption).foregroundStyle(.secondary)
                    TextField("Step title", text: $step.title)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Priority").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $step.priority) {
                        Text("P0").tag("P0")
                        Text("P1").tag("P1")
                        Text("P2").tag("P2")
                        Text("P3").tag("P3")
                    }
                    .frame(width: 70)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Goal").font(.caption).foregroundStyle(.secondary)
                TextField("What this step achieves", text: $step.goal, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent Profile").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: Binding(
                        get: { step.agentProfile ?? "" },
                        set: { step.agentProfile = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("(default)").tag("")
                        ForEach(profiles) { p in
                            Text(p.displayName).tag(p.name)
                        }
                    }
                    .frame(minWidth: 160)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mode").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $step.executionMode) {
                        Text("Worktree").tag("worktree")
                        Text("Main").tag("main")
                    }
                    .frame(width: 100)
                }
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On Failure").font(.caption).foregroundStyle(.secondary)
                    Picker("", selection: $step.onFailure) {
                        Text("Pause").tag("Pause")
                        Text("RetryOnce").tag("RetryOnce")
                        Text("Skip").tag("Skip")
                    }
                    .frame(width: 110)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Timeout (min)").font(.caption).foregroundStyle(.secondary)
                    TextField("", value: $step.timeoutMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Retries").font(.caption).foregroundStyle(.secondary)
                    Stepper(value: Binding(
                        get: { step.maxRetries ?? 0 },
                        set: { step.maxRetries = $0 == 0 ? nil : $0 }
                    ), in: 0...5) {
                        Text("\(step.maxRetries ?? 0)")
                    }
                    .frame(width: 100)
                }
                Toggle("Auto-dispatch", isOn: $step.autoDispatch)
                    .toggleStyle(.checkbox)
            }

            // Depends on
            if index > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Depends on").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(0..<index, id: \.self) { depIdx in
                            let title = depIdx < allStepTitles.count ? allStepTitles[depIdx] : "Step \(depIdx + 1)"
                            let isSelected = step.dependsOn.contains(depIdx)
                            Button(action: {
                                if isSelected {
                                    step.dependsOn.removeAll { $0 == depIdx }
                                } else {
                                    step.dependsOn.append(depIdx)
                                }
                            }) {
                                Text(title.isEmpty ? "Step \(depIdx + 1)" : title)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule().fill(isSelected ? Color.blue.opacity(0.2) : Color.gray.opacity(0.1))
                                    )
                                    .overlay(
                                        Capsule().stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Loop Configuration
            do {
                let loopEnabled = Binding<Bool>(
                    get: { step.loopConfig != nil },
                    set: { enabled in
                        if enabled {
                            step.loopConfig = LoopConfig(target: 0, maxIterations: 5)
                        } else {
                            step.loopConfig = nil
                        }
                    }
                )
                DisclosureGroup("Loop") {
                    Toggle("Enable Loop", isOn: loopEnabled)
                        .toggleStyle(.checkbox)
                    if let _ = step.loopConfig {
                        let loopMode = Binding<LoopMode>(
                            get: { step.loopConfig?.mode ?? .onFailure },
                            set: { newMode in
                                step.loopConfig?.mode = newMode
                                if newMode == .onFailure, let t = step.loopConfig?.target, t >= index {
                                    step.loopConfig?.target = max(index - 1, 0)
                                }
                            }
                        )
                        let loopTarget = Binding<Int>(
                            get: { step.loopConfig?.target ?? 0 },
                            set: { step.loopConfig?.target = $0 }
                        )
                        let loopMaxIter = Binding<Int>(
                            get: { step.loopConfig?.maxIterations ?? 5 },
                            set: { step.loopConfig?.maxIterations = $0 }
                        )
                        Picker("Mode", selection: loopMode) {
                            Text("On Failure").tag(LoopMode.onFailure)
                            Text("Until Complete (Ralph)").tag(LoopMode.untilComplete)
                        }
                        let maxTarget = loopMode.wrappedValue == .untilComplete ? index : max(index - 1, 0)
                        if loopMode.wrappedValue == .onFailure && index == 0 {
                            Text("No valid loop targets (need earlier steps)")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        } else {
                            Picker("Loop back to", selection: loopTarget) {
                                ForEach(0...maxTarget, id: \.self) { i in
                                    let label = i == index ? "Self" : (i < allStepTitles.count ? allStepTitles[i] : "Step \(i + 1)")
                                    Text(label.isEmpty ? "Step \(i + 1)" : label).tag(i)
                                }
                            }
                        }
                        Stepper("Max iterations: \(loopMaxIter.wrappedValue)",
                                value: loopMaxIter, in: 1...20)
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - Mini DAG Preview

struct MiniDagPreview: View {
    let steps: [WorkflowStepDef]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Pipeline Preview")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Array(layers.enumerated()), id: \.offset) { layerIdx, layer in
                        let (_, layerSteps) = layer
                        VStack(spacing: 6) {
                            ForEach(layerSteps, id: \.offset) { idx, step in
                                MiniStepNode(
                                    title: step.title.isEmpty ? "Step \(idx + 1)" : step.title,
                                    agentProfile: step.agentProfile,
                                    stepIndex: idx + 1,
                                    hasLoop: step.loopConfig != nil
                                )
                            }
                        }
                        if layerIdx < layers.count - 1 {
                            MiniConnector()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
    }

    private var layers: [(Int, [(offset: Int, element: WorkflowStepDef)])] {
        var depths: [Int: Int] = [:]
        for (i, step) in steps.enumerated() where step.dependsOn.isEmpty {
            depths[i] = 0
        }
        var changed = true
        var iterations = 0
        while changed && iterations < steps.count {
            changed = false
            iterations += 1
            for (i, step) in steps.enumerated() where depths[i] == nil {
                let depDepths = step.dependsOn.compactMap { depths[$0] }
                if depDepths.count == step.dependsOn.count {
                    depths[i] = (depDepths.max() ?? 0) + 1
                    changed = true
                }
            }
        }
        for i in steps.indices where depths[i] == nil {
            depths[i] = 0
        }
        let indexed = Array(steps.enumerated())
        let grouped = Dictionary(grouping: indexed) { depths[$0.offset] ?? 0 }
        return grouped.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

private struct MiniStepNode: View {
    let title: String
    let agentProfile: String?
    let stepIndex: Int
    var hasLoop: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Text("\(stepIndex)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.blue.opacity(0.7)))

            Text(title)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary.opacity(0.8))

            if hasLoop {
                Image(systemName: "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(hasLoop ? Color.orange.opacity(0.3) : Color.blue.opacity(0.15), lineWidth: 1)
        )
    }
}

private struct MiniConnector: View {
    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 16, height: 1.5)
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Color.blue.opacity(0.3))
            Rectangle()
                .fill(Color.blue.opacity(0.2))
                .frame(width: 16, height: 1.5)
        }
        .frame(width: 40)
    }
}

// MARK: - StatusBadge

struct StatusBadge: View {
    let status: String
    var body: some View {
        Text(status)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
    private var color: Color {
        switch status.lowercased() {
        case "running": return .blue
        case "completed": return .green
        case "failed": return .red
        default: return .secondary
        }
    }
}

// MARK: - ViewModel

final class WorkflowViewModel: ObservableObject {
    @Published var definitions: [WorkflowDefItem] = []
    @Published var instances: [WorkflowInstanceItem] = []
    @Published var selectedDetail: WorkflowInstanceDetail?
    @Published var availableProfiles: [AgentProfileItem] = []
    @Published var isLoading = false
    @Published var error: String?

    // Builder state
    @Published var builderSteps: [WorkflowStepDef] = []
    @Published var builderName: String = ""
    @Published var builderDescription: String = ""
    var editingWorkflowId: String?
    var scope: OrchestrationScope = .global

    func load() {
        guard let bus = CommandBus.shared else {
            error = "Backend connection unavailable"
            return
        }
        isLoading = true
        error = nil
        let defsMethod = scope == .global ? "global_workflow.list" : "workflow.list_defs"
        let profilesMethod = scope == .global ? "global_agent.list" : "agent_profile.list"
        Task {
            do {
                async let defs: [WorkflowDefItem] = bus.call(method: defsMethod)
                async let profiles: [AgentProfileItem] = bus.call(method: profilesMethod)
                // Workflow instances are project-scoped; skip when in global scope
                let loadedInsts: [WorkflowInstanceItem]
                if scope == .project {
                    loadedInsts = try await bus.call(method: "workflow.list_instances")
                } else {
                    loadedInsts = []
                }
                let (d, p) = try await (defs, profiles)
                await MainActor.run {
                    self.definitions = d
                    self.instances = loadedInsts
                    self.availableProfiles = p
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func loadInstanceDetail(_ id: String) {
        guard let bus = CommandBus.shared else {
            error = "Backend connection unavailable"
            return
        }
        Task {
            do {
                struct Params: Encodable { let id: String }
                let detail: WorkflowInstanceDetail = try await bus.call(method: "workflow.get_instance", params: Params(id: id))
                await MainActor.run { self.selectedDetail = detail }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func instantiate(_ name: String) {
        guard let bus = CommandBus.shared else {
            error = "Backend connection unavailable"
            return
        }
        Task {
            do {
                struct Params: Encodable { let workflowName: String }
                let _: WorkflowInstanceItem = try await bus.call(method: "workflow.instantiate", params: Params(workflowName: name))
                load()
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func save(completion: @escaping () -> Void) {
        guard let bus = CommandBus.shared else {
            error = "Backend connection unavailable"
            return
        }
        let yaml = serializeToYAML()
        let updateMethod = scope == .global ? "global_workflow.update" : "workflow.update"
        let createMethod = scope == .global ? "global_workflow.create" : "workflow.create"
        Task {
            do {
                if let existingId = editingWorkflowId {
                    struct Params: Encodable { let id: String; let name: String?; let description: String?; let definitionYaml: String? }
                    let _: WorkflowDefItem = try await bus.call(
                        method: updateMethod,
                        params: Params(id: existingId, name: builderName, description: builderDescription.isEmpty ? nil : builderDescription, definitionYaml: yaml)
                    )
                } else {
                    struct Params: Encodable { let name: String; let description: String?; let definitionYaml: String }
                    let _: WorkflowDefItem = try await bus.call(
                        method: createMethod,
                        params: Params(name: builderName, description: builderDescription.isEmpty ? nil : builderDescription, definitionYaml: yaml)
                    )
                }
                load()
                await MainActor.run {
                    self.error = nil
                    completion()
                }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func saveAndRun(completion: @escaping () -> Void) {
        save {
            self.instantiate(self.builderName)
            completion()
        }
    }

    func deleteWorkflow(_ id: String) {
        guard let bus = CommandBus.shared else {
            error = "Backend connection unavailable"
            return
        }
        let deleteMethod = scope == .global ? "global_workflow.delete" : "workflow.delete"
        Task {
            do {
                struct Params: Encodable { let id: String }
                let _: OkResponse = try await bus.call(method: deleteMethod, params: Params(id: id))
                load()
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func loadForEditing(_ def: WorkflowDefItem) {
        editingWorkflowId = def.dbId
        builderName = def.name
        builderDescription = def.description ?? ""
        builderSteps = def.steps ?? []
    }

    func resetBuilder() {
        editingWorkflowId = nil
        builderName = ""
        builderDescription = ""
        builderSteps = [WorkflowStepDef()]
        error = nil
    }

    func addStep() {
        builderSteps.append(WorkflowStepDef())
    }

    func removeStep(at index: Int) {
        guard builderSteps.count > 1 else { return }
        builderSteps.remove(at: index)
        // Fix depends_on indices
        for i in builderSteps.indices {
            builderSteps[i].dependsOn = builderSteps[i].dependsOn.compactMap { dep in
                if dep == index { return nil }
                return dep > index ? dep - 1 : dep
            }
        }
    }

    func moveStep(from: Int, to: Int) {
        builderSteps.swapAt(from, to)
        // Fix all depends_on references
        for i in builderSteps.indices {
            builderSteps[i].dependsOn = builderSteps[i].dependsOn.map { dep in
                if dep == from { return to }
                if dep == to { return from }
                return dep
            }
        }
    }

    // MARK: YAML Sync

    private func yamlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: "\\n")
         .replacingOccurrences(of: "\r", with: "\\r")
         .replacingOccurrences(of: "\t", with: "\\t")
    }

    func serializeToYAML() -> String {
        var lines: [String] = []
        lines.append("name: \"\(yamlEscape(builderName))\"")
        if !builderDescription.isEmpty {
            lines.append("description: \"\(yamlEscape(builderDescription))\"")
        }
        lines.append("steps:")
        for step in builderSteps {
            lines.append("  - title: \"\(yamlEscape(step.title))\"")
            lines.append("    goal: \"\(yamlEscape(step.goal))\"")
            if let profile = step.agentProfile {
                lines.append("    agent_profile: \"\(yamlEscape(profile))\"")
            }
            lines.append("    execution_mode: \(step.executionMode)")
            lines.append("    priority: \(step.priority)")
            lines.append("    auto_dispatch: \(step.autoDispatch)")
            if !step.dependsOn.isEmpty {
                lines.append("    depends_on: [\(step.dependsOn.map(String.init).joined(separator: ", "))]")
            }
            if let timeout = step.timeoutMinutes {
                lines.append("    timeout_minutes: \(timeout)")
            }
            if let retries = step.maxRetries, retries > 0 {
                lines.append("    max_retries: \(retries)")
            }
            if step.onFailure != "Pause" {
                lines.append("    on_failure: \(step.onFailure.lowercased())")
            }
            if !step.scope.isEmpty {
                lines.append("    scope: [\(step.scope.map { "\"\(yamlEscape($0))\"" }.joined(separator: ", "))]")
            }
            if !step.acceptanceCriteria.isEmpty {
                lines.append("    acceptance_criteria:")
                for c in step.acceptanceCriteria {
                    lines.append("      - \"\(yamlEscape(c))\"")
                }
            }
            if !step.constraints.isEmpty {
                lines.append("    constraints:")
                for c in step.constraints {
                    lines.append("      - \"\(yamlEscape(c))\"")
                }
            }
            if let loop = step.loopConfig {
                lines.append("    loop:")
                lines.append("      target: \(loop.target)")
                lines.append("      max_iterations: \(loop.maxIterations)")
                if loop.mode != .onFailure {
                    lines.append("      mode: \(loop.mode.rawValue)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func parseFromYAML(_ yaml: String) -> Bool {
        let lines = yaml.components(separatedBy: "\n")
        var parsedName: String?
        var parsedDescription: String?
        var steps: [WorkflowStepDef] = []
        var currentStep: WorkflowStepDef?
        var collectingKey: String?
        var collectedItems: [String] = []

        func unquote(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if (t.hasPrefix("\"") && t.hasSuffix("\"")) || (t.hasPrefix("'") && t.hasSuffix("'")) {
                return String(t.dropFirst().dropLast())
            }
            return t
        }

        func parseKV(_ s: String) -> (String, String)? {
            guard let colonIdx = s.firstIndex(of: ":") else { return nil }
            let key = String(s[s.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
            let value = String(s[s.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
            return (key, value)
        }

        func parseInlineArray(_ s: String) -> [String]? {
            let t = s.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("[") && t.hasSuffix("]") else { return nil }
            let inner = String(t.dropFirst().dropLast())
            if inner.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
            return inner.components(separatedBy: ",").map { unquote($0) }
        }

        func flushCollection() {
            guard let key = collectingKey, currentStep != nil else {
                collectingKey = nil
                collectedItems = []
                return
            }
            switch key {
            case "acceptance_criteria": currentStep!.acceptanceCriteria = collectedItems
            case "constraints": currentStep!.constraints = collectedItems
            case "scope": currentStep!.scope = collectedItems
            default: break
            }
            collectingKey = nil
            collectedItems = []
        }

        func flushStep() {
            flushCollection()
            if let step = currentStep {
                steps.append(step)
                currentStep = nil
            }
        }

        func applyToStep(_ key: String, _ value: String) {
            guard currentStep != nil else { return }
            switch key {
            case "title": currentStep!.title = unquote(value)
            case "goal": currentStep!.goal = unquote(value)
            case "agent_profile": currentStep!.agentProfile = unquote(value)
            case "execution_mode": currentStep!.executionMode = unquote(value)
            case "priority": currentStep!.priority = unquote(value)
            case "auto_dispatch": currentStep!.autoDispatch = (value == "true")
            case "depends_on":
                if let arr = parseInlineArray(value) {
                    currentStep!.dependsOn = arr.compactMap { Int($0) }
                }
            case "timeout_minutes": currentStep!.timeoutMinutes = Int(value)
            case "max_retries": currentStep!.maxRetries = Int(value)
            case "on_failure":
                switch unquote(value).lowercased() {
                case "retryonce", "retry_once": currentStep!.onFailure = "RetryOnce"
                case "skip": currentStep!.onFailure = "Skip"
                default: currentStep!.onFailure = "Pause"
                }
            case "scope":
                if let arr = parseInlineArray(value) {
                    currentStep!.scope = arr
                } else if value.isEmpty {
                    collectingKey = "scope"
                    collectedItems = []
                }
            case "acceptance_criteria":
                if value.isEmpty {
                    collectingKey = "acceptance_criteria"
                    collectedItems = []
                }
            case "constraints":
                if value.isEmpty {
                    collectingKey = "constraints"
                    collectedItems = []
                }
            case "loop":
                if value.isEmpty {
                    // Start collecting loop sub-keys
                    collectingKey = "loop"
                    currentStep!.loopConfig = LoopConfig(target: 0, maxIterations: 5)
                }
            default: break
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count

            // Loop sub-keys (indent 6+, e.g. "      target: 0")
            if indent >= 6 && collectingKey == "loop" && currentStep != nil {
                if let (key, value) = parseKV(trimmed) {
                    switch key {
                    case "target": currentStep!.loopConfig?.target = Int(value) ?? 0
                    case "max_iterations": currentStep!.loopConfig?.maxIterations = Int(value) ?? 5
                    case "mode": currentStep!.loopConfig?.mode = LoopMode(rawValue: value) ?? .onFailure
                    default: break
                    }
                }
                continue
            }

            // Block sequence item (acceptance_criteria / constraints / scope)
            if indent >= 6 && trimmed.hasPrefix("- ") && collectingKey != nil {
                collectedItems.append(unquote(String(trimmed.dropFirst(2))))
                continue
            }

            // New step marker: "  - title: ..."
            if indent >= 2 && trimmed.hasPrefix("- ") {
                flushStep()
                currentStep = WorkflowStepDef()
                let rest = String(trimmed.dropFirst(2))
                if let (key, value) = parseKV(rest) {
                    applyToStep(key, value)
                }
                continue
            }

            // Step property: "    key: value"
            if indent >= 4 && currentStep != nil {
                flushCollection()
                if let (key, value) = parseKV(trimmed) {
                    applyToStep(key, value)
                }
                continue
            }

            // Top-level key
            if let (key, value) = parseKV(trimmed) {
                flushCollection()
                switch key {
                case "name": parsedName = unquote(value)
                case "description": parsedDescription = unquote(value)
                case "steps": break
                default: break
                }
            }
        }
        flushStep()

        guard let name = parsedName, !name.isEmpty, !steps.isEmpty else { return false }

        builderName = name
        builderDescription = parsedDescription ?? ""
        builderSteps = steps
        return true
    }
}

// MARK: - AgentViewModel

private struct CopyResponse: Decodable {
    let id: String
}

final class AgentViewModel: ObservableObject {
    @Published var agents: [AgentProfileFullItem] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var editingAgent: AgentProfileFullItem?
    @Published var isCreating = false
    var scope: OrchestrationScope = .global

    func load() {
        guard let bus = CommandBus.shared else { return }
        isLoading = true
        error = nil
        let method = scope == .global ? "global_agent.list" : "agent_profile.list"
        Task {
            do {
                let items: [AgentProfileFullItem] = try await bus.call(method: method)
                await MainActor.run {
                    self.agents = items
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func startCreating() {
        isCreating = true
        editingAgent = AgentProfileFullItem(
            id: UUID().uuidString,
            name: "",
            role: "build",
            provider: "anthropic",
            model: "claude-sonnet-4-6",
            tokenBudget: 200000,
            timeoutMinutes: 30,
            maxConcurrent: 2,
            stations: [],
            configJson: "{}",
            systemPrompt: nil,
            active: true,
            scope: scope.rawValue.lowercased(),
            createdAt: nil,
            updatedAt: nil
        )
    }

    func startEditing(_ agent: AgentProfileFullItem) {
        isCreating = false
        editingAgent = agent
    }

    func cancelEditing() {
        editingAgent = nil
        isCreating = false
    }

    func save(_ agent: AgentProfileFullItem) {
        guard let bus = CommandBus.shared else { return }
        let isNew = isCreating

        struct CreateParams: Encodable {
            let name: String
            let role: String
            let provider: String
            let model: String
            let tokenBudget: Int
            let timeoutMinutes: Int
            let maxConcurrent: Int
            let stations: [String]
            let configJson: String
            let systemPrompt: String?
            let active: Bool
        }
        struct UpdateParams: Encodable {
            let id: String
            let name: String
            let role: String
            let provider: String
            let model: String
            let tokenBudget: Int
            let timeoutMinutes: Int
            let maxConcurrent: Int
            let stations: [String]
            let configJson: String
            let systemPrompt: String?
            let active: Bool
        }

        let createMethod = scope == .global ? "global_agent.create" : "agent_profile.create"
        let updateMethod = scope == .global ? "global_agent.update" : "agent_profile.update"

        Task {
            do {
                if isNew {
                    let _: AgentProfileFullItem = try await bus.call(
                        method: createMethod,
                        params: CreateParams(
                            name: agent.name,
                            role: agent.role,
                            provider: agent.provider,
                            model: agent.model,
                            tokenBudget: agent.tokenBudget,
                            timeoutMinutes: agent.timeoutMinutes,
                            maxConcurrent: agent.maxConcurrent,
                            stations: agent.stations,
                            configJson: agent.configJson,
                            systemPrompt: agent.systemPrompt,
                            active: agent.active
                        )
                    )
                } else {
                    let _: AgentProfileFullItem = try await bus.call(
                        method: updateMethod,
                        params: UpdateParams(
                            id: agent.id,
                            name: agent.name,
                            role: agent.role,
                            provider: agent.provider,
                            model: agent.model,
                            tokenBudget: agent.tokenBudget,
                            timeoutMinutes: agent.timeoutMinutes,
                            maxConcurrent: agent.maxConcurrent,
                            stations: agent.stations,
                            configJson: agent.configJson,
                            systemPrompt: agent.systemPrompt,
                            active: agent.active
                        )
                    )
                }
                await MainActor.run {
                    self.editingAgent = nil
                    self.isCreating = false
                }
                load()
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func delete(_ id: String) {
        guard let bus = CommandBus.shared else { return }
        let method = scope == .global ? "global_agent.delete" : "agent_profile.delete"
        Task {
            do {
                struct Params: Encodable { let id: String }
                let _: OkResponse = try await bus.call(method: method, params: Params(id: id))
                load()
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func copyToProject(_ id: String) {
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                struct Params: Encodable { let id: String }
                let _: CopyResponse = try await bus.call(method: "global_agent.copy_to_project", params: Params(id: id))
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }

    func copyToGlobal(_ id: String) {
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                struct Params: Encodable { let id: String }
                let _: CopyResponse = try await bus.call(method: "agent_profile.copy_to_global", params: Params(id: id))
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - AgentsSection

struct AgentsSection: View {
    @ObservedObject var viewModel: AgentViewModel

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
                    .foregroundColor(.secondary)
                Text("No agent profiles")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("Create an agent profile to configure AI agent behavior.")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
    @ObservedObject var viewModel: AgentViewModel

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
                            .cornerRadius(4)
                    }
                }
                Text("\(agent.provider) / \(agent.model)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let prompt = agent.systemPrompt, !prompt.isEmpty {
                    Text(String(prompt.prefix(80)) + (prompt.count > 80 ? "\u{2026}" : ""))
                        .font(.caption2)
                        .foregroundColor(.secondary)
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
                .foregroundColor(.red)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct RoleBadge: View {
    let role: String

    var color: Color {
        switch role.lowercased() {
        case "build": return .blue
        case "plan": return .purple
        case "review": return .orange
        case "ops": return .green
        case "research": return .cyan
        case "test": return .yellow
        default: return .gray
        }
    }

    var body: some View {
        Text(role)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
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

// MARK: - NSView Wrapper

final class WorkflowPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "workflow"
    let shouldPersist = false
    var title: String { "Agents" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(WorkflowView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
