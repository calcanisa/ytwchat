use std::net::SocketAddr;
use tracing_subscriber::EnvFilter;
use ytwchat_server::{app, build_state, cleanup, config::Config};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info,tower_http=info,sqlx=warn")))
        .json()
        .init();
    let cfg = Config::from_env()?;
    let addr = cfg.bind_addr;
    let state = build_state(cfg).await?;
    cleanup::spawn(state.clone());
    let listener = tokio::net::TcpListener::bind(addr).await?;
    tracing::info!(%addr, "ytwchat server listening");
    axum::serve(listener, app(state).into_make_service_with_connect_info::<SocketAddr>())
        .with_graceful_shutdown(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await?;
    Ok(())
}
