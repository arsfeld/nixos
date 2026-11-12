//! Renders the way the board does (`app/src/platform.rs`): one reused framebuffer, `frame::paint`, and only what
//! Slint marks dirty. The headless helper renders whole frames into a new buffer, so it cannot see a bug in that
//! path; this test caught `render_by_line` dropping every `Path`.

use std::rc::Rc;

use cylon_bot_ui::frame::paint;
use cylon_bot_ui::headless::rgb;
use cylon_bot_ui::rim::arc_segment;
use cylon_bot_ui::view::command_segments;
use cylon_bot_ui::{AppWindow, SessionState};
use slint::platform::software_renderer::{MinimalSoftwareWindow, RepaintBufferType, Rgb565Pixel};
use slint::platform::{Platform, WindowAdapter};
use slint::{ComponentHandle, ModelRc, VecModel};

const W: usize = 466;

struct Plat(Rc<MinimalSoftwareWindow>);
impl Platform for Plat {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.0.clone())
    }
}

/// One pass of the board's draw loop; returns the rows it would push.
fn draw(window: &MinimalSoftwareWindow, px: &mut [Rgb565Pixel]) -> Option<(usize, usize)> {
    slint::platform::update_timers_and_animations();
    let mut rows = None;
    window.draw_if_needed(|r| rows = paint(r, px, W, W));
    rows
}

fn rim_point(deg: f32) -> usize {
    let (x, y) = (233.0 + 220.0 * deg.to_radians().sin(), 233.0 - 220.0 * deg.to_radians().cos());
    y as usize * W + x as usize
}

#[test]
fn the_board_draw_loop_paints_paths_and_pushes_their_rows() {
    let window = MinimalSoftwareWindow::new(RepaintBufferType::ReusedBuffer);
    slint::platform::set_platform(Box::new(Plat(window.clone()))).unwrap();
    window.set_size(slint::PhysicalSize::new(W as u32, W as u32));
    let ui = AppWindow::new().unwrap();
    ui.set_commands(ModelRc::new(VecModel::from(command_segments())));
    ui.set_rim(ModelRc::new(VecModel::from(vec![arc_segment(200.0, 260.0, SessionState::Working)])));
    ui.set_link(true);
    ui.show().unwrap();
    let mut px = vec![Rgb565Pixel(0); W * W];

    assert_eq!(draw(&window, &mut px), Some((0, W)), "the first frame pushes the whole panel");
    let rim = rgb(px[rim_point(230.0)]);
    assert!(rim.2 > 200 && rim.0 < 120, "a session arc (a Path) is painted: {rim:?}");

    // Opening the menu repaints its band only, with its arcs and icons in it.
    ui.set_menu_open(true);
    let (y0, y1) = draw(&window, &mut px).expect("opening the menu repaints something");
    assert!(y0 <= 20 && y1 >= 100 && y1 < W, "pushed rows {y0}..{y1} cover the menu and not the whole panel");
    assert_eq!((y0 % 2, y1 % 2), (0, 0), "the panel takes even rows");
    let icon = rgb(px[103 * W + 78]);
    let band = rgb(px[40 * W + 200]);
    assert!(icon.0 > 180 && icon.1 < 90, "the volume icon is painted: {icon:?}");
    assert!(band != (0, 0, 0), "the link arc's band is painted: {band:?}");

    assert_eq!(draw(&window, &mut px), None, "nothing changed, nothing pushed");
}

/// A frame's repaint must leave the buffer exactly as a full render of the same scene would. Slint 1.18.1 blended a
/// Path over its whole clip rather than the dirty region, so a session arc changing beside the Volume arc repainted
/// that arc over its icon and label, which the frame did not redraw: on the board the menu icons vanished next to a
/// pulsing arc. Fixed by the local patch in patches/ (scripts/vendor-slint.sh).
#[test]
fn a_repaint_beside_the_menu_leaves_what_a_full_render_draws() {
    let window = MinimalSoftwareWindow::new(RepaintBufferType::ReusedBuffer);
    let _ = slint::platform::set_platform(Box::new(Plat(window.clone())));
    window.set_size(slint::PhysicalSize::new(W as u32, W as u32));
    let ui = AppWindow::new().unwrap();
    ui.set_commands(ModelRc::new(VecModel::from(command_segments())));
    ui.set_link(true);
    ui.set_menu_open(true);
    // An arc at 270..300 degrees: its box reaches into the Volume arc's (and its stroke-grown Path's) box.
    let beside = |state| ModelRc::new(VecModel::from(vec![arc_segment(270.0, 300.0, state)]));
    ui.set_rim(beside(SessionState::Working));
    ui.show().unwrap();
    let mut px = vec![Rgb565Pixel(0); W * W];
    draw(&window, &mut px);
    ui.set_rim(beside(SessionState::Done));
    let (y0, y1) = draw(&window, &mut px).expect("the arc changed");
    assert!(y1 - y0 < W / 2, "a partial repaint, rows {y0}..{y1}");

    window.request_redraw();
    let mut fresh = vec![Rgb565Pixel(0); W * W];
    window.draw_if_needed(|r| {
        r.set_repaint_buffer_type(RepaintBufferType::NewBuffer);
        r.render(&mut fresh, W);
    });
    let diff: Vec<(usize, usize)> = (0..W * W).filter(|&i| px[i].0 != fresh[i].0).map(|i| (i % W, i / W)).collect();
    assert!(diff.is_empty(), "{} pixels differ from a full render, e.g. {:?}", diff.len(), &diff[..diff.len().min(8)]);
}
