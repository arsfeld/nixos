//! Wire types shared by the hook endpoints and the board.

use serde::{Deserialize, Serialize};

use crate::asks::{AskId, PendingAsk};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Idle,
    Working,
    Waiting,
    Done,
    Error,
}

/// What a hook reports. `kind` is Claude Code's `notification_type`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum EventKind {
    SessionStart,
    UserPromptSubmit,
    Notification { kind: String },
    Stop,
    StopFailure,
    SessionEnd,
}

/// One normalised hook event. `cwd` may be empty: real `StopFailure` payloads
/// carry none, and the registry then keeps the last known directory.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Event {
    pub host: String,
    pub session: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(flatten)]
    pub event: EventKind,
    pub ts: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Session {
    pub host: String,
    pub session: String,
    pub project: String,
    pub cwd: String,
    pub state: State,
    pub since: i64,
}

/// What the bridge pushes to a board over its WebSocket (`t` is the tag).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum BoardMsg {
    State { sessions: Vec<Session> },
    Upsert { session: Session },
    Remove { host: String, session: String },
    Question {
        #[serde(flatten)]
        ask: PendingAsk,
    },
    QuestionClear { id: AskId },
}
