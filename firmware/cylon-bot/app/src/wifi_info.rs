//! What the link page shows about the Wi-Fi: the access point's signal and name and the station's address. Read
//! straight from ESP-IDF, so the UI thread can ask while net.rs's thread owns the driver; both calls only copy state
//! the driver already holds.

use std::net::Ipv4Addr;

use esp_idf_svc::sys::{esp_netif_get_handle_from_ifkey, esp_netif_get_ip_info, esp_netif_ip_info_t, esp_wifi_sta_get_ap_info, wifi_ap_record_t, ESP_OK};

pub struct WifiInfo {
    /// The access point's signal, in dBm.
    pub rssi: i8,
    /// Its name, converted lossily: bytes that are not UTF-8 become U+FFFD (drawn blank, like any missing glyph).
    pub ssid: String,
    /// The station's address; `None` before DHCP has given one.
    pub ip: Option<Ipv4Addr>,
}

/// `None` while the station is not associated with an access point.
pub fn read() -> Option<WifiInfo> {
    let mut ap = wifi_ap_record_t::default();
    if unsafe { esp_wifi_sta_get_ap_info(&mut ap) } != ESP_OK {
        return None;
    }
    let len = ap.ssid.iter().position(|&b| b == 0).unwrap_or(ap.ssid.len());
    let ssid = String::from_utf8_lossy(&ap.ssid[..len]).into_owned();
    Some(WifiInfo { rssi: ap.rssi, ssid, ip: station_ip() })
}

fn station_ip() -> Option<Ipv4Addr> {
    let netif = unsafe { esp_netif_get_handle_from_ifkey(c"WIFI_STA_DEF".as_ptr()) };
    if netif.is_null() {
        return None;
    }
    let mut info = esp_netif_ip_info_t::default();
    if unsafe { esp_netif_get_ip_info(netif, &mut info) } != ESP_OK {
        return None;
    }
    // lwIP keeps the address in network byte order: on this little-endian core the first octet is the low byte.
    Some(Ipv4Addr::from(info.ip.addr.to_le_bytes())).filter(|ip| !ip.is_unspecified())
}
