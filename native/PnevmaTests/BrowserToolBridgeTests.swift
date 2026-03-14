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

    func call<T: Decodable>(method: String, params: Encodable?) async throws -> T {
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
                payloadJSON: #"{"call_id":"call-1","tool_name":"browser.get_content","params":{}}"#
            )
        )

        for _ in 0..<20 {
            if await bus.recordedMethods().contains("browser.tool_result") {
                break
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        let methods = await bus.recordedMethods()
        let paramsJSON = await bus.recordedParamsJSON()

        XCTAssertEqual(methods, ["browser.tool_result"])
        XCTAssertTrue(paramsJSON.first?.contains("\"call_id\":\"call-1\"") == true)
        XCTAssertTrue(paramsJSON.first?.contains("no active browser page") == true)
    }
}
