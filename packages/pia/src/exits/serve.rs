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
/// A probe command that takes longer than this is killed and read as a failure, so a
/// wedged tailscaled or systemd cannot freeze the snapshot HA reads.
const PROBE_LIMIT: Duration = Duration::from_secs(5);
/// curl inside the namespace has its own `--max-time 10`; this only backs it up.
const EGRESS_LIMIT: Duration = Duration::from_secs(15);

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
    namespace_active: bool,
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
        namespace_active: p.namespace_active,
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

fn read_files(cfg: &ExitsConfig) -> Vec<Option<String>> {
    cfg.slots.iter().map(|sc| slots::read_region(&sc.region_file).map(|r| r.0)).collect()
}

/// Brings a snapshot built from an earlier read of the region files up to date with
/// `files`, read again under the snapshot's lock. A POST writes its file before it takes
/// that lock, so a choice recorded while a pass was probing is never published over:
/// `current` (the conflict check) and each changed slot's option, region and country
/// follow the files, and its state is `off` or, for a region just chosen, `starting`;
/// the rest of a changed slot's status waits for the next pass.
fn reconcile(snap: &mut Snapshot, files: &[Option<String>]) {
    for (status, file) in snap.slots.iter_mut().zip(files) {
        if status.region == *file {
            continue;
        }
        status.region.clone_from(file);
        status.option = file.as_deref().map_or_else(|| "Off".to_string(), |id| label(&snap.offered, id));
        status.country = file
            .as_deref()
            .and_then(|id| snap.offered.iter().find(|o| o.id == id))
            .map(|o| o.country.clone());
        status.state = if file.is_none() { State::Off } else { State::Starting };
    }
    snap.current = files.to_vec();
    let in_use: Vec<&str> = files.iter().flatten().map(String::as_str).collect();
    snap.options = regions::options(&snap.offered, &in_use);
}

fn handshake_age(cfg: &ExitsConfig, sc: &SlotConfig) -> Option<i64> {
    let wg = cfg.wg.to_string_lossy();
    let args = ["netns", "exec", &sc.namespace, &wg, "show", &sc.interface, "latest-handshakes"];
    let latest = watchdog::latest_handshake(&cmd::stdout_within(&cfg.ip, &args, PROBE_LIMIT).ok()?);
    (latest != 0).then(|| (Utc::now().timestamp() - latest).max(0))
}

fn check_egress(cfg: &ExitsConfig, sc: &SlotConfig) -> Result<Egress> {
    let curl = cfg.curl.to_string_lossy();
    let args = ["netns", "exec", &sc.namespace, &curl, "-s", "--max-time", "10", EGRESS_URL];
    let body = cmd::stdout_within(&cfg.ip, &args, EGRESS_LIMIT)?;
    status::parse_egress(&body).ok_or_else(|| anyhow!("unexpected answer from {EGRESS_URL}"))
}

/// One pass over a slot: re-read its region, then probe the tunnel if its namespace is up.
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
    // The namespace, not the target: the target stays active when connect fails or the
    // namespace is stopped, and then the slot must read `down`.
    let ns_unit = format!("{}.service", sc.namespace);
    p.namespace_active = cmd::succeeds_within(&cfg.systemctl, &["is-active", "--quiet", &ns_unit], PROBE_LIMIT);
    if !p.namespace_active {
        p.handshake_age_s = None;
        p.tailscale = Tailscale::default();
        return;
    }
    p.handshake_age_s = handshake_age(cfg, sc);
    let socket = sc.socket.to_string_lossy();
    p.tailscale = cmd::stdout_within(&cfg.tailscale, &["--socket", &socket, "status", "--json"], PROBE_LIMIT)
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
    p.egress_due = Some(now + egress_interval(settling, p.egress_ok));
}

