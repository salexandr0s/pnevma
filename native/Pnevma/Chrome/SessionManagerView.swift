import SwiftUI

struct SessionManagerView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var theme = GhosttyThemeProvider.shared

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
                    store.killAll()
                } label: {
                    Text("Kill All")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .disabled(store.activeCount == 0)

                Button {
                    store.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
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
                        SessionManagerEmptyState(
                            icon: "terminal",
                            title: "No sessions"
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
        .overlay(alignment: .bottom) {
            if let error = store.actionError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: theme.backgroundColor))
            }
        }
        .onAppear { store.activate() }
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
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(session.shortCwd)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if let pid = session.pid {
                Text("PID \(pid)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if session.isActionable {
                Button {
                    onKill()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(isHovering ? .red : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
            } else {
                Text(session.statusDisplayName)
                    .font(.system(size: 10))
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
    @ObservedObject var store: SessionStore

    var body: some View {
        SessionManagerView(store: store)
    }
}
