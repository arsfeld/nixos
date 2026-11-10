//! The controller against the real window: messages in, taps in, frames out, properties checked. The
//! messages are the bridge's own fixtures.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use claude_board_ui::controller::{Controller, Outbox};
use claude_board_ui::headless::{headless, Headless};
use claude_board_ui::{AppWindow, Page};
use serde_json::Value;
use slint::{ComponentHandle, Model as _};

const NOW: i64 = 1_800_000_000;

#[derive(Clone, Default)]
struct Wire {
    sent: Rc<RefCell<Vec<String>>>,
    online: Rc<Cell<bool>>,
}

impl Outbox for Wire {
    fn send(&self, json: String) -> bool {
        self.sent.borrow_mut().push(json);
        self.online.get()
    }
}

struct Fixture {
    _h: Headless,
    ui: AppWindow,
    c: Controller<Wire>,
    wire: Wire,
}

fn load(name: &str) -> String {
    let dir = format!("{}/../../../packages/claude-board-bridge/tests/fixtures/board", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(format!("{dir}/{name}.json")).unwrap()
}

fn fixture() -> Fixture {
    let h = headless();
    let ui = AppWindow::new().unwrap();
    ui.show().unwrap();
    let wire = Wire { online: Rc::new(Cell::new(true)), ..Default::default() };
    let c = Controller::new(&ui, wire.clone());
    c.tick(Some(NOW));
    Fixture { _h: h, ui, c, wire }
}

impl Fixture {
    fn feed(&self, name: &str) {
        self.c.on_message(&load(name));
    }
    fn sent(&self) -> Vec<Value> {
        self.wire.sent.borrow().iter().map(|s| serde_json::from_str(s).unwrap()).collect()
    }
    fn options(&self) -> Vec<(String, bool)> {
        let m = self.ui.get_options();
        (0..m.row_count()).map(|i| m.row_data(i).unwrap()).map(|o| (o.label.to_string(), o.selected)).collect()
    }
}

#[test]
fn a_waiting_question_takes_over_the_screen() {
    let f = fixture();
    f.feed("state");
    assert_eq!(f.ui.get_page(), Page::Home);
    f.feed("question_single");
    assert_eq!(f.ui.get_page(), Page::Question);
    assert_eq!(f.ui.get_question_text(), "Which colour?");
    assert_eq!(f.ui.get_question_source(), "GALACTICA - PLAB");
    assert_eq!(f.options(), [("Red".into(), false), ("Blue".into(), false)]);
    assert!(!f.ui.get_multi());
}

#[test]
fn home_summary_says_what_needs_attention() {
    let f = fixture();
    assert_eq!(f.ui.get_summary(), "No sessions");
    f.feed("state"); // one waiting
    assert_eq!(f.ui.get_summary(), "1 needs you");
}

#[test]
fn single_select_option_sends_the_answer_once() {
    let f = fixture();
    f.feed("question_single");
    f.ui.invoke_option_tapped(1);
    let sent = f.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0], serde_json::json!({"t":"answer","id":"00000000000000000000000000000001","answers":{"Which colour?":"Blue"}}));
    assert_ne!(f.ui.get_page(), Page::Question, "answered: the question is gone from the screen");
}

#[test]
fn double_tap_on_an_option_sends_one_answer() {
    let f = fixture();
    f.feed("question_single");
    f.ui.invoke_option_tapped(1);
    f.ui.invoke_option_tapped(1);
    assert_eq!(f.sent().len(), 1);
}

#[test]
fn double_tap_does_not_answer_the_next_question_of_the_same_ask() {
    // With several questions the second tap would answer the next one by mistake: it is ignored until the
    // next tick.
    let g = fixture();
    g.feed("question_multi");
    g.ui.invoke_option_tapped(1);
    g.ui.invoke_option_tapped(0);
    assert_eq!(g.ui.get_question_text(), "Which toppings?", "moved on to the second question");
    assert!(g.options().iter().all(|(_, sel)| !sel), "the second tap was ignored");
    assert!(g.sent().is_empty());
    g.c.tick(Some(NOW));
    g.ui.invoke_option_tapped(0); // now a real tap on the second question
    assert!(g.options()[0].1);
}

