//! Settings passed in by the systemd units, and the fixed file paths.

use std::path::PathBuf;

use anyhow::{Result, bail};

pub const STATE_PATH: &str = "/var/lib/pia/state.json";
pub const WG_CONF_PATH: &str = "/run/pia/wg0.conf";
pub const PORT_FILE_PATH: &str = "/run/pia/forwarded-port";
pub const RUN_DIR: &str = "/run/pia";
pub const STATE_DIR: &str = "/var/lib/pia";

pub struct Config {
    pub credentials: PathBuf,
    pub region: String,
    pub ca_cert: PathBuf,
    pub namespace: String,
    pub hook: PathBuf,
    pub wg: PathBuf,
    pub ip: PathBuf,
    pub iptables: PathBuf,
    pub systemctl: PathBuf,
}

impl Config {
    pub fn from_env() -> Result<Config> {
        Self::from_lookup(|k| std::env::var(k).ok())
    }

    pub fn from_lookup(f: impl Fn(&str) -> Option<String>) -> Result<Config> {
        let get = |k: &str| match f(k) {
            Some(v) if !v.is_empty() => Ok(v),
            _ => bail!("environment variable {k} is not set"),
        };
        Ok(Config {
            credentials: get("PIA_CREDENTIALS")?.into(),
            region: get("PIA_REGION")?,
            ca_cert: get("PIA_CA_CERT")?.into(),
            namespace: get("PIA_NAMESPACE")?,
            hook: get("PIA_HOOK")?.into(),
            wg: get("PIA_WG")?.into(),
            ip: get("PIA_IP")?.into(),
            iptables: get("PIA_IPTABLES")?.into(),
            systemctl: get("PIA_SYSTEMCTL")?.into(),
        })
    }

    /// The tunnel interface VPN-Confinement creates inside the namespace.
    pub fn interface(&self) -> String {
        format!("{}0", self.namespace)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ALL: [&str; 9] = [
        "PIA_CREDENTIALS",
        "PIA_REGION",
        "PIA_CA_CERT",
        "PIA_NAMESPACE",
        "PIA_HOOK",
        "PIA_WG",
        "PIA_IP",
        "PIA_IPTABLES",
        "PIA_SYSTEMCTL",
    ];

    fn lookup_without(missing: &'static str) -> impl Fn(&str) -> Option<String> {
        move |k: &str| {
            if k == missing {
                None
            } else if k == "PIA_NAMESPACE" {
                Some("pia".into())
            } else {
                ALL.contains(&k).then(|| format!("/x/{k}"))
            }
        }
    }

    #[test]
    fn missing_env_var_is_named() {
        let err = Config::from_lookup(lookup_without("PIA_HOOK")).err().unwrap();
        assert!(err.to_string().contains("PIA_HOOK"));
    }

    #[test]
    fn interface_is_namespace_zero() {
        let cfg = Config::from_lookup(lookup_without("")).unwrap();
        assert_eq!(cfg.interface(), "pia0");
        assert_eq!(cfg.hook, PathBuf::from("/x/PIA_HOOK"));
    }
}
