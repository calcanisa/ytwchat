use std::time::Duration;
use uuid::Uuid;

use crate::state::AppState;

pub async fn run_once(state: &AppState) -> anyhow::Result<()> {
    sqlx::query("DELETE FROM messages WHERE expires_at < now()").execute(&state.db).await?;
    sqlx::query("DELETE FROM access_tokens WHERE expires_at < now()").execute(&state.db).await?;
    sqlx::query("DELETE FROM refresh_tokens WHERE expires_at < now()").execute(&state.db).await?;
    sqlx::query("DELETE FROM security_events WHERE created_at < now() - make_interval(secs => $1)")
        .bind(state.cfg.retention.as_secs() as f64)
        .execute(&state.db)
        .await?;
    sqlx::query("DELETE FROM sessions WHERE revoked_at IS NOT NULL AND revoked_at < now() - interval '1 day'").execute(&state.db).await?;
    let expired: Vec<(Uuid,)> = sqlx::query_as(
        "DELETE FROM media m WHERE m.expires_at < now() AND NOT EXISTS (SELECT 1 FROM users u WHERE u.avatar_media_id = m.id) RETURNING m.id",
    )
    .fetch_all(&state.db)
    .await?;
    for (id,) in expired {
        let _ = tokio::fs::remove_file(state.cfg.media_dir.join(id.to_string())).await;
    }
    state.limiter.prune(Duration::from_secs(3600));
    Ok(())
}

pub fn spawn(state: AppState) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(600));
        loop {
            tick.tick().await;
            if let Err(err) = run_once(&state).await {
                tracing::error!(error = ?err, "cleanup failed");
            }
        }
    });
}
