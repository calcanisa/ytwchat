use axum::{
    Json, Router,
    extract::{Path, State},
    http::StatusCode,
    routing::{delete, get, post},
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{collections::HashMap, time::Duration};
use uuid::Uuid;

use crate::{
    auth::AuthUser,
    error::{AppError, AppResult},
    models::PublicUser,
    state::AppState,
};

const MAX_GROUP_MEMBERS: usize = 256;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list).post(create))
        .route("/{id}", get(get_one))
        .route("/{id}/devices", get(devices))
        .route("/{id}/members", post(add_members))
        .route("/{id}/members/{user_id}", delete(remove_member))
}

#[derive(Serialize, Clone)]
pub struct MemberOut {
    #[serde(flatten)]
    pub user: PublicUser,
    pub role: String,
}

#[derive(Serialize)]
pub struct ConversationOut {
    pub id: Uuid,
    pub kind: String,
    pub epoch: i64,
    pub created_at: DateTime<Utc>,
    pub last_activity_at: DateTime<Utc>,
    pub members: Vec<MemberOut>,
}

#[derive(sqlx::FromRow)]
struct ConvRow {
    id: Uuid,
    kind: String,
    epoch: i64,
    created_at: DateTime<Utc>,
    last_activity_at: DateTime<Utc>,
}

#[derive(sqlx::FromRow)]
struct MemberRow {
    conversation_id: Uuid,
    id: Uuid,
    username: String,
    display_name: String,
    avatar_media_id: Option<Uuid>,
    role: String,
}

async fn hydrate(state: &AppState, rows: Vec<ConvRow>) -> AppResult<Vec<ConversationOut>> {
    let ids: Vec<Uuid> = rows.iter().map(|r| r.id).collect();
    let members = sqlx::query_as::<_, MemberRow>(
        "SELECT m.conversation_id, u.id, u.username, u.display_name, u.avatar_media_id, m.role
         FROM conversation_members m JOIN users u ON u.id = m.user_id
         WHERE m.conversation_id = ANY($1) AND u.deleted_at IS NULL ORDER BY m.joined_at",
    )
    .bind(&ids)
    .fetch_all(&state.db)
    .await?;
    let mut grouped: HashMap<Uuid, Vec<MemberOut>> = HashMap::new();
    for m in members {
        grouped.entry(m.conversation_id).or_default().push(MemberOut {
            user: PublicUser { id: m.id, username: m.username, display_name: m.display_name, avatar_media_id: m.avatar_media_id },
            role: m.role,
        });
    }
    Ok(rows
        .into_iter()
        .map(|r| ConversationOut {
            members: grouped.remove(&r.id).unwrap_or_default(),
            id: r.id,
            kind: r.kind,
            epoch: r.epoch,
            created_at: r.created_at,
            last_activity_at: r.last_activity_at,
        })
        .collect())
}

pub async fn member_role(state: &AppState, conversation_id: Uuid, user_id: Uuid) -> AppResult<Option<String>> {
    let row: Option<(String,)> = sqlx::query_as("SELECT role FROM conversation_members WHERE conversation_id = $1 AND user_id = $2")
        .bind(conversation_id)
        .bind(user_id)
        .fetch_optional(&state.db)
        .await?;
    Ok(row.map(|r| r.0))
}

pub async fn load(state: &AppState, conversation_id: Uuid) -> AppResult<ConversationOut> {
    let rows = sqlx::query_as::<_, ConvRow>("SELECT id, kind, epoch, created_at, last_activity_at FROM conversations WHERE id = $1")
        .bind(conversation_id)
        .fetch_all(&state.db)
        .await?;
    hydrate(state, rows).await?.pop().ok_or(AppError::NotFound("That conversation could not be found."))
}

pub async fn member_ids(state: &AppState, conversation_id: Uuid) -> AppResult<Vec<Uuid>> {
    let rows: Vec<(Uuid,)> = sqlx::query_as("SELECT user_id FROM conversation_members WHERE conversation_id = $1")
        .bind(conversation_id)
        .fetch_all(&state.db)
        .await?;
    Ok(rows.into_iter().map(|r| r.0).collect())
}

async fn notify_updated(state: &AppState, conversation_id: Uuid, extra_users: &[Uuid]) -> AppResult<()> {
    let mut users = member_ids(state, conversation_id).await?;
    users.extend_from_slice(extra_users);
    let payload = json!({ "type": "conversation.updated", "conversation_id": conversation_id }).to_string();
    for u in users {
        state.hub.send_user(u, &payload);
    }
    Ok(())
}

pub async fn notify_user_conversations(state: &AppState, user_id: Uuid) -> AppResult<()> {
    let rows: Vec<(Uuid, Uuid)> = sqlx::query_as(
        "SELECT DISTINCT o.conversation_id, o.user_id FROM conversation_members m
         JOIN conversation_members o ON o.conversation_id = m.conversation_id
         WHERE m.user_id = $1",
    )
    .bind(user_id)
    .fetch_all(&state.db)
    .await?;
    send_updates(state, &rows);
    Ok(())
}

