import SwiftUI

/// SwiftUI sidebar listing workspaces and workspace-level actions.
/// Embedded in the main window via NSHostingView + NSVisualEffectView.
struct SidebarView: View {
    var workspaceManager: WorkspaceManager
    @Environment(GhosttyThemeProvider.self) var theme
    @AppStorage("sidebarBackgroundOffset") private var sidebarOffset: Double = BackgroundTint.defaultOffset

    /// Called when the user wants to add a new workspace.
    var onAddWorkspace: (() -> Void)?

    @State private var navigationMode: SidebarNavigationMode = .workspaces
    private let groupState = SidebarGroupState.shared

    /// Sidebar background derived from the ghostty terminal theme.
    private var sidebarBackground: Color {
        let bg = theme.backgroundColor
        let offset = BackgroundTint.clamped(sidebarOffset)
        if offset == 0 {
            return Color(nsColor: bg)
        }
        let tinted = bg.blended(withFraction: offset, of: .white) ?? bg
        return Color(nsColor: tinted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarNavigationHeader(
                mode: $navigationMode,
                onAddWorkspace: onAddWorkspace
            )
            Divider()

            switch navigationMode {
            case .workspaces:
                workspacesContent
            case .tasks:
                EmptyStateView(
                    icon: "checklist",
                    title: "No tasks yet",
                    message: "Task tracking will appear here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            SidebarFooter(onAddRepository: onAddWorkspace)
        }
        .frame(minWidth: 0, maxWidth: DesignTokens.Layout.sidebarMaxWidth)
        .background(sidebarBackground)
        .accessibilityIdentifier("sidebar.view")
    }

    // MARK: - Workspaces Content

    private var workspacesContent: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 2) {
                // Terminal section (always first)
                let terminals = workspaceManager.terminalWorkspaces
                if !terminals.isEmpty {
                    SidebarSectionHeader(
                        title: "Terminal",
                        isCollapsible: false
                    )
                    .padding(.top, 8)

                    ForEach(terminals) { workspace in
                        workspaceRow(workspace)
                    }
                }

                // Pinned section
                let pinned = workspaceManager.pinnedWorkspaces
                if !pinned.isEmpty {
                    SidebarSectionHeader(
                        title: "Pinned",
                        count: pinned.count,
                        isCollapsible: false
                    )
                    .padding(.top, 6)

                    ForEach(pinned) { workspace in
                        workspaceRow(workspace)
                    }
                }

                // Per-project groups
                let groups = workspaceManager.projectGroups
                ForEach(groups) { group in
                    let collapsed = groupState.isCollapsed(group.name)

                    SidebarSectionHeader(
                        title: group.name,
                        count: group.count,
                        isCollapsed: collapsed,
                        onToggle: { groupState.toggleCollapse(group.name) },
                        onAdd: onAddWorkspace
                    )
                    .padding(.top, 6)

                    if !collapsed {
                        VStack(alignment: .leading, spacing: 0) {
                            subgroupSection("Needs Attention", workspaces: group.attention)
                            subgroupSection("Active", workspaces: group.active)
                            subgroupSection("In Review", workspaces: group.review)
                            subgroupSection("Idle", workspaces: group.idle)
                        }
                        .transition(.opacity)
                    }
                }

                // Fallback: if no groups exist, show add button
                if terminals.isEmpty && pinned.isEmpty && groups.isEmpty {
                    EmptyStateView(
                        icon: "square.stack.3d.up",
                        title: "No workspaces",
                        message: "Create a workspace to get started."
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 32)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Helpers

    private func workspaceRow(_ workspace: Workspace) -> some View {
        WorkspaceRow(
            workspace: workspace,
            isActive: workspace.id == workspaceManager.activeWorkspaceID,
            onSelect: { workspaceManager.switchToWorkspace(workspace.id) },
            onClose: { workspaceManager.closeWorkspace(workspace.id) },
            onRename: { newName in
                workspaceManager.renameWorkspace(workspace.id, to: newName)
            },
            onPin: { workspaceManager.togglePinWorkspace(workspace.id) },
            onSetColor: { hex in
                workspaceManager.setWorkspaceColor(workspace.id, hex: hex)
            }
        )
    }

    @ViewBuilder
    private func subgroupSection(_ label: String, workspaces: [Workspace]) -> some View {
        if !workspaces.isEmpty {
            SmallSubgroupLabel(label)
            ForEach(workspaces) { workspace in
                workspaceRow(workspace)
            }
        }
    }
}
