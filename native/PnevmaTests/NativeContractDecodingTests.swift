import XCTest
@testable import Pnevma

@MainActor
final class NativeContractDecodingTests: XCTestCase {
    private let decoder = PnevmaJSON.decoder()

    func testWorkflowContractsDecodeRepresentativePayloads() throws {
        let workflowDefs = try decoder.decode(
            [WorkflowDefItem].self,
            from: Data(
                #"[{"id":"wf-1","name":"Ship","description":"Release workflow","source":"user","steps":[{"title":"Build","goal":"Compile the app","scope":["native/"],"priority":"P1","depends_on":[],"auto_dispatch":true,"agent_profile":"swift","execution_mode":"worktree","timeout_minutes":30,"max_retries":1,"acceptance_criteria":["build passes"],"constraints":["no force push"],"on_failure":"Pause"}]}]"#.utf8
            )
        )
        XCTAssertEqual(workflowDefs.first?.dbId, "wf-1")
        XCTAssertEqual(workflowDefs.first?.steps?.first?.executionMode, "worktree")

        let workflowInstances = try decoder.decode(
            [WorkflowInstanceItem].self,
            from: Data(
                #"[{"id":"instance-1","workflow_name":"Ship","description":null,"status":"running","task_ids":["task-1"],"created_at":"2026-03-08T00:00:00Z","updated_at":"2026-03-08T00:05:00Z"}]"#.utf8
            )
        )
        XCTAssertEqual(workflowInstances.first?.taskIds, ["task-1"])

        let workflowDetail = try decoder.decode(
            WorkflowInstanceDetail.self,
            from: Data(
                #"{"id":"instance-1","workflow_name":"Ship","description":null,"status":"running","steps":[{"step_index":0,"iteration":0,"task_id":"task-1","title":"Build","goal":"Compile","status":"running","priority":"P1","depends_on":[],"agent_profile":"swift","execution_mode":"worktree","branch":"task/build","created_at":"2026-03-08T00:00:00Z","updated_at":"2026-03-08T00:05:00Z"}],"created_at":"2026-03-08T00:00:00Z","updated_at":"2026-03-08T00:05:00Z"}"#.utf8
            )
        )
        XCTAssertEqual(workflowDetail.steps.first?.taskId, "task-1")
    }

