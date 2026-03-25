@preconcurrency import Cocoa

// MARK: - Scriptable Workspace Object

/// NSObject wrapper exposing Workspace properties to AppleScript.
/// Stores snapshot values to avoid cross-actor access issues.
@objc(ScriptableWorkspace)
final class ScriptableWorkspace: NSObject, @unchecked Sendable {
    private let workspaceID: UUID
    private let workspaceName: String
    private let workspaceProjectPath: String

    @MainActor
    init(workspace: Workspace) {
        self.workspaceID = workspace.id
        self.workspaceName = workspace.name
        self.workspaceProjectPath = workspace.projectPath ?? ""
        super.init()
    }

    @objc var uniqueID: String { workspaceID.uuidString }
    @objc var scriptingName: String { workspaceName }
    @objc var scriptingProjectPath: String { workspaceProjectPath }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        // The scripting subsystem always calls this on the main thread.
        nonisolated(unsafe) var desc: NSClassDescription?
        MainActor.assumeIsolated { desc = NSApp.classDescription }
        guard let classDescription = desc as? NSScriptClassDescription else { return nil }
        return NSUniqueIDSpecifier(
            containerClassDescription: classDescription,
            containerSpecifier: nil,
            key: "orderedWorkspaces",
            uniqueID: uniqueID
        )
    }
}

// MARK: - Application Scripting Extension

extension NSApplication {
    @objc var orderedWorkspaces: [ScriptableWorkspace] {
        MainActor.assumeIsolated {
            guard let delegate = NSApp.delegate as? AppDelegate,
                  let manager = delegate.workspaceManagerForIntents else { return [] }
            return manager.workspaces.map { ScriptableWorkspace(workspace: $0) }
        }
    }
}

// MARK: - Create Workspace Command

@objc(CreateWorkspaceScriptCommand)
class CreateWorkspaceScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let name = evaluatedArguments?["workspaceName"] as? String ?? "New Workspace"
        let path = evaluatedArguments?["projectPath"] as? String
        MainActor.assumeIsolated {
            guard let delegate = NSApp.delegate as? AppDelegate,
                  let manager = delegate.workspaceManagerForIntents else { return }
            manager.createWorkspace(name: name, projectPath: path)
        }
        return nil
    }
}

// MARK: - Switch Workspace Command

@objc(SwitchWorkspaceScriptCommand)
class SwitchWorkspaceScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let name = evaluatedArguments?["workspaceName"] as? String ?? ""
        MainActor.assumeIsolated {
            guard let delegate = NSApp.delegate as? AppDelegate,
                  let manager = delegate.workspaceManagerForIntents else { return }
            if let workspace = manager.workspaces.first(where: { $0.name == name }) {
                manager.switchToWorkspace(workspace.id)
            }
        }
        return nil
    }
}
