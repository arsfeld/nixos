//! The controller against the real window: messages in, taps in, frames out, properties checked. The
//! messages are the bridge's own fixtures.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use claude_board_ui::controller::{Controller, Outbox};
use claude_board_ui::headless::{headless, Headless};
use claude_board_ui::{AppWindow, Page};
use serde_json::Value;
use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, LogicalPosition, Model as _};

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
    /// A question message, then half a second: the question has been up long enough to be tapped (taps in the
    /// first 500 ms after one appears are ignored).
    fn ask(&self, name: &str) {
        self.feed(name);
        self.c.tick(Some(NOW));
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
    f.ask("question_single");
    f.ui.invoke_option_tapped(1);
    let sent = f.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0], serde_json::json!({"t":"answer","id":"00000000000000000000000000000001","answers":{"Which colour?":"Blue"}}));
    assert_ne!(f.ui.get_page(), Page::Question, "answered: the question is gone from the screen");
}

#[test]
fn double_tap_on_an_option_sends_one_answer() {
    let f = fixture();
    f.ask("question_single");
    f.ui.invoke_option_tapped(1);
    f.ui.invoke_option_tapped(1);
    assert_eq!(f.sent().len(), 1);
}

#[test]
fn double_tap_does_not_answer_the_next_question_of_the_same_ask() {
    // With several questions the second tap would answer the next one by mistake: it is ignored until the
    // next tick.
    let g = fixture();
    g.ask("question_multi");
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
    f.ask("question_multi");
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
    f.ask("question_multi");
    f.ui.invoke_option_tapped(1);
    f.c.tick(Some(NOW));
    assert!(!f.ui.get_can_done());
    f.ui.invoke_done_tapped();
    assert!(f.sent().is_empty());
}

#[test]
fn decline_sends_decline_and_hides_the_question() {
    let f = fixture();
    f.ask("question_single");
    f.ui.invoke_decline_tapped();
    assert_eq!(f.sent(), vec![serde_json::json!({"t":"decline","id":"00000000000000000000000000000001"})]);
    assert_ne!(f.ui.get_page(), Page::Question);
}

#[test]
fn stale_selection_is_cleared_when_a_snapshot_drops_and_the_same_ask_returns() {
    let f = fixture();
    f.ask("question_multi");
    f.ui.invoke_option_tapped(0);
    f.c.tick(Some(NOW));
    f.ui.invoke_option_tapped(1); // Cream selected
    assert!(f.options()[1].1);
    f.feed("state"); // the bridge restarted: snapshot, then the pending question again
    f.ask("question_multi");
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
    f.ask("question_single");
    f.ui.invoke_option_tapped(0);
    assert_eq!(f.sent().len(), 1);
    assert_ne!(f.ui.get_page(), Page::Question);
}

fn kinds(v: &[Value]) -> Vec<String> {
    v.iter().map(|m| m["t"].as_str().unwrap().to_owned()).collect()
}

fn open_raider(f: &Fixture) {
    f.feed("state");
    f.ui.invoke_avatar_tapped();
    f.ui.invoke_row_tapped(2); // raider s-1
}

#[test]
fn opening_a_detail_sends_watch() {
    let f = fixture();
    open_raider(&f);
    let sent = f.sent();
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0]["t"], "watch");
    assert_eq!((sent[0]["host"].as_str(), sent[0]["session"].as_str()), (Some("raider"), Some("s-1")));
}

#[test]
fn going_back_sends_unwatch() {
    let f = fixture();
    open_raider(&f);
    f.ui.invoke_back_tapped();
    assert_eq!(kinds(&f.sent()), ["watch", "unwatch"]);
    f.ui.invoke_back_tapped();
    assert_eq!(f.sent().len(), 2);
}

#[test]
fn opening_another_session_unwatches_the_first_then_watches_the_second() {
    let f = fixture();
    open_raider(&f);
    f.ui.invoke_rim_tapped(60.0); // galactica
    assert_eq!(kinds(&f.sent()), ["watch", "unwatch", "watch"]);
    assert_eq!(f.sent()[2]["host"], "galactica");
}

#[test]
fn link_coming_back_up_on_a_detail_resends_watch() {
    let f = fixture();
    f.c.set_link(false);
    open_raider(&f);
    f.c.set_link(true);
    let sent = f.sent();
    assert_eq!(kinds(&sent), ["watch", "watch"]);
    assert_eq!(sent[1]["session"], "s-1");
}

#[test]
fn link_up_on_the_list_sends_nothing() {
    let f = fixture();
    f.feed("state");
    f.ui.invoke_avatar_tapped();
    f.c.set_link(false);
    f.c.set_link(true);
    assert!(f.sent().is_empty());
}

#[test]
fn session_removed_while_watched_sends_unwatch() {
    let f = fixture();
    open_raider(&f);
    f.feed("remove");
    assert_eq!(f.ui.get_page(), Page::List);
    assert_eq!(kinds(&f.sent()), ["watch", "unwatch"]);
}

