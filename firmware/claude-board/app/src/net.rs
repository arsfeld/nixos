//! Wi-Fi, the clock and the websocket to the bridge, on their own thread.
//!
//! Fails closed: nothing connects until the clock is set (TLS certificates have validity dates) and the
//! server certificate is always validated against the certificate bundle, hostname included. Wi-Fi and
//! SNTP come from `esp-idf-svc`; the websocket uses the C client directly, because the Rust wrapper hands
//! over each chunk of a fragmented message without its offset and cannot reassemble them.

use std::ffi::{c_char, c_void, CString};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use claude_board_ui::controller::Outbox;
use claude_board_ui::link::{backoff_ms, clock_is_set, Settings};
use esp_idf_svc::eventloop::EspSystemEventLoop;
use esp_idf_svc::handle::RawHandle;
use esp_idf_svc::hal::delay::TickType;
use esp_idf_svc::hal::modem::Modem;
use esp_idf_svc::nvs::EspDefaultNvsPartition;
use esp_idf_svc::sntp::{EspSntp, SntpConf};
use esp_idf_svc::sys::{
    esp_crt_bundle_attach, esp_event_base_t, esp_websocket_client_config_t, esp_websocket_client_destroy,
    esp_websocket_client_handle_t, esp_websocket_client_init, esp_websocket_client_send_text, esp_websocket_client_start,
    esp_websocket_event_data_t, esp_websocket_event_id_t_WEBSOCKET_EVENT_ANY, esp_websocket_event_id_t_WEBSOCKET_EVENT_CLOSED,
    esp_websocket_event_id_t_WEBSOCKET_EVENT_CONNECTED, esp_websocket_event_id_t_WEBSOCKET_EVENT_DATA,
    esp_websocket_event_id_t_WEBSOCKET_EVENT_DISCONNECTED, esp_websocket_event_id_t_WEBSOCKET_EVENT_ERROR,
    esp_websocket_register_events, esp_netif_dns_info_t, esp_netif_dns_type_t_ESP_NETIF_DNS_MAIN, esp_netif_set_dns_info,
    ESP_IPADDR_TYPE_V4,
};
use esp_idf_svc::wifi::{AuthMethod, BlockingWifi, ClientConfiguration, Configuration, EspWifi};

/// What the net thread tells the UI thread.
pub enum Event {
    /// One complete text frame from the bridge.
    Message(String),
    /// The bridge connection came up or went down.
    Link(bool),
}

pub struct Credentials {
    pub ssid: &'static str,
    pub pass: &'static str,
    pub token: &'static str,
}

/// Frames above this are dropped, as in the C firmware.
const MAX_FRAME: usize = 64 * 1024;
/// How long to wait for NTP before trying again.
const CLOCK_WAIT: Duration = Duration::from_secs(15);

#[derive(Clone, Copy)]
struct ClientPtr(esp_websocket_client_handle_t);
// The handle is only used under the mutex, and the C client is thread safe for send.
unsafe impl Send for ClientPtr {}

struct Shared {
    client: Mutex<Option<ClientPtr>>,
    up: AtomicBool,
}

/// The way answers leave the board.
#[derive(Clone)]
pub struct Net(Arc<Shared>);

impl Outbox for Net {
    fn send(&self, json: String) -> bool {
        let guard = self.0.client.lock().unwrap();
        match *guard {
            Some(c) if self.0.up.load(Ordering::SeqCst) => {
                let ticks = TickType::from(Duration::from_secs(2)).ticks() as _;
                unsafe { esp_websocket_client_send_text(c.0, json.as_ptr() as *const c_char, json.len() as i32, ticks) >= 0 }
            }
            _ => false,
        }
    }
}

/// Start the net thread: it joins Wi-Fi, waits for the clock, connects and reconnects forever.
pub fn start(creds: Credentials, settings: Settings, modem: Modem<'static>, tx: mpsc::Sender<Event>) -> anyhow::Result<Net> {
    let shared = Arc::new(Shared { client: Mutex::new(None), up: AtomicBool::new(false) });
    let net = Net(shared.clone());
    std::thread::Builder::new().name("net".into()).stack_size(16 * 1024).spawn(move || {
        if let Err(e) = task(creds, settings, modem, tx, shared) {
            log::error!("net task ended: {e:#}");
        }
    })?;
    Ok(net)
}

