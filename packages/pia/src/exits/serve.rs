//! `pia exits serve`: one refresher thread gathers each slot's status into a shared
//! snapshot, and the HTTP loop answers from that snapshot, so a request never waits on
//! a command. A change is applied at once (region file, then `systemctl --no-block`) and
//! wakes the refresher.

use super::config::{ExitsConfig, SlotConfig};
use super::http::{handle, Snapshot};
use super::node::hostname;
use super::regions::{self, Offered};
use super::slots::{self, Action};
use super::status::{self, Egress, Inputs, SlotStatus, State, Tailscale};
use crate::{api, cmd, watchdog};
use anyhow::{anyhow, Result};
use chrono::{DateTime, SecondsFormat, Utc};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime};

const STATUS_EVERY: Duration = Duration::from_secs(30);
const EGRESS_EVERY: Duration = Duration::from_secs(300);
const REGIONS_EVERY: Duration = Duration::from_secs(6 * 3600);
/// Retry a failed region-list fetch sooner than the 6 h refresh.
const REGIONS_RETRY: Duration = Duration::from_secs(300);
/// A slot chosen this recently re-checks egress every pass until it comes up.
const SETTLING: Duration = Duration::from_secs(300);
const EGRESS_URL: &str = "https://ipinfo.io/json";

fn log(msg: &str) {
    eprintln!("pia-exits: {msg}");
}

fn lock(snap: &Mutex<Snapshot>) -> std::sync::MutexGuard<'_, Snapshot> {
    snap.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What the refresher remembers about one slot between passes.
#[derive(Default)]
struct Probe {
    region: Option<(String, SystemTime)>,
    target_active: bool,
    handshake_age_s: Option<i64>,
    tailscale: Tailscale,
    /// The last egress that parsed, kept for display.
    egress: Option<(Egress, DateTime<Utc>)>,
    /// Whether the most recent check succeeded; `derive` sees no egress until one does.
    egress_ok: bool,
    egress_due: Option<Instant>,
    /// A failing egress check is logged once, until one succeeds.
    egress_failure_logged: bool,
    state: Option<State>,
}


fn systemctl(cfg: &ExitsConfig, verb: &str, target: &str) {
    if let Err(e) = cmd::run(&cfg.systemctl, &[verb, "--no-block", target]) {
        log(&format!("systemctl {verb} {target}: {e:#}"));
    }
}

fn label(offered: &[Offered], id: &str) -> String {
    offered.iter().find(|o| o.id == id).map_or_else(|| id.to_string(), |o| o.label.clone())
}

fn slot_status(sc: &SlotConfig, offered: &[Offered], p: &Probe, now: SystemTime) -> SlotStatus {
    let region = p.region.as_ref().map(|r| r.0.clone());
    let country = region
        .as_deref()
        .and_then(|id| offered.iter().find(|o| o.id == id))
        .map(|o| o.country.clone());
    let chosen_secs_ago = p.region.as_ref().map_or(0, |r| now.duration_since(r.1).unwrap_or_default().as_secs());
    let inputs = Inputs {
        region: region.clone(),
        country: country.clone(),
        chosen_secs_ago,
        target_active: p.target_active,
        handshake_age_s: p.handshake_age_s,
        tailscale: p.tailscale.clone(),
        egress: p.egress.as_ref().filter(|_| p.egress_ok).map(|e| e.0.clone()),
    };
    let hostname = match (&region, p.tailscale.hostname.as_str()) {
        (_, h) if !h.is_empty() => h.to_string(),
        (Some(id), _) => hostname(id),
        (None, _) => String::new(),
    };
    SlotStatus {
        slot: sc.slot,
        option: region.as_deref().map_or_else(|| "Off".to_string(), |id| label(offered, id)),
        region,
        country,
        state: status::derive(&inputs),
        handshake_age_s: p.handshake_age_s,
        tailscale: status::tailscale_label(&p.tailscale),
        hostname,
        egress_ip: p.egress.as_ref().map(|e| e.0.ip.clone()),
        egress_country: p.egress.as_ref().map(|e| e.0.country.clone()),
        egress_checked: p.egress.as_ref().map(|e| e.1.to_rfc3339_opts(SecondsFormat::Secs, true)),
    }
}

