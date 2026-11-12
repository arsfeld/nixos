# Cylon Bot Power Saving Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The board's panel goes dark when nobody needs it (staying online), it deep-sleeps after a long idle on battery, and the chip scales its clock down whenever the panel is dark.

**Architecture:** A pure state machine in `ui/src/power.rs` (Bright / Dim / Dark plus a deep-sleep verdict) is fed touches, wake events and activity by the app loop. The controller classifies bridge messages into wake events and activity. The app turns states into panel commands (`bd_panel_power`), a paused render loop, power-management locks and, on battery, `esp_deep_sleep_start` with ext1 wake on the touch interrupt and BOOT.

**Tech Stack:** Rust (`cylon-bot-ui` host-tested crate, `app` ESP binary on `esp-idf-svc`), Slint software renderer, ESP-IDF 5.5.4 C component `board_display`, `esp_pm`, `esp_sleep`.

**Spec:** `docs/superpowers/specs/2026-11-11-cylon-bot-power-design.md`

## Global Constraints

- Firmware only: no change to `packages/cylon-bot-bridge`, `packages/cylon-bot-proto` or the protocol.
- Timeouts: Dim after `AWAKE_MS` = 30 000 ms (unchanged); Dark after a further `DIM_MS` = 120 000 ms; deep sleep after a further `DARK_TO_SLEEP_MS` = 600 000 ms in Dark.
- Brightness: Bright 70, Dim 8 (unchanged constants `BRIGHT_AWAKE`, `BRIGHT_IDLE`).
- Dark touch poll every 50 ms; Bright/Dim touch poll stays 20 ms.
- Deep sleep only when the last battery reading is `Some(r)` with `r.on_battery()`, no question is waiting, and no audio is playing or recording. A failed reading (`None`) counts as USB.
- PM: max 240 MHz, min 80 MHz; Wi-Fi `WIFI_PS_MIN_MODEM`; automatic light sleep compiled in but off (`LIGHT_SLEEP = false`) until the board gate passes.
- Panel off is DCS 0x28 then 0x10; on is 0x11, wait 120 ms, 0x29, then brightness.
- Deep sleep wake: ext1, any-low, on GPIO 11 (touch INT, active low) and GPIO 0 (BOOT).
- Logs carry no speech or text: `power: <state>`, `wake: touch|boot|reset|other`, `sleep: deep`.
- Commit straight to master; conventional commits, scope `modules`. Host tests: `nix develop .#firmware -c bash -c 'cd firmware/cylon-bot && cargo test -p cylon-bot-ui'`. Device build: `nix develop -c just board build`.

## Review Focus

1. **A question arrives while Dark and the first tap lands on an option.** Expect: the tap only wakes the panel; nothing is sent. Pinned by `a_tap_on_a_dark_screen_wakes_and_answers_nothing` (Task 3).
2. **Many session updates while Dark.** Expect: the panel stays dark (activity never lights it, and does not postpone deep sleep). Pinned by `activity_while_dark_neither_wakes_nor_postpones_sleep` (Task 1).
3. **The clock jumps (boot-relative ms is monotonic, but tests feed values before `last`).** Expect: no panic, treated as Bright. Pinned by `a_clock_before_the_last_event_is_bright` (Task 1).
4. **USB unplugged while a question is waiting in Dark, for more than 10 min.** Expect: no deep sleep until it is answered or cleared. Pinned by `never_deep_sleeps_with_a_question_waiting` (Task 1) and `question_waiting_follows_the_model` (Task 2).
5. **The link drops and comes back while Dark.** Expect: the return is a wake event (the user sees it reconnected); the drop is not. Pinned by `link_returning_is_a_wake_but_dropping_is_not` (Task 2).

---

### Task 0: Baseline measurement (on the board, before any code change)

**Files:**
- Create: `docs/superpowers/specs/2026-11-11-cylon-bot-power-findings.md`

