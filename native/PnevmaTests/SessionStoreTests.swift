import XCTest
@testable import Pnevma

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private actor MockSessionCommandBus: CommandCalling {
    enum KillBehavior {
        case killed
        case alreadyGone
        case failed(String)
    }

    private var liveSessions: [LiveSession]
    private var listError: Error?
    private var killBehaviors: [String: KillBehavior] = [:]

    init(sessions: [LiveSession], listError: Error? = nil) {
        liveSessions = sessions
        self.listError = listError
    }

    func setSessions(_ sessions: [LiveSession]) {
        liveSessions = sessions
    }

    func setKillBehavior(for sessionID: String, behavior: KillBehavior) {
        killBehaviors[sessionID] = behavior
    }

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
        switch method {
        case "session.list_live":
            if let listError {
                throw listError
            }
            return liveSessions as! T
        case "session.kill":
            let json = try encodeParams(params)
            let sessionID = json["session_id"] as? String ?? json["sessionID"] as? String ?? ""
            let behavior = killBehaviors[sessionID] ?? .killed
            switch behavior {
            case .killed:
                completeSession(sessionID, exitCode: -9)
                return SessionKillResult(
                    sessionID: sessionID,
                    outcome: "killed",
                    message: nil
                ) as! T
            case .alreadyGone:
                completeSession(sessionID, exitCode: nil)
                return SessionKillResult(
                    sessionID: sessionID,
                    outcome: "already_gone",
                    message: nil
                ) as! T
            case .failed(let message):
                return SessionKillResult(
                    sessionID: sessionID,
                    outcome: "failed",
                    message: message
                ) as! T
            }
        case "session.kill_all":
            var requested = 0
            var killed = 0
            var alreadyGone = 0
            var failures: [SessionKillFailure] = []

            for session in liveSessions where session.isActionable {
                requested += 1
                switch killBehaviors[session.id] ?? .killed {
                case .killed:
                    killed += 1
                    completeSession(session.id, exitCode: -9)
                case .alreadyGone:
                    alreadyGone += 1
                    completeSession(session.id, exitCode: nil)
                case .failed(let message):
                    failures.append(SessionKillFailure(sessionID: session.id, message: message))
                }
            }

            return SessionKillAllResult(
                requested: requested,
                killed: killed,
                alreadyGone: alreadyGone,
                failed: failures.count,
                failures: failures
            ) as! T
        default:
            throw NSError(domain: "MockSessionCommandBus", code: 1)
        }
    }

    private func encodeParams(_ params: Encodable?) throws -> [String: Any] {
        guard let params else { return [:] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(AnyEncodable(params))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func completeSession(_ sessionID: String, exitCode: Int?) {
        guard let idx = liveSessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let current = liveSessions[idx]
        liveSessions[idx] = LiveSession(
            id: current.id,
            name: current.name,
            status: "complete",
            health: "complete",
            pid: nil,
            cwd: current.cwd,
            command: current.command,
            startedAt: current.startedAt,
            lastHeartbeat: "2026-03-07T12:00:00Z",
            exitCode: exitCode,
            endedAt: "2026-03-07T12:00:00Z"
        )
    }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    private func waitUntil(
        timeoutNanos: UInt64 = 1_000_000_000,
        pollIntervalNanos: UInt64 = 10_000_000,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () async -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        while DispatchTime.now().uptimeNanoseconds < deadline {
            if await condition() {
                return
            }
            try await Task.sleep(nanoseconds: pollIntervalNanos)
        }
        XCTFail("Timed out waiting for session-store condition", file: file, line: line)
    }

    func testActivateLoadsSessionsNewestFirst() async throws {
        let older = LiveSession(
            id: "session-1",
            name: "Older",
            status: "running",
            health: "active",
            pid: 11,
            cwd: "/tmp/one",
            command: "zsh",
            startedAt: "2026-03-07T10:00:00Z",
            lastHeartbeat: "2026-03-07T10:00:00Z",
            exitCode: nil,
            endedAt: nil
        )
        let newer = LiveSession(
            id: "session-2",
            name: "Newer",
            status: "waiting",
            health: "waiting",
            pid: 22,
            cwd: "/tmp/two",
            command: "zsh",
            startedAt: "2026-03-07T11:00:00Z",
            lastHeartbeat: "2026-03-07T11:00:00Z",
            exitCode: nil,
            endedAt: nil
        )
        let bus = MockSessionCommandBus(sessions: [older, newer])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let store = SessionStore(commandBus: bus, bridgeEventHub: bridgeHub, activationHub: activationHub)

        await store.activate()
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            store.sessions.count == 2 && store.activeCount == 2
        }

        XCTAssertEqual(store.sessions.map(\.id), ["session-2", "session-1"])
    }

    func testNoOpenProjectBecomesNoProjectState() async throws {
        let bus = MockSessionCommandBus(
            sessions: [],
            listError: PnevmaError.backendError(
                method: "session.list_live",
                message: "no open project"
            )
        )
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let store = SessionStore(commandBus: bus, bridgeEventHub: bridgeHub, activationHub: activationHub)

        await store.activate()
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            if case .noProject = store.availability {
                return true
            }
            return false
        }

        XCTAssertTrue(store.sessions.isEmpty)
    }

    func testFailedKillRefreshesButKeepsRunningSessionVisible() async throws {
        let session = LiveSession(
            id: "session-1",
            name: "Primary",
            status: "running",
            health: "active",
            pid: 11,
            cwd: "/tmp/one",
            command: "zsh",
            startedAt: "2026-03-07T10:00:00Z",
            lastHeartbeat: "2026-03-07T10:00:00Z",
            exitCode: nil,
            endedAt: nil
        )
        let bus = MockSessionCommandBus(sessions: [session])
        await bus.setKillBehavior(for: session.id, behavior: .failed("permission denied"))
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let store = SessionStore(commandBus: bus, bridgeEventHub: bridgeHub, activationHub: activationHub)

        await store.activate()
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            store.sessions.count == 1
        }

        store.kill(sessionID: session.id)

        try await waitUntil {
            store.actionError != nil
        }

        XCTAssertEqual(store.sessions.first?.status, "running")
    }

    func testSessionSpawnedEventUpsertsSession() async throws {
        let bus = MockSessionCommandBus(sessions: [])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let store = SessionStore(commandBus: bus, bridgeEventHub: bridgeHub, activationHub: activationHub)
        let projectID = "project-1"

        await store.activate()
        activationHub.update(.open(workspaceID: UUID(), projectID: projectID))

        try await waitUntil {
            if case .ready = store.availability {
                return store.sessions.isEmpty
            }
            return false
        }

        bridgeHub.post(
            BridgeEvent(
                name: "session_spawned",
                payloadJSON: """
                {
                  "project_id": "\(projectID)",
                  "session_id": "session-3",
                  "session": {
                    "id": "session-3",
                    "name": "Event Session",
                    "status": "running",
                    "health": "active",
                    "pid": 77,
                    "cwd": "/tmp/event",
                    "command": "zsh",
                    "started_at": "2026-03-07T12:00:00Z",
                    "last_heartbeat": "2026-03-07T12:00:00Z",
                    "exit_code": null,
                    "ended_at": null
                  }
                }
                """
            )
        )

        try await waitUntil {
            store.sessions.count == 1 && store.activeCount == 1
        }

        XCTAssertEqual(store.sessions.first?.id, "session-3")
    }

    func testOpeningWorkspaceClearsPreviousProjectSessions() async throws {
        let projectASession = LiveSession(
            id: "session-a",
            name: "Project A",
            status: "running",
            health: "active",
            pid: 11,
            cwd: "/tmp/project-a",
            command: "zsh",
            startedAt: "2026-03-07T10:00:00Z",
            lastHeartbeat: "2026-03-07T10:00:00Z",
            exitCode: nil,
            endedAt: nil
        )
        let projectBSession = LiveSession(
            id: "session-b",
            name: "Project B",
            status: "running",
            health: "active",
            pid: 22,
            cwd: "/tmp/project-b",
            command: "zsh",
            startedAt: "2026-03-07T11:00:00Z",
            lastHeartbeat: "2026-03-07T11:00:00Z",
            exitCode: nil,
            endedAt: nil
        )
        let bus = MockSessionCommandBus(sessions: [projectASession])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let store = SessionStore(commandBus: bus, bridgeEventHub: bridgeHub, activationHub: activationHub)

        await store.activate()
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-a"))

        try await waitUntil {
            store.sessions.map(\.id) == ["session-a"]
        }

        await bus.setSessions([projectBSession])
        activationHub.update(.opening(workspaceID: UUID(), generation: 2))

        try await waitUntil {
            store.sessions.isEmpty && store.isLoading
        }

        activationHub.update(.open(workspaceID: UUID(), projectID: "project-b"))

        try await waitUntil {
            store.sessions.map(\.id) == ["session-b"] && store.activeCount == 1
        }
    }

    func testIgnoresSessionEventsFromInactiveProject() async throws {
        let bus = MockSessionCommandBus(sessions: [])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let store = SessionStore(commandBus: bus, bridgeEventHub: bridgeHub, activationHub: activationHub)

        await store.activate()
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-b"))

        try await waitUntil {
            if case .ready = store.availability {
                return store.sessions.isEmpty
            }
            return false
        }

        bridgeHub.post(
            BridgeEvent(
                name: "session_spawned",
                payloadJSON: """
                {
                  "project_id": "project-a",
                  "session_id": "session-a",
                  "session": {
                    "id": "session-a",
                    "name": "Late Session",
                    "status": "running",
                    "health": "active",
                    "pid": 77,
                    "cwd": "/tmp/project-a",
                    "command": "zsh",
                    "started_at": "2026-03-07T12:00:00Z",
                    "last_heartbeat": "2026-03-07T12:00:00Z",
                    "exit_code": null,
                    "ended_at": null
                  }
                }
                """
            )
        )

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertEqual(store.activeCount, 0)
    }

    func testProjectCloseClearsSessionsImmediately() async throws {
        let session = LiveSession(
            id: "session-1",
            name: "Primary",
            status: "running",
            health: "active",
            pid: 11,
            cwd: "/tmp/one",
            command: "zsh",
            startedAt: "2026-03-07T10:00:00Z",
            lastHeartbeat: "2026-03-07T10:00:00Z",
            exitCode: nil,
            endedAt: nil
        )
        let bus = MockSessionCommandBus(sessions: [session])
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        let store = SessionStore(commandBus: bus, bridgeEventHub: bridgeHub, activationHub: activationHub)

        await store.activate()
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        try await waitUntil {
            store.sessions.count == 1
        }

        activationHub.update(.closed(workspaceID: UUID()))

        try await waitUntil {
            store.sessions.isEmpty
        }

        XCTAssertEqual(store.activeCount, 0)
    }
}
