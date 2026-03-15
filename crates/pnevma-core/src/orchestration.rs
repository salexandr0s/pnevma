use crate::{Priority, TaskId};
use std::cmp::Ordering;
use std::collections::{BinaryHeap, HashSet};
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
    active_or_queued: HashSet<TaskId>,
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
                active_or_queued: HashSet::new(),
            }),
        }
    }

    pub async fn request_dispatch(&self, req: DispatchRequest) -> DispatchResult {
        let mut inner = self.inner.lock().await;
        // Deduplicate: reject if this task ID is already active or queued
        if !inner.active_or_queued.insert(req.task_id) {
            return DispatchResult::Queued {
                position: inner.queue.len(),
            };
        }
        if inner.active < inner.max_concurrent {
            inner.active += 1;
            return DispatchResult::Started;
        }

        let seq = inner.seq;
        inner.seq = inner.seq.wrapping_add(1);
        inner.queue.push(QueueItem { seq, req });

        DispatchResult::Queued {
            position: inner.queue.len(),
        }
    }

    /// Mark one active task as complete and dequeue the next if available.
    /// `completed_task_id` is removed from the dedup set so it can be re-dispatched later.
    pub async fn complete_one(&self, completed_task_id: Option<TaskId>) -> Option<DispatchRequest> {
        let mut inner = self.inner.lock().await;
        if inner.active > 0 {
            inner.active -= 1;
        }
        // Remove completed task from dedup set so it can be re-dispatched.
        if let Some(id) = completed_task_id {
            inner.active_or_queued.remove(&id);
        }

        let next = inner.queue.pop().map(|i| i.req);
        if let Some(ref _req) = next {
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
    use proptest::prelude::*;
    use uuid::Uuid;

    fn priority_from_rank(rank: u8) -> Priority {
        match rank {
            0 => Priority::P0,
            1 => Priority::P1,
            2 => Priority::P2,
            _ => Priority::P3,
        }
    }

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

        let next = pool.complete_one(None).await;
        assert!(next.is_some());
    }

    proptest! {
        #[test]
        fn queued_dispatch_respects_priority_then_fifo(priority_ranks in prop::collection::vec(0u8..4, 1..40)) {
            let runtime = tokio::runtime::Runtime::new().expect("runtime");
            runtime.block_on(async move {
                let pool = DispatchOrchestrator::new(1);
                let first = pool
                    .request_dispatch(DispatchRequest {
                        task_id: Uuid::new_v4(),
                        priority: Priority::P3,
                    })
                    .await;
                assert!(matches!(first, DispatchResult::Started));

                let mut expected = Vec::new();
                for (seq, rank) in priority_ranks.iter().copied().enumerate() {
                    let task_id = Uuid::from_u128((seq + 1) as u128);
                    let priority = priority_from_rank(rank);
                    let queued = pool
                        .request_dispatch(DispatchRequest { task_id, priority })
                        .await;
                    assert!(matches!(queued, DispatchResult::Queued { .. }));
                    expected.push((rank, seq, task_id));
                }

                expected.sort_by_key(|(rank, seq, _)| (*rank, *seq));

                let mut actual = Vec::new();
                while let Some(next) = pool.complete_one(None).await {
                    actual.push(next.task_id);
                }

                let expected_ids = expected
                    .iter()
                    .map(|(_, _, task_id)| *task_id)
                    .collect::<Vec<_>>();
                assert_eq!(actual, expected_ids);

                let state = pool.state().await;
                assert_eq!(state.active, 0);
                assert_eq!(state.queued, 0);
            });
        }
    }
}
