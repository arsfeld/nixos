//! Headless renders of the real Slint scene, checked pixel by pixel. They run the same software
//! renderer the board uses, so what passes here is what the panel draws.

use claude_board_ui::headless::{headless, rgb, Headless};
use claude_board_ui::rim::arc_segment;
use claude_board_ui::theme;
use claude_board_ui::{AppWindow, PresenceState, RimSegment, SessionState};
use slint::platform::software_renderer::Rgb565Pixel;
use slint::{ComponentHandle, Global, ModelRc, VecModel};

const W: usize = 466;

fn show() -> (Headless, AppWindow) {
    let h = headless();
    let ui = AppWindow::new().unwrap();
    ui.show().unwrap();
    (h, ui)
}

fn px(buf: &[Rgb565Pixel], x: usize, y: usize) -> (u8, u8, u8) {
    rgb(buf[y * W + x])
}

fn is_amber((r, g, b): (u8, u8, u8)) -> bool {
    r > 180 && (110..=210).contains(&g) && b < 110
}

fn near(a: (u8, u8, u8), b: (u8, u8, u8), tol: i32) -> bool {
    let d = |x: u8, y: u8| (x as i32 - y as i32).abs();
    d(a.0, b.0) <= tol && d(a.1, b.1) <= tol && d(a.2, b.2) <= tol
}

fn set_rim(ui: &AppWindow, still: Vec<RimSegment>, pulsing: Vec<RimSegment>) {
    ui.set_rim(ModelRc::new(VecModel::from(still)));
    ui.set_rim_pulsing(ModelRc::new(VecModel::from(pulsing)));
}

/// The point on the rim's centre line at `deg` clockwise from the top.
fn rim_point(deg: f32) -> (usize, usize) {
    let r = deg.to_radians();
    ((233.0 + 220.0 * r.sin()).round() as usize, (233.0 - 220.0 * r.cos()).round() as usize)
}

#[test]
fn presence_alert_draws_amber_pixels_near_the_centre() {
    let (h, ui) = show();
    ui.set_presence_state(PresenceState::Alert);
    let buf = h.render();
    let amber = (193..273).flat_map(|y| (193..273).map(move |x| (x, y))).filter(|&(x, y)| is_amber(px(&buf, x, y))).count();
    assert!(amber > 200, "only {amber} amber pixels in the 80 x 80 box around the centre");
}

#[test]
fn presence_idle_draws_no_amber() {
    let (h, ui) = show();
    ui.set_presence_state(PresenceState::Idle);
    let buf = h.render();
    let amber = (93..373).flat_map(|y| (93..373).map(move |x| (x, y))).filter(|&(x, y)| is_amber(px(&buf, x, y))).count();
    assert_eq!(amber, 0);
}

#[test]
fn rim_draws_each_segment_in_its_state_colour() {
    let (h, ui) = show();
    let cases = [
        (SessionState::Idle, theme::IDLE),
        (SessionState::Working, theme::WORKING),
        (SessionState::Waiting, theme::WAITING),
        (SessionState::Done, theme::DONE),
        (SessionState::Error, theme::ERROR),
    ];
    let segs = cases.iter().enumerate().map(|(i, (s, _))| arc_segment(i as f32 * 72.0 + 3.5, (i + 1) as f32 * 72.0 - 3.5, *s)).collect();
    set_rim(&ui, segs, vec![]);
    let buf = h.render();
    for (i, (_, want)) in cases.iter().enumerate() {
        let (x, y) = rim_point(i as f32 * 72.0 + 36.0);
        let got = px(&buf, x, y);
        assert!(near(got, *want, 24), "segment {i} at ({x},{y}): got {got:?}, want {want:?}");
    }
}

#[test]
fn rim_with_no_segments_leaves_the_ring_area_black() {
    let (h, ui) = show();
    set_rim(&ui, vec![], vec![]);
    let buf = h.render();
    for deg in (0..360).step_by(10) {
        let (x, y) = rim_point(deg as f32);
        assert_eq!(px(&buf, x, y), (0, 0, 0), "at {deg} degrees");
    }
}

#[test]
fn rim_pulsing_segment_changes_over_time() {
    let (h, ui) = show();
    set_rim(&ui, vec![], vec![arc_segment(3.5, 68.5, SessionState::Waiting)]);
    let (x, y) = rim_point(36.0);
    let before = px(&h.render(), x, y);
    for _ in 0..12 {
        h.step(33);
    }
    let after = px(&h.render(), x, y);
    assert_ne!(before, after, "the waiting arc did not pulse");
}

