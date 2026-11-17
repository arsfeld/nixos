//! Settings passed in by the systemd units, and the per-instance file paths.

use std::path::PathBuf;

use anyhow::{Context, Result, bail};

const DEFAULT_RUN_DIR: &str = "/run/pia";
const DEFAULT_STATE_DIR: &str = "/var/lib/pia";

pub struct Config {
    pub credentials: PathBuf,
    pub region: String,
    pub run_dir: PathBuf,
    pub state_dir: PathBuf,
    pub port_forward: bool,
    pub ca_cert: PathBuf,
    pub namespace: String,
    /// Consumer hook; present exactly when port forwarding is on.
    pub hook: Option<PathBuf>,
    pub wg: PathBuf,
    pub ip: PathBuf,
    /// Opens the forwarded port; present exactly when port forwarding is on.
    pub iptables: Option<PathBuf>,
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
        let set = |k: &str| f(k).filter(|v| !v.is_empty());
        let port_forward = match set("PIA_PORT_FORWARD").as_deref() {
            None | Some("1") => true,
            Some("0") => false,
            Some(other) => bail!("PIA_PORT_FORWARD must be 0 or 1, got '{other}'"),
        };
        let region = match (set("PIA_REGION"), set("PIA_REGION_FILE")) {
            (Some(r), None) => r,
            (None, Some(file)) => {
                let text = std::fs::read_to_string(&file).with_context(|| format!("reading PIA_REGION_FILE {file}"))?;
                let text = text.trim();
                if text.is_empty() {
                    bail!("PIA_REGION_FILE {file} is empty");
                }
                text.to_string()
            }
            (Some(_), Some(_)) => bail!("set only one of PIA_REGION and PIA_REGION_FILE"),
            (None, None) => bail!("environment variable PIA_REGION (or PIA_REGION_FILE) is not set"),
        };
        let (hook, iptables) = if port_forward {
            (Some(get("PIA_HOOK")?.into()), Some(get("PIA_IPTABLES")?.into()))
        } else {
            (set("PIA_HOOK").map(PathBuf::from), set("PIA_IPTABLES").map(PathBuf::from))
        };
        Ok(Config {
            credentials: get("PIA_CREDENTIALS")?.into(),
            region,
            run_dir: set("PIA_RUN_DIR").unwrap_or_else(|| DEFAULT_RUN_DIR.into()).into(),
            state_dir: set("PIA_STATE_DIR").unwrap_or_else(|| DEFAULT_STATE_DIR.into()).into(),
            port_forward,
            ca_cert: get("PIA_CA_CERT")?.into(),
            namespace: get("PIA_NAMESPACE")?,
            hook,
            wg: get("PIA_WG")?.into(),
            ip: get("PIA_IP")?.into(),
            iptables,
            systemctl: get("PIA_SYSTEMCTL")?.into(),
        })
    }

    pub fn wg_conf_path(&self) -> PathBuf {
        self.run_dir.join("wg0.conf")
    }

    pub fn port_file_path(&self) -> PathBuf {
        self.run_dir.join("forwarded-port")
    }

    pub fn state_path(&self) -> PathBuf {
        self.state_dir.join("state.json")
    }

    /// The tunnel interface VPN-Confinement creates inside the namespace.
    pub fn interface(&self) -> String {
        format!("{}0", self.namespace)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

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

    /// The full default environment with `set` applied on top; `None` removes a key.
    fn env(set: &[(&str, Option<&str>)]) -> impl Fn(&str) -> Option<String> {
        let mut m: HashMap<String, String> = ALL
            .iter()
            .map(|k| (k.to_string(), if *k == "PIA_NAMESPACE" { "pia".into() } else { format!("/x/{k}") }))
            .collect();
        for (k, v) in set {
            match v {
                Some(v) => m.insert(k.to_string(), v.to_string()),
                None => m.remove(*k),
            };
        }
        move |k: &str| m.get(k).cloned()
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
        assert_eq!(cfg.hook, Some(PathBuf::from("/x/PIA_HOOK")));
    }

    #[test]
    fn default_paths_unchanged() {
        let cfg = Config::from_lookup(env(&[])).unwrap();
        assert_eq!(cfg.wg_conf_path(), PathBuf::from("/run/pia/wg0.conf"));
        assert_eq!(cfg.port_file_path(), PathBuf::from("/run/pia/forwarded-port"));
        assert_eq!(cfg.state_path(), PathBuf::from("/var/lib/pia/state.json"));
        assert!(cfg.port_forward);
    }

    #[test]
    fn custom_dirs_honoured() {
        let cfg = Config::from_lookup(env(&[
            ("PIA_RUN_DIR", Some("/run/pia-x1")),
            ("PIA_STATE_DIR", Some("/var/lib/pia-x1")),
        ]))
        .unwrap();
        assert_eq!(cfg.wg_conf_path(), PathBuf::from("/run/pia-x1/wg0.conf"));
        assert_eq!(cfg.state_path(), PathBuf::from("/var/lib/pia-x1/state.json"));
    }

    #[test]
    fn region_from_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("region");
        std::fs::write(&file, "br-so\n").unwrap();
        let cfg = Config::from_lookup(env(&[
            ("PIA_REGION", None),
            ("PIA_REGION_FILE", Some(file.to_str().unwrap())),
        ]))
        .unwrap();
        assert_eq!(cfg.region, "br-so");
    }

    #[test]
    fn region_both_or_neither_is_error() {
        let both = Config::from_lookup(env(&[("PIA_REGION_FILE", Some("/x/f"))])).err().unwrap();
        assert!(both.to_string().contains("only one"), "{both}");
        let neither = Config::from_lookup(env(&[("PIA_REGION", None)])).err().unwrap();
        assert!(neither.to_string().contains("PIA_REGION"), "{neither}");
    }

    #[test]
    fn hook_optional_without_port_forward() {
        let cfg = Config::from_lookup(env(&[
            ("PIA_PORT_FORWARD", Some("0")),
            ("PIA_HOOK", None),
            ("PIA_IPTABLES", None),
        ]))
        .unwrap();
        assert!(!cfg.port_forward);
        assert_eq!(cfg.hook, None);
        assert_eq!(cfg.iptables, None);
    }

    #[test]
    fn hook_required_with_port_forward() {
        let err = Config::from_lookup(env(&[("PIA_HOOK", None)])).err().unwrap();
        assert!(err.to_string().contains("PIA_HOOK"), "{err}");
    }

    #[test]
    fn bad_port_forward_value_is_error() {
        let err = Config::from_lookup(env(&[("PIA_PORT_FORWARD", Some("yes"))])).err().unwrap();
        assert!(err.to_string().contains("PIA_PORT_FORWARD"), "{err}");
    }
}