#[test]
fn history_then_a_duplicate_entry_shows_each_row_once() {
    let f = fixture();
    open_raider(&f);
    assert!(f.ui.get_feed_empty());
    f.feed("history");
    // prompt, tool (marked failed by the result), reply
    assert_eq!(f.ui.get_feed().row_count(), 3);
    assert!(!f.ui.get_feed_empty());
    assert!(f.ui.get_feed().row_data(1).unwrap().failed);
    f.feed("entry"); // n = 5: new
    f.feed("entry"); // the same n again: dropped
    assert_eq!(f.ui.get_feed().row_count(), 4);
}

#[test]
fn switching_the_watched_session_empties_the_feed_on_the_same_page() {
    // detail.slint starts following the newest row again when the feed goes empty, so the controller must empty
    // it whenever the watched session changes, also when the detail page stays on screen.
    let f = fixture();
    open_raider(&f);
    f.feed("history");
    assert!(!f.ui.get_feed_empty());
    f.ui.invoke_rim_tapped(60.0); // galactica, straight from one detail to the next
    assert_eq!((f.ui.get_page(), f.ui.get_detail_host().to_string()), (Page::Detail, "galactica".into()));
    assert!(f.ui.get_feed_empty());
    assert_eq!(f.ui.get_feed().row_count(), 0);
}

#[test]
fn tapping_a_row_expands_its_full_text_and_back_closes_it() {
    let f = fixture();
    open_raider(&f);
    f.feed("history");
    f.ui.invoke_entry_tapped(2);
    assert_eq!(f.ui.get_expanded_text(), "The build failed: missing input.");
    f.ui.invoke_expanded_closed();
    assert_eq!(f.ui.get_expanded_text(), "");
    f.ui.invoke_entry_tapped(0);
    assert_eq!(f.ui.get_expanded_text(), "fix the build");
    f.ui.invoke_back_tapped();
    assert_eq!(f.ui.get_expanded_text(), "");
}

#[test]
fn a_tap_right_after_a_new_question_appears_is_ignored() {
    // A tap meant for the list or the feed must not answer a question that took over the screen under it.
    let f = fixture();
    f.c.set_time_ms(20_000);
    f.feed("question_single");
    f.ui.invoke_option_tapped(1);
    f.ui.invoke_decline_tapped();
    // Refreshes, and the same question sent again, do not start the window over.
    f.c.tick_at(Some(NOW), 20_250);
    f.feed("question_single");
    f.c.set_time_ms(20_499);
    f.ui.invoke_option_tapped(1);
    assert!(f.sent().is_empty(), "a tap within 500 ms of the question appearing answered it: {:?}", f.sent());
    assert_eq!(f.ui.get_page(), Page::Question);
    f.c.set_time_ms(20_500);
    f.ui.invoke_option_tapped(1);
    assert_eq!(f.sent().len(), 1, "a tap after the window must answer");
}

#[test]
fn a_decline_right_after_a_different_question_appears_is_ignored() {
    // The window belongs to the new question, not to the last answer: here the answer is old enough (past the
    // 400 ms answer guard) that only a guard on the new question can stop the tap.
    let f = fixture();
    f.c.set_time_ms(20_000);
    f.feed("question_single");
    f.c.set_time_ms(20_500);
    f.ui.invoke_option_tapped(0); // answers the first ask
    assert_eq!(f.sent().len(), 1);
    f.c.set_time_ms(21_000);
    f.feed("question_multi"); // a different ask takes over the screen
    f.c.set_time_ms(21_100);
    f.ui.invoke_decline_tapped();
    assert_eq!(f.sent().len(), 1, "a decline 100 ms after a new ask appeared went through");
    assert_eq!(f.ui.get_page(), Page::Question);
    f.c.set_time_ms(21_500);
    f.ui.invoke_decline_tapped();
    assert_eq!(f.sent().len(), 2);
}

#[test]
fn the_next_queued_ask_is_guarded_from_when_it_appears() {
    let f = fixture();
    f.c.set_time_ms(30_000);
    f.feed("question_single");
    f.feed("question_multi"); // queued behind the first
    f.c.set_time_ms(30_600);
    f.ui.invoke_option_tapped(0); // answers the first; the second takes over the screen now
    assert_eq!(f.sent().len(), 1);
    assert_eq!(f.ui.get_question_text(), "Which fruit?");
    f.c.set_time_ms(31_050); // past the 400 ms answer guard, inside the new ask's 500 ms
    f.ui.invoke_option_tapped(0);
    assert_eq!(f.ui.get_question_text(), "Which fruit?", "the new ask was answered within 500 ms of appearing");
    f.c.set_time_ms(31_100);
    f.ui.invoke_option_tapped(0);
    assert_eq!(f.ui.get_question_text(), "Which toppings?");
}

/// A one-question ask whose text is `text`, with Allow and Deny, as the bridge sends a tool approval.
fn approval(id: &str, text: &str) -> String {
    serde_json::json!({"t":"question","id":id,"host":"h","session":"s","project":"p",
        "questions":[{"question":text,"header":"Approve","options":[{"label":"Allow"},{"label":"Deny"}],"multiSelect":false}]})
    .to_string()
}

