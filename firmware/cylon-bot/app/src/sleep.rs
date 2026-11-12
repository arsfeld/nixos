//! The chip's power management: the clock scales between 80 and 240 MHz, and (once measured, see `LIGHT_SLEEP`)
//! automatic light sleep. Spec: docs/superpowers/specs/2026-11-11-cylon-bot-power-design.md.

use esp_idf_svc::sys::{
    esp_deep_sleep_start, esp_sleep_get_ext1_wakeup_status, esp_sleep_get_wakeup_cause,
    esp_sleep_source_t_ESP_SLEEP_WAKEUP_EXT1, esp_sleep_source_t_ESP_SLEEP_WAKEUP_UNDEFINED,
    esp, esp_pm_config_t, esp_pm_configure, esp_pm_lock_acquire, esp_pm_lock_create, esp_pm_lock_handle_t,
    esp_pm_lock_release, esp_pm_lock_type_t_ESP_PM_CPU_FREQ_MAX, esp_pm_lock_type_t_ESP_PM_NO_LIGHT_SLEEP,
};

/// Automatic light sleep while the panel is dark. Off until the board gate in the spec passes: with it on the
/// websocket must survive an hour dark, a question must light the panel within 1 s, and voice must still work.
pub const LIGHT_SLEEP: bool = false;

pub fn configure() -> anyhow::Result<()> {
    let config = esp_pm_config_t { max_freq_mhz: 240, min_freq_mhz: 80, light_sleep_enable: LIGHT_SLEEP };
    esp!(unsafe { esp_pm_configure(&config as *const esp_pm_config_t as *const _) })?;
    log::info!("pm: 80-240 MHz, light sleep {}", if LIGHT_SLEEP { "on" } else { "off" });
    Ok(())
}

/// Full speed and no light sleep, held in every power state but Dark. Capture, playback and rendering only happen
/// while the panel is lit (a hold starts with a touch, a reply with `speak_start`, both of which light it), so this
/// one hold covers them all.
pub struct Awake {
    freq: esp_pm_lock_handle_t,
    no_sleep: esp_pm_lock_handle_t,
    held: bool,
}

impl Awake {
    pub fn new() -> anyhow::Result<Self> {
        let mut freq: esp_pm_lock_handle_t = core::ptr::null_mut();
        let mut no_sleep: esp_pm_lock_handle_t = core::ptr::null_mut();
        esp!(unsafe { esp_pm_lock_create(esp_pm_lock_type_t_ESP_PM_CPU_FREQ_MAX, 0, c"awake-freq".as_ptr(), &mut freq) })?;
        esp!(unsafe { esp_pm_lock_create(esp_pm_lock_type_t_ESP_PM_NO_LIGHT_SLEEP, 0, c"awake-nosleep".as_ptr(), &mut no_sleep) })?;
        Ok(Awake { freq, no_sleep, held: false })
    }

    /// Hold or let go of full speed; calling it twice the same way does nothing.
    pub fn hold(&mut self, on: bool) {
        if on == self.held {
            return;
        }
        self.held = on;
        unsafe {
            if on {
                esp_pm_lock_acquire(self.freq);
                esp_pm_lock_acquire(self.no_sleep);
            } else {
                esp_pm_lock_release(self.no_sleep);
                esp_pm_lock_release(self.freq);
            }
        }
    }
}

/// Say why the chip started: a touch or BOOT out of deep sleep, or an ordinary reset.
pub fn log_wake_cause() {
    let cause = unsafe { esp_sleep_get_wakeup_cause() };
    let what = if cause == esp_sleep_source_t_ESP_SLEEP_WAKEUP_EXT1 {
        let pins = unsafe { esp_sleep_get_ext1_wakeup_status() };
        if pins & (1 << 11) != 0 { "touch" } else if pins & 1 != 0 { "boot" } else { "other" }
    } else if cause == esp_sleep_source_t_ESP_SLEEP_WAKEUP_UNDEFINED {
        "reset"
    } else {
        "other"
    };
    log::info!("wake: {what}");
}

/// Leave the bridge, turn everything off and deep-sleep until a touch or BOOT. Waking is a reboot.
pub fn deep_sleep(net: Option<&crate::net::Net>) -> ! {
    log::info!("sleep: deep");
    if let Some(net) = net {
        net.close();
    }
    crate::display::sleep_prepare();
    unsafe { esp_deep_sleep_start() }
}
