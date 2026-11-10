//! Claude Board firmware: shows every Claude Code session and answers Claude's questions.
//! Design: docs/superpowers/specs/2026-11-09-claude-board-rust-design.md

mod display;
mod mic;
mod net;
mod platform;
mod speaker;

use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use claude_board_ui::audio::{cancel_json, speech_event, volume_step, SpeechEvent, VOLUME_DEFAULT, VOLUME_MAX, VOLUME_MIN};
use claude_board_ui::controller::{Controller, Outbox};
use claude_board_ui::link;
use claude_board_ui::power::{drift_px, Power};
use claude_board_ui::{AppWindow, Page};
use esp_idf_svc::sys::{heap_caps_get_free_size, heap_caps_get_largest_free_block, MALLOC_CAP_DMA, MALLOC_CAP_INTERNAL, MALLOC_CAP_SPIRAM};
use esp_idf_svc::hal::peripherals::Peripherals;
use esp_idf_svc::nvs::{EspDefaultNvsPartition, EspNvs, NvsDefault};
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

/// The NVS key of the speaker volume, in the "board" namespace.
const VOLUME_KEY: &str = "volume";
/// How long the volume stays on screen after a swipe.
const VOLUME_SHOWN: Duration = Duration::from_millis(1500);

/// What the board keeps across reboots.
struct Settings {
    store: Option<EspNvs<NvsDefault>>,
    volume: u8,
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

    // The speaker volume survives a reboot in NVS; the Wi-Fi driver gets the same partition.
    let nvs = EspDefaultNvsPartition::take()?;
    let store = EspNvs::new(nvs.clone(), "board", true).map_err(|e| log::warn!("settings not stored: {e}")).ok();
    let volume = store.as_ref().and_then(|s| s.get_u8(VOLUME_KEY).ok().flatten()).unwrap_or(VOLUME_DEFAULT).clamp(VOLUME_MIN, VOLUME_MAX);
    display::set_volume(volume);
    ui.set_volume(volume as i32);
    let settings_store = Settings { store, volume };

    let settings = link::settings(env!("CB_URL"), env!("CB_NTP"), env!("CB_DNS")).map_err(anyhow::Error::msg)?;
    let (tx, rx) = mpsc::channel::<net::Event>();
    let (ssid, pass, token) = (env!("CB_WIFI_SSID"), env!("CB_WIFI_PASS"), env!("CB_TOKEN"));
    // `Box<dyn Fn>`-free: the controller is generic over its outbox, so each case builds its own loop.
    if ssid.is_empty() || token.is_empty() {
        log::error!("no credentials compiled in: run `just board creds`, then rebuild");
        return run(&window, &ui, Controller::new(&ui, NoWire), rx, None, settings_store);
    }
    let modem = Peripherals::take()?.modem;
    let wire = net::start(net::Credentials { ssid, pass, token }, settings, modem, nvs, tx)?;
    let mic_net = wire.clone();
    run(&window, &ui, Controller::new(&ui, wire), rx, Some(mic_net), settings_store)
}

