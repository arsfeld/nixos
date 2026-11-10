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
//!   BRIDGE_MCP_LISTEN           address of the loopback MCP endpoint for the creature (unset: off)
//!   BRIDGE_MCP_TOKEN_FILE       file holding the bearer token that endpoint requires (unset: none)
//!   BRIDGE_HA_URL               Home Assistant's base URL: the forecast tool, and HA's MCP tools proxied
//!   BRIDGE_HA_TOKEN_FILE        file holding the Home Assistant token (both needed for either)
//!   BRIDGE_HA_WEATHER_ENTITY    the forecast's weather entity (default weather.forecast_home)
//! With any of the four voice settings unset or empty, voice is off and the board sees the creature offline.
//! With all four set but the Hermes key file unreadable or empty, the bridge refuses to start.

use std::time::Duration;

use claude_board_bridge::app;
use claude_board_bridge::auth::Tokens;
use claude_board_bridge::config::{VoiceEnv, ha_settings_from_env, mcp_settings_from_env, voice_settings_from_env};
use claude_board_bridge::mcp::ha::HaMcp;
use claude_board_bridge::mcp::{Mcp, mcp_router};
use claude_board_bridge::http::{AppState, now_secs};
use claude_board_bridge::timers::Timers;
use claude_board_bridge::voice::VoiceConfig;
use claude_board_bridge::voice::backends::{Backends, HermesHttp, PiperHttp, WhisperHttp};
use claude_board_bridge::voice::cylon::Centurion;
use claude_board_bridge::voice::session::SessionId;

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
        tts: std::sync::Arc::new(Centurion(PiperHttp::new(s.tts_url))),
        brain: std::sync::Arc::new(HermesHttp::new(
            s.hermes_url,
            s.hermes_key,
            std::sync::Arc::new(SessionId::load(s.session, state_file("hermes-session"))),
        )),
    };
    let cfg = VoiceConfig { reply_timeout: Duration::from_secs(s.reply_timeout_secs), ..VoiceConfig::default() };
    Some((backends, cfg))
}

/// A file in `$STATE_DIRECTORY` (systemd sets it from `StateDirectory`; a list takes its first entry).
fn state_file(name: &str) -> Option<std::path::PathBuf> {
    std::env::var("STATE_DIRECTORY")
        .ok()
        .filter(|d| !d.is_empty())
        .map(|d| std::path::PathBuf::from(d.split(':').next().unwrap_or("")).join(name))
}

/// Timers live in `$STATE_DIRECTORY/timers.json`.
fn open_timers() -> Timers {
    let path = state_file("timers.json");
    if path.is_none() {
        eprintln!("claude-board-bridge: timers in memory only");
    }
    Timers::open(path, std::sync::Arc::new(now_secs))
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
    // One store, shared by the MCP timer tools and the board sockets that deliver due reminders.
    let timers = std::sync::Arc::new(open_timers());
    state = state.with_timers(timers.clone());

    match mcp_settings_from_env(|k| std::env::var(k).ok()) {
        Ok(Some(s)) => {
            let mut tools = claude_board_bridge::mcp::timers::tools(timers);
            // The forecast tool and HA's own MCP tools only when both BRIDGE_HA_URL and
            // BRIDGE_HA_TOKEN_FILE are set. HA's tools go through the bridge so the token stays here.
            let mut upstream = None;
            match ha_settings_from_env(|k| std::env::var(k).ok()) {
                Ok(Some(ha)) => {
                    eprintln!("claude-board-bridge: weather forecast and home assistant tools from home assistant");
                    upstream = Some(std::sync::Arc::new(HaMcp::new(ha.url.clone(), ha.token.clone())));
                    tools.extend(claude_board_bridge::mcp::weather::tools(ha));
                }
                Ok(None) => eprintln!("claude-board-bridge: home assistant off"),
                Err(e) => fatal(&e),
            }
            let mcp = std::sync::Arc::new(Mcp {
                tools,
                upstream,
                token: s.token,
                fail_delay: Duration::from_millis(env_num("BRIDGE_AUTH_FAIL_DELAY_MS", 500)),
            });
            let l = tokio::net::TcpListener::bind(&s.listen)
                .await
                .unwrap_or_else(|e| fatal(&format!("bind {}: {e}", s.listen)));
            eprintln!("claude-board-bridge: mcp on {}", s.listen);
            tokio::spawn(async move {
                if let Err(e) = axum::serve(l, mcp_router(mcp)).await {
                    fatal(&format!("mcp serve: {e}"));
                }
            });
        }
        Ok(None) => eprintln!("claude-board-bridge: mcp off"),
        Err(e) => fatal(&e),
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
