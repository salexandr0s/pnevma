import SwiftUI

// MARK: - Data Models

struct DailyBrief: Decodable {
    let generatedAt: String
    let totalTasks: Int
    let readyTasks: Int
    let reviewTasks: Int
    let blockedTasks: Int
    let failedTasks: Int
    let totalCostUsd: Double
    let recentEvents: [BriefEvent]
    let recommendedActions: [String]
    let activeSessions: Int
    let costLast24hUsd: Double
    let tasksCompletedLast24h: Int
    let tasksFailedLast24h: Int
    let staleReadyCount: Int
    let longestRunningTask: String?
    let topCostTasks: [TopCostTask]
}

struct BriefEvent: Identifiable, Decodable {
    let timestamp: String
    let kind: String
    let summary: String
    let payload: JSONValue

    var id: String { "\(timestamp)-\(kind)-\(summary)" }

    var level: EventLevel {
        switch kind {
        case "TaskFailed":        return .error
        case "TaskBlocked":       return .warning
        case "TaskCompleted":     return .success
        case "TaskDispatched",
             "TaskStarted":       return .info
        default:                  return .info
        }
    }

    enum EventLevel {
        case error, warning, success, info

        var color: Color {
            switch self {
            case .error:   return .red
            case .warning: return .orange
            case .success: return .green
            case .info:    return .blue
            }
        }
    }
}

struct TopCostTask: Decodable, Identifiable {
    let taskID: String
    let title: String
    let costUsd: Double

    var id: String { taskID }
    var taskId: String { taskID }
}
