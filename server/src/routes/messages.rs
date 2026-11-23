use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::time::Duration;
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    routes::conversations::member_role,
    state::AppState,
};

pub fn conversation_router() -> Router<AppState> {
    Router::new().route("/{id}/messages", post(send))
}

pub fn router() -> Router<AppState> {
    Router::new().route("/pending", get(pending)).route("/ack", post(ack))
}

#[derive(Serialize, sqlx::FromRow)]
pub struct MessageRow {
    pub id: Uuid,
    pub conversation_id: Uuid,
    pub sender_user_id: Uuid,
    pub sender_device_id: Uuid,
    pub kind: String,
    pub epoch: Option<i64>,
    #[serde(skip)]
    pub payload: Vec<u8>,
    pub created_at: DateTime<Utc>,
}

#[derive(Serialize)]
pub struct MessageOut {
    #[serde(flatten)]
    row: MessageRow,
    payload: String,
}

impl From<MessageRow> for MessageOut {
    fn from(row: MessageRow) -> Self {
        let payload = STANDARD.encode(&row.payload);
        Self { row, payload }
    }
}

#[derive(Deserialize)]
struct SendIn {
    kind: String,
    payload: String,
    epoch: Option<i64>,
    recipient_device_ids: Option<Vec<Uuid>>,
}

async fn send(State(state): State<AppState>, auth: AuthUser, Path(conversation_id): Path<Uuid>, Json(body): Json<SendIn>) -> AppResult<(StatusCode, Json<MessageOut>)> {
    state.limiter.check(format!("send:{}", auth.device_id), 600, Duration::from_secs(60))?;
    if member_role(&state, conversation_id, auth.user_id).await?.is_none() {
        return Err(AppError::NotFound("That conversation could not be found."));
    }
    if !matches!(body.kind.as_str(), "application" | "commit" | "welcome" | "proposal") {
        return Err(AppError::bad("invalid_kind", "Message kind must be application, commit, welcome or proposal."));
    }
    let payload = STANDARD.decode(body.payload.trim()).map_err(|_| AppError::bad("invalid_payload", "Payload must be base64."))?;
    if payload.is_empty() || payload.len() > 262_144 {
        return Err(AppError::bad("invalid_payload", "Payload must be between 1 byte and 256 KB."));
    }

    let mut tx = state.db.begin().await?;
    let (current_epoch, kind_conv): (i64, String) = sqlx::query_as("SELECT epoch, kind FROM conversations WHERE id = $1 FOR UPDATE")
        .bind(conversation_id)
        .fetch_one(&mut *tx)
        .await?;

    if body.kind == "commit" {
        let epoch = body.epoch.ok_or_else(|| AppError::bad("epoch_required", "Commits must include the epoch they apply to."))?;
        if epoch != current_epoch {
            return Err(AppError::Conflict("epoch_conflict", format!("The group is at epoch {current_epoch}. Fetch pending messages and retry.")));
        }
        sqlx::query("UPDATE conversations SET epoch = epoch + 1 WHERE id = $1").bind(conversation_id).execute(&mut *tx).await?;
    }

    let recipients: Vec<(Uuid, Uuid)> = if body.kind == "welcome" {
        let targets = body.recipient_device_ids.clone().unwrap_or_default();
        if targets.is_empty() || targets.len() > 1024 {
            return Err(AppError::bad("recipients_required", "Welcome messages must name the devices they are for."));
        }
        let rows: Vec<(Uuid, Uuid)> = sqlx::query_as(
            "SELECT d.id, d.user_id FROM devices d JOIN conversation_members m ON m.user_id = d.user_id AND m.conversation_id = $1
             WHERE d.id = ANY($2) AND d.revoked_at IS NULL",
        )
        .bind(conversation_id)
        .bind(&targets)
        .fetch_all(&mut *tx)
        .await?;
        if rows.len() != targets.len() {
            return Err(AppError::bad("invalid_recipients", "Every recipient device must belong to a member of this conversation."));
        }
        rows
    } else {
        sqlx::query_as(
            "SELECT d.id, d.user_id FROM devices d JOIN conversation_members m ON m.user_id = d.user_id AND m.conversation_id = $1
             WHERE d.revoked_at IS NULL AND d.id <> $2",
        )
        .bind(conversation_id)
        .bind(auth.device_id)
        .fetch_all(&mut *tx)
        .await?
    };

    let blocked_by: Vec<(Uuid,)> = if kind_conv == "direct" {
        sqlx::query_as("SELECT user_id FROM blocks WHERE blocked_user_id = $1").bind(auth.user_id).fetch_all(&mut *tx).await?
    } else {
        vec![]
    };
    let recipients: Vec<(Uuid, Uuid)> = recipients.into_iter().filter(|(_, user)| !blocked_by.iter().any(|(b,)| b == user)).collect();

    let id = Uuid::now_v7();
    let expires = Utc::now() + state.cfg.retention;
    let row = sqlx::query_as::<_, MessageRow>(
        "INSERT INTO messages (id, conversation_id, sender_user_id, sender_device_id, kind, epoch, payload, expires_at)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
         RETURNING id, conversation_id, sender_user_id, sender_device_id, kind, epoch, payload, created_at",
    )
    .bind(id)
    .bind(conversation_id)
    .bind(auth.user_id)
    .bind(auth.device_id)
    .bind(&body.kind)
    .bind(body.epoch)
    .bind(&payload)
    .bind(expires)
    .fetch_one(&mut *tx)
    .await?;
    let device_ids: Vec<Uuid> = recipients.iter().map(|(d, _)| *d).collect();
    if !device_ids.is_empty() {
        sqlx::query("INSERT INTO message_deliveries (message_id, device_id) SELECT $1, unnest($2::uuid[])").bind(id).bind(&device_ids).execute(&mut *tx).await?;
    }
    sqlx::query("UPDATE conversations SET last_activity_at = now() WHERE id = $1").bind(conversation_id).execute(&mut *tx).await?;
    if device_ids.is_empty() {
        sqlx::query("DELETE FROM messages WHERE id = $1").bind(id).execute(&mut *tx).await?;
    }
    tx.commit().await?;

    let out = MessageOut::from(row);
    let event = json!({ "type": "message.new", "message": &out }).to_string();
    for device in device_ids {
        state.hub.send_device(device, &event);
    }
    Ok((StatusCode::CREATED, Json(out)))
}

