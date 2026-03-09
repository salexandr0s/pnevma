import Foundation
import Observation

struct LiveSession: Identifiable, Decodable, Equatable {
    let id: String
    let name: String
    let status: String
    let health: String
    let pid: Int?
    let cwd: String
    let command: String
    let startedAt: String
    let lastHeartbeat: String
    let exitCode: Int?
    let endedAt: String?

    var isActionable: Bool {
        status == "running" || status == "waiting"
    }

    var isActive: Bool {
        isActionable
    }

    var statusDisplayName: String {
        switch status {
        case "running":
            return "Running"
        case "waiting":
            return "Waiting"
        case "error":
            return "Error"
        case "complete":
            return "Complete"
        default:
            return status.capitalized
        }
    }

    var shortCwd: String {
        if let home = ProcessInfo.processInfo.environment["HOME"], cwd.hasPrefix(home) {
            return "~" + cwd.dropFirst(home.count)
        }
        return cwd
    }
}

struct SessionKillResult: Decodable, Equatable {
    let sessionID: String
    let outcome: String
    let message: String?
}

struct SessionKillFailure: Decodable, Equatable {
    let sessionID: String
    let message: String
}

struct SessionKillAllResult: Decodable, Equatable {
    let requested: Int
    let killed: Int
    let alreadyGone: Int
    let failed: Int
    let failures: [SessionKillFailure]
}

enum SessionAvailability: Equatable {
    case waiting(String)
    case loading(String)
    case ready
    case failed(String)
    case noProject(String)
}

private struct SessionKillParams: Encodable {
    let sessionID: String
}

private struct SessionBridgePayload: Decodable {
    let projectID: String?
    let sessionID: String?
    let health: String?
    let code: Int?
    let session: LiveSession?
}

@Observable
@MainActor
final class SessionStore {
    private(set) var sessions: [LiveSession] = []
    private(set) var availability: SessionAvailability = .noProject(
        "Open a project to manage sessions."
    )
    private(set) var isLoading = false
    var actionError: String?

    @ObservationIgnored
    private let commandBus: (any CommandCalling)?
    @ObservationIgnored
    private let bridgeEventHub: BridgeEventHub
    @ObservationIgnored
    private let activationHub: ActiveWorkspaceActivationHub
    @ObservationIgnored
    private var bridgeObserverID: UUID?
    @ObservationIgnored
    private var activationObserverID: UUID?
    @ObservationIgnored
    private var eventRevision: UInt64 = 0

