import SwiftUI

struct SessionManagerView: View {
    var store: SessionStore
    var onNewSession: (() -> Void)?
    @State private var showKillAllAlert = false

    var body: some View {
        ToolbarAttachmentScaffold(title: "Sessions") {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("\(store.activeCount) active")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button("New") {
                    onNewSession?()
                }
                .buttonStyle(.plain)
                .disabled(onNewSession == nil || !store.hasActiveProject)
                .accessibilityLabel("New session")

                Button("Kill All") {
                    showKillAllAlert = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .disabled(store.activeCount == 0)
                .accessibilityLabel("Kill all sessions")

                Button {
                    store.refresh()
                } label: {
                    Label("Refresh Sessions", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh sessions")
            }
        } content: {
            Group {
                switch store.availability {
                case .loading(let message) where store.sessions.isEmpty:
                    EmptyStateView(icon: "hourglass", title: message)
                case .failed(let message) where store.sessions.isEmpty:
                    EmptyStateView(
                        icon: "exclamationmark.triangle",
                        title: message,
                        actionTitle: "Retry",
                        action: { store.refresh() }
                    )
                case .noProject(let message):
                    EmptyStateView(icon: "folder.badge.questionmark", title: message)
                default:
                    if store.sessions.isEmpty {
                        EmptyStateView(
                            icon: "terminal",
                            title: "No Sessions",
                            message: "No active terminal sessions"
                        )
                    } else {
                        NativeCollectionShell(surface: .pane) {
                            List {
                                ForEach(store.sessions) { session in
                                    SessionRow(session: session) {
                                        store.kill(sessionID: session.id)
                                    }
                                }
                            }
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                        }
                    }
                }
            }
        }
        .frame(width: 400, height: 320)
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
