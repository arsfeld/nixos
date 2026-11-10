//! The JSON files in tests/fixtures/board are the wire format the firmware parses
//! (firmware/claude-board/components/board_proto/test). This pins the bridge to produce
//! exactly them, so the two sides cannot drift apart.

use claude_board_bridge::asks::{AskId, PendingAsk, Question, QuestionOption};
use claude_board_bridge::protocol::{BoardMsg, Session, State};
use serde_json::Value;

fn fixture(name: &str) -> Value {
    let path = format!("{}/tests/fixtures/board/{name}.json", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

fn session(host: &str, id: &str, project: &str, cwd: &str, state: State, since: i64) -> Session {
    Session { host: host.into(), session: id.into(), project: project.into(), cwd: cwd.into(), state, since }
}

fn opt(label: &str, description: Option<&str>) -> QuestionOption {
    QuestionOption { label: label.into(), description: description.map(Into::into) }
}

fn q(text: &str, header: Option<&str>, options: Vec<QuestionOption>, multi: bool) -> Question {
    Question { question: text.into(), header: header.map(Into::into), options, multi_select: multi }
}

fn ask(id: &str, host: &str, sess: &str, project: &str, questions: Vec<Question>) -> BoardMsg {
    BoardMsg::Question { ask: PendingAsk { id: AskId(id.into()), host: host.into(), session: sess.into(), project: project.into(), questions } }
}

fn wire(m: &BoardMsg) -> Value {
    serde_json::to_value(m).unwrap()
}

#[test]
fn state_matches_the_firmware_fixture() {
    let m = BoardMsg::State {
        sessions: vec![
            session("raider", "s-1", "nixos", "/home/arosenfeld/Code/nixos", State::Working, 1000),
            session("galactica", "s-2", "plab", "/srv/plab", State::Waiting, 900),
            session("basestar", "s-3", "blog", "/srv/blog", State::Done, 1200),
        ],
    };
    assert_eq!(wire(&m), fixture("state"));
}

#[test]
fn upsert_matches_the_firmware_fixture() {
    let m = BoardMsg::Upsert { session: session("raider", "s-1", "nixos", "/home/arosenfeld/Code/nixos", State::Error, 1300) };
    assert_eq!(wire(&m), fixture("upsert"));
}

#[test]
fn remove_matches_the_firmware_fixture() {
    let m = BoardMsg::Remove { host: "raider".into(), session: "s-1".into() };
    assert_eq!(wire(&m), fixture("remove"));
}

#[test]
fn single_question_matches_the_firmware_fixture() {
    let m = ask(
        "00000000000000000000000000000001", "galactica", "s-2", "plab",
        vec![q("Which colour?", Some("Colour"), vec![opt("Red", Some("Pick red")), opt("Blue", None)], false)],
    );
    assert_eq!(wire(&m), fixture("question_single"));
}

#[test]
fn multi_question_matches_the_firmware_fixture() {
    let m = ask(
        "00000000000000000000000000000002", "raider", "s-1", "nixos",
        vec![
            q("Which fruit?", None, vec![opt("Apple", None), opt("Pear", None)], false),
            q("Which toppings?", Some("Toppings"), vec![opt("Nuts", None), opt("Cream", None), opt("Honey", None)], true),
        ],
    );
    assert_eq!(wire(&m), fixture("question_multi"));
}

#[test]
fn unicode_question_matches_the_firmware_fixture() {
    let m = ask(
        "00000000000000000000000000000003", "raider", "s-1", "nixos",
        vec![q("🎨 Cuál es tu color? e\u{0301}\u{200d}🙂", None, vec![opt("Α β ✓", None), opt("日本語", None)], false)],
    );
    assert_eq!(wire(&m), fixture("question_unicode"));
}

#[test]
fn question_clear_matches_the_firmware_fixture() {
    let m = BoardMsg::QuestionClear { id: AskId("00000000000000000000000000000001".into()) };
    assert_eq!(wire(&m), fixture("question_clear"));
}

#[test]
fn hello_matches_the_firmware_fixture() {
    let m = BoardMsg::Hello { version: claude_board_proto::PROTOCOL_VERSION };
    assert_eq!(wire(&m), fixture("hello"));
}