pub fn send_updates(state: &AppState, rows: &[(Uuid, Uuid)]) {
    for (conversation_id, member) in rows {
        let payload = json!({ "type": "conversation.updated", "conversation_id": conversation_id }).to_string();
        state.hub.send_user(*member, &payload);
    }
}

#[derive(Serialize, sqlx::FromRow)]
struct MemberDevice {
    user_id: Uuid,
    device_id: Uuid,
}

async fn devices(State(state): State<AppState>, auth: AuthUser, Path(id): Path<Uuid>) -> AppResult<Json<Vec<MemberDevice>>> {
    if member_role(&state, id, auth.user_id).await?.is_none() {
        return Err(AppError::NotFound("That conversation could not be found."));
    }
    let rows = sqlx::query_as::<_, MemberDevice>(
        "SELECT d.user_id, d.id AS device_id FROM devices d
         JOIN conversation_members m ON m.user_id = d.user_id AND m.conversation_id = $1
         JOIN users u ON u.id = d.user_id
         WHERE d.revoked_at IS NULL AND u.deleted_at IS NULL
           AND EXISTS (SELECT 1 FROM key_packages k WHERE k.device_id = d.id)
         ORDER BY d.user_id, d.id",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(rows))
}

async fn list(State(state): State<AppState>, auth: AuthUser) -> AppResult<Json<Vec<ConversationOut>>> {
    let rows = sqlx::query_as::<_, ConvRow>(
        "SELECT c.id, c.kind, c.epoch, c.created_at, c.last_activity_at
         FROM conversations c JOIN conversation_members m ON m.conversation_id = c.id
         WHERE m.user_id = $1 ORDER BY c.last_activity_at DESC LIMIT 500",
    )
    .bind(auth.user_id)
    .fetch_all(&state.db)
    .await?;
    Ok(Json(hydrate(&state, rows).await?))
}

async fn get_one(State(state): State<AppState>, auth: AuthUser, Path(id): Path<Uuid>) -> AppResult<Json<ConversationOut>> {
    if member_role(&state, id, auth.user_id).await?.is_none() {
        return Err(AppError::NotFound("That conversation could not be found."));
    }
    Ok(Json(load(&state, id).await?))
}

#[derive(Deserialize)]
struct CreateIn {
    kind: String,
    member_ids: Vec<Uuid>,
}

async fn check_reachable(state: &AppState, me: Uuid, others: &[Uuid]) -> AppResult<()> {
    let found: Vec<(Uuid,)> = sqlx::query_as(
        "SELECT u.id FROM users u WHERE u.id = ANY($1) AND u.deleted_at IS NULL
         AND NOT EXISTS (SELECT 1 FROM blocks b WHERE (b.user_id = u.id AND b.blocked_user_id = $2) OR (b.user_id = $2 AND b.blocked_user_id = u.id))",
    )
    .bind(others)
    .bind(me)
    .fetch_all(&state.db)
    .await?;
    if found.len() != others.len() {
        return Err(AppError::bad("member_unavailable", "One or more of those people cannot be added."));
    }
    Ok(())
}

async fn create(State(state): State<AppState>, auth: AuthUser, Json(body): Json<CreateIn>) -> AppResult<(StatusCode, Json<ConversationOut>)> {
    state.limiter.check(format!("conv:{}", auth.user_id), 60, Duration::from_secs(3600))?;
    let mut others: Vec<Uuid> = body.member_ids.into_iter().filter(|id| *id != auth.user_id).collect();
    others.sort();
    others.dedup();
    match body.kind.as_str() {
        "direct" => {
            if others.len() != 1 {
                return Err(AppError::bad("invalid_members", "A direct chat has exactly one other person."));
            }
            check_reachable(&state, auth.user_id, &others).await?;
            let other = others[0];
            let key = if auth.user_id < other { format!("{}:{}", auth.user_id, other) } else { format!("{}:{}", other, auth.user_id) };
            let mut tx = state.db.begin().await?;
            let existing: Option<(Uuid,)> = sqlx::query_as("SELECT id FROM conversations WHERE direct_key = $1 FOR UPDATE").bind(&key).fetch_optional(&mut *tx).await?;
            let (id, created) = match existing {
                Some((id,)) => (id, false),
                None => {
                    let id = Uuid::now_v7();
                    sqlx::query("INSERT INTO conversations (id, kind, created_by, direct_key) VALUES ($1, 'direct', $2, $3)")
                        .bind(id)
                        .bind(auth.user_id)
                        .bind(&key)
                        .execute(&mut *tx)
                        .await?;
                    (id, true)
                }
            };
            for user in [auth.user_id, other] {
                sqlx::query("INSERT INTO conversation_members (conversation_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING")
                    .bind(id)
                    .bind(user)
                    .execute(&mut *tx)
                    .await?;
            }
            tx.commit().await?;
            if created {
                notify_updated(&state, id, &[]).await?;
            }
            let status = if created { StatusCode::CREATED } else { StatusCode::OK };
            Ok((status, Json(load(&state, id).await?)))
        }
        "group" => {
            if others.is_empty() || others.len() + 1 > MAX_GROUP_MEMBERS {
                return Err(AppError::bad("invalid_members", "Groups need at least one other person and at most 256 members."));
            }
            check_reachable(&state, auth.user_id, &others).await?;
            let id = Uuid::now_v7();
            let mut tx = state.db.begin().await?;
            sqlx::query("INSERT INTO conversations (id, kind, created_by) VALUES ($1, 'group', $2)").bind(id).bind(auth.user_id).execute(&mut *tx).await?;
            sqlx::query("INSERT INTO conversation_members (conversation_id, user_id, role) VALUES ($1, $2, 'admin')").bind(id).bind(auth.user_id).execute(&mut *tx).await?;
            for user in &others {
                sqlx::query("INSERT INTO conversation_members (conversation_id, user_id) VALUES ($1, $2)").bind(id).bind(user).execute(&mut *tx).await?;
            }
            tx.commit().await?;
            notify_updated(&state, id, &[]).await?;
            Ok((StatusCode::CREATED, Json(load(&state, id).await?)))
        }
        _ => Err(AppError::bad("invalid_kind", "Conversation kind must be direct or group.")),
    }
}

#[derive(Deserialize)]
struct AddMembersIn {
    user_ids: Vec<Uuid>,
}

async fn add_members(State(state): State<AppState>, auth: AuthUser, Path(id): Path<Uuid>, Json(body): Json<AddMembersIn>) -> AppResult<Json<ConversationOut>> {
    let conv = load(&state, id).await?;
    if conv.kind != "group" || member_role(&state, id, auth.user_id).await?.as_deref() != Some("admin") {
        return Err(AppError::Forbidden("Only group admins can add people."));
    }
    let existing: Vec<Uuid> = conv.members.iter().map(|m| m.user.id).collect();
    let mut new: Vec<Uuid> = body.user_ids.into_iter().filter(|u| !existing.contains(u)).collect();
    new.sort();
    new.dedup();
    if new.is_empty() {
        return Ok(Json(conv));
    }
    if existing.len() + new.len() > MAX_GROUP_MEMBERS {
        return Err(AppError::bad("group_full", "Groups can have at most 256 members."));
    }
    check_reachable(&state, auth.user_id, &new).await?;
    let mut tx = state.db.begin().await?;
    for user in &new {
        sqlx::query("INSERT INTO conversation_members (conversation_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING").bind(id).bind(user).execute(&mut *tx).await?;
    }
    tx.commit().await?;
    notify_updated(&state, id, &[]).await?;
    Ok(Json(load(&state, id).await?))
}

async fn remove_member(State(state): State<AppState>, auth: AuthUser, Path((id, user_id)): Path<(Uuid, Uuid)>) -> AppResult<StatusCode> {
    let conv = load(&state, id).await?;
    let my_role = member_role(&state, id, auth.user_id).await?;
    if my_role.is_none() {
        return Err(AppError::NotFound("That conversation could not be found."));
    }
    if conv.kind != "group" {
        return Err(AppError::bad("not_group", "People can only be removed from groups."));
    }
    if user_id != auth.user_id && my_role.as_deref() != Some("admin") {
        return Err(AppError::Forbidden("Only group admins can remove people."));
    }
    let mut tx = state.db.begin().await?;
    sqlx::query("DELETE FROM conversation_members WHERE conversation_id = $1 AND user_id = $2").bind(id).bind(user_id).execute(&mut *tx).await?;
    sqlx::query(
        "DELETE FROM message_deliveries WHERE device_id IN (SELECT id FROM devices WHERE user_id = $2)
         AND message_id IN (SELECT id FROM messages WHERE conversation_id = $1)",
    )
    .bind(id)
    .bind(user_id)
    .execute(&mut *tx)
    .await?;
    let remaining: (i64, i64) = sqlx::query_as("SELECT count(*), count(*) FILTER (WHERE role = 'admin') FROM conversation_members WHERE conversation_id = $1")
        .bind(id)
        .fetch_one(&mut *tx)
        .await?;
    if remaining.0 == 0 {
        sqlx::query("DELETE FROM conversations WHERE id = $1").bind(id).execute(&mut *tx).await?;
    } else if remaining.1 == 0 {
        sqlx::query(
            "UPDATE conversation_members SET role = 'admin' WHERE conversation_id = $1 AND user_id =
             (SELECT user_id FROM conversation_members WHERE conversation_id = $1 ORDER BY joined_at LIMIT 1)",
        )
        .bind(id)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    if remaining.0 > 0 {
        notify_updated(&state, id, &[user_id]).await?;
    }
    Ok(StatusCode::NO_CONTENT)
}
