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
        let rpm = NonZeroU32::new(requests_per_minute.max(1)).expect(
            "requests_per_minute.max(1) is always >= 1, so NonZeroU32 construction cannot fail",
        );
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

    #[test]
    fn rate_limit_state_creates_per_ip_limiter() {
        let state = RateLimitState::new(60);
        let ip1: IpAddr = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 1));
        let ip2: IpAddr = IpAddr::V4(Ipv4Addr::new(10, 0, 0, 2));
        let l1 = state.limiter_for(ip1);
        let l2 = state.limiter_for(ip2);
        // Should be able to check without exhausting (60/min quota)
        assert!(l1.check().is_ok());
        assert!(l2.check().is_ok());
    }

    #[test]
    fn rate_limit_state_exhausts_at_threshold() {
        // 1 request per minute: second check should fail
        let state = RateLimitState::new(1);
        let ip: IpAddr = IpAddr::V4(Ipv4Addr::new(192, 168, 1, 1));
        let limiter = state.limiter_for(ip);

        assert!(limiter.check().is_ok(), "first request should pass");
        assert!(
            limiter.check().is_err(),
            "second request should be rate-limited"
        );
    }

    #[test]
    fn rate_limit_state_max_one_clamped_to_one() {
        // max(0, 1) = 1, so creating with 0 should work without panic
        let state = RateLimitState::new(0);
        let ip: IpAddr = IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1));
        let limiter = state.limiter_for(ip);
        // First call uses the 1 token
        let _ = limiter.check();
        // Second should fail since quota is 1/min
        assert!(limiter.check().is_err());
    }

    #[test]
    fn same_ip_returns_same_limiter_instance() {
        let state = RateLimitState::new(10);
        let ip: IpAddr = IpAddr::V4(Ipv4Addr::new(172, 16, 0, 1));
        let l1 = state.limiter_for(ip);
        let l2 = state.limiter_for(ip);
        // Both should point to the same underlying limiter (shared state)
        // Consume a token via l1; l2 should see the reduced quota
        let _ = l1.check();
        // If they share state, a high-quota limiter won't exhaust after 1 request
        // We can only verify no panic and both Arc pointers work
        assert!(Arc::ptr_eq(&l1, &l2));
    }
}
