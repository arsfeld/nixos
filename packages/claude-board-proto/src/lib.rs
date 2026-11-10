//! Wire types shared by the claude-board bridge and the board firmware.
//!
//! The JSON files in `packages/claude-board-bridge/tests/fixtures/board` are the contract: this crate
//! parses every one of them, and the bridge's `tests/wire.rs` pins its output to them.

pub mod model;
pub use model::{Applied, AnswerOutcome, Ask, Model, fit, join_labels};

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The protocol version the bridge announces in its `hello`. Boards ignore messages they do not know,
/// so a newer bridge can add messages without breaking older boards. Version 2 adds the per-session
/// activity feed (`history`, `entry`, and the board's `watch`/`unwatch`).
pub const PROTOCOL_VERSION: u32 = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Working,
    Waiting,
    Done,
    Error,
    /// Also what a state this version does not know parses as (serde needs it last).
    #[serde(other)]
    Idle,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Session {
    pub host: String,
    pub session: String,
    pub project: String,
    #[serde(default)]
    pub cwd: String,
    pub state: State,
    pub since: i64,
}

/// A single-use, unguessable question id (128 random bits, hex).
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AskId(pub String);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionOption {
    pub label: String,
    #[serde(default)]
    pub description: Option<String>,
}

/// One entry of the question tool's input; field names follow the tool.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Question {
    pub question: String,
    #[serde(default)]
    pub header: Option<String>,
    #[serde(default)]
    pub options: Vec<QuestionOption>,
    #[serde(default)]
    pub multi_select: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingAsk {
    pub id: AskId,
    pub host: String,
    pub session: String,
    pub project: String,
    pub questions: Vec<Question>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FeedKind {
    Prompt,
    Tool,
    Result,
    Reply,
    /// Also what a kind this version does not know parses as (serde needs it last).
    #[serde(other)]
    Other,
}

/// One line of a session's activity feed; `n` counts up per session.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FeedEntry {
    pub n: u64,
    pub ts: i64,
    pub kind: FeedKind,
    pub text: String,
}

/// What the bridge pushes to a board over its WebSocket (`t` is the tag). A message of a kind this
/// version does not know parses as `Unknown`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum BoardMsg {
    Hello { version: u32 },
    State { sessions: Vec<Session> },
    Upsert { session: Session },
    Remove { host: String, session: String },
    Question {
        #[serde(flatten)]
        ask: PendingAsk,
    },
    QuestionClear { id: AskId },
    History { host: String, session: String, entries: Vec<FeedEntry> },
    Entry {
        host: String,
        session: String,
        #[serde(flatten)]
        entry: FeedEntry,
    },
    #[serde(other)]
    Unknown,
}

/// What a board may send. Anything else is ignored by the bridge.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum ClientMsg {
    Answer { id: AskId, answers: BTreeMap<String, String> },
    Decline { id: AskId },
    Watch { host: String, session: String },
    Unwatch,
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn fixture_dir() -> String {
        format!("{}/../claude-board-bridge/tests/fixtures/board", env!("CARGO_MANIFEST_DIR"))
    }

    #[test]
    fn hello_fixture_round_trips() {
        let text = std::fs::read_to_string(format!("{}/hello.json", fixture_dir())).unwrap();
        let msg: BoardMsg = serde_json::from_str(&text).unwrap();
        assert_eq!(msg, BoardMsg::Hello { version: PROTOCOL_VERSION });
        assert_eq!(serde_json::to_value(&msg).unwrap(), serde_json::from_str::<Value>(&text).unwrap());
    }

    #[test]
    fn every_board_fixture_round_trips_through_boardmsg() {
        let mut n = 0;
        for entry in std::fs::read_dir(fixture_dir()).unwrap() {
            let path = entry.unwrap().path();
            let text = std::fs::read_to_string(&path).unwrap();
            let want: Value = serde_json::from_str(&text).unwrap();
            let msg: BoardMsg = serde_json::from_str(&text).unwrap();
            assert_ne!(msg, BoardMsg::Unknown, "{path:?} parsed as Unknown");
            assert_eq!(serde_json::to_value(&msg).unwrap(), want, "{path:?}");
            n += 1;
        }
        assert!(n >= 10, "expected the fixtures, found {n}");
    }

    #[test]
    fn unknown_feed_kind_parses_as_other() {
        let text = r#"{"t":"entry","host":"h","session":"s","n":1,"ts":2,"kind":"later","text":"x"}"#;
        let msg: BoardMsg = serde_json::from_str(text).unwrap();
        assert!(matches!(msg, BoardMsg::Entry { entry, .. } if entry.kind == FeedKind::Other));
    }

    #[test]
    fn watch_and_unwatch_serialise_to_the_firmware_shape() {
        let w = ClientMsg::Watch { host: "h".into(), session: "s".into() };
        assert_eq!(serde_json::to_value(&w).unwrap(), serde_json::json!({"t":"watch","host":"h","session":"s"}));
        assert_eq!(serde_json::to_value(&ClientMsg::Unwatch).unwrap(), serde_json::json!({"t":"unwatch"}));
    }

    #[test]
    fn unknown_t_parses_as_unknown() {
        let msg: BoardMsg = serde_json::from_str(r#"{"t":"future","x":1}"#).unwrap();
        assert_eq!(msg, BoardMsg::Unknown);
    }

    #[test]
    fn unknown_fields_are_ignored() {
        let text = r#"{"t":"upsert","extra":true,"session":{"host":"h","session":"s","project":"p","cwd":"/","state":"idle","since":1,"later":"x"}}"#;
        let msg: BoardMsg = serde_json::from_str(text).unwrap();
        assert!(matches!(msg, BoardMsg::Upsert { session } if session.state == State::Idle && session.host == "h"));
    }

    #[test]
    fn client_answer_and_decline_serialise_to_the_firmware_shape() {
        let mut answers = std::collections::BTreeMap::new();
        answers.insert("Which colour?".to_string(), "Red".to_string());
        let a = ClientMsg::Answer { id: AskId("abc".into()), answers };
        assert_eq!(
            serde_json::to_value(&a).unwrap(),
            serde_json::json!({"t":"answer","id":"abc","answers":{"Which colour?":"Red"}})
        );
        let d = ClientMsg::Decline { id: AskId("abc".into()) };
        assert_eq!(serde_json::to_value(&d).unwrap(), serde_json::json!({"t":"decline","id":"abc"}));
    }
}
