import SwiftUI

/// SwiftUI sidebar listing workspaces and workspace-level actions.
/// Embedded in the main window via NSHostingView + NSVisualEffectView.
struct SidebarView: View {
    var workspaceManager: WorkspaceManager
    @Environment(GhosttyThemeProvider.self) var theme
    @AppStorage("sidebarBackgroundOffset") private var sidebarOffset: Double = BackgroundTint.defaultOffset

    /// Called when the user wants to add a new workspace.
    var onAddWorkspace: (() -> Void)?

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

    /// Workspaces sorted with pinned items first, preserving relative order.
    private var sortedWorkspaces: [Workspace] {
        let terminal = workspaceManager.workspaces.filter(\.isPermanent)
        let projectWorkspaces = workspaceManager.workspaces.filter { !$0.isPermanent }
        let pinned = projectWorkspaces.filter(\.isPinned)
        let unpinned = projectWorkspaces.filter { !$0.isPinned }
        return terminal + pinned + unpinned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("WORKSPACES")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        AddButton { onAddWorkspace?() }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 2)

                    ForEach(sortedWorkspaces) { workspace in
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
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: DesignTokens.Layout.sidebarWidth)
        .background(sidebarBackground)
        .accessibilityIdentifier("sidebar.view")
    }
}
