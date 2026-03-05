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

impl ActionRiskInfo {
    /// Returns true when `user_input` exactly matches the required confirmation phrase.
    /// Actions without a phrase (Caution/Safe) always pass.
    pub fn verify_confirmation(&self, user_input: &str) -> bool {
        match &self.confirmation_phrase {
            Some(phrase) => user_input == phrase,
            None => true,
        }
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    // ── verify_confirmation ───────────────────────────────────────────────────

    #[test]
    fn correct_phrase_passes() {
        let info = ActionKind::MergeToTarget.risk_info();
        assert!(info.verify_confirmation("merge to target"));
    }

    #[test]
    fn wrong_phrase_fails() {
        let info = ActionKind::MergeToTarget.risk_info();
        assert!(!info.verify_confirmation("merge"));
        assert!(!info.verify_confirmation("MERGE TO TARGET"));
        assert!(!info.verify_confirmation("merge to target "));
    }

    #[test]
    fn case_sensitive_mismatch_fails() {
        let info = ActionKind::ForcePush.risk_info();
        // Phrase is "force push" — uppercase must fail.
        assert!(!info.verify_confirmation("Force Push"));
        assert!(!info.verify_confirmation("FORCE PUSH"));
    }

    #[test]
    fn empty_input_fails_for_danger_action() {
        let info = ActionKind::DeleteWorktreeWithChanges.risk_info();
        assert!(!info.verify_confirmation(""));
    }

    #[test]
    fn action_without_phrase_always_passes() {
        // Caution-level actions have no confirmation phrase.
        let info = ActionKind::PurgeScrollback.risk_info();
        assert!(info.verify_confirmation(""));
        assert!(info.verify_confirmation("anything at all"));
    }

    #[test]
    fn safe_action_always_passes() {
        let info = ActionKind::CreateTask.risk_info();
        assert!(info.verify_confirmation(""));
        assert!(info.verify_confirmation("random input"));
    }

    #[test]
    fn bulk_delete_phrase_exact_match() {
        let info = ActionKind::BulkDeleteCompletedTasks.risk_info();
        assert!(info.verify_confirmation("delete all completed"));
        assert!(!info.verify_confirmation("delete all"));
        assert!(!info.verify_confirmation("delete all completed tasks"));
    }

    #[test]
    fn delete_active_task_phrase_exact_match() {
        let info = ActionKind::DeleteTaskWithActiveSession.risk_info();
        assert!(info.verify_confirmation("delete active task"));
        assert!(!info.verify_confirmation("delete active"));
    }
}
