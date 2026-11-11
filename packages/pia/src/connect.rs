//! `pia connect` (host netns): authenticate, register an ephemeral WireGuard key,
//! and write the tunnel config plus what `portforward` needs into the state file.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use anyhow::{Context, Result, bail};

use crate::api::{self, AddKey, Region, Server};
use crate::config::{Config, RUN_DIR, STATE_DIR, STATE_PATH, WG_CONF_PATH};
use crate::state::{self, State};
use crate::{cmd, creds, log};

/// `auto` takes the first region with port forwarding; anything else is an exact region id.
pub fn select_region<'a>(regions: &'a [Region], want: &str) -> Result<(&'a Region, &'a Server)> {
    let found = if want == "auto" {
        regions.iter().find(|r| r.port_forward)
    } else {
        regions.iter().find(|r| r.id == want)
    };
    let Some(region) = found else {
        bail!("no matching region for '{want}'");
    };
    if !region.port_forward {
        bail!("region '{}' does not support port forwarding (US regions never do)", region.id);
    }
    let Some(server) = region.servers.wg.first() else {
        bail!("region '{}' has no WireGuard servers", region.id);
    };
    Ok((region, server))
}

pub fn render_wg_conf(private_key: &str, a: &AddKey) -> String {
    let dns = a.dns_servers.first().map(String::as_str).unwrap_or_default();
    [
        "[Interface]".to_string(),
        format!("Address = {}", a.peer_ip),
        format!("PrivateKey = {private_key}"),
        format!("DNS = {dns}"),
        String::new(),
        "[Peer]".to_string(),
        "PersistentKeepalive = 25".to_string(),
        format!("PublicKey = {}", a.server_key),
        "AllowedIPs = 0.0.0.0/0".to_string(),
        format!("Endpoint = {}:{}", a.server_ip, a.server_port),
        String::new(),
    ]
    .join("\n")
}

/// Records what `portforward` needs. The payload, signature and port are kept: they are
/// tied to the account, not the tunnel, so a reconnect keeps rebinding the same port.
pub fn merge_connect(state: &mut State, token: &str, a: &AddKey, hostname: &str) {
    state.token = Some(token.to_string());
    state.pf_gateway = Some(a.server_vip.clone());
    state.pf_hostname = Some(hostname.to_string());
    state.dns_servers = Some(a.dns_servers.clone());
}

fn ensure_dir(path: &str, mode: u32) -> Result<()> {
    std::fs::create_dir_all(path).with_context(|| format!("creating {path}"))?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).with_context(|| format!("chmod {path}"))
}

pub fn run(cfg: &Config) -> Result<()> {
    let text = std::fs::read_to_string(&cfg.credentials).context("reading the credentials file")?;
    let creds = creds::parse(&text)?;
    let ca = std::fs::read(&cfg.ca_cert).context("reading the PIA CA certificate")?;

    // /run/pia is traversable so consumers can read the bare port file; wg0.conf
    // inside it stays 0600 (it holds the private key).
    ensure_dir(RUN_DIR, 0o755)?;
    ensure_dir(STATE_DIR, 0o700)?;

    log("requesting auth token");
    let token = api::token(&creds.user, &creds.pass)?;

    log("fetching server list");
    let regions = api::server_list()?;
    let (region, server) = select_region(&regions, &cfg.region)?;
    log(&format!("selected region '{}' server {} ({})", region.id, server.cn, server.ip));

    let private = cmd::stdout(&cfg.wg, &["genkey"], None)?;
    let public = cmd::stdout(&cfg.wg, &["pubkey"], Some(&format!("{private}\n")))?;

    log(&format!("registering key with {}", server.cn));
    let added = api::add_key(&ca, server, &public, &token)?;

    state::write_atomic(Path::new(WG_CONF_PATH), render_wg_conf(&private, &added).as_bytes(), 0o600)?;

    let state_path = Path::new(STATE_PATH);
    let mut st = state::load(state_path)?;
    merge_connect(&mut st, &token, &added, &server.cn);
    state::save(state_path, &st)?;
    log(&format!("tunnel config written; gateway {}", added.server_vip));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::parse_server_list;

    fn regions() -> Vec<Region> {
        parse_server_list(include_str!("../tests/fixtures/servers-v6.txt")).unwrap()
    }

    fn addkey(dns: &[&str]) -> AddKey {
        AddKey {
            peer_ip: "10.9.8.7/32".into(),
            server_key: "SK=".into(),
            server_ip: "1.2.3.4".into(),
            server_port: 1337,
            server_vip: "10.1.2.1".into(),
            dns_servers: dns.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn err(want: &str) -> String {
        select_region(&regions(), want).unwrap_err().to_string()
    }

    #[test]
    fn auto_picks_first_port_forward_region() {
        let r = regions();
        let (region, server) = select_region(&r, "auto").unwrap();
        assert_eq!((region.id.as_str(), server.cn.as_str()), ("ca", "montreal421"));
    }

    #[test]
    fn exact_region() {
        assert_eq!(select_region(&regions(), "ca").unwrap().0.id, "ca");
    }

    #[test]
    fn unknown_region_errors() {
        assert!(err("xx").contains("no matching region for 'xx'"));
    }

    #[test]
    fn region_without_pf_errors() {
        assert!(err("us_east").contains("does not support port forwarding"));
    }

    #[test]
    fn region_without_wg_servers_errors() {
        let e = err("nowg");
        assert!(e.contains("nowg") && e.contains("no WireGuard servers"), "{e}");
    }

    #[test]
    fn wg_conf_matches_python_output() {
        assert_eq!(
            render_wg_conf("PK=", &addkey(&["10.0.0.243"])),
            "[Interface]\nAddress = 10.9.8.7/32\nPrivateKey = PK=\nDNS = 10.0.0.243\n\n[Peer]\nPersistentKeepalive = 25\nPublicKey = SK=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.2.3.4:1337\n"
        );
    }

    #[test]
    fn wg_conf_empty_dns() {
        assert!(render_wg_conf("PK=", &addkey(&[])).contains("DNS = \n"));
    }

    #[test]
    fn merge_preserves_port_forward_fields() {
        let mut s = State {
            token: Some("old".into()),
            payload: Some("p".into()),
            signature: Some("s".into()),
            expires_at: Some("e".into()),
            port: Some(5),
            applied_port: Some(5),
            ..Default::default()
        };
        let before = s.clone();
        merge_connect(&mut s, "new", &addkey(&["10.0.0.243"]), "montreal421");
        assert_eq!(s.token.as_deref(), Some("new"));
        assert_eq!(s.pf_gateway.as_deref(), Some("10.1.2.1"));
        assert_eq!(s.pf_hostname.as_deref(), Some("montreal421"));
        assert_eq!(s.dns_servers, Some(vec!["10.0.0.243".to_string()]));
        assert_eq!(
            (&s.payload, &s.signature, &s.expires_at, s.port, s.applied_port),
            (&before.payload, &before.signature, &before.expires_at, before.port, before.applied_port)
        );
    }
}