- [ ] **Step 1:** Flash current master (`nix develop -c just board build && nix develop -c just board flash`), unplug USB, leave it idle 1 h, capture `just board monitor` output. Record the first and last `battery:` lines (mV, percent) and the elapsed time.
- [ ] **Step 2:** If a USB power meter is available, record mA on USB idle (dimmed) for 5 minutes. Otherwise write "no meter".
- [ ] **Step 3:** Write the findings file with a "Baseline (before changes)" section holding those numbers, and a table with empty rows for: after PM (Task 4), after Dark (Task 5), light sleep (Task 6).
- [ ] **Step 4:** Commit: `git commit -m "docs(modules): record the cylon bot's power baseline"`.

---

### Task 1: Power state machine

**Files:**
- Modify: `firmware/cylon-bot/ui/src/power.rs`

**Interfaces:**
- Produces:
  - `pub enum State { Bright, Dim, Dark }` (`Debug, Clone, Copy, PartialEq, Eq`)
  - `pub const DIM_MS: i64 = 120_000; pub const DARK_TO_SLEEP_MS: i64 = 600_000;`
  - `pub struct Conditions { pub on_battery: bool, pub question_waiting: bool, pub audio_busy: bool }`
  - `impl Conditions { pub fn new(reading: Option<&battery::Reading>, question_waiting: bool, audio_busy: bool) -> Self }` (`on_battery` = `reading.is_some_and(|r| r.on_battery())`)
  - `impl Power`: `new(now_ms: i64)`, `touch(now_ms)`, `wake_event(now_ms)`, `activity(now_ms)` (replaces `model_changed`; a no-op when `state(now_ms) == Dark`), `state(now_ms) -> State`, `brightness(now_ms) -> u8` (70 Bright, 8 Dim and Dark), `should_deep_sleep(now_ms, c: &Conditions) -> bool`.
  - `drift_px` unchanged.

Model: one `last_ms` (the latest touch, wake event, or activity accepted while not Dark). Elapsed `e = now - last`: `e < AWAKE_MS` Bright, `e < AWAKE_MS + DIM_MS` Dim, else Dark. Deep sleep when `e >= AWAKE_MS + DIM_MS + DARK_TO_SLEEP_MS` and `c.on_battery && !c.question_waiting && !c.audio_busy`.

- [ ] **Step 1: Write the failing tests** (replace the two `model_changed` tests with `activity` equivalents; keep the drift tests)

```rust
#[test]
fn bright_then_dim_then_dark() {
    let p = Power::new(0);
    assert_eq!(p.state(29_999), State::Bright);
    assert_eq!(p.state(30_000), State::Dim);
    assert_eq!(p.state(149_999), State::Dim);
    assert_eq!(p.state(150_000), State::Dark);
}

#[test]
fn touch_and_wake_event_light_a_dark_panel() {
    let mut p = Power::new(0);
    p.touch(200_000);
    assert_eq!(p.state(200_000), State::Bright);
    let mut q = Power::new(0);
    q.wake_event(200_000);
    assert_eq!(q.state(200_000), State::Bright);
}

#[test]
fn activity_restarts_the_timer_while_bright_or_dim() {
    let mut p = Power::new(0);
    p.activity(100_000); // Dim at this point
    assert_eq!(p.state(129_999), State::Bright);
}

#[test]
fn activity_while_dark_neither_wakes_nor_postpones_sleep() {
    let mut p = Power::new(0);
    let c = Conditions { on_battery: true, question_waiting: false, audio_busy: false };
    for t in (150_000..750_000).step_by(5_000) {
        p.activity(t);
        assert_eq!(p.state(t), State::Dark);
    }
    assert!(p.should_deep_sleep(750_000, &c));
}

#[test]
fn deep_sleep_after_ten_minutes_dark_on_battery() {
    let p = Power::new(0);
    let c = Conditions { on_battery: true, question_waiting: false, audio_busy: false };
    assert!(!p.should_deep_sleep(749_999, &c));
    assert!(p.should_deep_sleep(750_000, &c));
}

#[test]
fn never_deep_sleeps_on_usb_or_without_a_reading() {
    let p = Power::new(0);
    let usb = battery::Reading { present: true, usb: true, charging: false, percent: 50, millivolts: 3900 };
    assert!(!p.should_deep_sleep(10_000_000, &Conditions::new(Some(&usb), false, false)));
    assert!(!p.should_deep_sleep(10_000_000, &Conditions::new(None, false, false)));
}

#[test]
fn never_deep_sleeps_with_a_question_waiting() {
    let p = Power::new(0);
    assert!(!p.should_deep_sleep(10_000_000, &Conditions { on_battery: true, question_waiting: true, audio_busy: false }));
}

#[test]
fn never_deep_sleeps_while_audio_is_busy() {
    let p = Power::new(0);
    assert!(!p.should_deep_sleep(10_000_000, &Conditions { on_battery: true, question_waiting: false, audio_busy: true }));
}

#[test]
fn a_clock_before_the_last_event_is_bright() {
    let mut p = Power::new(0);
    p.touch(500_000);
    assert_eq!(p.state(1_000), State::Bright);
    assert_eq!(p.state(i64::MIN), State::Bright);
    let c = Conditions { on_battery: true, question_waiting: false, audio_busy: false };
    assert!(!p.should_deep_sleep(i64::MIN, &c));
    let _ = p.state(i64::MAX); // no overflow panic: use saturating_sub
}

#[test]
fn brightness_follows_the_state() {
    let p = Power::new(0);
    assert_eq!(p.brightness(0), 70);
    assert_eq!(p.brightness(30_000), 8);
    assert_eq!((AWAKE_MS, DIM_MS, DARK_TO_SLEEP_MS), (30_000, 120_000, 600_000));
}
```