    func testUsageAnalyticsAndDailyBriefContractsDecodeRepresentativePayloads() throws {
        let providerOverview = try decoder.decode(
            ProviderUsageOverview.self,
            from: Data(
                #"{"generated_at":"2026-03-11T12:00:00Z","refresh_interval_seconds":120,"stale_after_seconds":120,"providers":[{"provider":"codex","display_name":"Codex","status":"ok","status_message":null,"repair_hint":null,"source":"cli-rpc","account_email":"user@example.com","plan_label":"Pro","last_refreshed_at":"2026-03-11T12:00:00Z","session_window":{"label":"Current Session","percent_used":25.0,"percent_remaining":75.0,"reset_at":"2026-03-11T17:00:00Z"},"weekly_window":{"label":"Current Week","percent_used":40.0,"percent_remaining":60.0,"reset_at":"2026-03-15T23:00:00Z"},"model_windows":[],"credit":{"label":"Credits","balance_display":"42.50","is_unlimited":false},"local_usage":{"requests":10,"input_tokens":1200,"output_tokens":2400,"total_tokens":3600,"top_model":"gpt-5-codex","peak_day":"2026-03-10","peak_day_tokens":2100},"dashboard_extras":null}]}"#.utf8
            )
        )
        XCTAssertEqual(providerOverview.providers.first?.provider, "codex")
        XCTAssertEqual(providerOverview.providers.first?.credit?.balanceDisplay, "42.50")
        XCTAssertEqual(providerOverview.providers.first?.localUsage.totalTokens, 3600)

        let providerSettings = try decoder.decode(
            ProviderUsageSettingsSnapshot.self,
            from: Data(
                #"{"refresh_interval_seconds":120,"codex":{"source":"auto","web_extras_enabled":false,"keychain_prompt_policy":"user_action","manual_cookie_configured":true},"claude":{"source":"oauth","web_extras_enabled":true,"keychain_prompt_policy":"always","manual_cookie_configured":false}}"#.utf8
            )
        )
        XCTAssertEqual(providerSettings.refreshIntervalSeconds, 120)
        XCTAssertEqual(providerSettings.codex.source, "auto")
        XCTAssertTrue(providerSettings.codex.manualCookieConfigured)

        let usageSnapshots = try decoder.decode(
            [ProviderUsageSnapshot].self,
            from: Data(
                #"[{"provider":"claude","status":"ok","error_message":null,"days":[{"date":"2026-03-08","input_tokens":1200,"output_tokens":2400,"cache_read_tokens":300,"cache_write_tokens":50,"requests":3}],"totals":{"total_input_tokens":1200,"total_output_tokens":2400,"total_cache_read_tokens":300,"total_cache_write_tokens":50,"total_requests":3,"avg_daily_tokens":3600,"peak_day":"2026-03-08","peak_day_tokens":3600},"top_models":[{"model":"claude-sonnet","tokens":3600,"share_percent":100.0}]}]"#.utf8
            )
        )
        XCTAssertEqual(usageSnapshots.first?.provider, "claude")
        XCTAssertEqual(usageSnapshots.first?.totals.totalRequests, 3)
        XCTAssertEqual(usageSnapshots.first?.days.first?.inputTokens, 1200)
        XCTAssertEqual(usageSnapshots.first?.topModels.first?.model, "claude-sonnet")

        let usageSummary = try decoder.decode(
            UsageAnalyticsSummary.self,
            from: Data(
                #"{"scope":"project","from":"2026-03-01","to":"2026-03-08","totals":{"total_input_tokens":1200,"total_output_tokens":2400,"total_tokens":3600,"total_cost_usd":2.75,"avg_daily_cost_usd":0.34,"avg_daily_tokens":450,"active_sessions":2,"tasks_with_spend":3,"error_hotspot_count":1},"daily_trend":[{"date":"2026-03-08","tokens_in":1200,"tokens_out":2400,"estimated_usd":2.75}],"top_providers":[{"key":"claude","label":"claude","secondary_label":null,"total_tokens":3600,"estimated_usd":2.75,"record_count":3}],"top_models":[{"key":"claude-sonnet","label":"claude-sonnet","secondary_label":"claude","total_tokens":3600,"estimated_usd":2.75,"record_count":3}],"top_tasks":[{"project_name":"Pnevma","task_id":"task-1","title":"Ship usage pane","status":"Review","providers":["claude"],"models":["claude-sonnet"],"session_count":1,"total_input_tokens":1200,"total_output_tokens":2400,"total_tokens":3600,"total_cost_usd":2.75,"last_activity_at":"2026-03-08T00:05:00Z"}],"activity":{"weekdays":[{"index":0,"label":"Mon","total_tokens":1200,"estimated_usd":0.75}],"hours":[{"index":12,"label":"12:00","total_tokens":2400,"estimated_usd":2.0}]},"error_hotspots":[{"id":"err-1","signature_hash":"sig-1","canonical_message":"Build failed","category":"compiler","first_seen":"2026-03-08T00:00:00Z","last_seen":"2026-03-08T00:05:00Z","total_count":4,"sample_output":"error: bad","remediation_hint":"Run cargo check"}]}"#.utf8
            )
        )
        XCTAssertEqual(usageSummary.scope, "project")
        XCTAssertEqual(usageSummary.totals.totalTokens, 3600)
        XCTAssertEqual(usageSummary.topTasks.first?.title, "Ship usage pane")
        XCTAssertEqual(usageSummary.activity.hours.first?.index, 12)

        let sessionRows = try decoder.decode(
            [UsageSessionAnalyticsRow].self,
            from: Data(
                #"[{"project_name":"Pnevma","session_id":"session-1","session_name":"Codex Run","session_status":"running","branch":"task/usage","task_id":"task-1","task_title":"Ship usage pane","task_status":"Review","providers":["claude"],"models":["claude-sonnet"],"total_input_tokens":1200,"total_output_tokens":2400,"total_tokens":3600,"total_cost_usd":2.75,"started_at":"2026-03-08T00:00:00Z","last_heartbeat":"2026-03-08T00:05:00Z"}]"#.utf8
            )
        )
        XCTAssertEqual(sessionRows.first?.sessionID, "session-1")
        XCTAssertEqual(sessionRows.first?.providers, ["claude"])

        let diagnostics = try decoder.decode(
            UsageDiagnostics.self,
            from: Data(
                #"{"scope":"global","from":"2026-03-01","to":"2026-03-08","project_names":["Pnevma","ClawControl"],"tracked_cost_rows":8,"untracked_cost_rows":2,"last_tracked_cost_at":"2026-03-08T00:05:00Z","local_provider_snapshots":[{"provider":"codex","status":"no_data","error_message":null,"days":[],"totals":{"total_input_tokens":0,"total_output_tokens":0,"total_cache_read_tokens":0,"total_cache_write_tokens":0,"total_requests":0,"avg_daily_tokens":0,"peak_day":null,"peak_day_tokens":0},"top_models":[]}]}"#.utf8
            )
        )
        XCTAssertEqual(diagnostics.projectNames.count, 2)
        XCTAssertEqual(diagnostics.localProviderSnapshots.first?.status, "no_data")

        let brief = try decoder.decode(
            DailyBrief.self,
            from: Data(
                #"{"generated_at":"2026-03-08T00:00:00Z","total_tasks":4,"ready_tasks":1,"review_tasks":1,"blocked_tasks":1,"failed_tasks":1,"total_cost_usd":2.5,"recent_events":[{"timestamp":"2026-03-08T00:00:00Z","kind":"TaskCompleted","summary":"Build complete","payload":{"task_id":"task-1"}}],"recommended_actions":["Review task-1"],"active_sessions":2,"cost_last_24h_usd":1.5,"tasks_completed_last_24h":3,"tasks_failed_last_24h":1,"stale_ready_count":0,"longest_running_task":null,"top_cost_tasks":[{"task_id":"task-1","title":"Build","cost_usd":1.25}]}"#.utf8
            )
        )
        XCTAssertEqual(brief.topCostTasks.first?.taskId, "task-1")
    }

