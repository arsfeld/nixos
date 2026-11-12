//! Cylon Bot firmware: shows every Claude Code session and answers Claude's questions.
//! Design: docs/superpowers/specs/2026-11-09-cylon-bot-rust-design.md

mod display;
mod mic;
mod net;
mod platform;
mod sleep;
mod speaker;
mod wifi_info;

use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cylon_bot_ui::audio::{cancel_json, speech_event, volume_step, SpeechEvent, VOLUME_DEFAULT, VOLUME_MAX, VOLUME_MIN};
use cylon_bot_ui::battery::{self, Warner};
use cylon_bot_ui::controller::{Controller, Outbox};
use cylon_bot_ui::link;
use cylon_bot_ui::power::{drift_px, Conditions, Power, State};
use cylon_bot_ui::view::{battery_view, fmt_uptime, signal_bars};
use cylon_bot_ui::{AppWindow, LinkInfo, Page};
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
/// The UI's task (ESP-IDF's main task), for its stack's low-water mark in the heap line.
static UI_TASK: std::sync::atomic::AtomicPtr<core::ffi::c_void> = std::sync::atomic::AtomicPtr::new(core::ptr::null_mut());

fn heap_line() {
    unsafe {
        let ui = UI_TASK.load(std::sync::atomic::Ordering::Relaxed);
        log::info!(
            "heap: internal free={} largest={} dma_largest={} psram free={} ui_stack_min_free={}",
            heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
            heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
            heap_caps_get_largest_free_block(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL),
            heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
            if ui.is_null() { 0 } else { esp_idf_svc::sys::uxTaskGetStackHighWaterMark(ui as _) },
        );
    }
}

/// The NVS key of the speaker volume, in the "board" namespace.
const VOLUME_KEY: &str = "volume";
/// How long the volume stays on screen after a swipe.
const VOLUME_SHOWN: Duration = Duration::from_millis(1500);
/// How often the link page reads the Wi-Fi state while it is open.
const LINK_REFRESH: Duration = Duration::from_secs(2);

/// What the board keeps across reboots.
struct Settings {
    store: Option<EspNvs<NvsDefault>>,
    volume: u8,
}

