//! `pia portforward` (inside the namespace): acquire or reuse the port-forward
//! signature, bind it (PIA drops a binding not refreshed within 15 minutes), publish
//! the port, open it on the tunnel interface, and notify consumers when it changes.

use std::path::Path;

use anyhow::{Context, Result};
use base64::Engine;
use serde::Deserialize;

use crate::config::{Config, PORT_FILE_PATH, RUN_DIR, STATE_PATH};
use crate::state::{self, State};
use crate::{api, cmd, log};

/// Renew a signature this long before PIA's expiry.
const RENEW_MARGIN: i64 = 86_400;

/// True unless a payload and signature are cached and expire more than a day from `now`.
/// An unparseable expiry counts as expired.
pub fn needs_signature(s: &State, now: i64) -> bool {
    let (Some(_), Some(_), Some(expires)) = (&s.payload, &s.signature, &s.expires_at) else {
        return true;
    };
    match chrono::DateTime::parse_from_rfc3339(expires.trim()) {
        Ok(t) => t.timestamp() <= now + RENEW_MARGIN,
        Err(_) => true,
    }
}

/// The payload is base64 JSON carrying the assigned port and its expiry.
pub fn decode_payload(payload: &str) -> Result<(u16, String)> {
    #[derive(Deserialize)]
    struct Payload {
        port: u16,
        expires_at: String,
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(payload.trim())
        .context("port-forward payload is not base64")?;
    let p: Payload = serde_json::from_slice(&bytes).context("port-forward payload is not the expected JSON")?;
    Ok((p.port, p.expires_at))
}

/// On a port change: retire the old port's rules, notify consumers, and only then
/// record `applied_port`, so a failed notification is retried on the next run.
/// Returns whether the port changed.
pub fn apply_port(
    state: &mut State,
    port: u16,
    mut retire: impl FnMut(u16),
    mut notify: impl FnMut(u16) -> Result<()>,
) -> Result<bool> {
    if state.applied_port == Some(port) {
        return Ok(false);
    }
    if let Some(old) = state.applied_port {
        retire(old);
    }
    notify(port)?;
    state.applied_port = Some(port);
    Ok(true)
}

fn rule<'a>(op: &'a str, iface: &'a str, proto: &'a str, port: &'a str) -> [&'a str; 10] {
    [op, "INPUT", "-i", iface, "-p", proto, "--dport", port, "-j", "ACCEPT"]
}