- [ ] **Step 2:** Run host tests; expect compile failure (`State`, `Conditions` not defined).
- [ ] **Step 3:** Implement as described in Interfaces in `ui/src/power.rs`; update the module comment to mention the dark panel and deep sleep. Use `now_ms.saturating_sub(self.last_ms)`. Rename the call in `app/src/main.rs` from `power.model_changed(ms())` to `power.activity(ms())` so the app still builds.
- [ ] **Step 4:** Run host tests; expect PASS.
- [ ] **Step 5:** Commit: `git commit -m "feat(modules): cylon bot power states with a dark panel and a deep sleep verdict"`.

---

### Task 2: Controller classifies wake events

**Files:**
- Modify: `firmware/cylon-bot/ui/src/controller.rs`
- Test: `firmware/cylon-bot/ui/tests/controller.rs`

**Interfaces:**
- Produces:
  - `pub fn take_wake(&self) -> bool` — true once after a message or link change that should light a dark panel; cleared on read (same pattern as `wants_chime`).
  - `pub fn question_waiting(&self) -> bool` — `self.model.waiting_count() > 0`.

A wake is set exactly where the controller sets `chime` (new waiting question or approval, a new current ask, a `reminder`), plus on `SpeakStart`, plus in `set_link(true)` when the previous link state was down. Everything else is activity. The battery warning is a wake handled in `main.rs` (Task 5), not here.

- [ ] **Step 1: Write the failing tests** in `ui/tests/controller.rs`, using its existing fixture loader:

```rust
#[test]
fn fixtures_classify_as_wake_or_activity() {
    let wakes = ["question_single", "question_multi", "question_unicode", "reminder", "speak_start"];
    let activity = ["hello", "upsert", "state", "remove", "entry", "history", "creature", "transcript",
                    "reply_text", "speak_end", "session_reset", "question_clear"];
    for name in wakes {
        let f = fx(); // fresh controller per fixture
        f.c.on_message(&load(name));
        assert!(f.c.take_wake(), "{name} should wake");
        assert!(!f.c.take_wake(), "{name}: take_wake must clear");
    }
    for name in activity {
        let f = fx();
        f.c.on_message(&load(name));
        assert!(!f.c.take_wake(), "{name} should not wake");
    }
}

#[test]
fn link_returning_is_a_wake_but_dropping_is_not() {
    let f = fx();
    f.c.set_link(true);
    f.c.take_wake();
    f.c.set_link(false);
    assert!(!f.c.take_wake());
    f.c.set_link(true);
    assert!(f.c.take_wake());
    f.c.set_link(true); // already up
    assert!(!f.c.take_wake());
}

#[test]
fn question_waiting_follows_the_model() {
    let f = fx();
    assert!(!f.c.question_waiting());
    f.c.on_message(&load("question_single"));
    assert!(f.c.question_waiting());
    f.c.on_message(&load("question_clear"));
    assert!(!f.c.question_waiting());
}
```

