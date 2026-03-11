import SwiftUI

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

struct WorkflowStepDef: Identifiable, Codable {
    var id: UUID = UUID()
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

    enum CodingKeys: String, CodingKey {
        case title, goal, scope, priority, dependsOn, autoDispatch
        case agentProfile, executionMode, timeoutMinutes, maxRetries
        case acceptanceCriteria, constraints, onFailure, loopConfig
    }
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
    let source: String?
    let sourcePath: String?
    let userModified: Bool?

    var displayName: String {
        "\(name) (\(provider) / \(model))"
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
    let source: String?
    let sourcePath: String?
    let userModified: Bool?
}

enum OrchestrationScope: String, CaseIterable {
    case global = "Global"
    case project = "Project"
}
