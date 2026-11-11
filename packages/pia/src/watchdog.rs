//! `pia watchdog`: nothing else notices a dead tunnel, since every unit stays active
//! while the namespace has no route out (on 2026-11-09 Transmission sat idle for 2.5
//! days). With PersistentKeepalive = 25 a live peer re-handshakes every 2 minutes, so
//! a handshake older than 5 minutes means the server is gone. Restarting the namespace
//! re-runs `connect`, which registers a fresh key on a server from the current list.

use anyhow::Result;

use crate::cmd;
use crate::config::Config;

/// A handshake older than this means the server is gone; also the grace given a fresh tunnel.
const STALE: i64 = 300;

#[derive(Debug, PartialEq)]
pub enum Verdict {
    Healthy,
    Restart(String),
}

/// The newest handshake in `wg show <if> latest-handshakes` output (0 when there is none).
pub fn latest_handshake(wg_output: &str) -> i64 {
    wg_output
        .lines()
        .filter_map(|l| l.split_whitespace().nth(1)?.parse().ok())
        .max()
        .unwrap_or(0)
}

pub fn decide(unit: &str, active: bool, active_since: Option<i64>, last_handshake: i64, now: i64) -> Verdict {
    if !active {
        return Verdict::Restart(format!("{unit} is not active"));
    }
    // Give a fresh tunnel time for its first handshake.
    if active_since.is_some_and(|t| now - t < STALE) {
        return Verdict::Healthy;
    }
    if now - last_handshake >= STALE {
        return Verdict::Restart(format!("last handshake {}s ago", now - last_handshake));
    }
    Verdict::Healthy
}

pub fn run(cfg: &Config) -> Result<()> {
    let unit = format!("{}.service", cfg.namespace);
    let now = chrono::Utc::now().timestamp();
    let active = cmd::succeeds(&cfg.systemctl, &["is-active", "--quiet", &unit]);
    let since = cmd::stdout(&cfg.systemctl, &["show", "-P", "ActiveEnterTimestamp", "--timestamp=unix", &unit], None)
        .ok()
        .and_then(|s| s.strip_prefix('@')?.parse().ok());
    let in_grace = since.is_some_and(|t: i64| now - t < STALE);
    let last = if active && !in_grace {
        let wg = cfg.wg.to_string_lossy();
        let iface = cfg.interface();
        let args = ["netns", "exec", &cfg.namespace, &wg, "show", &iface, "latest-handshakes"];
        latest_handshake(&cmd::stdout(&cfg.ip, &args, None).unwrap_or_default())
    } else {
        0
    };
    if let Verdict::Restart(reason) = decide(&unit, active, since, last, now) {
        eprintln!("pia-watchdog: {reason}; restarting {unit}");
        cmd::run(&cfg.systemctl, &["restart", &unit])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const U: &str = "pia.service";

    #[test]
    fn handshake_takes_max_over_peers() {
        assert_eq!(latest_handshake("PUB1\t100\nPUB2\t250\n"), 250);
    }

    #[test]
    fn handshake_empty_is_zero() {
        assert_eq!(latest_handshake(""), 0);
    }

    #[test]
    fn inactive_restarts() {
        assert_eq!(decide(U, false, None, 0, 1000), Verdict::Restart("pia.service is not active".into()));
    }

    #[test]
    fn grace_after_start() {
        assert_eq!(decide(U, true, Some(900), 0, 1000), Verdict::Healthy);
    }

    #[test]
    fn fresh_handshake_is_healthy() {
        assert_eq!(decide(U, true, Some(0), 800, 1000), Verdict::Healthy);
    }

    #[test]
    fn stale_handshake_restarts() {
        assert_eq!(decide(U, true, Some(0), 700, 1000), Verdict::Restart("last handshake 300s ago".into()));
    }

    #[test]
    fn never_handshaked_restarts() {
        assert_eq!(decide(U, true, Some(0), 0, 1000), Verdict::Restart("last handshake 1000s ago".into()));
    }
}
