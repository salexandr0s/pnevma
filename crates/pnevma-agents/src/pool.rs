use pnevma_core::{Priority, TaskId};
use std::cmp::Ordering;
use std::collections::BinaryHeap;
use tokio::sync::{Mutex, Notify};

#[derive(Debug, Clone)]
pub struct QueuedDispatch {
    pub task_id: TaskId,
    pub priority: Priority,
}

#[derive(Debug)]
struct QueueItem {
    seq: u64,
    dispatch: QueuedDispatch,
}

impl QueueItem {
    fn rank(priority: &Priority) -> u8 {
        match priority {
            Priority::P0 => 0,
            Priority::P1 => 1,
            Priority::P2 => 2,
            Priority::P3 => 3,
        }
    }
}

impl PartialEq for QueueItem {
    fn eq(&self, other: &Self) -> bool {
        self.seq == other.seq
    }
}
impl Eq for QueueItem {}

impl PartialOrd for QueueItem {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for QueueItem {
    fn cmp(&self, other: &Self) -> Ordering {
        let a = Self::rank(&self.dispatch.priority);
        let b = Self::rank(&other.dispatch.priority);
        b.cmp(&a).then_with(|| other.seq.cmp(&self.seq))
    }
}

#[derive(Debug)]
struct Inner {
    max: usize,
    max_queue_depth: usize,
    active: usize,
    seq: u64,
    queue: BinaryHeap<QueueItem>,
}

#[derive(Debug)]
pub struct DispatchPool {
    inner: Mutex<Inner>,
    notify: Notify,
}

#[derive(Debug)]
pub struct DispatchPermit {
    pool: Option<std::sync::Arc<DispatchPool>>,
}

impl DispatchPermit {
    pub async fn release(mut self) {
        if let Some(pool) = self.pool.take() {
            pool.release().await;
        }
    }
}

impl Drop for DispatchPermit {
    fn drop(&mut self) {
        if let Some(pool) = self.pool.take() {
            // CONCURRENCY: Drop cannot be async, so we spawn a task to release the slot.
            // Guard with try_current() to avoid panic when no Tokio runtime is active
            // (e.g., during process shutdown).
            if let Ok(handle) = tokio::runtime::Handle::try_current() {
                handle.spawn(async move {
                    pool.release().await;
                });
            }
        }
    }
}

/// Result of a `try_acquire` call, distinguishing between immediate
/// acquisition, successful queuing, and queue-full rejection.
#[derive(Debug)]
pub enum TryAcquireResult {
    /// A permit was immediately acquired.
    Acquired(DispatchPermit),
    /// The dispatch was queued; the value is the current queue depth.
    Queued(usize),
    /// The queue is full; the value is the current queue depth.
    QueueFull(usize),
}

impl DispatchPool {
    pub fn new(max: usize) -> std::sync::Arc<Self> {
        Self::with_queue_limit(max, 32)
    }

    pub fn with_queue_limit(max: usize, max_queue_depth: usize) -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self {
            inner: Mutex::new(Inner {
                max,
                max_queue_depth,
                active: 0,
                seq: 0,
                queue: BinaryHeap::new(),
            }),
            notify: Notify::new(),
        })
    }

    pub async fn try_acquire(
        self: &std::sync::Arc<Self>,
        dispatch: QueuedDispatch,
    ) -> TryAcquireResult {
        let mut inner = self.inner.lock().await;
        if inner.active < inner.max {
            inner.active += 1;
            return TryAcquireResult::Acquired(DispatchPermit {
                pool: Some(self.clone()),
            });
        }

        if inner.queue.len() >= inner.max_queue_depth {
            return TryAcquireResult::QueueFull(inner.queue.len());
        }

        let seq = inner.seq;
        inner.seq = inner.seq.wrapping_add(1);
        inner.queue.push(QueueItem { seq, dispatch });
        TryAcquireResult::Queued(inner.queue.len())
    }

    pub async fn wait_next(self: &std::sync::Arc<Self>) -> QueuedDispatch {
        // CONCURRENCY: Register the notified future BEFORE checking state under
        // the lock to avoid missed notifications (standard Notify pattern).
        loop {
            let notified = self.notify.notified();
            {
                let mut inner = self.inner.lock().await;
                if inner.active < inner.max {
                    if let Some(item) = inner.queue.pop() {
                        inner.active += 1;
                        return item.dispatch;
                    }
                }
            }
            notified.await;
        }
    }

    async fn release(self: &std::sync::Arc<Self>) {
        let mut inner = self.inner.lock().await;
        if inner.active > 0 {
            inner.active -= 1;
        }
        drop(inner);
        self.notify.notify_waiters();
    }

    pub async fn state(&self) -> (usize, usize, usize, usize) {
        let inner = self.inner.lock().await;
        (
            inner.max,
            inner.active,
            inner.queue.len(),
            inner.max_queue_depth,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[tokio::test]
    async fn queue_depth_limit_rejects_when_full() {
        let pool = DispatchPool::with_queue_limit(1, 2);
        // Acquire the one slot
        let result = pool
            .try_acquire(QueuedDispatch {
                task_id: Uuid::new_v4(),
                priority: pnevma_core::Priority::P2,
            })
            .await;
        let _permit = match result {
            TryAcquireResult::Acquired(p) => p,
            other => panic!("expected Acquired, got {:?}", other),
        };

        // Queue 2 items (up to limit)
        assert!(matches!(
            pool.try_acquire(QueuedDispatch {
                task_id: Uuid::new_v4(),
                priority: pnevma_core::Priority::P2,
            })
            .await,
            TryAcquireResult::Queued(_)
        ));
        assert!(matches!(
            pool.try_acquire(QueuedDispatch {
                task_id: Uuid::new_v4(),
                priority: pnevma_core::Priority::P2,
            })
            .await,
            TryAcquireResult::Queued(_)
        ));

        // Third queue attempt should be rejected (queue full)
        assert!(matches!(
            pool.try_acquire(QueuedDispatch {
                task_id: Uuid::new_v4(),
                priority: pnevma_core::Priority::P2,
            })
            .await,
            TryAcquireResult::QueueFull(_)
        ));
    }

    #[tokio::test]
    async fn state_reports_correct_values() {
        let pool = DispatchPool::with_queue_limit(3, 10);
        let (max, active, queued, max_queue) = pool.state().await;
        assert_eq!(max, 3);
        assert_eq!(active, 0);
        assert_eq!(queued, 0);
        assert_eq!(max_queue, 10);
    }
}