#[test]
fn multi_select_toggles_then_done_sends_joined_labels() {
    let f = fixture();
    f.feed("question_multi");
    f.ui.invoke_option_tapped(0); // fruit: Apple
    f.c.tick(Some(NOW));
    assert!(f.ui.get_multi());
    f.ui.invoke_option_tapped(0); // Nuts
    f.ui.invoke_option_tapped(2); // Honey
    assert_eq!(f.options(), [("Nuts".into(), true), ("Cream".into(), false), ("Honey".into(), true)]);
    assert!(f.ui.get_can_done());
    f.ui.invoke_option_tapped(2); // toggle Honey off again
    f.ui.invoke_option_tapped(2); // and on
    f.ui.invoke_done_tapped();
    let sent = f.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["answers"]["Which fruit?"], "Apple");
    assert_eq!(sent[0]["answers"]["Which toppings?"], "Nuts,Honey");
}

#[test]
fn done_with_nothing_selected_sends_nothing() {
    let f = fixture();
    f.feed("question_multi");
    f.ui.invoke_option_tapped(1);
    f.c.tick(Some(NOW));
    assert!(!f.ui.get_can_done());
    f.ui.invoke_done_tapped();
    assert!(f.sent().is_empty());
}

#[test]
fn decline_sends_decline_and_hides_the_question() {
    let f = fixture();
    f.feed("question_single");
    f.ui.invoke_decline_tapped();
    assert_eq!(f.sent(), vec![serde_json::json!({"t":"decline","id":"00000000000000000000000000000001"})]);
    assert_ne!(f.ui.get_page(), Page::Question);
}

#[test]
fn stale_selection_is_cleared_when_a_snapshot_drops_and_the_same_ask_returns() {
    let f = fixture();
    f.feed("question_multi");
    f.ui.invoke_option_tapped(0);
    f.c.tick(Some(NOW));
    f.ui.invoke_option_tapped(1); // Cream selected
    assert!(f.options()[1].1);
    f.feed("state"); // the bridge restarted: snapshot, then the pending question again
    f.feed("question_multi");
    assert_eq!(f.ui.get_page(), Page::Question);
    assert_eq!(f.ui.get_question_text(), "Which fruit?", "back at the first question");
    f.ui.invoke_option_tapped(0);
    f.c.tick(Some(NOW));
    assert!(f.options().iter().all(|(_, sel)| !sel), "a selection from before the restart came back: {:?}", f.options());
}

#[test]
fn snapshot_while_question_open_goes_back_to_the_list_then_reopens() {
    let f = fixture();
    f.feed("state");
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.ui.get_page(), Page::List);
    f.feed("question_single");
    assert_eq!(f.ui.get_page(), Page::Question);
    f.feed("state");
    assert_eq!(f.ui.get_page(), Page::List);
    f.feed("question_single");
    assert_eq!(f.ui.get_page(), Page::Question);
}

#[test]
fn tap_on_a_row_opens_detail_and_back_returns_to_the_list() {
    let f = fixture();
    f.feed("state");
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.ui.get_page(), Page::List);
    assert_eq!(f.ui.get_rows().row_count(), 3);
    f.ui.invoke_row_tapped(0); // the waiting one comes first
    assert_eq!(f.ui.get_page(), Page::Detail);
    assert_eq!(f.ui.get_detail_host(), "galactica");
    assert_eq!(f.ui.get_detail_project(), "plab");
    assert_eq!(f.ui.get_detail_state_text(), "waiting");
    f.ui.invoke_back_tapped();
    assert_eq!(f.ui.get_page(), Page::List);
    f.ui.invoke_back_tapped();
    assert_eq!(f.ui.get_page(), Page::Home);
}