#[test]
fn the_board_shows_exactly_the_approval_limit_of_a_question_and_shortens_the_rest() {
    // The bridge sends an approval only when its whole text fits in APPROVAL_TEXT_MAX bytes, so that is what the
    // board must show whole; a byte more is cut.
    let f = fixture();
    let fits = format!("Bash: {}", "x".repeat(claude_board_proto::APPROVAL_TEXT_MAX - "Bash: ".len()));
    assert_eq!(fits.len(), claude_board_proto::APPROVAL_TEXT_MAX);
    f.c.on_message(&approval("a1", &fits));
    assert_eq!(f.ui.get_question_text(), fits.as_str());
    f.c.on_message(r#"{"t":"question_clear","id":"a1"}"#);
    let too_long = format!("{fits}y");
    f.c.on_message(&approval("a2", &too_long));
    assert_eq!(f.ui.get_question_text(), format!("{fits}...").as_str());
}

// ---- Voice: hold to talk, the creature's moods, the reply card ----

use claude_board_ui::PresenceState;

fn mood(f: &Fixture, m: &str) {
    f.c.on_message(&format!(r#"{{"t":"creature","mood":"{m}"}}"#));
}

fn sent_types(f: &Fixture) -> Vec<String> {
    f.sent().iter().map(|v| v["t"].as_str().unwrap().to_string()).collect()
}

#[test]
fn hold_on_the_avatar_sends_voice_start_and_shows_listening() {
    let f = fixture();
    assert!(f.c.hold_started(233, 233));
    assert_eq!(f.ui.get_presence_state(), PresenceState::Listening);
    let id = f.c.utterance().expect("an utterance is open");
    assert_eq!(f.sent(), [serde_json::json!({"t": "voice_start", "utterance": id})]);
}

#[test]
fn hold_off_the_avatar_does_nothing() {
    let f = fixture();
    assert!(!f.c.hold_started(20, 20));
    assert_eq!(f.c.utterance(), None);
    assert!(f.sent().is_empty());
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
}

#[test]
fn release_sends_voice_end_with_the_same_utterance() {
    let f = fixture();
    assert!(f.c.hold_started(233, 233));
    let id = f.c.utterance().unwrap();
    assert_eq!(f.c.hold_ended(), Some(id));
    assert_eq!(f.sent()[1], serde_json::json!({"t": "voice_end", "utterance": id}));
    assert_ne!(f.ui.get_presence_state(), PresenceState::Listening);
    // A second hold gets a new id.
    assert!(f.c.hold_started(233, 233));
    assert_ne!(f.c.utterance(), Some(id));
    // A release with no hold open sends nothing.
    f.c.hold_ended();
    assert_eq!(f.c.hold_ended(), None);
    assert_eq!(sent_types(&f), ["voice_start", "voice_end", "voice_start", "voice_end"]);
}

#[test]
fn can_hold_at_matches_hold_started_without_sending_anything() {
    let f = fixture();
    assert!(f.c.can_hold_at(233, 233));
    assert!(!f.c.can_hold_at(20, 20));
    assert!(f.sent().is_empty(), "asking opens no utterance");
    assert_eq!(f.c.utterance(), None);
    assert!(f.c.hold_started(233, 233));
    assert!(!f.c.can_hold_at(233, 233), "not while a hold is open");
    f.c.hold_ended();
    mood(&f, "offline");
    assert!(!f.c.can_hold_at(233, 233), "not while offline");
}

#[test]
fn hold_is_refused_while_the_creature_is_offline() {
    let f = fixture();
    mood(&f, "offline");
    assert!(!f.c.hold_started(233, 233));
    assert_eq!(f.c.utterance(), None);
    assert!(!sent_types(&f).contains(&"voice_start".to_string()), "nothing is recorded or uploaded");
}

#[test]
fn hold_end_without_an_open_utterance_does_not_show_thinking() {
    let f = fixture();
    mood(&f, "offline");
    assert!(!f.c.hold_started(233, 233));
    let before = f.ui.get_presence_state();
    assert_eq!(f.c.hold_ended(), None);
    assert_ne!(f.ui.get_presence_state(), PresenceState::Thinking);
    assert_eq!(f.ui.get_presence_state(), before);
    assert!(!sent_types(&f).contains(&"voice_end".to_string()));
}

#[test]
fn mic_level_drives_the_presence_while_listening() {
    let f = fixture();
    f.c.hold_started(233, 233);
    f.c.set_mic_level(0.6);
    assert!((f.ui.get_presence_level() - 0.6).abs() < 1e-6);
}

#[test]
fn creature_thinking_and_speaking_set_the_presence_state() {
    let f = fixture();
    mood(&f, "thinking");
    assert_eq!(f.ui.get_presence_state(), PresenceState::Thinking);
    mood(&f, "speaking");
    assert_eq!(f.ui.get_presence_state(), PresenceState::Speaking);
    mood(&f, "alert");
    assert_eq!(f.ui.get_presence_state(), PresenceState::Alert);
    mood(&f, "idle");
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
}

#[test]
fn offline_mood_sets_voice_unavailable() {
    let f = fixture();
    assert!(f.ui.get_voice_available());
    mood(&f, "offline");
    assert!(!f.ui.get_voice_available());
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
    mood(&f, "idle");
    assert!(f.ui.get_voice_available());
}

#[test]
fn reply_text_shows_the_card_and_it_expires_after_20_seconds() {
    let f = fixture();
    assert_eq!(f.ui.get_reply_text(), "");
    f.c.on_message(r#"{"t":"transcript","utterance":1,"text":"what is up"}"#);
    f.c.on_message(r#"{"t":"reply_text","utterance":1,"text":"All good. Nothing is on fire."}"#);
    assert_eq!(f.ui.get_reply_text(), "All good. Nothing is on fire.");
    assert_eq!(f.ui.get_reply_heading(), "what is up");
    for _ in 0..38 {
        f.c.tick(Some(NOW)); // 19 s
    }
    assert_eq!(f.ui.get_reply_text(), "All good. Nothing is on fire.");
    for _ in 0..3 {
        f.c.tick(Some(NOW)); // past 20 s
    }
    assert_eq!(f.ui.get_reply_text(), "");
}

#[test]
fn tapping_the_reply_card_dismisses_it() {
    let f = fixture();
    f.c.on_message(r#"{"t":"reply_text","utterance":1,"text":"Hello."}"#);
    f.ui.invoke_reply_tapped();
    assert_eq!(f.ui.get_reply_text(), "");
}

#[test]
fn tapping_while_speaking_sends_cancel() {
    let f = fixture();
    f.c.hold_started(233, 233);
    let id = f.c.utterance().unwrap();
    f.c.hold_ended();
    mood(&f, "speaking");
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.sent().last().unwrap(), &serde_json::json!({"t": "cancel", "utterance": id}));
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
    assert_eq!(f.ui.get_page(), Page::Home, "the cancelling tap does not also open the list");
}

#[test]
fn a_hold_during_a_waiting_question_is_ignored() {
    let f = fixture();
    f.ask("question_single");
    assert!(!f.c.hold_started(233, 233));
    assert_eq!(f.c.utterance(), None);
    assert!(f.sent().is_empty());
}

// ---- Voice state does not outlive the link or a reply that never comes ----

#[test]
fn link_drop_while_listening_returns_to_idle() {
    let f = fixture();
    f.c.set_link(true);
    assert!(f.c.hold_started(233, 233));
    let sent_before = f.sent().len();
    f.c.set_link(false);
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
    assert_eq!(f.c.utterance(), None);
    assert_eq!(f.c.hold_ended(), None, "the hold is over");
    assert_eq!(f.sent().len(), sent_before, "nothing is sent on a dropped link");
}

#[test]
fn link_drop_while_thinking_returns_to_idle() {
    let f = fixture();
    f.c.set_link(true);
    f.c.hold_started(233, 233);
    f.c.hold_ended();
    assert_eq!(f.ui.get_presence_state(), PresenceState::Thinking);
    f.c.set_link(false);
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
    assert_eq!(f.c.utterance(), None);
}

#[test]
fn link_drop_while_speaking_returns_to_idle() {
    let f = fixture();
    f.c.set_link(true);
    mood(&f, "speaking");
    assert_eq!(f.ui.get_presence_state(), PresenceState::Speaking);
    let sent_before = f.sent().len();
    f.c.set_link(false);
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.sent().len(), sent_before, "no cancel for speech that is already gone");
}

#[test]
fn thinking_returns_to_idle_after_90_seconds_without_a_reply() {
    let f = fixture();
    f.c.hold_started(233, 233);
    f.c.hold_ended();
    for _ in 0..178 {
        f.c.tick(Some(NOW)); // 89 s
    }
    assert_eq!(f.ui.get_presence_state(), PresenceState::Thinking);
    for _ in 0..4 {
        f.c.tick(Some(NOW));
    }
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
}

#[test]
fn idle_after_speech_is_held_back_while_the_audio_still_plays() {
    let f = fixture();
    f.c.set_link(true);
    mood(&f, "speaking");
    f.c.set_audio_playing(true);
    assert!(f.c.is_speaking());
    mood(&f, "idle"); // the bridge is done sending; the board is not done playing
    assert_eq!(f.ui.get_presence_state(), PresenceState::Speaking);
    f.c.set_audio_playing(false); // the queue drained
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
    assert!(!f.c.is_speaking());
}

#[test]
fn a_tap_during_the_drain_cancels_the_speech() {
    let f = fixture();
    f.c.set_link(true);
    f.c.hold_started(233, 233);
    f.c.hold_ended();
    mood(&f, "speaking");
    f.c.set_audio_playing(true);
    mood(&f, "idle");
    let before = f.sent().len();
    assert!(f.c.tap_cancels_speech());
    assert_eq!(f.sent().len(), before + 1);
    assert!(!f.c.is_speaking());
    f.c.set_audio_playing(false);
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
}

#[test]
fn other_moods_are_not_held_back_by_playing_audio() {
    let f = fixture();
    f.c.set_link(true);
    mood(&f, "speaking");
    f.c.set_audio_playing(true);
    mood(&f, "offline");
    assert!(!f.c.is_speaking());
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
}

#[test]
fn speech_events_are_parsed_for_the_app() {
    use claude_board_ui::audio::{speech_event, SpeechEvent};
    assert_eq!(
        speech_event(r#"{"t":"speak_start","utterance":4,"sample_rate":22050}"#),
        Some(SpeechEvent::Start { utterance: 4, rate: 22_050 })
    );
    assert_eq!(speech_event(r#"{"t":"speak_end","utterance":4}"#), Some(SpeechEvent::End));
    assert_eq!(speech_event(r#"{"t":"sessions","sessions":[]}"#), None);
    assert_eq!(speech_event("not json"), None);
}

// ---- Reminders: a sticky card on home, and bridge-owned speech ----

const REMINDER: &str = r#"{"t":"reminder","id":"tmr_01","label":"check the oven","due":"2026-11-10T18:42:00-05:00"}"#;

#[test]
fn reminder_shows_a_sticky_card_with_local_time() {
    let f = fixture();
    f.c.on_message(REMINDER);
    assert_eq!(f.ui.get_reply_heading(), "Reminder 18:42");
    assert_eq!(f.ui.get_reply_text(), "check the oven");
    for _ in 0..80 {
        f.c.tick(Some(NOW)); // 40 s, well past REPLY_CARD_MS
    }
    assert_eq!(f.ui.get_reply_text(), "check the oven");
    assert_eq!(f.ui.get_reply_heading(), "Reminder 18:42");
}

#[test]
fn reminder_sets_the_chime() {
    let f = fixture();
    assert!(!f.c.wants_chime());
    f.c.on_message(REMINDER);
    assert!(f.c.wants_chime());
}

#[test]
fn tapping_the_reminder_card_dismisses_it() {
    let f = fixture();
    f.c.on_message(REMINDER);
    f.ui.invoke_reply_tapped();
    assert_eq!(f.ui.get_reply_text(), "");
}

#[test]
fn tapping_the_reminder_card_while_it_is_spoken_cancels_its_speech() {
    let f = fixture();
    f.c.on_message(REMINDER);
    f.c.on_message(r#"{"t":"creature","mood":"speaking"}"#);
    f.c.on_message(r#"{"t":"speak_start","utterance":2147483649,"sample_rate":22050}"#);
    f.ui.invoke_reply_tapped();
    assert_eq!(f.ui.get_reply_text(), "");
    assert_eq!(f.sent(), [serde_json::json!({"t": "cancel", "utterance": 2147483649u32})]);
    assert!(!f.c.is_speaking());
}

#[test]
fn tapping_the_reminder_card_before_its_speech_sends_nothing() {
    let f = fixture();
    f.c.on_message(REMINDER);
    f.ui.invoke_reply_tapped();
    assert_eq!(f.ui.get_reply_text(), "");
    assert!(f.sent().is_empty(), "{:?}", f.sent());
}

#[test]
fn tapping_an_ordinary_reply_card_does_not_cancel_speech() {
    let f = fixture();
    let id = own_utterance(&f);
    f.c.on_message(&format!(r#"{{"t":"speak_start","utterance":{id},"sample_rate":22050}}"#));
    mood(&f, "speaking");
    f.c.on_message(&format!(r#"{{"t":"reply_text","utterance":{id},"text":"All good."}}"#));
    let before = f.sent().len();
    f.ui.invoke_reply_tapped();
    assert_eq!(f.ui.get_reply_text(), "");
    assert_eq!(f.sent().len(), before, "{:?}", f.sent());
    assert!(f.c.is_speaking());
}

#[test]
fn reply_text_replaces_a_reminder_card() {
    let f = fixture();
    f.c.on_message(REMINDER);
    f.c.on_message(r#"{"t":"transcript","utterance":1,"text":"what is up"}"#);
    f.c.on_message(r#"{"t":"reply_text","utterance":1,"text":"All good."}"#);
    assert_eq!(f.ui.get_reply_text(), "All good.");
    assert_eq!(f.ui.get_reply_heading(), "what is up");
    for _ in 0..42 {
        f.c.tick(Some(NOW)); // past 20 s: the reply expires as replies do
    }
    assert_eq!(f.ui.get_reply_text(), "");
}

#[test]
fn reminder_returns_from_the_session_list_to_home() {
    let f = fixture();
    f.feed("state");
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.ui.get_page(), Page::List);
    f.c.on_message(REMINDER);
    assert_eq!(f.ui.get_page(), Page::Home);
    assert_eq!(f.ui.get_reply_text(), "check the oven");
}

#[test]
fn reminder_returns_from_a_session_detail_to_home() {
    let f = fixture();
    f.feed("state");
    f.ui.invoke_row_tapped(0);
    assert_eq!(f.ui.get_page(), Page::Detail);
    f.c.on_message(REMINDER);
    assert_eq!(f.ui.get_page(), Page::Home);
}

#[test]
fn reminder_does_not_cover_a_waiting_question() {
    let f = fixture();
    f.ask("question_single");
    f.c.on_message(REMINDER);
    assert_eq!(f.ui.get_page(), Page::Question);
    f.ui.invoke_option_tapped(1);
    assert_eq!(f.ui.get_page(), Page::Home);
    assert_eq!(f.ui.get_reply_text(), "check the oven", "the card is there once the question is answered");
}

#[test]
fn tap_during_bridge_speech_cancels_the_bridge_id() {
    let f = fixture();
    f.c.on_message(r#"{"t":"creature","mood":"speaking"}"#);
    f.c.on_message(r#"{"t":"speak_start","utterance":2147483649,"sample_rate":22050}"#);
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.sent().last().unwrap(), &serde_json::json!({"t": "cancel", "utterance": 2147483649u32}));
    assert_eq!(f.ui.get_page(), Page::Home);
}

/// A finished hold: the board's own last utterance has an id.
fn own_utterance(f: &Fixture) -> u32 {
    f.c.hold_started(233, 233);
    let id = f.c.utterance().unwrap();
    f.c.hold_ended();
    id
}

#[test]
fn tap_after_bridge_speech_ended_cancels_the_board_id_not_the_bridge_id() {
    let f = fixture();
    let id = own_utterance(&f);
    f.c.on_message(r#"{"t":"speak_start","utterance":2147483649,"sample_rate":22050}"#);
    f.c.on_message(r#"{"t":"speak_end","utterance":2147483649}"#);
    mood(&f, "speaking");
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.sent().last().unwrap(), &serde_json::json!({"t": "cancel", "utterance": id}));
    assert!(f.sent().iter().all(|v| v["utterance"] != 2147483649u32));
}

#[test]
fn tap_during_own_reply_still_cancels_own_id() {
    let f = fixture();
    f.c.hold_started(233, 233);
    let id = f.c.utterance().unwrap();
    f.c.hold_ended();
    f.c.on_message(&format!(r#"{{"t":"speak_start","utterance":{id},"sample_rate":22050}}"#));
    mood(&f, "speaking");
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.sent().last().unwrap(), &serde_json::json!({"t": "cancel", "utterance": id}));
}

#[test]
fn link_drop_forgets_the_bridge_speech() {
    let f = fixture();
    f.c.on_message(r#"{"t":"speak_start","utterance":2147483649,"sample_rate":22050}"#);
    // The drop clears the board's own utterance too, so start a new hold after the link is back.
    f.c.set_link(false);
    f.c.set_link(true);
    let id = own_utterance(&f);
    mood(&f, "speaking");
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.sent().last().unwrap(), &serde_json::json!({"t": "cancel", "utterance": id}));
    assert!(f.sent().iter().all(|v| v["utterance"] != 2147483649u32));
}

// The command menu, opened by a swipe down from the top edge of home.

#[test]
fn edge_menu_opens_and_a_rim_tap_opens_its_page() {
    let f = fixture();
    f.feed("state"); // three arcs, midpoints 60, 180 and 300 degrees
    assert_eq!(f.ui.get_rim().row_count() + f.ui.get_rim_pulsing().row_count(), 3);
    f.c.open_menu();
    assert!(f.c.menu_open());
    assert!(f.ui.get_menu_open());
    assert_eq!(f.ui.get_commands().row_count(), 3);
    assert_eq!(f.ui.get_rim().row_count() + f.ui.get_rim_pulsing().row_count(), 1, "the top arcs make way for the menu");
    f.ui.invoke_rim_tapped(60.0); // a session arc's angle, but no command there: nothing
    assert_eq!(f.ui.get_page(), Page::Home);
    assert!(f.c.menu_open());
    f.ui.invoke_rim_tapped(2.0); // Link
    assert_eq!(f.ui.get_page(), Page::Link);
    assert!(!f.c.menu_open());
    assert!(!f.ui.get_menu_open());
    assert_eq!(f.ui.get_rim().row_count() + f.ui.get_rim_pulsing().row_count(), 3);
    f.ui.invoke_back_tapped();
    f.c.open_menu();
    f.ui.invoke_rim_tapped(-44.0);
    assert_eq!(f.ui.get_page(), Page::Volume);
}

#[test]
fn purge_does_nothing_while_the_link_is_down() {
    let f = fixture();
    f.c.open_menu();
    f.ui.invoke_rim_tapped(44.0);
    assert_eq!(f.ui.get_page(), Page::Home);
    assert!(f.c.menu_open());
    f.c.set_link(true);
    f.ui.invoke_rim_tapped(44.0);
    assert_eq!(f.ui.get_page(), Page::Purge);
}

#[test]
fn the_menu_opens_only_on_home() {
    let f = fixture();
    f.feed("state");
    f.ui.invoke_avatar_tapped();
    assert_eq!(f.ui.get_page(), Page::List);
    f.c.open_menu();
    assert!(!f.c.menu_open());
}

#[test]
fn the_menu_closes_after_ten_idle_seconds() {
    let f = fixture();
    f.c.tick_at(Some(NOW), 100_000);
    f.c.open_menu();
    f.c.tick_at(Some(NOW), 109_999);
    assert!(f.c.menu_open());
    f.c.tick_at(Some(NOW), 110_000);
    assert!(!f.c.menu_open());
    assert!(!f.ui.get_menu_open());
}

#[test]
fn a_touch_keeps_the_menu_open() {
    let f = fixture();
    f.c.tick_at(Some(NOW), 100_000);
    f.c.open_menu();
    f.c.tick_at(Some(NOW), 108_000);
    f.c.note_touch();
    f.c.tick_at(Some(NOW), 117_999);
    assert!(f.c.menu_open(), "ten seconds count from the last touch");
    f.c.tick_at(Some(NOW), 118_000);
    assert!(!f.c.menu_open());
}

#[test]
fn the_avatar_closes_the_menu() {
    let f = fixture();
    f.c.open_menu();
    f.ui.invoke_avatar_tapped();
    assert!(!f.c.menu_open());
    assert_eq!(f.ui.get_page(), Page::List, "and opens the list, as it does with the menu closed");
    f.ui.invoke_back_tapped();
    f.c.open_menu();
    assert!(f.c.hold_started(233, 233), "holding the avatar still talks");
    assert!(!f.c.menu_open());
}

#[test]
fn back_on_home_closes_the_menu() {
    let f = fixture();
    f.c.open_menu();
    f.ui.invoke_back_tapped();
    assert!(!f.c.menu_open());
    assert_eq!(f.ui.get_page(), Page::Home);
}

#[test]
fn back_from_a_command_page_returns_home() {
    let f = fixture();
    f.c.set_link(true);
    for (deg, page) in [(-44.0, Page::Volume), (0.0, Page::Link), (44.0, Page::Purge)] {
        f.c.open_menu();
        f.ui.invoke_rim_tapped(deg);
        assert_eq!(f.ui.get_page(), page);
        f.ui.invoke_back_tapped();
        assert_eq!(f.ui.get_page(), Page::Home);
        assert!(!f.c.menu_open());
    }
}

#[test]
fn a_question_closes_the_menu_and_answering_returns_home() {
    let f = fixture();
    f.c.open_menu();
    f.ask("question_single");
    assert_eq!(f.ui.get_page(), Page::Question);
    assert!(!f.c.menu_open());
    f.ui.invoke_option_tapped(0);
    assert_eq!(f.ui.get_page(), Page::Home);
    assert!(!f.c.menu_open());
}

#[test]
fn a_question_over_a_command_page_returns_home_once_answered() {
    let g = fixture();
    g.c.open_menu();
    g.ui.invoke_rim_tapped(0.0);
    assert_eq!(g.ui.get_page(), Page::Link);
    g.ask("question_single");
    assert_eq!(g.ui.get_page(), Page::Question);
    g.ui.invoke_option_tapped(0);
    assert_eq!(g.ui.get_page(), Page::Home);
    assert!(!g.c.menu_open());
}

impl Fixture {
    /// A real tap at screen (x, y), through Slint's touch areas.
    fn tap(&self, x: f32, y: f32) {
        let position = LogicalPosition::new(x, y);
        let w = &self._h.window;
        w.dispatch_event(WindowEvent::PointerPressed { position, button: PointerEventButton::Left });
        w.dispatch_event(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
        w.dispatch_event(WindowEvent::PointerExited);
    }
}

#[test]
fn a_tap_on_a_menu_arc_over_the_avatars_box_opens_the_command() {
    let f = fixture();
    f.c.open_menu();
    // The Volume arc at -44 degrees, radius 180: inside the avatar's 280 px box but outside its circle.
    let (x, y) = (233.0 - 180.0 * 44f32.to_radians().sin(), 233.0 - 180.0 * 44f32.to_radians().cos());
    assert!(x > 93.0 && y > 93.0, "the point is in the avatar's box");
    f.tap(x, y);
    assert_eq!(f.ui.get_page(), Page::Volume);
    // The Link arc's middle, through the window's ring.
    f.ui.invoke_back_tapped();
    f.c.open_menu();
    f.tap(233.0, 33.0);
    assert_eq!(f.ui.get_page(), Page::Link);
    // With the menu closed, the avatar still opens the list.
    f.ui.invoke_back_tapped();
    f.tap(233.0, 233.0);
    assert_eq!(f.ui.get_page(), Page::List);
}

#[test]
fn tapping_a_command_label_opens_its_page() {
    // The labels sit at radius about 160, between the avatar's circle (140) and the arcs: a tap on one is a tap on
    // its command.
    let f = fixture();
    f.c.set_link(true);
    for ((x, y), page) in [((122.0, 119.0), Page::Volume), ((233.0, 73.0), Page::Link), ((344.0, 119.0), Page::Purge)] {
        f.c.open_menu();
        f.tap(x, y);
        assert_eq!(f.ui.get_page(), page, "label at ({x}, {y})");
        f.ui.invoke_back_tapped();
    }
    // The avatar itself still opens the list with the menu open.
    f.c.open_menu();
    f.tap(233.0, 233.0);
    assert_eq!(f.ui.get_page(), Page::List);
}

// The volume and purge pages.

#[test]
fn volume_buttons_queue_steps() {
    let f = fixture();
    assert_eq!(f.c.take_volume_step(), None);
    f.ui.invoke_volume_step(true);
    assert_eq!(f.c.take_volume_step(), Some(true));
    assert_eq!(f.c.take_volume_step(), None);
    f.ui.invoke_volume_step(false);
    assert_eq!(f.c.take_volume_step(), Some(false));
    assert_eq!(f.c.take_volume_step(), None);
}

#[test]
fn the_ticks_are_built_once() {
    let f = fixture();
    assert_eq!(f.ui.get_volume_ticks().row_count(), 24);
    assert_eq!(f.ui.get_ring_ticks().row_count(), 36);
}

impl Fixture {
    fn open_purge(&self) {
        self.c.set_link(true);
        self.c.open_menu();
        self.ui.invoke_rim_tapped(44.0);
        assert_eq!(self.ui.get_page(), Page::Purge);
    }
    fn new_sessions(&self) -> Vec<u64> {
        self.sent().iter().filter(|v| v["t"] == "new_session").map(|v| v["utterance"].as_u64().unwrap()).collect()
    }
}

#[test]
fn purge_sends_new_session_once_and_goes_home() {
    let f = fixture();
    f.open_purge();
    f.ui.invoke_purge_confirmed();
    assert_eq!(f.new_sessions(), [1]);
    assert_eq!(f.ui.get_page(), Page::Home);
    assert_eq!(f.ui.get_presence_state(), PresenceState::Thinking);
    // Again while the bridge has not answered: nothing more is sent.
    f.open_purge();
    f.ui.invoke_purge_confirmed();
    assert_eq!(f.new_sessions(), [1]);
}

#[test]
fn purge_takes_the_next_utterance_id() {
    let f = fixture();
    let spoken = own_utterance(&f);
    f.open_purge();
    f.ui.invoke_purge_confirmed();
    assert_eq!(f.new_sessions(), [spoken as u64 + 1]);
    assert!(f.c.hold_started(233, 233));
    assert_eq!(f.c.utterance(), Some(spoken + 2), "and the next hold takes the one after");
}

#[test]
fn purge_is_ignored_while_unlinked() {
    let f = fixture();
    f.open_purge();
    f.c.set_link(false);
    f.ui.invoke_purge_confirmed();
    assert!(f.new_sessions().is_empty());
    assert_eq!(f.ui.get_page(), Page::Purge);
}

#[test]
fn session_reset_clears_the_wait() {
    let f = fixture();
    f.open_purge();
    f.ui.invoke_purge_confirmed();
    f.c.on_message(r#"{"t":"session_reset","utterance":99}"#); // not ours
    f.open_purge();
    f.ui.invoke_purge_confirmed();
    assert_eq!(f.new_sessions(), [1]);
    f.c.on_message(r#"{"t":"session_reset","utterance":1}"#);
    f.ui.invoke_purge_confirmed();
    assert_eq!(f.new_sessions(), [1, 2]);
}

#[test]
fn session_reset_clears_the_wait_and_keeps_thinking() {
    let f = fixture();
    f.open_purge();
    f.ui.invoke_purge_confirmed();
    assert!(f.ui.get_purge_pending());
    f.c.on_message(r#"{"t":"session_reset","utterance":99}"#);
    assert_eq!(f.ui.get_presence_state(), PresenceState::Thinking, "another id changes nothing");
    assert!(f.ui.get_purge_pending());
    f.c.on_message(r#"{"t":"session_reset","utterance":1}"#);
    assert!(!f.ui.get_purge_pending(), "the wait is over");
    assert_eq!(f.ui.get_presence_state(), PresenceState::Thinking, "the bridge's own mood follows");
    // When speech works, the bridge's speaking mood follows and takes over; when it fails, its idle does.
    mood(&f, "speaking");
    assert_eq!(f.ui.get_presence_state(), PresenceState::Speaking);
    mood(&f, "idle");
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
}

#[test]
fn purge_while_offline_keeps_offline() {
    let f = fixture();
    f.open_purge();
    mood(&f, "offline");
    f.ui.invoke_purge_confirmed();
    assert_eq!(f.new_sessions(), [1], "the link is up: the purge is still sent");
    assert!(!f.ui.get_voice_available(), "offline is not overwritten by thinking");
    assert_ne!(f.ui.get_presence_state(), PresenceState::Thinking);
}

#[test]
fn a_voice_hold_ends_the_purge_wait() {
    let f = fixture();
    f.c.tick_at(Some(NOW), 100_000);
    f.open_purge();
    f.ui.invoke_purge_confirmed();
    assert!(f.c.hold_started(233, 233));
    assert!(!f.ui.get_purge_pending(), "the hold took over from the purge");
    f.c.tick_at(Some(NOW), 101_000);
    f.c.hold_ended();
    assert_eq!(f.ui.get_presence_state(), PresenceState::Thinking);
    // Past the purge's 10 s fallback: the question's thinking stays.
    f.c.tick_at(Some(NOW), 110_500);
    assert_eq!(f.ui.get_presence_state(), PresenceState::Thinking);
}

#[test]
fn no_session_reset_drops_to_idle_after_ten_seconds() {
    let f = fixture();
    f.c.tick_at(Some(NOW), 100_000);
    f.open_purge();
    f.ui.invoke_purge_confirmed();
    f.c.tick_at(Some(NOW), 109_999);
    assert_eq!(f.ui.get_presence_state(), PresenceState::Thinking);
    f.c.tick_at(Some(NOW), 110_000);
    assert_eq!(f.ui.get_presence_state(), PresenceState::Idle);
    // The wait is over: a purge can be tried again.
    f.open_purge();
    f.ui.invoke_purge_confirmed();
    assert_eq!(f.new_sessions(), [1, 2]);
}
