//! HTTP calls to PIA.

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use anyhow::{Context, Result};
use reqwest::blocking::Client;
use reqwest::Certificate;

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
