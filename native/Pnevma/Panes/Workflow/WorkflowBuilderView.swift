import SwiftUI

// MARK: - Builder Section

struct BuilderSection: View {
    @Bindable var viewModel: WorkflowViewModel
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
    @Bindable var viewModel: WorkflowViewModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(Array(viewModel.builderSteps.enumerated()), id: \.element.id) { idx, _ in
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
                                .foregroundStyle(.secondary)
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
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Pipeline Preview")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            ScrollView(.horizontal) {
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
            .scrollIndicators(.hidden)
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
                .font(.caption2.weight(.medium))
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
