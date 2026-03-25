import SwiftUI

enum SidebarToolDefaultPresentation: String, Equatable, CaseIterable {
    case pane
    case tab
    case drawer
}

/// Logical grouping for tool dock separator placement.
enum ToolGroup: String {
    case dev        // terminal, files, diff, review, harness
    case ops        // workflow, tasks, notifications, replay
    case monitor    // analytics, resource_monitor, brief, browser
    case manage     // ssh, rules, secrets, ports
    case system     // settings
}

/// Sidebar tool items — each maps to a pane type.
struct SidebarToolItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let paneType: String
    let isStub: Bool
    let group: ToolGroup

    init(
        id: String,
        title: String,
        icon: String,
        paneType: String,
        isStub: Bool = false,
        group: ToolGroup = .dev
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.paneType = paneType
        self.isStub = isStub
        self.group = group
    }
}

/// Tools with working backends are listed first; stubs are marked as "Coming Soon".
private let allSidebarTools: [SidebarToolItem] = [
    // Dev tools
    SidebarToolItem(
        id: "terminal",
        title: "Terminal",
        icon: "terminal",
        paneType: "terminal",
        group: .dev
    ),
    SidebarToolItem(
        id: "files",
        title: "File Browser",
        icon: "folder",
        paneType: "file_browser",
        group: .dev
    ),
    SidebarToolItem(
        id: "diff",
        title: "Diff Viewer",
        icon: "doc.text.magnifyingglass",
        paneType: "diff",
        group: .dev
    ),
    SidebarToolItem(
        id: "review",
        title: "Review",
        icon: "eye",
        paneType: "review",
        group: .dev
    ),
    SidebarToolItem(
        id: "harness",
        title: "Harness Config",
        icon: "slider.horizontal.3",
        paneType: "harness_config",
        group: .dev
    ),
    // Ops tools
    SidebarToolItem(
        id: "workflow",
        title: "Agents",
        icon: "point.3.connected.trianglepath.dotted",
        paneType: "workflow",
        group: .ops
    ),
    SidebarToolItem(
        id: "tasks",
        title: "Task Board",
        icon: "checklist",
        paneType: "taskboard",
        group: .ops
    ),
    SidebarToolItem(
        id: "notifications",
        title: "Notifications",
        icon: "bell",
        paneType: "notifications",
        group: .ops
    ),
    SidebarToolItem(
        id: "replay",
        title: "Session Replay",
        icon: "play.square.stack",
        paneType: "replay",
        group: .ops
    ),
    // Monitor tools
    SidebarToolItem(
        id: "browser",
        title: "Browser",
        icon: "globe",
        paneType: "browser",
        group: .monitor
    ),
    SidebarToolItem(
        id: "analytics",
        title: "Usage",
        icon: "chart.bar.xaxis",
        paneType: "analytics",
        group: .monitor
    ),
    SidebarToolItem(
        id: "resource_monitor",
        title: "Resources",
        icon: "gauge.with.dots.needle.bottom.50percent",
        paneType: "resource_monitor",
        group: .monitor
    ),
    SidebarToolItem(
        id: "brief",
        title: "Daily Brief",
        icon: "doc.text.image",
        paneType: "daily_brief",
        group: .monitor
    ),
    // Manage tools
    SidebarToolItem(
        id: "ssh",
        title: "SSH Manager",
        icon: "key.horizontal",
        paneType: "ssh",
        group: .manage
    ),
    SidebarToolItem(
        id: "rules",
        title: "Rules Manager",
        icon: "checklist.checked",
        paneType: "rules",
        group: .manage
    ),
    SidebarToolItem(
        id: "secrets",
        title: "Secrets",
        icon: "key",
        paneType: "secrets",
        group: .manage
    ),
    SidebarToolItem(
        id: "ports",
        title: "Ports",
        icon: "network.badge.shield.half.filled",
        paneType: "ports",
        group: .manage
    ),
    // System
    SidebarToolItem(
        id: "settings",
        title: "Settings",
        icon: "gearshape",
        paneType: "settings",
        group: .system
    ),
]

func sidebarToolDefinition(id: String) -> SidebarToolItem? {
    allSidebarTools.first { $0.id == id }
}

func sidebarToolDefinition(paneType: String) -> SidebarToolItem? {
    allSidebarTools.first { $0.paneType == paneType }
}

@MainActor
func sidebarTool(id: String, in workspace: Workspace?) -> SidebarToolItem? {
    sidebarTools(for: workspace).first { $0.id == id }
}

@MainActor
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
            "resource_monitor",
            "brief",
            "rules",
            "secrets",
            "ports",
        ]
    } else {
        allowedIDs = ["terminal", "workflow", "notifications", "ssh", "harness", "browser", "analytics", "resource_monitor"]
    }

    return allSidebarTools.filter { allowedIDs.contains($0.id) }
}
