import SwiftUI
import Observation

// MARK: - ViewModel

@Observable @MainActor
final class NotificationsViewModel {
    /// Shared instance used by both the popover and the full notifications pane.
    static let shared = NotificationsViewModel()

    private enum ViewState: Equatable {
        case waiting(String)
        case loading(String)
        case ready
        case failed(String)
    }

    enum Filter: String { case all, unread, errors }

    var notifications: [NotificationItem] = []
    var filter: Filter = .all
    var actionError: String?
    private var viewState: ViewState = .waiting("Open a project to load notifications.")
    private var isMarkingAllRead = false

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let bridgeEventHub: BridgeEventHub
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
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

    func activate() async {
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
                        sourcePaneType: nil,
                        sessionID: $0.sessionID,
                        taskID: $0.taskID
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
