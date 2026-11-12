# Cylon Bot power saving

Date: 2026-11-11. Firmware only (`firmware/cylon-bot`); no bridge or protocol change.

## Intent

The board usually sits on USB power but should also last when unplugged. Two outcomes:

1. **On USB:** the panel goes dark when nobody needs it, and the board stays online, so a Claude question or a
   reminder still lights it and chimes.
2. **On battery:** the same, and after a long idle it deep-sleeps; a touch wakes it. While it sleeps, questions fall
   through to the terminal and reminders wait on the bridge (delivered on reconnect if within its 60-minute window),
   exactly as when the board is unplugged.

Success: measurably lower draw in every state (numbers recorded in the findings file, see Measurement), no missed
wake for a question while online, and no accidental answer from a touch on a dark screen.

## Today

- `ui/src/power.rs`: brightness 70, dropping to 8 after 30 s without a touch or a bridge message; burn-in drift.
  The panel never turns off.
- The UI loop (`app/src/platform.rs`) wakes every 1 ms and redraws whenever an animation runs; the eye sweep always
  runs, so it renders continuously, even dimmed.
- CPU fixed at 240 MHz (`CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_240`), no `CONFIG_PM_ENABLE`, no tickless idle, Wi-Fi power
  save left at the ESP-IDF default.
- Battery (AXP2101) read every 30 s; `usb` and `percent` known.
- Touch interrupt is GPIO 11 (an RTC GPIO, usable for ext1 wake). Whether the CST9217 asserts it while idle has not
  been measured. BOOT is GPIO 0, also an RTC GPIO.

## Power states

| State | Panel | Rendering | Loop | Enters when |
|---|---|---|---|---|
| Bright | 70 % | normal | paced by the next due frame | a touch or a wake event |
| Dim | 8 % | normal | paced by the next due frame | 30 s with no touch and no activity |
| Dark | off (DCS 0x28, 0x10) | stopped | touch polled every 50 ms; bridge events handled | 2 min in Dim |
| Deep sleep | off | none | chip off, RTC only | 10 min in Dark, on battery, with no question waiting and no speech playing |

Constants: `AWAKE_MS` 30 000 (unchanged), `DIM_MS` 120 000, `DARK_TO_SLEEP_MS` 600 000.

Rules:

- **Wake events** light a Dark panel and return to Bright: touch, a new question or approval, a `reminder`,
  `speak_start`, a battery warning, and the bridge link coming back up after being down. **Activity** (every other
  bridge message, e.g. session status changes) restarts the 30 s timer while Bright or Dim, as today, but never
  lights a Dark panel; with several busy sessions it arrives every few seconds and would keep the panel on forever.
- **The first touch on a Dark panel only wakes it.** It is not delivered to Slint or the touch tracker; everything is
  dropped until that finger lifts. A tap meant to wake the board can never answer the question that woke it.
- **Deep sleep never happens on USB power, with a question waiting, while speech plays or a hold records, or when the
  battery read failed** (a failed read counts as USB).
- Waking from deep sleep is a full reboot. The RTC keeps system time through deep sleep, so if the clock is already
  plausible at boot the board does not wait for SNTP before connecting (SNTP still runs). Expect a few seconds of
  Wi-Fi and TLS before it is online.
- Burn-in drift continues in Bright and Dim.

## Chip power management (always on)

- `CONFIG_PM_ENABLE=y`, and `esp_pm_configure` with max 240 MHz, min 80 MHz. Timing-sensitive paths hold an
  `ESP_PM_CPU_FREQ_MAX` lock: microphone capture, speaker playback, and the panel push of a frame. With PM on, the
  IDF drivers (I2S, SPI/QSPI, Wi-Fi) take their own locks.
- `CONFIG_FREERTOS_USE_TICKLESS_IDLE=y`. `CONFIG_FREERTOS_HZ` stays 1000.
- The UI loop stops spinning at 1 ms: in Bright and Dim it sleeps until the earlier of the next frame Slint needs
  (`has_active_animations` / the timer deadline) and the next 20 ms touch poll; in Dark it sleeps 50 ms.
