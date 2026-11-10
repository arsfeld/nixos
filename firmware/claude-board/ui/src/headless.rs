//! Renders the real scene without a display: the same software renderer the firmware uses, a clock the
//! test controls, and full-frame RGB565 output. Used by the tests and the preview tool.

use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use slint::platform::software_renderer::{MinimalSoftwareWindow, RepaintBufferType, Rgb565Pixel};
use slint::platform::{Platform, WindowAdapter};

pub const WIDTH: usize = 466;
pub const HEIGHT: usize = 466;

struct HeadlessPlatform {
    window: Rc<MinimalSoftwareWindow>,
    clock: Rc<Cell<Duration>>,
}

impl Platform for HeadlessPlatform {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.window.clone())
    }
    fn duration_since_start(&self) -> Duration {
        self.clock.get()
    }
}

pub struct Headless {
    pub window: Rc<MinimalSoftwareWindow>,
    clock: Rc<Cell<Duration>>,
}

/// Install a headless platform for this thread (Slint keeps its platform per thread, so every test gets
/// its own) and size its window to the panel. Call before creating a component.
pub fn headless() -> Headless {
    let window = MinimalSoftwareWindow::new(RepaintBufferType::NewBuffer);
    let clock = Rc::new(Cell::new(Duration::ZERO));
    slint::platform::set_platform(Box::new(HeadlessPlatform { window: window.clone(), clock: clock.clone() }))
        .expect("one headless platform per thread");
    window.set_size(slint::PhysicalSize::new(WIDTH as u32, HEIGHT as u32));
    Headless { window, clock }
}

impl Headless {
    /// Move the clock on by `ms` and run timers and animations up to it.
    pub fn step(&self, ms: u64) {
        self.clock.set(self.clock.get() + Duration::from_millis(ms));
        slint::platform::update_timers_and_animations();
    }

    /// Render the whole window.
    pub fn render(&self) -> Vec<Rgb565Pixel> {
        slint::platform::update_timers_and_animations();
        self.window.request_redraw();
        let mut buf = vec![Rgb565Pixel(0); WIDTH * HEIGHT];
        self.window.draw_if_needed(|renderer| {
            renderer.render(&mut buf, WIDTH);
        });
        buf
    }
}

/// The 8-bit RGB of an RGB565 pixel.
pub fn rgb(p: Rgb565Pixel) -> (u8, u8, u8) {
    let (r, g, b) = ((p.0 >> 11) & 31, (p.0 >> 5) & 63, p.0 & 31);
    ((r << 3 | r >> 2) as u8, (g << 2 | g >> 4) as u8, (b << 3 | b >> 2) as u8)
}