fn unix_now() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn task(creds: Credentials, settings: Settings, modem: Modem<'static>, tx: mpsc::Sender<Event>, shared: Arc<Shared>) -> anyhow::Result<()> {
    let sysloop = EspSystemEventLoop::take()?;
    let nvs = EspDefaultNvsPartition::take()?;
    let mut wifi = BlockingWifi::wrap(EspWifi::new(modem, sysloop.clone(), Some(nvs))?, sysloop)?;
    wifi.set_configuration(&Configuration::Client(ClientConfiguration {
        ssid: creds.ssid.try_into().map_err(|_| anyhow::anyhow!("Wi-Fi name too long"))?,
        password: creds.pass.try_into().map_err(|_| anyhow::anyhow!("Wi-Fi password too long"))?,
        auth_method: AuthMethod::WPA2Personal, // WPA2 or better, so WPA2/WPA3 mixed works
        ..Default::default()
    }))?;
    wifi.start()?;
    // Started once the network is up: an SNTP client that starts with no route waits a long time before
    // its next try.
    let mut sntp: Option<EspSntp> = None;

    let (mut wifi_attempt, mut ws_attempt) = (0u32, 0u32);
    loop {
        if !wifi.is_connected().unwrap_or(false) {
            match wifi.connect().and_then(|_| wifi.wait_netif_up()) {
                Ok(()) => {
                    wifi_attempt = 0;
                    if let Some(dns) = settings.dns {
                        match set_dns(wifi.wifi().sta_netif(), dns) {
                            Ok(()) => log::info!("dns override: {dns}"),
                            Err(e) => log::warn!("dns override failed: {e}"),
                        }
                    }
                    if let Ok(ip) = wifi.wifi().sta_netif().get_ip_info() {
                        log::info!("got ip {}", ip.ip);
                    }
                    if sntp.is_none() {
                        sntp = Some(EspSntp::new(&SntpConf { servers: [settings.ntp.as_str()], ..Default::default() })?);
                    }
                }
                Err(e) => {
                    let wait = backoff_ms(wifi_attempt);
                    log::warn!("wifi connect failed ({e}); retrying in {wait} ms");
                    wifi_attempt = wifi_attempt.saturating_add(1);
                    std::thread::sleep(Duration::from_millis(wait as u64));
                    continue;
                }
            }
        }

        if !clock_is_set(unix_now()) {
            log::info!("waiting for the clock ({})", settings.ntp);
            let until = Instant::now() + CLOCK_WAIT;
            while !clock_is_set(unix_now()) && Instant::now() < until {
                std::thread::sleep(Duration::from_millis(250));
            }
            if !clock_is_set(unix_now()) {
                log::warn!("clock not set; not connecting");
                std::thread::sleep(Duration::from_secs(5));
                continue;
            }
            log::info!("clock set");
        }

        let started = Instant::now();
        connect_once(&settings.url, creds.token, &tx, &shared, &wifi);
        // A connection that lasted starts the backoff over; failures back off up to 30 s.
        if started.elapsed() > Duration::from_secs(30) {
            ws_attempt = 0;
        }
        let wait = backoff_ms(ws_attempt);
        ws_attempt = ws_attempt.saturating_add(1);
        log::info!("next attempt in {wait} ms");
        std::thread::sleep(Duration::from_millis(wait as u64));
    }
}

/// Use `dns` instead of the server DHCP handed out, for networks whose DNS cannot be trusted.
fn set_dns(netif: &esp_idf_svc::netif::EspNetif, dns: std::net::Ipv4Addr) -> Result<(), String> {
    let mut info: esp_netif_dns_info_t = unsafe { std::mem::zeroed() };
    info.ip.type_ = ESP_IPADDR_TYPE_V4 as u8;
    info.ip.u_addr.ip4.addr = u32::from_ne_bytes(dns.octets());
    match unsafe { esp_netif_set_dns_info(netif.handle(), esp_netif_dns_type_t_ESP_NETIF_DNS_MAIN, &mut info) } {
        0 => Ok(()),
        err => Err(format!("esp_netif_set_dns_info returned {err}")),
    }
}

/// What the websocket callback needs; owned by `connect_once` for the life of one connection.
struct WsCtx {
    tx: mpsc::Sender<Event>,
    shared: Arc<Shared>,
    closed: Arc<AtomicBool>,
    frame: Vec<u8>,
    /// The frame being received is over the size limit: skip its remaining chunks.
    skipping: bool,
}

