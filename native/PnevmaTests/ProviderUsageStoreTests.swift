import XCTest
@testable import Pnevma

private struct ProviderUsageAnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private actor MockProviderUsageCommandBus: CommandCalling {
    private(set) var methodHistory: [String] = []
    private(set) var forceRefreshHistory: [Bool] = []

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        methodHistory.append(method)
        let paramsJSON = try encodeParams(params)
        if method == "usage.providers.overview" {
            forceRefreshHistory.append((paramsJSON["force_refresh"] as? Bool) ?? false)
            return try decode(
                #"{"generated_at":"2026-03-11T12:00:00Z","refresh_interval_seconds":120,"stale_after_seconds":120,"providers":[{"provider":"codex","display_name":"Codex","status":"ok","status_message":null,"repair_hint":null,"source":"cli-rpc","account_email":"user@example.com","plan_label":"Pro","last_refreshed_at":"2026-03-11T12:00:00Z","session_window":{"label":"Current Session","percent_used":25.0,"percent_remaining":75.0,"reset_at":"2026-03-11T17:00:00Z"},"weekly_window":null,"model_windows":[],"credit":null,"local_usage":{"requests":10,"input_tokens":1200,"output_tokens":2400,"total_tokens":3600,"top_model":"gpt-5-codex","peak_day":"2026-03-10","peak_day_tokens":2100},"dashboard_extras":null},{"provider":"claude","display_name":"Claude","status":"warning","status_message":"OAuth unavailable","repair_hint":"Pnevma fell back to local Claude session usage only.","source":"local","account_email":null,"plan_label":null,"last_refreshed_at":"2026-03-11T12:00:00Z","session_window":null,"weekly_window":null,"model_windows":[],"credit":null,"local_usage":{"requests":2,"input_tokens":100,"output_tokens":50,"total_tokens":150,"top_model":"claude-sonnet","peak_day":"2026-03-09","peak_day_tokens":150},"dashboard_extras":null}]}"#
            )
        }
        if method == "usage.providers.settings.get" || method == "usage.providers.settings.set" {
            return try decode(
                #"{"refresh_interval_seconds":120,"codex":{"source":"auto","web_extras_enabled":false,"keychain_prompt_policy":"user_action","manual_cookie_configured":true},"claude":{"source":"oauth","web_extras_enabled":false,"keychain_prompt_policy":"always","manual_cookie_configured":false}}"#
            )
        }
        throw NSError(domain: "MockProviderUsageCommandBus", code: 1)
    }

    func methods() -> [String] {
        methodHistory
    }

    func forceRefreshes() -> [Bool] {
        forceRefreshHistory
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    private func encodeParams(_ params: Encodable?) throws -> [String: Any] {
        guard let params else { return [:] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(ProviderUsageAnyEncodable(params))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

@MainActor
final class ProviderUsageStoreTests: XCTestCase {
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
        XCTFail("Timed out waiting for provider-usage condition", file: file, line: line)
    }

    func testProviderUsageStoreLoadsOverviewAndComputesIndicatorState() async throws {
        let bus = MockProviderUsageCommandBus()
        let bridgeHub = BridgeEventHub()
        let store = ProviderUsageStore(commandBus: bus, bridgeEventHub: bridgeHub)

        await store.activate()

        try await waitUntil {
            store.providerSnapshots.count == 2 && store.errorMessage == nil
        }

        XCTAssertEqual(store.providerSnapshots.first?.provider, "codex")
        XCTAssertEqual(store.indicatorState, .warning)
        let methods = await bus.methods()
        XCTAssertTrue(methods.contains("usage.providers.overview"))
        XCTAssertTrue(methods.contains("usage.providers.settings.get"))
    }

    func testProviderUsageStoreDoesNotForceRefreshOnReactivationWhenWarningDataExists() async throws {
        let bus = MockProviderUsageCommandBus()
        let bridgeHub = BridgeEventHub()
        let store = ProviderUsageStore(commandBus: bus, bridgeEventHub: bridgeHub)

        await store.activate()
        try await waitUntil {
            store.providerSnapshots.count == 2
        }

        try await Task.sleep(nanoseconds: 50_000_000)
        await store.activate()

        let forceRefreshes = await bus.forceRefreshes()
        XCTAssertEqual(forceRefreshes, [false, false])
    }

    func testProviderUsageSettingsViewModelStoresGeneralSettings() async throws {
        let bus = MockProviderUsageCommandBus()
        let viewModel = ProviderUsageSettingsViewModel(commandBus: bus)
        viewModel.load()

        try await waitUntil {
            viewModel.codexSource == "auto" && viewModel.claudeSource == "oauth"
        }

        viewModel.refreshIntervalSeconds = 180
        viewModel.saveGeneralSettings()

        try await waitUntil {
            viewModel.statusMessage == "Saved"
        }

        let methods = await bus.methods()
        XCTAssertTrue(methods.contains("usage.providers.settings.set"))
    }
}
