//! THROWAWAY: Slint's software renderer on the panel. A persistent RGB565 framebuffer in PSRAM is
//! rendered line by line; the dirty rows are copied (byte-swapped) into a small internal DMA buffer
//! and pushed through `bd_draw`.
use std::ops::Range;
use std::rc::Rc;
use std::time::{Duration, Instant};

use esp_idf_svc::sys::board_display::{bd_draw, bd_touch_read, bd_touch_t, bd_wait};
use esp_idf_svc::sys::{heap_caps_malloc, MALLOC_CAP_DMA, MALLOC_CAP_INTERNAL};
use slint::platform::software_renderer::{LineBufferProvider, MinimalSoftwareWindow, RepaintBufferType, Rgb565Pixel};
use slint::platform::{Platform, PointerEventButton, WindowAdapter, WindowEvent};
use slint::{ComponentHandle, LogicalPosition};

slint::include_modules!();

const W: usize = 466;
const H: usize = 466;
const STRIP: usize = 16;
const SWAP_BYTES: bool = true;

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

struct Fb<'a> {
    px: &'a mut [Rgb565Pixel],
    xmin: usize,
    xmax: usize,
    min: usize,
    max: usize,
}
impl LineBufferProvider for &mut Fb<'_> {
    type TargetPixel = Rgb565Pixel;
    fn process_line(&mut self, line: usize, range: Range<usize>, render_fn: impl FnOnce(&mut [Rgb565Pixel])) {
        render_fn(&mut self.px[line * W + range.start..line * W + range.end]);
        self.xmin = self.xmin.min(range.start);
        self.xmax = self.xmax.max(range.end);
        self.min = self.min.min(line);
        self.max = self.max.max(line);
    }
}

