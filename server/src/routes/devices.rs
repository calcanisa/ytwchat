use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    routing::{delete, get, post, put},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    routes::auth::revoke_device,
    state::AppState,
};

const MAX_KEY_PACKAGES: i64 = 200;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list))
        .route("/{id}", delete(revoke))
        .route("/current/push-token", put(set_push_token))
        .route("/current/key-packages", post(upload_key_packages).get(key_package_count))
}

pub fn keys_router() -> Router<AppState> {
    Router::new().route("/{user_id}/claim", post(claim))
}

#[derive(Serialize, sqlx::FromRow)]
struct DeviceOut {
    id: Uuid,
    name: String,
    platform: String,
    created_at: DateTime<Utc>,
    last_seen_at: DateTime<Utc>,
    #[sqlx(skip)]
    current: bool,
}

async fn list(State(state): State<AppState>, auth: AuthUser) -> AppResult<Json<Vec<DeviceOut>>> {
    let mut devices = sqlx::query_as::<_, DeviceOut>(
        "SELECT id, name, platform, created_at, last_seen_at FROM devices WHERE user_id = $1 AND revoked_at IS NULL ORDER BY created_at",
    )
    .bind(auth.user_id)
    .fetch_all(&state.db)
    .await?;
    for d in devices.iter_mut() {
        d.current = d.id == auth.device_id;
    }
    Ok(Json(devices))
}

async fn revoke(State(state): State<AppState>, auth: AuthUser, Path(id): Path<Uuid>) -> AppResult<StatusCode> {
    let owned: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM devices WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL")
        .bind(id)
        .bind(auth.user_id)
        .fetch_optional(&state.db)
        .await?;
    if owned.is_none() {
        return Err(AppError::NotFound("That device could not be found."));
    }
    revoke_device(&state, id).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct PushIn {
    push_token: Option<String>,
}

async fn set_push_token(State(state): State<AppState>, auth: AuthUser, Json(body): Json<PushIn>) -> AppResult<StatusCode> {
    let token = body.push_token.map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
    if token.as_ref().is_some_and(|t| t.len() > 4096) {
        return Err(AppError::bad("invalid_push_token", "Push token is too long."));
    }
    sqlx::query("UPDATE devices SET push_token = $2 WHERE id = $1").bind(auth.device_id).bind(token).execute(&state.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct KeyPackagesIn {
    key_packages: Vec<String>,
    last_resort: Option<String>,
}

#[derive(Serialize)]
struct CountOut {
    available: i64,
    has_last_resort: bool,
}

fn decode_kp(raw: &str) -> AppResult<Vec<u8>> {
    let bytes = STANDARD.decode(raw.trim()).map_err(|_| AppError::bad("invalid_key_package", "Key packages must be base64."))?;
    if bytes.is_empty() || bytes.len() > 16384 {
        return Err(AppError::bad("invalid_key_package", "Key package size is not valid."));
    }
    Ok(bytes)
}

async fn upload_key_packages(State(state): State<AppState>, auth: AuthUser, Json(body): Json<KeyPackagesIn>) -> AppResult<Json<CountOut>> {
    state.limiter.check(format!("kp:{}", auth.device_id), 30, Duration::from_secs(3600))?;
    if body.key_packages.len() > 100 {
        return Err(AppError::bad("too_many_key_packages", "Upload at most 100 key packages at a time."));
    }
    let packages: Vec<Vec<u8>> = body.key_packages.iter().map(|k| decode_kp(k)).collect::<AppResult<_>>()?;
    let last_resort = body.last_resort.as_deref().map(decode_kp).transpose()?;
    let mut tx = state.db.begin().await?;
    let current: (i64,) = sqlx::query_as("SELECT count(*) FROM key_packages WHERE device_id = $1 AND NOT is_last_resort")
        .bind(auth.device_id)
        .fetch_one(&mut *tx)
        .await?;
    if current.0 + packages.len() as i64 > MAX_KEY_PACKAGES {
        return Err(AppError::bad("key_package_limit", "This device already has enough key packages stored."));
    }
    for kp in packages {
        sqlx::query("INSERT INTO key_packages (id, device_id, key_package) VALUES ($1, $2, $3)")
            .bind(Uuid::now_v7())
            .bind(auth.device_id)
            .bind(kp)
            .execute(&mut *tx)
            .await?;
    }
    if let Some(kp) = last_resort {
        sqlx::query("DELETE FROM key_packages WHERE device_id = $1 AND is_last_resort").bind(auth.device_id).execute(&mut *tx).await?;
        sqlx::query("INSERT INTO key_packages (id, device_id, key_package, is_last_resort) VALUES ($1, $2, $3, TRUE)")
            .bind(Uuid::now_v7())
            .bind(auth.device_id)
            .bind(kp)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    count_for(&state, auth.device_id).await.map(Json)
}

async fn count_for(state: &AppState, device_id: Uuid) -> AppResult<CountOut> {
    let row: (i64, bool) = sqlx::query_as(
        "SELECT count(*) FILTER (WHERE NOT is_last_resort), bool_or(is_last_resort) IS TRUE FROM key_packages WHERE device_id = $1",
    )
    .bind(device_id)
    .fetch_one(&state.db)
    .await?;
    Ok(CountOut { available: row.0, has_last_resort: row.1 })
}

async fn key_package_count(State(state): State<AppState>, auth: AuthUser) -> AppResult<Json<CountOut>> {
    count_for(&state, auth.device_id).await.map(Json)
}

#[derive(Serialize)]
struct ClaimedOut {
    device_id: Uuid,
    key_package: String,
}

async fn claim(State(state): State<AppState>, auth: AuthUser, Path(user_id): Path<Uuid>) -> AppResult<Json<Vec<ClaimedOut>>> {
    state.limiter.check(format!("claim:{}", auth.user_id), 120, Duration::from_secs(3600))?;
    let blocked: Option<(Uuid,)> = sqlx::query_as("SELECT user_id FROM blocks WHERE user_id = $1 AND blocked_user_id = $2")
        .bind(user_id)
        .bind(auth.user_id)
        .fetch_optional(&state.db)
        .await?;
    if blocked.is_some() {
        return Err(AppError::NotFound("That person could not be found."));
    }
    let mut tx = state.db.begin().await?;
    let devices: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT d.id FROM devices d JOIN users u ON u.id = d.user_id
         WHERE d.user_id = $1 AND d.revoked_at IS NULL AND u.deleted_at IS NULL AND d.id <> $2",
    )
    .bind(user_id)
    .bind(auth.device_id)
    .fetch_all(&mut *tx)
    .await?;
    let mut out = Vec::new();
    for (device_id,) in devices {
        let row: Option<(Uuid, Vec<u8>, bool)> = sqlx::query_as(
            "SELECT id, key_package, is_last_resort FROM key_packages WHERE device_id = $1
             ORDER BY is_last_resort, created_at LIMIT 1 FOR UPDATE SKIP LOCKED",
        )
        .bind(device_id)
        .fetch_optional(&mut *tx)
        .await?;
        if let Some((id, kp, last_resort)) = row {
            if !last_resort {
                sqlx::query("DELETE FROM key_packages WHERE id = $1").bind(id).execute(&mut *tx).await?;
            }
            out.push(ClaimedOut { device_id, key_package: STANDARD.encode(kp) });
        }
    }
    tx.commit().await?;
    Ok(Json(out))
}
