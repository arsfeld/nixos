use std::sync::mpsc;
use std::time::Duration;

use esp_idf_svc::eventloop::EspSystemEventLoop;
use esp_idf_svc::hal::peripherals::Peripherals;
use esp_idf_svc::nvs::EspDefaultNvsPartition;
use esp_idf_svc::sntp::{EspSntp, SyncStatus};
use esp_idf_svc::sys::{esp_crt_bundle_attach, heap_caps_get_free_size, heap_caps_get_largest_free_block, MALLOC_CAP_DMA, MALLOC_CAP_INTERNAL, MALLOC_CAP_SPIRAM};
use esp_idf_svc::wifi::{AuthMethod, BlockingWifi, ClientConfiguration, Configuration, EspWifi};
use esp_idf_svc::ws::client::{EspWebSocketClient, EspWebSocketClientConfig, WebSocketEvent, WebSocketEventType};

const SSID: &str = env!("CB_WIFI_SSID");
const PASS: &str = env!("CB_WIFI_PASS");
const TOKEN: &str = env!("CB_TOKEN");
const URL: &str = "wss://claude-board.arsfeld.one/v1/board";

fn heap_line() {
    unsafe {
        log::info!(
            "heap: internal free={} largest={} dma_largest={} psram free={}",
            heap_caps_get_free_size(MALLOC_CAP_INTERNAL),
            heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL),
            heap_caps_get_largest_free_block(MALLOC_CAP_DMA | MALLOC_CAP_INTERNAL),
            heap_caps_get_free_size(MALLOC_CAP_SPIRAM),
        );
    }
}

fn main() -> anyhow::Result<()> {
    esp_idf_svc::sys::link_patches();
    esp_idf_svc::log::EspLogger::initialize_default();
    log::info!("probe alive");
    if SSID.is_empty() || TOKEN.is_empty() {
        anyhow::bail!("no credentials: run `just board creds`, then rebuild");
    }

    let peripherals = Peripherals::take()?;
    let sysloop = EspSystemEventLoop::take()?;
    let nvs = EspDefaultNvsPartition::take()?;
    let mut wifi = BlockingWifi::wrap(EspWifi::new(peripherals.modem, sysloop.clone(), Some(nvs))?, sysloop)?;
    wifi.set_configuration(&Configuration::Client(ClientConfiguration {
        ssid: SSID.try_into().map_err(|_| anyhow::anyhow!("ssid too long"))?,
        password: PASS.try_into().map_err(|_| anyhow::anyhow!("password too long"))?,
        auth_method: AuthMethod::WPA2Personal, // WPA2 or better, so WPA2/WPA3 mixed works
        ..Default::default()
    }))?;
    wifi.start()?;
    wifi.connect()?;
    wifi.wait_netif_up()?;
    log::info!("wifi up");
    heap_line();

    // No TLS connection until the clock is set (certificate validity dates).
    let sntp = EspSntp::new_default()?;
    while sntp.get_sync_status() != SyncStatus::Completed {
        std::thread::sleep(Duration::from_millis(250));
    }
    log::info!("clock set");

    let (tx, rx) = mpsc::channel::<String>();
    let headers = format!("Authorization: Bearer {TOKEN}\r\n");
    let config = EspWebSocketClientConfig {
        crt_bundle_attach: Some(esp_crt_bundle_attach),
        headers: Some(&headers),
        disable_auto_reconnect: true,
        ..Default::default()
    };
    let _client = EspWebSocketClient::new(URL, &config, Duration::from_secs(10), move |ev| {
        if let Ok(WebSocketEvent { event_type: WebSocketEventType::Text(t), .. }) = ev {
            let _ = tx.send(t.chars().take(80).collect());
        }
    })?;
    log::info!("connecting to {URL}");

    loop {
        match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(first80) => log::info!("frame: {first80}"),
            Err(_) => {}
        }
        heap_line();
    }
}
