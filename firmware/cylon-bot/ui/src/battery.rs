//! The battery, as the AXP2101 reports it: what the power page says about it, when home shows the low glyph, and
//! when the board chimes a warning. Pure, so it is tested on the host; the firmware reads the chip
//! (`bd_battery_read`) every `REFRESH` and feeds the result in.

use std::time::Duration;

/// How often the firmware reads the chip. Charge moves slowly; this only bounds how late a warning can be.
pub const REFRESH: Duration = Duration::from_secs(30);
/// At or below this, on battery, home shows the low glyph and the board chimes once.
pub const LOW_PERCENT: u8 = 15;
/// At or below this, on battery, it chimes once more.
pub const CRITICAL_PERCENT: u8 = 5;
/// The warnings re-arm only once the charge is back to this, or USB power returns, so a gauge that wobbles around
/// the threshold does not chime again every reading.
pub const REARM_PERCENT: u8 = 20;

/// One reading of the power chip.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Reading {
    /// A battery is connected.
    pub present: bool,
    /// USB power is present (the chip's VBUS-good bit).
    pub usb: bool,
    pub charging: bool,
    /// The chip's fuel gauge, 0 to 100; meaningless without a battery.
    pub percent: u8,
    pub millivolts: u16,
}

impl Reading {
    /// Running from the battery alone: the only case in which its level is a warning.
    pub fn on_battery(&self) -> bool {
        self.present && !self.usb
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Ok,
    Low,
    Critical,
}

/// How worried to be about this reading. Never low on USB power: it is charging or full.
pub fn level(r: &Reading) -> Level {
    match r {
        r if !r.on_battery() => Level::Ok,
        r if r.percent <= CRITICAL_PERCENT => Level::Critical,
        r if r.percent <= LOW_PERCENT => Level::Low,
        _ => Level::Ok,
    }
}

/// How many of the power page's four cells are lit: one per started quarter, none without a battery to measure.
pub fn cells(r: Option<&Reading>) -> u8 {
    match r {
        Some(r) if r.present => r.percent.min(100).div_ceil(25),
        _ => 0,
    }
}

/// The power page's big number: the charge, or "--" with no battery or no reading.
pub fn percent_text(r: Option<&Reading>) -> String {
    match r {
        Some(r) if r.present => r.percent.to_string(),
        _ => "--".into(),
    }
}

/// What runs the board. A board with no battery is running from USB, whatever the VBUS bit says.
pub fn source_text(r: Option<&Reading>) -> &'static str {
    match r {
        None => "--",
        Some(r) if r.on_battery() => "BATTERY",
        Some(_) => "USB",
    }
}

/// What the battery is doing. On battery the warning levels replace "DISCHARGING".
pub fn state_text(r: Option<&Reading>) -> &'static str {
    match r {
        None => "NO READING",
        Some(r) if !r.present => "NO BATTERY",
        Some(r) if r.charging => "CHARGING",
        Some(r) if r.usb && r.percent >= 100 => "FULL",
        Some(r) if r.usb => "NOT CHARGING",
        Some(r) => match level(r) {
            Level::Critical => "CRITICAL",
            Level::Low => "LOW",
            Level::Ok => "DISCHARGING",
        },
    }
}

/// The cell voltage, "3.92 V"; "--" with no battery or no reading.
pub fn voltage_text(r: Option<&Reading>) -> String {
    match r {
        Some(r) if r.present => format!("{:.2} V", r.millivolts as f32 / 1000.0),
        _ => "--".into(),
    }
}

/// Decides when to chime: once on dropping to `LOW_PERCENT`, once more on dropping to `CRITICAL_PERCENT`.
#[derive(Debug, Default)]
pub struct Warner {
    warned: Option<Level>,
}

