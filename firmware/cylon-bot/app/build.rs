// Turns credentials.env (written by `just board creds`) into compile-time values: plain settings become env vars,
// and the Wi-Fi networks (repeated CB_WIFI_SSID/CB_WIFI_PASS pairs, in order) become `$OUT_DIR/wifi.rs`.
fn main() {
    embuild::espidf::sysenv::output();
    println!("cargo:rerun-if-changed=credentials.env");
    let text = std::fs::read_to_string("credentials.env").unwrap_or_default();
    for key in ["CB_TOKEN", "CB_URL", "CB_NTP", "CB_DNS"] {
        let val = text.lines().find_map(|l| l.strip_prefix(&format!("{key}="))).unwrap_or("");
        println!("cargo:rustc-env={key}={val}");
    }

    // Each CB_WIFI_SSID line starts a network; the CB_WIFI_PASS line after it is its password (none: open).
    let mut networks: Vec<(String, String)> = Vec::new();
    for line in text.lines() {
        if let Some(ssid) = line.strip_prefix("CB_WIFI_SSID=") {
            networks.push((ssid.to_owned(), String::new()));
        } else if let Some(pass) = line.strip_prefix("CB_WIFI_PASS=") {
            let Some(last) = networks.last_mut() else { panic!("credentials.env: CB_WIFI_PASS before any CB_WIFI_SSID") };
            last.1 = pass.to_owned();
        }
    }
    // The driver's limits, checked here so a bad entry fails the build rather than the board at start.
    for (ssid, pass) in &networks {
        assert!(!ssid.is_empty() && ssid.len() <= 32, "credentials.env: a Wi-Fi name must be 1 to 32 bytes");
        assert!(pass.is_empty() || (8..=64).contains(&pass.len()), "credentials.env: a Wi-Fi password must be empty or 8 to 64 bytes");
    }
    // `{:?}` of a str is a valid Rust string literal, whatever the name holds.
    let entries: String = networks.iter().map(|(s, p)| format!("    ({s:?}, {p:?}),\n")).collect();
    let out = std::path::Path::new(&std::env::var("OUT_DIR").unwrap()).join("wifi.rs");
    std::fs::write(out, format!("/// The Wi-Fi networks to join, from credentials.env, in its order.\npub const WIFI_NETWORKS: &[(&str, &str)] = &[\n{entries}];\n")).unwrap();
}
