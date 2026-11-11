//! Wire types shared by the cylon-bot bridge and the board firmware.
//!
//! The JSON files in `packages/cylon-bot-bridge/tests/fixtures/board` are the contract: this crate
//! parses every one of them, and the bridge's `tests/wire.rs` pins its output to them.

pub mod model;
pub use model::{Applied, AnswerOutcome, Ask, Model, fit, join_labels};

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The protocol version the bridge announces in its `hello`. Boards ignore messages they do not know,
/// so a newer bridge can add messages without breaking older boards. Version 2 adds the per-session
/// activity feed (`history`, `entry`, and the board's `watch`/`unwatch`). Version 3 adds the creature's voice messages.
/// Version 4 adds `reminder`, which the board shows when a timer or reminder is due.
/// Version 5 adds `new_session` / `session_reset`.
pub const PROTOCOL_VERSION: u32 = 5;

/// Sample rate of the 16-bit mono PCM the board uploads.
pub const UPLINK_RATE: u32 = 16_000;
/// The most PCM bytes one utterance may carry (30 s at the uplink rate).
pub const MAX_UTTERANCE_BYTES: usize = 960_000;
/// Binary audio frames, both directions: a 4-byte little-endian utterance id, then PCM bytes.
pub const AUDIO_HEADER_LEN: usize = 4;
/// The most PCM bytes the bridge puts in one downlink frame.
pub const DOWNLINK_CHUNK_MAX: usize = 32 * 1024;

/// Build a binary audio frame.
pub fn encode_audio(utterance: u32, pcm: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(AUDIO_HEADER_LEN + pcm.len());
    frame.extend_from_slice(&utterance.to_le_bytes());
    frame.extend_from_slice(pcm);
    frame
}

/// Split a binary audio frame; `None` only when it is shorter than the header (an empty payload is valid).
pub fn decode_audio(frame: &[u8]) -> Option<(u32, &[u8])> {
    let (head, pcm) = frame.split_at_checked(AUDIO_HEADER_LEN)?;
    Some((u32::from_le_bytes(head.try_into().ok()?), pcm))
}

/// The most question text, in bytes, the board shows before it shortens it. A tool approval reaches the
/// board only when its whole text ("<tool>: <summary>") fits, so nobody approves a command they could not
/// read to the end; anything longer is left to the terminal prompt.
pub const APPROVAL_TEXT_MAX: usize = 160;

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

