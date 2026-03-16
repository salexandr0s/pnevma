import XCTest
@testable import Pnevma

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ value: some Encodable) {
        self.encodeImpl = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private actor BrowserToolBridgeCommandBus: CommandCalling {
    private(set) var methods: [String] = []
    private(set) var paramsJSON: [String] = []

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        methods.append(method)
        if let params {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(AnyEncodable(params))
            paramsJSON.append(String(decoding: data, as: UTF8.self))
        } else {
            paramsJSON.append("{}")
        }

        let data = Data(#"{"ok":true}"#.utf8)
        return try PnevmaJSON.decoder().decode(T.self, from: data)
    }

    func recordedMethods() -> [String] { methods }
    func recordedParamsJSON() -> [String] { paramsJSON }
}

@MainActor
final class BrowserToolBridgeTests: XCTestCase {
    func testBridgeReturnsErrorResultWhenNoBrowserSessionIsAvailable() async throws {
        for toolName in [
            "browser.get_content",
            "browser.copy_selection",
            "browser.save_markdown",
            "browser.copy_link_list",
        ] {
            let (methods, paramsJSON) = try await invokeToolWithoutSession(toolName: toolName)
            XCTAssertEqual(methods, ["browser.tool_result"], "toolName=\(toolName)")
            XCTAssertTrue(paramsJSON.first?.contains("\"call_id\":\"call-1\"") == true, "toolName=\(toolName)")
            XCTAssertTrue(paramsJSON.first?.contains("no active browser page") == true, "toolName=\(toolName)")
        }
    }

    private func invokeToolWithoutSession(
        toolName: String
    ) async throws -> ([String], [String]) {
        let hub = BridgeEventHub()
        let bus = BrowserToolBridgeCommandBus()
        let bridge = BrowserToolBridge(
            bridgeEventHub: hub,
            sessionProvider: { nil },
            commandBusProvider: { bus },
            ensureBrowserVisible: { _ in }
        )
        withExtendedLifetime(bridge) {}

        hub.post(
            BridgeEvent(
                name: "browser_tool_request",
                payloadJSON: #"{"call_id":"call-1","tool_name":"\#(toolName)","params":{}}"#
            )
        )

        for _ in 0..<20 {
            if await bus.recordedMethods().contains("browser.tool_result") {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        return (await bus.recordedMethods(), await bus.recordedParamsJSON())
    }
}
