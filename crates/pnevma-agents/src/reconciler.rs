use serde::{Deserialize, Serialize};
use std::path::Path;
use uuid::Uuid;

/// A claim that needs reconciliation (from the coordinator's running set).
#[derive(Debug, Clone)]
pub struct ReconciliationClaim {
    pub task_id: Uuid,
    pub session_id: Uuid,
    pub worktree_path: Option<String>,
    pub branch: Option<String>,
    /// How the claim's lease status appears.
    pub lease_status: String,
}

/// What action to take for a reconciliation claim.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReconciliationAction {
    /// Mark the task as Failed and release the claim.
    MarkFailed { task_id: Uuid, reason: String },
    /// Refresh the lease (everything looks healthy).
    RefreshLease { task_id: Uuid },
    /// Cleanup an orphaned worktree with no active session.
    CleanupOrphan {
        task_id: Uuid,
        worktree_path: String,
    },
}

/// Check whether an active session exists for the given session ID.
/// This is a simplified check — the actual implementation would query the session supervisor.
fn is_session_active(session_id: &Uuid, active_sessions: &[Uuid]) -> bool {
    active_sessions.contains(session_id)
}

/// Check whether a worktree path exists on disk.
fn worktree_exists(path: &str) -> bool {
    Path::new(path).exists()
}

/// Reconcile a set of claims against the actual system state.
///
/// For each claim, determine what action to take:
/// - If session is active and worktree exists → RefreshLease
/// - If session is dead and worktree exists → CleanupOrphan
/// - If session is dead and worktree is gone → MarkFailed
/// - If session is active but worktree is gone → MarkFailed (something went wrong)
pub fn reconcile_claims(
    claims: &[ReconciliationClaim],
    active_sessions: &[Uuid],
) -> Vec<ReconciliationAction> {
    let mut actions = Vec::with_capacity(claims.len());

    for claim in claims {
        let session_alive = is_session_active(&claim.session_id, active_sessions);
        let wt_exists = claim
            .worktree_path
            .as_ref()
            .map(|p| worktree_exists(p))
            .unwrap_or(false);

        let action = match (session_alive, wt_exists) {
            (true, true) => {
                // Everything healthy
                ReconciliationAction::RefreshLease {
                    task_id: claim.task_id,
                }
            }
            (true, false) => {
                // Session alive but worktree gone — something went wrong
                ReconciliationAction::MarkFailed {
                    task_id: claim.task_id,
                    reason: "worktree missing while session still active".to_string(),
                }
            }
            (false, true) => {
                // Session dead but worktree left behind — orphan
                if let Some(ref path) = claim.worktree_path {
                    ReconciliationAction::CleanupOrphan {
                        task_id: claim.task_id,
                        worktree_path: path.clone(),
                    }
                } else {
                    ReconciliationAction::MarkFailed {
                        task_id: claim.task_id,
                        reason: "session dead, no worktree path recorded".to_string(),
                    }
                }
            }
            (false, false) => {
                // Both gone — just mark failed
                ReconciliationAction::MarkFailed {
                    task_id: claim.task_id,
                    reason: "session and worktree both gone".to_string(),
                }
            }
        };

        actions.push(action);
    }

    actions
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_claim(task_id: Uuid, session_id: Uuid, worktree: Option<&str>) -> ReconciliationClaim {
        ReconciliationClaim {
            task_id,
            session_id,
            worktree_path: worktree.map(String::from),
            branch: Some("feat/test".to_string()),
            lease_status: "Active".to_string(),
        }
    }

    #[test]
    fn healthy_session_and_worktree_refreshes_lease() {
        let task_id = Uuid::new_v4();
        let session_id = Uuid::new_v4();
        let dir = tempfile::TempDir::new().unwrap();
        let claim = make_claim(task_id, session_id, Some(dir.path().to_str().unwrap()));

        let actions = reconcile_claims(&[claim], &[session_id]);
        assert_eq!(actions.len(), 1);
        assert_eq!(actions[0], ReconciliationAction::RefreshLease { task_id });
    }

    #[test]
    fn dead_session_with_worktree_is_orphan() {
        let task_id = Uuid::new_v4();
        let session_id = Uuid::new_v4();
        let dir = tempfile::TempDir::new().unwrap();
        let path = dir.path().to_str().unwrap().to_string();
        let claim = make_claim(task_id, session_id, Some(&path));

        let actions = reconcile_claims(&[claim], &[]); // no active sessions
        assert_eq!(actions.len(), 1);
        assert_eq!(
            actions[0],
            ReconciliationAction::CleanupOrphan {
                task_id,
                worktree_path: path
            }
        );
    }

    #[test]
    fn dead_session_no_worktree_marks_failed() {
        let task_id = Uuid::new_v4();
        let session_id = Uuid::new_v4();
        let claim = make_claim(task_id, session_id, Some("/nonexistent/path/xyz"));

        let actions = reconcile_claims(&[claim], &[]);
        assert_eq!(actions.len(), 1);
        assert!(matches!(
            actions[0],
            ReconciliationAction::MarkFailed { .. }
        ));
    }

    #[test]
    fn alive_session_missing_worktree_marks_failed() {
        let task_id = Uuid::new_v4();
        let session_id = Uuid::new_v4();
        let claim = make_claim(task_id, session_id, Some("/nonexistent/path/xyz"));

        let actions = reconcile_claims(&[claim], &[session_id]);
        assert_eq!(actions.len(), 1);
        assert!(matches!(
            actions[0],
            ReconciliationAction::MarkFailed { .. }
        ));
    }

    #[test]
    fn multiple_claims_reconciled() {
        let t1 = Uuid::new_v4();
        let s1 = Uuid::new_v4();
        let t2 = Uuid::new_v4();
        let s2 = Uuid::new_v4();
        let dir = tempfile::TempDir::new().unwrap();

        let claims = vec![
            make_claim(t1, s1, Some(dir.path().to_str().unwrap())),
            make_claim(t2, s2, Some("/nonexistent")),
        ];

        let actions = reconcile_claims(&claims, &[s1]);
        assert_eq!(actions.len(), 2);
        assert_eq!(
            actions[0],
            ReconciliationAction::RefreshLease { task_id: t1 }
        );
        assert!(matches!(
            actions[1],
            ReconciliationAction::MarkFailed { .. }
        ));
    }
}