If `question_single` alone does not create a waiting session in the model (it may need `upsert` first), feed the fixtures in the order the existing controller tests use and adjust only the setup, not the assertions. `new_session.json` is client-to-bridge and is excluded. The rule is "wake exactly when the controller chimes, plus `speak_start` and the link returning": if a fixture in the activity list (say `state` or `upsert` putting a session into a waiting state) makes today's controller chime, move it to the wake list rather than changing the rule.

- [ ] **Step 2:** Run host tests; expect compile failure (`take_wake` not defined).
- [ ] **Step 3:** Add a `wake: bool` field to the controller's inner state and implement the two methods as described.
- [ ] **Step 4:** Run host tests; expect PASS.
- [ ] **Step 5:** Commit: `git commit -m "feat(modules): cylon bot controller reports which bridge messages wake the panel"`.

---

### Task 3: Swallow the waking touch

**Files:**
- Modify: `firmware/cylon-bot/ui/src/touch.rs`
- Test: `firmware/cylon-bot/ui/tests/touch.rs`

**Interfaces:**
- Produces: `pub struct WakeGate` with `pub fn new() -> Self` and `pub fn pass(&mut self, dark: bool, pressed: bool) -> bool`. Returns false (drop the sample) from the first pressed sample seen while `dark` until and including the first released sample after it; true otherwise. The touch loop still marks the touch (so the panel wakes) for dropped samples.

- [ ] **Step 1: Write the failing tests.** Unit tests in `touch.rs`:

```rust
#[test]
fn the_waking_touch_is_dropped_until_lift() {
    let mut g = WakeGate::new();
    assert!(!g.pass(true, true));   // first touch on a dark panel
    assert!(!g.pass(false, true));  // panel now lit, same finger still down
    assert!(!g.pass(false, false)); // its lift
    assert!(g.pass(false, true));   // next touch lands
    assert!(g.pass(false, false));
}

#[test]
fn touches_while_lit_pass() {
    let mut g = WakeGate::new();
    assert!(g.pass(false, true));
    assert!(g.pass(false, false));
    assert!(g.pass(true, false)); // a release sample while dark with no finger down passes harmlessly
}
```

And a headless test in `ui/tests/touch.rs` that routes taps through the gate (add a `gated_tap(&self, gate: &mut WakeGate, dark: bool, x, y)` helper that only dispatches the press/release when `gate.pass` returns true):

```rust
#[test]
fn a_tap_on_a_dark_screen_wakes_and_answers_nothing() {
    let f = fx();
    let mut gate = WakeGate::new();
    f.ask("question_single");
    f.h.render();
    f.gated_tap(&mut gate, true, 233.0, 201.0); // the panel was dark: this tap only wakes it
    assert!(f.wire.0.borrow().is_empty());
    f.gated_tap(&mut gate, false, 233.0, 201.0);
    let sent = f.wire.0.borrow().clone();
    assert_eq!(sent.len(), 1);
    assert!(sent[0].contains(r#""Which colour?":"Red""#), "{}", sent[0]);
}
```

- [ ] **Step 2:** Run host tests; expect compile failure (`WakeGate` not defined).
- [ ] **Step 3:** Implement `WakeGate` (one `swallowing: bool`).
- [ ] **Step 4:** Run host tests; expect PASS.
- [ ] **Step 5:** Commit: `git commit -m "feat(modules): cylon bot ignores the touch that wakes a dark panel"`.

---

### Task 4: Chip power management and loop pacing

**Files:**
- Create: `firmware/cylon-bot/app/src/sleep.rs`
- Modify: `firmware/cylon-bot/app/sdkconfig.defaults`, `firmware/cylon-bot/app/src/main.rs`, `firmware/cylon-bot/app/src/platform.rs`, `firmware/cylon-bot/app/src/net.rs`

