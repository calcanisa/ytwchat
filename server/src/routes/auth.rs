use axum::{Json, Router, extract::State, routing::post};
use chrono::Utc;
use serde::{Deserialize, Serialize};
use std::time::Duration;
use uuid::Uuid;

use crate::{
    auth::{AuthUser, ClientIp},
    error::{AppError, AppResult},
    models::{ME_SELECT, Me},
    password,
    state::AppState,
    tokens::{hash_token, new_token},
    validate,
};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/register", post(register))
        .route("/login", post(login))
        .route("/refresh", post(refresh))
        .route("/logout", post(logout))
}

#[derive(Deserialize)]
pub struct DeviceIn {
    pub name: String,
    pub platform: String,
}

#[derive(Deserialize)]
struct RegisterIn {
    username: String,
    display_name: String,
    email: String,
    password: String,
    device: DeviceIn,
}

#[derive(Deserialize)]
struct LoginIn {
    email: String,
    password: String,
    device: DeviceIn,
}

#[derive(Deserialize)]
struct RefreshIn {
    refresh_token: String,
}

#[derive(Serialize)]
pub struct TokensOut {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in: u64,
    pub device_id: Uuid,
}

#[derive(Serialize)]
struct AuthOut {
    #[serde(flatten)]
    tokens: TokensOut,
    user: Me,
}

pub async fn log_event(state: &AppState, user_id: Option<Uuid>, ip: &ClientIp, event: &str) {
    let _ = sqlx::query("INSERT INTO security_events (user_id, ip, event) VALUES ($1, $2::inet, $3)")
        .bind(user_id)
        .bind(ip.0.to_string())
        .bind(event)
        .execute(&state.db)
        .await;
}

async fn issue_tokens(state: &AppState, session_id: Uuid, device_id: Uuid, tx: &mut sqlx::PgConnection) -> AppResult<TokensOut> {
    let access = new_token();
    let refresh = new_token();
    let access_exp = Utc::now() + state.cfg.access_ttl;
    let refresh_exp = Utc::now() + state.cfg.refresh_ttl;
    sqlx::query("INSERT INTO access_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)")
        .bind(hash_token(&access))
        .bind(session_id)
        .bind(access_exp)
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO refresh_tokens (token_hash, session_id, expires_at) VALUES ($1, $2, $3)")
        .bind(hash_token(&refresh))
        .bind(session_id)
        .bind(refresh_exp)
        .execute(&mut *tx)
        .await?;
    Ok(TokensOut { access_token: access, refresh_token: refresh, expires_in: state.cfg.access_ttl.as_secs(), device_id })
}

pub async fn start_session(state: &AppState, user_id: Uuid, device: &DeviceIn) -> AppResult<TokensOut> {
    let name = validate::device_name(&device.name)?;
    let platform = validate::platform(&device.platform)?;
    let device_id = Uuid::now_v7();
    let session_id = Uuid::now_v7();
    let mut tx = state.db.begin().await?;
    sqlx::query("INSERT INTO devices (id, user_id, name, platform) VALUES ($1, $2, $3, $4)")
        .bind(device_id)
        .bind(user_id)
        .bind(name)
        .bind(platform)
        .execute(&mut *tx)
        .await?;
    sqlx::query("INSERT INTO sessions (id, user_id, device_id) VALUES ($1, $2, $3)")
        .bind(session_id)
        .bind(user_id)
        .bind(device_id)
        .execute(&mut *tx)
        .await?;
    let tokens = issue_tokens(state, session_id, device_id, &mut tx).await?;
    tx.commit().await?;
    Ok(tokens)
}

async fn load_me(state: &AppState, user_id: Uuid) -> AppResult<Me> {
    sqlx::query_as::<_, Me>(ME_SELECT)
        .bind(user_id)
        .fetch_optional(&state.db)
        .await?
        .ok_or(AppError::Unauthorized)
}

async fn register(State(state): State<AppState>, ip: ClientIp, Json(body): Json<RegisterIn>) -> AppResult<Json<AuthOut>> {
    state.limiter.check(format!("register:{}", ip.0), 5, Duration::from_secs(3600))?;
    let username = validate::username(&body.username)?;
    let display_name = validate::display_name(&body.display_name)?;
    let email = validate::email(&body.email)?;
    validate::password(&body.password)?;
    validate::device_name(&body.device.name)?;
    validate::platform(&body.device.platform)?;

    let (username_taken, email_taken): (Option<bool>, Option<bool>) = sqlx::query_as(
        "SELECT bool_or(username = $1), bool_or(lower(email) = lower($2)) FROM users WHERE username = $1 OR lower(email) = lower($2)",
    )
    .bind(&username)
    .bind(&email)
    .fetch_one(&state.db)
    .await?;
    if username_taken == Some(true) {
        return Err(AppError::Conflict("username_taken", "That username is taken. Try another one.".into()));
    }
    if email_taken == Some(true) {
        return Err(AppError::Conflict("email_in_use", "An account with that email already exists. Sign in instead.".into()));
    }

    let hash = password::hash_blocking(body.password).await?;
    let user_id = Uuid::now_v7();
    let inserted = sqlx::query("INSERT INTO users (id, username, display_name, email, password_hash) VALUES ($1, $2, $3, $4, $5)")
        .bind(user_id)
        .bind(&username)
        .bind(&display_name)
        .bind(&email)
        .bind(hash)
        .execute(&state.db)
        .await;
    if let Err(sqlx::Error::Database(db)) = &inserted
        && db.is_unique_violation()
    {
        return Err(AppError::Conflict("account_exists", "That username or email is already in use.".into()));
    }
    inserted?;

    let tokens = start_session(&state, user_id, &body.device).await?;
    log_event(&state, Some(user_id), &ip, "register").await;
    Ok(Json(AuthOut { tokens, user: load_me(&state, user_id).await? }))
}

