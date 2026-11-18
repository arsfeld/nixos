//! Is the phone near raider, at the basement office desk?
//!
//! Every 30 s it pings the phone over classic Bluetooth (`l2ping`, which pages
//! a bonded device without connecting a profile) and, while that ping holds
//! the link up, reads the link's RSSI (`btmgmt conn-info`). `GET /status`
//! serves the last result as JSON for galactica's Home Assistant, or 503 once
//! it is older than 3 minutes, so a wedged probe reads as unavailable rather
//! than as a stale answer.
//!
//! BR/EDR RSSI is relative to the controller's golden receive range: 0 means
//! strong, negative means below it. It is reported for calibration; whether
//! the phone counts as near is Home Assistant's decision.
//!
//! Env: PHONE_FILE (a file holding the phone's Bluetooth address), LISTEN
//! (default 0.0.0.0:8593).

use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use std::{env, fs, thread};

const INTERVAL: Duration = Duration::from_secs(30);
const STALE: Duration = Duration::from_secs(180);

#[derive(Clone, Copy, Debug, PartialEq)]
struct Probe {
    reachable: bool,
    rssi: Option<i32>,
}

/// `btmgmt conn-info` prints "... RSSI -7 TX power 8 ..." while connected.
fn parse_rssi(out: &str) -> Option<i32> {
    let rest = &out[out.find("RSSI ")? + 5..];
    rest.split_whitespace().next()?.parse().ok()
}

/// `l2ping` ends with "3 sent, 2 received, 33% loss".
fn parse_received(out: &str) -> u32 {
    out.lines()
        .find_map(|l| {
            let (_, after) = l.split_once("sent, ")?;
            after.split_whitespace().next()?.parse().ok()
        })
        .unwrap_or(0)
}

fn probe(phone: &str) -> Probe {
    let ping = Command::new("l2ping")
        .args(["-c", "3", "-t", "5", phone])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut ping) = ping else {
        eprintln!("office-presence: cannot run l2ping");
        return Probe { reachable: false, rssi: None };
    };
    let mut rssi = None;
    for _ in 0..8 {
        thread::sleep(Duration::from_millis(500));
        if let Ok(out) = Command::new("btmgmt")
            .args(["conn-info", "-t", "0", phone])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
        {
            rssi = parse_rssi(&String::from_utf8_lossy(&out.stdout));
        }
        if rssi.is_some() || matches!(ping.try_wait(), Ok(Some(_))) {
            break;
        }
    }
    let out = ping.wait_with_output().map(|o| o.stdout).unwrap_or_default();
    Probe { reachable: parse_received(&String::from_utf8_lossy(&out)) > 0, rssi }
}

fn status_json(last: Option<(Probe, Instant)>, now: Instant) -> (u16, String) {
    match last {
        Some((p, at)) if now.duration_since(at) < STALE => {
            let rssi = p.rssi.map_or("null".to_string(), |r| r.to_string());
            let age = now.duration_since(at).as_secs();
            (200, format!(r#"{{"reachable":{},"rssi":{},"age_s":{}}}"#, p.reachable, rssi, age))
        }
        _ => (503, r#"{"error":"no recent probe"}"#.to_string()),
    }
}

fn serve(mut stream: TcpStream, last: &Mutex<Option<(Probe, Instant)>>) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
    let mut request = String::new();
    if BufReader::new(&stream).read_line(&mut request).is_err() {
        return;
    }
    let (code, body) = if request.starts_with("GET /status ") {
        status_json(*last.lock().unwrap(), Instant::now())
    } else {
        (404, r#"{"error":"not found"}"#.to_string())
    };
    let reason = match code {
        200 => "OK",
        404 => "Not Found",
        _ => "Service Unavailable",
    };
    let _ = write!(
        stream,
        "HTTP/1.1 {code} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}

fn main() {
    let phone_file = env::var("PHONE_FILE").expect("PHONE_FILE is not set");
    let phone = fs::read_to_string(&phone_file).expect("cannot read PHONE_FILE").trim().to_string();
    let listen = env::var("LISTEN").unwrap_or_else(|_| "0.0.0.0:8593".to_string());
    let listener = TcpListener::bind(&listen).expect("cannot bind LISTEN");
    let last: Arc<Mutex<Option<(Probe, Instant)>>> = Arc::default();

    let writer = Arc::clone(&last);
    thread::spawn(move || {
        let mut was = None;
        loop {
            let started = Instant::now();
            let p = probe(&phone);
            if was != Some(p.reachable) {
                // The address stays out of the journal.
                eprintln!("office-presence: phone {}", if p.reachable { "reachable" } else { "unreachable" });
                was = Some(p.reachable);
            }
            *writer.lock().unwrap() = Some((p, Instant::now()));
            thread::sleep(INTERVAL.saturating_sub(started.elapsed()));
        }
    });

    for stream in listener.incoming().flatten() {
        serve(stream, &last);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rssi_from_conn_info() {
        let out = "Connection Information for C4:C1:7D:C1:B4:76 (BR/EDR)\n\tRSSI -7\tTX power 8\tmaximum TX power 8\n";
        assert_eq!(parse_rssi(out), Some(-7));
        assert_eq!(parse_rssi("RSSI 0\tTX power 8"), Some(0));
        assert_eq!(parse_rssi("Get Connection Information for X failed. status 0x02 (Not Connected)"), None);
    }

    #[test]
    fn received_from_l2ping() {
        assert_eq!(parse_received("Ping: X from Y (data size 44) ...\n0 bytes from X id 0 time 20.97ms\n3 sent, 2 received, 33% loss\n"), 2);
        assert_eq!(parse_received("Ping: X from Y\nno response from X: id 0\n3 sent, 0 received, 100% loss\n"), 0);
        assert_eq!(parse_received("Can't connect: Host is down\n"), 0);
    }

    #[test]
    fn status_goes_stale() {
        let now = Instant::now();
        let p = Probe { reachable: true, rssi: Some(-3) };
        assert_eq!(status_json(Some((p, now)), now), (200, r#"{"reachable":true,"rssi":-3,"age_s":0}"#.to_string()));
        let none = Probe { reachable: false, rssi: None };
        assert_eq!(status_json(Some((none, now)), now).1, r#"{"reachable":false,"rssi":null,"age_s":0}"#);
        assert_eq!(status_json(Some((p, now)), now + STALE).0, 503);
        assert_eq!(status_json(None, now).0, 503);
    }
}
