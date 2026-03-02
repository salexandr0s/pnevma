use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum LeaseStatus {
    Active,
    Stale,
    Released,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorktreeLease {
    pub id: Uuid,
    pub task_id: Uuid,
    pub branch: String,
    pub path: String,
    pub started_at: DateTime<Utc>,
    pub last_active: DateTime<Utc>,
    pub status: LeaseStatus,
}

impl WorktreeLease {
    pub fn refresh(&mut self) {
        self.last_active = Utc::now();
        self.status = LeaseStatus::Active;
    }

    pub fn mark_stale_if_needed(&mut self, stale_after: Duration) {
        if self.status == LeaseStatus::Released {
            return;
        }

        if Utc::now() - self.last_active >= stale_after {
            self.status = LeaseStatus::Stale;
        } else {
            self.status = LeaseStatus::Active;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;

    fn sample_lease() -> WorktreeLease {
        WorktreeLease {
            id: Uuid::new_v4(),
            task_id: Uuid::new_v4(),
            branch: "pnevma/test".to_string(),
            path: "/tmp/pnevma/worktree".to_string(),
            started_at: Utc::now(),
            last_active: Utc::now(),
            status: LeaseStatus::Active,
        }
    }

    #[test]
    fn released_lease_never_reactivates_when_marked_stale() {
        let mut lease = sample_lease();
        lease.status = LeaseStatus::Released;
        lease.last_active = Utc::now() - Duration::hours(5);
        lease.mark_stale_if_needed(Duration::minutes(30));
        assert_eq!(lease.status, LeaseStatus::Released);
    }

    proptest! {
        #[test]
        fn mark_stale_follows_last_active_age(seconds_ago in 0i64..2000) {
            let mut lease = sample_lease();
            lease.last_active = Utc::now() - Duration::seconds(seconds_ago);
            lease.status = LeaseStatus::Active;
            lease.mark_stale_if_needed(Duration::seconds(300));
            if seconds_ago <= 299 {
                prop_assert_eq!(lease.status.clone(), LeaseStatus::Active);
            }
            if seconds_ago >= 301 {
                prop_assert_eq!(lease.status.clone(), LeaseStatus::Stale);
            }
        }
    }

    #[test]
    fn refresh_sets_active_and_updates_timestamp() {
        let mut lease = sample_lease();
        lease.status = LeaseStatus::Stale;
        lease.last_active = Utc::now() - Duration::hours(1);
        lease.refresh();
        assert_eq!(lease.status, LeaseStatus::Active);
        assert!(Utc::now() - lease.last_active < Duration::seconds(1));
    }
}
