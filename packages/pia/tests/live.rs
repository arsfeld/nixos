//! Live check that rustls accepts PIA's server certificates through the pinned client.

use std::time::Duration;

// Read at run time, not include_bytes!: the Nix build's source holds only this package.
const CA_PATH: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../../modules/hosts/galactica/services/pia-ca.rsa.4096.crt");

#[test]
#[ignore = "needs network: run by hand with --ignored"]
fn pinned_client_handshakes_with_live_pia_server() {
    let body = pia::api::public_client(Duration::from_secs(30))
        .unwrap()
        .get("https://serverlist.piaservers.net/vpninfo/servers/v6")
        .send()
        .unwrap()
        .text()
        .unwrap();
    let list: serde_json::Value = serde_json::from_str(body.lines().next().unwrap()).unwrap();
    let region = list["regions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == "ca")
        .unwrap();
    let wg = &region["servers"]["wg"][0];
    let (ip, cn) = (wg["ip"].as_str().unwrap(), wg["cn"].as_str().unwrap());
    let client = pia::api::pinned_client(&std::fs::read(CA_PATH).unwrap(), cn, ip.parse().unwrap(), 1337, Duration::from_secs(30)).unwrap();
    match client.get(format!("https://{cn}:1337/addKey")).send() {
        Ok(resp) => println!("{cn} ({ip}) answered HTTP {}", resp.status()),
        Err(e) => panic!("TLS/transport error against {cn} ({ip}): {e:?}"),
    }
}
