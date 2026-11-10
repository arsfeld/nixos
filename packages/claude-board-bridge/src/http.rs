//! The endpoints Claude Code hooks call: one-way events and held questions.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use axum::body::Bytes;
use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::post;
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::Value;
use tokio::sync::broadcast;

use crate::asks::{Answered, Asks, build_approval_decision, build_decision};
use crate::auth::{Tokens, check_bearer};
use crate::protocol::{BoardMsg, Event, EventKind};
use crate::state::{Change, Registry, project_of};

#[derive(Clone)]
pub struct AppState {
    pub registry: Arc<Mutex<Registry>>,
    pub asks: Arc<Asks>,
    pub tx: broadcast::Sender<BoardMsg>,
    pub tokens: Arc<Tokens>,
    pub ask_timeout: Duration,
    pub fail_delay: Duration,
    /// Live board sockets; a question is only held open when this is non-zero.
    pub board_connected: Arc<AtomicUsize>,
    /// How often the board socket is pinged, so Cloudflare's idle timeout never closes it.
    pub ping_every: Duration,
}

impl AppState {
    pub fn new(tokens: Tokens, ask_timeout: Duration, fail_delay: Duration, expire_secs: i64) -> AppState {
        AppState {
            registry: Arc::new(Mutex::new(Registry::new(expire_secs))),
            asks: Arc::new(Asks::new()),
            tx: broadcast::channel(256).0,
            tokens: Arc::new(tokens),
            ask_timeout,
            fail_delay,
            board_connected: Arc::new(AtomicUsize::new(0)),
            ping_every: Duration::from_secs(30),
        }
    }

    pub fn with_ping_every(mut self, every: Duration) -> AppState {
        self.ping_every = every;
        self
    }

    pub fn publish(&self, c: Change) {
        let msg = match c {
            Change::Upsert(session) => BoardMsg::Upsert { session },
            Change::Remove { host, session } => BoardMsg::Remove { host, session },
        };
        let _ = self.tx.send(msg);
    }
}

pub fn now_secs() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub fn hook_router(state: AppState) -> Router {
    Router::new().route("/v1/event", post(event)).route("/v1/ask", post(ask)).with_state(state)
}

async fn event(State(s): State<AppState>, headers: HeaderMap, body: Bytes) -> Result<StatusCode, StatusCode> {
    check_bearer(&headers, &s.tokens.host, s.fail_delay).await?;
    let e: Event = serde_json::from_slice(&body).map_err(|_| StatusCode::BAD_REQUEST)?;
    let is_note = matches!(e.event, EventKind::Notification { .. });
    let has_pending = s.asks.pending().iter().any(|a| a.host == e.host && a.session == e.session);
    // A notification while a question is held (the 60 s idle prompt, say) is
    // not news: the card stays waiting.
    if !(is_note && has_pending) {
        let change = s.registry.lock().unwrap().apply(&e);
        if let Some(c) = change {
            s.publish(c);
        }
    }
    // Any other event means Claude moved on, so the user must have answered in
    // the terminal: drop the held question.
    if !is_note {
        for id in s.asks.cancel_session(&e.host, &e.session) {
            let _ = s.tx.send(BoardMsg::QuestionClear { id });
        }
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Cleans up a held question if the request is dropped while waiting, which is
/// what happens when the hook process is killed and its connection closes.
struct HeldAsk {
    state: AppState,
    id: crate::asks::AskId,
    armed: bool,
}

impl Drop for HeldAsk {
    fn drop(&mut self) {
        if self.armed {
            self.state.asks.cancel(&self.id);
            let _ = self.state.tx.send(BoardMsg::QuestionClear { id: self.id.clone() });
        }
    }
}

#[derive(Deserialize)]
struct AskReq {
    host: String,
    session: String,
    #[serde(default)]
    cwd: String,
    #[serde(default = "question_tool")]
    tool_name: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    tool_input: Value,
}

const QUESTION_TOOL: &str = "AskUserQuestion";

fn question_tool() -> String {
    QUESTION_TOOL.into()
}

async fn ask(State(s): State<AppState>, headers: HeaderMap, body: Bytes) -> Result<Response, StatusCode> {
    check_bearer(&headers, &s.tokens.host, s.fail_delay).await?;
    let r: AskReq = serde_json::from_slice(&body).map_err(|_| StatusCode::BAD_REQUEST)?;
    if s.board_connected.load(Ordering::SeqCst) == 0 {
        return Ok(StatusCode::NO_CONTENT.into_response());
    }
    // The two paths differ only in how the ask is registered and how the
    // answer becomes a decision; holding, cancelling and timing out are shared.
    let is_question = r.tool_name == QUESTION_TOOL;
    let project = project_of(&r.cwd);
    let (id, rx) = if is_question {
        s.asks.register(&r.host, &r.session, &project, r.tool_input.clone())
    } else {
        s.asks.register_approval(&r.host, &r.session, &project, &r.tool_name, &r.summary)
    };
    let change = s.registry.lock().unwrap().set_waiting(&r.host, &r.session, &r.cwd, now_secs());
    if let Some(c) = change {
        s.publish(c);
    }
    if let Some(ask) = s.asks.pending().into_iter().find(|a| a.id == id) {
        let _ = s.tx.send(BoardMsg::Question { ask });
    }
    let mut held = HeldAsk { state: s.clone(), id: id.clone(), armed: true };
    let outcome = tokio::time::timeout(s.ask_timeout, rx).await;
    held.armed = false;
    match outcome {
        Ok(Ok(Answered::Answers(a))) => {
            let _ = s.tx.send(BoardMsg::QuestionClear { id });
            let decision =
                if is_question { Some(build_decision(&r.tool_input, &a)) } else { build_approval_decision(&a) };
            let Some(decision) = decision else {
                return Ok(StatusCode::NO_CONTENT.into_response());
            };
            let change = s.registry.lock().unwrap().set_working(&r.host, &r.session, &r.cwd, now_secs());
            if let Some(c) = change {
                s.publish(c);
            }
            Ok((StatusCode::OK, Json(decision)).into_response())
        }
        Ok(Ok(Answered::Declined)) => {
            let _ = s.tx.send(BoardMsg::QuestionClear { id });
            Ok(StatusCode::NO_CONTENT.into_response())
        }
        // Cancelled by a later event for the session, which already told the board.
        Ok(Err(_)) => Ok(StatusCode::NO_CONTENT.into_response()),
        Err(_) => {
            s.asks.cancel(&id);
            let _ = s.tx.send(BoardMsg::QuestionClear { id });
            Ok(StatusCode::NO_CONTENT.into_response())
        }
    }
}
