import SwiftUI

struct SessionManagerView: View {
    var store: SessionStore
    var onNewSession: (() -> Void)?
    @State private var showKillAllAlert = false
    @Environment(GhosttyThemeProvider.self) var theme

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.headline)
                Spacer()

                Text("\(store.activeCount) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    onNewSession?()
                } label: {
                    Text("New")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(onNewSession == nil || !store.hasActiveProject)
                .accessibilityLabel("New session")

                Button {
                    showKillAllAlert = true
                } label: {
                    Text("Kill All")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(store.activeCount == 0)
                .accessibilityLabel("Kill all sessions")

                Button {
                    store.refresh()
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                        .font(.caption)
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh sessions")
            }
            .padding(12)

            Divider()

            Group {
                switch store.availability {
                case .loading(let message) where store.sessions.isEmpty:
                    SessionManagerEmptyState(
                        icon: "hourglass",
                        title: message
                    )
                case .failed(let message) where store.sessions.isEmpty:
                    SessionManagerEmptyState(
                        icon: "exclamationmark.triangle",
                        title: message,
                        actionTitle: "Retry",
                        action: { store.refresh() }
                    )
                case .noProject(let message):
                    SessionManagerEmptyState(
                        icon: "folder.badge.questionmark",
                        title: message
                    )
                default:
                    if store.sessions.isEmpty {
                        ContentUnavailableView(
                            "No Sessions",
                            systemImage: "terminal",
                            description: Text("No active terminal sessions")
                        )
                    } else {
                        List {
                            ForEach(store.sessions) { session in
                                SessionRow(session: session) {
                                    store.kill(sessionID: session.id)
                                }
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 380, height: 320)
        .overlay(alignment: .bottom) { ErrorBanner(message: store.actionError) }
        .alert("Kill All Sessions?", isPresented: $showKillAllAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Kill All", role: .destructive) { store.killAll() }
        } message: {
            Text("This will terminate all active sessions.")
        }
        .task { await store.activate() }
    }
}

private struct SessionManagerEmptyState: View {
    let icon: String
    let title: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: String,
        title: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct SessionRow: View {
    let session: LiveSession
    let onKill: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .font(.system(size: 10))
                .foregroundStyle(statusColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(session.shortCwd)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let pid = session.pid {
                Text("PID \(pid)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            if session.isActionable {
                Button {
                    onKill()
                } label: {
                    Label("Kill Session", systemImage: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .labelStyle(.iconOnly)
                        .foregroundStyle(isHovering ? .red : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .accessibilityLabel("Kill session")
            } else {
                Text(session.statusDisplayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch session.status {
        case "running":
            return "circle.fill"
        case "waiting":
            return "clock.fill"
        case "error":
            return "exclamationmark.triangle.fill"
        case "complete":
            return "checkmark.circle.fill"
        default:
            return "questionmark.circle"
        }
    }

    private var statusColor: Color {
        switch session.status {
        case "running":
            return .green
        case "waiting":
            return .yellow
        case "error":
            return .red
        case "complete":
            return .secondary
        default:
            return .secondary
        }
    }
}

struct SessionManagerPopoverView: View {
    var store: SessionStore
    var onNewSession: (() -> Void)?

    var body: some View {
        SessionManagerView(store: store, onNewSession: onNewSession)
    }
}
