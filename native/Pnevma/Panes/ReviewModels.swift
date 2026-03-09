import Foundation

// MARK: - Data Models

/// Matches the backend `ReviewPackView` response from `review.get_pack`.
/// The decoder uses `PnevmaJSON.decoder()` which converts snake_case → camelCase with acronym handling.
struct ReviewPack: Decodable {
    let taskID: String
    let status: String          // "Pending" | "Approved" | "Rejected"
    let reviewPackPath: String
    let reviewerNotes: String?
    let approvedAt: String?
    let pack: JSONValue

    var taskId: String { taskID }
}

struct AcceptanceCriterion: Identifiable, Codable {
    var id: String { description }
    let description: String
    var met: Bool
}

struct ReviewTaskItem: Identifiable, Hashable {
    let id: String
    let title: String
    let costUsd: Double?
}

// MARK: - Backend param/response types (internal for ViewModel use)

struct TaskListParams: Encodable {
    let status: String?
}

struct ReviewGetPackParams: Encodable {
    let taskId: String
}

struct ReviewActionParams: Encodable {
    let taskId: String
    let note: String?
}

struct BackendTaskItem: Decodable {
    let id: String
    let title: String
    let status: String
    let priority: String
    let costUsd: Double?
}
