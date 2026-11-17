//! The loopback HTTP API, as a pure function of the request and the current snapshot.

use super::regions::Offered;
use super::slots::{choose, Action, ChoiceError};
use super::status::{SlotStatus, State};

#[derive(Default)]
pub struct Snapshot {
    pub options: Vec<String>,
    pub offered: Vec<Offered>,
    pub slots: Vec<SlotStatus>,
    /// Each slot's region id, `None` when Off.
    pub current: Vec<Option<String>>,
}

#[derive(Debug)]
pub struct Response {
    pub code: u16,
    pub body: String,
    /// A recorded choice for the caller to apply: slot, region (None is Off), action.
    pub change: Option<(u8, Option<String>, Action)>,
}

fn reply(code: u16, body: String) -> Response {
    Response { code, body, change: None }
}

fn error(code: u16, msg: &str) -> Response {
    reply(code, serde_json::json!({ "error": msg }).to_string())
}

/// `GET /status` and `POST /slots/<n>`; the body of a POST is `{"option": "<label>"}`.
/// A POST answers with the slot's status as it stood; the change takes effect when applied.
pub fn handle(method: &str, path: &str, body: &str, snap: &Snapshot) -> Response {
    let path = path.split('?').next().unwrap_or("");
    if path == "/status" {
        if method != "GET" {
            return error(405, "method not allowed");
        }
        let active = snap.slots.iter().filter(|s| s.state != State::Off).count();
        let v = serde_json::json!({ "options": snap.options, "active": active, "slots": snap.slots });
        return reply(200, v.to_string());
    }
    let Some(slot) = path.strip_prefix("/slots/").and_then(|n| n.parse::<u8>().ok()) else {
        return error(404, "not found");
    };
    if method != "POST" {
        return error(405, "method not allowed");
    }
    let count = u8::try_from(snap.slots.len()).unwrap_or(u8::MAX);
    match choose(slot, count, body, &snap.offered, &snap.current) {
        Ok((region, action)) => {
            let status = &snap.slots[usize::from(slot) - 1];
            let mut r = reply(200, serde_json::to_string(status).unwrap_or_default());
            r.change = Some((slot, region, action));
            r
        }
        Err(ChoiceError::UnknownSlot) => error(404, "no such slot"),
        Err(ChoiceError::UnknownOption) => error(400, "unknown option"),
        Err(ChoiceError::BadBody) => error(400, "expected {\"option\": \"<label>\"}"),
        Err(ChoiceError::Conflict) => error(409, "the other slot already uses that region"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn status(slot: u8, state: State, region: Option<&str>) -> SlotStatus {
        SlotStatus {
            slot,
            option: region.map_or("Off".into(), |r| format!("L-{r}")),
            region: region.map(str::to_string),
            country: None,
            state,
            handshake_age_s: None,
            tailscale: "stopped",
            hostname: String::new(),
            egress_ip: None,
            egress_country: None,
            egress_checked: None,
        }
    }

    fn snap() -> Snapshot {
        let offered = vec![
            Offered { label: "Brazil".into(), id: "br".into(), country: "BR".into() },
            Offered { label: "Canada".into(), id: "ca".into(), country: "CA".into() },
        ];
        Snapshot {
            options: vec!["Off".into(), "Brazil".into(), "Canada".into()],
            offered,
            slots: vec![status(1, State::Off, None), status(2, State::Up, Some("ca"))],
            current: vec![None, Some("ca".into())],
        }
    }

    fn json(r: &Response) -> Value {
        serde_json::from_str(&r.body).unwrap()
    }

    #[test]
    fn status_shape() {
        let r = handle("GET", "/status", "", &snap());
        assert_eq!(r.code, 200);
        assert!(r.change.is_none());
        let v = json(&r);
        assert_eq!(v["options"][0], "Off");
        assert_eq!(v["options"].as_array().unwrap().len(), 3);
        assert_eq!(v["active"], 1);
        assert_eq!(v["slots"].as_array().unwrap().len(), 2);
        assert_eq!(v["slots"][1]["state"], "up");
    }

    #[test]
    fn post_returns_change() {
        let r = handle("POST", "/slots/1", r#"{"option":"Brazil"}"#, &snap());
        assert_eq!(r.code, 200);
        assert_eq!(r.change, Some((1, Some("br".into()), Action::Start)));
        assert_eq!(json(&r)["slot"], 1);
    }

    #[test]
    fn post_off_stops() {
        let r = handle("POST", "/slots/2", r#"{"option":"Off"}"#, &snap());
        assert_eq!(r.code, 200);
        assert_eq!(r.change, Some((2, None, Action::Stop)));
    }

    #[test]
    fn post_conflict_409() {
        let r = handle("POST", "/slots/1", r#"{"option":"Canada"}"#, &snap());
        assert_eq!(r.code, 409);
        assert!(r.change.is_none());
        assert!(json(&r)["error"].is_string());
    }

    #[test]
    fn post_unknown_label_400() {
        let r = handle("POST", "/slots/1", r#"{"option":"Narnia"}"#, &snap());
        assert_eq!(r.code, 400);
        assert!(r.change.is_none());
        assert_eq!(handle("POST", "/slots/1", "nope", &snap()).code, 400);
    }

    #[test]
    fn unknown_path_404() {
        for p in ["/", "/nope", "/slots/3", "/slots/0", "/slots/x", "/slots/1/extra"] {
            let r = handle("POST", p, r#"{"option":"Off"}"#, &snap());
            assert_eq!(r.code, 404, "{p}");
            assert!(r.change.is_none());
        }
        assert_eq!(handle("GET", "/nope", "", &snap()).code, 404);
    }

    #[test]
    fn get_on_slot_405() {
        assert_eq!(handle("GET", "/slots/1", "", &snap()).code, 405);
        assert_eq!(handle("POST", "/status", "", &snap()).code, 405);
    }

    #[test]
    fn query_string_ignored() {
        assert_eq!(handle("GET", "/status?x=1", "", &snap()).code, 200);
    }
}