#[test]
fn tapping_the_ring_opens_that_sessions_detail() {
    let f = fixture();
    f.feed("state"); // 3 arcs of 120 degrees: waiting galactica, then basestar, then raider
    f.ui.invoke_rim_tapped(60.0);
    assert_eq!((f.ui.get_page(), f.ui.get_detail_host().to_string()), (Page::Detail, "galactica".into()));
    f.ui.invoke_back_tapped();
    f.ui.invoke_back_tapped();
    f.ui.invoke_rim_tapped(300.0);
    assert_eq!(f.ui.get_detail_host(), "raider");
}

#[test]
fn a_session_that_disappears_closes_its_detail() {
    let f = fixture();
    f.feed("state");
    f.ui.invoke_avatar_tapped();
    f.ui.invoke_row_tapped(2); // raider s-1 is last
    assert_eq!(f.ui.get_page(), Page::Detail);
    f.feed("remove"); // raider s-1
    assert_eq!(f.ui.get_page(), Page::List);
}

#[test]
fn wants_chime_is_true_when_a_new_ask_appears_and_false_on_repeat() {
    let f = fixture();
    assert!(!f.c.wants_chime());
    f.feed("question_single");
    assert!(f.c.wants_chime());
    assert!(!f.c.wants_chime(), "the chime was already asked for");
    f.feed("question_single"); // a re-send of the same question
    assert!(!f.c.wants_chime());
    f.feed("question_multi"); // queued behind the first, which is still waiting: the user already knows
    assert!(!f.c.wants_chime());
    f.feed("question_clear"); // the first is gone, so the second is now the one on screen
    assert!(f.c.wants_chime(), "a different question needs the user again");
}

#[test]
fn wants_chime_when_a_session_starts_waiting() {
    let f = fixture();
    f.c.on_message(r#"{"t":"upsert","session":{"host":"h","session":"s","project":"p","cwd":"/","state":"working","since":1}}"#);
    assert!(!f.c.wants_chime());
    f.c.on_message(r#"{"t":"upsert","session":{"host":"h","session":"s","project":"p","cwd":"/","state":"waiting","since":2}}"#);
    assert!(f.c.wants_chime());
}

#[test]
fn tick_with_unset_clock_shows_dashes() {
    let f = fixture();
    f.feed("state");
    f.ui.invoke_avatar_tapped();
    f.c.tick(None);
    assert_eq!(f.ui.get_rows().row_data(0).unwrap().ago, "--");
    f.c.tick(Some(1_000_000_000)); // still before 2025: not set
    assert_eq!(f.ui.get_rows().row_data(0).unwrap().ago, "--");
    f.c.tick(Some(1_900_000_000));
    assert_ne!(f.ui.get_rows().row_data(0).unwrap().ago, "--");
}

#[test]
fn offline_link_flag_is_set_on_the_window_and_sessions_stay_visible() {
    let f = fixture();
    f.feed("state");
    assert!(!f.ui.get_link(), "offline until the bridge connects");
    f.c.set_link(true);
    assert!(f.ui.get_link());
    f.c.set_link(false);
    assert!(!f.ui.get_link());
    assert_eq!(f.ui.get_summary(), "1 needs you", "sessions already known stay on screen");
}

#[test]
fn malformed_and_unknown_messages_leave_the_screen_alone() {
    let f = fixture();
    f.feed("state");
    f.c.on_message("{not json");
    f.c.on_message(r#"{"t":"hello","version":9}"#);
    f.c.on_message(r#"{"t":"something_new","x":1}"#);
    assert_eq!(f.ui.get_summary(), "1 needs you");
}

#[test]
fn an_answer_sent_while_offline_is_still_consumed() {
    // Parity with the C firmware: the question is not kept on screen; the bridge times it out.
    let f = fixture();
    f.wire.online.set(false);
    f.feed("question_single");
    f.ui.invoke_option_tapped(0);
    assert_eq!(f.sent().len(), 1);
    assert_ne!(f.ui.get_page(), Page::Question);
}
