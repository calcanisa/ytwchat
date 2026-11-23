use axum::{
    extract::{ConnectInfo, FromRequestParts},
    http::{HeaderMap, request::Parts},
};
use std::net::{IpAddr, SocketAddr};
use uuid::Uuid;

use crate::{error::AppError, state::AppState, tokens::hash_token};

#[derive(Clone, Copy, Debug)]
pub struct AuthUser {
    pub user_id: Uuid,
    pub device_id: Uuid,
    pub session_id: Uuid,
}

pub async fn authenticate(state: &AppState, token: &str) -> Result<AuthUser, AppError> {
    if token.is_empty() || token.len() > 128 {
        return Err(AppError::Unauthorized);
    }
    let row: Option<(Uuid, Uuid, Uuid)> = sqlx::query_as(
        "SELECT s.user_id, s.device_id, s.id
         FROM access_tokens a
         JOIN sessions s ON s.id = a.session_id
         JOIN devices d ON d.id = s.device_id
         JOIN users u ON u.id = s.user_id
         WHERE a.token_hash = $1 AND a.expires_at > now()
           AND s.revoked_at IS NULL AND d.revoked_at IS NULL AND u.deleted_at IS NULL",
    )
    .bind(hash_token(token))
    .fetch_optional(&state.db)
    .await?;
    let (user_id, device_id, session_id) = row.ok_or(AppError::Unauthorized)?;
    Ok(AuthUser { user_id, device_id, session_id })
}

impl FromRequestParts<AppState> for AuthUser {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let header = parts
            .headers
            .get(axum::http::header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .ok_or(AppError::Unauthorized)?;
        let token = header.strip_prefix("Bearer ").ok_or(AppError::Unauthorized)?;
        authenticate(state, token.trim()).await
    }
}

#[derive(Clone, Copy, Debug)]
pub struct ClientIp(pub IpAddr);

pub fn client_ip(headers: &HeaderMap, peer: Option<SocketAddr>, trust_proxy: bool) -> IpAddr {
    if trust_proxy
        && let Some(ip) = headers.get("x-real-ip").and_then(|v| v.to_str().ok()).and_then(|v| v.trim().parse::<IpAddr>().ok())
    {
        return ip;
    }
    peer.map(|p| p.ip()).unwrap_or(IpAddr::from([0, 0, 0, 0]))
}

impl FromRequestParts<AppState> for ClientIp {
    type Rejection = AppError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let peer = parts.extensions.get::<ConnectInfo<SocketAddr>>().map(|c| c.0);
        Ok(ClientIp(client_ip(&parts.headers, peer, state.cfg.trust_proxy)))
    }
}
