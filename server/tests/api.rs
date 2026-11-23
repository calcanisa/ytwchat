use base64::{Engine, engine::general_purpose::STANDARD};
use futures::{SinkExt, StreamExt};
use reqwest::{Client, StatusCode};
use serde_json::{Value, json};
use sqlx::{Connection, PgConnection};
use std::{net::SocketAddr, path::PathBuf, time::Duration};
use tokio_tungstenite::tungstenite::Message;
use uuid::Uuid;
use ytwchat_server::{app, build_state, config::Config};

struct Server {
    base: String,
    ws: String,
    http: Client,
}

async fn spawn() -> Server {
    let admin = std::env::var("TEST_ADMIN_DATABASE_URL").unwrap_or_else(|_| "postgres://ytwchat:devpass@localhost/ytwchat".into());
    let name = format!("ytwchat_test_{}", Uuid::new_v4().simple());
    let mut conn = PgConnection::connect(&admin).await.expect("admin connect");
    sqlx::query(&format!("CREATE DATABASE {name}")).execute(&mut conn).await.expect("create db");
    let base_url = admin.rsplit_once('/').map(|(b, _)| b.to_string()).unwrap();
    let media_dir = PathBuf::from(format!("/tmp/{name}"));
    let cfg = Config {
        database_url: format!("{base_url}/{name}"),
        bind_addr: "127.0.0.1:0".parse().unwrap(),
        media_dir,
        media_max_bytes: 1024 * 1024,
        trust_proxy: false,
        cors_origins: vec![],
        retention: Duration::from_secs(30 * 86_400),
        access_ttl: Duration::from_secs(900),
        refresh_ttl: Duration::from_secs(86_400),
    };
    let state = build_state(cfg).await.expect("state");
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        axum::serve(listener, app(state).into_make_service_with_connect_info::<SocketAddr>()).await.unwrap();
    });
    Server { base: format!("http://{addr}/v1"), ws: format!("ws://{addr}/v1/ws"), http: Client::new() }
}

struct Account {
    token: String,
    refresh: String,
    user_id: String,
    device_id: String,
}

impl Server {
    async fn register(&self, username: &str) -> Account {
        let res = self
            .http
            .post(format!("{}/auth/register", self.base))
            .json(&json!({
                "username": username,
                "display_name": username.to_uppercase(),
                "email": format!("{username}@example.com"),
                "password": "correct horse battery",
                "device": { "name": "Test phone", "platform": "android" }
            }))
            .send()
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK, "{}", res.text().await.unwrap());
        let body: Value = res.json().await.unwrap();
        Account {
            token: body["access_token"].as_str().unwrap().into(),
            refresh: body["refresh_token"].as_str().unwrap().into(),
            user_id: body["user"]["id"].as_str().unwrap().into(),
            device_id: body["device_id"].as_str().unwrap().into(),
        }
    }

    async fn login(&self, username: &str) -> Account {
        let res = self
            .http
            .post(format!("{}/auth/login", self.base))
            .json(&json!({ "email": format!("{username}@example.com"), "password": "correct horse battery", "device": { "name": "Laptop", "platform": "desktop" } }))
            .send()
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        let body: Value = res.json().await.unwrap();
        Account {
            token: body["access_token"].as_str().unwrap().into(),
            refresh: body["refresh_token"].as_str().unwrap().into(),
            user_id: body["user"]["id"].as_str().unwrap().into(),
            device_id: body["device_id"].as_str().unwrap().into(),
        }
    }

    async fn get(&self, a: &Account, path: &str) -> (StatusCode, Value) {
        let res = self.http.get(format!("{}{path}", self.base)).bearer_auth(&a.token).send().await.unwrap();
        let status = res.status();
        (status, res.json().await.unwrap_or(Value::Null))
    }

    async fn post(&self, a: &Account, path: &str, body: Value) -> (StatusCode, Value) {
        let res = self.http.post(format!("{}{path}", self.base)).bearer_auth(&a.token).json(&body).send().await.unwrap();
        let status = res.status();
        (status, res.json().await.unwrap_or(Value::Null))
    }
}

