//! Pure status logic for an exit slot: parsers for `tailscale status --json` and
//! ipinfo.io, and the derivation of the slot's `state`.

use serde::Serialize;
use serde_json::Value;

/// A tunnel is "starting" for this long after its region is chosen.
const STARTING_SECS: u64 = 120;
/// A handshake older than this means the tunnel is not passing traffic.
const HANDSHAKE_MAX_AGE_S: i64 = 300;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct Tailscale {
    pub running: bool,
    pub online: bool,
    /// The exit-node routes are approved (0.0.0.0/0 is among the node's AllowedIPs).
    pub approved: bool,
    pub hostname: String,
}

/// Parse `tailscale status --json`; anything unparsable is all false.
pub fn parse_tailscale(json: &str) -> Tailscale {
    let Ok(v) = serde_json::from_str::<Value>(json) else {
        return Tailscale::default();
    };
    let me = &v["Self"];
    Tailscale {
        running: v["BackendState"].as_str() == Some("Running"),
        online: me["Online"].as_bool().unwrap_or(false),
        approved: me["AllowedIPs"]
            .as_array()
            .is_some_and(|a| a.iter().any(|x| x.as_str() == Some("0.0.0.0/0"))),
        hostname: me["HostName"].as_str().unwrap_or("").to_string(),
    }
}

pub fn tailscale_label(t: &Tailscale) -> &'static str {
    if !t.running {
        "stopped"
    } else if !t.online {
        "offline"
    } else if !t.approved {
        "unapproved"
    } else {
        "running"
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Egress {
    pub ip: String,
    pub country: String,
}

/// Parse ipinfo.io's JSON; anything without `ip` and `country` strings is `None`.
pub fn parse_egress(json: &str) -> Option<Egress> {
    let v: Value = serde_json::from_str(json).ok()?;
    Some(Egress {
        ip: v.get("ip")?.as_str()?.to_string(),
        country: v.get("country")?.as_str()?.to_string(),
    })
}

#[derive(Serialize, Clone, Copy, PartialEq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Off,
    Starting,
    Up,
    Degraded,
    Down,
}

pub struct Inputs {
    pub region: Option<String>,
    pub country: Option<String>,
    pub chosen_secs_ago: u64,
    pub target_active: bool,
    pub handshake_age_s: Option<i64>,
    pub tailscale: Tailscale,
    pub egress: Option<Egress>,
}

/// off -> up -> starting (< 120 s) -> down (target inactive) -> degraded.
pub fn derive(i: &Inputs) -> State {
    if i.region.is_none() {
        return State::Off;
    }
    let t = &i.tailscale;
    let country_ok = match (&i.egress, &i.country) {
        (Some(e), Some(c)) => e.country.eq_ignore_ascii_case(c),
        _ => false,
    };
    let up = i.target_active
        && i.handshake_age_s.is_some_and(|a| a < HANDSHAKE_MAX_AGE_S)
        && t.running
        && t.online
        && t.approved
        && country_ok;
    if up {
        State::Up
    } else if i.chosen_secs_ago < STARTING_SECS {
        State::Starting
    } else if !i.target_active {
        State::Down
    } else {
        State::Degraded
    }
}

#[derive(Serialize)]
pub struct SlotStatus {
    pub slot: u8,
    pub option: String,
    pub region: Option<String>,
    pub country: Option<String>,
    pub state: State,
    pub handshake_age_s: Option<i64>,
    pub tailscale: &'static str,
    pub hostname: String,
    pub egress_ip: Option<String>,
    pub egress_country: Option<String>,
    /// RFC 3339, null when never checked.
    pub egress_checked: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ts(running: bool, online: bool, approved: bool) -> Tailscale {
        Tailscale { running, online, approved, hostname: "pia-br".into() }
    }
    fn eg(c: &str) -> Option<Egress> {
        Some(Egress { ip: "1.2.3.4".into(), country: c.into() })
    }
    fn good() -> Inputs {
        Inputs {
            region: Some("br".into()),
            country: Some("BR".into()),
            chosen_secs_ago: 1000,
            target_active: true,
            handshake_age_s: Some(41),
            tailscale: ts(true, true, true),
            egress: eg("BR"),
        }
    }

