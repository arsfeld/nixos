//! When the board is bright, when it dims, when its panel goes dark, and when (on battery) it may deep-sleep. An
//! AMOLED panel that shows the same bright pixels for days burns in, so the screen dims after a quiet spell, goes
//! dark after a longer one, and shifts by a few pixels. Spec: docs/superpowers/specs/2026-11-11-cylon-bot-power-design.md.
//! Pure functions over a monotonic millisecond clock, tested on the host.

use crate::battery;

/// How long the screen stays bright after a touch, a wake event or activity.
pub const AWAKE_MS: i64 = 30_000;
/// How long it then stays dim before the panel goes dark.
pub const DIM_MS: i64 = 120_000;
/// How long the panel stays dark before the board may deep-sleep (on battery only).
pub const DARK_TO_SLEEP_MS: i64 = 600_000;
pub const BRIGHT_AWAKE: u8 = 70;
pub const BRIGHT_IDLE: u8 = 8;
/// The picture moves within this many pixels of centre, in each direction.
const DRIFT_RANGE: i64 = 4;
const DRIFT_STEP_MS: i64 = 60_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Bright,
    Dim,
    /// The panel is off and nothing is drawn; the board stays online.
    Dark,
}

/// What, besides the clock, decides whether the board may deep-sleep.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Conditions {
    pub on_battery: bool,
    pub question_waiting: bool,
    /// Speech playing or a hold recording.
    pub audio_busy: bool,
}

impl Conditions {
    /// A failed battery read (`None`) counts as USB power: never deep-sleep on a guess.
    pub fn new(reading: Option<&battery::Reading>, question_waiting: bool, audio_busy: bool) -> Self {
        Conditions { on_battery: reading.is_some_and(|r| r.on_battery()), question_waiting, audio_busy }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Power {
    /// The latest touch, wake event, or activity seen while the panel was lit.
    last_ms: i64,
}

impl Power {
    /// Bright at boot, for the usual 30 seconds.
    pub fn new(now_ms: i64) -> Self {
        Power { last_ms: now_ms }
    }

    /// The screen was touched.
    pub fn touch(&mut self, now_ms: i64) {
        self.last_ms = now_ms;
    }

    /// Something the user should notice even with the panel dark: a question, a reminder, a spoken reply, a
    /// battery warning, the link coming back.
    pub fn wake_event(&mut self, now_ms: i64) {
        self.last_ms = now_ms;
    }

    /// Anything else from the bridge: keeps a lit panel lit, but never lights a dark one (with busy sessions it
    /// arrives every few seconds and would keep the panel on for good).
    pub fn activity(&mut self, now_ms: i64) {
        if self.state(now_ms) != State::Dark {
            self.last_ms = now_ms;
        }
    }

    fn elapsed(&self, now_ms: i64) -> i64 {
        now_ms.saturating_sub(self.last_ms)
    }

    pub fn state(&self, now_ms: i64) -> State {
        let e = self.elapsed(now_ms);
        if e < AWAKE_MS {
            State::Bright
        } else if e < AWAKE_MS + DIM_MS {
            State::Dim
        } else {
            State::Dark
        }
    }

    /// The panel brightness for a lit panel; a dark one is switched off rather than set to 0.
    pub fn brightness(&self, now_ms: i64) -> u8 {
        if self.state(now_ms) == State::Bright { BRIGHT_AWAKE } else { BRIGHT_IDLE }
    }

    /// Long enough in the dark, on battery, with nothing that needs the board awake.
    pub fn should_deep_sleep(&self, now_ms: i64, c: &Conditions) -> bool {
        self.elapsed(now_ms) >= AWAKE_MS + DIM_MS + DARK_TO_SLEEP_MS
            && c.on_battery
            && !c.question_waiting
            && !c.audio_busy
    }
}

/// Offset in pixels to draw everything at, changing once a minute and wandering over a 9 x 9 grid.
pub fn drift_px(now_ms: i64) -> (i32, i32) {
    let step = now_ms.div_euclid(DRIFT_STEP_MS);
    let span = 2 * DRIFT_RANGE + 1;
    // Coprime strides visit most of the grid before repeating.
    let x = (step.wrapping_mul(7)).rem_euclid(span) - DRIFT_RANGE;
    let y = (step.wrapping_mul(5).wrapping_add(step / span)).rem_euclid(span) - DRIFT_RANGE;
    (x as i32, y as i32)
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let bat = battery::Reading { usb: false, ..usb };
        assert!(p.should_deep_sleep(10_000_000, &Conditions::new(Some(&bat), false, false)));
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
        let _ = p.state(i64::MAX); // no overflow panic
    }

    #[test]
    fn brightness_follows_the_state() {
        let p = Power::new(0);
        assert_eq!(p.brightness(0), 70);
        assert_eq!(p.brightness(30_000), 8);
        assert_eq!((AWAKE_MS, DIM_MS, DARK_TO_SLEEP_MS), (30_000, 120_000, 600_000));
    }

    #[test]
    fn drift_stays_within_four_pixels_over_a_day() {
        let mut seen = std::collections::HashSet::new();
        for t in (0..86_400_000i64).step_by(7_000) {
            let (x, y) = drift_px(t);
            assert!((-4..=4).contains(&x) && (-4..=4).contains(&y), "({x},{y}) at {t} ms");
            seen.insert((x, y));
        }
        assert!(seen.len() >= 20, "the picture should wander, saw {} positions", seen.len());
    }

    #[test]
    fn drift_moves_slowly_not_every_frame() {
        let start = drift_px(0);
        for t in (0..59_000).step_by(1_000) {
            assert_eq!(drift_px(t), start, "moved within the first minute at {t} ms");
        }
    }

    #[test]
    fn drift_handles_negative_and_huge_clocks() {
        let _ = drift_px(-1);
        let _ = drift_px(i64::MAX);
        let (x, y) = drift_px(i64::MIN);
        assert!((-4..=4).contains(&x) && (-4..=4).contains(&y));
    }
}
