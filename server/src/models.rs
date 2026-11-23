use chrono::{DateTime, Utc};
use serde::Serialize;
use uuid::Uuid;

#[derive(Debug, Serialize, sqlx::FromRow, Clone)]
pub struct PublicUser {
    pub id: Uuid,
    pub username: String,
    pub display_name: String,
    pub avatar_media_id: Option<Uuid>,
}

#[derive(Debug, Serialize, sqlx::FromRow)]
pub struct Me {
    pub id: Uuid,
    pub username: String,
    pub display_name: String,
    pub email: String,
    pub email_verified: bool,
    pub phone_e164: Option<String>,
    pub phone_verified: bool,
    pub avatar_media_id: Option<Uuid>,
    pub has_password: bool,
    pub ytw_linked: bool,
    pub created_at: DateTime<Utc>,
}

pub const PUBLIC_USER_COLUMNS: &str = "u.id, u.username, u.display_name, u.avatar_media_id";

pub const ME_SELECT: &str = "SELECT id, username, display_name, email, email_verified, phone_e164, phone_verified, avatar_media_id, password_hash IS NOT NULL AS has_password, ytw_user_id IS NOT NULL AS ytw_linked, created_at FROM users WHERE id = $1 AND deleted_at IS NULL";
