//! claude-board-bridge: relays Claude Code hook events to the board and the
//! board's answers back. Configuration is by environment:
//!   BRIDGE_LISTEN               address to listen on (default 127.0.0.1:8590)
//!   BRIDGE_HOST_TOKEN_FILE      file holding the token hooks present (required)
//!   BRIDGE_DEVICE_TOKEN_FILE    file holding the token the board presents (required)
//!   BRIDGE_ASK_TIMEOUT_SECS     how long a question is held (default 60)
//!   BRIDGE_AUTH_FAIL_DELAY_MS   delay before a 401 (default 500)
//!   BRIDGE_EXPIRE_SECS          drop a session with no event for this long (default 21600)

use std::time::Duration;

use claude_board_bridge::app;
use claude_board_bridge::auth::Tokens;
use claude_board_bridge::http::{AppState, now_secs};

fn env_num(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

fn token(var: &str) -> String {
    let path = std::env::var(var).unwrap_or_else(|_| fatal(&format!("{var} is not set")));
    let tok = std::fs::read_to_string(&path).unwrap_or_else(|e| fatal(&format!("{var}: cannot read {path}: {e}")));
    let tok = tok.trim().to_string();
    if tok.is_empty() {
        fatal(&format!("{var}: {path} is empty"));
    }
    tok
}

fn fatal(msg: &str) -> ! {
    eprintln!("claude-board-bridge: {msg}");
    std::process::exit(1)
}

#[tokio::main]
async fn main() {
    let listen = std::env::var("BRIDGE_LISTEN").unwrap_or_else(|_| "127.0.0.1:8590".into());
    let tokens = Tokens { host: token("BRIDGE_HOST_TOKEN_FILE"), device: token("BRIDGE_DEVICE_TOKEN_FILE") };
    let state = AppState::new(
        tokens,
        Duration::from_secs(env_num("BRIDGE_ASK_TIMEOUT_SECS", 60)),
        Duration::from_millis(env_num("BRIDGE_AUTH_FAIL_DELAY_MS", 500)),
        env_num("BRIDGE_EXPIRE_SECS", 21600) as i64,
    );

    let sweep = state.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            let gone = sweep.registry.lock().unwrap().expire(now_secs());
            for c in gone {
                sweep.publish(c);
            }
        }
    });

    let listener = tokio::net::TcpListener::bind(&listen).await.unwrap_or_else(|e| fatal(&format!("bind {listen}: {e}")));
    eprintln!("claude-board-bridge listening on {listen}");
    axum::serve(listener, app(state)).await.unwrap_or_else(|e| fatal(&format!("serve: {e}")));
}