async fn login(State(state): State<AppState>, ip: ClientIp, Json(body): Json<LoginIn>) -> AppResult<Json<AuthOut>> {
    let email = body.email.trim().to_lowercase();
    state.limiter.check(format!("login-ip:{}", ip.0), 20, Duration::from_secs(900))?;
    state.limiter.check(format!("login-email:{email}"), 8, Duration::from_secs(900))?;
    if body.password.chars().count() > 256 {
        return Err(AppError::bad("invalid_login", "Incorrect email or password."));
    }
    let row: Option<(Uuid, Option<String>)> =
        sqlx::query_as("SELECT id, password_hash FROM users WHERE lower(email) = $1 AND deleted_at IS NULL")
            .bind(&email)
            .fetch_optional(&state.db)
            .await?;
    let (user_id, stored) = match row {
        Some((id, hash)) => (Some(id), hash),
        None => (None, None),
    };
    let ok = password::verify_blocking(body.password, stored).await;
    let Some(user_id) = user_id.filter(|_| ok) else {
        log_event(&state, user_id, &ip, "login_failed").await;
        return Err(AppError::bad("invalid_login", "Incorrect email or password."));
    };
    let tokens = start_session(&state, user_id, &body.device).await?;
    log_event(&state, Some(user_id), &ip, "login").await;
    Ok(Json(AuthOut { tokens, user: load_me(&state, user_id).await? }))
}

async fn refresh(State(state): State<AppState>, ip: ClientIp, Json(body): Json<RefreshIn>) -> AppResult<Json<TokensOut>> {
    state.limiter.check(format!("refresh:{}", ip.0), 60, Duration::from_secs(300))?;
    if body.refresh_token.is_empty() || body.refresh_token.len() > 128 {
        return Err(AppError::Unauthorized);
    }
    let mut tx = state.db.begin().await?;
    let row: Option<(Uuid, Option<chrono::DateTime<Utc>>, Uuid, Uuid)> = sqlx::query_as(
        "SELECT r.session_id, r.used_at, s.device_id, s.user_id
         FROM refresh_tokens r
         JOIN sessions s ON s.id = r.session_id
         JOIN devices d ON d.id = s.device_id
         JOIN users u ON u.id = s.user_id
         WHERE r.token_hash = $1 AND r.expires_at > now()
           AND s.revoked_at IS NULL AND d.revoked_at IS NULL AND u.deleted_at IS NULL
         FOR UPDATE OF r",
    )
    .bind(hash_token(&body.refresh_token))
    .fetch_optional(&mut *tx)
    .await?;
    let Some((session_id, used_at, device_id, user_id)) = row else {
        return Err(AppError::Unauthorized);
    };
    if used_at.is_some() {
        sqlx::query("UPDATE sessions SET revoked_at = now() WHERE id = $1").bind(session_id).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM access_tokens WHERE session_id = $1").bind(session_id).execute(&mut *tx).await?;
        tx.commit().await?;
        log_event(&state, Some(user_id), &ip, "refresh_reuse_revoked").await;
        state.hub.disconnect_device(device_id);
        return Err(AppError::Unauthorized);
    }
    sqlx::query("UPDATE refresh_tokens SET used_at = now() WHERE token_hash = $1")
        .bind(hash_token(&body.refresh_token))
        .execute(&mut *tx)
        .await?;
    sqlx::query("UPDATE sessions SET last_used_at = now() WHERE id = $1").bind(session_id).execute(&mut *tx).await?;
    sqlx::query("UPDATE devices SET last_seen_at = now() WHERE id = $1").bind(device_id).execute(&mut *tx).await?;
    let tokens = issue_tokens(&state, session_id, device_id, &mut tx).await?;
    tx.commit().await?;
    Ok(Json(tokens))
}

async fn logout(State(state): State<AppState>, auth: AuthUser) -> AppResult<axum::http::StatusCode> {
    revoke_device(&state, auth.device_id).await?;
    Ok(axum::http::StatusCode::NO_CONTENT)
}

pub async fn revoke_device(state: &AppState, device_id: Uuid) -> AppResult<()> {
    let mut tx = state.db.begin().await?;
    sqlx::query("UPDATE devices SET revoked_at = now(), push_token = NULL WHERE id = $1").bind(device_id).execute(&mut *tx).await?;
    sqlx::query("UPDATE sessions SET revoked_at = now() WHERE device_id = $1").bind(device_id).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM access_tokens WHERE session_id IN (SELECT id FROM sessions WHERE device_id = $1)").bind(device_id).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM refresh_tokens WHERE session_id IN (SELECT id FROM sessions WHERE device_id = $1)").bind(device_id).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM key_packages WHERE device_id = $1").bind(device_id).execute(&mut *tx).await?;
    sqlx::query("DELETE FROM message_deliveries WHERE device_id = $1").bind(device_id).execute(&mut *tx).await?;
    tx.commit().await?;
    state.hub.disconnect_device(device_id);
    Ok(())
}
