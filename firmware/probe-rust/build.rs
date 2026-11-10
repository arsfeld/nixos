// Turns credentials.env (written by `just board creds`) into compile-time env vars, and compiles the
// Slint scene for the software renderer.
fn main() {
    embuild::espidf::sysenv::output();
    println!("cargo:rerun-if-changed=credentials.env");
    let text = std::fs::read_to_string("credentials.env").unwrap_or_default();
    for key in ["CB_WIFI_SSID", "CB_WIFI_PASS", "CB_TOKEN"] {
        let val = text
            .lines()
            .find_map(|l| l.strip_prefix(&format!("{key}=")))
            .unwrap_or("");
        println!("cargo:rustc-env={key}={val}");
    }
    let cfg = slint_build::CompilerConfiguration::new()
        .embed_resources(slint_build::EmbedResourcesKind::EmbedForSoftwareRenderer);
    slint_build::compile_with_config("ui/probe.slint", cfg).unwrap();
}
