//! Real pointer events at real coordinates, so the Slint touch areas themselves are tested (the controller
//! tests call the callbacks directly and would not notice a touch area that never receives a tap).

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use claude_board_ui::controller::{Controller, Outbox};
use claude_board_ui::headless::{headless, Headless};
use claude_board_ui::touch::TouchTracker;
use claude_board_ui::{AppWindow, Page};
use slint::platform::{PointerEventButton, WindowEvent};
use slint::{ComponentHandle, LogicalPosition};

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
    ticks: Cell<u32>,
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
    c.tick(Some(1_800_000_000));
    Fx { h, ui, c, wire, ticks: Cell::new(0) }
}

impl Fx {
    fn feed(&self, name: &str) {
        self.c.on_message(&load(name));
    }

    /// A finger down and up at (x, y), the way the firmware's touch loop reports it.
    fn tap(&self, x: f32, y: f32) {
        let position = LogicalPosition::new(x, y);
        let w = &self.h.window;
        w.dispatch_event(WindowEvent::PointerPressed { position, button: PointerEventButton::Left });
        w.dispatch_event(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
        w.dispatch_event(WindowEvent::PointerExited);
        // A tick between taps, as in the app, so the double-tap guard has moved on.
        self.ticks.set(self.ticks.get() + 1);
        self.c.tick(Some(1_800_000_000));
    }
}

#[test]
fn tapping_the_avatar_opens_the_list() {
    let f = fx();
    f.feed("state");
    f.h.render();
    f.tap(233.0, 233.0);
    assert_eq!(f.ui.get_page(), Page::List);
}

#[test]
fn tapping_anywhere_in_the_avatars_box_opens_the_list() {
    let f = fx();
    f.feed("state");
    for (x, y) in [(258.0, 270.0), (266.0, 222.0), (273.0, 202.0), (110.0, 110.0), (350.0, 350.0)] {
        f.h.render();
        f.tap(x, y);
        assert_eq!(f.ui.get_page(), Page::List, "tap at ({x}, {y})");
        f.ui.invoke_back_tapped();
        assert_eq!(f.ui.get_page(), Page::Home);
    }
}

/// The touch controller's stream as the firmware sees it: coordinates only while a finger is down, and a
/// stale (0, 0) sample once it is up. Fed through the tracker into the real window.
#[test]
fn a_finger_stream_with_stale_release_coordinates_still_taps_the_avatar() {
    let f = fx();
    f.feed("state");
    f.h.render();
    let mut tracker = TouchTracker::new();
    for (x, y, pressed) in [(258, 270, true), (258, 270, true), (259, 271, true), (0, 0, false), (0, 0, false)] {
        for event in tracker.update(x, y, pressed) {
            f.h.window.dispatch_event(event);
        }
        f.h.render();
    }
    assert_eq!(f.ui.get_page(), Page::List);
}

#[test]
fn tapping_the_ring_opens_that_session() {
    let f = fx();
    f.feed("state"); // 3 arcs: galactica (waiting) from the top, clockwise
    f.h.render();
    f.tap(233.0, 12.0);
    assert_eq!((f.ui.get_page(), f.ui.get_detail_host().to_string()), (Page::Detail, "galactica".into()));
}

#[test]
fn list_row_and_back_buttons_work() {
    let f = fx();
    f.feed("state");
    f.tap(233.0, 233.0); // list
    f.h.render();
    f.tap(233.0, 116.0); // first row
    assert_eq!(f.ui.get_page(), Page::Detail);
    f.h.render();
    f.tap(233.0, 396.0); // Back
    assert_eq!(f.ui.get_page(), Page::List);
    f.h.render();
    f.tap(233.0, 396.0); // Back again
    assert_eq!(f.ui.get_page(), Page::Home);
}

#[test]
fn tapping_an_option_answers_the_question() {
    let f = fx();
    f.feed("question_single");
    f.h.render();
    f.tap(233.0, 201.0); // first option, Red
    let sent = f.wire.0.borrow().clone();
    assert_eq!(sent.len(), 1);
    assert!(sent[0].contains(r#""Which colour?":"Red""#), "{}", sent[0]);
}

#[test]
fn tapping_on_computer_declines() {
    let f = fx();
    f.feed("question_single");
    f.h.render();
    f.tap(233.0, 428.0);
    let sent = f.wire.0.borrow().clone();
    assert_eq!(sent.len(), 1);
    assert!(sent[0].contains(r#""t":"decline""#), "{}", sent[0]);
}

#[test]
fn multi_select_taps_and_done_work() {
    let f = fx();
    f.feed("question_multi");
    f.h.render();
    f.tap(233.0, 201.0); // fruit: Apple
    f.h.render();
    f.tap(233.0, 201.0); // topping: Nuts
    f.h.render();
    f.tap(233.0, 392.0); // Done
    let sent = f.wire.0.borrow().clone();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert!(sent[0].contains(r#""Which toppings?":"Nuts""#), "{}", sent[0]);
}