    #[test]
    fn off_without_region() {
        let mut i = good();
        i.region = None;
        assert_eq!(derive(&i), State::Off);
    }
    #[test]
    fn up_when_all_checks_pass() {
        assert_eq!(derive(&good()), State::Up);
    }
    #[test]
    fn starting_within_two_minutes() {
        let mut i = good();
        i.chosen_secs_ago = 30;
        i.handshake_age_s = None;
        i.egress = None;
        assert_eq!(derive(&i), State::Starting);
    }
    #[test]
    fn degraded_after_two_minutes() {
        let mut i = good();
        i.chosen_secs_ago = 300;
        i.handshake_age_s = Some(400);
        assert_eq!(derive(&i), State::Degraded);
    }
    #[test]
    fn degraded_on_wrong_country() {
        let mut i = good();
        i.egress = eg("US");
        assert_eq!(derive(&i), State::Degraded);
    }
    #[test]
    fn degraded_when_unapproved() {
        let mut i = good();
        i.tailscale = ts(true, true, false);
        assert_eq!(derive(&i), State::Degraded);
    }
    #[test]
    fn degraded_without_egress() {
        let mut i = good();
        i.egress = None;
        assert_eq!(derive(&i), State::Degraded);
    }
    #[test]
    fn down_when_target_inactive() {
        let mut i = good();
        i.target_active = false;
        assert_eq!(derive(&i), State::Down);
    }
    #[test]
    fn tailscale_label_order() {
        assert_eq!(tailscale_label(&ts(false, false, false)), "stopped");
        assert_eq!(tailscale_label(&ts(true, false, false)), "offline");
        assert_eq!(tailscale_label(&ts(true, true, false)), "unapproved");
        assert_eq!(tailscale_label(&ts(true, true, true)), "running");
    }
    #[test]
    fn tailscale_json_parsed() {
        let j = r#"{"BackendState":"Running","Self":{"HostName":"pia-br","Online":true,
            "AllowedIPs":["100.64.0.1/32","fd7a:115c::1/128","0.0.0.0/0","::/0"]}}"#;
        let t = parse_tailscale(j);
        assert!(t.running && t.online && t.approved);
        assert_eq!(t.hostname, "pia-br");
        let j2 = r#"{"BackendState":"Running","Self":{"HostName":"x","Online":true,"AllowedIPs":["100.64.0.1/32"]}}"#;
        assert!(!parse_tailscale(j2).approved);
    }
    #[test]
    fn tailscale_garbage_is_all_false() {
        for g in ["", "not json", "{}", "[]"] {
            let t = parse_tailscale(g);
            assert!(!t.running && !t.online && !t.approved);
            assert_eq!(t.hostname, "");
        }
    }
    #[test]
    fn egress_parsed() {
        let e = parse_egress(r#"{"ip":"1.2.3.4","country":"BR","city":"x"}"#).unwrap();
        assert_eq!((e.ip.as_str(), e.country.as_str()), ("1.2.3.4", "BR"));
    }
    #[test]
    fn egress_rate_limit_page_is_none() {
        assert!(parse_egress("<html>429</html>").is_none());
        assert!(parse_egress(r#"{"error":"rate limited"}"#).is_none());
    }
    #[test]
    fn slot_status_serializes_null_checked() {
        let s = SlotStatus {
            slot: 1,
            option: "a".into(),
            region: None,
            country: None,
            state: State::Off,
            handshake_age_s: None,
            tailscale: "stopped",
            hostname: String::new(),
            egress_ip: None,
            egress_country: None,
            egress_checked: None,
        };
        let v = serde_json::to_value(&s).unwrap();
        assert!(v["egress_checked"].is_null());
        assert_eq!(v["state"], "off");
    }
}
