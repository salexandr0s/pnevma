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

    /// The pane layout for this workspace.
    let layoutEngine: PaneLayoutEngine

    /// When this workspace was created.
    let createdAt: Date

    init(name: String, projectPath: String? = nil, rootPaneID: PaneID = PaneID()) {
        self.id = UUID()
        self.name = name
        self.projectPath = projectPath
        self.layoutEngine = PaneLayoutEngine(rootPaneID: rootPaneID)
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
    }

    func snapshot() -> Snapshot {
        Snapshot(
            id: id,
            name: name,
            projectPath: projectPath,
            layoutData: layoutEngine.serialize()
        )
    }
}
