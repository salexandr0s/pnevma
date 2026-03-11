import XCTest
@testable import Pnevma

final class NativeContractDecodingTests: XCTestCase {
    private let decoder = PnevmaJSON.decoder()

    func testSearchAndWorkflowContractsDecodeRepresentativePayloads() throws {
        let searchResults = try decoder.decode(
            [SearchResult].self,
            from: Data(
                #"[{"id":"result-1","source":"file","title":"lib.rs","snippet":"pub fn tree() {}","path":"src/lib.rs","task_id":null,"session_id":null,"timestamp":"2026-03-08T00:00:00Z"}]"#.utf8
            )
        )
        XCTAssertEqual(searchResults.first?.filePath, "src/lib.rs")

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

    func testUsageSnapshotAndDailyBriefContractsDecodeRepresentativePayloads() throws {
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
}
