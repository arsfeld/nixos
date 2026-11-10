//! A refresh (the app ticks four times a second, and every bridge message refreshes) must not destroy the
//! controls under a finger: a tap is a press and a release some 100 ms apart, and a touch area rebuilt in
//! between never sees the release, so the tap is lost.

use std::cell::RefCell;
use std::rc::Rc;

use claude_board_ui::controller::{Controller, Outbox};
use claude_board_ui::headless::{headless, Headless};
use claude_board_ui::{AppWindow, Page};
use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, LogicalPosition, Model as _};

const NOW: i64 = 1_800_000_000;

#[derive(Clone, Default)]
struct Wire(Rc<RefCell<Vec<String>>>);
impl Outbox for Wire {
    fn send(&self, json: String) -> bool {
        self.0.borrow_mut().push(json);
        true
    }
}

struct Fx {
    h: Headless,
    ui: AppWindow,
    c: Controller<Wire>,
    wire: Wire,
}

fn load(name: &str) -> String {
    let dir = format!("{}/../../../packages/claude-board-bridge/tests/fixtures/board", env!("CARGO_MANIFEST_DIR"));
    std::fs::read_to_string(format!("{dir}/{name}.json")).unwrap()
}

fn fx() -> Fx {
    let h = headless();
    let ui = AppWindow::new().unwrap();
    ui.show().unwrap();
    let wire = Wire::default();
    let c = Controller::new(&ui, wire.clone());
    c.tick(Some(NOW));
    Fx { h, ui, c, wire }
}

impl Fx {
    fn press(&self, x: f32, y: f32) {
        self.h.window.dispatch_event(WindowEvent::PointerPressed { position: LogicalPosition::new(x, y), button: PointerEventButton::Left });
    }
    fn release(&self, x: f32, y: f32) {
        let position = LogicalPosition::new(x, y);
        self.h.window.dispatch_event(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
        self.h.window.dispatch_event(WindowEvent::PointerExited);
    }
}

#[test]
fn a_list_row_tap_survives_a_tick_between_press_and_release() {
    let f = fx();
    f.c.on_message(&load("state"));
    f.ui.invoke_avatar_tapped();
    f.h.render();
    f.press(233.0, 129.0);
    f.c.tick(Some(NOW)); // the app's 250 ms refresh lands mid-tap
    f.h.render();
    f.release(233.0, 129.0);
    assert_eq!(f.ui.get_page(), Page::Detail, "the tap was lost when the list was refreshed under the finger");
}

#[test]
fn a_list_row_tap_survives_a_bridge_message_between_press_and_release() {
    let f = fx();
    f.c.on_message(&load("state"));
    f.ui.invoke_avatar_tapped();
    f.h.render();
    f.press(233.0, 129.0);
    f.c.on_message(&load("upsert")); // a session changed while the finger was down
    f.h.render();
    f.release(233.0, 129.0);
    assert_eq!(f.ui.get_page(), Page::Detail);
}

#[test]
fn an_option_tap_survives_a_tick_between_press_and_release() {
    let f = fx();
    f.c.on_message(&load("question_single"));
    f.c.tick(Some(NOW)); // taps in the first 500 ms after a question appears are ignored
    f.h.render();
    f.press(233.0, 201.0); // the first option, Red
    f.c.tick(Some(NOW));
    f.h.render();
    f.release(233.0, 201.0);
    assert_eq!(f.wire.0.borrow().len(), 1, "the answer was lost when the options were refreshed under the finger");
}

#[test]
fn the_double_tap_guard_lasts_400_ms_across_a_tick_boundary() {
    // Several questions in one ask: a second tap would answer the next question by mistake.
    let f = fx();
    f.c.set_time_ms(10_000);
    f.c.on_message(&load("question_multi"));
    f.c.set_time_ms(10_500); // the question has been up for 500 ms: it can be tapped
    f.ui.invoke_option_tapped(1); // fruit: Pear, answered at t = 10.5 s
    assert_eq!(f.ui.get_question_text(), "Which toppings?");
    f.c.tick_at(Some(NOW), 10_750); // the app's refresh lands in between
    f.ui.invoke_option_tapped(0); // 250 ms after the answer: still a double tap
    assert!(f.ui.get_options().iter().all(|o| !o.selected), "a tap 250 ms after an answer must be ignored");
    f.c.set_time_ms(10_950);
    f.ui.invoke_option_tapped(0); // 450 ms: a deliberate tap
    assert!(f.ui.get_options().iter().any(|o| o.selected));
}

#[test]
fn the_board_shows_offline_until_the_bridge_connects() {
    let f = fx();
    assert!(!f.ui.get_link(), "no connection yet: the home screen must say OFFLINE");
    f.c.set_link(true);
    assert!(f.ui.get_link());
    f.c.set_link(false);
    assert!(!f.ui.get_link());
}
