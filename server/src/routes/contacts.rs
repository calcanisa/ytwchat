use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    routing::{delete, get, post},
};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    models::{PUBLIC_USER_COLUMNS, PublicUser},
    state::AppState,
    validate,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list).post(add))
        .route("/{id}", delete(remove))
        .route("/lookup", post(lookup))
}

pub fn blocks_router() -> Router<AppState> {
    Router::new().route("/", get(list_blocks).post(block)).route("/{id}", delete(unblock))
}

#[derive(Serialize)]
struct ContactOut {
    #[serde(flatten)]
    user: PublicUser,
    online: bool,
}

async fn list(State(state): State<AppState>, auth: AuthUser) -> AppResult<Json<Vec<ContactOut>>> {
    let sql = format!(
        "SELECT {PUBLIC_USER_COLUMNS} FROM contacts c JOIN users u ON u.id = c.contact_user_id
         WHERE c.user_id = $1 AND u.deleted_at IS NULL ORDER BY lower(u.display_name)"
    );
    let users = sqlx::query_as::<_, PublicUser>(&sql).bind(auth.user_id).fetch_all(&state.db).await?;
    let out = users.into_iter().map(|u| ContactOut { online: state.hub.is_online(u.id), user: u }).collect();
    Ok(Json(out))
}

#[derive(Deserialize)]
struct AddIn {
    contact_user_id: Uuid,
}

async fn add(State(state): State<AppState>, auth: AuthUser, Json(body): Json<AddIn>) -> AppResult<Json<PublicUser>> {
    if body.contact_user_id == auth.user_id {
        return Err(AppError::bad("invalid_contact", "You cannot add yourself."));
    }
    let sql = format!(
        "SELECT {PUBLIC_USER_COLUMNS} FROM users u WHERE u.id = $1 AND u.deleted_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM blocks b WHERE b.user_id = u.id AND b.blocked_user_id = $2)"
    );
    let user = sqlx::query_as::<_, PublicUser>(&sql).bind(body.contact_user_id).bind(auth.user_id).fetch_optional(&state.db).await?.ok_or(AppError::NotFound("That person could not be found."))?;
    let count: (i64,) = sqlx::query_as("SELECT count(*) FROM contacts WHERE user_id = $1").bind(auth.user_id).fetch_one(&state.db).await?;
    if count.0 >= 5000 {
        return Err(AppError::bad("contact_limit", "You have reached the contact limit."));
    }
    sqlx::query("INSERT INTO contacts (user_id, contact_user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING")
        .bind(auth.user_id)
        .bind(body.contact_user_id)
        .execute(&state.db)
        .await?;
    Ok(Json(user))
}

async fn remove(State(state): State<AppState>, auth: AuthUser, Path(id): Path<Uuid>) -> AppResult<StatusCode> {
    sqlx::query("DELETE FROM contacts WHERE user_id = $1 AND contact_user_id = $2").bind(auth.user_id).bind(id).execute(&state.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize)]
struct LookupIn {
    phone_numbers: Vec<String>,
}

#[derive(Serialize, sqlx::FromRow)]
struct LookupOut {
    phone_number: String,
    #[sqlx(flatten)]
    #[serde(flatten)]
    user: PublicUser,
}

async fn lookup(State(state): State<AppState>, auth: AuthUser, Json(body): Json<LookupIn>) -> AppResult<Json<Vec<LookupOut>>> {
    state.limiter.check(format!("lookup:{}", auth.user_id), 10, Duration::from_secs(3600))?;
    if body.phone_numbers.len() > 1000 {
        return Err(AppError::bad("too_many_numbers", "Send at most 1000 numbers at a time."));
    }
    let mut numbers: Vec<String> = body.phone_numbers.iter().filter_map(|n| validate::phone(n)).collect();
    numbers.sort();
    numbers.dedup();
    if numbers.is_empty() {
        return Ok(Json(vec![]));
    }
    let sql = format!(
        "SELECT u.phone_e164 AS phone_number, {PUBLIC_USER_COLUMNS} FROM users u
         WHERE u.phone_verified AND u.phone_e164 = ANY($1) AND u.deleted_at IS NULL AND u.id <> $2
           AND NOT EXISTS (SELECT 1 FROM blocks b WHERE b.user_id = u.id AND b.blocked_user_id = $2)"
    );
    let found = sqlx::query_as::<_, LookupOut>(&sql).bind(&numbers).bind(auth.user_id).fetch_all(&state.db).await?;
    Ok(Json(found))
}

#[derive(Deserialize)]
struct BlockIn {
    user_id: Uuid,
}

async fn list_blocks(State(state): State<AppState>, auth: AuthUser) -> AppResult<Json<Vec<PublicUser>>> {
    let sql = format!("SELECT {PUBLIC_USER_COLUMNS} FROM blocks b JOIN users u ON u.id = b.blocked_user_id WHERE b.user_id = $1 ORDER BY b.created_at DESC");
    Ok(Json(sqlx::query_as::<_, PublicUser>(&sql).bind(auth.user_id).fetch_all(&state.db).await?))
}

async fn block(State(state): State<AppState>, auth: AuthUser, Json(body): Json<BlockIn>) -> AppResult<StatusCode> {
    if body.user_id == auth.user_id {
        return Err(AppError::bad("invalid_block", "You cannot block yourself."));
    }
    let exists: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM users WHERE id = $1").bind(body.user_id).fetch_optional(&state.db).await?;
    if exists.is_none() {
        return Err(AppError::NotFound("That person could not be found."));
    }
    sqlx::query("INSERT INTO blocks (user_id, blocked_user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING").bind(auth.user_id).bind(body.user_id).execute(&state.db).await?;
    sqlx::query("DELETE FROM contacts WHERE user_id = $1 AND contact_user_id = $2").bind(auth.user_id).bind(body.user_id).execute(&state.db).await?;
    Ok(StatusCode::NO_CONTENT)
}

async fn unblock(State(state): State<AppState>, auth: AuthUser, Path(id): Path<Uuid>) -> AppResult<StatusCode> {
    sqlx::query("DELETE FROM blocks WHERE user_id = $1 AND blocked_user_id = $2").bind(auth.user_id).bind(id).execute(&state.db).await?;
    Ok(StatusCode::NO_CONTENT)
}