pub fn run() -> anyhow::Result<()> {
    let window = MinimalSoftwareWindow::new(RepaintBufferType::ReusedBuffer);
    slint::platform::set_platform(Box::new(Plat { window: window.clone(), start: Instant::now() }))
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    window.set_size(slint::PhysicalSize::new(W as u32, H as u32));
    let ui = Probe::new().map_err(|e| anyhow::anyhow!("{e}"))?;
    ui.show().map_err(|e| anyhow::anyhow!("{e}"))?;

    let mut pixels = vec![Rgb565Pixel(0); W * H]; // PSRAM
    let mut fb = Fb { px: &mut pixels, xmin: usize::MAX, xmax: 0, min: usize::MAX, max: 0 };
    let mut dma: [&mut [u32]; 2] = [(); 2].map(|_| {
        let p = unsafe { heap_caps_malloc(W * STRIP * 2, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL) } as *mut u32;
        assert!(!p.is_null(), "no internal DMA memory for a strip buffer");
        unsafe { std::slice::from_raw_parts_mut(p, W * STRIP / 2) }
    });

    let started = Instant::now();
    let (mut frames, mut window_start, mut push_us_total, mut render_us_total) = (0u32, Instant::now(), 0u128, 0u128);
    let mut phase = (-1, true, true);
    let mut rows_total = 0usize;
    let mut xspan_total = 0usize;
    let (mut t_copy, mut t_draw, mut t_wait) = (0u128, 0u128, 0u128);
    let mut was_pressed = false;
    let mut last_touch = Instant::now();
    loop {
        slint::platform::update_timers_and_animations();
        let secs = started.elapsed().as_secs();
        // 0-6 s colour bars; then 12 s phases: both, centre only, rim only (repeating).
        let (mode, rim, centre) = match secs {
            0..=5 => (0, true, true),
            _ => match ((secs - 6) / 12) % 3 { 0 => (1, true, true), 1 => (1, false, true), _ => (1, true, false) },
        };
        if (mode, rim, centre) != phase {
            phase = (mode, rim, centre);
            ui.set_mode(mode);
            ui.set_rim_on(rim);
            ui.set_center_on(centre);
            (frames, window_start, push_us_total, render_us_total) = (0, Instant::now(), 0, 0);
            log::info!("phase: mode={mode} rim={rim} centre={centre}");
        }

        window.draw_if_needed(|renderer| {
            fb.min = usize::MAX;
            fb.max = 0;
            fb.xmin = usize::MAX;
            fb.xmax = 0;
            let tr = Instant::now();
            renderer.render_by_line(&mut fb);
            render_us_total += tr.elapsed().as_micros();
            if fb.min == usize::MAX {
                return;
            }
            let (y0, y1) = (fb.min & !1, ((fb.max | 1) + 1).min(H));
            let t = Instant::now();
            let mut y = y0;
            let mut which = 0;
            while y < y1 {
                let rows = STRIP.min(y1 - y);
                // Two pixels per 32-bit word, swapped to the panel's big-endian order.
                let src: &[u32] = unsafe {
                    std::slice::from_raw_parts(fb.px[y * W..].as_ptr() as *const u32, rows * W / 2)
                };
                let tc = Instant::now();
                let buf = &mut dma[which];
                for (d, s) in buf[..rows * W / 2].iter_mut().zip(src) {
                    *d = if SWAP_BYTES { ((s & 0x00ff_00ff) << 8) | ((s >> 8) & 0x00ff_00ff) } else { *s };
                }
                t_copy += tc.elapsed().as_micros();
                let td = Instant::now();
                if unsafe { bd_draw(0, y as i32, W as i32, (y + rows) as i32, buf.as_ptr() as *const u16) } != 0 {
                    log::warn!("bd_draw failed at row {y}");
                }
                t_draw += td.elapsed().as_micros();
                which ^= 1;
                y += rows;
            }
            let tw = Instant::now();
            unsafe { bd_wait() };
            t_wait += tw.elapsed().as_micros();
            push_us_total += t.elapsed().as_micros();
            rows_total += y1 - y0;
            xspan_total += fb.xmax.saturating_sub(fb.xmin);
            frames += 1;
        });

        if last_touch.elapsed() >= Duration::from_millis(20) {
            last_touch = Instant::now();
            let mut t = bd_touch_t { x: 0, y: 0, pressed: false };
            if unsafe { bd_touch_read(&mut t) } {
                let pos = LogicalPosition::new(t.x as f32, t.y as f32);
                if t.pressed && !was_pressed {
                    log::info!("touch down at {},{}", t.x, t.y);
                    window.dispatch_event(WindowEvent::PointerPressed { position: pos, button: PointerEventButton::Left });
                } else if t.pressed {
                    window.dispatch_event(WindowEvent::PointerMoved { position: pos });
                } else if was_pressed {
                    window.dispatch_event(WindowEvent::PointerReleased { position: pos, button: PointerEventButton::Left });
                }
                was_pressed = t.pressed;
            }
        }

        let elapsed = window_start.elapsed();
        if elapsed >= Duration::from_secs(5) {
            let fps = frames as f32 / elapsed.as_secs_f32();
            let push_ms = if frames > 0 { push_us_total as f32 / frames as f32 / 1000.0 } else { 0.0 };
            let render_ms = if frames > 0 { render_us_total as f32 / frames as f32 / 1000.0 } else { 0.0 };
            let rows = if frames > 0 { rows_total / frames as usize } else { 0 };
            let xs = if frames > 0 { xspan_total / frames as usize } else { 0 };
            if frames > 0 {
                let f = frames as f32 * 1000.0;
                log::info!("push split per frame: copy {:.1} ms, draw calls {:.1} ms, wait {:.1} ms", t_copy as f32 / f, t_draw as f32 / f, t_wait as f32 / f);
            }
            (t_copy, t_draw, t_wait) = (0, 0, 0);
            log::info!("render: {fps:.1} fps; per frame: render {render_ms:.1} ms, push {push_ms:.1} ms, {rows} rows, x span {xs}");
            ui.set_fps_text(format!("{fps:.0} fps").into());
            (frames, window_start, push_us_total, render_us_total, rows_total, xspan_total) = (0, Instant::now(), 0, 0, 0, 0);
        }

        std::thread::sleep(Duration::from_millis(1)); // yields to the idle task and the watchdog
    }
}
