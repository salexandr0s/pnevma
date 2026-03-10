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

    func testAnalyticsAndDailyBriefContractsDecodeRepresentativePayloads() throws {
        let breakdown = try decoder.decode(
            [UsageBreakdown].self,
            from: Data(
                #"[{"provider":"anthropic","tokens_in":1200,"tokens_out":2400,"estimated_usd":1.25,"record_count":3}]"#.utf8
            )
        )
        XCTAssertEqual(breakdown.first?.recordCount, 3)

        let byModel = try decoder.decode(
            [UsageByModel].self,
            from: Data(
                #"[{"provider":"anthropic","model":"claude-sonnet","tokens_in":1200,"tokens_out":2400,"estimated_usd":1.25}]"#.utf8
            )
        )
        XCTAssertEqual(byModel.first?.model, "claude-sonnet")

        let trend = try decoder.decode(
            [UsageDailyTrend].self,
            from: Data(
                #"[{"date":"2026-03-08","tokens_in":1200,"tokens_out":2400,"estimated_usd":1.25}]"#.utf8
            )
        )
        XCTAssertEqual(trend.first?.date, "2026-03-08")

        let errors = try decoder.decode(
            [ErrorSignatureItem].self,
            from: Data(
                #"[{"id":"sig-1","signature_hash":"hash","canonical_message":"backend failed","category":"decode","first_seen":"2026-03-07T00:00:00Z","last_seen":"2026-03-08T00:00:00Z","total_count":2,"sample_output":"missing key","remediation_hint":"check contract"}]"#.utf8
            )
        )
        XCTAssertEqual(errors.first?.signatureHash, "hash")

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
