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
    @ObservedObject private var theme = GhosttyThemeProvider.shared

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
                .accessibilityLabel("Filter notifications")

                Button("Mark All Read") { viewModel.markAllRead() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityLabel("Mark all notifications as read")

                Button("Clear") { viewModel.clearAll() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear all notifications")
            }
            .padding(12)

            Divider()

            if let statusMessage = viewModel.statusMessage {
                EmptyStateView(
                    icon: "bell.badge",
                    title: statusMessage
                )
            } else if viewModel.filteredNotifications.isEmpty {
                EmptyStateView(
                    icon: "bell.slash",
                    title: "No notifications",
                    message: "You're all caught up"
                )
            } else {
                List(viewModel.filteredNotifications) { notification in
                    NotificationRow(notification: notification)
                        .onTapGesture { viewModel.markRead(notification.id) }
                }
                .listStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) {
            if let error = viewModel.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: theme.backgroundColor))
            }
        }
        .onAppear { viewModel.activate() }
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

            Image(systemName: icon.name)
                .foregroundStyle(icon.color)
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
        .accessibilityElement(children: .combine)
    }

    private var icon: (name: String, color: Color) {
        switch notification.level {
        case "error": return ("exclamationmark.circle.fill", .red)
        case "warning": return ("exclamationmark.triangle.fill", .orange)
        case "success": return ("checkmark.circle.fill", .green)
        default: return ("info.circle.fill", .blue)
        }
    }
}

@MainActor
final class NotificationsViewModel: ObservableObject {
    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    enum Filter: String { case all, unread, errors }

    @Published var notifications: [NotificationItem] = []
    @Published var filter: Filter = .all
    @Published var actionError: String?
    @Published private var viewState: ViewState = .waiting("Open a project to load notifications.")
    private var isMarkingAllRead = false

    private let commandBus: (any CommandCalling)?
    private let bridgeEventHub: BridgeEventHub
    private let activationHub: ActiveWorkspaceActivationHub
    private var bridgeObserverID: UUID?
    private var activationObserverID: UUID?

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        bridgeEventHub: BridgeEventHub = .shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.bridgeEventHub = bridgeEventHub
        self.activationHub = activationHub

        bridgeObserverID = bridgeEventHub.addObserver { [weak self] event in
            switch event.name {
            case "notification_created", "notification_cleared", "notification_updated":
                Task { @MainActor [weak self] in
                    self?.refreshIfActive()
                }
            default:
                break
            }
        }
        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
        if let bridgeObserverID {
            bridgeEventHub.removeObserver(bridgeObserverID)
        }
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
    }

    var statusMessage: String? {
        switch viewState {
        case .waiting(let message), .loading(let message), .failed(let message):
            return message
        case .ready:
            return nil
        }
    }

    func activate() {
        handleActivationState(activationHub.currentState)
    }

    var filteredNotifications: [NotificationItem] {
        switch filter {
        case .all: return notifications
        case .unread: return notifications.filter { !$0.isRead }
        case .errors: return notifications.filter { $0.level == "error" }
        }
    }

    func load() {
        guard let bus = commandBus else {
            viewState = .failed("Notification loading is unavailable because the command bus is not configured.")
            return
        }
        if notifications.isEmpty {
            viewState = .loading("Loading notifications...")
        }
        Task { [weak self] in
            guard let self else { return }
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
                self.finishLoading(mapped)
            } catch {
                self.handleLoadFailure(error)
            }
        }
    }

    func markRead(_ id: String) {
        if let idx = notifications.firstIndex(where: { $0.id == id }) {
            notifications[idx].isRead = true
        }
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await bus.call(
                    method: "notification.mark_read",
                    params: NotificationMarkReadParams(notificationID: id)
                )
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
                self.refreshAfterMutation()
            }
        }
    }

    func markAllRead() {
        guard !isMarkingAllRead else { return }
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        isMarkingAllRead = true
        // Optimistic batch flip
        for i in notifications.indices where !notifications[i].isRead {
            notifications[i].isRead = true
        }
        Task { [weak self] in
            guard let self else { return }
            defer { self.isMarkingAllRead = false }
            var hadError = false
            for notification in self.notifications {
                do {
                    let _: OkResponse = try await bus.call(
                        method: "notification.mark_read",
                        params: NotificationMarkReadParams(notificationID: notification.id)
                    )
                } catch {
                    if !hadError {
                        hadError = true
                        self.actionError = error.localizedDescription
                        self.scheduleDismissActionError()
                    }
                }
            }
            if hadError {
                self.refreshAfterMutation()
            }
        }
    }

    func clearAll() {
        notifications.removeAll()
        guard let bus = commandBus else {
            actionError = "Backend connection unavailable"
            scheduleDismissActionError()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let _: OkResponse = try await bus.call(method: "notification.clear", params: nil)
            } catch {
                self.actionError = error.localizedDescription
                self.scheduleDismissActionError()
                self.refreshAfterMutation()
            }
        }
    }

    private func scheduleDismissActionError() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.actionError = nil
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle:
            viewState = .waiting("Waiting for project activation...")
        case .opening:
            viewState = .waiting("Waiting for project activation...")
        case .open:
            load()
        case .failed(_, _, let message):
            viewState = .failed(message)
        case .closed:
            viewState = .waiting("Open a project to load notifications.")
        }
    }

    private func refreshIfActive() {
        guard activationHub.currentState.isOpen else { return }
        load()
    }

    private func finishLoading(_ items: [NotificationItem]) {
        notifications = items
        viewState = .ready
    }

    private func handleLoadFailure(_ error: Error) {
        if PnevmaError.isProjectNotReady(error) {
            viewState = .waiting("Waiting for project activation...")
            return
        }
        viewState = .failed(error.localizedDescription)
    }

    private func refreshAfterMutation() {
        guard activationHub.currentState.isOpen else { return }
        load()
    }
}

final class NotificationsPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "notifications"
    let shouldPersist = false
    var title: String { "Notifications" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(NotificationsView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
