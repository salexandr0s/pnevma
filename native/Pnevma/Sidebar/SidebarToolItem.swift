import SwiftUI

enum SidebarToolDefaultPresentation: Equatable {
    case pane
    case tab
    case drawer
}

/// Sidebar tool items — each maps to a pane type and recommended default opening style.
struct SidebarToolItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let paneType: String
    let defaultPresentation: SidebarToolDefaultPresentation
    let isStub: Bool

    init(
        id: String,
        title: String,
        icon: String,
        paneType: String,
        defaultPresentation: SidebarToolDefaultPresentation,
        isStub: Bool = false
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.paneType = paneType
        self.defaultPresentation = defaultPresentation
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
        defaultPresentation: .pane
    ),
    SidebarToolItem(
        id: "tasks",
        title: "Task Board",
        icon: "checklist",
        paneType: "taskboard",
        defaultPresentation: .pane
    ),
    SidebarToolItem(
        id: "workflow",
        title: "Agents",
        icon: "arrow.triangle.branch",
        paneType: "workflow",
        defaultPresentation: .tab
    ),
    SidebarToolItem(
        id: "notifications",
        title: "Notifications",
        icon: "bell",
        paneType: "notifications",
        defaultPresentation: .pane
    ),
    SidebarToolItem(
        id: "files",
        title: "File Browser",
        icon: "folder",
        paneType: "file_browser",
        defaultPresentation: .pane
    ),
    SidebarToolItem(
        id: "ssh",
        title: "SSH Manager",
        icon: "network",
        paneType: "ssh",
        defaultPresentation: .pane
    ),
    SidebarToolItem(
        id: "harness",
        title: "Harness Config",
        icon: "slider.horizontal.3",
        paneType: "harness_config",
        defaultPresentation: .tab
    ),
    SidebarToolItem(
        id: "replay",
        title: "Session Replay",
        icon: "play.rectangle",
        paneType: "replay",
        defaultPresentation: .tab
    ),
    SidebarToolItem(
        id: "browser",
        title: "Browser",
        icon: "globe",
        paneType: "browser",
        defaultPresentation: .drawer
    ),
    SidebarToolItem(
        id: "review",
        title: "Review",
        icon: "eye",
        paneType: "review",
        defaultPresentation: .tab
    ),
    SidebarToolItem(
        id: "diff",
        title: "Diff Viewer",
        icon: "doc.text.magnifyingglass",
        paneType: "diff",
        defaultPresentation: .tab
    ),
    SidebarToolItem(
        id: "analytics",
        title: "Usage",
        icon: "chart.bar",
        paneType: "analytics",
        defaultPresentation: .tab
    ),
    SidebarToolItem(
        id: "brief",
        title: "Daily Brief",
        icon: "newspaper",
        paneType: "daily_brief",
        defaultPresentation: .tab
    ),
    SidebarToolItem(
        id: "rules",
        title: "Rules Manager",
        icon: "list.bullet.rectangle",
        paneType: "rules",
        defaultPresentation: .pane
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
        ]
    } else {
        allowedIDs = ["terminal", "workflow", "notifications", "ssh", "harness", "browser", "analytics"]
    }

    return allSidebarTools.filter { allowedIDs.contains($0.id) }
}
