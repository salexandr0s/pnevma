import SwiftUI
import Cocoa

// MARK: - Data Models

struct WorkflowDefItem: Identifiable, Codable {
    var id: String? { dbId ?? name }
    let dbId: String?
    let name: String
    let description: String?
    let source: String
    let steps: [WorkflowStepDef]

    enum CodingKeys: String, CodingKey {
        case dbId = "id"
        case name, description, source, steps
    }
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
}

struct WorkflowInstanceItem: Identifiable, Codable {
    let id: String
    let workflowName: String
    let description: String?
    let status: String
    let taskIds: [String]
    let createdAt: String
    let updatedAt: String
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
    var id: String { taskId }
    let stepIndex: Int
    let taskId: String
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

    var statusColor: Color {
        switch status.lowercased() {
        case "completed", "done": return .green
        case "inprogress", "in_progress", "running": return .blue
        case "failed": return .red
        case "blocked": return .orange
        case "ready": return .cyan
        default: return .secondary
        }
    }
}

struct AgentProfileItem: Identifiable, Codable {
    let id: String
    let name: String
    let provider: String
    let model: String
    let timeoutMinutes: Int
    let maxConcurrent: Int

    var displayName: String {
        "\(name) (\(provider) / \(model))"
    }
}

// MARK: - Main View

struct WorkflowView: View {
    @StateObject private var viewModel = WorkflowViewModel()
    @State private var selectedTab: Tab = .library

    enum Tab: String, CaseIterable {
        case library = "Library"
        case active = "Active"
        case builder = "Builder"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Workflows")
                    .font(.headline)
                Spacer()
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                if selectedTab == .library {
                    Button(action: { selectedTab = .builder; viewModel.resetBuilder() }) {
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
            }
        }
        .onAppear { viewModel.load() }
    }
}

// MARK: - Library Section

struct LibrarySection: View {
    @ObservedObject var viewModel: WorkflowViewModel
    var onEdit: (WorkflowDefItem) -> Void

