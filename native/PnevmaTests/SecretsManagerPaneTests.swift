import XCTest
@testable import Pnevma

private actor SecretsManagerCommandBus: CommandCalling {
    private var listCallCountValue = 0

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
        switch method {
        case "project.secrets.list":
            listCallCountValue += 1
            return try decode(
                #"""
                [{
                  "id":"secret-1",
                  "project_id":"project-1",
                  "scope":"project",
                  "name":"OPENAI_API_KEY",
                  "backend":"keychain",
                  "location_display":"Keychain",
                  "status":"configured",
                  "status_message":null,
                  "created_at":"2026-03-14T10:00:00Z",
                  "updated_at":"2026-03-14T10:00:00Z"
                }]
                """#
            )
        default:
            throw NSError(domain: "SecretsManagerCommandBus", code: 1)
        }
    }

    func listCallCount() -> Int {
        listCallCountValue
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }
}

@MainActor
final class SecretsManagerPaneTests: XCTestCase {
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
        XCTFail("Timed out waiting for secrets-manager condition", file: file, line: line)
    }

    func testOpeningStateShowsWaitingMessageInsteadOfNoProjectState() async throws {
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = SecretsManagerViewModel(commandBus: nil, activationHub: activationHub)

        activationHub.update(.opening(workspaceID: UUID(), generation: 1))

        try await waitUntil {
            !viewModel.isProjectOpen
                && viewModel.projectStatusMessage == "Waiting for project activation..."
                && viewModel.secrets.isEmpty
        }
    }

    func testLoadsSecretsWhenProjectIsActive() async throws {
        let bus = SecretsManagerCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let bridgeHub = BridgeEventHub()
        activationHub.update(.open(workspaceID: UUID(), projectID: "project-1"))

        let viewModel = SecretsManagerViewModel(
            commandBus: bus,
            bridgeEventHub: bridgeHub,
            activationHub: activationHub
        )

        await viewModel.activate()

        try await waitUntil {
            await bus.listCallCount() == 1
                && viewModel.isProjectOpen
                && viewModel.projectStatusMessage == nil
                && viewModel.secrets.map(\.name) == ["OPENAI_API_KEY"]
        }
    }
}
