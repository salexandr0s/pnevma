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