    init(
        commandBus: (any CommandCalling)? = CommandBus.shared,
        bridgeEventHub: BridgeEventHub = .shared,
        activationHub: ActiveWorkspaceActivationHub = .shared
    ) {
        self.commandBus = commandBus
        self.bridgeEventHub = bridgeEventHub
        self.activationHub = activationHub

        bridgeObserverID = bridgeEventHub.addObserver { [weak self] event in
            guard event.name == "session_spawned"
                || event.name == "session_heartbeat"
                || event.name == "session_exited"
            else {
                return
            }

            Task { @MainActor [weak self] in
                self?.handleBridgeEvent(event)
            }
        }
        activationObserverID = activationHub.addObserver { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleActivationState(state)
            }
        }
    }

    deinit {
        if let bridgeObserverID {
            bridgeEventHub.removeObserver(bridgeObserverID)
        }
        if let activationObserverID {
            activationHub.removeObserver(activationObserverID)
        }
    }

    var statusMessage: String? {
        switch availability {
        case .waiting(let message), .loading(let message), .failed(let message), .noProject(let message):
            return message
        case .ready:
            return nil
        }
    }

    var activeCount: Int {
        sessions.filter(\.isActive).count
    }

    var hasActiveProject: Bool {
        if case .noProject = availability {
            return false
        }
        return true
    }

    private var currentProjectID: String? {
        if case .open(_, let projectID) = activationHub.currentState {
            return projectID
        }
        return nil
    }

    func activate() async {
        handleActivationState(activationHub.currentState)
    }

    func refresh(clearActionError: Bool = true) {
        Task { [weak self] in
            await self?.reloadSessions(clearActionError: clearActionError)
        }
    }

    func kill(sessionID: String) {
        Task { [weak self] in
            await self?.performKill(sessionID: sessionID)
        }
    }

    func killAll() {
        Task { [weak self] in
            await self?.performKillAll()
        }
    }

    private func handleActivationState(_ state: ActiveWorkspaceActivationState) {
        switch state {
        case .idle, .closed:
            resetForProjectClose()
        case .opening:
            resetForProjectOpening()
        case .open:
            refresh(clearActionError: false)
        case .failed(_, _, let message):
            isLoading = false
            sessions = []
            actionError = nil
            availability = .failed(message)
        }
    }

    private func handleBridgeEvent(_ event: BridgeEvent) {
        guard let activeProjectID = currentProjectID else { return }
        guard let data = event.payloadJSON.data(using: .utf8) else { return }

        do {
            let payload = try PnevmaJSON.decoder().decode(SessionBridgePayload.self, from: data)
            guard payload.projectID == activeProjectID else { return }

            eventRevision += 1
            if let session = payload.session {
                upsert(session)
                availability = .ready
                isLoading = false
                return
            }

            if payload.sessionID != nil || payload.health != nil || payload.code != nil {
                refresh(clearActionError: false)
            }
        } catch {
            refresh(clearActionError: false)
        }
    }

    private func performKill(sessionID: String) async {
        guard let bus = commandBus else {
            availability = .failed("Session management is unavailable because the command bus is not configured.")
            return
        }

        do {
            let result: SessionKillResult = try await bus.call(
                method: "session.kill",
                params: SessionKillParams(sessionID: sessionID)
            )
            await reloadSessions(clearActionError: false)
            switch result.outcome {
            case "failed":
                actionError = result.message ?? "Failed to kill session."
            default:
                actionError = nil
            }
        } catch {
            actionError = "Failed to kill session: \(error.localizedDescription)"
            await reloadSessions(clearActionError: false)
        }
    }

    private func performKillAll() async {
        guard let bus = commandBus else {
            availability = .failed("Session management is unavailable because the command bus is not configured.")
            return
        }

        do {
            let result: SessionKillAllResult = try await bus.call(
                method: "session.kill_all",
                params: nil
            )
            await reloadSessions(clearActionError: false)
            if result.failed > 0 {
                let detail = result.failures.first?.message ?? "Failed to kill one or more sessions."
                actionError = "Failed to kill \(result.failed) session\(result.failed == 1 ? "" : "s"): \(detail)"
            } else {
                actionError = nil
            }
        } catch {
            actionError = "Failed to kill sessions: \(error.localizedDescription)"
            await reloadSessions(clearActionError: false)
        }
    }

    private func reloadSessions(clearActionError: Bool) async {
        guard let bus = commandBus else {
            isLoading = false
            sessions = []
            availability = .failed("Session management is unavailable because the command bus is not configured.")
            return
        }

        if clearActionError {
            actionError = nil
        }
        isLoading = true
        if sessions.isEmpty {
            availability = .loading("Loading sessions...")
        }
        var attempt = 0

        while true {
            guard let requestedProjectID = currentProjectID else {
                resetForProjectClose()
                return
            }
            let refreshRevision = eventRevision

            do {
                let result: [LiveSession] = try await bus.call(
                    method: "session.list_live",
                    params: nil
                )
                guard requestedProjectID == currentProjectID else {
                    return
                }

                if eventRevision != refreshRevision && attempt < 2 {
                    attempt += 1
                    continue
                }

                sessions = result.sorted { $0.startedAt > $1.startedAt }
                isLoading = false
                availability = .ready
                return
            } catch {
                guard requestedProjectID == currentProjectID else {
                    return
                }

                isLoading = false
                if PnevmaError.isProjectNotReady(error) {
                    resetForProjectClose()
                    return
                }

                if sessions.isEmpty {
                    availability = .failed(error.localizedDescription)
                } else {
                    actionError = error.localizedDescription
                    availability = .ready
                }
                return
            }
        }
    }

    private func resetForProjectOpening() {
        sessions = []
        isLoading = true
        actionError = nil
        availability = .loading("Waiting for project activation...")
    }

    private func resetForProjectClose() {
        sessions = []
        isLoading = false
        actionError = nil
        availability = .noProject("Open a project to manage sessions.")
    }

    private func upsert(_ session: LiveSession) {
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.startedAt > $1.startedAt }
    }
}