**Interfaces:**
- Produces (in `sleep.rs`):
  - `pub const LIGHT_SLEEP: bool = false;`
  - `pub fn configure() -> anyhow::Result<()>` — `esp_pm_configure` with `max_freq_mhz: 240, min_freq_mhz: 80, light_sleep_enable: LIGHT_SLEEP`.
  - `pub struct Awake` — holds two `esp_pm_lock_handle_t` (`ESP_PM_CPU_FREQ_MAX` and `ESP_PM_NO_LIGHT_SLEEP`); `pub fn new() -> anyhow::Result<Self>`, `pub fn hold(&mut self, on: bool)` (acquires both when going on, releases both when going off; idempotent). Held in every state except Dark, so capture, playback and rendering always run at 240 MHz and light sleep can only happen in Dark.
- In `platform.rs`: `pub fn set_dark(on: bool)` (an `AtomicBool DARK`, like the existing statics).

Note: the spec lists per-path locks for capture, playback and the panel push; capture and playback only happen outside Dark (both start from a touch or `speak_start`, which wake the panel), so the single "held outside Dark" lock covers them.

- [ ] **Step 1:** `sdkconfig.defaults`: add `CONFIG_PM_ENABLE=y` and `CONFIG_FREERTOS_USE_TICKLESS_IDLE=y`, each with a one-line comment pointing at the spec.
- [ ] **Step 2:** Write `sleep.rs` with `configure` and `Awake`. Call `sleep::configure()` early in `main`, create an `Awake`, `hold(true)` at boot.
- [ ] **Step 3:** `net.rs`: after Wi-Fi starts, `esp_wifi_set_ps(wifi_ps_type_t_WIFI_PS_MIN_MODEM)` with a comment saying why not max modem.
- [ ] **Step 4:** `platform.rs` pacing. Replace the flat `sleep(1 ms)` with: if `DARK`, sleep 50 ms and skip `draw_if_needed`; otherwise sleep until the next 20 ms touch poll, or less if `slint::platform::duration_until_next_timer_update()` is sooner (minimum 1 ms). Poll touch every 50 ms while Dark, 20 ms otherwise. Dark never sets yet (Task 5), so this task only changes Bright/Dim pacing.
- [ ] **Step 5:** Build: `nix develop -c just board build`. Expected: success.
- [ ] **Step 6 (board):** Flash and `just board monitor`: the eye sweep is smooth by eye, a tap and a voice hold and reply work as before, `heap:` margins similar to before. Record the 1 h battery numbers in the findings file under "after PM".
- [ ] **Step 7:** Commit: `git commit -m "feat(modules): cylon bot scales its clock down and stops spinning its loop"`.

---

### Task 5: Dark panel and deep sleep

**Files:**
- Modify: `firmware/cylon-bot/app/components/board_display/board_display.c` and its header, `firmware/cylon-bot/app/src/display.rs`, `firmware/cylon-bot/app/src/platform.rs`, `firmware/cylon-bot/app/src/main.rs`, `firmware/cylon-bot/app/src/sleep.rs`, `firmware/cylon-bot/app/src/net.rs`

**Interfaces:**
- Consumes: Task 1 `Power`, `State`, `Conditions`; Task 2 `take_wake`, `question_waiting`; Task 3 `WakeGate`; Task 4 `Awake`, `platform::set_dark`.
- Produces:
  - C: `esp_err_t bd_panel_power(bool on, uint8_t brightness)` (sequence from Global Constraints; the comment records the 120 ms sleep-out wait); `void bd_sleep_prepare(void)` (panel off, power amp pin low, `rtc_gpio_pullup_en` on GPIO 0 and 11, `esp_sleep_enable_ext1_wakeup(BIT64(0) | BIT64(11), ESP_EXT1_WAKEUP_ANY_LOW)`).
  - Rust: `display::panel_power(on: bool, brightness: u8) -> bool`; `sleep::log_wake_cause()` (logs `wake: touch` when ext1 status has bit 11, `wake: boot` for bit 0, `wake: reset` for an undefined cause, `wake: other` otherwise); `sleep::deep_sleep(net: Option<&net::Net>) -> !` (logs `sleep: deep`, `net.close()`, `bd_sleep_prepare()`, `esp_deep_sleep_start()`); `net::Net::close(&self)` — sends a websocket close frame with a 1 s timeout (`esp_websocket_client_close`), then stops Wi-Fi.