impl Warner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Feed a reading; true when the board should chime now. An unreadable chip changes nothing.
    pub fn update(&mut self, r: Option<&Reading>) -> bool {
        let Some(r) = r else { return false };
        if !r.on_battery() || r.percent >= REARM_PERCENT {
            self.warned = None;
            return false;
        }
        let now = level(r);
        let fire = match (now, self.warned) {
            (Level::Ok, _) => false,
            (Level::Low, None) => true,
            (Level::Critical, None | Some(Level::Low)) => true,
            _ => false,
        };
        if fire {
            self.warned = Some(now);
        }
        fire
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn on_battery(percent: u8) -> Reading {
        Reading { present: true, usb: false, charging: false, percent, millivolts: 3700 }
    }

    fn on_usb(percent: u8, charging: bool) -> Reading {
        Reading { present: true, usb: true, charging, percent, millivolts: 4100 }
    }

    #[test]
    fn level_follows_the_thresholds_on_battery_only() {
        assert_eq!(level(&on_battery(16)), Level::Ok);
        assert_eq!(level(&on_battery(15)), Level::Low);
        assert_eq!(level(&on_battery(6)), Level::Low);
        assert_eq!(level(&on_battery(5)), Level::Critical);
        assert_eq!(level(&on_battery(0)), Level::Critical);
        assert_eq!(level(&on_usb(3, true)), Level::Ok, "plugged in is never low");
        let none = Reading { present: false, ..on_battery(0) };
        assert_eq!(level(&none), Level::Ok, "no battery: the gauge means nothing");
    }

    #[test]
    fn cells_light_one_per_started_quarter() {
        let lit: Vec<u8> = [0, 1, 25, 26, 50, 51, 75, 76, 100].iter().map(|&p| cells(Some(&on_battery(p)))).collect();
        assert_eq!(lit, [0, 1, 1, 2, 2, 3, 3, 4, 4]);
        assert_eq!(cells(None), 0);
        assert_eq!(cells(Some(&Reading { present: false, ..on_usb(80, false) })), 0, "no battery, nothing to fill");
    }

    #[test]
    fn the_power_page_says_what_powers_the_board() {
        let rows = |r: Option<&Reading>| (percent_text(r), source_text(r), state_text(r), voltage_text(r));
        assert_eq!(rows(None), ("--".into(), "--", "NO READING", "--".into()));
        let none = Reading { present: false, ..on_usb(0, false) };
        assert_eq!(rows(Some(&none)), ("--".into(), "USB", "NO BATTERY", "--".into()));
        assert_eq!(rows(Some(&on_usb(64, true))), ("64".into(), "USB", "CHARGING", "4.10 V".into()));
        assert_eq!(rows(Some(&on_usb(100, false))).2, "FULL");
        assert_eq!(rows(Some(&on_usb(80, false))).2, "NOT CHARGING");
        assert_eq!(rows(Some(&on_battery(87))), ("87".into(), "BATTERY", "DISCHARGING", "3.70 V".into()));
        assert_eq!(state_text(Some(&on_battery(15))), "LOW");
        assert_eq!(state_text(Some(&on_battery(5))), "CRITICAL");
    }

    #[test]
    fn warns_once_on_low_and_once_more_on_critical() {
        let mut w = Warner::new();
        let chimes: Vec<bool> = [40, 16, 15, 14, 15, 13, 6, 5, 4, 5, 2].iter().map(|&p| w.update(Some(&on_battery(p)))).collect();
        assert_eq!(chimes, [false, false, true, false, false, false, false, true, false, false, false]);
    }

    #[test]
    fn a_wobble_below_the_rearm_level_does_not_chime_again() {
        let mut w = Warner::new();
        assert!(w.update(Some(&on_battery(15))));
        for p in [16, 19, 15, 18, 14] {
            assert!(!w.update(Some(&on_battery(p))), "at {p}%");
        }
    }

    #[test]
    fn rearms_at_twenty_percent_or_on_usb() {
        let mut w = Warner::new();
        assert!(w.update(Some(&on_battery(15))));
        assert!(!w.update(Some(&on_battery(20))));
        assert!(w.update(Some(&on_battery(15))), "re-armed by recovering to 20%");
        assert!(!w.update(Some(&on_usb(15, true))));
        assert!(w.update(Some(&on_battery(14))), "re-armed by USB power");
    }

    #[test]
    fn starting_critical_chimes_once_not_twice() {
        let mut w = Warner::new();
        assert!(w.update(Some(&on_battery(4))));
        assert!(!w.update(Some(&on_battery(3))));
        assert!(!w.update(Some(&on_battery(12))), "climbing back to low does not warn again");
    }

    #[test]
    fn an_unreadable_chip_changes_nothing() {
        let mut w = Warner::new();
        assert!(w.update(Some(&on_battery(15))));
        assert!(!w.update(None));
        assert!(!w.update(Some(&on_battery(14))), "still warned");
    }

    #[test]
    fn plugged_in_at_low_charge_never_chimes() {
        let mut w = Warner::new();
        assert!(!w.update(Some(&on_usb(3, true))));
        assert!(!w.update(Some(&Reading { present: false, ..on_battery(0) })));
    }
}
