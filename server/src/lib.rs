pub mod auth;
pub mod cleanup;
pub mod config;
pub mod error;
pub mod hub;
pub mod models;
pub mod password;
pub mod ratelimit;
pub mod routes;
pub mod state;
pub mod tokens;
pub mod validate;

use axum::{
    Json, Router,
    extract::DefaultBodyLimit,
    http::{HeaderName, HeaderValue, Method, header},
    routing::get,
};
use serde_json::json;
use sqlx::postgres::PgPoolOptions;
use std::{sync::Arc, time::Duration};
use tower_http::{
    cors::{AllowOrigin, CorsLayer},
    set_header::SetResponseHeaderLayer,
    trace::TraceLayer,
};

use crate::{config::Config, hub::Hub, ratelimit::RateLimiter, state::AppState};

pub async fn build_state(cfg: Config) -> anyhow::Result<AppState> {
    let db = PgPoolOptions::new().max_connections(20).acquire_timeout(Duration::from_secs(5)).connect(&cfg.database_url).await?;
    sqlx::migrate!("./migrations").run(&db).await?;
    tokio::fs::create_dir_all(&cfg.media_dir).await?;
    Ok(AppState { db, cfg: Arc::new(cfg), hub: Arc::new(Hub::default()), limiter: Arc::new(RateLimiter::default()) })
}

pub fn app(state: AppState) -> Router {
    let media_max = state.cfg.media_max_bytes;
    let origins: Vec<HeaderValue> = state.cfg.cors_origins.iter().filter_map(|o| o.parse().ok()).collect();
    let cors = CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([Method::GET, Method::POST, Method::PATCH, Method::PUT, Method::DELETE])
        .allow_headers([header::AUTHORIZATION, header::CONTENT_TYPE])
        .max_age(Duration::from_secs(3600));

    let api = Router::new()
        .nest("/auth", routes::auth::router())
        .nest("/users", routes::users::router())
        .nest("/contacts", routes::contacts::router())
        .nest("/blocks", routes::contacts::blocks_router())
        .nest("/devices", routes::devices::router())
        .nest("/key-packages", routes::devices::keys_router())
        .nest("/conversations", routes::conversations::router().merge(routes::messages::conversation_router()))
        .nest("/messages", routes::messages::router())
        .nest("/media", routes::media::router(media_max))
        .nest("/ws", routes::ws::router())
        .layer(DefaultBodyLimit::max(1024 * 1024));

    Router::new()
        .route("/health", get(|| async { Json(json!({ "status": "ok" })) }))
        .nest("/v1", api)
        .layer(cors)
        .layer(SetResponseHeaderLayer::overriding(HeaderName::from_static("x-content-type-options"), HeaderValue::from_static("nosniff")))
        .layer(SetResponseHeaderLayer::overriding(HeaderName::from_static("referrer-policy"), HeaderValue::from_static("no-referrer")))
        .layer(SetResponseHeaderLayer::overriding(header::CACHE_CONTROL, HeaderValue::from_static("no-store")))
        .layer(TraceLayer::new_for_http())
        .with_state(state)
}
