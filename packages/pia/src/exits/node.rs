//! `pia exits node <slot>`: log a slot's tailscaled in and name it for its region.
//!
//! The auth key is the OAuth client secret with `?ephemeral=false&preauthorized=true`
//! appended, handed to `tailscale up` through a 0600 file in the unit's runtime
//! directory, never on a command line. Non-ephemeral on purpose: an ephemeral node comes
//! back after an outage as a new node, unsetting every client's choice of exit node.

use super::config::{ExitsConfig, SlotConfig};
use super::slots::read_region;
use crate::cmd;
use anyhow::{bail, Context, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// How long tailscaled gets to answer `status` after it starts.
const STATUS_WAIT: Duration = Duration::from_secs(30);

/// The tailnet hostname for a region id: `pia-` plus the id, lowercased, with anything
/// outside `[a-z0-9-]` turned into `-`.
pub fn hostname(region: &str) -> String {
    let id: String = region
        .chars()
        .map(|c| c.to_ascii_lowercase())
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '-' })
        .collect();
    format!("pia-{id}")
}

/// Whether `tailscale status --json` describes a node that is not logged in: the backend
/// says `NeedsLogin`, or there is no node key for this machine.
pub fn needs_login(status_json: &str) -> bool {
    let Ok(v) = serde_json::from_str::<Value>(status_json) else {
        return true;
    };
    if v["BackendState"].as_str() == Some("NeedsLogin") {
        return true;
    }
    v["Self"]["PublicKey"].as_str().is_none_or(str::is_empty)
}

fn tailscale(cfg: &ExitsConfig, slot: &SlotConfig, args: &[&str]) -> Result<String> {
    let socket = slot.socket.to_string_lossy();
    let mut all = vec!["--socket", &socket];
    all.extend_from_slice(args);
    cmd::stdout(&cfg.tailscale, &all, None)
}

/// `tailscale status --json` once it answers with a settled backend, for up to 30 s.
fn wait_status(cfg: &ExitsConfig, slot: &SlotConfig) -> Result<String> {
    let deadline = Instant::now() + STATUS_WAIT;
    loop {
        let res = tailscale(cfg, slot, &["status", "--json"]);
        let settled = res.as_ref().is_ok_and(|j| {
            serde_json::from_str::<Value>(j).is_ok_and(|v| v["BackendState"].as_str() != Some("NoState"))
        });
        if settled || Instant::now() >= deadline {
            return res.context("tailscaled did not answer status");
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn authkey_path() -> Result<PathBuf> {
    let dir = std::env::var("RUNTIME_DIRECTORY").context("RUNTIME_DIRECTORY is not set")?;
    let first = dir.split(':').next().unwrap_or_default();
    if first.is_empty() {
        bail!("RUNTIME_DIRECTORY is empty");
    }
    Ok(Path::new(first).join("authkey"))
}

fn login(cfg: &ExitsConfig, slot: &SlotConfig, name: &str) -> Result<()> {
    let secret = std::fs::read_to_string(&cfg.oauth_key)
        .with_context(|| format!("reading {}", cfg.oauth_key.display()))?;
    let key = format!("{}?ephemeral=false&preauthorized=true", secret.trim());
    let path = authkey_path()?;
    crate::state::write_atomic(&path, key.as_bytes(), 0o600)?;
    let auth = format!("--auth-key=file:{}", path.display());
    let host = format!("--hostname={name}");
    let res = tailscale(cfg, slot, &["up", &auth, &host, "--advertise-exit-node", "--advertise-tags=tag:service"]);
    let _ = std::fs::remove_file(&path);
    res.map(|_| ())
}

pub fn run(cfg: &ExitsConfig, slot: u8) -> Result<()> {
    let sc = cfg.slot(slot).with_context(|| format!("no slot {slot} in the config"))?;
    let Some((region, _)) = read_region(&sc.region_file) else {
        eprintln!("pia-exits: slot {slot} has no region, leaving its node alone");
        return Ok(());
    };
    let name = hostname(&region);
    let status = wait_status(cfg, sc)?;
    if needs_login(&status) {
        eprintln!("pia-exits: slot {slot} logging in as {name}");
        login(cfg, sc, &name).context("tailscale up")?;
    }
    tailscale(cfg, sc, &["set", "--advertise-exit-node", &format!("--hostname={name}")]).context("tailscale set")?;
    eprintln!("pia-exits: slot {slot} advertising as {name}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hostname_sanitised() {
        assert_eq!(hostname("br-so"), "pia-br-so");
        assert_eq!(hostname("us_new_york_city"), "pia-us-new-york-city");
        assert_eq!(hostname("CA"), "pia-ca");
    }

    #[test]
    fn needs_login_detected() {
        assert!(needs_login(r#"{"BackendState":"NeedsLogin","Self":{"PublicKey":""}}"#));
        assert!(needs_login(r#"{"BackendState":"Stopped"}"#));
        assert!(!needs_login(r#"{"BackendState":"Running","Self":{"PublicKey":"nodekey:abc"}}"#));
        assert!(!needs_login(r#"{"BackendState":"Stopped","Self":{"PublicKey":"nodekey:abc"}}"#));
    }
}
