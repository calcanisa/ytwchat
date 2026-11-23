use axum::{
    Json, Router,
    body::{Body, Bytes},
    extract::{DefaultBodyLimit, Path, State},
    http::{HeaderValue, StatusCode, header},
    response::Response,
    routing::{get, post},
};
use chrono::Utc;
use serde::Serialize;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    state::AppState,
};

pub fn router(max_bytes: usize) -> Router<AppState> {
    Router::new()
        .route("/", post(upload).layer(DefaultBodyLimit::max(max_bytes)))
        .route("/{id}", get(download))
}

#[derive(Serialize)]
struct UploadOut {
    id: Uuid,
    size_bytes: i64,
}

async fn upload(State(state): State<AppState>, auth: AuthUser, body: Bytes) -> AppResult<(StatusCode, Json<UploadOut>)> {
    state.limiter.check(format!("upload:{}", auth.user_id), 200, Duration::from_secs(3600))?;
    if body.is_empty() {
        return Err(AppError::bad("empty_upload", "The file is empty."));
    }
    if body.len() > state.cfg.media_max_bytes {
        return Err(AppError::PayloadTooLarge("That file is too large."));
    }
    let id = Uuid::new_v4();
    let dir = &state.cfg.media_dir;
    tokio::fs::create_dir_all(dir).await.map_err(anyhow::Error::from)?;
    let tmp = dir.join(format!("{id}.part"));
    let mut file = tokio::fs::OpenOptions::new().write(true).create_new(true).open(&tmp).await.map_err(anyhow::Error::from)?;
    file.write_all(&body).await.map_err(anyhow::Error::from)?;
    file.sync_all().await.map_err(anyhow::Error::from)?;
    tokio::fs::rename(&tmp, dir.join(id.to_string())).await.map_err(anyhow::Error::from)?;
    let size = body.len() as i64;
    sqlx::query("INSERT INTO media (id, uploader_user_id, size_bytes, expires_at) VALUES ($1, $2, $3, $4)")
        .bind(id)
        .bind(auth.user_id)
        .bind(size)
        .bind(Utc::now() + state.cfg.retention)
        .execute(&state.db)
        .await?;
    Ok((StatusCode::CREATED, Json(UploadOut { id, size_bytes: size })))
}

async fn download(State(state): State<AppState>, auth: AuthUser, Path(id): Path<Uuid>) -> AppResult<Response> {
    let allowed: Option<(Uuid,)> = sqlx::query_as(
        "SELECT m.id FROM media m WHERE m.id = $1 AND m.expires_at > now() AND (
            m.uploader_user_id = $2
            OR EXISTS (SELECT 1 FROM users u WHERE u.avatar_media_id = m.id)
            OR EXISTS (
                SELECT 1 FROM conversation_members a JOIN conversation_members b ON a.conversation_id = b.conversation_id
                WHERE a.user_id = m.uploader_user_id AND b.user_id = $2
            )
        )",
    )
    .bind(id)
    .bind(auth.user_id)
    .fetch_optional(&state.db)
    .await?;
    if allowed.is_none() {
        return Err(AppError::NotFound("That file is not available."));
    }
    let bytes = tokio::fs::read(state.cfg.media_dir.join(id.to_string())).await.map_err(|_| AppError::NotFound("That file is not available."))?;
    let mut res = Response::new(Body::from(bytes));
    let headers = res.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static("application/octet-stream"));
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static("private, max-age=86400, immutable"));
    headers.insert("x-content-type-options", HeaderValue::from_static("nosniff"));
    Ok(res)
}
