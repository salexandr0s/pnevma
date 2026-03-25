import AppIntents
import Cocoa

// MARK: - Workspace Entity

struct WorkspaceEntity: AppEntity, Sendable {
    nonisolated(unsafe) static var defaultQuery = WorkspaceEntityQuery()
    nonisolated(unsafe) static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workspace")

    var id: UUID
    var name: String
    var projectPath: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct WorkspaceEntityQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WorkspaceEntity] {
        await MainActor.run {
            guard let manager = (NSApp.delegate as? AppDelegate)?.workspaceManagerForIntents else { return [] }
            return manager.workspaces
                .filter { identifiers.contains($0.id) }
                .map { WorkspaceEntity(id: $0.id, name: $0.name, projectPath: $0.projectPath) }
        }
    }

    func suggestedEntities() async throws -> [WorkspaceEntity] {
        await MainActor.run {
            guard let manager = (NSApp.delegate as? AppDelegate)?.workspaceManagerForIntents else { return [] }
            return manager.workspaces
                .map { WorkspaceEntity(id: $0.id, name: $0.name, projectPath: $0.projectPath) }
        }
    }
}

// MARK: - Open Workspace Intent

struct OpenWorkspaceIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Open Workspace"
    nonisolated(unsafe) static var description = IntentDescription("Opens the Pnevma workspace selector")
    nonisolated(unsafe) static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.openWorkspaceAction()
        }
        return .result()
    }
}

// MARK: - Switch Workspace Intent

struct SwitchWorkspaceIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "Switch Workspace"
    nonisolated(unsafe) static var description = IntentDescription("Switches to a specific Pnevma workspace")
    nonisolated(unsafe) static var openAppWhenRun = true

    @Parameter(title: "Workspace")
    var workspace: WorkspaceEntity

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.workspaceManagerForIntents?.switchToWorkspace(workspace.id)
        }
        return .result()
    }
}

// MARK: - New Terminal Intent

struct NewTerminalIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "New Terminal"
    nonisolated(unsafe) static var description = IntentDescription("Opens a new terminal in Pnevma")
    nonisolated(unsafe) static var openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            (NSApp.delegate as? AppDelegate)?.newTerminal()
        }
        return .result()
    }
}

// MARK: - List Workspaces Intent

struct ListWorkspacesIntent: AppIntent {
    nonisolated(unsafe) static var title: LocalizedStringResource = "List Workspaces"
    nonisolated(unsafe) static var description = IntentDescription("Returns all Pnevma workspaces")

    func perform() async throws -> some IntentResult & ReturnsValue<[WorkspaceEntity]> {
        let entities = await MainActor.run {
            guard let manager = (NSApp.delegate as? AppDelegate)?.workspaceManagerForIntents else { return [WorkspaceEntity]() }
            return manager.workspaces
                .map { WorkspaceEntity(id: $0.id, name: $0.name, projectPath: $0.projectPath) }
        }
        return .result(value: entities)
    }
}

// MARK: - Shortcuts Provider

struct PnevmaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenWorkspaceIntent(),
            phrases: ["Open workspace in \(.applicationName)"],
            shortTitle: "Open Workspace",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: NewTerminalIntent(),
            phrases: ["New terminal in \(.applicationName)"],
            shortTitle: "New Terminal",
            systemImageName: "terminal"
        )
    }
}
