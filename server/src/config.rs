use std::{env, net::SocketAddr, path::PathBuf, time::Duration};

#[derive(Clone, Debug)]
pub struct Config {
    pub database_url: String,
    pub bind_addr: SocketAddr,
    pub media_dir: PathBuf,
    pub media_max_bytes: usize,
    pub trust_proxy: bool,
    pub cors_origins: Vec<String>,
    pub retention: Duration,
    pub access_ttl: Duration,
    pub refresh_ttl: Duration,
}

fn var(name: &str) -> Option<String> {
    env::var(name).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

fn num(name: &str, default: u64) -> anyhow::Result<u64> {
    match var(name) {
        Some(v) => v.parse().map_err(|_| anyhow::anyhow!("{name} must be a whole number")),
        None => Ok(default),
    }
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        let database_url = var("DATABASE_URL").ok_or_else(|| anyhow::anyhow!("DATABASE_URL is required"))?;
        let bind_addr = var("BIND_ADDR").unwrap_or_else(|| "0.0.0.0:8001".into()).parse()?;
        let media_dir = PathBuf::from(var("MEDIA_DIR").unwrap_or_else(|| "./storage/media".into()));
        let media_max_bytes = num("MEDIA_MAX_MB", 64)? as usize * 1024 * 1024;
        let trust_proxy = matches!(var("TRUST_PROXY").as_deref(), Some("1") | Some("true"));
        let cors_origins = var("CORS_ORIGINS")
            .map(|v| v.split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect())
            .unwrap_or_default();
        Ok(Self {
            database_url,
            bind_addr,
            media_dir,
            media_max_bytes,
            trust_proxy,
            cors_origins,
            retention: Duration::from_secs(num("RETENTION_DAYS", 30)? * 86_400),
            access_ttl: Duration::from_secs(num("ACCESS_TTL_SECS", 900)?),
            refresh_ttl: Duration::from_secs(num("REFRESH_TTL_DAYS", 30)? * 86_400),
        })
    }
}