/// One connection attempt; returns when it ended (failed, closed, or Wi-Fi lost).
fn connect_once(url: &str, token: &str, tx: &mpsc::Sender<Event>, shared: &Arc<Shared>, wifi: &BlockingWifi<EspWifi<'static>>) {
    let (Ok(uri), Ok(headers)) = (CString::new(url), CString::new(format!("Authorization: Bearer {token}\r\n"))) else {
        log::error!("the bridge URL or token contains a NUL byte");
        return;
    };
    // The server certificate is validated against the bundle, hostname included. Nothing here may relax that.
    let mut cfg: esp_websocket_client_config_t = unsafe { std::mem::zeroed() };
    cfg.uri = uri.as_ptr();
    cfg.headers = headers.as_ptr();
    cfg.crt_bundle_attach = Some(esp_crt_bundle_attach);
    cfg.disable_auto_reconnect = true; // task() backs off between attempts
    cfg.network_timeout_ms = 10_000;
    cfg.buffer_size = 4096;
    cfg.task_stack = 6144;

    let closed = Arc::new(AtomicBool::new(false));
    let ctx = Box::into_raw(Box::new(WsCtx { tx: tx.clone(), shared: shared.clone(), closed: closed.clone(), frame: Vec::new(), skipping: false }));
    let client = unsafe { esp_websocket_client_init(&cfg) };
    if client.is_null() {
        log::error!("websocket client init failed");
        drop(unsafe { Box::from_raw(ctx) });
        return;
    }
    unsafe { esp_websocket_register_events(client, esp_websocket_event_id_t_WEBSOCKET_EVENT_ANY, Some(on_ws_event), ctx as *mut c_void) };
    *shared.client.lock().unwrap() = Some(ClientPtr(client));
    if unsafe { esp_websocket_client_start(client) } != 0 {
        closed.store(true, Ordering::SeqCst);
    }
    log::info!("connecting to {url}");

    // Leaves on close or error, or when Wi-Fi drops (the client would sit in its own timeouts).
    while !closed.load(Ordering::SeqCst) {
        std::thread::sleep(Duration::from_millis(500));
        if !wifi.is_connected().unwrap_or(false) {
            break;
        }
    }

    let was_up = shared.up.swap(false, Ordering::SeqCst);
    *shared.client.lock().unwrap() = None;
    unsafe { esp_websocket_client_destroy(client) };
    drop(unsafe { Box::from_raw(ctx) });
    if was_up {
        let _ = tx.send(Event::Link(false));
    }
}

#[allow(non_upper_case_globals)] // the bindgen constants are lower case
unsafe extern "C" fn on_ws_event(arg: *mut c_void, _base: esp_event_base_t, id: i32, data: *mut c_void) {
    let ctx = &mut *(arg as *mut WsCtx);
    let e = &*(data as *const esp_websocket_event_data_t);
    match id {
        esp_websocket_event_id_t_WEBSOCKET_EVENT_CONNECTED => {
            log::info!("bridge connected");
            ctx.shared.up.store(true, Ordering::SeqCst);
            let _ = ctx.tx.send(Event::Link(true));
        }
        esp_websocket_event_id_t_WEBSOCKET_EVENT_DATA => handle_data(ctx, e),
        esp_websocket_event_id_t_WEBSOCKET_EVENT_ERROR => {
            log::warn!(
                "bridge error: type={} tls=0x{:x} stack=0x{:x} sock_errno={} http={}",
                e.error_handle.error_type,
                e.error_handle.esp_tls_last_esp_err,
                e.error_handle.esp_tls_stack_err,
                e.error_handle.esp_transport_sock_errno,
                e.error_handle.esp_ws_handshake_status_code
            );
            ctx.closed.store(true, Ordering::SeqCst);
        }
        esp_websocket_event_id_t_WEBSOCKET_EVENT_DISCONNECTED | esp_websocket_event_id_t_WEBSOCKET_EVENT_CLOSED => {
            log::warn!("bridge connection closed");
            ctx.closed.store(true, Ordering::SeqCst);
        }
        _ => {}
    }
}

/// A text frame can arrive in several chunks: collect them by offset and hand over the whole message.
unsafe fn handle_data(ctx: &mut WsCtx, e: &esp_websocket_event_data_t) {
    if e.op_code != 0x1 && e.op_code != 0x0 {
        return; // text, or a continuation of one
    }
    let (len, total, offset) = (e.data_len.max(0) as usize, e.payload_len.max(0) as usize, e.payload_offset.max(0) as usize);
    if offset == 0 {
        ctx.frame.clear();
        ctx.skipping = total > MAX_FRAME;
        if ctx.skipping {
            log::warn!("dropping a {total} byte frame (limit {MAX_FRAME})");
        }
    }
    if ctx.skipping {
        return;
    }
    if len > 0 {
        // (An empty frame may come with a null pointer, which from_raw_parts must not be given.)
        ctx.frame.extend_from_slice(std::slice::from_raw_parts(e.data_ptr as *const u8, len));
    }
    if offset + len >= total {
        match String::from_utf8(std::mem::take(&mut ctx.frame)) {
            Ok(text) => {
                let _ = ctx.tx.send(Event::Message(text));
            }
            Err(_) => log::warn!("dropping a frame that is not valid UTF-8"),
        }
    }
}
