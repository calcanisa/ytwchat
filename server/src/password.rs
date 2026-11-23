use argon2::{
    Argon2,
    password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString, rand_core::OsRng},
};
use std::sync::OnceLock;

pub fn hash(password: &str) -> anyhow::Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    Argon2::default()
        .hash_password(password.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|e| anyhow::anyhow!("password hashing failed: {e}"))
}

fn dummy_hash() -> &'static str {
    static DUMMY: OnceLock<String> = OnceLock::new();
    DUMMY.get_or_init(|| hash("timing-equaliser-not-a-real-password").unwrap_or_default())
}

pub fn verify(password: &str, stored: Option<&str>) -> bool {
    let target = stored.unwrap_or_else(|| dummy_hash());
    let ok = PasswordHash::new(target)
        .map(|parsed| Argon2::default().verify_password(password.as_bytes(), &parsed).is_ok())
        .unwrap_or(false);
    ok && stored.is_some()
}

pub async fn hash_blocking(password: String) -> anyhow::Result<String> {
    tokio::task::spawn_blocking(move || hash(&password)).await?
}

pub async fn verify_blocking(password: String, stored: Option<String>) -> bool {
    tokio::task::spawn_blocking(move || verify(&password, stored.as_deref())).await.unwrap_or(false)
}
