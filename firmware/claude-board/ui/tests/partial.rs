//! Renders the way the board does (`app/src/platform.rs`): one reused framebuffer, `frame::paint`, and only what
//! Slint marks dirty. The headless helper renders whole frames into a new buffer, so it cannot see a bug in that
//! path; this test caught `render_by_line` dropping every `Path`.

use std::rc::Rc;

use claude_board_ui::frame::paint;
use claude_board_ui::headless::rgb;
use claude_board_ui::rim::arc_segment;
use claude_board_ui::view::command_segments;
use claude_board_ui::{AppWindow, SessionState};
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
    let icon = rgb(px[89 * W + 90]);
    let band = rgb(px[40 * W + 200]);
    assert!(icon.0 > 180 && icon.1 < 90, "the volume icon is painted: {icon:?}");
    assert!(band != (0, 0, 0), "the link arc's band is painted: {band:?}");

    assert_eq!(draw(&window, &mut px), None, "nothing changed, nothing pushed");
}
