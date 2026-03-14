import SwiftUI

/// SwiftUI sidebar listing workspaces, projects, and quick actions.
/// Embedded in the main window via NSHostingView + NSVisualEffectView.
struct SidebarView: View {
    var workspaceManager: WorkspaceManager
    @Environment(GhosttyThemeProvider.self) var theme

    /// Called when the user wants to add a new workspace.
    var onAddWorkspace: (() -> Void)?
    /// Called when the user wants to open settings.
    var onOpenSettings: (() -> Void)?
    /// Called when the user wants to open a tool using its default presentation.
    var onOpenTool: ((String) -> Void)?
    /// Called when the user wants to open a tool as a new tab.
    var onOpenToolAsTab: ((String) -> Void)?
    /// Called when the user wants to open a tool as a split pane.
    var onOpenToolAsPane: ((String) -> Void)?

    @State private var activeToolID: String?
    @State private var isToolsExpanded: Bool = true

    /// Sidebar background derived from the ghostty terminal theme.
    private var sidebarBackground: Color {
        let bg = theme.backgroundColor
        let offset = SidebarPreferences.backgroundOffset
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
            // 1. Workspaces (top, takes remaining space)
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

            Spacer(minLength: 0)

            // 2. Tools (bottom-aligned, no scroll)
            VStack(spacing: 0) {
                Divider()

                ToolsSectionHeader(isExpanded: $isToolsExpanded)

                if isToolsExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sidebarTools(for: workspaceManager.activeWorkspace)) { tool in
                            SidebarToolButton(
                                tool: tool,
                                isActive: activeToolID == tool.id,
                                onOpenAsTab: { onOpenToolAsTab?(tool.id) },
                                onOpenAsPane: { onOpenToolAsPane?(tool.id) }
                            ) {
                                activeToolID = tool.id
                                onOpenTool?(tool.id)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .padding(.horizontal, 8)

            // 3. Settings (pinned bottom)
            VStack(spacing: 0) {
                Divider()
                SidebarToolButton(
                    tool: SidebarToolItem(
                        id: "settings",
                        title: "Settings",
                        icon: "gear",
                        paneType: "settings",
                        defaultPresentation: .tab
                    ),
                    isActive: activeToolID == "settings",
                    accessibilityID: "sidebar.tool.settings"
                ) {
                    activeToolID = "settings"
                    onOpenSettings?()
                }
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: DesignTokens.Layout.sidebarWidth)
        .background(sidebarBackground)
        .accessibilityIdentifier("sidebar.view")
    }
}