pub fn run(cfg: &Config) -> Result<()> {
    let state_path = Path::new(STATE_PATH);
    let mut st = state::load(state_path)?;
    if st.is_empty() {
        anyhow::bail!("no state yet (connect not run)");
    }
    let (Some(token), Some(gateway), Some(hostname)) = (st.token.clone(), st.pf_gateway.clone(), st.pf_hostname.clone())
    else {
        anyhow::bail!("state is missing token, pf_gateway or pf_hostname (connect not run)");
    };
    let ca = std::fs::read(&cfg.ca_cert).context("reading the PIA CA certificate")?;
    let iface = cfg.interface();

    // The namespace's accessibleFrom 10.0.0.0/8 route (to the host bridge) would capture
    // the PF gateway VIP and PIA's tunnel DNS servers (both in 10/8) and send them out
    // the veth. Pin each as a /32 through the tunnel so the more specific route wins.
    let dns = st.dns_servers.clone().unwrap_or_default();
    for host in std::iter::once(&gateway).chain(dns.iter().filter(|d| !d.is_empty())) {
        cmd::run(&cfg.ip, &["route", "replace", &format!("{host}/32"), "dev", &iface])?;
    }

    let now = chrono::Utc::now().timestamp();
    let (payload, signature) = if needs_signature(&st, now) {
        log("requesting new port-forward signature");
        let sig = api::get_signature(&ca, &hostname, &gateway, &token)?;
        (sig.payload, sig.signature)
    } else {
        (st.payload.clone().unwrap_or_default(), st.signature.clone().unwrap_or_default())
    };
    let (port, expires_at) = decode_payload(&payload)?;

    log(&format!("binding port {port}"));
    api::bind_port(&ca, &hostname, &gateway, &payload, &signature)?;

    st.payload = Some(payload);
    st.signature = Some(signature);
    st.expires_at = Some(expires_at);
    st.port = Some(port);
    state::save(state_path, &st)?;

    std::fs::create_dir_all(RUN_DIR)?;
    state::write_atomic(Path::new(PORT_FILE_PATH), format!("{port}\n").as_bytes(), 0o644)?;

    // Open the peer port on every run, not only on a change: restarting the namespace
    // wipes its firewall while applied_port persists, so a change-gated rule would stay
    // closed after every restart. -C first keeps this idempotent.
    let port_s = port.to_string();
    for proto in ["tcp", "udp"] {
        if !cmd::succeeds(&cfg.iptables, &rule("-C", &iface, proto, &port_s)) {
            cmd::run(&cfg.iptables, &rule("-A", &iface, proto, &port_s))?;
        }
    }

    let previous = st.applied_port;
    let changed = apply_port(
        &mut st,
        port,
        |old| {
            let old = old.to_string();
            for proto in ["tcp", "udp"] {
                cmd::succeeds(&cfg.iptables, &rule("-D", &iface, proto, &old));
            }
        },
        |p| {
            let old = previous.map_or_else(|| "none".to_string(), |o| o.to_string());
            log(&format!("forwarded port changed {old} -> {p}; dispatching consumers"));
            cmd::run(&cfg.hook, &[&p.to_string()]).context("consumer hook failed")
        },
    )?;
    if changed {
        state::save(state_path, &st)?;
    } else {
        log(&format!("port unchanged ({port}); rebind kept alive"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use anyhow::bail;
    use base64::Engine;

    /// 2026-01-01T00:00:00Z
    const NOW: i64 = 1_767_225_600;

    fn rfc3339(secs: i64) -> String {
        chrono::DateTime::from_timestamp(secs, 0).unwrap().to_rfc3339()
    }

    fn signed(expires_at: &str) -> State {
        State {
            payload: Some("p".into()),
            signature: Some("s".into()),
            expires_at: Some(expires_at.into()),
            ..Default::default()
        }
    }

    #[test]
    fn missing_fields_need_signature() {
        assert!(needs_signature(&State::default(), NOW));
        let mut s = signed(&rfc3339(NOW + 10 * 86_400));
        s.signature = None;
        assert!(needs_signature(&s, NOW));
    }

    #[test]
    fn expiry_within_a_day_renews() {
        assert!(needs_signature(&signed(&rfc3339(NOW + 86_000)), NOW));
    }

    #[test]
    fn expiry_beyond_a_day_keeps() {
        assert!(!needs_signature(&signed(&rfc3339(NOW + 86_401)), NOW));
    }

    #[test]
    fn nanosecond_expiry_is_valid() {
        assert!(!needs_signature(&signed("2027-01-10T12:00:00.123456789Z"), NOW));
    }

    #[test]
    fn unparseable_expiry_renews() {
        assert!(needs_signature(&signed("garbage"), NOW));
    }

    #[test]
    fn payload_decodes() {
        let p = base64::engine::general_purpose::STANDARD
            .encode(r#"{"token":"x","port":51234,"expires_at":"2027-01-10T12:00:00Z"}"#);
        assert_eq!(decode_payload(&p).unwrap(), (51234, "2027-01-10T12:00:00Z".to_string()));
    }

    #[test]
    fn garbage_payload_errors() {
        assert!(decode_payload("!!!").is_err());
    }

    fn apply(applied: Option<u16>, port: u16, fail: bool) -> (Result<bool>, State, Vec<u16>, Vec<u16>) {
        let mut s = State { applied_port: applied, ..Default::default() };
        let (mut retired, mut notified) = (vec![], vec![]);
        let r = apply_port(&mut s, port, |p| retired.push(p), |p| {
            notified.push(p);
            if fail { bail!("hook failed") } else { Ok(()) }
        });
        (r, s, retired, notified)
    }

    #[test]
    fn unchanged_port_notifies_nobody() {
        let (r, s, retired, notified) = apply(Some(5), 5, false);
        assert!(!r.unwrap());
        assert!(retired.is_empty() && notified.is_empty());
        assert_eq!(s.applied_port, Some(5));
    }

    #[test]
    fn first_port_notifies_without_retiring() {
        let (r, s, retired, notified) = apply(None, 5, false);
        assert!(r.unwrap());
        assert!(retired.is_empty());
        assert_eq!(notified, vec![5]);
        assert_eq!(s.applied_port, Some(5));
    }

    #[test]
    fn changed_port_retires_old_then_notifies() {
        let (r, s, retired, notified) = apply(Some(4), 5, false);
        assert!(r.unwrap());
        assert_eq!((retired, notified), (vec![4], vec![5]));
        assert_eq!(s.applied_port, Some(5));
    }

    #[test]
    fn hook_failure_keeps_applied_port() {
        let (r, s, _, notified) = apply(Some(4), 5, true);
        assert!(r.is_err());
        assert_eq!(notified, vec![5]);
        assert_eq!(s.applied_port, Some(4));
    }
}
