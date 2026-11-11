//! Headless renders of the real Slint scene, checked pixel by pixel. They run the same software
//! renderer the board uses, so what passes here is what the panel draws.

use cylon_bot_ui::headless::{headless, rgb, Headless};
use cylon_bot_ui::rim::arc_segment;
use cylon_bot_ui::theme;
use cylon_bot_ui::{AppWindow, PresenceState, RimSegment, SessionState};
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

// ---- The avatar: a Centurion head whose red eye sweeps the visor ----

/// The visor slot on screen: the avatar sits at (93, 93) and the slot is x 74..206, y 123..145 in it.
const VISOR_X: std::ops::Range<usize> = 167..299;
const VISOR_Y: std::ops::Range<usize> = 216..238;

fn is_red((r, g, b): (u8, u8, u8)) -> bool {
    r > 120 && (g as i32) < r as i32 / 2 && (b as i32) < r as i32 / 2
}

/// Red pixels in a box, and the mean x of them (None when there are none).
fn red_in(buf: &[Rgb565Pixel], xs: std::ops::Range<usize>, ys: std::ops::Range<usize>) -> (usize, Option<f32>) {
    let pts: Vec<usize> = ys.flat_map(|y| xs.clone().map(move |x| (x, y))).filter(|&(x, y)| is_red(px(buf, x, y))).map(|(x, _)| x).collect();
    let n = pts.len();
    (n, (n > 0).then(|| pts.iter().sum::<usize>() as f32 / n as f32))
}

/// The brightest red channel in the visor.
fn visor_peak(buf: &[Rgb565Pixel]) -> u8 {
    VISOR_Y.flat_map(|y| VISOR_X.map(move |x| (x, y))).map(|(x, y)| px(buf, x, y)).filter(|&c| is_red(c)).map(|c| c.0).max().unwrap_or(0)
}

#[test]
fn every_mood_draws_a_red_eye_in_the_visor() {
    let (h, ui) = show();
    for state in [PresenceState::Idle, PresenceState::Listening, PresenceState::Thinking, PresenceState::Speaking, PresenceState::Alert] {
        ui.set_presence_state(state);
        h.step(100);
        let (n, _) = red_in(&h.render(), VISOR_X, VISOR_Y);
        assert!(n > 40, "{state:?}: only {n} red pixels in the visor");
    }
}

#[test]
fn the_head_is_drawn_around_the_visor() {
    let (h, ui) = show();
    ui.set_presence_state(PresenceState::Idle);
    let buf = h.render();
    assert!(lit(&buf, 160..306, 140..210) > 6000, "the dome is drawn above the visor");
    assert!(lit(&buf, 180..286, 262..322) > 3000, "the grille is drawn below the visor");
    assert!(lit(&buf, 100..366, 345..380) == 0, "the chin clears the summary line");
}

#[test]
fn the_eye_sweeps_while_idle_and_faster_while_thinking() {
    let (h, ui) = show();
    let travel = |state: PresenceState| {
        ui.set_presence_state(state);
        let mut xs = Vec::new();
        for _ in 0..12 {
            h.step(100);
            xs.push(red_in(&h.render(), VISOR_X, VISOR_Y).1.unwrap());
        }
        xs.windows(2).map(|w| (w[1] - w[0]).abs()).sum::<f32>()
    };
    let idle = travel(PresenceState::Idle);
    let thinking = travel(PresenceState::Thinking);
    assert!(idle > 20.0, "the idle eye moves ({idle} px)");
    assert!(thinking > idle * 1.5, "thinking sweeps faster ({thinking} px against {idle} px idle)");
}

#[test]
fn the_eye_holds_still_in_the_centre_while_listening_and_grows_with_the_level() {
    let (h, ui) = show();
    ui.set_presence_state(PresenceState::Listening);
    ui.set_presence_level(0.0);
    let mut quiet = 0;
    for _ in 0..6 {
        h.step(100);
        let (n, x) = red_in(&h.render(), VISOR_X, VISOR_Y);
        assert!((x.unwrap() - 233.0).abs() < 6.0, "the listening eye is centred, at {x:?}");
        quiet = quiet.max(n);
    }
    ui.set_presence_level(1.0);
    h.step(100);
    let (loud, _) = red_in(&h.render(), VISOR_X, VISOR_Y);
    assert!(loud > quiet, "a loud voice grows the eye ({loud} red pixels against {quiet})");
}

