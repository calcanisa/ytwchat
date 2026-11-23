use dashmap::DashMap;
use std::time::{Duration, Instant};

use crate::error::AppError;

#[derive(Default)]
pub struct RateLimiter {
    buckets: DashMap<String, (u32, Instant)>,
}

impl RateLimiter {
    pub fn check(&self, key: String, limit: u32, window: Duration) -> Result<(), AppError> {
        let now = Instant::now();
        let mut entry = self.buckets.entry(key).or_insert((0, now));
        if now.duration_since(entry.1) >= window {
            *entry = (0, now);
        }
        if entry.0 >= limit {
            return Err(AppError::RateLimited);
        }
        entry.0 += 1;
        Ok(())
    }

    pub fn prune(&self, max_window: Duration) {
        let now = Instant::now();
        self.buckets.retain(|_, (_, start)| now.duration_since(*start) < max_window);
    }
}
