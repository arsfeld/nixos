//! `PIA_EXITS_CONFIG`: the JSON file nix renders for `pia exits serve` and `pia exits node`.

use anyhow::{bail, Context, Result};
use serde::Deserialize;
use std::path::PathBuf;

#[derive(Deserialize, Debug, Clone)]
pub struct ExitsConfig {
    pub listen: String,
    pub ip: PathBuf,
    pub wg: PathBuf,
    pub systemctl: PathBuf,
    pub tailscale: PathBuf,
    pub curl: PathBuf,
    pub oauth_key: PathBuf,
    pub slots: Vec<SlotConfig>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct SlotConfig {
    pub slot: u8,
    pub namespace: String,
    pub interface: String,
    pub target: String,
    pub socket: PathBuf,
    pub region_file: PathBuf,
    pub port: u16,
}

impl ExitsConfig {
    pub fn from_env() -> Result<ExitsConfig> {
        let path = std::env::var("PIA_EXITS_CONFIG").context("PIA_EXITS_CONFIG is not set")?;
        let json = std::fs::read_to_string(&path).with_context(|| format!("reading {path}"))?;
        Self::parse(&json).with_context(|| format!("parsing {path}"))
    }

    /// Slots must be listed as 1, 2, … in order: the API addresses them by position.
    pub fn parse(json: &str) -> Result<ExitsConfig> {
        let cfg: ExitsConfig = serde_json::from_str(json)?;
        for (i, s) in cfg.slots.iter().enumerate() {
            if usize::from(s.slot) != i + 1 {
                bail!("slot {} is listed at position {}; slots must be 1, 2, … in order", s.slot, i + 1);
            }
        }
        Ok(cfg)
    }

    pub fn slot(&self, n: u8) -> Option<&SlotConfig> {
        self.slots.iter().find(|s| s.slot == n)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{
      "listen": "127.0.0.1:8592",
      "ip": "/bin/ip", "wg": "/bin/wg", "systemctl": "/bin/systemctl",
      "tailscale": "/bin/tailscale", "curl": "/bin/curl",
      "oauth_key": "/run/secrets/tailscale-key",
      "slots": [
        {"slot": 1, "namespace": "piax1", "interface": "piax1", "target": "pia-exit-1.target",
         "socket": "/run/tailscale-piax1/tailscaled.sock", "region_file": "/var/lib/pia-exits/slot-1", "port": 41642},
        {"slot": 2, "namespace": "piax2", "interface": "piax2", "target": "pia-exit-2.target",
         "socket": "/run/tailscale-piax2/tailscaled.sock", "region_file": "/var/lib/pia-exits/slot-2", "port": 41643}
      ]
    }"#;

    #[test]
    fn config_round_trips() {
        let c = ExitsConfig::parse(SAMPLE).unwrap();
        assert_eq!(c.listen, "127.0.0.1:8592");
        assert_eq!(c.slots.len(), 2);
        assert_eq!(c.slots[1].slot, 2);
        assert_eq!(c.slots[1].namespace, "piax2");
        assert_eq!(c.slots[1].port, 41643);
        assert_eq!(c.oauth_key, PathBuf::from("/run/secrets/tailscale-key"));
    }

    #[test]
    fn slots_out_of_order_rejected() {
        let swapped = SAMPLE.replace("\"slot\": 1,", "\"slot\": 9,");
        assert!(ExitsConfig::parse(&swapped).is_err());
    }

    #[test]
    fn missing_field_rejected() {
        assert!(ExitsConfig::parse(r#"{"listen":"x"}"#).is_err());
    }
}
