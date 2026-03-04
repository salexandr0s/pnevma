use std::{net::IpAddr, num::NonZeroU32, sync::Arc, time::Instant};

use axum::{
    body::Body,
    extract::ConnectInfo,
    http::{Request, StatusCode},
    middleware::Next,
    response::Response,
};
use dashmap::DashMap;
use governor::{
    clock::DefaultClock,
    middleware::NoOpMiddleware,
    state::{InMemoryState, NotKeyed},
    Quota, RateLimiter,
};
use std::net::SocketAddr;

type Limiter = RateLimiter<NotKeyed, InMemoryState, DefaultClock, NoOpMiddleware>;

#[derive(Clone)]
pub struct RateLimitState {
    limiters: Arc<DashMap<IpAddr, (Arc<Limiter>, Instant)>>,
    quota: Quota,
}

impl RateLimitState {
    pub fn new(requests_per_minute: u32) -> Self {
        let rpm = NonZeroU32::new(requests_per_minute.max(1)).unwrap();
        Self {
            limiters: Arc::new(DashMap::new()),
            quota: Quota::per_minute(rpm),
        }
    }

    fn limiter_for(&self, ip: IpAddr) -> Arc<Limiter> {
        let now = Instant::now();
        self.limiters
            .entry(ip)
            .and_modify(|(_, last_seen)| *last_seen = now)
            .or_insert_with(|| (Arc::new(RateLimiter::direct(self.quota)), now))
            .0
            .clone()
    }

    /// Spawn a background task that evicts limiters not seen in the last 10 minutes.
    /// Prevents unbounded memory growth for long-running servers with many IPs.
    pub fn spawn_cleanup(&self) {
        let limiters = self.limiters.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(600));
            loop {
                interval.tick().await;
                let cutoff = Instant::now()
                    .checked_sub(std::time::Duration::from_secs(600))
                    .unwrap_or(Instant::now());
                limiters.retain(|_, (_, last_seen)| *last_seen > cutoff);
            }
        });
    }
}

/// Middleware that enforces per-IP rate limiting.
pub async fn rate_limit(
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    axum::extract::State(state): axum::extract::State<RateLimitState>,
    req: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    let limiter = state.limiter_for(addr.ip());
    match limiter.check() {
        Ok(_) => Ok(next.run(req).await),
        Err(_) => {
            tracing::warn!(remote_ip = %addr.ip(), "Rate limit exceeded");
            Err(StatusCode::TOO_MANY_REQUESTS)
        }
    }
}
