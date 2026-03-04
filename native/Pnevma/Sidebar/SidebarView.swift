import SwiftUI

/// SwiftUI sidebar listing workspaces, projects, and quick actions.
/// Embedded in the main window via NSHostingView + NSVisualEffectView.
struct SidebarView: View {
    @ObservedObject var workspaceManager: WorkspaceManager

    /// Called when the user wants to open a new project.
    var onOpenProject: (() -> Void)?
    /// Called when the user wants to open settings.
    var onOpenSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Workspace tabs
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(workspaceManager.workspaces) { workspace in
                        WorkspaceTab(
                            workspace: workspace,
                            isActive: workspace.id == workspaceManager.activeWorkspaceID,
                            onSelect: { workspaceManager.switchToWorkspace(workspace.id) },
                            onClose: { workspaceManager.closeWorkspace(workspace.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Spacer()

            // Bottom actions
            VStack(spacing: 4) {
                Divider()

                Button(action: { onOpenProject?() }) {
                    Label("Open Project", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Button(action: { onOpenSettings?() }) {
                    Label("Settings", systemImage: "gear")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .padding(.bottom, 8)
            }
        }
        .frame(width: DesignTokens.Layout.sidebarWidth)
    }
}

// MARK: - WorkspaceTab

struct WorkspaceTab: View {
    @ObservedObject var workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Active indicator dot
            Circle()
                .fill(isActive ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(workspace.name)
                    .font(.body)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let branch = workspace.gitBranch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if workspace.activeTasks > 0 {
                        Label("\(workspace.activeTasks)", systemImage: "checklist")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            // Notification badge
            if workspace.unreadNotifications > 0 {
                NotificationBadge(count: workspace.unreadNotifications)
            }

            // Close button on hover
            if isHovering {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
    }
}

// MARK: - NotificationBadge

struct NotificationBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.red))
    }
}

// MARK: - DesignTokens bridging for SwiftUI

private extension DesignTokens.Layout {
    // Already defined in DesignTokens.swift — accessible here via the enum.
}
