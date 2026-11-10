//! Wire types for the hook endpoints. The types the board shares live in `claude-board-proto`.

use serde::{Deserialize, Serialize};

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

pub use claude_board_proto::{BoardMsg, ClientMsg, FeedEntry, FeedKind, PROTOCOL_VERSION, Session, State};
