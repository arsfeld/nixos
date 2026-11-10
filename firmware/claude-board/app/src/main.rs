//! Claude Board firmware: shows every Claude Code session and answers Claude's questions.
//! Design: docs/superpowers/specs/2026-11-09-claude-board-rust-design.md

mod display;
mod net;
mod platform;

use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use claude_board_ui::controller::{Controller, Outbox};
use claude_board_ui::link;
use claude_board_ui::power::{drift_px, Power};
use claude_board_ui::{AppWindow, Page};
use esp_idf_svc::sys::{heap_caps_get_free_size, heap_caps_get_largest_free_block, MALLOC_CAP_DMA, MALLOC_CAP_INTERNAL, MALLOC_CAP_SPIRAM};
use esp_idf_svc::hal::peripherals::Peripherals;
use slint::ComponentHandle;

/// Used when no credentials are compiled in: answers have nowhere to go.
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

    let settings = link::settings(env!("CB_URL"), env!("CB_NTP"), env!("CB_DNS")).map_err(anyhow::Error::msg)?;
    let (tx, rx) = mpsc::channel::<net::Event>();
    let (ssid, pass, token) = (env!("CB_WIFI_SSID"), env!("CB_WIFI_PASS"), env!("CB_TOKEN"));
    // `Box<dyn Fn>`-free: the controller is generic over its outbox, so each case builds its own loop.
    if ssid.is_empty() || token.is_empty() {
        log::error!("no credentials compiled in: run `just board creds`, then rebuild");
        ui.set_link(false);
        return run(&window, &ui, Controller::new(&ui, NoWire), rx);
    }
    let modem = Peripherals::take()?.modem;
    let wire = net::start(net::Credentials { ssid, pass, token }, settings, modem, tx)?;
    ui.set_link(false);
    run(&window, &ui, Controller::new(&ui, wire), rx)
}

fn run<O: Outbox + 'static>(
    window: &std::rc::Rc<slint::platform::software_renderer::MinimalSoftwareWindow>,
    ui: &AppWindow,
    controller: Controller<O>,
    rx: mpsc::Receiver<net::Event>,
) -> anyhow::Result<()> {
    std::thread::Builder::new().stack_size(3072).spawn(|| loop {
        std::thread::sleep(Duration::from_secs(30));
        heap_line();
    })?;

    let boot = Instant::now();
    let ms = || boot.elapsed().as_millis() as i64;
    let mut power = Power::new(ms());
    let mut brightness = 0u8;
    let mut last_tick = Instant::now();
    platform::run(window, || {
        if platform::take_touch() {
            power.touch(ms());
        }
        // Swipe right goes back a level (detail to list, list to home); a question on screen stays put.
        if platform::take_swipe_right() && ui.get_page() != Page::Question {
            ui.invoke_back_tapped();
        }
        while let Ok(event) = rx.try_recv() {
            match event {
                net::Event::Message(text) => {
                    log::info!("bridge message: {} bytes", text.len());
                    power.model_changed(ms());
                    controller.on_message(&text);
                    if controller.wants_chime() {
                        display::chime();
                    }
                }
                net::Event::Link(up) => controller.set_link(up),
            }
        }
        if last_tick.elapsed() >= Duration::from_millis(250) {
            last_tick = Instant::now();
            controller.tick(unix_now());
            // Dim after a quiet spell and nudge the picture a few pixels, against burn-in.
            let wanted = power.brightness(ms());
            if wanted != brightness {
                brightness = wanted;
                display::set_brightness(wanted);
                log::info!("brightness {wanted}");
            }
            let (dx, dy) = drift_px(ms());
            ui.set_drift_x(dx as f32);
            ui.set_drift_y(dy as f32);
        }
    })
}