    func testMergeQueueAndRulesContractsDecodeRepresentativePayloads() throws {
        let mergeQueue = try decoder.decode(
            [MergeQueueItem].self,
            from: Data(
                #"[{"id":"mq-1","task_id":"task-1","task_title":"Ship fix","status":"Queued","blocked_reason":null,"approved_at":"2026-03-08T00:00:00Z","started_at":null,"completed_at":null}]"#.utf8
            )
        )
        XCTAssertEqual(mergeQueue.first?.taskId, "task-1")

        let rules = try decoder.decode(
            [ProjectRule].self,
            from: Data(
                #"[{"id":"rule-1","name":"No force push","path":"rules/no-force-push.md","scope":"rule","active":true,"content":"Never force push."}]"#.utf8
            )
        )
        XCTAssertEqual(rules.first?.scope, "rule")
    }

    func testCommandCenterContractsDecodeWorktreeFileFallbacks() throws {
        let snapshot = try decoder.decode(
            CommandCenterSnapshot.self,
            from: Data(
                #"{"project_id":"project-1","project_name":"Pnevma","project_path":"/tmp/pnevma","generated_at":"2026-03-14T08:00:00Z","summary":{"active_count":1,"queued_count":0,"idle_count":0,"stuck_count":0,"review_needed_count":0,"failed_count":0,"retrying_count":0,"slot_limit":4,"slot_in_use":1,"cost_today_usd":1.25},"runs":[{"id":"run-1","task_id":"task-1","task_title":"Scoped task","task_status":"InProgress","session_id":"session-1","session_name":"Agent","session_status":"running","session_health":"active","provider":"codex","model":"gpt-5","agent_profile":"default","branch":"task/scoped","worktree_id":"wt-1","primary_file_path":"src/main.rs","scope_paths":["src/main.rs"],"worktree_path":"worktrees/task-scoped","state":"running","started_at":"2026-03-14T07:55:00Z","last_activity_at":"2026-03-14T07:59:00Z","retry_count":0,"cost_usd":0.5,"tokens_in":100,"tokens_out":200,"available_actions":["open_files"]},{"id":"run-2","task_id":"task-2","task_title":"Worktree task","task_status":"Review","session_id":null,"session_name":null,"session_status":null,"session_health":null,"provider":"codex","model":"gpt-5","agent_profile":"default","branch":"task/worktree","worktree_id":"wt-2","primary_file_path":null,"scope_paths":[],"worktree_path":"worktrees/task-worktree","state":"review_needed","started_at":"2026-03-14T07:40:00Z","last_activity_at":"2026-03-14T07:58:00Z","retry_count":0,"cost_usd":0.75,"tokens_in":150,"tokens_out":300,"available_actions":["open_files"]}]}"#.utf8
            )
        )

        XCTAssertEqual(snapshot.runs.first?.relatedFilesPath, "src/main.rs")
        XCTAssertEqual(snapshot.runs.last?.worktreePath, "worktrees/task-worktree")
        XCTAssertEqual(snapshot.runs.last?.relatedFilesPath, "worktrees/task-worktree")
    }
}
