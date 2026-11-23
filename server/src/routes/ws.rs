use axum::{
    Router,
    extract::{
        State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    response::Response,
    routing::get,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::HashSet,
    time::{Duration, Instant},
};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::{auth::authenticate, routes::conversations::member_role, state::AppState};

const MAX_FRAME: usize = 300 * 1024;

pub fn router() -> Router<AppState> {
    Router::new().route("/", get(upgrade))
}

async fn upgrade(State(state): State<AppState>, ws: WebSocketUpgrade) -> Response {
    ws.max_message_size(MAX_FRAME).max_frame_size(MAX_FRAME).on_upgrade(move |socket| run(state, socket))
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ClientMsg {
    Auth { token: String },
    Ping,
    Signal { conversation_id: Uuid, payload: String, to_device_ids: Option<Vec<Uuid>> },
}

async fn presence(state: &AppState, user_id: Uuid, online: bool) {
    let watchers: Vec<(Uuid,)> = sqlx::query_as("SELECT user_id FROM contacts WHERE contact_user_id = $1")
        .bind(user_id)
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();
    let event = json!({ "type": "presence", "user_id": user_id, "online": online }).to_string();
    for (watcher,) in watchers {
        state.hub.send_user(watcher, &event);
    }
}

async fn run(state: AppState, socket: WebSocket) {
    let (mut sink, mut stream) = socket.split();

    let first = tokio::time::timeout(Duration::from_secs(10), stream.next()).await;
    let token = match first {
        Ok(Some(Ok(Message::Text(text)))) => match serde_json::from_str::<ClientMsg>(&text) {
            Ok(ClientMsg::Auth { token }) => token,
            _ => return,
        },
        _ => return,
    };
    let Ok(auth) = authenticate(&state, &token).await else {
        let _ = sink.send(Message::Text(json!({ "type": "error", "code": "unauthorized" }).to_string().into())).await;
        return;
    };

    let (tx, mut rx) = mpsc::channel::<String>(256);
    let (conn_id, first_device) = state.hub.register(auth.user_id, auth.device_id, tx);
    if first_device {
        presence(&state, auth.user_id, true).await;
    }
    let _ = sink.send(Message::Text(json!({ "type": "ready", "device_id": auth.device_id }).to_string().into())).await;

    let mut allowed: HashSet<Uuid> = HashSet::new();
    let mut window = Instant::now();
    let mut count: u32 = 0;
    let mut keepalive = tokio::time::interval(Duration::from_secs(30));
    keepalive.tick().await;

    loop {
        tokio::select! {
            out = rx.recv() => {
                match out {
                    Some(text) => {
                        if sink.send(Message::Text(text.into())).await.is_err() {
                            break;
                        }
                    }
                    None => break,
                }
            }
            _ = keepalive.tick() => {
                if sink.send(Message::Ping(Vec::new().into())).await.is_err() {
                    break;
                }
            }
            incoming = stream.next() => {
                let Some(Ok(msg)) = incoming else { break };
                let text = match msg {
                    Message::Text(t) => t,
                    Message::Close(_) => break,
                    _ => continue,
                };
                if window.elapsed() >= Duration::from_secs(1) {
                    window = Instant::now();
                    count = 0;
                }
                count += 1;
                if count > 30 {
                    continue;
                }
                match serde_json::from_str::<ClientMsg>(&text) {
                    Ok(ClientMsg::Ping) => {
                        let _ = sink.send(Message::Text(json!({ "type": "pong" }).to_string().into())).await;
                    }
                    Ok(ClientMsg::Signal { conversation_id, payload, to_device_ids }) => {
                        if payload.is_empty() || payload.len() > 200 * 1024 || STANDARD.decode(&payload).is_err() {
                            continue;
                        }
                        if !allowed.contains(&conversation_id) {
                            match member_role(&state, conversation_id, auth.user_id).await {
                                Ok(Some(_)) => { allowed.insert(conversation_id); }
                                _ => continue,
                            }
                        }
                        let devices: Vec<(Uuid,)> = sqlx::query_as(
                            "SELECT d.id FROM devices d JOIN conversation_members m ON m.user_id = d.user_id AND m.conversation_id = $1
                             WHERE d.revoked_at IS NULL AND d.id <> $2 AND ($3::uuid[] IS NULL OR d.id = ANY($3))
                               AND NOT EXISTS (SELECT 1 FROM blocks b WHERE b.user_id = d.user_id AND b.blocked_user_id = $4)",
                        )
                        .bind(conversation_id)
                        .bind(auth.device_id)
                        .bind(to_device_ids)
                        .bind(auth.user_id)
                        .fetch_all(&state.db)
                        .await
                        .unwrap_or_default();
                        let event = json!({
                            "type": "signal",
                            "conversation_id": conversation_id,
                            "sender_user_id": auth.user_id,
                            "sender_device_id": auth.device_id,
                            "payload": payload,
                        }).to_string();
                        for (device,) in devices {
                            state.hub.send_device(device, &event);
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    if state.hub.unregister(auth.user_id, auth.device_id, conn_id) {
        presence(&state, auth.user_id, false).await;
    }
}
