use crate::{SessionId, TaskId};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::fmt;
use std::str::FromStr;
use thiserror::Error;

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum Priority {
    P0,
    P1,
    P2,
    P3,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum TaskStatus {
    Planned,
    Ready,
    Dispatching,
    InProgress,
    Review,
    Done,
    Failed,
    Blocked,
    Looped,
}

impl fmt::Display for Priority {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Priority::P0 => write!(f, "P0"),
            Priority::P1 => write!(f, "P1"),
            Priority::P2 => write!(f, "P2"),
            Priority::P3 => write!(f, "P3"),
        }
    }
}

impl FromStr for Priority {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "P0" => Ok(Priority::P0),
            "P1" => Ok(Priority::P1),
            "P2" => Ok(Priority::P2),
            "P3" => Ok(Priority::P3),
            _ => Err(format!("unknown priority: {s}")),
        }
    }
}

impl fmt::Display for TaskStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TaskStatus::Planned => write!(f, "Planned"),
            TaskStatus::Ready => write!(f, "Ready"),
            TaskStatus::Dispatching => write!(f, "Dispatching"),
            TaskStatus::InProgress => write!(f, "InProgress"),
            TaskStatus::Review => write!(f, "Review"),
            TaskStatus::Done => write!(f, "Done"),
            TaskStatus::Failed => write!(f, "Failed"),
            TaskStatus::Blocked => write!(f, "Blocked"),
            TaskStatus::Looped => write!(f, "Looped"),
        }
    }
}

impl FromStr for TaskStatus {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "Planned" => Ok(TaskStatus::Planned),
            "Ready" => Ok(TaskStatus::Ready),
            "Dispatching" => Ok(TaskStatus::Dispatching),
            "InProgress" => Ok(TaskStatus::InProgress),
            "Review" => Ok(TaskStatus::Review),
            "Done" => Ok(TaskStatus::Done),
            "Failed" => Ok(TaskStatus::Failed),
            "Blocked" => Ok(TaskStatus::Blocked),
            "Looped" => Ok(TaskStatus::Looped),
            _ => Err(format!("unknown task status: {s}")),
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
pub enum LeaseStatus {
    Active,
    Released,
    Expired,
}

impl fmt::Display for LeaseStatus {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            LeaseStatus::Active => write!(f, "Active"),
            LeaseStatus::Released => write!(f, "Released"),
            LeaseStatus::Expired => write!(f, "Expired"),
        }
    }
}

impl FromStr for LeaseStatus {
    type Err = String;
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "Active" | "active" => Ok(LeaseStatus::Active),
            "Released" | "released" => Ok(LeaseStatus::Released),
            "Expired" | "expired" => Ok(LeaseStatus::Expired),
            _ => Err(format!("unknown lease status: {s}")),
        }
    }
}

/// Re-export from workflow module for TaskContract usage.
pub use crate::workflow::ExecutionMode;

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
    pub execution_mode: Option<ExecutionMode>,
    pub timeout_minutes: Option<u32>,
    pub max_retries: Option<i64>,
    pub loop_iteration: u32,
    pub loop_context_json: Option<String>,
    pub external_source: Option<TaskExternalSource>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct TaskExternalSource {
    pub kind: String,
    pub external_id: String,
    pub identifier: String,
    pub url: String,
    pub state: String,
}

#[derive(Debug, Error)]
pub enum TransitionError {
    #[error("task transition from {from:?} to {to:?} is invalid")]
    InvalidTransition { from: TaskStatus, to: TaskStatus },
}

impl TaskContract {
    pub fn validate_new(&self) -> Result<(), crate::CoreError> {
        if self.title.trim().is_empty() {
            return Err(crate::CoreError::InvalidConfig(
                "title must not be empty".to_string(),
            ));
        }
        if self.goal.trim().is_empty() {
            return Err(crate::CoreError::InvalidConfig(
                "goal must not be empty".to_string(),
            ));
        }
        Ok(())
    }