fn snapshot(cfg: &ExitsConfig, offered: &[Offered], probes: &[Probe]) -> Snapshot {
    let now = SystemTime::now();
    let current: Vec<Option<String>> = probes.iter().map(|p| p.region.as_ref().map(|r| r.0.clone())).collect();
    let in_use: Vec<&str> = current.iter().flatten().map(String::as_str).collect();
    Snapshot {
        options: regions::options(offered, &in_use),
        offered: offered.to_vec(),
        slots: cfg.slots.iter().zip(probes).map(|(sc, p)| slot_status(sc, offered, p, now)).collect(),
        current,
    }
}

fn handshake_age(cfg: &ExitsConfig, sc: &SlotConfig) -> Option<i64> {
    let wg = cfg.wg.to_string_lossy();
    let args = ["netns", "exec", &sc.namespace, &wg, "show", &sc.interface, "latest-handshakes"];
    let latest = watchdog::latest_handshake(&cmd::stdout(&cfg.ip, &args, None).ok()?);
    (latest != 0).then(|| (Utc::now().timestamp() - latest).max(0))
}

fn check_egress(cfg: &ExitsConfig, sc: &SlotConfig) -> Result<Egress> {
    let curl = cfg.curl.to_string_lossy();
    let args = ["netns", "exec", &sc.namespace, &curl, "-s", "--max-time", "10", EGRESS_URL];
    let body = cmd::stdout(&cfg.ip, &args, None)?;
    status::parse_egress(&body).ok_or_else(|| anyhow!("unexpected answer from {EGRESS_URL}"))
}

/// One pass over a slot: re-read its region, then probe the tunnel if its target is up.
fn probe(cfg: &ExitsConfig, sc: &SlotConfig, offered: &[Offered], p: &mut Probe, now: Instant) {
    let region = slots::read_region(&sc.region_file);
    if region != p.region {
        match &region {
            Some((id, _)) => log(&format!("slot {}: region {}", sc.slot, label(offered, id))),
            None => log(&format!("slot {}: off", sc.slot)),
        }
        if region.is_none() {
            p.egress = None;
            p.egress_ok = false;
        }
        p.egress_due = None;
        p.region = region;
    }
    p.target_active = cmd::succeeds(&cfg.systemctl, &["is-active", "--quiet", &sc.target]);
    if !p.target_active {
        p.handshake_age_s = None;
        p.tailscale = Tailscale::default();
        return;
    }
    p.handshake_age_s = handshake_age(cfg, sc);
    let socket = sc.socket.to_string_lossy();
    p.tailscale = cmd::stdout(&cfg.tailscale, &["--socket", &socket, "status", "--json"], None)
        .map(|j| status::parse_tailscale(&j))
        .unwrap_or_default();
    if p.region.is_none() || p.egress_due.is_some_and(|d| now < d) {
        return;
    }
    match check_egress(cfg, sc) {
        Ok(e) => {
            p.egress = Some((e, Utc::now()));
            p.egress_ok = true;
            p.egress_failure_logged = false;
        }
        Err(e) => {
            if !p.egress_failure_logged {
                log(&format!("slot {}: egress check failed: {e:#}", sc.slot));
                p.egress_failure_logged = true;
            }
            p.egress_ok = false;
        }
    }
    let settling = p
        .region
        .as_ref()
        .is_some_and(|r| SystemTime::now().duration_since(r.1).unwrap_or_default() < SETTLING);
    p.egress_due = Some(now + if settling { STATUS_EVERY } else { EGRESS_EVERY });
}

