import SwiftUI

// MARK: - Data Models

struct TaskItem: Identifiable, Equatable {
    let id: String
    var title: String
    var goal: String
    var status: TaskStatus
    var priority: TaskPriority
    var scope: [String]
    var acceptanceCriteria: [String]
    var dependencies: [String]
    var branch: String?
    var worktreeID: String?
    var queuedPosition: Int?
    var cost: Double?
    var executionMode: String?
    var updatedAt: Date
}

enum TaskStatus: String, CaseIterable, Hashable {
    case planned = "Planned"
    case ready = "Ready"
    case inProgress = "InProgress"
    case review = "Review"
    case done = "Done"
    case failed = "Failed"
    case blocked = "Blocked"

    var displayName: String {
        switch self {
        case .planned: return "Planned"
        case .ready: return "Ready"
        case .inProgress: return "In Progress"
        case .review: return "Review"
        case .done: return "Done"
        case .failed: return "Failed"
        case .blocked: return "Blocked"
        }
    }

    var symbolName: String {
        switch self {
        case .planned: return "calendar"
        case .ready: return "checkmark.circle"
        case .inProgress: return "bolt"
        case .review: return "doc.text.magnifyingglass"
        case .done: return "checkmark.seal"
        case .failed: return "exclamationmark.triangle"
        case .blocked: return "lock"
        }
    }

    var tint: Color {
        switch self {
        case .planned: return Color(nsColor: .systemBlue)
        case .ready: return Color(nsColor: .systemMint)
        case .inProgress: return Color(nsColor: .systemOrange)
        case .review: return Color(nsColor: .systemYellow)
        case .done: return Color(nsColor: .systemGreen)
        case .failed: return Color(nsColor: .systemRed)
        case .blocked: return Color(nsColor: .systemGray)
        }
    }
}

enum TaskPriority: String, CaseIterable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"

    var color: Color {
        switch self {
        case .p0: return Color(nsColor: .systemRed)
        case .p1: return Color(nsColor: .systemOrange)
        case .p2: return Color(nsColor: .systemBlue)
        case .p3: return Color(nsColor: .systemGray)
        }
    }

    var sortRank: Int {
        switch self {
        case .p0: return 0
        case .p1: return 1
        case .p2: return 2
        case .p3: return 3
        }
    }
}

struct TaskCreationDraft {
    var title = ""
    var goal = ""
    var priority: TaskPriority = .p1
    var scopeText = ""
    var acceptanceCriteriaText = ""
    var constraintsText = ""
    var selectedDependencyIDs = Set<String>()

    mutating func reset() {
        self = TaskCreationDraft()
    }

    var scopeEntries: [String] {
        Self.parseLines(scopeText)
    }

    var acceptanceCriteriaEntries: [String] {
        Self.parseLines(acceptanceCriteriaText)
    }

    var constraintEntries: [String] {
        Self.parseLines(constraintsText)
    }

    var validationMessage: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Title is required."
        }
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Goal is required."
        }
        return nil
    }

    private static func parseLines(_ text: String) -> [String] {
        text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Backend param/response types (internal for ViewModel use)

struct BackendCheck: Decodable {
    let description: String
}

struct BackendTask: Decodable {
    let id: String
    let title: String
    let goal: String
    let status: String
    let priority: String
    let scope: [String]
    let dependencies: [String]
    let acceptanceCriteria: [BackendCheck]
    let branch: String?
    let worktreeID: String?
    let queuedPosition: Int?
    let costUsd: Double?
    let executionMode: String?
    let updatedAt: Date
}

struct UpdateTaskParams: Encodable {
    let taskID: String
    let status: String
}

struct CreateTaskParams: Encodable {
    let title: String
    let goal: String
    let scope: [String]
    let acceptanceCriteria: [String]
    let constraints: [String]
    let dependencies: [String]
    let priority: String
}

struct TaskCreateResponse: Decodable {
    let taskID: String
}

struct TaskBoardError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
