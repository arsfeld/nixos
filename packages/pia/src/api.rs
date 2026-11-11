//! HTTP calls to PIA.
//!
//! Errors never carry a request URL: the query strings hold the token, payload and
//! signature, so every reqwest error goes through `http_err`, which strips it.

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use anyhow::{Context, Result, anyhow, bail};
use reqwest::Certificate;
use reqwest::blocking::{Client, RequestBuilder, multipart::Form};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

const TOKEN_URL: &str = "https://www.privateinternetaccess.com/api/client/v2/token";
const SERVER_LIST_URL: &str = "https://serverlist.piaservers.net/vpninfo/servers/v6";
const SLOW: Duration = Duration::from_secs(30);
const PORT_FORWARD: Duration = Duration::from_secs(10);
const ADDKEY_PORT: u16 = 1337;
const PF_PORT: u16 = 19999;

/// A client for PIA's public endpoints (token, server list), trusting the bundled web roots.
pub fn public_client(timeout: Duration) -> Result<Client> {
    Client::builder()
        .timeout(timeout)
        .build()
        .context("building HTTP client")
}

/// A client for a PIA server's own endpoints. Equivalent to curl's
/// `--connect-to <cn>::<ip>: --cacert <ca>`: it connects to `ip`, sends SNI and
/// validates the certificate against `cn`, and trusts only PIA's CA.
pub fn pinned_client(ca_pem: &[u8], cn: &str, ip: IpAddr, port: u16, timeout: Duration) -> Result<Client> {
    let ca = Certificate::from_pem(ca_pem).context("parsing the PIA CA certificate")?;
    Client::builder()
        .tls_built_in_root_certs(false)
        .add_root_certificate(ca)
        .resolve(cn, SocketAddr::new(ip, port))
        .timeout(timeout)
        .build()
        .context("building pinned HTTP client")
}

#[derive(Deserialize, Debug)]
pub struct Region {
    pub id: String,
    #[serde(default)]
    pub port_forward: bool,
    #[serde(default)]
    pub servers: Servers,
}

#[derive(Deserialize, Debug, Default)]
pub struct Servers {
    #[serde(default)]
    pub wg: Vec<Server>,
}

#[derive(Deserialize, Debug, Clone)]
pub struct Server {
    pub ip: String,
    pub cn: String,
}

#[derive(Deserialize, Debug, Clone)]
pub struct AddKey {
    pub peer_ip: String,
    pub server_key: String,
    pub server_ip: String,
    pub server_port: u16,
    pub server_vip: String,
    #[serde(default)]
    pub dns_servers: Vec<String>,
}

#[derive(Deserialize)]
pub struct Signature {
    pub payload: String,
    pub signature: String,
}

/// The v6 server list is one line of JSON followed by a signature; only the JSON is read.
pub fn parse_server_list(body: &str) -> Result<Vec<Region>> {
    #[derive(Deserialize)]
    struct List {
        regions: Vec<Region>,
    }
    let first = body.lines().next().unwrap_or_default();
    Ok(serde_json::from_str::<List>(first).context("parsing the server list")?.regions)
}

/// Parses a PIA response, which is an error unless its `status` is `"OK"`.
pub fn check_ok<T: DeserializeOwned>(endpoint: &str, body: &str) -> Result<T> {
    let v: Value = serde_json::from_str(body).with_context(|| format!("{endpoint}: response is not JSON"))?;
    match v.get("status").and_then(Value::as_str) {
        Some("OK") => serde_json::from_value(v).with_context(|| format!("{endpoint}: unexpected response")),
        other => bail!("{endpoint} failed: status {}", other.unwrap_or("missing")),
    }
}

fn http_err(endpoint: &str, e: reqwest::Error) -> anyhow::Error {
    anyhow!(e.without_url()).context(format!("{endpoint} request failed"))
}

fn send(endpoint: &str, req: RequestBuilder) -> Result<String> {
    req.send()
        .and_then(|r| r.error_for_status())
        .and_then(|r| r.text())
        .map_err(|e| http_err(endpoint, e))
}

