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
    pool: std::sync::Arc<DispatchPool>,
}

impl Drop for DispatchPermit {
    fn drop(&mut self) {
        // CONCURRENCY: Drop cannot be async, so we spawn a task to release the slot.
        // This is safe because Arc<DispatchPool> is Send+Sync and outlives the spawn.
        let pool = self.pool.clone();
        tokio::spawn(async move {
            pool.release().await;
        });
    }
}

impl DispatchPool {
    pub fn new(max: usize) -> std::sync::Arc<Self> {
        std::sync::Arc::new(Self {
            inner: Mutex::new(Inner {
                max,
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
    ) -> Result<DispatchPermit, usize> {
        let mut inner = self.inner.lock().await;
        if inner.active < inner.max {
            inner.active += 1;
            return Ok(DispatchPermit { pool: self.clone() });
        }

        let seq = inner.seq;
        inner.seq += 1;
        inner.queue.push(QueueItem { seq, dispatch });
        Err(inner.queue.len())
    }

    pub async fn wait_next(self: &std::sync::Arc<Self>) -> QueuedDispatch {
        // CONCURRENCY: The mutex is released before `.notified().await` so other
        // tasks can acquire and release permits while this waiter sleeps.
        loop {
            {
                let mut inner = self.inner.lock().await;
                if inner.active < inner.max {
                    if let Some(item) = inner.queue.pop() {
                        inner.active += 1;
                        return item.dispatch;
                    }
                }
            }
            self.notify.notified().await;
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

    pub async fn state(&self) -> (usize, usize, usize) {
        let inner = self.inner.lock().await;
        (inner.max, inner.active, inner.queue.len())
    }
}