- Wi-Fi power save set explicitly to `WIFI_PS_MIN_MODEM`. Max modem sleep is not used: its added latency would show
  on answers and voice.
- **Automatic light sleep** (`light_sleep_enable` in `esp_pm_config_t`) is a gated step, off in the shipped
  configuration until the board gate passes: with it on, over one hour in Dark (1) the websocket stays connected,
  (2) a question sent while Dark lights the panel within 1 s, (3) a voice hold and reply afterwards work as before.
  If all three hold it ships on, enabled only while Dark. If not, it stays off and the findings file records which
  check failed.

## Components

- **`ui/src/power.rs`**: pure state machine. Inputs: `touch(now)`, `wake_event(now)`, `activity(now)` (today's
  `model_changed`), `conditions { usb, question_waiting, audio_busy }`, and the clock. Outputs: `state(now)`,
  `brightness(now)`, `should_deep_sleep(now)`. No hardware calls. `drift_px` unchanged.
- **`ui/src/controller.rs`**: classifies each bridge message as wake event or activity, and exposes
  `question_waiting()`.
- **`app/components/board_display/board_display.c`**: `bd_panel_power(bool on)`. Off: 0x28 display off, 0x10 sleep in.
  On: 0x11 sleep out, wait 120 ms, 0x29 display on, then restore brightness. The CO5300 timing is in its comment.
- **`app/src/platform.rs`**: in Dark skips `draw_if_needed`, polls touch every 50 ms, swallows the first touch until
  lift; paces the loop by the next due frame. On leaving Dark it forces a full repaint.
- **`app/src/sleep.rs`** (new): `esp_pm_configure`, the Wi-Fi power save setting, and deep sleep entry: close the
  websocket cleanly, mute the amp, panel off, arm ext1 on GPIO 11 (low) and GPIO 0 (low), `esp_deep_sleep_start`.
  At boot logs `wake: touch|boot|reset`.
- **`app/src/main.rs`**: wires the above; feeds battery `usb`, `question_waiting` and audio state into `Power`.
- **`app/sdkconfig.defaults`**: `CONFIG_PM_ENABLE`, `CONFIG_FREERTOS_USE_TICKLESS_IDLE`.

## Failure handling

- Panel fails to wake (DCS write error): retry once, then `esp_restart`. A board stuck dark is worse than a reboot.
- GPIO 11 does not wake the chip (found at the board gate): deep sleep wakes on BOOT only, and the docs say so. If
  neither wakes it, deep sleep is disabled.
- Battery read fails: treated as USB, so no deep sleep.
- No reconnect after a wake: the existing reconnect loop; the creature shows `offline`.

## Testing

- Host tests in `power.rs`: every transition and timeout; wake event vs activity in each state; deep sleep never on
  USB, never with a question waiting, never with audio busy; clocks that jump backwards or far forwards.
- Host test that every fixture in `packages/cylon-bot-bridge/tests/fixtures/board/` classifies as intended.
- Headless `ui` test: a tap on a Dark screen is swallowed and the next tap lands.

Board gate (`just board monitor`), each recorded as passed or failed:

1. A question while Dark lights the panel and chimes.
2. A reminder while Dark lights the panel and is spoken.
3. Touch wakes from deep sleep (`wake: touch`); otherwise BOOT does (`wake: boot`).
4. Unplugged and idle: deep sleep after 2.5 min to Dark plus 10 min.
5. Plugged back in while Dark: never deep-sleeps.
6. Voice hold and reply work with PM on.
7. The light sleep gate above.

## Measurement

Before any change and after each step (PM, loop pacing, Dark, light sleep), on battery: an hour per state with the
existing `battery:` log line (voltage and percent); on USB, current from a USB power meter if one is available.
Results go in `docs/superpowers/specs/2026-11-11-cylon-bot-power-findings.md`, like earlier probes.

## Documentation

A "Power" bullet in CLAUDE.md's Cylon Bot section: the states and timeouts, what wakes a Dark panel and why activity
does not, the wake sources from deep sleep, the light sleep outcome, and what was and was not measured.

## Out of scope

Timed wake from deep sleep for reminders (option C), night-hours schedules, an ambient light or presence sensor,
max modem sleep.
