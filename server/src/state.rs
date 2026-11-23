use sqlx::PgPool;
use std::sync::Arc;

use crate::{config::Config, hub::Hub, ratelimit::RateLimiter};

#[derive(Clone)]
pub struct AppState {
    pub db: PgPool,
    pub cfg: Arc<Config>,
    pub hub: Arc<Hub>,
    pub limiter: Arc<RateLimiter>,
}