fn refresher(cfg: &ExitsConfig, mut probes: Vec<Probe>, shared: &Mutex<Snapshot>, wake: &Receiver<()>) {
    let mut offered: Vec<Offered> = Vec::new();
    let mut regions_due = Instant::now();
    loop {
        let now = Instant::now();
        if now >= regions_due {
            match api::server_list() {
                Ok(list) => {
                    offered = regions::offered(&list);
                    regions_due = now + REGIONS_EVERY;
                }
                Err(e) => {
                    log(&format!("fetching the region list: {e:#}"));
                    regions_due = now + REGIONS_RETRY;
                }
            }
        }
        for (sc, p) in cfg.slots.iter().zip(probes.iter_mut()) {
            probe(cfg, sc, &offered, p, now);
        }
        let snap = snapshot(cfg, &offered, &probes);
        for (s, p) in snap.slots.iter().zip(probes.iter_mut()) {
            if p.state != Some(s.state) {
                if let Some(old) = p.state {
                    log(&format!("slot {}: {old:?} -> {:?}", s.slot, s.state).to_lowercase());
                }
                p.state = Some(s.state);
            }
        }
        *lock(shared) = snap;
        match wake.recv_timeout(STATUS_EVERY) {
            Ok(()) => while wake.try_recv().is_ok() {},
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
    }
}

fn apply(cfg: &ExitsConfig, slot: u8, region: Option<&str>, action: &Action) -> Result<()> {
    let sc = cfg.slot(slot).ok_or_else(|| anyhow!("no slot {slot}"))?;
    slots::apply_region(&sc.region_file, region)?;
    let verb = match action {
        Action::Start => "start",
        Action::Restart => "restart",
        Action::Stop => "stop",
    };
    systemctl(cfg, verb, &sc.target);
    Ok(())
}

fn respond(req: tiny_http::Request, code: u16, body: String) {
    let header = tiny_http::Header::from_bytes("Content-Type", "application/json").expect("static header is valid");
    let resp = tiny_http::Response::from_string(body).with_status_code(code).with_header(header);
    if let Err(e) = req.respond(resp) {
        log(&format!("answering a request: {e}"));
    }
}

fn serve_http(cfg: &ExitsConfig, shared: &Mutex<Snapshot>, wake: &Sender<()>) -> Result<()> {
    let server = tiny_http::Server::http(&cfg.listen).map_err(|e| anyhow!("listening on {}: {e}", cfg.listen))?;
    log(&format!("listening on {}", cfg.listen));
    for mut req in server.incoming_requests() {
        let mut body = String::new();
        if std::io::Read::read_to_string(req.as_reader(), &mut body).is_err() {
            respond(req, 400, serde_json::json!({ "error": "unreadable body" }).to_string());
            continue;
        }
        let method = req.method().as_str().to_string();
        let mut r = handle(&method, req.url(), &body, &lock(shared));
        if let Some((slot, region, action)) = r.change.take() {
            match apply(cfg, slot, region.as_deref(), &action) {
                Ok(()) => {
                    let mut snap = lock(shared);
                    if let Some(c) = snap.current.get_mut(usize::from(slot) - 1) {
                        c.clone_from(&region);
                    }
                    drop(snap);
                    let _ = wake.send(());
                }
                Err(e) => {
                    log(&format!("slot {slot}: applying the choice: {e:#}"));
                    r.code = 500;
                    r.body = serde_json::json!({ "error": format!("{e:#}") }).to_string();
                }
            }
        }
        respond(req, r.code, r.body);
    }
    Ok(())
}

pub fn run(cfg: &ExitsConfig) -> Result<()> {
    // Choices survive restarts: every slot with a region file is started, the rest stopped.
    let probes: Vec<Probe> = cfg
        .slots
        .iter()
        .map(|sc| Probe { region: slots::read_region(&sc.region_file), ..Probe::default() })
        .collect();
    let files: Vec<Option<String>> = probes.iter().map(|p| p.region.as_ref().map(|r| r.0.clone())).collect();
    let count = u8::try_from(cfg.slots.len()).unwrap_or(u8::MAX);
    let start = slots::slots_to_start(count, &files);
    for (sc, file) in cfg.slots.iter().zip(&files) {
        log(&format!("slot {}: {}", sc.slot, file.as_deref().unwrap_or("off")));
        systemctl(cfg, if start.contains(&sc.slot) { "start" } else { "stop" }, &sc.target);
    }
    let shared = Arc::new(Mutex::new(snapshot(cfg, &[], &probes)));
    let (tx, rx) = mpsc::channel();
    let (cfg2, shared2) = (cfg.clone(), Arc::clone(&shared));
    std::thread::spawn(move || refresher(&cfg2, probes, &shared2, &rx));
    serve_http(cfg, &shared, &tx)
}
