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
private let allSidebarTools: [SidebarToolItem] = [
    SidebarToolItem(id: "terminal", title: "Terminal", icon: "terminal"),
    SidebarToolItem(id: "tasks", title: "Task Board", icon: "checklist"),
    SidebarToolItem(id: "workflow", title: "Agents", icon: "arrow.triangle.branch"),
    SidebarToolItem(id: "notifications", title: "Notifications", icon: "bell"),
    SidebarToolItem(id: "files", title: "File Browser", icon: "folder"),
    SidebarToolItem(id: "ssh", title: "SSH Manager", icon: "network"),
    SidebarToolItem(id: "harness", title: "Harness Config", icon: "slider.horizontal.3"),
    SidebarToolItem(id: "replay", title: "Session Replay", icon: "play.rectangle"),
    SidebarToolItem(id: "browser", title: "Browser", icon: "globe"),
    SidebarToolItem(id: "search", title: "Search", icon: "magnifyingglass"),
    SidebarToolItem(id: "review", title: "Review", icon: "eye"),
    SidebarToolItem(id: "merge", title: "Merge Queue", icon: "arrow.triangle.merge"),
    SidebarToolItem(id: "diff", title: "Diff Viewer", icon: "doc.text.magnifyingglass"),
    SidebarToolItem(id: "analytics", title: "Usage", icon: "chart.bar"),
    SidebarToolItem(id: "brief", title: "Daily Brief", icon: "newspaper"),
    SidebarToolItem(id: "rules", title: "Rules Manager", icon: "list.bullet.rectangle"),
]

func sidebarTools(for workspace: Workspace?) -> [SidebarToolItem] {
    let allowedIDs: Set<String>
    if let workspace, workspace.showsProjectToolsInUI {
        allowedIDs = [
            "terminal",
            "tasks",
            "workflow",
            "notifications",
            "files",
            "ssh",
            "harness",
            "replay",
            "browser",
            "search",
            "review",
            "merge",
            "diff",
            "analytics",
            "brief",
            "rules",
        ]
    } else {
        allowedIDs = ["terminal", "workflow", "notifications", "ssh", "harness", "browser", "analytics"]
    }

    return allSidebarTools.filter { allowedIDs.contains($0.id) }
}
