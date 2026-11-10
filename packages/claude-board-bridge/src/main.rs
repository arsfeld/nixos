//! claude-board-bridge: relays Claude Code hook events to the board and the
//! board's answers back. Configuration is by environment:
//!   BRIDGE_LISTEN               address to listen on (default 127.0.0.1:8590)
//!   BRIDGE_HOST_TOKEN_FILE      file holding the token hooks present (required)
//!   BRIDGE_DEVICE_TOKEN_FILE    file holding the token the board presents (required)
//!   BRIDGE_ASK_TIMEOUT_SECS     how long a question is held (default 60)
//!   BRIDGE_AUTH_FAIL_DELAY_MS   delay before a 401 (default 500)
//!   BRIDGE_EXPIRE_SECS          drop a session with no event for this long (default 21600)
//!   BRIDGE_STT_URL              base URL of the speech-to-text server (voice needs all four of these)
//!   BRIDGE_TTS_URL              base URL of the text-to-speech server
//!   BRIDGE_HERMES_URL           base URL of the Hermes API server
//!   BRIDGE_HERMES_KEY_FILE      file holding the Hermes API key
//!   BRIDGE_HERMES_SESSION       Hermes session the creature talks in (default creature)
//!   BRIDGE_REPLY_TIMEOUT_SECS   bounds the brain and speech phase of one utterance (default 60)
//! With any of the four voice settings unset or empty, voice is off and the board sees the creature offline.
//! With all four set but the Hermes key file unreadable or empty, the bridge refuses to start.

use std::time::Duration;

use claude_board_bridge::app;
use claude_board_bridge::auth::Tokens;
use claude_board_bridge::config::{VoiceEnv, voice_settings_from_env};
use claude_board_bridge::http::{AppState, now_secs};
use claude_board_bridge::voice::VoiceConfig;
use claude_board_bridge::voice::backends::{Backends, HermesHttp, PiperHttp, WhisperHttp};

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

/// Voice settings from the environment; `None` (with a note naming what is unset) leaves it off.
fn voice() -> Option<(Backends, VoiceConfig)> {
    let s = match voice_settings_from_env(|k| std::env::var(k).ok()) {
        Ok(VoiceEnv::On(s)) => s,
        Ok(VoiceEnv::Off { missing }) => {
            eprintln!("claude-board-bridge: voice off, not set: {}", missing.join(", "));
            return None;
        }
        Err(e) => fatal(&e),
    };
    let backends = Backends {
        stt: std::sync::Arc::new(WhisperHttp::new(s.stt_url)),
        tts: std::sync::Arc::new(PiperHttp::new(s.tts_url)),
        brain: std::sync::Arc::new(HermesHttp::new(s.hermes_url, s.hermes_key, s.session)),
    };
    let cfg = VoiceConfig { reply_timeout: Duration::from_secs(s.reply_timeout_secs), ..VoiceConfig::default() };
    Some((backends, cfg))
}

fn fatal(msg: &str) -> ! {
    eprintln!("claude-board-bridge: {msg}");
    std::process::exit(1)
}

#[tokio::main]
async fn main() {
    let listen = std::env::var("BRIDGE_LISTEN").unwrap_or_else(|_| "127.0.0.1:8590".into());
    let tokens = Tokens { host: token("BRIDGE_HOST_TOKEN_FILE"), device: token("BRIDGE_DEVICE_TOKEN_FILE") };
    let mut state = AppState::new(
        tokens,
        Duration::from_secs(env_num("BRIDGE_ASK_TIMEOUT_SECS", 60)),
        Duration::from_millis(env_num("BRIDGE_AUTH_FAIL_DELAY_MS", 500)),
        env_num("BRIDGE_EXPIRE_SECS", 21600) as i64,
    );
    match voice() {
        Some((backends, cfg)) => {
            eprintln!("claude-board-bridge: voice on");
            state = state.with_voice(backends, cfg);
        }
        None => {}
    }

    let sweep = state.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(Duration::from_secs(60));
        loop {
            tick.tick().await;
            sweep.sweep(now_secs());
        }
    });

    let listener = tokio::net::TcpListener::bind(&listen).await.unwrap_or_else(|e| fatal(&format!("bind {listen}: {e}")));
    eprintln!("claude-board-bridge listening on {listen}");
    axum::serve(listener, app(state)).await.unwrap_or_else(|e| fatal(&format!("serve: {e}")));
}
