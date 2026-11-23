# ytwchat server

Rust (Axum) backend for ytwchat. The server never sees message contents: clients encrypt with MLS (RFC 9420) and the server stores and routes opaque payloads.

## Run locally

```
cp ../.env.example ../.env
docker compose up -d --build
curl http://127.0.0.1:8101/health
```

Without Docker: run Postgres, then `DATABASE_URL=postgres://user:pass@localhost/ytwchat cargo run`. Migrations run on start.

## Tests

`cargo test` runs the API against a real Postgres. Each test creates its own database through `TEST_ADMIN_DATABASE_URL` (default `postgres://ytwchat:devpass@localhost/ytwchat`, a role with CREATEDB).

## API (all under `/v1`, JSON, `Authorization: Bearer <access_token>`)

| Area | Endpoints |
| --- | --- |
| Auth | `POST /auth/register`, `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout` |
| Me | `GET/PATCH/DELETE /users/me`, `GET /users/search?q=`, `GET /users/{id}` |
| Contacts | `GET/POST /contacts`, `DELETE /contacts/{id}`, `POST /contacts/lookup` |
| Blocks | `GET/POST /blocks`, `DELETE /blocks/{id}` |
| Devices | `GET /devices`, `DELETE /devices/{id}`, `PUT /devices/current/push-token` |
| MLS keys | `GET/POST /devices/current/key-packages`, `POST /key-packages/{user_id}/claim` |
| Conversations | `GET/POST /conversations`, `GET /conversations/{id}`, `POST /conversations/{id}/members`, `DELETE /conversations/{id}/members/{user_id}` |
| Messages | `POST /conversations/{id}/messages`, `GET /messages/pending`, `POST /messages/ack` |
| Media | `POST /media` (raw encrypted bytes), `GET /media/{id}` |
| Live | `GET /ws` (WebSocket; first frame `{"type":"auth","token":"..."}`) |

### Security model

- Access tokens live 15 minutes, refresh tokens 30 days, both stored only as SHA-256 hashes. Refresh tokens rotate on every use; reusing an old one revokes the whole session.
- Passwords use Argon2id. Login checks take the same time whether or not the email exists.
- Each sign-in creates a device. Revoking a device ends its sessions, removes its keys and closes its live connection.
- Messages are deleted once every recipient device acknowledges them, or after `RETENTION_DAYS`. Media and security logs expire the same way.
- MLS commits must name the current epoch; the server applies them in order and rejects stale ones (`409 epoch_conflict`).
- Blocking stops delivery, search, key package claims and new conversations, without telling the blocked person.
- Rate limits on registration, login, refresh, search, contact lookup, uploads, sends and live signals.
