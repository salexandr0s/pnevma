import SwiftUI
import Cocoa

private struct BackendNotificationItem: Identifiable, Decodable {
    let id: String
    let level: String
    let title: String
    let body: String
    let unread: Bool
    let createdAt: String
    let taskID: String?
    let sessionID: String?
}

private struct NotificationListParams: Encodable {
    let unreadOnly: Bool
}

private struct NotificationMarkReadParams: Encodable {
    let notificationID: String
}

struct NotificationItem: Identifiable {
    let id: String
    let level: String
    let title: String
    let body: String?
    let timestamp: String
    var isRead: Bool
    let sourcePaneType: String?
}

struct NotificationsView: View {
    @StateObject private var viewModel = NotificationsViewModel()

    var body: some View {
        VStack(spacing: 0) {
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

struct NotificationRow: View {
    let notification: NotificationItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(notification.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)

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

final class NotificationsViewModel: ObservableObject {
    enum Filter: String { case all, unread, errors }

    @Published var notifications: [NotificationItem] = []
    @Published var filter: Filter = .all

    private var bridgeObserverID: UUID?

    init() {
        bridgeObserverID = BridgeEventHub.shared.addObserver { [weak self] event in
            switch event.name {
            case "notification_created", "notification_cleared", "notification_updated":
                self?.load()
            default:
                break
            }
        }
    }

    deinit {
        if let bridgeObserverID {
            BridgeEventHub.shared.removeObserver(bridgeObserverID)
        }
    }

    var filteredNotifications: [NotificationItem] {
        switch filter {
        case .all: return notifications
        case .unread: return notifications.filter { !$0.isRead }
        case .errors: return notifications.filter { $0.level == "error" }
        }
    }

    func load() {
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                let items: [BackendNotificationItem] = try await bus.call(
                    method: "notification.list",
                    params: NotificationListParams(unreadOnly: false)
                )
                let mapped = items.map {
                    NotificationItem(
                        id: $0.id,
                        level: $0.level,
                        title: $0.title,
                        body: $0.body,
                        timestamp: $0.createdAt,
                        isRead: !$0.unread,
                        sourcePaneType: nil
                    )
                }
                await MainActor.run {
                    self.notifications = mapped
                }
            } catch {
                // Preserve the existing list when refresh fails.
            }
        }
    }

    func markRead(_ id: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            notifications[idx].isRead = true
        }
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                let _: OkResponse = try await bus.call(
                    method: "notification.mark_read",
                    params: NotificationMarkReadParams(notificationID: id)
                )
            } catch {
                load()
            }
        }
    }

    func markAllRead() {
        for notification in notifications where !notification.isRead {
            markRead(notification.id)
        }
    }

    func clearAll() {
        notifications.removeAll()
        guard let bus = CommandBus.shared else { return }
        Task {
            do {
                let _: OkResponse = try await bus.call(method: "notification.clear")
            } catch {
                load()
            }
        }
    }
}

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
