use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::StatusCode,
    routing::get,
};
use serde::Deserialize;
use std::time::Duration;
use uuid::Uuid;

use crate::{
    auth::{AuthUser, ClientIp},
    error::{AppError, AppResult},
    models::{ME_SELECT, Me, PUBLIC_USER_COLUMNS, PublicUser},
    password,
    routes::auth::log_event,
    state::AppState,
    validate,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/me", get(me).patch(update_me).delete(delete_me))
        .route("/search", get(search))
        .route("/{id}", get(get_user))
}

async fn me(State(state): State<AppState>, auth: AuthUser) -> AppResult<Json<Me>> {
    let me = sqlx::query_as::<_, Me>(ME_SELECT).bind(auth.user_id).fetch_optional(&state.db).await?.ok_or(AppError::Unauthorized)?;
    Ok(Json(me))
}

#[derive(Deserialize)]
struct UpdateMe {
    display_name: Option<String>,
    avatar_media_id: Option<Option<Uuid>>,
}

async fn update_me(State(state): State<AppState>, auth: AuthUser, Json(body): Json<UpdateMe>) -> AppResult<Json<Me>> {
    if let Some(name) = body.display_name {
        let name = validate::display_name(&name)?;
        sqlx::query("UPDATE users SET display_name = $2, updated_at = now() WHERE id = $1").bind(auth.user_id).bind(name).execute(&state.db).await?;
    }
    if let Some(avatar) = body.avatar_media_id {
        if let Some(media_id) = avatar {
            let owned: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM media WHERE id = $1 AND uploader_user_id = $2")
                .bind(media_id)
                .bind(auth.user_id)
                .fetch_optional(&state.db)
                .await?;
            if owned.is_none() {
                return Err(AppError::bad("invalid_avatar", "Upload the photo first, then set it as your avatar."));
            }
            sqlx::query("UPDATE media SET expires_at = 'infinity' WHERE id = $1").bind(media_id).execute(&state.db).await?;
        }
        sqlx::query("UPDATE users SET avatar_media_id = $2, updated_at = now() WHERE id = $1").bind(auth.user_id).bind(avatar).execute(&state.db).await?;
    }
    me(State(state), auth).await
}

#[derive(Deserialize)]
struct DeleteMe {
    password: Option<String>,
}

async fn delete_me(State(state): State<AppState>, auth: AuthUser, ip: ClientIp, Json(body): Json<DeleteMe>) -> AppResult<StatusCode> {
    state.limiter.check(format!("delete:{}", auth.user_id), 5, Duration::from_secs(900))?;
    let stored: Option<(Option<String>,)> = sqlx::query_as("SELECT password_hash FROM users WHERE id = $1").bind(auth.user_id).fetch_optional(&state.db).await?;
    let stored = stored.ok_or(AppError::Unauthorized)?.0;
    if stored.is_some() {
        let ok = password::verify_blocking(body.password.unwrap_or_default(), stored).await;
        if !ok {
            return Err(AppError::bad("invalid_password", "That password is not correct."));
        }
    }
    let media: Vec<(Uuid,)> = sqlx::query_as("SELECT id FROM media WHERE uploader_user_id = $1").bind(auth.user_id).fetch_all(&state.db).await?;
    let devices: Vec<(Uuid,)> = sqlx::query_as("SELECT id FROM devices WHERE user_id = $1").bind(auth.user_id).fetch_all(&state.db).await?;
    let watchers: Vec<(Uuid, Uuid)> = sqlx::query_as(
        "SELECT DISTINCT o.conversation_id, o.user_id FROM conversation_members m
         JOIN conversation_members o ON o.conversation_id = m.conversation_id
         WHERE m.user_id = $1 AND o.user_id <> $1",
    )
    .bind(auth.user_id)
    .fetch_all(&state.db)
    .await?;
    log_event(&state, None, &ip, "account_deleted").await;
    sqlx::query("DELETE FROM users WHERE id = $1").bind(auth.user_id).execute(&state.db).await?;
    for (id,) in media {
        let _ = tokio::fs::remove_file(state.cfg.media_dir.join(id.to_string())).await;
    }
    for (id,) in devices {
        state.hub.disconnect_device(id);
    }
    crate::routes::conversations::send_updates(&state, &watchers);
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct SearchQ {
    q: String,
}

async fn search(State(state): State<AppState>, auth: AuthUser, Query(q): Query<SearchQ>) -> AppResult<Json<Vec<PublicUser>>> {
    state.limiter.check(format!("search:{}", auth.user_id), 60, Duration::from_secs(60))?;
    let term: String = q.q.trim().trim_start_matches('@').to_lowercase().chars().filter(|c| c.is_ascii_alphanumeric() || *c == '_').take(30).collect();
    if term.len() < 3 {
        return Ok(Json(vec![]));
    }
    let sql = format!(
        "SELECT {PUBLIC_USER_COLUMNS} FROM users u
         WHERE u.deleted_at IS NULL AND u.id <> $1 AND u.username LIKE $2
           AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.user_id = u.id AND b.blocked_user_id = $1) OR (b.user_id = $1 AND b.blocked_user_id = u.id))
         ORDER BY (u.username = $3) DESC, u.username LIMIT 20"
    );
    let users = sqlx::query_as::<_, PublicUser>(&sql)
        .bind(auth.user_id)
        .bind(format!("{term}%"))
        .bind(&term)
        .fetch_all(&state.db)
        .await?;
    Ok(Json(users))
}

async fn get_user(State(state): State<AppState>, auth: AuthUser, Path(id): Path<Uuid>) -> AppResult<Json<PublicUser>> {
    let sql = format!(
        "SELECT {PUBLIC_USER_COLUMNS} FROM users u WHERE u.id = $1 AND u.deleted_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM blocks b WHERE b.user_id = u.id AND b.blocked_user_id = $2)"
    );
    let user = sqlx::query_as::<_, PublicUser>(&sql).bind(id).bind(auth.user_id).fetch_optional(&state.db).await?.ok_or(AppError::NotFound("That person could not be found."))?;
    Ok(Json(user))
}
