import XCTest
@testable import Pnevma

private struct UsagePaneAnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init(_ wrapped: Encodable) {
        encodeImpl = wrapped.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private actor MockUsageAnalyticsCommandBus: CommandCalling {
    private var methodHistory: [String] = []
    private var scopeHistoryByMethod: [String: [String]] = [:]
    private let summaryJSON: String
    private let diagnosticsJSON: String

    init(
        summaryJSON: String = #"{"scope":"global","from":"2026-03-01","to":"2026-03-08","totals":{"total_input_tokens":1200,"total_output_tokens":2400,"total_tokens":3600,"total_cost_usd":2.75,"avg_daily_cost_usd":0.34,"avg_daily_tokens":450,"active_sessions":2,"tasks_with_spend":3,"error_hotspot_count":1},"daily_trend":[{"date":"2026-03-08","tokens_in":1200,"tokens_out":2400,"estimated_usd":2.75}],"top_providers":[{"key":"claude","label":"claude","secondary_label":null,"total_tokens":3600,"estimated_usd":2.75,"record_count":3}],"top_models":[{"key":"claude-sonnet","label":"claude-sonnet","secondary_label":"claude","total_tokens":3600,"estimated_usd":2.75,"record_count":3}],"top_tasks":[{"project_name":"Pnevma","task_id":"task-1","title":"Ship usage pane","status":"Review","providers":["claude"],"models":["claude-sonnet"],"session_count":1,"total_input_tokens":1200,"total_output_tokens":2400,"total_tokens":3600,"total_cost_usd":2.75,"last_activity_at":"2026-03-08T00:05:00Z"}],"activity":{"weekdays":[{"index":0,"label":"Mon","total_tokens":1200,"estimated_usd":0.75}],"hours":[{"index":12,"label":"12:00","total_tokens":2400,"estimated_usd":2.0}]},"error_hotspots":[{"id":"err-1","signature_hash":"sig-1","canonical_message":"Build failed","category":"compiler","first_seen":"2026-03-08T00:00:00Z","last_seen":"2026-03-08T00:05:00Z","total_count":4,"sample_output":"error: bad","remediation_hint":"Run cargo check"}]}"#,
        diagnosticsJSON: String = #"{"scope":"global","from":"2026-03-01","to":"2026-03-08","project_names":["Pnevma"],"tracked_cost_rows":8,"untracked_cost_rows":2,"last_tracked_cost_at":"2026-03-08T00:05:00Z","local_provider_snapshots":[]}"#
    ) {
        self.summaryJSON = summaryJSON
        self.diagnosticsJSON = diagnosticsJSON
    }

    func call<T: Decodable & Sendable>(method: String, params: (any Encodable & Sendable)?) async throws -> T {
        methodHistory.append(method)
        let paramsJSON = try encodeParams(params)
        if let scope = paramsJSON["scope"] as? String {
            scopeHistoryByMethod[method, default: []].append(scope)
        }

        switch method {
        case "analytics.usage_summary":
            return try decode(summaryJSON)
        case "analytics.usage_sessions":
            return try decode(
                #"[{"project_name":"Pnevma","session_id":"session-1","session_name":"Codex Run","session_status":"running","branch":"task/usage","task_id":"task-1","task_title":"Ship usage pane","task_status":"Review","providers":["claude"],"models":["claude-sonnet"],"total_input_tokens":1200,"total_output_tokens":2400,"total_tokens":3600,"total_cost_usd":2.75,"started_at":"2026-03-08T00:00:00Z","last_heartbeat":"2026-03-08T00:05:00Z"}]"#
            )
        case "analytics.usage_tasks":
            return try decode(
                #"[{"project_name":"Pnevma","task_id":"task-1","title":"Ship usage pane","status":"Review","providers":["claude"],"models":["claude-sonnet"],"session_count":1,"total_input_tokens":1200,"total_output_tokens":2400,"total_tokens":3600,"total_cost_usd":2.75,"last_activity_at":"2026-03-08T00:05:00Z"}]"#
            )
        case "analytics.usage_diagnostics":
            return try decode(diagnosticsJSON)
        default:
            throw NSError(domain: "MockUsageAnalyticsCommandBus", code: 1)
        }
    }

    func methods() -> [String] {
        methodHistory
    }

    func scopes(for method: String) -> [String] {
        scopeHistoryByMethod[method, default: []]
    }

    private func decode<T: Decodable>(_ json: String) throws -> T {
        try PnevmaJSON.decoder().decode(T.self, from: Data(json.utf8))
    }

    private func encodeParams(_ params: Encodable?) throws -> [String: Any] {
        guard let params else { return [:] }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(UsagePaneAnyEncodable(params))
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}

@MainActor
final class AnalyticsPaneTests: XCTestCase {
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
        XCTFail("Timed out waiting for analytics-pane condition", file: file, line: line)
    }

    func testUsageViewModelLoadsGlobalAnalyticsWhenWorkspaceCloses() async throws {
        let bus = MockUsageAnalyticsCommandBus()
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = UsageViewModel(commandBus: bus, activationHub: activationHub)

        viewModel.setScope(.global)
        activationHub.update(.closed(workspaceID: nil))

        try await waitUntil {
            viewModel.summary?.scope == "global"
                && viewModel.sessions.count == 1
                && viewModel.tasks.count == 1
                && viewModel.statusMessage == nil
        }

        let methods = await bus.methods()
        XCTAssertTrue(methods.contains("analytics.usage_summary"))
        XCTAssertTrue(methods.contains("analytics.usage_sessions"))
        XCTAssertTrue(methods.contains("analytics.usage_tasks"))
        let usageScopes = await bus.scopes(for: "analytics.usage_summary")
        XCTAssertEqual(usageScopes.last, "global")
    }

    func testUsageRequestTimestampUsesLocalDayBounds() {
        let timeZone = TimeZone(identifier: "Europe/Vienna")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let date = calendar.date(from: DateComponents(
            year: 2026,
            month: 3,
            day: 11,
            hour: 12
        ))!

        XCTAssertEqual(
            usageRequestTimestamp(for: date, boundary: .start, calendar: calendar, timeZone: timeZone),
            "2026-03-11T00:00:00.000+01:00"
        )
        XCTAssertEqual(
            usageRequestTimestamp(for: date, boundary: .end, calendar: calendar, timeZone: timeZone),
            "2026-03-11T23:59:59.999+01:00"
        )
    }

    func testUsageViewModelPrefetchesDiagnosticsWhenTrackedUsageIsEmpty() async throws {
        let bus = MockUsageAnalyticsCommandBus(
            summaryJSON: #"{"scope":"global","from":"2026-03-01","to":"2026-03-08","totals":{"total_input_tokens":0,"total_output_tokens":0,"total_tokens":0,"total_cost_usd":0.0,"avg_daily_cost_usd":0.0,"avg_daily_tokens":0,"active_sessions":0,"tasks_with_spend":0,"error_hotspot_count":0},"daily_trend":[],"top_providers":[],"top_models":[],"top_tasks":[],"activity":{"weekdays":[],"hours":[]},"error_hotspots":[]}"#,
            diagnosticsJSON: #"{"scope":"global","from":"2026-03-01","to":"2026-03-08","project_names":["Pnevma"],"tracked_cost_rows":0,"untracked_cost_rows":0,"last_tracked_cost_at":null,"local_provider_snapshots":[{"provider":"claude","status":"ok","error_message":null,"days":[],"totals":{"total_input_tokens":100,"total_output_tokens":50,"total_cache_read_tokens":0,"total_cache_write_tokens":0,"total_requests":2,"avg_daily_tokens":50,"peak_day":"2026-03-08","peak_day_tokens":150},"top_models":[{"model":"claude-sonnet","tokens":150,"share_percent":100.0}]}]}"#
        )
        let activationHub = ActiveWorkspaceActivationHub()
        let viewModel = UsageViewModel(commandBus: bus, activationHub: activationHub)

        viewModel.setScope(.global)
        activationHub.update(.closed(workspaceID: nil))

        try await waitUntil {
            viewModel.summary != nil && viewModel.diagnostics != nil
        }

        let methods = await bus.methods()
        XCTAssertTrue(methods.contains("analytics.usage_diagnostics"))
        XCTAssertFalse(viewModel.hasTrackedUsageInWindow)
        XCTAssertEqual(viewModel.diagnostics?.trackedCostRows, 0)
    }

    func testSearchQueryChangeResetsExplorerPagination() {
        let viewModel = UsageViewModel(commandBus: nil, activationHub: ActiveWorkspaceActivationHub())
        viewModel.currentPage = 4

        viewModel.searchQuery = "workflow"

        XCTAssertEqual(viewModel.currentPage, 1)
    }

    func testPageSizeChangeResetsExplorerPagination() {
        let viewModel = UsageViewModel(commandBus: nil, activationHub: ActiveWorkspaceActivationHub())
        viewModel.currentPage = 3

        viewModel.pageSize = 100

        XCTAssertEqual(viewModel.currentPage, 1)
    }
}
