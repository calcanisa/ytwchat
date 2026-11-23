use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("{1}")]
    BadRequest(&'static str, String),
    #[error("Sign in again to continue.")]
    Unauthorized,
    #[error("{0}")]
    Forbidden(&'static str),
    #[error("{0}")]
    NotFound(&'static str),
    #[error("{1}")]
    Conflict(&'static str, String),
    #[error("Too many requests. Wait a moment and try again.")]
    RateLimited,
    #[error("{0}")]
    PayloadTooLarge(&'static str),
    #[error("Something went wrong on our side. Try again.")]
    Internal(#[from] anyhow::Error),
}

impl AppError {
    pub fn bad(code: &'static str, message: impl Into<String>) -> Self {
        Self::BadRequest(code, message.into())
    }

    fn parts(&self) -> (StatusCode, &'static str) {
        match self {
            Self::BadRequest(code, _) => (StatusCode::BAD_REQUEST, code),
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            Self::Forbidden(_) => (StatusCode::FORBIDDEN, "forbidden"),
            Self::NotFound(_) => (StatusCode::NOT_FOUND, "not_found"),
            Self::Conflict(code, _) => (StatusCode::CONFLICT, code),
            Self::RateLimited => (StatusCode::TOO_MANY_REQUESTS, "rate_limited"),
            Self::PayloadTooLarge(_) => (StatusCode::PAYLOAD_TOO_LARGE, "too_large"),
            Self::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, "internal"),
        }
    }
}

impl From<sqlx::Error> for AppError {
    fn from(err: sqlx::Error) -> Self {
        Self::Internal(err.into())
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code) = self.parts();
        if let Self::Internal(err) = &self {
            tracing::error!(error = ?err, "internal error");
        }
        (status, Json(json!({ "error": { "code": code, "message": self.to_string() } }))).into_response()
    }
}

pub type AppResult<T> = Result<T, AppError>;