/// What the creature on the board is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mood {
    Listening,
    Thinking,
    Speaking,
    Alert,
    Offline,
    /// Also what a mood this version does not know parses as (serde needs it last).
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
    Creature { mood: Mood },
    Transcript { utterance: u32, text: String },
    ReplyText { utterance: u32, text: String },
    SpeakStart { utterance: u32, sample_rate: u32 },
    SpeakEnd { utterance: u32 },
    /// A reminder or timer came due. `due` is RFC 3339 with the local offset.
    Reminder { id: String, label: String, due: String },
    /// The creature's conversation was reset, in answer to `NewSession`.
    SessionReset { utterance: u32 },
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
    VoiceStart { utterance: u32 },
    VoiceEnd { utterance: u32 },
    Cancel { utterance: u32 },
    /// Start the creature's conversation afresh.
    NewSession { utterance: u32 },
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn fixture_dir() -> String {
        format!("{}/../cylon-bot-bridge/tests/fixtures/board", env!("CARGO_MANIFEST_DIR"))
    }

    #[test]
    fn hello_fixture_round_trips() {
        let text = std::fs::read_to_string(format!("{}/hello.json", fixture_dir())).unwrap();
        let msg: BoardMsg = serde_json::from_str(&text).unwrap();
        assert_eq!(msg, BoardMsg::Hello { version: PROTOCOL_VERSION });
        assert_eq!(serde_json::to_value(&msg).unwrap(), serde_json::from_str::<Value>(&text).unwrap());
    }

    /// Fixtures of what the board sends, among the bridge-to-board ones.
    const CLIENT_FIXTURES: &[&str] = &["new_session.json"];

    #[test]
    fn every_board_fixture_round_trips_through_boardmsg() {
        let mut n = 0;
        for entry in std::fs::read_dir(fixture_dir()).unwrap() {
            let path = entry.unwrap().path();
            if path.file_name().and_then(|f| f.to_str()).is_some_and(|f| CLIENT_FIXTURES.contains(&f)) {
                continue;
            }
            let text = std::fs::read_to_string(&path).unwrap();
            let want: Value = serde_json::from_str(&text).unwrap();
            let msg: BoardMsg = serde_json::from_str(&text).unwrap();
            assert_ne!(msg, BoardMsg::Unknown, "{path:?} parsed as Unknown");
            assert_eq!(serde_json::to_value(&msg).unwrap(), want, "{path:?}");
            n += 1;
        }
        assert!(n >= 16, "expected the fixtures, found {n}");
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

    #[test]
    fn audio_frame_round_trips() {
        let frame = encode_audio(7, &[1, 2, 3, 4]);
        assert_eq!(decode_audio(&frame), Some((7, &[1u8, 2, 3, 4][..])));
    }

    #[test]
    fn audio_frame_shorter_than_header_is_none() {
        assert_eq!(decode_audio(&[1, 2, 3]), None);
        assert_eq!(decode_audio(&[]), None);
    }

    #[test]
    fn empty_audio_payload_is_valid() {
        let frame = encode_audio(9, &[]);
        assert_eq!(frame.len(), AUDIO_HEADER_LEN);
        assert_eq!(decode_audio(&frame), Some((9, &[][..])));
    }

    #[test]
    fn voice_client_messages_serialise_to_the_firmware_shape() {
        for (msg, t) in [
            (ClientMsg::VoiceStart { utterance: 3 }, "voice_start"),
            (ClientMsg::VoiceEnd { utterance: 3 }, "voice_end"),
            (ClientMsg::Cancel { utterance: 3 }, "cancel"),
            (ClientMsg::NewSession { utterance: 3 }, "new_session"),
        ] {
            assert_eq!(serde_json::to_value(&msg).unwrap(), serde_json::json!({"t": t, "utterance": 3}));
        }
    }

    #[test]
    fn new_session_fixture_round_trips() {
        let text = std::fs::read_to_string(format!("{}/new_session.json", fixture_dir())).unwrap();
        let msg: ClientMsg = serde_json::from_str(&text).unwrap();
        assert_eq!(msg, ClientMsg::NewSession { utterance: 3 });
        assert_eq!(serde_json::to_value(&msg).unwrap(), serde_json::from_str::<Value>(&text).unwrap());
        assert_eq!(serde_json::to_string(&msg).unwrap(), text.trim_end());
    }

    #[test]
    fn session_reset_fixture_round_trips() {
        let text = std::fs::read_to_string(format!("{}/session_reset.json", fixture_dir())).unwrap();
        let msg: BoardMsg = serde_json::from_str(&text).unwrap();
        assert_eq!(msg, BoardMsg::SessionReset { utterance: 7 });
        assert_eq!(serde_json::to_value(&msg).unwrap(), serde_json::from_str::<Value>(&text).unwrap());
    }

    #[test]
    fn reminder_fixture_round_trips() {
        let text = std::fs::read_to_string(format!("{}/reminder.json", fixture_dir())).unwrap();
        let msg: BoardMsg = serde_json::from_str(&text).unwrap();
        assert_eq!(
            msg,
            BoardMsg::Reminder {
                id: "tmr_01".into(),
                label: "check the oven".into(),
                due: "2026-11-10T18:42:00-05:00".into(),
            }
        );
        assert_eq!(serde_json::to_value(&msg).unwrap(), serde_json::from_str::<Value>(&text).unwrap());
    }

    #[test]
    fn unknown_mood_parses_as_idle() {
        let msg: BoardMsg = serde_json::from_str(r#"{"t":"creature","mood":"dancing"}"#).unwrap();
        assert_eq!(msg, BoardMsg::Creature { mood: Mood::Idle });
    }
}