#[tokio::test]
async fn auth_flow_and_refresh_reuse_detection() {
    let s = spawn().await;
    let a = s.register("alice").await;

    let dup = s
        .http
        .post(format!("{}/auth/register", s.base))
        .json(&json!({ "username": "alice", "display_name": "A", "email": "other@example.com", "password": "correct horse battery", "device": { "name": "x", "platform": "ios" } }))
        .send()
        .await
        .unwrap();
    assert_eq!(dup.status(), StatusCode::CONFLICT);

    let bad = s
        .http
        .post(format!("{}/auth/login", s.base))
        .json(&json!({ "email": "alice@example.com", "password": "wrong password!", "device": { "name": "x", "platform": "ios" } }))
        .send()
        .await
        .unwrap();
    assert_eq!(bad.status(), StatusCode::BAD_REQUEST);

    let (status, me) = s.get(&a, "/users/me").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(me["username"], "alice");
    assert!(me.get("password_hash").is_none());

    let r1: Value = s.http.post(format!("{}/auth/refresh", s.base)).json(&json!({ "refresh_token": a.refresh })).send().await.unwrap().json().await.unwrap();
    let new_access = r1["access_token"].as_str().unwrap().to_string();
    let reused = s.http.post(format!("{}/auth/refresh", s.base)).json(&json!({ "refresh_token": a.refresh })).send().await.unwrap();
    assert_eq!(reused.status(), StatusCode::UNAUTHORIZED);
    let after = s.http.get(format!("{}/users/me", s.base)).bearer_auth(&new_access).send().await.unwrap();
    assert_eq!(after.status(), StatusCode::UNAUTHORIZED, "reuse must revoke the whole session");

    let b = s.login("alice").await;
    let out = s.http.post(format!("{}/auth/logout", s.base)).bearer_auth(&b.token).send().await.unwrap();
    assert_eq!(out.status(), StatusCode::NO_CONTENT);
    let (status, _) = s.get(&b, "/users/me").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn messaging_delivery_epochs_and_blocks() {
    let s = spawn().await;
    let a = s.register("anna").await;
    let b = s.register("ben").await;
    let b2 = s.login("ben").await;
    let c = s.register("cara").await;

    let (status, found) = s.get(&a, "/users/search?q=be").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(found.as_array().unwrap().len(), 0, "search needs at least 3 characters");
    let (_, found) = s.get(&a, "/users/search?q=ben").await;
    assert_eq!(found[0]["id"], b.user_id.as_str());

    let (status, conv) = s.post(&a, "/conversations", json!({ "kind": "direct", "member_ids": [b.user_id] })).await;
    assert_eq!(status, StatusCode::CREATED);
    let conv_id = conv["id"].as_str().unwrap().to_string();
    let (status, again) = s.post(&b, "/conversations", json!({ "kind": "direct", "member_ids": [a.user_id] })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(again["id"], conv_id.as_str());

    let (status, _) = s.get(&c, &format!("/conversations/{conv_id}")).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "non members cannot see the conversation");
    let (status, _) = s.post(&c, &format!("/conversations/{conv_id}/messages"), json!({ "kind": "application", "payload": STANDARD.encode(b"x") })).await;
    assert_eq!(status, StatusCode::NOT_FOUND);

    let (status, msg) = s.post(&a, &format!("/conversations/{conv_id}/messages"), json!({ "kind": "application", "epoch": 0, "payload": STANDARD.encode(b"ciphertext-1") })).await;
    assert_eq!(status, StatusCode::CREATED);
    let msg_id = msg["id"].as_str().unwrap().to_string();

    for dev in [&b, &b2] {
        let (_, pending) = s.get(dev, "/messages/pending").await;
        assert_eq!(pending.as_array().unwrap().len(), 1);
        assert_eq!(STANDARD.decode(pending[0]["payload"].as_str().unwrap()).unwrap(), b"ciphertext-1");
    }
    let (_, own) = s.get(&a, "/messages/pending").await;
    assert_eq!(own.as_array().unwrap().len(), 0, "sender device gets no copy");

    s.post(&b, "/messages/ack", json!({ "message_ids": [msg_id] })).await;
    let (_, still) = s.get(&b2, "/messages/pending").await;
    assert_eq!(still.as_array().unwrap().len(), 1, "other device still waiting");
    s.post(&b2, "/messages/ack", json!({ "message_ids": [msg_id] })).await;
    let (_, gone) = s.get(&b2, "/messages/pending").await;
    assert_eq!(gone.as_array().unwrap().len(), 0);

    let (status, _) = s.post(&a, &format!("/conversations/{conv_id}/messages"), json!({ "kind": "commit", "epoch": 0, "payload": STANDARD.encode(b"commit") })).await;
    assert_eq!(status, StatusCode::CREATED);
    let (status, err) = s.post(&b, &format!("/conversations/{conv_id}/messages"), json!({ "kind": "commit", "epoch": 0, "payload": STANDARD.encode(b"late commit") })).await;
    assert_eq!(status, StatusCode::CONFLICT);
    assert_eq!(err["error"]["code"], "epoch_conflict");

    let (status, _) = s.post(&a, &format!("/conversations/{conv_id}/messages"), json!({ "kind": "welcome", "payload": STANDARD.encode(b"w"), "recipient_device_ids": [c.device_id] })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "welcome only to member devices");

    s.post(&b, "/blocks", json!({ "user_id": a.user_id })).await;
    let before: usize = s.get(&b, "/messages/pending").await.1.as_array().unwrap().len();
    let (status, _) = s.post(&a, &format!("/conversations/{conv_id}/messages"), json!({ "kind": "application", "payload": STANDARD.encode(b"blocked") })).await;
    assert_eq!(status, StatusCode::CREATED, "blocked sender is not told");
    let after: usize = s.get(&b, "/messages/pending").await.1.as_array().unwrap().len();
    assert_eq!(before, after, "blocked messages are not delivered");
    let (status, _) = s.post(&a, "/conversations", json!({ "kind": "group", "member_ids": [b.user_id, c.user_id] })).await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "cannot add someone who blocked you");
    let (_, search) = s.get(&a, "/users/search?q=ben").await;
    assert_eq!(search.as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn groups_and_key_packages() {
    let s = spawn().await;
    let a = s.register("ama").await;
    let b = s.register("bob").await;
    let c = s.register("cyd").await;

    let kps: Vec<String> = (0..3).map(|i| STANDARD.encode(format!("kp-{i}"))).collect();
    let (status, count) = s.post(&b, "/devices/current/key-packages", json!({ "key_packages": kps, "last_resort": STANDARD.encode("last") })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(count["available"], 3);
    for expected in ["kp-0", "kp-1", "kp-2", "last", "last"] {
        let (_, claimed) = s.post(&a, &format!("/key-packages/{}/claim", b.user_id), json!({})).await;
        assert_eq!(STANDARD.decode(claimed[0]["key_package"].as_str().unwrap()).unwrap(), expected.as_bytes());
    }

    let (status, group) = s.post(&a, "/conversations", json!({ "kind": "group", "member_ids": [b.user_id] })).await;
    assert_eq!(status, StatusCode::CREATED);
    let gid = group["id"].as_str().unwrap().to_string();
    let (status, _) = s.post(&b, &format!("/conversations/{gid}/members"), json!({ "user_ids": [c.user_id] })).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "only admins add people");
    let (status, updated) = s.post(&a, &format!("/conversations/{gid}/members"), json!({ "user_ids": [c.user_id] })).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(updated["members"].as_array().unwrap().len(), 3);

    let res = s.http.delete(format!("{}/conversations/{gid}/members/{}", s.base, a.user_id)).bearer_auth(&a.token).send().await.unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let (_, after) = s.get(&b, &format!("/conversations/{gid}")).await;
    let admins = after["members"].as_array().unwrap().iter().filter(|m| m["role"] == "admin").count();
    assert_eq!(admins, 1, "a new admin is promoted when the last one leaves");
}

#[tokio::test]
async fn media_access_and_account_deletion() {
    let s = spawn().await;
    let a = s.register("ada").await;
    let b = s.register("bea").await;
    let c = s.register("cleo").await;

    let up = s.http.post(format!("{}/media", s.base)).bearer_auth(&a.token).body(vec![7u8; 2048]).send().await.unwrap();
    assert_eq!(up.status(), StatusCode::CREATED);
    let media: Value = up.json().await.unwrap();
    let mid = media["id"].as_str().unwrap().to_string();

    let too_big = s.http.post(format!("{}/media", s.base)).bearer_auth(&a.token).body(vec![0u8; 2 * 1024 * 1024]).send().await.unwrap();
    assert_eq!(too_big.status(), StatusCode::PAYLOAD_TOO_LARGE);

    let denied = s.http.get(format!("{}/media/{mid}", s.base)).bearer_auth(&c.token).send().await.unwrap();
    assert_eq!(denied.status(), StatusCode::NOT_FOUND, "strangers cannot fetch media");
    s.post(&a, "/conversations", json!({ "kind": "direct", "member_ids": [b.user_id] })).await;
    let ok = s.http.get(format!("{}/media/{mid}", s.base)).bearer_auth(&b.token).send().await.unwrap();
    assert_eq!(ok.status(), StatusCode::OK);
    assert_eq!(ok.bytes().await.unwrap().len(), 2048);

    let wrong = s.http.delete(format!("{}/users/me", s.base)).bearer_auth(&a.token).json(&json!({ "password": "nope nope nope" })).send().await.unwrap();
    assert_eq!(wrong.status(), StatusCode::BAD_REQUEST);
    let del = s.http.delete(format!("{}/users/me", s.base)).bearer_auth(&a.token).json(&json!({ "password": "correct horse battery" })).send().await.unwrap();
    assert_eq!(del.status(), StatusCode::NO_CONTENT);
    let (status, _) = s.get(&a, "/users/me").await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let gone = s.http.get(format!("{}/media/{mid}", s.base)).bearer_auth(&b.token).send().await.unwrap();
    assert_eq!(gone.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn websocket_delivery_signals_and_presence() {
    let s = spawn().await;
    let a = s.register("abe").await;
    let b = s.register("bree").await;
    s.post(&a, "/contacts", json!({ "contact_user_id": b.user_id })).await;
    let (_, conv) = s.post(&a, "/conversations", json!({ "kind": "direct", "member_ids": [b.user_id] })).await;
    let cid = conv["id"].as_str().unwrap().to_string();

    let (mut bad_ws, _) = tokio_tungstenite::connect_async(&s.ws).await.unwrap();
    bad_ws.send(Message::Text(json!({ "type": "auth", "token": "nope" }).to_string().into())).await.unwrap();
    let reply = bad_ws.next().await.unwrap().unwrap();
    assert!(reply.to_text().unwrap().contains("unauthorized"));

    let (mut wa, _) = tokio_tungstenite::connect_async(&s.ws).await.unwrap();
    wa.send(Message::Text(json!({ "type": "auth", "token": a.token }).to_string().into())).await.unwrap();
    assert!(wa.next().await.unwrap().unwrap().to_text().unwrap().contains("ready"));

    let (mut wb, _) = tokio_tungstenite::connect_async(&s.ws).await.unwrap();
    wb.send(Message::Text(json!({ "type": "auth", "token": b.token }).to_string().into())).await.unwrap();
    assert!(wb.next().await.unwrap().unwrap().to_text().unwrap().contains("ready"));

    let presence = tokio::time::timeout(Duration::from_secs(2), wa.next()).await.unwrap().unwrap().unwrap();
    let presence: Value = serde_json::from_str(presence.to_text().unwrap()).unwrap();
    assert_eq!(presence["type"], "presence");
    assert_eq!(presence["user_id"], b.user_id.as_str());

    s.post(&a, &format!("/conversations/{cid}/messages"), json!({ "kind": "application", "payload": STANDARD.encode(b"live") })).await;
    let event = tokio::time::timeout(Duration::from_secs(2), wb.next()).await.unwrap().unwrap().unwrap();
    let event: Value = serde_json::from_str(event.to_text().unwrap()).unwrap();
    assert_eq!(event["type"], "message.new");
    assert_eq!(event["message"]["sender_device_id"], a.device_id.as_str());

    wa.send(Message::Text(json!({ "type": "signal", "conversation_id": cid, "payload": STANDARD.encode(b"typing") }).to_string().into())).await.unwrap();
    let signal = tokio::time::timeout(Duration::from_secs(2), wb.next()).await.unwrap().unwrap().unwrap();
    let signal: Value = serde_json::from_str(signal.to_text().unwrap()).unwrap();
    assert_eq!(signal["type"], "signal");
    assert_eq!(signal["sender_user_id"], a.user_id.as_str());

    let res = s.http.delete(format!("{}/devices/{}", s.base, b.device_id)).bearer_auth(&b.token).send().await.unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let closed = tokio::time::timeout(Duration::from_secs(2), wb.next()).await.unwrap();
    assert!(matches!(closed, None | Some(Ok(Message::Close(_))) | Some(Err(_))), "revoked device is disconnected");
}
