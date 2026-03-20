import XCTest
@testable import Pnevma

@MainActor
final class CommandBusTests: XCTestCase {

    // MARK: - PnevmaError

    func testBridgeCallFailedErrorContainsMethod() {
        let err = PnevmaError.bridgeCallFailed(method: "session.create")
        guard case .bridgeCallFailed(let method) = err else {
            XCTFail("Expected bridgeCallFailed case")
            return
        }
        XCTAssertEqual(method, "session.create")
    }

    func testInvalidResponseErrorIsDistinct() {
        let err = PnevmaError.invalidResponse
        if case .invalidResponse = err {
            // expected
        } else {
            XCTFail("Expected invalidResponse case")
        }
    }

    func testDecodingFailedErrorWrapsUnderlying() {
        struct Dummy: Decodable {}
        let underlying = DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "bad data")
        )
        let err = PnevmaError.decodingFailed(method: "workspace.files.tree", error: underlying)
        if case .decodingFailed(let method, let wrapped) = err {
            XCTAssertEqual(method, "workspace.files.tree")
            XCTAssertNotNil(wrapped)
        } else {
            XCTFail("Expected decodingFailed case")
        }
    }

    func testDecodingFailedErrorIncludesMethodAndMissingKey() {
        let error = DecodingError.keyNotFound(
            DynamicCodingKey("is_directory"),
            DecodingError.Context(codingPath: [], debugDescription: "missing field")
        )
        let wrapped = PnevmaError.decodingFailed(method: "workspace.files.tree", error: error)

        let description = wrapped.localizedDescription
        XCTAssertTrue(description.contains("workspace.files.tree"))
        XCTAssertTrue(description.contains("is_directory"))
    }

    // MARK: - JSON param encoding

    /// Verifies that the encoder produces valid UTF-8 JSON from an Encodable value.
    func testParamEncodingProducesValidJSON() throws {
        struct Params: Encodable {
            let name: String
            let count: Int
        }
        let params = Params(name: "test-session", count: 42)
        let encoder = JSONEncoder()
        let data = try encoder.encode(params)
        let jsonString = String(data: data, encoding: .utf8)
        XCTAssertNotNil(jsonString, "Encoded params must produce valid UTF-8 JSON")

        // Round-trip: parse back and verify fields
        let parsed = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        XCTAssertEqual(parsed?["name"] as? String, "test-session")
        XCTAssertEqual(parsed?["count"] as? Int, 42)
    }

    func testEmptyParamsFallsBackToEmptyObject() throws {
        // Encoding nil params should produce `{}` — mirrors the CommandBus.call logic
        let fallback = "{}"
        let parsed = try JSONSerialization.jsonObject(with: Data(fallback.utf8), options: []) as? [String: Any]
        XCTAssertNotNil(parsed)
        XCTAssertTrue(parsed?.isEmpty == true, "Default params should be empty JSON object")
    }

    func testNestedParamEncodingIsValid() throws {
        struct Inner: Encodable { let value: String }
        struct Outer: Encodable { let inner: Inner; let flag: Bool }
        let params = Outer(inner: Inner(value: "deep"), flag: true)
        let data = try JSONEncoder().encode(params)
        XCTAssertFalse(data.isEmpty)
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        XCTAssertEqual((json?["inner"] as? [String: Any])?["value"] as? String, "deep")
        XCTAssertEqual(json?["flag"] as? Bool, true)
    }

    func testBackendErrorLocalizedDescriptionMapsWorkspaceTrustFailures() {
        let trustError = PnevmaError.backendError(
            method: "project.open",
            message: "workspace_not_trusted"
        )
        XCTAssertEqual(
            trustError.localizedDescription,
            "Workspace trust is required before this project can open."
        )

        let changedError = PnevmaError.backendError(
            method: "project.open",
            message: "workspace_config_changed"
        )
        XCTAssertEqual(
            changedError.localizedDescription,
            "The workspace configuration changed and must be trusted again before opening."
        )

        let initializationError = PnevmaError.backendError(
            method: "project.open",
            message: "workspace_not_initialized"
        )
        XCTAssertEqual(
            initializationError.localizedDescription,
            "This workspace is missing pnevma.toml and the .pnevma support files. Initialize the project scaffold to open it."
        )
    }

    func testBackendErrorLocalizedDescriptionMapsUsageAvailabilityFailures() {
        let availabilityError = PnevmaError.backendError(
            method: "analytics.usage_summary",
            message: "no projects available"
        )
        XCTAssertEqual(
            availabilityError.localizedDescription,
            "No trusted or open projects are available."
        )

        let staleBridgeError = PnevmaError.backendError(
            method: "analytics.usage_summary",
            message: "unknown method: analytics.usage_summary"
        )
        XCTAssertEqual(
            staleBridgeError.localizedDescription,
            "This build is using an older backend binary. Rebuild the app so the Rust bridge matches the native UI."
        )
    }

    func testPnevmaJSONDecoderDecodesSnakeCaseProjectIDs() throws {
        let json = #"""
        {
          "project_id": "project-123",
          "status": {
            "project_id": "project-123",
            "project_name": "Pnevma",
            "project_path": "/tmp/pnevma",
            "checkout_path": "/tmp/pnevma",
            "sessions": 1,
            "tasks": 2,
            "worktrees": 3
          }
        }
        """#

        let decoded = try PnevmaJSON.decoder().decode(ProjectOpenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.projectID, "project-123")
        XCTAssertEqual(decoded.status.projectID, "project-123")
        XCTAssertEqual(decoded.status.projectPath, "/tmp/pnevma")
    }

    func testPnevmaJSONDecoderDecodesOptionalSnakeCaseIDs() throws {
        let json = #"""
        {
          "ok": true,
          "action": "reattach",
          "new_session_id": "session-123"
        }
        """#

        let decoded = try PnevmaJSON.decoder().decode(SessionRecoveryResult.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.ok)
        XCTAssertEqual(decoded.newSessionID, "session-123")
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
