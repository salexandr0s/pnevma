import SwiftUI
import Cocoa

// MARK: - Data Models

struct NotificationItem: Identifiable, Codable {
    let id: String
    let level: String  // info, warning, error, success
    let title: String
    let body: String?
    let timestamp: String
    var isRead: Bool
    let sourcePaneType: String?
}

// MARK: - NotificationsView

struct NotificationsView: View {
    @StateObject private var viewModel = NotificationsViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // Header with actions
            HStack {
                Text("Notifications")
                    .font(.headline)
                Spacer()

                Picker("Filter", selection: $viewModel.filter) {
                    Text("All").tag(NotificationsViewModel.Filter.all)
                    Text("Unread").tag(NotificationsViewModel.Filter.unread)
                    Text("Errors").tag(NotificationsViewModel.Filter.errors)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)

                Button("Mark All Read") { viewModel.markAllRead() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)

                Button("Clear") { viewModel.clearAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            // Notification list
            if viewModel.filteredNotifications.isEmpty {
                Spacer()
                Text("No notifications")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(viewModel.filteredNotifications) { notification in
                    NotificationRow(notification: notification)
                        .onTapGesture { viewModel.markRead(notification.id) }
                }
                .listStyle(.plain)
            }
        }
        .onAppear { viewModel.load() }
    }
}

// MARK: - NotificationRow

struct NotificationRow: View {
    let notification: NotificationItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Unread indicator
            Circle()
                .fill(notification.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

            // Level icon
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.title)
                    .font(.body)
                    .fontWeight(notification.isRead ? .regular : .semibold)
                if let body = notification.body {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(notification.timestamp)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch notification.level {
        case "error": return "exclamationmark.circle.fill"
        case "warning": return "exclamationmark.triangle.fill"
        case "success": return "checkmark.circle.fill"
        default: return "info.circle.fill"
        }
    }

    private var iconColor: Color {
        switch notification.level {
        case "error": return .red
        case "warning": return .orange
        case "success": return .green
        default: return .blue
        }
    }
}

// MARK: - ViewModel

final class NotificationsViewModel: ObservableObject {
    enum Filter: String { case all, unread, errors }

    @Published var notifications: [NotificationItem] = []
    @Published var filter: Filter = .all

    var filteredNotifications: [NotificationItem] {
        switch filter {
        case .all: return notifications
        case .unread: return notifications.filter { !$0.isRead }
        case .errors: return notifications.filter { $0.level == "error" }
        }
    }

    func load() {
        // pnevma_call("notification.list", "{}")
    }

    func markRead(_ id: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            notifications[idx].isRead = true
        }
    }

    func markAllRead() {
        for i in notifications.indices { notifications[i].isRead = true }
    }

    func clearAll() {
        notifications.removeAll()
    }
}

// MARK: - NSView Wrapper

final class NotificationsPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "notifications"
    var title: String { "Notifications" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(NotificationsView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
