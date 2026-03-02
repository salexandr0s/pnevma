use crate::error::GitError;
use crate::lease::{LeaseStatus, WorktreeLease};
use chrono::{Duration, Utc};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::process::Command;
use tokio::sync::Mutex;
use uuid::Uuid;

#[derive(Debug, Clone)]
pub struct GitService {
    repo_root: PathBuf,
    worktree_root: PathBuf,
    leases: Arc<Mutex<HashMap<Uuid, WorktreeLease>>>,
    stale_after: Duration,
}

impl GitService {
    pub fn new(repo_root: impl AsRef<Path>) -> Self {
        let repo_root = repo_root.as_ref().to_path_buf();
        let worktree_root = repo_root.join(".pnevma/worktrees");
        Self {
            repo_root,
            worktree_root,
            leases: Arc::new(Mutex::new(HashMap::new())),
            stale_after: Duration::hours(2),
        }
    }

    pub async fn create_worktree(
        &self,
        task_id: Uuid,
        base_branch: &str,
        slug: &str,
    ) -> Result<WorktreeLease, GitError> {
        {
            let leases = self.leases.lock().await;
            if leases.contains_key(&task_id) {
                return Err(GitError::LeaseViolation(format!(
                    "task {} already has an active lease",
                    task_id
                )));
            }
        }

        tokio::fs::create_dir_all(&self.worktree_root).await?;

        let branch = format!("pnevma/{}/{}", task_id, slug);
        let path = self.worktree_root.join(task_id.to_string());

        self.git(["branch", &branch, base_branch]).await?;
        self.git(["worktree", "add", path.to_string_lossy().as_ref(), &branch])
            .await?;

        let lease = WorktreeLease {
            id: Uuid::new_v4(),
            task_id,
            branch,
            path: path.to_string_lossy().to_string(),
            started_at: Utc::now(),
            last_active: Utc::now(),
            status: LeaseStatus::Active,
        };

        self.leases.lock().await.insert(task_id, lease.clone());
        Ok(lease)
    }

    pub async fn cleanup_worktree(
        &self,
        task_id: Uuid,
        delete_branch: bool,
    ) -> Result<(), GitError> {
        let mut leases = self.leases.lock().await;
        let Some(lease) = leases.remove(&task_id) else {
            return Err(GitError::WorktreeNotFound(task_id.to_string()));
        };

        self.git(["worktree", "remove", "--force", &lease.path])
            .await?;
        if delete_branch {
            self.git(["branch", "-D", &lease.branch]).await?;
        }
        Ok(())
    }

    pub async fn cleanup_persisted_worktree(
        &self,
        task_id: Uuid,
        path: &str,
        branch: Option<&str>,
        delete_branch: bool,
    ) -> Result<(), GitError> {
        self.leases.lock().await.remove(&task_id);
        let remove_res = self.git(["worktree", "remove", "--force", path]).await;
        if let Err(err) = remove_res {
            // The path may already be gone after a manual cleanup or failed run.
            if Path::new(path).exists() {
                return Err(err);
            }
        }
        if delete_branch {
            if let Some(branch) = branch {
                self.git(["branch", "-D", branch]).await?;
            }
        }
        Ok(())
    }

    pub async fn list_worktrees(&self) -> Vec<WorktreeLease> {
        let mut leases: Vec<_> = self.leases.lock().await.values().cloned().collect();
        for lease in &mut leases {
            lease.mark_stale_if_needed(self.stale_after);
        }
        leases
    }

    pub async fn touch_lease(&self, task_id: Uuid) -> Result<(), GitError> {
        let mut leases = self.leases.lock().await;
        let Some(lease) = leases.get_mut(&task_id) else {
            return Err(GitError::WorktreeNotFound(task_id.to_string()));
        };
        lease.refresh();
        Ok(())
    }

    async fn git<I, S>(&self, args: I) -> Result<(), GitError>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let args_vec: Vec<String> = args.into_iter().map(|s| s.as_ref().to_string()).collect();
        let out = Command::new("git")
            .args(&args_vec)
            .current_dir(&self.repo_root)
            .output()
            .await?;

        if out.status.success() {
            return Ok(());
        }

        let stderr = String::from_utf8_lossy(&out.stderr).to_string();
        Err(GitError::Command(format!(
            "git {} failed: {}",
            args_vec.join(" "),
            stderr.trim()
        )))
    }
}

#[derive(Debug, Default)]
pub struct MergeQueue {
    queue: Arc<Mutex<VecDeque<Uuid>>>,
    merge_lock: Arc<Mutex<()>>,
}

impl MergeQueue {
    pub fn new() -> Self {
        Self::default()
    }

    pub async fn enqueue(&self, task_id: Uuid) {
        self.queue.lock().await.push_back(task_id);
    }

    pub async fn next(&self) -> Option<Uuid> {
        self.queue.lock().await.pop_front()
    }

    pub async fn with_merge_lock<F, Fut, T>(&self, f: F) -> T
    where
        F: FnOnce() -> Fut,
        Fut: std::future::Future<Output = T>,
    {
        let _guard = self.merge_lock.lock().await;
        f().await
    }

    pub async fn size(&self) -> usize {
        self.queue.lock().await.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use proptest::prelude::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc as StdArc;

    proptest! {
        #[test]
        fn merge_queue_is_fifo(task_ids in prop::collection::vec(any::<u128>(), 1..64)) {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async move {
                let queue = MergeQueue::new();
                let expected = task_ids
                    .iter()
                    .map(|raw| Uuid::from_u128(*raw))
                    .collect::<Vec<_>>();

                for task_id in &expected {
                    queue.enqueue(*task_id).await;
                }
                assert_eq!(queue.size().await, expected.len());

                let mut actual = Vec::new();
                while let Some(next) = queue.next().await {
                    actual.push(next);
                }
                assert_eq!(actual, expected);
                assert_eq!(queue.size().await, 0);
            });
        }
    }

    #[tokio::test]
    async fn merge_lock_serializes_concurrent_sections() {
        let queue = StdArc::new(MergeQueue::new());
        let active = StdArc::new(AtomicUsize::new(0));
        let max_seen = StdArc::new(AtomicUsize::new(0));

        let mut handles = Vec::new();
        for _ in 0..8usize {
            let queue_ref = queue.clone();
            let active_ref = active.clone();
            let max_ref = max_seen.clone();
            handles.push(tokio::spawn(async move {
                queue_ref
                    .with_merge_lock(|| async {
                        let now = active_ref.fetch_add(1, Ordering::SeqCst) + 1;
                        let _ = max_ref.fetch_max(now, Ordering::SeqCst);
                        tokio::time::sleep(std::time::Duration::from_millis(10)).await;
                        active_ref.fetch_sub(1, Ordering::SeqCst);
                    })
                    .await;
            }));
        }
        for handle in handles {
            handle.await.expect("join");
        }

        assert_eq!(max_seen.load(Ordering::SeqCst), 1);
    }
}
