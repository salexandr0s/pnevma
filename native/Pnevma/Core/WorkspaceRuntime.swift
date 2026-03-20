import Foundation
import Observation

enum WorkspaceProjectCloseMode: String, Encodable {
    case workspaceClose = "workspace_close"
    case appShutdown = "app_shutdown"
}

private struct WorkspaceRuntimeProjectCloseParams: Encodable {
    let mode: WorkspaceProjectCloseMode
}

@MainActor
@Observable
final class WorkspaceRuntime {
    enum State: Equatable {
        case closed
        case opening(generation: UInt64)
        case open(projectID: String)
        case failed(generation: UInt64, message: String)
    }

    let workspaceID: UUID
    let commandBus: any CommandCalling

    @ObservationIgnored
    private let bridge: PnevmaBridge?
    @ObservationIgnored
    private let providedSessionBridge: (any SessionBridging)?
    @ObservationIgnored
    private lazy var sessionBridgeStorage: any SessionBridging = {
        providedSessionBridge ?? SessionBridge(commandBus: commandBus) { [weak self] in
            self?.projectPath
        }
    }()

    private(set) var projectPath: String?
    private(set) var state: State = .closed

    var sessionBridge: any SessionBridging { sessionBridgeStorage }

    init(
        workspaceID: UUID,
        bridge: PnevmaBridge,
        commandBus: any CommandCalling
    ) {
        self.workspaceID = workspaceID
        self.bridge = bridge
        self.commandBus = commandBus
        self.providedSessionBridge = nil
    }

    init(
        workspaceID: UUID,
        commandBus: any CommandCalling,
        sessionBridge: (any SessionBridging)? = nil
    ) {
        self.workspaceID = workspaceID
        self.bridge = nil
        self.commandBus = commandBus
        self.providedSessionBridge = sessionBridge
    }

    // TODO(perf): Consider sharing a single Tokio runtime across workspaces
    // to reduce thread pool overhead when running multiple workspaces.
    convenience init(workspaceID: UUID) {
        let bridge = PnevmaBridge()
        let commandBus = CommandBus(bridge: bridge)
        self.init(workspaceID: workspaceID, bridge: bridge, commandBus: commandBus)
    }

    var projectID: String? {
        if case .open(let projectID) = state {
            return projectID
        }
        return nil
    }

    func updateProjectPath(_ projectPath: String?) {
        self.projectPath = projectPath
    }

    func markOpening(generation: UInt64, projectPath: String?) {
        self.projectPath = projectPath
        state = .opening(generation: generation)
    }

    func markOpen(projectID: String, projectPath: String) {
        self.projectPath = projectPath
        state = .open(projectID: projectID)
    }

    func markFailed(generation: UInt64, message: String) {
        state = .failed(generation: generation, message: message)
    }

    func markClosed() {
        state = .closed
    }

    func fetchCommandCenterSnapshot() async throws -> CommandCenterSnapshot {
        try await commandBus.call(method: "project.command_center_snapshot", params: nil)
    }

    func closeProject(mode: WorkspaceProjectCloseMode = .workspaceClose) async {
        guard case .open = state else {
            markClosed()
            return
        }
        do {
            let _: OkResponse = try await commandBus.call(
                method: "project.close",
                params: WorkspaceRuntimeProjectCloseParams(mode: mode)
            )
        } catch {
            Log.workspace.error(
                "Failed to close backend project for workspace runtime \(self.workspaceID.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
        markClosed()
    }

    func destroy() {
        bridge?.destroy()
    }

    func shutdown() {
        destroy()
    }

    deinit {
        bridge?.destroy()
    }
}
