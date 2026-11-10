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

/// Non-black pixels in the question's text box (away from the rim and the buttons) for `texts`, one
/// render each on a single window.
fn question_ink(texts: &[&str]) -> Vec<usize> {
    let (h, ui) = show();
    ui.set_page(claude_board_ui::Page::Question);
    texts
        .iter()
        .map(|t| {
            ui.set_question_text((*t).into());
            let buf = h.render();
            (72..178).flat_map(|y| (83..383).map(move |x| (x, y))).filter(|&(x, y)| px(&buf, x, y) != (0, 0, 0)).count()
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
