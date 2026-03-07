import SwiftUI

/// Sidebar tool items — each opens a feature pane.
struct SidebarToolItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let isStub: Bool

    init(id: String, title: String, icon: String, isStub: Bool = false) {
        self.id = id
        self.title = title
        self.icon = icon
        self.isStub = isStub
    }
}

/// Tools with working backends are listed first; stubs are marked as "Coming Soon".
let sidebarTools: [SidebarToolItem] = [
    SidebarToolItem(id: "terminal", title: "Terminal", icon: "terminal"),
    SidebarToolItem(id: "tasks", title: "Task Board", icon: "checklist"),
    SidebarToolItem(id: "workflow", title: "Workflow", icon: "arrow.triangle.branch"),
    SidebarToolItem(id: "notifications", title: "Notifications", icon: "bell"),
    SidebarToolItem(id: "files", title: "File Browser", icon: "folder"),
    SidebarToolItem(id: "ssh", title: "SSH Manager", icon: "network"),
    SidebarToolItem(id: "replay", title: "Session Replay", icon: "play.rectangle"),
    SidebarToolItem(id: "browser", title: "Browser", icon: "globe"),
    SidebarToolItem(id: "search", title: "Search", icon: "magnifyingglass"),
    SidebarToolItem(id: "review", title: "Review", icon: "eye"),
    SidebarToolItem(id: "merge", title: "Merge Queue", icon: "arrow.triangle.merge"),
    SidebarToolItem(id: "diff", title: "Diff Viewer", icon: "doc.text.magnifyingglass"),
    SidebarToolItem(id: "analytics", title: "Analytics", icon: "chart.bar"),
    SidebarToolItem(id: "brief", title: "Daily Brief", icon: "newspaper"),
    SidebarToolItem(id: "rules", title: "Rules Manager", icon: "list.bullet.rectangle"),
]

/// SwiftUI sidebar listing workspaces, projects, and quick actions.
/// Embedded in the main window via NSHostingView + NSVisualEffectView.
struct SidebarView: View {
    @ObservedObject var workspaceManager: WorkspaceManager
    @ObservedObject private var theme = GhosttyThemeProvider.shared

    /// Called when the user wants to add a new workspace.
    var onAddWorkspace: (() -> Void)?
    /// Called when the user wants to open settings.
    var onOpenSettings: (() -> Void)?
    /// Called when the user wants to open a tool pane.
    var onOpenTool: ((String) -> Void)?

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
        let pinned = workspaceManager.workspaces.filter(\.isPinned)
        let unpinned = workspaceManager.workspaces.filter { !$0.isPinned }
        return pinned + unpinned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Workspaces (top, takes remaining space)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("WORKSPACES")
                            .font(.system(size: 11))
                            .fontWeight(.semibold)
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
                            }
                        )
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Spacer(minLength: 0)

            // 2. Tools (bottom-aligned, no scroll)
            VStack(spacing: 0) {
                Divider()

                ToolsSectionHeader(isExpanded: $isToolsExpanded)

                if isToolsExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sidebarTools) { tool in
                            SidebarToolButton(tool: tool, isActive: activeToolID == tool.id) {
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
                    tool: SidebarToolItem(id: "settings", title: "Settings", icon: "gear"),
                    isActive: activeToolID == "settings"
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
    }
}

// MARK: - SidebarToolButton

struct SidebarToolButton: View {
    let tool: SidebarToolItem
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: tool.icon)
                    .font(.callout)
                    .frame(width: 20, alignment: .center)
                    .foregroundStyle(tool.isStub ? .tertiary : .primary)
                Text(tool.title)
                    .font(.callout)
                    .foregroundStyle(tool.isStub ? .tertiary : .primary)
                Spacer()
                if tool.isStub {
                    Text("Soon")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(DesignTokens.Opacity.subtle)))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isActive ? Color.primary.opacity(DesignTokens.Opacity.light) :
                          isHovering ? Color.primary.opacity(DesignTokens.Opacity.subtle) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(tool.title + (tool.isStub ? ", coming soon" : ""))
    }
}