    var body: some View {
        if viewModel.definitions.isEmpty {
            Spacer()
            Text("No workflows defined")
                .foregroundStyle(.secondary)
            Text("Create one with the + button")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
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
                        Text("\(def.steps.count) steps")
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
            Spacer()
            Text("No active workflow instances")
                .foregroundStyle(.secondary)
            Spacer()
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(detail.workflowName).font(.title3.bold())
                Spacer()
                StatusBadge(status: detail.status)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(layers, id: \.0) { _, layerSteps in
                        HStack(spacing: 16) {
                            ForEach(layerSteps) { step in
                                InstanceStepNode(step: step)
                            }
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
        while changed {
            changed = false
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
        VStack(spacing: 4) {
            Circle()
                .fill(step.statusColor)
                .frame(width: 24, height: 24)
                .overlay {
                    statusIcon
                        .font(.caption2)
                        .foregroundStyle(.white)
                }

            Text(step.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            if let profile = step.agentProfile {
                Text(profile)
                    .font(.caption2)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
            }

            Image(systemName: step.executionMode == "main" ? "house.fill" : "arrow.triangle.branch")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 100)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(step.statusColor.opacity(0.3), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status.lowercased() {
        case "completed", "done": Image(systemName: "checkmark")
        case "inprogress", "in_progress", "running": Image(systemName: "play.fill")
        case "failed": Image(systemName: "xmark")
        case "blocked": Image(systemName: "lock.fill")
        case "ready": Image(systemName: "bolt.fill")
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
                Divider()
                MiniDagPreview(steps: viewModel.builderSteps)
                    .frame(height: 120)
            }

            Divider()
            // Actions
            HStack {
                Button("Cancel") {
                    viewModel.resetBuilder()
                    onSaved()
                }
                Spacer()
                if let err = viewModel.error {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
                Button("Save") {
                    if mode == .source {
                        _ = viewModel.parseFromYAML(yamlText)
                    }
                    viewModel.save { onSaved() }
                }
                .buttonStyle(.bordered)
                Button("Run") {
                    if mode == .source {
                        _ = viewModel.parseFromYAML(yamlText)
                    }
                    viewModel.saveAndRun { onRun() }
                }
                .buttonStyle(.borderedProminent)
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
        ScrollView(.horizontal) {
            HStack(spacing: 16) {
                ForEach(layers, id: \.0) { _, layerSteps in
                    VStack(spacing: 8) {
                        ForEach(layerSteps, id: \.offset) { idx, step in
                            VStack(spacing: 2) {
                                Circle()
                                    .fill(Color.blue.opacity(0.5))
                                    .frame(width: 16, height: 16)
                                Text(step.title.isEmpty ? "Step \(idx + 1)" : step.title)
                                    .font(.caption2)
                                    .lineLimit(1)
                                if let profile = step.agentProfile {
                                    Text(profile)
                                        .font(.system(size: 8))
                                        .foregroundStyle(.purple)
                                }
                            }
                            .frame(width: 70)
                        }
                    }
                }
            }
            .padding(8)
        }
    }

    private var layers: [(Int, [(offset: Int, element: WorkflowStepDef)])] {
        var depths: [Int: Int] = [:]
        for (i, step) in steps.enumerated() where step.dependsOn.isEmpty {
            depths[i] = 0
        }
        var changed = true
        while changed {
            changed = false
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

    func load() {
        guard let bus = CommandBus.shared else { return }
        isLoading = true
        Task {
            do {
                async let defs: [WorkflowDefItem] = bus.call(method: "workflow.list_defs")
                async let insts: [WorkflowInstanceItem] = bus.call(method: "workflow.list_instances")
                async let profiles: [AgentProfileItem] = bus.call(method: "agent_profile.list")
                let (d, i, p) = try await (defs, insts, profiles)
                await MainActor.run {
                    self.definitions = d
                    self.instances = i
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
        guard let bus = CommandBus.shared else { return }
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
        guard let bus = CommandBus.shared else { return }
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
        guard let bus = CommandBus.shared else { return }
        let yaml = serializeToYAML()
        Task {
            do {
                if let existingId = editingWorkflowId {
                    struct Params: Encodable { let id: String; let name: String?; let description: String?; let definitionYaml: String? }
                    let _: WorkflowDefItem = try await bus.call(
                        method: "workflow.update",
                        params: Params(id: existingId, name: builderName, description: builderDescription.isEmpty ? nil : builderDescription, definitionYaml: yaml)
                    )
                } else {
                    struct Params: Encodable { let name: String; let description: String?; let definitionYaml: String }
                    let _: WorkflowDefItem = try await bus.call(
                        method: "workflow.create",
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
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                struct Params: Encodable { let id: String }
                let _: [String: Bool] = try await bus.call(method: "workflow.delete", params: Params(id: id))
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
        builderSteps = def.steps
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

    func serializeToYAML() -> String {
        var lines: [String] = []
        lines.append("name: \"\(builderName)\"")
        if !builderDescription.isEmpty {
            lines.append("description: \"\(builderDescription)\"")
        }
        lines.append("steps:")
        for step in builderSteps {
            lines.append("  - title: \"\(step.title)\"")
            lines.append("    goal: \"\(step.goal)\"")
            if let profile = step.agentProfile {
                lines.append("    agent_profile: \"\(profile)\"")
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
                lines.append("    scope: [\(step.scope.map { "\"\($0)\"" }.joined(separator: ", "))]")
            }
            if !step.acceptanceCriteria.isEmpty {
                lines.append("    acceptance_criteria:")
                for c in step.acceptanceCriteria {
                    lines.append("      - \"\(c)\"")
                }
            }
            if !step.constraints.isEmpty {
                lines.append("    constraints:")
                for c in step.constraints {
                    lines.append("      - \"\(c)\"")
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
            default: break
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let indent = line.prefix(while: { $0 == " " }).count

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

// MARK: - NSView Wrapper

final class WorkflowPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "workflow"
    var title: String { "Workflow" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(WorkflowView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
