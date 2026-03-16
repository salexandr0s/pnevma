import AppKit
import XCTest
@testable import Pnevma

private struct AnyEncodableSecrets: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private struct SecretsDeletePayload: Decodable {
    let id: String
}

private actor SecretsManagerCommandBus: CommandCalling {
    private var secrets: [ProjectSecret]
    private var listCallCountValue = 0

    init(secrets: [ProjectSecret]) {
        self.secrets = secrets
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        switch method {
        case "project.secrets.list":
            listCallCountValue += 1
            return try decode(encode(secrets))
        case "project.secrets.delete":
            let payload = try decodeParams(SecretsDeletePayload.self, params: params)
            secrets.removeAll { $0.id == payload.id }
            return try decode(#"{"ok":true}"#)
        default:
            throw NSError(domain: "SecretsManagerCommandBus", code: 1)
        }
    }

    func listCallCount() -> Int {
        listCallCountValue
    }

    func currentSecrets() -> [ProjectSecret] {
        secrets
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    private func decodeParams<T: Decodable>(_ type: T.Type, params: Encodable?) throws -> T {
        guard let params else {
            throw NSError(domain: "SecretsManagerCommandBus", code: 2)
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(AnyEncodableSecrets(params))
        return try PnevmaJSON.decoder().decode(T.self, from: data)
    }
}

@MainActor
final class SecretsManagerPaneTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

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

    private func makeSecret(
        id: String,
        scope: String,
        name: String,
        backend: String = "keychain",
        locationDisplay: String? = nil
    ) -> ProjectSecret {
        ProjectSecret(
            id: id,
            projectID: scope == "global" ? nil : "project-1",
            scope: scope,
            name: name,
            backend: backend,
            locationDisplay: locationDisplay ?? (backend == "keychain" ? "Keychain" : ".env.local"),
            status: "configured",
            statusMessage: nil,
            createdAt: Date(timeIntervalSince1970: 1_710_410_400),
            updatedAt: Date(timeIntervalSince1970: 1_710_410_400)
        )
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
        let bus = SecretsManagerCommandBus(secrets: [
            makeSecret(id: "secret-1", scope: "project", name: "OPENAI_API_KEY")
        ])
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

    func testListPresentationOrdersProjectSectionBeforeGlobalSection() {
        let presentation = SecretsListPresentation(secrets: [
            makeSecret(id: "global-1", scope: "global", name: "DATABASE_URL"),
            makeSecret(id: "project-1", scope: "project", name: "DATABASE_URL"),
        ])

        XCTAssertEqual(presentation.orderedSections, [.project, .global])
        XCTAssertEqual(presentation.projectSecrets.map(\.id), ["project-1"])
        XCTAssertEqual(presentation.globalSecrets.map(\.id), ["global-1"])
        XCTAssertTrue(presentation.hasShadowedGlobals)
    }

    func testDeletingProjectSecretReloadsAndRevealsGlobalFallback() async throws {
        let bus = SecretsManagerCommandBus(secrets: [
            makeSecret(id: "project-1", scope: "project", name: "DATABASE_URL"),
            makeSecret(id: "global-1", scope: "global", name: "DATABASE_URL"),
        ])
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
            await bus.listCallCount() == 1 && viewModel.secrets.count == 2
        }

        let projectSecret = try XCTUnwrap(viewModel.secrets.first { $0.scope == "project" })
        viewModel.deleteSecret(projectSecret)

        try await waitUntil {
            let names = viewModel.secrets.map(\.id)
            let busSecretIDs = await bus.currentSecrets().map(\.id)
            return names == ["global-1"] && busSecretIDs == ["global-1"]
        }
    }

    func testGlobalEditDraftDisablesStorageSelectionAndShowsKeychainHelper() {
        let draft = SecretEditorDraft(
            id: "global-1",
            name: "OPENAI_API_KEY",
            scope: "global",
            backend: "keychain",
            replacementValue: "",
            isEditing: true
        )

        XCTAssertTrue(draft.storageSelectionDisabled)
        XCTAssertEqual(draft.storageHelperText, "Global secrets are always stored in Keychain.")
        XCTAssertEqual(
            draft.valueHelperText,
            "Existing secret values are never shown again. Leave the field blank to keep the current value."
        )
        XCTAssertEqual(draft.backendHelperText, "Keychain-backed secrets stay out of the project working tree.")
    }

    func testNarrowHeaderLayoutUsesCompactOverflowMode() {
        XCTAssertEqual(SecretsHeaderActionLayout.from(width: 520), .compact)
        XCTAssertEqual(SecretsHeaderActionLayout.from(width: 980), .expanded)
    }
}
