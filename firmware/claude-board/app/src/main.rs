//! Claude Board firmware: shows every Claude Code session and answers Claude's questions.
//! Design: docs/superpowers/specs/2026-11-09-claude-board-rust-design.md

mod display;
mod platform;

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use claude_board_ui::controller::{Controller, Outbox};
use claude_board_ui::AppWindow;
use esp_idf_svc::sys::{heap_caps_get_free_size, heap_caps_get_largest_free_block, MALLOC_CAP_DMA, MALLOC_CAP_INTERNAL, MALLOC_CAP_SPIRAM};
use slint::ComponentHandle;

/// Until the network task exists (Task 11) there is nowhere to send answers.
struct NoWire;

impl Outbox for NoWire {
    fn send(&self, _json: String) -> bool {
        false
    }
}

/// Internal RAM is the scarce resource (see sdkconfig.defaults); a line every 30 s shows a leak or a
/// squeeze long before something fails to allocate.
fn heap_line() {
    unsafe {
        log::info!(
            "heap: internal free={} largest={} dma_largest={} psram free={}",
            heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
            heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
            heap_caps_get_largest_free_block(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL),
            heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
        );
    }
}

fn unix_now() -> Option<i64> {
    SystemTime::now().duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs() as i64)
}

fn main() -> anyhow::Result<()> {
    esp_idf_svc::sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();

    display::init()?;
    log::info!("display and touch up");
    heap_line();

    let window = platform::install()?;
    let ui = AppWindow::new().map_err(|e| anyhow::anyhow!("{e}"))?;
    ui.show().map_err(|e| anyhow::anyhow!("{e}"))?;
    let controller = Controller::new(&ui, NoWire);
    // A fixed set of sessions, so the screens can be seen before the network task exists.
    controller.on_message(include_str!("../../../../packages/claude-board-bridge/tests/fixtures/board/state.json"));

    std::thread::Builder::new().stack_size(3072).spawn(|| loop {
        std::thread::sleep(Duration::from_secs(30));
        heap_line();
    })?;

    let mut last_tick = Instant::now();
    platform::run(&window, || {
        if last_tick.elapsed() >= Duration::from_millis(250) {
            last_tick = Instant::now();
            controller.tick(unix_now());
        }
    })
}