#[derive(Deserialize)]
struct PendingQ {
    limit: Option<i64>,
    after: Option<Uuid>,
}

async fn pending(State(state): State<AppState>, auth: AuthUser, Query(q): Query<PendingQ>) -> AppResult<Json<Vec<MessageOut>>> {
    let limit = q.limit.unwrap_or(200).clamp(1, 500);
    let rows = sqlx::query_as::<_, MessageRow>(
        "SELECT m.id, m.conversation_id, m.sender_user_id, m.sender_device_id, m.kind, m.epoch, m.payload, m.created_at
         FROM message_deliveries d JOIN messages m ON m.id = d.message_id
         WHERE d.device_id = $1 AND ($2::uuid IS NULL OR m.id > $2)
         ORDER BY m.id LIMIT $3",
    )
    .bind(auth.device_id)
    .bind(q.after)
    .bind(limit)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(rows.into_iter().map(MessageOut::from).collect()))
}

#[derive(Deserialize)]
struct AckIn {
    message_ids: Vec<Uuid>,
}

async fn ack(State(state): State<AppState>, auth: AuthUser, Json(body): Json<AckIn>) -> AppResult<StatusCode> {
    if body.message_ids.len() > 1000 {
        return Err(AppError::bad("too_many_ids", "Acknowledge at most 1000 messages at a time."));
    }
    if body.message_ids.is_empty() {
        return Ok(StatusCode::NO_CONTENT);
    }
    let mut tx = state.db.begin().await?;
    sqlx::query("DELETE FROM message_deliveries WHERE device_id = $1 AND message_id = ANY($2)").bind(auth.device_id).bind(&body.message_ids).execute(&mut *tx).await?;
    sqlx::query(
        "DELETE FROM messages m WHERE m.id = ANY($1)
         AND NOT EXISTS (SELECT 1 FROM message_deliveries d WHERE d.message_id = m.id)",
    )
    .bind(&body.message_ids)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;
    Ok(StatusCode::NO_CONTENT)
}