fn parse_ip(s: &str) -> Result<IpAddr> {
    s.parse().with_context(|| format!("invalid IP address {s:?}"))
}

/// Exchanges the account's username and password for an API token.
pub fn token(user: &str, pass: &str) -> Result<String> {
    let form = Form::new().text("username", user.to_string()).text("password", pass.to_string());
    let body = send("token", public_client(SLOW)?.post(TOKEN_URL).multipart(form))?;
    let v: Value = serde_json::from_str(&body).context("token: response is not JSON")?;
    match v.get("token").and_then(Value::as_str) {
        Some(t) if !t.is_empty() => Ok(t.to_string()),
        _ => bail!("token request failed"),
    }
}

pub fn server_list() -> Result<Vec<Region>> {
    parse_server_list(&send("server list", public_client(SLOW)?.get(SERVER_LIST_URL))?)
}

/// Registers a WireGuard public key with the server.
pub fn add_key(ca: &[u8], server: &Server, pubkey: &str, token: &str) -> Result<AddKey> {
    let client = pinned_client(ca, &server.cn, parse_ip(&server.ip)?, ADDKEY_PORT, SLOW)?;
    let req = client
        .get(format!("https://{}:{ADDKEY_PORT}/addKey", server.cn))
        .query(&[("pt", token), ("pubkey", pubkey)]);
    check_ok("addKey", &send("addKey", req)?)
}

pub fn get_signature(ca: &[u8], hostname: &str, gateway: &str, token: &str) -> Result<Signature> {
    let client = pinned_client(ca, hostname, parse_ip(gateway)?, PF_PORT, PORT_FORWARD)?;
    let req = client
        .get(format!("https://{hostname}:{PF_PORT}/getSignature"))
        .query(&[("token", token)]);
    check_ok("getSignature", &send("getSignature", req)?)
}

pub fn bind_port(ca: &[u8], hostname: &str, gateway: &str, payload: &str, signature: &str) -> Result<()> {
    let client = pinned_client(ca, hostname, parse_ip(gateway)?, PF_PORT, PORT_FORWARD)?;
    let req = client
        .get(format!("https://{hostname}:{PF_PORT}/bindPort"))
        .query(&[("payload", payload), ("signature", signature)]);
    check_ok::<Value>("bindPort", &send("bindPort", req)?).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_list_ignores_signature_line() {
        let r = parse_server_list(include_str!("../tests/fixtures/servers-v6.txt")).unwrap();
        assert_eq!(r.len(), 3);
        assert_eq!(r[0].servers.wg[0].cn, "montreal421");
        assert!(r[2].servers.wg.is_empty());
    }

    #[test]
    fn addkey_parses() {
        let a: AddKey = check_ok("addKey", include_str!("../tests/fixtures/addkey-ok.json")).unwrap();
        assert_eq!(a.dns_servers, vec!["10.0.0.243", "10.0.0.242"]);
        assert_eq!(a.server_port, 1337);
        assert_eq!(a.server_vip, "10.1.2.1");
    }

    #[test]
    fn signature_and_bind_parse() {
        let s: Signature = check_ok("getSignature", include_str!("../tests/fixtures/signature-ok.json")).unwrap();
        assert_eq!((s.payload.as_str(), s.signature.as_str()), ("cGF5", "sig"));
        check_ok::<serde_json::Value>("bindPort", include_str!("../tests/fixtures/bind-ok.json")).unwrap();
    }

    #[test]
    fn non_ok_status_names_endpoint() {
        let e = check_ok::<serde_json::Value>("getSignature", include_str!("../tests/fixtures/status-error.json"))
            .unwrap_err()
            .to_string();
        assert!(e.contains("getSignature") && e.contains("ERROR"), "{e}");
    }

    #[test]
    fn transport_error_hides_query() {
        let e = public_client(Duration::from_secs(1))
            .unwrap()
            .get("http://127.0.0.1:9/x")
            .query(&[("token", "SECRET")])
            .send()
            .unwrap_err();
        let msg = format!("{:#}", http_err("getSignature", e));
        assert!(msg.contains("getSignature"), "{msg}");
        assert!(!msg.contains("SECRET"), "{msg}");
    }
}
