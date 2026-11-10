//! Slint's software renderer on the panel: a persistent RGB565 framebuffer in PSRAM that Slint paints
//! line by line, the dirty rows pushed through `display::Strips`, and the touch controller turned into
//! pointer events.

use std::ops::Range;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use slint::platform::software_renderer::{LineBufferProvider, MinimalSoftwareWindow, RepaintBufferType, Rgb565Pixel};
use slint::platform::{Platform, PointerEventButton, WindowAdapter, WindowEvent};
use slint::LogicalPosition;

use crate::display::{self, Strips, HEIGHT, WIDTH};

/// Set whenever a finger touches the glass; the app reads it to wake the screen.
static TOUCHED: AtomicBool = AtomicBool::new(false);

/// True once after the screen was touched.
pub fn take_touch() -> bool {
    TOUCHED.swap(false, Ordering::SeqCst)
}

struct Plat {
    window: Rc<MinimalSoftwareWindow>,
    start: Instant,
}

impl Platform for Plat {
    fn create_window_adapter(&self) -> Result<Rc<dyn WindowAdapter>, slint::PlatformError> {
        Ok(self.window.clone())
    }
    fn duration_since_start(&self) -> Duration {
        self.start.elapsed()
    }
}

/// Install the platform and return the window every component will be shown in. Call once, first.
pub fn install() -> anyhow::Result<Rc<MinimalSoftwareWindow>> {
    let window = MinimalSoftwareWindow::new(RepaintBufferType::ReusedBuffer);
    slint::platform::set_platform(Box::new(Plat { window: window.clone(), start: Instant::now() }))
        .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    window.set_size(slint::PhysicalSize::new(WIDTH as u32, HEIGHT as u32));
    Ok(window)
}

/// Paints into the framebuffer and remembers which rows it touched.
struct Frame<'a> {
    px: &'a mut [Rgb565Pixel],
    first: usize,
    last: usize,
}

impl LineBufferProvider for &mut Frame<'_> {
    type TargetPixel = Rgb565Pixel;
    fn process_line(&mut self, line: usize, range: Range<usize>, render_fn: impl FnOnce(&mut [Rgb565Pixel])) {
        render_fn(&mut self.px[line * WIDTH + range.start..line * WIDTH + range.end]);
        self.first = self.first.min(line);
        self.last = self.last.max(line);
    }
}

/// Draw whatever changed and handle the touch screen, forever. `each_loop` runs once per pass (a few
/// hundred times a second at most) for the app's own timers and message handling.
pub fn run(window: &Rc<MinimalSoftwareWindow>, mut each_loop: impl FnMut()) -> anyhow::Result<()> {
    let mut pixels = vec![Rgb565Pixel(0); WIDTH * HEIGHT]; // PSRAM
    let mut frame = Frame { px: &mut pixels, first: usize::MAX, last: 0 };
    let mut strips = Strips::new()?;
    let (mut was_pressed, mut last_touch) = (false, Instant::now());

    loop {
        slint::platform::update_timers_and_animations();
        each_loop();

        window.draw_if_needed(|renderer| {
            frame.first = usize::MAX;
            frame.last = 0;
            renderer.render_by_line(&mut frame);
            if frame.first != usize::MAX {
                // The panel takes windows with an even origin and size.
                let (y0, y1) = (frame.first & !1, ((frame.last | 1) + 1).min(HEIGHT));
                strips.push(frame.px, y0, y1);
            }
        });

        if last_touch.elapsed() >= Duration::from_millis(20) {
            last_touch = Instant::now();
            if let Some(t) = display::touch() {
                let position = LogicalPosition::new(t.x as f32, t.y as f32);
                if t.pressed {
                    TOUCHED.store(true, Ordering::SeqCst);
                }
                if t.pressed && !was_pressed {
                    window.dispatch_event(WindowEvent::PointerPressed { position, button: PointerEventButton::Left });
                } else if t.pressed {
                    window.dispatch_event(WindowEvent::PointerMoved { position });
                } else if was_pressed {
                    window.dispatch_event(WindowEvent::PointerReleased { position, button: PointerEventButton::Left });
                    window.dispatch_event(WindowEvent::PointerExited);
                }
                was_pressed = t.pressed;
            }
        }

        std::thread::sleep(Duration::from_millis(1)); // yields to the idle task and the watchdog
    }
}
