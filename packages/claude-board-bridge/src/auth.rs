//! Bearer-token checks for the hook endpoints and the board socket.

use std::time::Duration;

use axum::http::{HeaderMap, StatusCode, header::AUTHORIZATION};

#[derive(Clone)]
pub struct Tokens {
    /// Accepted from hooks on any host.
    pub host: String,
    /// Accepted from the board.
    pub device: String,
}

/// Constant-time comparison; a length difference does not short-circuit.
fn ct_eq(a: &[u8], b: &[u8]) -> bool {
    let mut diff = a.len() ^ b.len();
    for i in 0..a.len().max(b.len()) {
        diff |= (a.get(i).copied().unwrap_or(0) ^ b.get(i).copied().unwrap_or(0)) as usize;
    }
    diff == 0
}

/// `Ok` when the request carries `Authorization: Bearer <want>`. A failure
/// waits `fail_delay` before answering 401, so guessing is slow while valid
/// requests, which never wait, stay fast. An empty `want` never matches.
pub async fn check_bearer(headers: &HeaderMap, want: &str, fail_delay: Duration) -> Result<(), StatusCode> {
    let got = headers
        .get(AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or("");
    if !want.is_empty() && ct_eq(got.as_bytes(), want.as_bytes()) {
        return Ok(());
    }
    tokio::time::sleep(fail_delay).await;
    Err(StatusCode::UNAUTHORIZED)
}
