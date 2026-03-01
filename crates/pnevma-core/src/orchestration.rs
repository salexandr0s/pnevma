use crate::{Priority, TaskId};
use std::cmp::Ordering;
use std::collections::BinaryHeap;
use tokio::sync::Mutex;

#[derive(Debug, Clone)]
pub struct DispatchRequest {
    pub task_id: TaskId,
    pub priority: Priority,
}

#[derive(Debug, Clone)]
pub enum DispatchResult {
    Started,
    Queued { position: usize },
}

#[derive(Debug, Clone)]
pub struct PoolState {
    pub max_concurrent: usize,
    pub active: usize,
    pub queued: usize,
}

#[derive(Debug, Clone)]
struct QueueItem {
    seq: u64,
    req: DispatchRequest,
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
        let a = Self::rank(&self.req.priority);
        let b = Self::rank(&other.req.priority);
        b.cmp(&a).then_with(|| other.seq.cmp(&self.seq))
    }
}

#[derive(Debug)]
struct Inner {
    max_concurrent: usize,
    active: usize,
    seq: u64,
    queue: BinaryHeap<QueueItem>,
}

#[derive(Debug)]
pub struct DispatchOrchestrator {
    inner: Mutex<Inner>,
}

impl DispatchOrchestrator {
    pub fn new(max_concurrent: usize) -> Self {
        Self {
            inner: Mutex::new(Inner {
                max_concurrent,
                active: 0,
                seq: 0,
                queue: BinaryHeap::new(),
            }),
        }
    }

    pub async fn request_dispatch(&self, req: DispatchRequest) -> DispatchResult {
        let mut inner = self.inner.lock().await;
        if inner.active < inner.max_concurrent {
            inner.active += 1;
            return DispatchResult::Started;
        }

        let seq = inner.seq;
        inner.seq += 1;
        inner.queue.push(QueueItem { seq, req });

        DispatchResult::Queued {
            position: inner.queue.len(),
        }
    }

    pub async fn complete_one(&self) -> Option<DispatchRequest> {
        let mut inner = self.inner.lock().await;
        if inner.active > 0 {
            inner.active -= 1;
        }

        let next = inner.queue.pop().map(|i| i.req);
        if next.is_some() {
            inner.active += 1;
        }
        next
    }

    pub async fn state(&self) -> PoolState {
        let inner = self.inner.lock().await;
        PoolState {
            max_concurrent: inner.max_concurrent,
            active: inner.active,
            queued: inner.queue.len(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use uuid::Uuid;

    #[tokio::test]
    async fn queues_when_full() {
        let pool = DispatchOrchestrator::new(1);
        let first = pool
            .request_dispatch(DispatchRequest {
                task_id: Uuid::new_v4(),
                priority: Priority::P2,
            })
            .await;
        assert!(matches!(first, DispatchResult::Started));

        let second = pool
            .request_dispatch(DispatchRequest {
                task_id: Uuid::new_v4(),
                priority: Priority::P0,
            })
            .await;
        assert!(matches!(second, DispatchResult::Queued { .. }));

        let next = pool.complete_one().await;
        assert!(next.is_some());
    }
}
