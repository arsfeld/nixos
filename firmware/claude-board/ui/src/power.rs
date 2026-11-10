//! When the board is bright, when it dims, and how the picture wanders: an AMOLED panel that shows the same
//! bright pixels for days burns in, so the screen dims after a quiet spell and shifts by a few pixels.
//! Pure functions over a monotonic millisecond clock, tested on the host.

/// How long the screen stays awake after a touch or a change on screen.
pub const AWAKE_MS: i64 = 30_000;
pub const BRIGHT_AWAKE: u8 = 70;
pub const BRIGHT_IDLE: u8 = 8;
/// The picture moves within this many pixels of centre, in each direction.
const DRIFT_RANGE: i64 = 4;
const DRIFT_STEP_MS: i64 = 60_000;

#[derive(Debug, Clone, Copy)]
pub struct Power {
    last_touch_ms: i64,
    last_change_ms: i64,
}

impl Power {
    /// Awake at boot, for the usual 30 seconds.
    pub fn new(now_ms: i64) -> Self {
        Power { last_touch_ms: now_ms, last_change_ms: now_ms }
    }

    /// The screen was touched.
    pub fn touch(&mut self, now_ms: i64) {
        self.last_touch_ms = now_ms;
    }

    /// Something changed on screen that the user should see (a message from the bridge).
    pub fn model_changed(&mut self, now_ms: i64) {
        self.last_change_ms = now_ms;
    }

    pub fn awake(&self, now_ms: i64) -> bool {
        now_ms - self.last_touch_ms < AWAKE_MS || now_ms - self.last_change_ms < AWAKE_MS
    }

    pub fn brightness(&self, now_ms: i64) -> u8 {
        if self.awake(now_ms) { BRIGHT_AWAKE } else { BRIGHT_IDLE }
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
    fn awake_for_30_seconds_after_a_touch() {
        let mut p = Power::new(0);
        p.touch(100_000);
        assert!(p.awake(100_000));
        assert!(p.awake(129_999));
        assert!(!p.awake(130_000));
    }

    #[test]
    fn awake_for_30_seconds_after_a_model_change() {
        let mut p = Power::new(0);
        p.model_changed(200_000);
        assert!(p.awake(229_999));
        assert!(!p.awake(230_000));
    }

    #[test]
    fn a_touch_and_a_change_keep_it_awake_until_the_later_one_expires() {
        let mut p = Power::new(0);
        p.touch(100_000);
        p.model_changed(120_000);
        assert!(p.awake(149_999)); // 29.9 s after the change
        assert!(!p.awake(150_000));
    }

    #[test]
    fn awake_at_boot_then_idle() {
        let p = Power::new(5_000);
        assert!(p.awake(5_000));
        assert!(!p.awake(35_000));
    }

    #[test]
    fn awake_uses_brightness_70_and_idle_uses_brightness_8() {
        let mut p = Power::new(0);
        p.touch(1_000);
        assert_eq!(p.brightness(1_000), 70);
        assert_eq!(p.brightness(31_000), 8);
        assert_eq!((BRIGHT_AWAKE, BRIGHT_IDLE, AWAKE_MS), (70, 8, 30_000));
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