/// One step louder or quieter, from a swipe on home or the volume page's keys: set, shown, played as a chime and
/// saved. On home the level shows in a pill for a moment; the volume page shows it itself.
fn step_volume(louder: bool, saved: &mut Settings, ui: &AppWindow, abandoned: &mut Option<mic::Abandoned>, volume_hide: &mut Option<Instant>) {
    saved.volume = volume_step(saved.volume, louder);
    display::set_volume(saved.volume);
    ui.set_volume(saved.volume as i32);
    if ui.get_page() == Page::Home {
        ui.set_volume_shown(true);
        *volume_hide = Some(Instant::now() + VOLUME_SHOWN);
    }
    // A swipe begins on the avatar, so a pre-roll may still be closing: the chime needs the clock.
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

/// The link page's reading: the Wi-Fi from ESP-IDF and the time since boot.
fn link_info(uptime: Duration) -> LinkInfo {
    let uptime = fmt_uptime(uptime.as_secs()).into();
    match wifi_info::read() {
        Some(w) => LinkInfo {
            rssi: w.rssi as i32,
            bars: signal_bars(w.rssi as i32),
            ssid: w.ssid.into(),
            address: w.ip.map_or_else(|| "--".into(), |ip| ip.to_string().into()),
            uptime,
        },
        None => LinkInfo { rssi: 0, bars: 0, ssid: "--".into(), address: "--".into(), uptime },
    }
}

/// Read the power chip, show the result and say whether a low-battery warning is due. Each reading is logged, like
/// the heap line, so `just board monitor` shows the charge.
fn read_battery(ui: &AppWindow, warner: &mut Warner) -> (bool, Option<battery::Reading>) {
    let r = display::battery();
    match &r {
        Some(b) => log::info!("battery: present={} usb={} charging={} percent={} mv={}", b.present as u8, b.usb as u8, b.charging as u8, b.percent, b.millivolts),
        None => log::info!("battery: no reading"),
    }
    ui.set_battery(battery_view(r.as_ref()));
    (warner.update(r.as_ref()), r)
}

/// Turn the panel on or off, once more if it did not take the command, and restart if it still did not: a board
/// stuck dark is worse than a reboot.
fn panel_power(on: bool, brightness: u8) {
    if !display::panel_power(on, brightness) && !display::panel_power(on, brightness) {
        log::error!("panel did not take power {}; restarting", if on { "on" } else { "off" });
        unsafe { esp_idf_svc::sys::esp_restart() };
    }
}

fn unix_now() -> Option<i64> {
    SystemTime::now().duration_since(UNIX_EPOCH).ok().map(|d| d.as_secs() as i64)
}

fn main() -> anyhow::Result<()> {
    esp_idf_svc::sys::link_patches();
    UI_TASK.store(unsafe { esp_idf_svc::sys::xTaskGetCurrentTaskHandle() } as _, std::sync::atomic::Ordering::Relaxed);
    esp_idf_svc::log::EspLogger::initialize_default();
    sleep::log_wake_cause();

    sleep::configure()?;
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
    let (networks, token) = (net::WIFI_NETWORKS, env!("CB_TOKEN"));
    // `Box<dyn Fn>`-free: the controller is generic over its outbox, so each case builds its own loop.
    if networks.is_empty() || token.is_empty() {
        log::error!("no credentials compiled in: run `just board creds`, then rebuild");
        return run(&window, &ui, Controller::new(&ui, NoWire), rx, None, settings_store);
    }
    let modem = Peripherals::take()?.modem;
    let wire = net::start(net::Credentials { networks, token }, settings, modem, nvs, tx)?;
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
    // Full speed while the panel is lit (see sleep.rs).
    let mut awake = sleep::Awake::new()?;
    awake.hold(true);
    let mut state = State::Bright;
    // The last battery reading, for the deep-sleep decision; none yet counts as USB.
    let mut last_reading: Option<battery::Reading> = None;
    let mut sleep_tried: Option<Instant> = None;
    let mut brightness = 0u8;
    let mut last_tick = Instant::now();
    // Press to talk: the capture thread and the channel its levels arrive on, while a hold is being recorded.
    let mut capture: Option<(mic::Capture, mpsc::Receiver<f32>)> = None;
    // A pre-roll let go on a tap, still closing the microphone: waited for before it is opened again.
    let mut abandoned: Option<mic::Abandoned> = None;
    // The creature's voice: its own thread plays what the UI loop feeds it (see speaker.rs).
    let player = speaker::Player::start()?;
    let mut volume_hide: Option<Instant> = None;
    // When the link page last read the Wi-Fi; `None` off that page, so opening it reads at once.
    let mut link_read: Option<Instant> = None;
    // The battery: read at once, then every `battery::REFRESH`.
    let mut battery_read: Option<Instant> = None;
    let mut battery_warner = Warner::new();
    platform::run(window, || {
        controller.set_time_ms(ms() as u64); // precise timestamps for the double-tap guard
        if platform::take_touch() {
            power.touch(ms());
            controller.note_touch(); // keeps the command menu open while it is used
        }
        // Swipe right goes back a level (detail to list, list to home); a question on screen stays put.
        if platform::take_swipe_right() && ui.get_page() != Page::Question {
            ui.invoke_back_tapped();
        }
        let press = platform::take_press();
        // A tap anywhere but home cancels the creature's speech (on home the avatar's own handler does). Not on the
        // volume page: its - and + are there to adjust a reply while it plays.
        if press.is_some() && !matches!(ui.get_page(), Page::Home | Page::Volume) {
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
        // A swipe down from the top edge of home opens the command menu.
        platform::set_vertical_swipes(ui.get_page() == Page::Home);
        if platform::take_edge_down() && ui.get_page() == Page::Home {
            controller.open_menu();
        }
        // Swipe up or down on home: louder or quieter. While the menu is open, up closes it and down does nothing.
        if let Some(louder) = platform::take_swipe_vertical() {
            if ui.get_page() == Page::Home {
                if controller.menu_open() {
                    if louder {
                        ui.invoke_back_tapped(); // on home, back closes the menu
                    }
                } else {
                    step_volume(louder, &mut saved, ui, &mut abandoned, &mut volume_hide);
                }
            }
        }
        // The volume page's - and + keys.
        if let Some(louder) = controller.take_volume_step() {
            step_volume(louder, &mut saved, ui, &mut abandoned, &mut volume_hide);
        }
        if volume_hide.is_some_and(|t| Instant::now() >= t) {
            volume_hide = None;
            ui.set_volume_shown(false);
        }
        while let Ok(event) = rx.try_recv() {
            match event {
                net::Event::Message(text) => {
                    log::info!("bridge message: {} bytes", text.len());
                    match speech_event(&text) {
                        Some(SpeechEvent::Start { utterance, rate }) => {
                            player.begin(utterance, rate);
                            controller.set_audio_playing(true);
                        }
                        Some(SpeechEvent::End) => player.end(),
                        None => {}
                    }
                    controller.on_message(&text);
                    // A question, a reminder or a reply lights a dark panel; anything else only keeps a lit one lit.
                    if controller.take_wake() { power.wake_event(ms()) } else { power.activity(ms()) }
                    if controller.wants_chime() {
                        display::chime();
                    }
                }
                net::Event::Audio(frame) => player.push(&frame),
                net::Event::Link(up) => {
                    controller.set_link(up);
                    if controller.take_wake() {
                        power.wake_event(ms());
                    }
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
            let now_state = power.state(ms());
            if now_state != state {
                log::info!("power: {now_state:?}");
                let lit = power.brightness(ms());
                if now_state == State::Dark {
                    panel_power(false, 0);
                    platform::set_dark(true);
                    awake.hold(false);
                } else if state == State::Dark {
                    awake.hold(true);
                    panel_power(true, lit);
                    brightness = lit;
                    platform::set_dark(false);
                }
                state = now_state;
            }
            let wanted = power.brightness(ms());
            if state != State::Dark && wanted != brightness {
                brightness = wanted;
                display::set_brightness(wanted);
                log::info!("brightness {wanted}");
            }
            let (dx, dy) = drift_px(ms());
            ui.set_drift_x(dx as f32);
            ui.set_drift_y(dy as f32);
        }
        // While the power page is open it reads as often as the link page reads the Wi-Fi, so plugging in shows.
        let battery_due = if ui.get_page() == Page::Power { LINK_REFRESH } else { battery::REFRESH };
        if battery_read.is_none_or(|t| t.elapsed() >= battery_due) {
            battery_read = Some(Instant::now());
            let (warn, reading) = read_battery(ui, &mut battery_warner);
            last_reading = reading;
            if warn {
                log::info!("battery: low warning");
                power.wake_event(ms());
                display::chime();
            }
        }
        // On battery, long dark, nothing waiting: sleep until a touch. Waking is a reboot.
        let conditions = Conditions::new(last_reading.as_ref(), controller.question_waiting(), player.is_playing() || capture.is_some());
        if power.should_deep_sleep(ms(), &conditions) && sleep_tried.is_none_or(|t| t.elapsed() >= Duration::from_secs(5)) {
            sleep_tried = Some(Instant::now());
            sleep::deep_sleep(net.as_ref()); // returns only if a wake pin is low; tried again in 5 s
        }
        if ui.get_page() != Page::Link {
            link_read = None;
        } else if link_read.is_none_or(|t| t.elapsed() >= LINK_REFRESH) {
            link_read = Some(Instant::now());
            ui.set_link_info(link_info(boot.elapsed()));
        }
    })
}