#[test]
fn rust_theme_colours_match_the_slint_theme() {
    let (_h, ui) = show();
    let t = claude_board_ui::Theme::get(&ui);
    let c = |col: slint::Color| (col.red(), col.green(), col.blue());
    assert_eq!(c(t.get_waiting()), theme::WAITING);
    assert_eq!(c(t.get_working()), theme::WORKING);
    assert_eq!(c(t.get_error()), theme::ERROR);
}

/// Non-black pixels in the question's text box (away from the rim and the wheel) for `texts`, one
/// render each on a single window.
fn question_ink(texts: &[&str]) -> Vec<usize> {
    let (h, ui) = show();
    ui.set_page(claude_board_ui::Page::Question);
    texts
        .iter()
        .map(|t| {
            ui.set_question_text((*t).into());
            let buf = h.render();
            (64..150).flat_map(|y| (83..383).map(move |x| (x, y))).filter(|&(x, y)| px(&buf, x, y) != (0, 0, 0)).count()
        })
        .collect()
}

#[test]
fn accented_latin_letters_have_glyphs() {
    // Names and questions arrive at run time; Slint only embeds glyphs it sees in the sources, which
    // ui/glyphs.slint extends to Latin-1 and Latin Extended-A.
    let ink = question_ink(&[" ", "éàüçñ Œ"]);
    assert_eq!(ink[0], 0);
    assert!(ink[1] > 150, "accented letters drew (almost) nothing: {}", ink[1]);
}

#[test]
fn characters_outside_the_fonts_draw_blank_instead_of_failing() {
    assert_eq!(question_ink(&["日本語"]), vec![0]);
}

#[test]
fn drift_shifts_everything_by_the_given_pixels() {
    let (h, ui) = show();
    set_rim(&ui, vec![arc_segment(3.5, 68.5, SessionState::Error)], vec![]);
    let (x, y) = rim_point(36.0);
    assert!(near(px(&h.render(), x, y), theme::ERROR, 24));
    ui.set_drift_x(4.0);
    ui.set_drift_y(-2.0);
    let buf = h.render();
    assert!(near(px(&buf, x + 4, y - 2), theme::ERROR, 24), "the arc should have moved by (4, -2)");
}

fn feed_row(kind: claude_board_ui::FeedKind, text: &str, failed: bool) -> claude_board_ui::FeedRow {
    claude_board_ui::FeedRow { kind, text: text.into(), failed }
}

fn detail_page() -> (Headless, AppWindow) {
    let (h, ui) = show();
    ui.set_page(claude_board_ui::Page::Detail);
    ui.set_detail_host("raider".into());
    ui.set_detail_project("nixos".into());
    (h, ui)
}

fn set_feed(h: &Headless, ui: &AppWindow, rows: Vec<claude_board_ui::FeedRow>, empty: bool) {
    ui.set_feed(ModelRc::new(VecModel::from(rows)));
    ui.set_feed_empty(empty);
    for _ in 0..4 {
        h.step(33);
    }
}

/// Non-black pixels (and error-coloured ones) in the feed column, below the header.
fn feed_ink(buf: &[Rgb565Pixel]) -> (usize, usize) {
    let mut ink = 0;
    let mut red = 0;
    for y in 164..390 {
        for x in 83..383 {
            let p = px(buf, x, y);
            if p != (0, 0, 0) {
                ink += 1;
            }
            if near(p, theme::ERROR, 40) {
                red += 1;
            }
        }
    }
    (ink, red)
}

/// A finger down at (233, y0), dragged to (233, y1) in ten steps and lifted.
fn drag_y(h: &Headless, y0: f32, y1: f32) {
    use slint::platform::{PointerEventButton, WindowEvent};
    use slint::LogicalPosition;
    let at = |y: f32| LogicalPosition::new(233., y);
    let w = &h.window;
    w.dispatch_event(WindowEvent::PointerPressed { position: at(y0), button: PointerEventButton::Left });
    for i in 1..=10 {
        w.dispatch_event(WindowEvent::PointerMoved { position: at(y0 + (y1 - y0) * i as f32 / 10.) });
        h.step(16);
    }
    w.dispatch_event(WindowEvent::PointerReleased { position: at(y1), button: PointerEventButton::Left });
    w.dispatch_event(WindowEvent::PointerExited);
    h.step(33);
}

