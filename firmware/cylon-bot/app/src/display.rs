//! Safe wrappers over `board_display`, the C component that owns the panel, touch and speaker.

use esp_idf_svc::sys::board_display as bd;
use esp_idf_svc::sys::{heap_caps_malloc, MALLOC_CAP_DMA, MALLOC_CAP_INTERNAL};
use slint::platform::software_renderer::Rgb565Pixel;

pub const WIDTH: usize = 466;
pub const HEIGHT: usize = 466;
/// The most rows one `bd_draw` takes; also the size of each DMA strip.
pub const STRIP_ROWS: usize = 16;

pub fn init() -> anyhow::Result<()> {
    let err = unsafe { bd::bd_init() };
    anyhow::ensure!(err == 0, "board_display init failed: {err}");
    Ok(())
}

pub fn set_brightness(percent: u8) {
    unsafe { bd::bd_set_brightness(percent) }
}

/// A short two-tone chime (rate limited inside the component).
pub fn chime() {
    unsafe { bd::bd_chime() }
}

/// The chime now, ignoring the rate limit: to hear a new volume.
pub fn chime_now() {
    unsafe { bd::bd_chime_now() }
}

/// Speaker volume, 0 to 100, for chimes and replies.
pub fn set_volume(percent: u8) {
    unsafe { bd::bd_set_volume(percent) }
}

/// Start capturing the microphone at the uplink rate (16 kHz mono). Waits for a chime in progress; fails if the
/// microphone is absent or already open. Pair with `mic_close`.
pub fn mic_open() -> anyhow::Result<()> {
    let err = unsafe { bd::bd_mic_open(cylon_bot_proto::UPLINK_RATE) };
    anyhow::ensure!(err == 0, "microphone open failed: {err}");
    Ok(())
}

/// Fill `out` with mono 16-bit samples, blocking about as long as they take to record. Returns how many were
/// written: `out.len()` on success, 0 on an error or a timeout.
pub fn mic_read(out: &mut [i16]) -> usize {
    let n = unsafe { bd::bd_mic_read(out.as_mut_ptr(), out.len() as i32, 1000) };
    n.max(0) as usize
}

pub fn mic_close() {
    unsafe { bd::bd_mic_close() }
}

/// Open the speaker for a spoken reply at `rate` (16-bit mono). Fails if the microphone is open or the speaker is
/// absent. Pair with `speaker_end`.
pub fn speaker_begin(rate: u32) -> anyhow::Result<()> {
    let err = unsafe { bd::bd_speaker_begin(rate) };
    anyhow::ensure!(err == 0, "speaker open failed: {err}");
    Ok(())
}

/// Play `pcm` (whole little-endian 16-bit samples), blocking until it is queued. The buffer is mutable because the
/// codec's software volume scales it in place. False on an error.
pub fn speaker_write(pcm: &mut [u8]) -> bool {
    unsafe { bd::bd_speaker_write(pcm.as_mut_ptr() as *const core::ffi::c_void, pcm.len()) >= 0 }
}

pub fn speaker_end() {
    unsafe { bd::bd_speaker_end() }
}

/// The finger on the glass, if it can be read.
pub struct Touch {
    pub x: i16,
    pub y: i16,
    pub pressed: bool,
}

pub fn touch() -> Option<Touch> {
    let mut t = bd::bd_touch_t { x: 0, y: 0, pressed: false };
    unsafe { bd::bd_touch_read(&mut t) }.then_some(Touch { x: t.x, y: t.y, pressed: t.pressed })
}

/// Two internal-RAM strips the panel's DMA reads from, used alternately so one is filled while the other
/// is being sent.
pub struct Strips {
    bufs: [&'static mut [u32]; 2],
}

impl Strips {
    pub fn new() -> anyhow::Result<Self> {
        let alloc = || -> anyhow::Result<&'static mut [u32]> {
            let p = unsafe { heap_caps_malloc(WIDTH * STRIP_ROWS * 2, MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL) } as *mut u32;
            anyhow::ensure!(!p.is_null(), "no internal DMA memory for a panel strip");
            Ok(unsafe { std::slice::from_raw_parts_mut(p, WIDTH * STRIP_ROWS / 2) })
        };
        Ok(Strips { bufs: [alloc()?, alloc()?] })
    }

    /// Send rows `y0..y1` (both even) of the RGB565 framebuffer to the panel and wait until they are out.
    pub fn push(&mut self, fb: &[Rgb565Pixel], y0: usize, y1: usize) {
        debug_assert!(y0 % 2 == 0 && y1 % 2 == 0 && y1 <= HEIGHT);
        let mut which = 0;
        let mut y = y0;
        while y < y1 {
            let rows = STRIP_ROWS.min(y1 - y);
            // Two pixels per 32-bit word, byte-swapped into the panel's big-endian order.
            let src: &[u32] = unsafe { std::slice::from_raw_parts(fb[y * WIDTH..].as_ptr() as *const u32, rows * WIDTH / 2) };
            let buf = &mut self.bufs[which];
            for (d, s) in buf[..rows * WIDTH / 2].iter_mut().zip(src) {
                *d = ((s & 0x00ff_00ff) << 8) | ((s >> 8) & 0x00ff_00ff);
            }
            // The panel IO finishes the previous strip before it starts this one, so the other buffer is
            // free again as soon as this call returns.
            if unsafe { bd::bd_draw(0, y as i32, WIDTH as i32, (y + rows) as i32, buf.as_ptr() as *const u16) } != 0 {
                log::warn!("panel draw failed at row {y}");
            }
            which ^= 1;
            y += rows;
        }
        unsafe { bd::bd_wait() };
    }
}
