#![forbid(unsafe_code)]

pub mod error;
pub mod global_store;
pub mod models;
pub mod store;

pub use error::DbError;
pub use global_store::{sha256_hex, GlobalDb, RecentProjectRow, TrustRecord};
pub use models::{
    AgentHookRow, AgentPerformanceRow, AgentProfileRow, ArtifactRow, AttentionRuleRow,
    AutomationRetryRow, AutomationRunRow, CheckResultRow, CheckRunRow, CheckpointRow, CiJobRow,
    CiPipelineRow, ContextRuleUsageRow, CostDailyAggregateRow, CostHourlyAggregateRow, CostRow,
    DeploymentRow, EditorProfileRow, ErrorSignatureDailyRow, ErrorSignatureRow, EventRow,
    FeedbackRow, FleetSnapshotRow, GlobalAgentProfileRow, GlobalSshProfileRow, GlobalWorkflowRow,
    IntakeQueueRow, MergeQueueRow, NotificationRow, OnboardingStateRow, PaneLayoutTemplateRow,
    PaneRow, PortAllocationRow, PrCheckRunRow, ProjectRow, PullRequestRow, ReviewChecklistItemRow,
    ReviewCommentRow, ReviewFileRow, ReviewRow, RuleRow, SecretRefRow, SessionRestoreLogRow,
    SessionRow, SshProfileRow, StoryProgressRow, TaskExternalSourceRow, TaskLineageRow, TaskRow,
    TaskStoryRow, TelemetryEventRow, TelemetryMetricRow, WorkflowInstanceRow, WorkflowRow,
    WorkflowTaskRow, WorkspaceHookRunRow, WorktreeRow,
};
pub use store::{Db, EventQueryFilter, NewEvent};
