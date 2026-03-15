import SwiftUI

enum SidebarToolDefaultPresentation: String, Equatable, CaseIterable {
    case pane
    case tab
    case drawer
}

/// Sidebar tool items — each maps to a pane type.
struct SidebarToolItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let paneType: String
    let isStub: Bool

    init(
        id: String,
        title: String,
        icon: String,
        paneType: String,
        isStub: Bool = false
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.paneType = paneType
        self.isStub = isStub
    }
}

/// Tools with working backends are listed first; stubs are marked as "Coming Soon".
private let allSidebarTools: [SidebarToolItem] = [
    SidebarToolItem(
        id: "terminal",
        title: "Terminal",
        icon: "terminal",
        paneType: "terminal",
    ),
    SidebarToolItem(
        id: "tasks",
        title: "Task Board",
        icon: "checklist",
        paneType: "taskboard",
    ),
    SidebarToolItem(
        id: "workflow",
        title: "Agents",
        icon: "arrow.triangle.branch",
        paneType: "workflow",
    ),
    SidebarToolItem(
        id: "notifications",
        title: "Notifications",
        icon: "bell",
        paneType: "notifications",
    ),
    SidebarToolItem(
        id: "files",
        title: "File Browser",
        icon: "folder",
        paneType: "file_browser",
    ),
    SidebarToolItem(
        id: "ssh",
        title: "SSH Manager",
        icon: "network",
        paneType: "ssh",
    ),
    SidebarToolItem(
        id: "harness",
        title: "Harness Config",
        icon: "slider.horizontal.3",
        paneType: "harness_config",
    ),
    SidebarToolItem(
        id: "replay",
        title: "Session Replay",
        icon: "play.rectangle",
        paneType: "replay",
    ),
    SidebarToolItem(
        id: "browser",
        title: "Browser",
        icon: "globe",
        paneType: "browser"
    ),
    SidebarToolItem(
        id: "review",
        title: "Review",
        icon: "eye",
        paneType: "review",
    ),
    SidebarToolItem(
        id: "diff",
        title: "Diff Viewer",
        icon: "doc.text.magnifyingglass",
        paneType: "diff",
    ),
    SidebarToolItem(
        id: "analytics",
        title: "Usage",
        icon: "chart.bar",
        paneType: "analytics",
    ),
    SidebarToolItem(
        id: "brief",
        title: "Daily Brief",
        icon: "newspaper",
        paneType: "daily_brief",
    ),
    SidebarToolItem(
        id: "rules",
        title: "Rules Manager",
        icon: "list.bullet.rectangle",
        paneType: "rules",
    ),
    SidebarToolItem(
        id: "secrets",
        title: "Secrets",
        icon: "key.fill",
        paneType: "secrets",
    ),
    SidebarToolItem(
        id: "settings",
        title: "Settings",
        icon: "gearshape",
        paneType: "settings",
    ),
]

func sidebarToolDefinition(id: String) -> SidebarToolItem? {
    allSidebarTools.first { $0.id == id }
}

func sidebarToolDefinition(paneType: String) -> SidebarToolItem? {
    allSidebarTools.first { $0.paneType == paneType }
}

func sidebarTool(id: String, in workspace: Workspace?) -> SidebarToolItem? {
    sidebarTools(for: workspace).first { $0.id == id }
}

func sidebarTools(for workspace: Workspace?) -> [SidebarToolItem] {
    let allowedIDs: Set<String>
    if let workspace, workspace.showsProjectToolsInUI {
        allowedIDs = [
            "terminal",
            "tasks",
            "workflow",
            "notifications",
            "ssh",
            "harness",
            "replay",
            "browser",
            "analytics",
            "brief",
            "rules",
            "secrets",
            "settings",
        ]
    } else {
        allowedIDs = ["terminal", "workflow", "notifications", "ssh", "harness", "browser", "analytics", "settings"]
    }

    return allSidebarTools.filter { allowedIDs.contains($0.id) }
}