#[test]
fn feed_page_shows_the_empty_text() {
    let (h, ui) = detail_page();
    set_feed(&h, &ui, vec![], true);
    assert!(feed_ink(&h.render()).0 > 50, "no empty-feed text drawn");
    set_feed(&h, &ui, vec![], false);
    assert_eq!(feed_ink(&h.render()).0, 0);
}

#[test]
fn a_failed_tool_row_draws_the_error_colour() {
    use claude_board_ui::FeedKind::Tool;
    let (h, ui) = detail_page();
    set_feed(&h, &ui, vec![feed_row(Tool, "Bash cargo test", true)], false);
    assert!(feed_ink(&h.render()).1 > 3, "no error-coloured marker");
    set_feed(&h, &ui, vec![feed_row(Tool, "Bash cargo test", false)], false);
    assert_eq!(feed_ink(&h.render()).1, 0);
}

#[test]
fn feed_follows_the_newest_row() {
    use claude_board_ui::FeedKind::{Prompt, Tool};
    let mut rows: Vec<_> = (0..29).map(|i| feed_row(Prompt, &format!("prompt number {i}"), false)).collect();
    rows.push(feed_row(Tool, "Bash last", true));
    let (h, ui) = detail_page();
    set_feed(&h, &ui, rows, false);
    assert!(feed_ink(&h.render()).1 > 3, "the newest (failed) row is not in view");
}

/// 30 rows whose newest is a failed tool row, so the red marker is in view exactly when the newest row is.
fn thirty_rows(newest: &str) -> Vec<claude_board_ui::FeedRow> {
    use claude_board_ui::FeedKind::{Prompt, Tool};
    let mut rows: Vec<_> = (0..29).map(|i| feed_row(Prompt, &format!("prompt number {i}"), false)).collect();
    rows.push(feed_row(Tool, newest, true));
    rows
}

/// Flick the feed down (finger moving down) until its newest row is out of view.
fn scroll_feed_up(h: &Headless) {
    for _ in 0..6 {
        drag_y(h, 200., 380.);
    }
    assert_eq!(feed_ink(&h.render()).1, 0, "the feed did not scroll up");
}

#[test]
fn feed_follows_the_newest_row_again_once_the_feed_is_replaced() {
    // Scrolled up in one session, then another session's feed arrives on the same page (the controller empties
    // the feed when the watched session changes): it must start at its newest row, not where the first was left.
    let (h, ui) = detail_page();
    set_feed(&h, &ui, thirty_rows("Bash first"), false);
    assert!(feed_ink(&h.render()).1 > 3, "the feed does not start at its newest row");
    scroll_feed_up(&h);
    set_feed(&h, &ui, vec![], true);
    h.render(); // the app draws a frame every pass, so one shows the empty feed while the history is on its way
    set_feed(&h, &ui, thirty_rows("Bash second"), false);
    assert!(feed_ink(&h.render()).1 > 3, "the replaced feed does not start at its newest row");
}

#[test]
fn feed_stays_where_the_user_scrolled_while_entries_arrive() {
    let (h, ui) = detail_page();
    set_feed(&h, &ui, thirty_rows("Bash first"), false);
    scroll_feed_up(&h);
    let mut more = thirty_rows("Bash first");
    more.push(feed_row(claude_board_ui::FeedKind::Reply, "a new reply", false));
    set_feed(&h, &ui, more, false);
    assert_eq!(feed_ink(&h.render()).1, 0, "a new entry pulled the feed away from where the user had scrolled");
}

#[test]
fn feed_opened_with_its_rows_already_there_starts_at_the_newest() {
    // Back from a question that took over the screen: the page is built again over a feed that is already full.
    let (h, ui) = show();
    ui.set_detail_host("raider".into());
    ui.set_detail_project("nixos".into());
    ui.set_feed(ModelRc::new(VecModel::from(thirty_rows("Bash only"))));
    ui.set_feed_empty(false);
    ui.set_page(claude_board_ui::Page::Detail);
    for _ in 0..4 {
        h.step(33);
    }
    assert!(feed_ink(&h.render()).1 > 3, "the page opened at the oldest row");
}

#[test]
fn feed_follows_again_when_the_page_is_left_and_opened_again() {
    let (h, ui) = detail_page();
    set_feed(&h, &ui, thirty_rows("Bash first"), false);
    scroll_feed_up(&h);
    ui.set_page(claude_board_ui::Page::List);
    h.render(); // a frame is drawn between the two taps, which is what removes the detail page
    ui.set_page(claude_board_ui::Page::Detail);
    for _ in 0..4 {
        h.step(33);
    }
    assert!(feed_ink(&h.render()).1 > 3, "the reopened page kept the old scroll position");
}