// MARK: - WorkspaceRow

struct WorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var onRename: ((String) -> Void)?

    @State private var isHovering = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var isRenameFieldFocused: Bool

    private var themeAccentColor: Color {
        Color(nsColor: GhosttyThemeProvider.shared.foregroundColor)
    }

    private var totalNotifications: Int {
        workspace.unreadNotifications + workspace.terminalNotificationCount
    }

    private var indicatorColor: Color {
        if let hex = workspace.customColor, let nsColor = NSColor(hexString: hex) {
            return Color(nsColor: nsColor)
        }
        return isActive ? themeAccentColor : Color.secondary.opacity(0.3)
    }

    private var shortenedPath: String? {
        guard let path = workspace.projectPath else { return nil }
        let components = path.split(separator: "/")
        if components.count <= 2 { return path }
        return "~/" + components.suffix(2).joined(separator: "/")
    }

    var body: some View {
        HStack(spacing: 8) {
            // Pin icon or active indicator dot
            if workspace.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(indicatorColor)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isRenaming {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(.body)
                        .fontWeight(.semibold)
                        .focused($isRenameFieldFocused)
                        .onSubmit {
                            let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                onRename?(trimmed)
                            }
                            isRenaming = false
                        }
                        .onExitCommand {
                            isRenaming = false
                        }
                } else {
                    Text(workspace.name)
                        .font(.body)
                        .fontWeight(isActive ? .semibold : .regular)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    if workspace.projectPath != nil && workspace.gitBranch == nil && isActive {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.7)
                    }

                    if let branch = workspace.gitBranch {
                        HStack(spacing: 2) {
                            Label(branch, systemImage: "arrow.triangle.branch")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if workspace.gitDirty {
                                Text("*")
                                    .font(.caption2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    if workspace.activeTasks > 0 {
                        Label("\(workspace.activeTasks)", systemImage: "checklist")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if let shortPath = shortenedPath {
                    Text(shortPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Notification badge (backend + terminal notifications combined)
            if totalNotifications > 0 {
                NotificationBadge(count: totalNotifications)
            }

            // Close button on hover
            if isHovering {
                CloseButton(action: onClose)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? indicatorColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovering = $0 }
        .onChange(of: isRenaming) {
            if isRenaming {
                isRenameFieldFocused = true
            }
        }
        .contextMenu {
            Button("Rename...") {
                renameText = workspace.name
                isRenaming = true
            }
            Button(workspace.isPinned ? "Unpin" : "Pin") {
                workspace.isPinned.toggle()
            }
            if let path = workspace.projectPath {
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(path, forType: .string)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                }
            }
            Divider()
            Button("Close Workspace", role: .destructive) {
                onClose()
            }
        }
        .accessibilityLabel("Workspace: \(workspace.name)\(workspace.isPinned ? ", pinned" : "")")
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

// MARK: - AddButton

private struct AddButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? Color.green : Color.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Add workspace")
    }
}

// MARK: - CloseButton

private struct CloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isHovering ? Color.red : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Close workspace")
    }
}

// MARK: - ToolsSectionHeader

private struct ToolsSectionHeader: View {
    @Binding var isExpanded: Bool
    @State private var isHovering = false

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        }) {
            HStack {
                Text("TOOLS")
                    .font(.system(size: 11))
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isHovering ? Color.accentColor : .secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : 180))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(isExpanded ? "Collapse tools section" : "Expand tools section")
    }
}

// MARK: - SidebarPreferences

enum SidebarPreferences {
    private static let defaults = UserDefaults.standard

    /// How much to lighten the sidebar background relative to the terminal.
    /// 0.0 = exact terminal color, 0.05 = slight lightening (default).
    static var backgroundOffset: Double {
        get {
            let raw = defaults.object(forKey: "sidebarBackgroundOffset") as? Double ?? 0.05
            return max(0.0, min(0.3, raw))
        }
        set { defaults.set(newValue, forKey: "sidebarBackgroundOffset") }
    }
}

