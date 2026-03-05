use crate::{SessionId, TaskId};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use thiserror::Error;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum Priority {
    P0,
    P1,
    P2,
    P3,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum TaskStatus {
    Planned,
    Ready,
    InProgress,
    Review,
    Done,
    Failed,
    Blocked,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum CheckType {
    TestCommand,
    FileExists,
    ManualApproval,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Check {
    pub description: String,
    pub check_type: CheckType,
    #[serde(default)]
    pub command: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContextManifestItem {
    pub kind: String,
    pub included: bool,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContextPack {
    pub task_contract: Box<TaskContract>,
    pub project_brief: String,
    pub architecture_notes: String,
    pub conventions: Vec<String>,
    pub rules: Vec<String>,
    pub relevant_file_contents: Vec<(String, String)>,
    pub prior_task_summaries: Vec<String>,
    pub token_budget: usize,
    pub actual_tokens: usize,
    #[serde(default)]
    pub manifest: Vec<ContextManifestItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskContract {
    pub id: TaskId,
    pub title: String,
    pub goal: String,
    pub scope: Vec<String>,
    pub out_of_scope: Vec<String>,
    pub dependencies: Vec<TaskId>,
    pub acceptance_criteria: Vec<Check>,
    pub constraints: Vec<String>,
    pub priority: Priority,
    pub status: TaskStatus,
    pub assigned_session: Option<SessionId>,
    pub branch: Option<String>,
    pub worktree: Option<String>,
    pub prompt_pack: Option<ContextPack>,
    pub handoff_summary: Option<String>,
    pub auto_dispatch: bool,
    pub agent_profile_override: Option<String>,
    pub execution_mode: Option<String>,
    pub timeout_minutes: Option<i64>,
    pub max_retries: Option<i64>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Error)]
pub enum TransitionError {
    #[error("task transition from {from:?} to {to:?} is invalid")]
    InvalidTransition { from: TaskStatus, to: TaskStatus },
}

impl TaskContract {
    pub fn validate_new(&self) -> Result<(), String> {
        if self.title.trim().is_empty() {
            return Err("title must not be empty".to_string());
        }
        if self.goal.trim().is_empty() {
            return Err("goal must not be empty".to_string());
        }
        Ok(())
    }

    pub fn transition(&mut self, to: TaskStatus) -> Result<(), TransitionError> {
        use TaskStatus::*;
        let valid = matches!(
            (&self.status, &to),
            (Planned, Ready)
                | (Ready, InProgress)
                | (InProgress, Review)
                | (Review, Done)
                | (Ready, Failed)
                | (InProgress, Failed)
                | (Review, Failed)
                | (Planned, Blocked)
                | (Ready, Blocked)
                | (Blocked, Planned)
        );

        if !valid {
            return Err(TransitionError::InvalidTransition {
                from: self.status.clone(),
                to,
            });
        }

        self.status = to;
        self.updated_at = Utc::now();
        Ok(())
    }

    pub fn refresh_blocked_status(&mut self, completed: &HashSet<TaskId>) {
        let unmet = self.dependencies.iter().any(|dep| !completed.contains(dep));
        if unmet && self.status != TaskStatus::Blocked {
            self.status = TaskStatus::Blocked;
            self.updated_at = Utc::now();
        } else if !unmet && self.status == TaskStatus::Blocked {
            self.status = TaskStatus::Planned;
            self.updated_at = Utc::now();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use uuid::Uuid;

    fn base_task() -> TaskContract {
        TaskContract {
            id: Uuid::new_v4(),
            title: "Example".to_string(),
            goal: "Do a thing".to_string(),
            scope: vec!["src/main.rs".to_string()],
            out_of_scope: vec![],
            dependencies: vec![],
            acceptance_criteria: vec![Check {
                description: "tests pass".to_string(),
                check_type: CheckType::TestCommand,
                command: Some("cargo test".to_string()),
            }],
            constraints: vec![],
            priority: Priority::P1,
            status: TaskStatus::Planned,
            assigned_session: None,
            branch: None,
            worktree: None,
            prompt_pack: None,
            handoff_summary: None,
            auto_dispatch: false,
            agent_profile_override: None,
            execution_mode: None,
            timeout_minutes: None,
            max_retries: None,
            created_at: Utc::now(),
            updated_at: Utc::now(),
        }
    }

    #[test]
    fn valid_transition_planned_to_ready() {
        let mut task = base_task();
        task.transition(TaskStatus::Ready)
            .expect("transition failed");
        assert_eq!(task.status, TaskStatus::Ready);
    }

    #[test]
    fn invalid_transition_planned_to_done() {
        let mut task = base_task();
        let err = task
            .transition(TaskStatus::Done)
            .expect_err("expected invalid transition");
        assert!(matches!(err, TransitionError::InvalidTransition { .. }));
    }

    proptest! {
        #[test]
        fn empty_titles_are_rejected(title in "\\s*") {
            let mut task = base_task();
            task.title = title;
            let valid = task.validate_new();
            prop_assert!(valid.is_err());
        }

        #[test]
        fn arbitrary_transition_sequence_never_panics(
            // Generate up to 10 transition attempts using indices into valid statuses
            transitions in proptest::collection::vec(0usize..7, 0..=10)
        ) {
            let statuses = [
                TaskStatus::Planned,
                TaskStatus::Ready,
                TaskStatus::InProgress,
                TaskStatus::Review,
                TaskStatus::Done,
                TaskStatus::Failed,
                TaskStatus::Blocked,
            ];

            let mut task = base_task();
            for idx in &transitions {
                let to = statuses[*idx].clone();
                // Transition may succeed or fail — both are acceptable, no panics allowed.
                let _ = task.transition(to);
                // Assert task is always in one of the defined states (not corrupted).
                prop_assert!(matches!(
                    task.status,
                    TaskStatus::Planned
                        | TaskStatus::Ready
                        | TaskStatus::InProgress
                        | TaskStatus::Review
                        | TaskStatus::Done
                        | TaskStatus::Failed
                        | TaskStatus::Blocked
                ));
            }
        }

        #[test]
        fn terminal_states_cannot_transition_further(
            next in 0usize..7
        ) {
            let statuses = [
                TaskStatus::Planned,
                TaskStatus::Ready,
                TaskStatus::InProgress,
                TaskStatus::Review,
                TaskStatus::Done,
                TaskStatus::Failed,
                TaskStatus::Blocked,
            ];

            // Done and Failed are terminal — no outgoing transitions are defined for them.
            for terminal in [TaskStatus::Done, TaskStatus::Failed] {
                let mut task = base_task();
                task.status = terminal.clone();
                let to = statuses[next].clone();
                // Any transition from a terminal state must be rejected.
                let result = task.transition(to);
                prop_assert!(
                    result.is_err(),
                    "transition from terminal state {:?} should fail",
                    terminal
                );
                // Status must remain terminal after a rejected transition.
                prop_assert_eq!(task.status, terminal);
            }
        }

        #[test]
        fn happy_path_and_failure_branches_all_succeed(
            // 0 = full happy path (no failure); 1/2/3 = fail after reaching Ready/InProgress/Review
            scenario in 0usize..=3
        ) {
            // Happy path: Planned → Ready → InProgress → Review → Done
            // Valid failure exits: Ready→Failed, InProgress→Failed, Review→Failed
            let mut task = base_task();

            // Step 0: Planned → Ready (always first)
            prop_assert!(task.transition(TaskStatus::Ready).is_ok());
            if scenario == 1 {
                prop_assert!(task.transition(TaskStatus::Failed).is_ok());
                return Ok(());
            }

            // Step 1: Ready → InProgress
            prop_assert!(task.transition(TaskStatus::InProgress).is_ok());
            if scenario == 2 {
                prop_assert!(task.transition(TaskStatus::Failed).is_ok());
                return Ok(());
            }

            // Step 2: InProgress → Review
            prop_assert!(task.transition(TaskStatus::Review).is_ok());
            if scenario == 3 {
                prop_assert!(task.transition(TaskStatus::Failed).is_ok());
                return Ok(());
            }

            // Full happy path: Review → Done
            prop_assert!(task.transition(TaskStatus::Done).is_ok());
            prop_assert_eq!(task.status, TaskStatus::Done);
        }
    }

    #[test]
    fn blocked_to_planned_transition_succeeds() {
        let mut task = base_task();
        task.status = TaskStatus::Blocked;
        task.transition(TaskStatus::Planned)
            .expect("Blocked -> Planned must succeed");
        assert_eq!(task.status, TaskStatus::Planned);
    }

    #[test]
    fn done_state_rejects_all_transitions() {
        for to in [
            TaskStatus::Planned,
            TaskStatus::Ready,
            TaskStatus::InProgress,
            TaskStatus::Review,
            TaskStatus::Failed,
            TaskStatus::Blocked,
        ] {
            let mut task = base_task();
            task.status = TaskStatus::Done;
            assert!(
                task.transition(to.clone()).is_err(),
                "Done -> {to:?} should be rejected"
            );
        }
    }

    #[test]
    fn failed_state_rejects_all_transitions() {
        for to in [
            TaskStatus::Planned,
            TaskStatus::Ready,
            TaskStatus::InProgress,
            TaskStatus::Review,
            TaskStatus::Done,
            TaskStatus::Blocked,
        ] {
            let mut task = base_task();
            task.status = TaskStatus::Failed;
            assert!(
                task.transition(to.clone()).is_err(),
                "Failed -> {to:?} should be rejected"
            );
        }
    }
}