#[test]
fn alert_lights_more_of_the_visor_than_idle() {
    let (h, ui) = show();
    ui.set_presence_state(PresenceState::Idle);
    h.step(100);
    let (idle, _) = red_in(&h.render(), VISOR_X, VISOR_Y);
    ui.set_presence_state(PresenceState::Alert);
    let alert = (0..10).map(|_| { h.step(50); red_in(&h.render(), VISOR_X, VISOR_Y).0 }).max().unwrap();
    assert!(alert > idle * 2, "alert flashes the visor ({alert} red pixels against {idle})");
}

#[test]
fn offline_dims_the_eye_and_parks_it() {
    let (h, ui) = show();
    ui.set_presence_state(PresenceState::Idle);
    h.step(100);
    let lit_peak = visor_peak(&h.render());
    ui.set_voice_available(false);
    let mut xs = Vec::new();
    for _ in 0..5 {
        h.step(200);
        let buf = h.render();
        assert!(visor_peak(&buf) + 60 < lit_peak, "offline is dimmer ({} against {lit_peak})", visor_peak(&buf));
        xs.push(red_in(&buf, 0..W, 0..W).1.unwrap_or(233.0));
    }
    assert!(xs.iter().all(|x| (x - 233.0).abs() < 6.0), "the offline eye is parked in the centre: {xs:?}");
}

#[test]
fn nothing_red_is_drawn_outside_the_head() {
    let (h, ui) = show();
    for state in [PresenceState::Alert, PresenceState::Thinking, PresenceState::Speaking] {
        ui.set_presence_state(state);
        ui.set_presence_level(1.0);
        for _ in 0..5 {
            h.step(70);
            let buf = h.render();
            let (all, _) = red_in(&buf, 0..W, 0..W);
            let (inside, _) = red_in(&buf, 93..373, 93..373);
            assert_eq!(all, inside, "{state:?} draws red outside the avatar box");
        }
    }
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
    let t = cylon_bot_ui::Theme::get(&ui);
    let c = |col: slint::Color| (col.red(), col.green(), col.blue());
    assert_eq!(c(t.get_waiting()), theme::WAITING);
    assert_eq!(c(t.get_working()), theme::WORKING);
    assert_eq!(c(t.get_error()), theme::ERROR);
}

