import SwiftUI
import Observation

// MARK: - WorkflowViewModel

@Observable @MainActor
final class WorkflowViewModel {
    var definitions: [WorkflowDefItem] = []
    var instances: [WorkflowInstanceItem] = []
    var selectedDetail: WorkflowInstanceDetail?
    var availableProfiles: [AgentProfileItem] = []
    var isLoading = false
    var error: String?

    // Builder state
    var builderSteps: [WorkflowStepDef] = []
    var builderName: String = ""
    var builderDescription: String = ""
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
                self.definitions = d
                self.instances = loadedInsts
                self.availableProfiles = p
                self.isLoading = false
            } catch {
                self.error = error.localizedDescription
                self.isLoading = false
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
                self.selectedDetail = detail
            } catch {
                self.error = error.localizedDescription
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
                self.error = error.localizedDescription
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
                self.error = nil
                completion()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func saveAndRun(completion: @escaping () -> Void) {
        save { [weak self] in
            self?.instantiate(self?.builderName ?? "")
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
                self.error = error.localizedDescription
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
        s.replacing("\\", with: "\\\\")
         .replacing("\"", with: "\\\"")
         .replacing("\n", with: "\\n")
         .replacing("\r", with: "\\r")
         .replacing("\t", with: "\\t")
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
            case "acceptance_criteria": currentStep?.acceptanceCriteria = collectedItems
            case "constraints": currentStep?.constraints = collectedItems
            case "scope": currentStep?.scope = collectedItems
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
            case "title": currentStep?.title = unquote(value)
            case "goal": currentStep?.goal = unquote(value)
            case "agent_profile": currentStep?.agentProfile = unquote(value)
            case "execution_mode": currentStep?.executionMode = unquote(value)
            case "priority": currentStep?.priority = unquote(value)
            case "auto_dispatch": currentStep?.autoDispatch = (value == "true")
            case "depends_on":
                if let arr = parseInlineArray(value) {
                    currentStep?.dependsOn = arr.compactMap { Int($0) }
                }
            case "timeout_minutes": currentStep?.timeoutMinutes = Int(value)
            case "max_retries": currentStep?.maxRetries = Int(value)
            case "on_failure":
                switch unquote(value).lowercased() {
                case "retryonce", "retry_once": currentStep?.onFailure = "RetryOnce"
                case "skip": currentStep?.onFailure = "Skip"
                default: currentStep?.onFailure = "Pause"
                }
            case "scope":
                if let arr = parseInlineArray(value) {
                    currentStep?.scope = arr
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
                    collectingKey = "loop"
                    currentStep?.loopConfig = LoopConfig(target: 0, maxIterations: 5)
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
                    case "target": currentStep?.loopConfig?.target = Int(value) ?? 0
                    case "max_iterations": currentStep?.loopConfig?.maxIterations = Int(value) ?? 5
                    case "mode": currentStep?.loopConfig?.mode = LoopMode(rawValue: value) ?? .onFailure
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

@Observable @MainActor
final class AgentViewModel {
    var agents: [AgentProfileFullItem] = []
    var isLoading = false
    var error: String?
    var editingAgent: AgentProfileFullItem?
    var isCreating = false
    var scope: OrchestrationScope = .global

    func load() {
        guard let bus = CommandBus.shared else { return }
        isLoading = true
        error = nil
        let method = scope == .global ? "global_agent.list" : "agent_profile.list"
        Task {
            do {
                let items: [AgentProfileFullItem] = try await bus.call(method: method)
                self.agents = items
                self.isLoading = false
            } catch {
                self.error = error.localizedDescription
                self.isLoading = false
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
                self.editingAgent = nil
                self.isCreating = false
                load()
            } catch {
                self.error = error.localizedDescription
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
                self.error = error.localizedDescription
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
                self.error = error.localizedDescription
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
                self.error = error.localizedDescription
            }
        }
    }
}
