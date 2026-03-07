import Foundation
import Combine

/// A single tab within a workspace. Each tab has its own pane layout.
final class WorkspaceTab: Identifiable {
    let id: UUID
    var title: String
    let layoutEngine: PaneLayoutEngine

    init(id: UUID = UUID(), title: String = "Terminal", layoutEngine: PaneLayoutEngine? = nil, rootPaneID: PaneID = PaneID()) {
        self.id = id
        self.title = title
        self.layoutEngine = layoutEngine ?? PaneLayoutEngine(rootPaneID: rootPaneID)
    }
}

/// A workspace represents an open project with its own tabs, terminal sessions,
/// and connection to the Rust backend (via a shared PnevmaBridge).
final class Workspace: ObservableObject, Identifiable {

    let id: UUID
    @Published var name: String
    @Published var projectPath: String?
    @Published var gitBranch: String?
    @Published var activeTasks: Int = 0
    @Published var activeAgents: Int = 0
    @Published var costToday: Double = 0.0
    @Published var unreadNotifications: Int = 0
    @Published var terminalNotificationCount: Int = 0
    @Published var customColor: String?
    @Published var isPinned: Bool = false
    @Published var gitDirty: Bool = false

    /// Tabs within this workspace.
    @Published var tabs: [WorkspaceTab]

    /// Index of the currently active tab.
    @Published var activeTabIndex: Int = 0

    /// The active tab's pane layout engine.
    var layoutEngine: PaneLayoutEngine {
        tabs[activeTabIndex].layoutEngine
    }

    /// When this workspace was created.
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        projectPath: String? = nil,
        layoutEngine: PaneLayoutEngine? = nil,
        rootPaneID: PaneID = PaneID()
    ) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        let initialTab = WorkspaceTab(
            title: "Terminal",
            layoutEngine: layoutEngine,
            rootPaneID: rootPaneID
        )
        self.tabs = [initialTab]
        self.activeTabIndex = 0
        self.createdAt = Date()
    }

    /// Initialize with pre-built tabs (used for restore).
    init(
        id: UUID,
        name: String,
        projectPath: String?,
        tabs: [WorkspaceTab],
        activeTabIndex: Int
    ) {
        self.id = id
        self.name = name
        self.projectPath = projectPath
        let resolvedTabs = tabs.isEmpty ? [WorkspaceTab(title: "Terminal")] : tabs
        self.tabs = resolvedTabs
        self.activeTabIndex = min(activeTabIndex, resolvedTabs.count - 1)
        self.createdAt = Date()
    }

    // MARK: - Tab Operations

    /// Add a new tab and make it active. Returns the new tab.
    @discardableResult
    func addTab(title: String = "Terminal", rootPaneID: PaneID = PaneID()) -> WorkspaceTab {
        let tab = WorkspaceTab(title: title, rootPaneID: rootPaneID)
        tabs.append(tab)
        activeTabIndex = tabs.count - 1
        return tab
    }

    /// Close a tab by index. Returns true if the tab was closed.
    @discardableResult
    func closeTab(at index: Int) -> Bool {
        guard tabs.count > 1, index >= 0, index < tabs.count else { return false }
        tabs.remove(at: index)
        if activeTabIndex >= tabs.count {
            activeTabIndex = tabs.count - 1
        } else if activeTabIndex > index {
            activeTabIndex -= 1
        }
        return true
    }

    /// Close a tab by ID. Returns true if the tab was closed.
    @discardableResult
    func closeTab(id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return closeTab(at: index)
    }

    /// Switch to tab at the given index.
    func switchToTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        activeTabIndex = index
    }
}

// MARK: - Codable serialization for persistence

extension WorkspaceTab {
    struct Snapshot: Codable {
        let id: UUID
        let title: String
        let layoutData: Data?
    }

    func snapshot() -> Snapshot {
        Snapshot(id: id, title: title, layoutData: layoutEngine.serialize())
    }

    convenience init(snapshot: Snapshot) {
        let engine = snapshot.layoutData.flatMap(PaneLayoutEngine.deserialize(from:))
        self.init(id: snapshot.id, title: snapshot.title, layoutEngine: engine)
    }
}

extension Workspace {
    struct Snapshot: Codable {
        let id: UUID
        let name: String
        let projectPath: String?
        // New: per-tab serialization
        var tabSnapshots: [WorkspaceTab.Snapshot]?
        var activeTabIndex: Int?
        // Legacy: single layout (pre-tabs). Kept for backward compat.
        let layoutData: Data?
        var customColor: String?
        var isPinned: Bool?
    }

    func snapshot() -> Snapshot {
        Snapshot(
            id: id,
            name: name,
            projectPath: projectPath,
            tabSnapshots: tabs.map { $0.snapshot() },
            activeTabIndex: activeTabIndex,
            layoutData: nil,
            customColor: customColor,
            isPinned: isPinned
        )
    }

    convenience init(snapshot: Snapshot) {
        if let tabSnapshots = snapshot.tabSnapshots, !tabSnapshots.isEmpty {
            // New format: restore tabs
            let restoredTabs = tabSnapshots.map(WorkspaceTab.init(snapshot:))
            self.init(
                id: snapshot.id,
                name: snapshot.name,
                projectPath: snapshot.projectPath,
                tabs: restoredTabs,
                activeTabIndex: snapshot.activeTabIndex ?? 0
            )
        } else {
            // Legacy format: single layout -> single tab
            let restoredLayout = snapshot.layoutData.flatMap(PaneLayoutEngine.deserialize(from:))
            self.init(
                id: snapshot.id,
                name: snapshot.name,
                projectPath: snapshot.projectPath,
                layoutEngine: restoredLayout
            )
        }
        self.customColor = snapshot.customColor
        self.isPinned = snapshot.isPinned ?? false
    }
}