#[test]
fn expanded_overlay_covers_the_feed() {
    use claude_board_ui::FeedKind::Tool;
    let (h, ui) = detail_page();
    set_feed(&h, &ui, vec![feed_row(Tool, "Bash cargo test", true)], false);
    assert!(feed_ink(&h.render()).1 > 3);
    ui.set_expanded_text("the full text of the entry".into());
    h.step(33);
    let buf = h.render();
    assert_eq!(feed_ink(&buf).1, 0, "feed row still visible under the overlay");
    // The overlay's text starts higher than the feed does, over where the header was.
    let top = (60..164).flat_map(|y| (83..383).map(move |x| (x, y))).filter(|&(x, y)| px(&buf, x, y) != (0, 0, 0)).count();
    assert!(top > 50, "no overlay text");
}

#[test]
fn expanded_overlay_scrolls_by_drag_and_closes_by_tap() {
    use slint::platform::{PointerEventButton, WindowEvent};
    use slint::LogicalPosition;
    use std::cell::Cell;
    use std::rc::Rc;
    let (h, ui) = detail_page();
    let closed = Rc::new(Cell::new(0));
    let c = closed.clone();
    ui.on_expanded_closed(move || c.set(c.get() + 1));
    let long = (0..40).map(|i| format!("line number {i}")).collect::<Vec<_>>().join("\n");
    ui.set_expanded_text(long.into());
    h.step(33);
    let before = h.render().to_vec();
    drag_y(&h, 300., 150.);
    let after = h.render().to_vec();
    assert_ne!(before, after, "dragging did not scroll the overlay");
    assert_eq!(closed.get(), 0, "a drag closed the overlay");
    let at = |x: f32, y: f32| LogicalPosition::new(x, y);
    let w = &h.window;
    w.dispatch_event(WindowEvent::PointerPressed { position: at(233., 300.), button: PointerEventButton::Left });
    w.dispatch_event(WindowEvent::PointerReleased { position: at(233., 300.), button: PointerEventButton::Left });
    w.dispatch_event(WindowEvent::PointerExited);
    assert_eq!(closed.get(), 1, "a tap did not close the overlay");
}

// ---- Voice: presence moods and the reply card ----

/// Pixels in the 466 x 466 frame that are not (nearly) the background.
fn lit(buf: &[Rgb565Pixel], xs: std::ops::Range<usize>, ys: std::ops::Range<usize>) -> usize {
    ys.flat_map(|y| xs.clone().map(move |x| (x, y))).filter(|&(x, y)| !near(px(buf, x, y), (0, 0, 0), 24)).count()
}

#[test]
fn listening_thinking_and_speaking_each_draw_their_own_colour_at_the_core() {
    let (h, ui) = show();
    let mut centres = Vec::new();
    for state in [PresenceState::Listening, PresenceState::Thinking, PresenceState::Speaking] {
        ui.set_presence_state(state);
        let buf = h.render();
        centres.push(px(&buf, 233, 233));
    }
    assert!(centres[0].1 > centres[0].2, "listening is green: {:?}", centres[0]);
    assert!(centres[1].2 > centres[1].0 + 60, "thinking is blue: {:?}", centres[1]);
    assert!(centres[2].0 > 150 && centres[2].1 > 150 && centres[2].2 > 200, "speaking is pale: {:?}", centres[2]);
}

#[test]
fn the_reply_card_draws_under_the_avatar_and_takes_the_summarys_place() {
    let (h, ui) = show();
    ui.set_summary("All quiet".into());
    let before = h.render();
    let summary_ink = lit(&before, 100..366, 352..380);
    assert!(summary_ink > 50, "the summary is drawn when there is no reply ({summary_ink})");
    ui.set_reply_heading("what is on my calendar".into());
    ui.set_reply_text("You have a dentist appointment at three. Nothing else is on today.".into());
    let after = h.render();
    // The card's body is lit, and its corners stay inside the round screen.
    assert!(lit(&after, 100..366, 340..400) > 2000, "the card body is drawn");
    for (x, y) in [(110usize, 402usize), (355, 402), (110, 310), (355, 310)] {
        let (dx, dy) = (x as f32 - 233.0, y as f32 - 233.0);
        assert!((dx * dx + dy * dy).sqrt() < 210.0, "card corner ({x}, {y}) is on the rim");
    }
    ui.set_reply_text("".into());
    assert!(lit(&h.render(), 100..366, 352..380) > 50, "the summary is back once the card is gone");
}
