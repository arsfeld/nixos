//! The session list as a fan-out wheel: the row at the vertical centre sits furthest left, rows above and
//! below curve away to the right and fade, and a tap on the centre row opens it, whatever the scroll.

use std::cell::RefCell;
use std::rc::Rc;

use claude_board_ui::controller::{Controller, Outbox};
use claude_board_ui::headless::{headless, rgb, Headless};
use claude_board_ui::{AppWindow, Page};
use slint::platform::{PointerEventButton, WindowEvent};
use slint::platform::software_renderer::Rgb565Pixel;
use slint::{ComponentHandle, LogicalPosition};

const W: usize = 466;
/// Row pitch and the screen y of the first row's centre at scroll 0 (see sessions.slint).
const PITCH: f32 = 56.0;
const FIRST_ROW_Y: f32 = 231.0;

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
    _c: Controller<Wire>,
}

/// Eight working sessions p0..p7 (blue badges), the list open.
fn fx() -> Fx {
    let h = headless();
    let ui = AppWindow::new().unwrap();
    ui.show().unwrap();
    let c = Controller::new(&ui, Wire::default());
    c.tick(Some(1_800_000_000));
    let sessions: Vec<String> = (0..8)
        .map(|i| format!(r#"{{"host":"h{i}","session":"s{i}","project":"p{i}","cwd":"/","state":"working","since":{}}}"#, 1_000 - i))
        .collect();
    c.on_message(&format!(r#"{{"t":"state","sessions":[{}]}}"#, sessions.join(",")));
    ui.invoke_avatar_tapped();
    assert_eq!(ui.get_page(), Page::List);
    Fx { h, ui, _c: c }
}

impl Fx {
    fn tap(&self, x: f32, y: f32) {
        let position = LogicalPosition::new(x, y);
        let w = &self.h.window;
        w.dispatch_event(WindowEvent::PointerPressed { position, button: PointerEventButton::Left });
        w.dispatch_event(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
        w.dispatch_event(WindowEvent::PointerExited);
    }
}

/// Blue-dominant, however faded: the working badge is (59, 130, 246) times the row's fade.
fn is_blue((r, g, b): (u8, u8, u8)) -> bool {
    b >= 50 && b as i32 - r as i32 > 40 && b as i32 - g as i32 > 25
}

/// The left-most blue (badge) pixel and the brightest blue in the band around screen row `yc`, ignoring the rim.
fn badge(buf: &[Rgb565Pixel], yc: f32) -> Option<(usize, u8)> {
    let (mut left, mut bright) = (None, 0u8);
    for y in (yc as usize - 16)..(yc as usize + 16) {
        for x in 0..W {
            let (dx, dy) = (x as f32 - 233.0, y as f32 - 233.0);
            if (dx * dx + dy * dy).sqrt() > 205.0 {
                continue; // the rim is blue too
            }
            let px = rgb(buf[y * W + x]);
            if is_blue(px) {
                left = Some(left.map_or(x, |l: usize| l.min(x)));
                bright = bright.max(px.2);
            }
        }
    }
    left.map(|l| (l, bright))
}

#[test]
fn rows_curve_away_from_the_centre_row() {
    let f = fx();
    let buf = f.h.render();
    let lefts: Vec<usize> = (0..3).map(|k| badge(&buf, FIRST_ROW_Y + k as f32 * PITCH).expect("a badge").0).collect();
    assert!(lefts[0] < lefts[1] && lefts[1] < lefts[2], "badges should drift right away from the centre: {lefts:?}");
    assert!(lefts[2] - lefts[0] >= 20, "the curve should be visible: {lefts:?}");
}

#[test]
fn rows_fade_away_from_the_centre_row() {
    let f = fx();
    let buf = f.h.render();
    let bright: Vec<u8> = (0..3).map(|k| badge(&buf, FIRST_ROW_Y + k as f32 * PITCH).expect("a badge").1).collect();
    assert!(bright[0] > bright[2], "a row two steps off the centre should be dimmer: {bright:?}");
}

#[test]
fn scrolling_brings_another_row_to_the_centre() {
    let f = fx();
    let at_start = badge(&f.h.render(), FIRST_ROW_Y).expect("a badge").0;
    f.ui.set_list_scroll(-3.0 * PITCH);
    // Row 3 is now where row 0 was: its badge sits at the centre row's left edge.
    let at_centre = badge(&f.h.render(), FIRST_ROW_Y).expect("a badge").0;
    assert_eq!(at_centre, at_start);
}

#[test]
fn tapping_the_centre_row_opens_it_at_any_scroll() {
    let f = fx();
    for scroll_rows in [0, 3, 5] {
        f.ui.set_list_scroll(-(scroll_rows as f32) * PITCH);
        f.h.render();
        f.tap(233.0, FIRST_ROW_Y);
        assert_eq!(f.ui.get_page(), Page::Detail, "scrolled {scroll_rows} rows");
        assert_eq!(f.ui.get_detail_project(), format!("p{scroll_rows}"));
        f.ui.invoke_back_tapped(); // back to the list, which keeps its scroll position
        assert_eq!(f.ui.get_page(), Page::List);
    }
}

#[test]
fn entering_the_list_starts_at_the_first_row() {
    let f = fx();
    f.ui.set_list_scroll(-4.0 * PITCH);
    f.ui.invoke_back_tapped(); // home
    f.ui.invoke_avatar_tapped(); // the list again
    assert_eq!(f.ui.get_list_scroll(), 0.0);
}