/// Non-black pixels in the question's text box (away from the rim and the wheel) for `texts`, one
/// render each on a single window.
fn question_ink(texts: &[&str]) -> Vec<usize> {
    let (h, ui) = show();
    ui.set_page(cylon_bot_ui::Page::Question);
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

fn feed_row(kind: cylon_bot_ui::FeedKind, text: &str, failed: bool) -> cylon_bot_ui::FeedRow {
    cylon_bot_ui::FeedRow { kind, text: text.into(), failed }
}

fn detail_page() -> (Headless, AppWindow) {
    let (h, ui) = show();
    ui.set_page(cylon_bot_ui::Page::Detail);
    ui.set_detail_host("raider".into());
    ui.set_detail_project("nixos".into());
    (h, ui)
}

fn set_feed(h: &Headless, ui: &AppWindow, rows: Vec<cylon_bot_ui::FeedRow>, empty: bool) {
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
    use cylon_bot_ui::FeedKind::Tool;
    let (h, ui) = detail_page();
    set_feed(&h, &ui, vec![feed_row(Tool, "Bash cargo test", true)], false);
    assert!(feed_ink(&h.render()).1 > 3, "no error-coloured marker");
    set_feed(&h, &ui, vec![feed_row(Tool, "Bash cargo test", false)], false);
    assert_eq!(feed_ink(&h.render()).1, 0);
}

#[test]
fn feed_follows_the_newest_row() {
    use cylon_bot_ui::FeedKind::{Prompt, Tool};
    let mut rows: Vec<_> = (0..29).map(|i| feed_row(Prompt, &format!("prompt number {i}"), false)).collect();
    rows.push(feed_row(Tool, "Bash last", true));
    let (h, ui) = detail_page();
    set_feed(&h, &ui, rows, false);
    assert!(feed_ink(&h.render()).1 > 3, "the newest (failed) row is not in view");
}

/// 30 rows whose newest is a failed tool row, so the red marker is in view exactly when the newest row is.
fn thirty_rows(newest: &str) -> Vec<cylon_bot_ui::FeedRow> {
    use cylon_bot_ui::FeedKind::{Prompt, Tool};
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
    more.push(feed_row(cylon_bot_ui::FeedKind::Reply, "a new reply", false));
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
    ui.set_page(cylon_bot_ui::Page::Detail);
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
    ui.set_page(cylon_bot_ui::Page::List);
    h.render(); // a frame is drawn between the two taps, which is what removes the detail page
    ui.set_page(cylon_bot_ui::Page::Detail);
    for _ in 0..4 {
        h.step(33);
    }
    assert!(feed_ink(&h.render()).1 > 3, "the reopened page kept the old scroll position");
}

#[test]
fn expanded_overlay_covers_the_feed() {
    use cylon_bot_ui::FeedKind::Tool;
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

#[test]
fn reminder_card_renders_over_home() {
    use cylon_bot_ui::controller::{Controller, Outbox};
    struct Mute;
    impl Outbox for Mute {
        fn send(&self, _: String) -> bool {
            true
        }
    }
    let (h, ui) = show();
    let c = Controller::new(&ui, Mute);
    c.tick(Some(1_800_000_000));
    let before = h.render();
    c.on_message(r#"{"t":"reminder","id":"tmr_01","label":"check the oven","due":"2026-11-10T18:42:00-05:00"}"#);
    let after = h.render();
    assert!(lit(&after, 100..366, 340..400) > lit(&before, 100..366, 340..400) + 1500, "the reminder card is drawn");
    ui.invoke_reply_tapped();
    assert!(lit(&h.render(), 100..366, 340..400) < lit(&after, 100..366, 340..400), "tapping it takes the card away");
}

#[test]
fn the_command_menu_draws_metal_arcs_with_a_red_purge_edge_only_while_open() {
    let (h, ui) = show();
    ui.set_commands(ModelRc::new(VecModel::from(cylon_bot_ui::view::command_segments())));
    ui.set_link(true);
    // Points on the Link arc (12 degrees right of the top) and on Purge's outer edge (44 degrees).
    let at = |deg: f32, r: f32| {
        let a = deg.to_radians();
        ((233.0 + r * a.sin()).round() as usize, (233.0 - r * a.cos()).round() as usize)
    };
    let (fill, edge, purge_edge) = (at(12.0, 200.0), at(12.0, 224.0), at(44.0, 224.0));
    let buf = h.render();
    assert_eq!(px(&buf, fill.0, fill.1), (0, 0, 0), "closed: nothing there");
    ui.set_menu_open(true);
    let buf = h.render();
    assert!(near(px(&buf, fill.0, fill.1), (0x15, 0x17, 0x1c), 10), "{:?}", px(&buf, fill.0, fill.1));
    assert!(near(px(&buf, edge.0, edge.1), (0x5b, 0x60, 0x6b), 10), "{:?}", px(&buf, edge.0, edge.1));
    let lit = px(&buf, purge_edge.0, purge_edge.1);
    assert!(is_red(lit), "{lit:?}");
    ui.set_link(false);
    let buf = h.render();
    let dim = px(&buf, purge_edge.0, purge_edge.1);
    assert!(dim.0 < lit.0 / 2, "offline, purge is dimmed: {dim:?} against {lit:?}");
}

// ---- The purge page: hold the button for 1.5 s ----

mod purge {
    use super::*;
    use cylon_bot_ui::controller::{Controller, Outbox};
    use cylon_bot_ui::touch::{Gesture, TouchTracker};
    use cylon_bot_ui::Page;
    use std::cell::RefCell;
    use std::rc::Rc;

    #[derive(Clone, Default)]
    struct Wire(Rc<RefCell<Vec<String>>>);
    impl Outbox for Wire {
        fn send(&self, json: String) -> bool {
            self.0.borrow_mut().push(json);
            true
        }
    }
    impl Wire {
        fn new_sessions(&self) -> usize {
            self.0.borrow().iter().filter(|s| s.contains(r#""t":"new_session""#)).count()
        }
    }

    /// The HOLD button's centre.
    const BUTTON: (i16, i16) = (233, 363);

    struct Board {
        h: Headless,
        ui: AppWindow,
        c: Controller<Wire>,
        wire: Wire,
        touch: TouchTracker,
        ms: u64,
    }

    impl Board {
        fn on_purge() -> Board {
            let (h, ui) = show();
            let wire = Wire::default();
            let c = Controller::new(&ui, wire.clone());
            c.set_link(true);
            c.open_menu();
            ui.invoke_rim_tapped(44.0);
            assert_eq!(ui.get_page(), Page::Purge);
            h.render();
            Board { h, ui, c, wire, touch: TouchTracker::new(), ms: 0 }
        }

        /// One touch sample through the tracker and the controller, as the app runs them.
        fn sample(&mut self, pressed: bool) {
            let (x, y) = BUTTON;
            let u = self.touch.update_at(x, y, pressed, self.ms);
            for e in u.events {
                self.h.window.dispatch_event(e);
            }
            if let Some(Gesture::HoldStart(x, y)) = u.gesture {
                if self.c.hold_started(x, y) {
                    for e in self.touch.accept_hold() {
                        self.h.window.dispatch_event(e);
                    }
                }
            }
        }

        /// Keep the finger on the button for `ms`, sampling every 33 ms.
        fn hold_for(&mut self, ms: u64) {
            self.sample(true);
            let end = self.ms + ms;
            while self.ms < end {
                self.ms += 33;
                self.h.step(33);
                self.sample(true);
            }
        }

        fn release(&mut self) {
            self.sample(false);
            self.ms += 33;
            self.h.step(33);
        }

        /// Red ticks on the ring.
        fn red_ticks(&self) -> usize {
            let buf = self.h.render();
            (0..36)
                .filter(|i| {
                    let a = (*i as f32 * 10.0).to_radians();
                    let (x, y) = ((233.0 + 211.0 * a.sin()).round() as usize, (233.0 - 211.0 * a.cos()).round() as usize);
                    is_red(px(&buf, x, y)) || near(px(&buf, x, y), (0xff, 0xb4, 0xa0), 24)
                })
                .count()
        }
    }

    #[test]
    fn holding_purge_for_1_5_s_confirms() {
        let mut b = Board::on_purge();
        assert_eq!(b.red_ticks(), 0, "the ring starts empty");
        b.hold_for(990);
        let filling = b.red_ticks();
        assert!((20..=27).contains(&filling), "two thirds of the way the ring is two thirds lit: {filling}");
        assert_eq!(b.wire.new_sessions(), 0);
        b.hold_for(560);
        assert_eq!(b.wire.new_sessions(), 1, "a hold off the avatar is not taken: the button stays pressed");
        assert_eq!(b.ui.get_page(), Page::Home);
        b.release();
        assert_eq!(b.wire.new_sessions(), 1, "once");
        assert_eq!(b.ui.get_page(), Page::Home, "the lift on home is not a tap on the avatar");
    }

    #[test]
    fn releasing_purge_early_restarts_the_ring() {
        let mut b = Board::on_purge();
        b.hold_for(1400);
        b.release();
        assert_eq!(b.red_ticks(), 0, "letting go empties the ring");
        b.hold_for(1400);
        assert_eq!(b.wire.new_sessions(), 0, "1.4 s twice is not 1.5 s");
        b.release();
        b.hold_for(1550);
        assert_eq!(b.wire.new_sessions(), 1);
    }

    #[test]
    fn the_purge_button_is_inert_while_a_purge_is_pending() {
        let mut b = Board::on_purge();
        b.hold_for(1550);
        b.release();
        assert_eq!(b.wire.new_sessions(), 1);
        // Back to the page before the bridge has answered.
        b.c.open_menu();
        b.ui.invoke_rim_tapped(44.0);
        assert_eq!(b.ui.get_page(), Page::Purge);
        b.hold_for(2000);
        assert_eq!(b.red_ticks(), 0, "the button does nothing");
        assert_eq!(b.wire.new_sessions(), 1);
        b.release();
        // The bridge answers: the button works again.
        b.c.on_message(r#"{"t":"session_reset","utterance":1}"#);
        b.hold_for(1550);
        assert_eq!(b.wire.new_sessions(), 2);
    }

    #[test]
    fn the_purge_button_is_inert_while_unlinked() {
        let mut b = Board::on_purge();
        b.c.set_link(false);
        b.hold_for(2000);
        assert_eq!(b.red_ticks(), 0);
        assert_eq!(b.wire.new_sessions(), 0);
    }
}

// ---- The volume page ----

#[test]
fn the_volume_page_lights_ticks_up_to_the_level() {
    use cylon_bot_ui::controller::{Controller, Outbox};
    struct Mute;
    impl Outbox for Mute {
        fn send(&self, _: String) -> bool {
            true
        }
    }
    let (h, ui) = show();
    let _c = Controller::new(&ui, Mute);
    ui.set_page(cylon_bot_ui::Page::Volume);
    let lit_ticks = |buf: &[Rgb565Pixel]| {
        (0..24)
            .filter(|i| {
                let a = (-120.0 + 240.0 * *i as f32 / 23.0f32).to_radians();
                let (x, y) = ((233.0 + 208.0 * a.sin()).round() as usize, (233.0 - 208.0 * a.cos()).round() as usize);
                let c = px(buf, x, y);
                is_red(c) || near(c, (0xff, 0xb4, 0xa0), 24)
            })
            .count()
    };
    ui.set_volume(50);
    assert_eq!(lit_ticks(&h.render()), 12);
    ui.set_volume(100);
    assert_eq!(lit_ticks(&h.render()), 24);
    ui.set_volume(10);
    let buf = h.render();
    assert_eq!(lit_ticks(&buf), 2);
    // The last lit tick is the bright one.
    let a = (-120.0 + 240.0 / 23.0f32).to_radians();
    let tip = px(&buf, (233.0 + 208.0 * a.sin()).round() as usize, (233.0 - 208.0 * a.cos()).round() as usize);
    assert!(near(tip, (0xff, 0xb4, 0xa0), 24), "{tip:?}");
}

#[test]
fn the_volume_buttons_step_through_real_taps() {
    use cylon_bot_ui::controller::{Controller, Outbox};
    struct Mute;
    impl Outbox for Mute {
        fn send(&self, _: String) -> bool {
            true
        }
    }
    use slint::platform::{PointerEventButton, WindowEvent};
    use slint::LogicalPosition;
    let (h, ui) = show();
    let c = Controller::new(&ui, Mute);
    ui.set_page(cylon_bot_ui::Page::Volume);
    h.render();
    let tap = |x: f32, y: f32| {
        let position = LogicalPosition::new(x, y);
        h.window.dispatch_event(WindowEvent::PointerPressed { position, button: PointerEventButton::Left });
        h.window.dispatch_event(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
        h.window.dispatch_event(WindowEvent::PointerExited);
    };
    tap(144.0, 350.0);
    assert_eq!(c.take_volume_step(), Some(false));
    tap(322.0, 350.0);
    assert_eq!(c.take_volume_step(), Some(true));
}

#[test]
fn the_volume_pill_on_home_is_a_row_of_red_ticks() {
    let (h, ui) = show();
    ui.set_volume(70);
    ui.set_volume_shown(true);
    let buf = h.render();
    // Ten ticks, 9 px apart, from x 219 (the pill at 143 plus 76), centred on y 64.
    let lit: Vec<bool> = (0..10)
        .map(|i| {
            let c = px(&buf, 219 + 9 * i + 2, 64);
            is_red(c) || near(c, (0xff, 0xb4, 0xa0), 24)
        })
        .collect();
    assert_eq!(lit, [true, true, true, true, true, true, true, false, false, false]);
    assert!(near(px(&buf, 219 + 9 * 6 + 2, 64), (0xff, 0xb4, 0xa0), 24), "the last lit tick is the bright one");
}

#[test]
fn the_link_page_lights_its_arcs_from_the_inside_and_colours_the_bridge() {
    use cylon_bot_ui::LinkInfo;
    let (h, ui) = show();
    ui.set_page(cylon_bot_ui::Page::Link);
    let info = |rssi: i32| LinkInfo {
        rssi,
        bars: cylon_bot_ui::view::signal_bars(rssi),
        ssid: "net".into(),
        address: "10.0.0.2".into(),
        uptime: "7m".into(),
    };
    // The top of each arc, outermost first (the mockup's geometry in link.slint).
    let lit = |buf: &[Rgb565Pixel]| [100, 123, 146, 168].map(|y| is_red(px(buf, 233, y)));
    ui.set_link_info(info(-70));
    assert_eq!(lit(&h.render()), [false, false, true, true]);
    ui.set_link_info(info(-50));
    assert_eq!(lit(&h.render()), [true, true, true, true]);
    // Not associated: the app sends rssi 0 with no bars.
    ui.set_link_info(LinkInfo { bars: 0, ..info(0) });
    assert_eq!(lit(&h.render()), [false, false, false, false]);
    // BRIDGE's value (x 198.., y 316..338) is green while linked, grey while not.
    let green = |buf: &[Rgb565Pixel]| (198..260).flat_map(|x| (316..338).map(move |y| (x, y))).any(|(x, y)| {
        let (r, g, b) = px(buf, x, y);
        g > 150 && r < 100 && b < 140
    });
    ui.set_link(true);
    assert!(green(&h.render()));
    ui.set_link(false);
    assert!(!green(&h.render()));
    // VOICE's value (y 342..364) goes through the bridge: never green while it is down, whatever the mood says.
    let voice_green = |buf: &[Rgb565Pixel]| (198..260).flat_map(|x| (342..364).map(move |y| (x, y))).any(|(x, y)| {
        let (r, g, b) = px(buf, x, y);
        g > 150 && r < 100 && b < 140
    });
    ui.set_voice_available(true);
    assert!(!voice_green(&h.render()), "bridge down: VOICE is offline");
    ui.set_link(true);
    assert!(voice_green(&h.render()), "bridge up with a voice: VOICE is online");
    ui.set_voice_available(false);
    assert!(!voice_green(&h.render()));
}
