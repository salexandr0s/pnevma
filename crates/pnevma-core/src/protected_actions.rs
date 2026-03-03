use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RiskLevel {
    Safe,
    Caution,
    Danger,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ActionKind {
    MergeToTarget,
    DeleteWorktreeWithChanges,
    ForcePush,
    DeleteTaskWithActiveSession,
    PurgeScrollback,
    RestartStuckAgent,
    DiscardReview,
    RedispatchFailedTask,
    BulkDeleteCompletedTasks,
    CreateTask,
    DispatchReadyTask,
    OpenPane,
    CreateCheckpoint,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ActionRiskInfo {
    pub kind: ActionKind,
    pub risk_level: RiskLevel,
    pub description: String,
    pub consequences: Vec<String>,
    pub confirmation_phrase: Option<String>,
}

impl ActionKind {
    pub fn risk_info(&self) -> ActionRiskInfo {
        match self {
            ActionKind::MergeToTarget => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Danger,
                description: "Merge task branch into target".to_string(),
                consequences: vec![
                    "Changes will be merged into the target branch".to_string(),
                    "This cannot be easily undone".to_string(),
                ],
                confirmation_phrase: Some("merge to target".to_string()),
            },
            ActionKind::DeleteWorktreeWithChanges => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Danger,
                description: "Delete worktree with uncommitted changes".to_string(),
                consequences: vec![
                    "All uncommitted changes will be lost".to_string(),
                    "The worktree directory will be removed".to_string(),
                ],
                confirmation_phrase: Some("delete worktree".to_string()),
            },
            ActionKind::ForcePush => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Danger,
                description: "Force push to remote".to_string(),
                consequences: vec![
                    "Remote branch history will be rewritten".to_string(),
                    "Other collaborators may lose work".to_string(),
                ],
                confirmation_phrase: Some("force push".to_string()),
            },
            ActionKind::DeleteTaskWithActiveSession => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Danger,
                description: "Delete task with active agent session".to_string(),
                consequences: vec![
                    "The running agent session will be terminated".to_string(),
                    "Task data and history will be deleted".to_string(),
                ],
                confirmation_phrase: Some("delete active task".to_string()),
            },
            ActionKind::PurgeScrollback => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Caution,
                description: "Purge session scrollback history".to_string(),
                consequences: vec!["All terminal output history will be cleared".to_string()],
                confirmation_phrase: None,
            },
            ActionKind::RestartStuckAgent => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Caution,
                description: "Restart a stuck agent".to_string(),
                consequences: vec![
                    "The current agent process will be killed".to_string(),
                    "Work in progress may be lost".to_string(),
                ],
                confirmation_phrase: None,
            },
            ActionKind::DiscardReview => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Caution,
                description: "Discard review and send task back".to_string(),
                consequences: vec!["Review notes will be discarded".to_string()],
                confirmation_phrase: None,
            },
            ActionKind::RedispatchFailedTask => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Caution,
                description: "Redispatch a failed task".to_string(),
                consequences: vec!["Previous failure output will be preserved".to_string()],
                confirmation_phrase: None,
            },
            ActionKind::BulkDeleteCompletedTasks => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Danger,
                description: "Delete all completed tasks".to_string(),
                consequences: vec![
                    "All completed task records will be permanently deleted".to_string(),
                    "Associated artifacts and reviews will remain".to_string(),
                ],
                confirmation_phrase: Some("delete all completed".to_string()),
            },
            ActionKind::CreateTask
            | ActionKind::DispatchReadyTask
            | ActionKind::OpenPane
            | ActionKind::CreateCheckpoint => ActionRiskInfo {
                kind: *self,
                risk_level: RiskLevel::Safe,
                description: format!("{:?}", self),
                consequences: vec![],
                confirmation_phrase: None,
            },
        }
    }
}
