import Foundation
import Combine

/// A workspace represents an open project with its own layout, terminal sessions,
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

    /// The pane layout for this workspace.
    let layoutEngine: PaneLayoutEngine

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
        self.layoutEngine = layoutEngine ?? PaneLayoutEngine(rootPaneID: rootPaneID)
        self.createdAt = Date()
    }
}

// MARK: - Codable serialization for persistence

extension Workspace {
    struct Snapshot: Codable {
        let id: UUID
        let name: String
        let projectPath: String?
        let layoutData: Data?
        var customColor: String?
        var isPinned: Bool?
    }

    func snapshot() -> Snapshot {
        Snapshot(
            id: id,
            name: name,
            projectPath: projectPath,
            layoutData: layoutEngine.serialize(),
            customColor: customColor,
            isPinned: isPinned
        )
    }

    convenience init(snapshot: Snapshot) {
        let restoredLayout = snapshot.layoutData.flatMap(PaneLayoutEngine.deserialize(from:))
        self.init(
            id: snapshot.id,
            name: snapshot.name,
            projectPath: snapshot.projectPath,
            layoutEngine: restoredLayout
        )
        self.customColor = snapshot.customColor
        self.isPinned = snapshot.isPinned ?? false
    }
}