    pub fn transition(&mut self, to: TaskStatus) -> Result<(), TransitionError> {
        use TaskStatus::*;
        let valid = matches!(
            (&self.status, &to),
            (Planned, Ready)
                | (Ready, Dispatching)
                | (Dispatching, InProgress)
                | (Dispatching, Ready)
                | (Dispatching, Failed)
                | (Ready, InProgress)
                | (InProgress, Review)
                | (Review, Done)
                | (Ready, Failed)
                | (InProgress, Failed)
                | (Review, Failed)
                | (Planned, Blocked)
                | (Ready, Blocked)
                | (Blocked, Planned)
                | (Failed, Looped)
                | (Done, Looped)
                | (Looped, Planned)
        );

        if !valid {
            return Err(TransitionError::InvalidTransition {
                from: self.status,
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
            // Attempt to transition to Blocked; log unexpected failures
            // (states like Done/Failed cannot transition to Blocked by design).
            if let Err(e) = self.transition(TaskStatus::Blocked) {
                tracing::warn!(
                    task_id = %self.id,
                    status = %self.status,
                    error = %e,
                    "could not transition task to Blocked (unmet dependencies exist)"
                );
            }
        } else if !unmet && self.status == TaskStatus::Blocked {
            if let Err(e) = self.transition(TaskStatus::Planned) {
                tracing::warn!(
                    task_id = %self.id,
                    status = %self.status,
                    error = %e,
                    "could not unblock task (all dependencies met)"
                );
            }
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
            loop_iteration: 0,
            loop_context_json: None,
            external_source: None,
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
            transitions in proptest::collection::vec(0usize..9, 0..=10)
        ) {
            let statuses = [
                TaskStatus::Planned,
                TaskStatus::Ready,
                TaskStatus::Dispatching,
                TaskStatus::InProgress,
                TaskStatus::Review,
                TaskStatus::Done,
                TaskStatus::Failed,
                TaskStatus::Blocked,
                TaskStatus::Looped,
            ];

            let mut task = base_task();
            for idx in &transitions {
                let to = statuses[*idx];
                // Transition may succeed or fail — both are acceptable, no panics allowed.
                let _ = task.transition(to);
                // Assert task is always in one of the defined states (not corrupted).
                prop_assert!(matches!(
                    task.status,
                    TaskStatus::Planned
                        | TaskStatus::Ready
                        | TaskStatus::Dispatching
                        | TaskStatus::InProgress
                        | TaskStatus::Review
                        | TaskStatus::Done
                        | TaskStatus::Failed
                        | TaskStatus::Blocked
                        | TaskStatus::Looped
                ));
            }
        }

        #[test]
        fn terminal_states_cannot_transition_further(
            next in 0usize..9
        ) {
            let statuses = [
                TaskStatus::Planned,
                TaskStatus::Ready,
                TaskStatus::Dispatching,
                TaskStatus::InProgress,
                TaskStatus::Review,
                TaskStatus::Done,
                TaskStatus::Failed,
                TaskStatus::Blocked,
                TaskStatus::Looped,
            ];

            // Done allows only Done -> Looped (for until_complete loops).
            // Looped allows only Looped -> Planned (to re-enter the pipeline).
            for terminal in [TaskStatus::Done, TaskStatus::Looped] {
                let mut task = base_task();
                task.status = terminal;
                let to = statuses[next];
                let is_valid_exit = (terminal == TaskStatus::Done && to == TaskStatus::Looped)
                    || (terminal == TaskStatus::Looped && to == TaskStatus::Planned);
                if is_valid_exit {
                    let result = task.transition(to);
                    prop_assert!(result.is_ok(), "{:?} -> {:?} should succeed", terminal, to);
                } else {
                    // All other transitions from terminal states must be rejected.
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
    fn done_state_rejects_non_looped_transitions() {
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
                task.transition(to).is_err(),
                "Done -> {to:?} should be rejected"
            );
        }
    }

    #[test]
    fn done_state_allows_looped_transition() {
        let mut task = base_task();
        task.status = TaskStatus::Done;
        task.transition(TaskStatus::Looped)
            .expect("Done -> Looped must succeed for until_complete loops");
        assert_eq!(task.status, TaskStatus::Looped);
    }

    #[test]
    fn failed_state_allows_looped_transition() {
        let mut task = base_task();
        task.status = TaskStatus::Failed;
        task.transition(TaskStatus::Looped)
            .expect("Failed -> Looped must succeed");
        assert_eq!(task.status, TaskStatus::Looped);
    }

    #[test]
    fn failed_state_rejects_other_transitions() {
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
                task.transition(to).is_err(),
                "Failed -> {to:?} should be rejected"
            );
        }
    }

    #[test]
    fn priority_display_fromstr_roundtrip() {
        for p in [Priority::P0, Priority::P1, Priority::P2, Priority::P3] {
            let s = p.to_string();
            let parsed: Priority = s.parse().unwrap();
            assert_eq!(parsed, p);
        }
    }

    #[test]
    fn priority_fromstr_unknown_is_err() {
        assert!("high".parse::<Priority>().is_err());
        assert!("medium".parse::<Priority>().is_err());
        assert!("".parse::<Priority>().is_err());
    }

    #[test]
    fn task_status_display_fromstr_roundtrip() {
        for s in [
            TaskStatus::Planned,
            TaskStatus::Ready,
            TaskStatus::Dispatching,
            TaskStatus::InProgress,
            TaskStatus::Review,
            TaskStatus::Done,
            TaskStatus::Failed,
            TaskStatus::Blocked,
            TaskStatus::Looped,
        ] {
            let text = s.to_string();
            let parsed: TaskStatus = text.parse().unwrap();
            assert_eq!(parsed, s);
        }
    }

    #[test]
    fn task_status_fromstr_unknown_is_err() {
        assert!("Pending".parse::<TaskStatus>().is_err());
        assert!("".parse::<TaskStatus>().is_err());
    }

    #[test]
    fn lease_status_display_fromstr_roundtrip() {
        use crate::task::LeaseStatus;
        for s in [
            LeaseStatus::Active,
            LeaseStatus::Released,
            LeaseStatus::Expired,
        ] {
            let text = s.to_string();
            let parsed: LeaseStatus = text.parse().unwrap();
            assert_eq!(parsed, s);
        }
    }

    #[test]
    fn lease_status_accepts_lowercase() {
        use crate::task::LeaseStatus;
        assert_eq!(
            "active".parse::<LeaseStatus>().unwrap(),
            LeaseStatus::Active
        );
        assert_eq!(
            "released".parse::<LeaseStatus>().unwrap(),
            LeaseStatus::Released
        );
        assert_eq!(
            "expired".parse::<LeaseStatus>().unwrap(),
            LeaseStatus::Expired
        );
    }
}
