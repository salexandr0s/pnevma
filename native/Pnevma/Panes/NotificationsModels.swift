import Foundation

// MARK: - Data Models

struct NotificationItem: Identifiable {
    let id: String
    let level: String
    let title: String
    let body: String?
    let timestamp: String
    var isRead: Bool
    let sourcePaneType: String?
}

// MARK: - Backend param/response types (internal for ViewModel use)

struct BackendNotificationItem: Identifiable, Decodable {
    let id: String
    let level: String
    let title: String
    let body: String
    let unread: Bool
    let createdAt: String
    let taskID: String?
    let sessionID: String?
}

struct NotificationListParams: Encodable {
    let unreadOnly: Bool
}

struct NotificationMarkReadParams: Encodable {
    let notificationID: String
}
