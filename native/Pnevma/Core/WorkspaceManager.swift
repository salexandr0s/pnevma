import Cocoa
import Combine
import os

/// Manages workspace lifecycle — creation, switching, persistence, and teardown.
/// Coordinates between the sidebar, content area, and Rust backend.
final class WorkspaceManager: ObservableObject {

    // MARK: - Published State

    @Published private(set) var workspaces: [Workspace] = []
    @Published private(set) var activeWorkspaceID: UUID?

    var activeWorkspace: Workspace? {
        guard let id = activeWorkspaceID else { return nil }
        return workspaces.first { $0.id == id }
    }

    // MARK: - Callbacks

    /// Called when the active workspace changes, providing the new workspace's layout engine.
    var onActiveWorkspaceChanged: ((PaneLayoutEngine) -> Void)?

    // MARK: - Dependencies

    private let bridge: PnevmaBridge
    private let commandBus: CommandBus
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(bridge: PnevmaBridge, commandBus: CommandBus) {
        self.bridge = bridge
        self.commandBus = commandBus
    }

    // MARK: - Workspace Operations

    /// Create a new workspace and make it active.
    @discardableResult
    func createWorkspace(name: String, projectPath: String? = nil) -> Workspace {
        let workspace = Workspace(name: name, projectPath: projectPath)
        workspaces.append(workspace)
        activeWorkspaceID = workspace.id

        // Open project in Rust backend if path is provided.
        if let path = projectPath {
            openProjectInBackend(path: path, workspace: workspace)
        }

        Log.workspace.info("Created workspace '\(name)' id=\(workspace.id)")
        return workspace
    }

    /// Switch to the workspace at the given index.
    func switchToWorkspace(_ id: UUID) {
        guard let workspace = workspaces.first(where: { $0.id == id }) else { return }
        activeWorkspaceID = id
        onActiveWorkspaceChanged?(workspace.layoutEngine)
        Log.workspace.info("Switched to workspace \(id)")
    }

    /// Close and remove a workspace.
    func closeWorkspace(_ id: UUID) {
        guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let workspace = workspaces.remove(at: index)
        Log.workspace.info("Closed workspace '\(workspace.name)'")

        // If we closed the active workspace, switch to next available.
        if activeWorkspaceID == id {
            activeWorkspaceID = workspaces.first?.id
        }
    }

    // MARK: - Metadata Updates

    /// Refresh workspace metadata from the Rust backend.
    func refreshMetadata(for workspace: Workspace) {
        Task {
            do {
                let summary: ProjectSummary = try await commandBus.call(
                    method: "project.summary", params: EmptyParams())
                await MainActor.run {
                    workspace.gitBranch = summary.gitBranch
                    workspace.activeTasks = summary.activeTasks
                    workspace.activeAgents = summary.activeAgents
                    workspace.costToday = summary.costToday
                }
            } catch {
                Log.workspace.error("Failed to refresh metadata: \(error)")
            }
        }
    }

    // MARK: - Private

    private func openProjectInBackend(path: String, workspace: Workspace) {
        Task {
            do {
                let _: EmptyResponse = try await commandBus.call(
                    method: "project.open",
                    params: OpenProjectParams(path: path)
                )
                refreshMetadata(for: workspace)
            } catch {
                Log.workspace.error("Failed to open project: \(error)")
            }
        }
    }
}

// MARK: - API Types

private struct EmptyParams: Encodable {}
private struct EmptyResponse: Decodable {}
private struct OpenProjectParams: Encodable { let path: String }

struct ProjectSummary: Decodable {
    let gitBranch: String?
    let activeTasks: Int
    let activeAgents: Int
    let costToday: Double
}