/// A slot settling after a change, or whose last check failed, re-checks every pass:
/// after a reboot or a watchdog restart the region file is old, and a working slot must
/// not read degraded for 5 minutes on one failed check.
fn egress_interval(settling: bool, last_ok: bool) -> Duration {
    if settling || !last_ok { STATUS_EVERY } else { EGRESS_EVERY }
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
        let mut guard = lock(shared);
        *guard = snap;
        reconcile(&mut guard, &read_files(cfg));
        drop(guard);
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

/// After a change is applied: bring the snapshot up to date with the region files and
/// answer with the slot's new status, so HA's refresh right after reads the new option.
fn applied(snap: &mut Snapshot, files: &[Option<String>], slot: u8) -> String {
    reconcile(snap, files);
    snap.slots
        .get(usize::from(slot) - 1)
        .and_then(|s| serde_json::to_string(s).ok())
        .unwrap_or_default()
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
                    r.body = applied(&mut snap, &read_files(cfg), slot);
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
    // A dead refresher would leave /status serving a frozen snapshot while POSTs still
    // work, so its panic ends the process and systemd (Restart=always) starts it afresh.
    std::thread::spawn(move || {
        let run = std::panic::AssertUnwindSafe(|| refresher(&cfg2, probes, &shared2, &rx));
        if std::panic::catch_unwind(run).is_err() {
            log("the refresher panicked; exiting");
            std::process::exit(1);
        }
    });
    serve_http(cfg, &shared, &tx)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(slot: u8, region: Option<&str>, state: State) -> SlotStatus {
        SlotStatus {
            slot,
            option: region.map_or("Off".into(), |r| format!("L-{r}")),
            region: region.map(str::to_string),
            country: region.map(|_| "XX".into()),
            state,
            handshake_age_s: None,
            tailscale: "stopped",
            hostname: String::new(),
            egress_ip: None,
            egress_country: None,
            egress_checked: None,
        }
    }

    fn stale() -> Snapshot {
        let offered = ["br", "ca"]
            .iter()
            .map(|i| Offered { label: format!("L-{i}"), id: i.to_string(), country: i.to_uppercase() })
            .collect();
        Snapshot {
            options: vec!["Off".into(), "L-br".into(), "L-ca".into()],
            offered,
            slots: vec![status(1, None, State::Off), status(2, Some("ca"), State::Up)],
            current: vec![None, Some("ca".into())],
        }
    }

    #[test]
    fn reconcile_keeps_a_choice_made_during_a_pass() {
        // The pass read slot 1 as Off; a POST then chose br for it.
        let mut snap = stale();
        reconcile(&mut snap, &[Some("br".into()), Some("ca".into())]);
        assert_eq!(snap.current, vec![Some("br".to_string()), Some("ca".to_string())]);
        assert_eq!(snap.slots[0].option, "L-br");
        assert_eq!(snap.slots[0].region.as_deref(), Some("br"));
        assert_eq!(snap.slots[0].country.as_deref(), Some("BR"));
        // The conflict check now sees it.
        let r = super::super::http::handle("POST", "/slots/2", r#"{"option":"L-br"}"#, &snap);
        assert_eq!(r.code, 409);
    }

    #[test]
    fn reconcile_turns_a_slot_off() {
        let mut snap = stale();
        reconcile(&mut snap, &[None, None]);
        assert_eq!(snap.current, vec![None, None]);
        assert_eq!(snap.slots[1].option, "Off");
        assert_eq!(snap.slots[1].state, State::Off);
        assert!(snap.slots[1].country.is_none());
    }

    #[test]
    fn reconcile_leaves_unchanged_slots_alone() {
        let mut snap = stale();
        reconcile(&mut snap, &[None, Some("ca".into())]);
        assert_eq!(snap.slots[1].state, State::Up);
        assert_eq!(snap.slots[1].option, "L-ca");
    }

    #[test]
    fn reconcile_marks_a_new_region_starting() {
        let mut snap = stale();
        reconcile(&mut snap, &[Some("br".into()), Some("ca".into())]);
        assert_eq!(snap.slots[0].state, State::Starting);
    }

    #[test]
    fn applied_answers_with_the_new_status() {
        let mut snap = stale();
        let body = applied(&mut snap, &[Some("br".into()), Some("ca".into())], 1);
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(v["option"], "L-br");
        assert_eq!(v["region"], "br");
        assert_eq!(v["country"], "BR");
        assert_eq!(v["state"], "starting");
        // And /status (what HA's update_entity reads) shows it too.
        let s = super::super::http::handle("GET", "/status", "", &snap);
        let v: serde_json::Value = serde_json::from_str(&s.body).unwrap();
        assert_eq!(v["slots"][0]["option"], "L-br");
    }

    #[test]
    fn applied_off_answers_off() {
        let mut snap = stale();
        let body = applied(&mut snap, &[None, None], 2);
        let v: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!((v["option"].as_str(), v["state"].as_str()), (Some("Off"), Some("off")));
    }

    #[test]
    fn egress_retries_at_status_cadence_after_a_failure() {
        assert_eq!(egress_interval(false, true), EGRESS_EVERY);
        assert_eq!(egress_interval(false, false), STATUS_EVERY);
        assert_eq!(egress_interval(true, true), STATUS_EVERY);
    }

    #[test]
    fn reconcile_offers_an_unlisted_in_use_region() {
        let mut snap = stale();
        reconcile(&mut snap, &[Some("gone".into()), Some("ca".into())]);
        assert_eq!(snap.slots[0].option, "gone");
        assert!(snap.options.iter().any(|o| o == "gone"));
    }
}
