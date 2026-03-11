import SwiftUI
import Observation
import Cocoa

struct NotificationsView: View {
    @State private var viewModel: NotificationsViewModel
    @State private var showClearAllAlert = false
    @Environment(GhosttyThemeProvider.self) var theme

    @MainActor
    init(viewModel: NotificationsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    @MainActor
    init() {
        _viewModel = State(initialValue: NotificationsViewModel.shared)
    }

    var body: some View {
        @Bindable var viewModel = viewModel
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
                    .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Clear") { showClearAllAlert = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear all notifications")
            }
            .padding(12)

            Divider()

            if let statusMessage = viewModel.statusMessage {
                VStack(spacing: 10) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text(statusMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)
                Spacer()
            } else if viewModel.filteredNotifications.isEmpty {
                EmptyStateView(icon: "bell.slash", title: "No Notifications", message: "You're all caught up")
            } else {
                List(viewModel.filteredNotifications) { notification in
                    NotificationRow(notification: notification)
                        .accessibilityAddTraits(.isButton)
                        .onTapGesture { viewModel.markRead(notification.id) }
                }
                .listStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) { ErrorBanner(message: viewModel.actionError) }
        .alert("Clear All Notifications?", isPresented: $showClearAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { viewModel.clearAll() }
        } message: {
            Text("This will remove all notifications.")
        }
        .task { await viewModel.activate() }
        .accessibilityIdentifier("pane.notifications")
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
                .accessibilityLabel("\(notification.level) notification")

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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let sessionID = notification.sessionID {
                    Label("Session: \(sessionID.prefix(8))", systemImage: "terminal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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

final class NotificationsPaneView: NSView, PaneContent {
    let paneID = PaneID()
    let paneType = "notifications"
    let shouldPersist = true
    var title: String { "Notifications" }

    override init(frame: NSRect) {
        super.init(frame: frame)
        _ = addSwiftUISubview(NotificationsView())
    }

    required init?(coder: NSCoder) { fatalError() }
}
