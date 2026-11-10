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
const PITCH: f32 = 104.0;
/// At scroll 0 the first row is one slot above the screen centre, so row 1 is centred.
const FIRST_ROW_Y: f32 = 129.0;
const CENTRE_Y: f32 = 233.0;

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
            if (212.0..=228.0).contains(&(dx * dx + dy * dy).sqrt()) {
                continue; // the rim is blue too; skip its band (a badge leaving at the edge may still show past it)
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
    let buf = f.h.render(); // row 1 is at the centre, rows 0 and 2 above and below it
    let left = |dy: f32| badge(&buf, CENTRE_Y + dy).expect("a badge").0;
    let (above, centre, below) = (left(-PITCH), left(0.0), left(PITCH));
    assert!(centre + 15 <= above && centre + 15 <= below, "badges should sweep right away from the centre: {above} {centre} {below}");
}

#[test]
fn rows_leaving_the_screen_straighten_out() {
    let f = fx();
    let buf = f.h.render(); // rows 0..3 at dy = -104, 0, 104, 208
    let left = |dy: f32| badge(&buf, CENTRE_Y + dy);
    let centre = left(0.0).expect("a badge").0;
    // The row at dy=104 has bent right by about 24 px. The one at dy=208 is leaving, and must not have
    // swung much further than the curve's limit (64 px), where a plain circle would put it 128 px out.
    let leaving = left(208.0).expect("the leaving row's badge").0;
    assert!(leaving <= centre + 70, "a row leaving the screen bent too far right: {leaving} vs centre {centre}");
}

#[test]
fn scrolling_brings_another_row_to_the_centre() {
    let f = fx();
    let at_start = badge(&f.h.render(), CENTRE_Y).expect("a badge").0;
    f.ui.set_list_scroll(-3.0 * PITCH); // row 4 where row 1 was
    let at_centre = badge(&f.h.render(), CENTRE_Y).expect("a badge").0;
    assert_eq!(at_centre, at_start);
}

#[test]
fn tapping_the_centre_row_opens_it_at_any_scroll() {
    let f = fx();
    for scroll_rows in [0, 2, 4] {
        f.ui.set_list_scroll(-(scroll_rows as f32) * PITCH);
        f.h.render();
        f.tap(233.0, CENTRE_Y);
        assert_eq!(f.ui.get_page(), Page::Detail, "scrolled {scroll_rows} rows");
        assert_eq!(f.ui.get_detail_project(), format!("p{}", scroll_rows + 1)); // row 1 is centred at scroll 0
        f.ui.invoke_back_tapped(); // back to the list, which keeps its scroll position
        assert_eq!(f.ui.get_page(), Page::List);
    }
}

#[test]
fn the_first_row_starts_one_slot_above_the_centre_and_can_be_tapped() {
    let f = fx();
    f.h.render();
    f.tap(233.0, FIRST_ROW_Y);
    assert_eq!((f.ui.get_page(), f.ui.get_detail_project().to_string()), (Page::Detail, "p0".into()));
}

#[test]
fn entering_the_list_starts_at_the_first_row() {
    let f = fx();
    f.ui.set_list_scroll(-4.0 * PITCH);
    f.ui.invoke_back_tapped(); // home
    f.ui.invoke_avatar_tapped(); // the list again
    assert_eq!(f.ui.get_list_scroll(), 0.0);
}
