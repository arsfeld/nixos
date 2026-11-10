//! The pure parts of the network link: when to retry, whether the clock is usable, and which bridge to
//! talk to. Kept here, not in the firmware crate, so they are tested on the host.

use std::net::Ipv4Addr;

/// A clock at or before this (2025-01-01) has not been set by NTP yet.
pub const CLOCK_FLOOR: i64 = 1_735_689_600;

const DEFAULT_URL: &str = "wss://claude-board.arsfeld.one/v1/board";
const DEFAULT_NTP: &str = "pool.ntp.org";
const BACKOFF_START_MS: u32 = 1000;
const BACKOFF_CAP_MS: u32 = 30_000;

/// Whether `unix_secs` is a real time. TLS certificates are only valid within dates, so nothing connects
/// until this is true.
pub fn clock_is_set(unix_secs: i64) -> bool {
    unix_secs > CLOCK_FLOOR
}

/// Wait before reconnect attempt number `attempt` (from 0): one second, doubling, up to 30 s.
pub fn backoff_ms(attempt: u32) -> u32 {
    BACKOFF_START_MS.checked_shl(attempt.min(16)).unwrap_or(BACKOFF_CAP_MS).min(BACKOFF_CAP_MS)
}

/// Where the board connects and how it keeps time.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Settings {
    pub url: String,
    pub ntp: String,
    /// A DNS server to use instead of DHCP's, for networks whose DNS cannot be trusted.
    pub dns: Option<Ipv4Addr>,
}

/// Build-time values (empty means "use the default"). Fails closed: only `wss://` is accepted, and a DNS
/// override that does not parse is an error rather than silently ignored.
pub fn settings(url: &str, ntp: &str, dns: &str) -> Result<Settings, String> {
    let url = if url.is_empty() { DEFAULT_URL } else { url };
    if !url.starts_with("wss://") {
        return Err(format!("only wss:// is supported (the server certificate is always validated): {url}"));
    }
    let dns = match dns {
        "" => None,
        d => Some(d.parse::<Ipv4Addr>().map_err(|_| format!("DNS override is not an IPv4 address: {d}"))?),
    };
    Ok(Settings { url: url.to_owned(), ntp: if ntp.is_empty() { DEFAULT_NTP } else { ntp }.to_owned(), dns })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backoff_doubles_from_one_second_to_a_cap_of_thirty() {
        let seq: Vec<u32> = (0..8).map(backoff_ms).collect();
        assert_eq!(seq, [1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000]);
        assert_eq!(backoff_ms(u32::MAX), 30000);
    }

    #[test]
    fn clock_is_set_rejects_before_2025_and_accepts_after() {
        assert!(!clock_is_set(0));
        assert!(!clock_is_set(1_700_000_000));
        assert!(!clock_is_set(1_735_689_600), "2025-01-01 itself is the floor, not past it");
        assert!(clock_is_set(1_735_689_601));
        assert!(clock_is_set(1_800_000_000));
    }

    #[test]
    fn settings_defaults_apply_when_url_and_ntp_unset() {
        let s = settings("", "", "").unwrap();
        assert_eq!(s.url, "wss://claude-board.arsfeld.one/v1/board");
        assert_eq!(s.ntp, "pool.ntp.org");
        assert_eq!(s.dns, None);
    }

    #[test]
    fn settings_keep_what_was_given() {
        let s = settings("wss://example.test/v1/board", "time.example.test", "192.0.2.53").unwrap();
        assert_eq!((s.url.as_str(), s.ntp.as_str(), s.dns), ("wss://example.test/v1/board", "time.example.test", Some("192.0.2.53".parse().unwrap())));
    }

    #[test]
    fn a_plain_ws_url_is_refused() {
        // The server certificate is always validated; there is no insecure mode.
        assert!(settings("ws://claude-board.arsfeld.one/v1/board", "", "").is_err());
        assert!(settings("http://x", "", "").is_err());
    }

    #[test]
    fn a_bad_dns_override_is_refused_rather_than_ignored() {
        assert!(settings("", "", "not-an-address").is_err());
    }
}