- [ ] **Step 1: platform.rs.** Feed each touch sample through a `WakeGate` with `dark = DARK.load()`: `TOUCHED` is still set for every pressed sample, but the sample reaches the tracker only when `gate.pass` is true. On the transition from dark to lit, call `window.request_redraw()` and push the whole buffer once (`strips.push(&pixels, 0, HEIGHT)`) after the next `draw_if_needed`, so the panel shows the current frame and not the one from before it went dark.
- [ ] **Step 2: C component and display.rs** as in Interfaces.
- [ ] **Step 3: main.rs.** Each 250 ms tick: if `controller.take_wake()` (also checked right after each `on_message` and `set_link`) or `read_battery` returned a warning, `power.wake_event(ms())`. Compute `state = power.state(ms())`; on change log `power: <state>`, and on entering Dark call `display::panel_power(false, 0)`, `platform::set_dark(true)`, `awake.hold(false)`; on leaving Dark `display::panel_power(true, power.brightness(ms()))`, `set_dark(false)`, `awake.hold(true)`. If `panel_power` returns false, retry once, then `esp_restart()`. Brightness changes between Bright and Dim stay as today. Keep the last battery `Reading` from `read_battery` (change it to also return the reading), build `Conditions::new(last_reading.as_ref(), controller.question_waiting(), player.is_playing() || capture.is_some())`, and call `sleep::deep_sleep(net.as_ref())` when `power.should_deep_sleep(ms(), &conditions)`. Call `sleep::log_wake_cause()` at boot.
- [ ] **Step 4:** Build: `nix develop -c just board build`. Expected: success.
- [ ] **Step 5 (board gate, record each pass/fail in the findings file):**
  1. Idle 2.5 min: `power: dark` and the panel is off; touch lights it and the touch does not open the list.
  2. A question sent while Dark lights the panel and chimes (send one from any Claude session).
  3. A reminder while Dark (`set a timer for one minute` by voice, then wait dark) lights it and is spoken.
  4. Unplugged, idle 12.5 min: `sleep: deep`; a touch wakes it (`wake: touch`). If not, BOOT does (`wake: boot`); if neither, set deep sleep off (comment in `sleep.rs` saying which check failed) and note it.
  5. On USB, idle 15 min: no `sleep: deep`.
  6. After a deep-sleep wake the board connects without `waiting for the clock` (the RTC kept time).
  7. A voice hold and reply work after waking from Dark.
  Record the 1 h battery numbers under "after Dark".
- [ ] **Step 6:** Commit: `git commit -m "feat(modules): cylon bot turns its panel off when idle and deep-sleeps on battery"`.

---

### Task 6: Light sleep gate and documentation

**Files:**
- Modify: `firmware/cylon-bot/app/src/sleep.rs`, `docs/superpowers/specs/2026-11-11-cylon-bot-power-findings.md`, `CLAUDE.md`

- [ ] **Step 1 (board):** Build with `LIGHT_SLEEP = true`, flash, and run the spec's light sleep gate: one hour in Dark with the websocket connected (no reconnect lines in the log), a question sent while Dark lights the panel within 1 s (time it against the hook's send), and a voice hold and reply afterwards work. Record battery numbers under "light sleep".
- [ ] **Step 2:** If all three passed, keep `LIGHT_SLEEP = true`; otherwise set it back to `false` with a comment naming the failed check. Record the outcome in the findings file.
- [ ] **Step 3:** CLAUDE.md, Cylon Bot section: add a **Power** bullet after "Battery": the three states and their timeouts; what wakes a dark panel and why activity does not; the waking touch is swallowed; deep sleep only on battery with no question waiting or audio, its wake sources as measured, and that waking is a reboot; PM 80–240 MHz with the frequency/no-light-sleep locks held outside Dark; the light sleep outcome; and what was and was not measured (link the findings file).
- [ ] **Step 4:** Commit: `git commit -m "docs(modules): cylon bot power findings and the power bullet"`.