fn run<O: Outbox + 'static>(
    window: &std::rc::Rc<slint::platform::software_renderer::MinimalSoftwareWindow>,
    ui: &AppWindow,
    controller: Controller<O>,
    rx: mpsc::Receiver<net::Event>,
    net: Option<net::Net>,
    mut saved: Settings,
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
    // Press to talk: the capture thread and the channel its levels arrive on, while a hold is being recorded.
    let mut capture: Option<(mic::Capture, mpsc::Receiver<f32>)> = None;
    // A pre-roll let go on a tap, still closing the microphone: waited for before it is opened again.
    let mut abandoned: Option<mic::Abandoned> = None;
    // The creature's voice: its own thread plays what the UI loop feeds it (see speaker.rs).
    let player = speaker::Player::start()?;
    let mut volume_hide: Option<Instant> = None;
    platform::run(window, || {
        controller.set_time_ms(ms() as u64); // precise timestamps for the double-tap guard
        if platform::take_touch() {
            power.touch(ms());
        }
        // Swipe right goes back a level (detail to list, list to home); a question on screen stays put.
        if platform::take_swipe_right() && ui.get_page() != Page::Question {
            ui.invoke_back_tapped();
        }
        let press = platform::take_press();
        // A tap anywhere but home cancels the creature's speech (on home the avatar's own handler does).
        if press.is_some() && ui.get_page() != Page::Home {
            controller.tap_cancels_speech();
        }
        // A finger on the avatar may become a hold: start the microphone now, so the words said before the hold
        // is recognised (450 ms) are kept. Not while it speaks: the speaker holds the shared clock until the hold
        // stops it, and that hold starts its capture the old way.
        if let (Some((x, y)), Some(net), None) = (press, &net, &capture) {
            if net.is_up() && !controller.is_speaking() && controller.can_hold_at(x, y) {
                if let Some(a) = abandoned.take() {
                    a.wait();
                }
                let (levels_tx, levels_rx) = mpsc::channel();
                capture = Some((mic::Capture::preroll(net.clone(), levels_tx), levels_rx));
            }
        }
        // A hold on the avatar starts a voice question, if the link is up and nothing is recording.
        if let Some((x, y)) = platform::take_hold_start() {
            // A pre-roll waiting for this hold.
            if matches!(&capture, Some((cap, _)) if !cap.is_live()) {
                if controller.hold_started(x, y) {
                    platform::accept_hold();
                    let utterance = controller.utterance().unwrap_or(0);
                    log::info!("voice: hold at ({x}, {y}), utterance {utterance} (pre-roll)");
                    if let Some((cap, _)) = &capture {
                        cap.begin(utterance); // after voice_start went out
                    }
                } else if let Some((cap, _)) = capture.take() {
                    abandoned = Some(cap.abandon());
                }
            } else if let (Some(net), None) = (&net, &capture) {
                // A hold while the creature speaks cancels the speech first: the speaker must be closed before the
                // microphone can have the shared clock.
                if net.is_up() && controller.is_speaking() {
                    controller.tap_cancels_speech();
                    player.stop_and_wait();
                    controller.set_audio_playing(false);
                }
                if net.is_up() && controller.hold_started(x, y) {
                    platform::accept_hold();
                    let (levels_tx, levels_rx) = mpsc::channel();
                    let utterance = controller.utterance().unwrap_or(0);
                    log::info!("voice: hold at ({x}, {y}), utterance {utterance}");
                    if let Some(a) = abandoned.take() {
                        a.wait(); // a discarded pre-roll may still hold the microphone
                    }
                    capture = Some((mic::Capture::start(utterance, net.clone(), levels_tx), levels_rx));
                }
            }
        }
        // A pre-roll that died on its own (the microphone failed) is dropped quietly: no hold was announced.
        if matches!(&capture, Some((cap, _)) if !cap.is_live() && cap.outcome() != mic::Outcome::Running) {
            if let Some((cap, _)) = capture.take() {
                abandoned = Some(cap.abandon());
            }
        }
        if let Some((cap, levels)) = &capture {
            while let Ok(level) = levels.try_recv() {
                controller.set_mic_level(level);
            }
            // The capture ended by itself: the limit is a release, a failure a cancel.
            let ended = cap.outcome();
            if ended == mic::Outcome::LimitReached || ended == mic::Outcome::Failed {
                if let Some((cap, _)) = capture.take() {
                    cap.stop();
                }
                let utterance = controller.hold_ended(); // sends voice_end and shows it thinking
                if let (Some(utterance), mic::Outcome::Failed, Some(net)) = (utterance, ended, &net) {
                    net.send(cancel_json(utterance));
                }
            }
        }
        if platform::take_hold_end() {
            if let Some((cap, _)) = capture.take() {
                cap.stop();
            }
            controller.hold_ended();
        }
        // The finger lifted before a hold was recognised: it was a tap, so the pre-roll goes.
        if platform::take_lift() && matches!(&capture, Some((cap, _)) if !cap.is_live()) {
            if let Some((cap, _)) = capture.take() {
                abandoned = Some(cap.abandon());
            }
        }
        // Swipe up or down on home: louder or quieter, shown for a moment and played as a chime.
        platform::set_vertical_swipes(ui.get_page() == Page::Home);
        if let Some(louder) = platform::take_swipe_vertical() {
            if ui.get_page() == Page::Home {
                saved.volume = volume_step(saved.volume, louder);
                display::set_volume(saved.volume);
                ui.set_volume(saved.volume as i32);
                ui.set_volume_shown(true);
                volume_hide = Some(Instant::now() + VOLUME_SHOWN);
                // The swipe began on the avatar, so a pre-roll may still be closing: the chime needs the clock.
                if let Some(a) = abandoned.take() {
                    a.wait();
                }
                display::chime_now();
                if let Some(store) = saved.store.as_mut() {
                    if let Err(e) = store.set_u8(VOLUME_KEY, saved.volume) {
                        log::warn!("volume not saved: {e}");
                    }
                }
                log::info!("volume {}", saved.volume);
            }
        }
        if volume_hide.is_some_and(|t| Instant::now() >= t) {
            volume_hide = None;
            ui.set_volume_shown(false);
        }
        while let Ok(event) = rx.try_recv() {
            match event {
                net::Event::Message(text) => {
                    log::info!("bridge message: {} bytes", text.len());
                    power.model_changed(ms());
                    match speech_event(&text) {
                        Some(SpeechEvent::Start { utterance, rate }) => {
                            player.begin(utterance, rate);
                            controller.set_audio_playing(true);
                        }
                        Some(SpeechEvent::End) => player.end(),
                        None => {}
                    }
                    controller.on_message(&text);
                    if controller.wants_chime() {
                        display::chime();
                    }
                }
                net::Event::Audio(frame) => player.push(&frame),
                net::Event::Link(up) => {
                    controller.set_link(up);
                    if !up {
                        player.stop(); // the rest of the reply will never arrive
                        controller.set_audio_playing(false);
                    }
                }
            }
        }
        // Speech that the creature is no longer doing (a tap cancelled it, or its mood moved on) stops at once; and
        // once the audio has drained the creature may go idle.
        if player.is_playing() {
            if !controller.is_speaking() {
                player.stop();
                controller.set_audio_playing(false);
            }
        } else {
            controller.set_audio_playing(false);
        }
        if last_tick.elapsed() >= Duration::from_millis(250) {
            last_tick = Instant::now();
            controller.tick_at(unix_now(), ms() as u64);
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
