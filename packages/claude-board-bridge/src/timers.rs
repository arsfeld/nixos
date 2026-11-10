//! The creature's timers: a small persistent store, in Toronto local time. Labels are never logged.

use std::fmt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use jiff::civil::DateTime;
use jiff::tz::{AmbiguousOffset, TimeZone};
use jiff::{Timestamp, Zoned};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;

pub const MAX_TIMERS: usize = 20;
pub const LABEL_MAX: usize = 200;
pub const MAX_AHEAD_SECS: i64 = 30 * 86_400;
/// A timer found this long after its due time is dropped rather than announced.
pub const REMINDER_GRACE_SECS: i64 = 3600;
pub const TZ: &str = "America/Toronto";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Timer {
    pub id: String,
    pub label: String,
    /// Unix seconds.
    pub due: i64,
}

pub enum When {
    In(u64),
    At(String),
}

#[derive(Debug)]
pub enum TimerError {
    BadTime(String),
    Full,
    BadLabel,
    NotFound,
    Ambiguous(Vec<Timer>),
}

impl fmt::Display for TimerError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TimerError::BadTime(m) => write!(f, "{m}"),
            TimerError::Full => write!(f, "There are already {MAX_TIMERS} timers."),
            TimerError::BadLabel => write!(f, "A timer needs a label of up to {LABEL_MAX} characters."),
            TimerError::NotFound => write!(f, "There is no such timer."),
            TimerError::Ambiguous(c) => {
                let names: Vec<&str> = c.iter().map(|t| t.label.as_str()).collect();
                write!(f, "More than one timer matches: {}. Say which one.", names.join(", "))
            }
        }
    }
}

pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

pub struct Due {
    pub timer: Timer,
    pub late_secs: i64,
}

#[derive(Serialize, Deserialize)]
struct File {
    version: u32,
    timers: Vec<Timer>,
}

struct Inner {
    timers: Vec<Timer>,
    path: Option<PathBuf>,
}

pub struct Timers {
    inner: Mutex<Inner>,
    clock: Clock,
    changed: watch::Sender<u64>,
}

fn tz() -> TimeZone {
    TimeZone::get(TZ).expect("bundled tz database has America/Toronto")
}

fn local(ts: i64) -> Zoned {
    Timestamp::from_second(ts).unwrap_or(Timestamp::UNIX_EPOCH).to_zoned(tz())
}

fn sibling(path: &std::path::Path, suffix: &str) -> PathBuf {
    let mut s = path.as_os_str().to_owned();
    s.push(suffix);
    PathBuf::from(s)
}

fn load(path: &std::path::Path) -> Vec<Timer> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return vec![],
        Err(_) => return quarantine(path),
    };
    match serde_json::from_str::<File>(&text) {
        Ok(f) if f.version == 1 => f.timers,
        _ => quarantine(path),
    }
}

fn quarantine(path: &std::path::Path) -> Vec<Timer> {
    let bad = sibling(path, ".bad");
    match std::fs::rename(path, &bad) {
        Ok(()) => eprintln!("timer: unreadable timers file moved to {}", bad.display()),
        Err(e) => eprintln!("timer: unreadable timers file could not be moved aside: {e}"),
    }
    vec![]
}

fn save(path: &std::path::Path, timers: &[Timer]) -> std::io::Result<()> {
    use std::io::Write;
    let tmp = sibling(path, ".tmp");
    let body = serde_json::to_vec(&File { version: 1, timers: timers.to_vec() }).map_err(std::io::Error::other)?;
    let mut f = std::fs::File::create(&tmp)?;
    f.write_all(&body)?;
    f.sync_all()?;
    drop(f);
    std::fs::rename(&tmp, path)
}

fn new_id(existing: &[Timer]) -> String {
    loop {
        let mut b = [0u8; 3];
        getrandom::fill(&mut b).expect("getrandom");
        let id = format!("tmr_{:02x}{:02x}{:02x}", b[0], b[1], b[2]);
        if !existing.iter().any(|t| t.id == id) {
            return id;
        }
    }
}

impl Timers {
    pub fn open(path: Option<PathBuf>, clock: Clock) -> Timers {
        let timers = path.as_deref().map(load).unwrap_or_default();
        let (changed, _) = watch::channel(0);
        Timers { inner: Mutex::new(Inner { timers, path }), clock, changed }
    }

    pub fn now(&self) -> i64 {
        (self.clock)()
    }

    fn commit(&self, inner: &Inner) {
        if let Some(p) = &inner.path {
            if let Err(e) = save(p, &inner.timers) {
                eprintln!("timer: save failed ({:?})", e.kind());
            }
        }
        self.changed.send_modify(|n| *n += 1);
    }

    pub fn set(&self, label: &str, when: When) -> Result<Timer, TimerError> {
        let label = label.trim();
        if label.is_empty() || label.len() > LABEL_MAX {
            return Err(TimerError::BadLabel);
        }
        let now = self.now();
        let due = match when {
            When::In(s) => {
                if s == 0 || s > MAX_AHEAD_SECS as u64 {
                    return Err(TimerError::BadTime("A timer must be between one second and thirty days away.".into()));
                }
                now + s as i64
            }
            When::At(text) => parse_at(&text)?,
        };
        if due <= now {
            return Err(TimerError::BadTime("That time is in the past.".into()));
        }
        if due > now + MAX_AHEAD_SECS {
            return Err(TimerError::BadTime("That is more than thirty days away.".into()));
        }
        let mut inner = self.inner.lock().unwrap();
        if inner.timers.len() >= MAX_TIMERS {
            return Err(TimerError::Full);
        }
        let timer = Timer { id: new_id(&inner.timers), label: label.to_string(), due };
        inner.timers.push(timer.clone());
        inner.timers.sort_by_key(|t| t.due);
        self.commit(&inner);
        Ok(timer)
    }

    pub fn list(&self) -> Vec<Timer> {
        let mut v = self.inner.lock().unwrap().timers.clone();
        v.sort_by_key(|t| t.due);
        v
    }

    pub fn cancel(&self, sel: &str) -> Result<Timer, TimerError> {
        let sel = sel.trim();
        let mut inner = self.inner.lock().unwrap();
        let idx = if let Some(i) = inner.timers.iter().position(|t| t.id == sel) {
            i
        } else {
            let hits: Vec<usize> = inner
                .timers
                .iter()
                .enumerate()
                .filter(|(_, t)| t.label.to_lowercase() == sel.to_lowercase())
                .map(|(i, _)| i)
                .collect();
            match hits.len() {
                0 => return Err(TimerError::NotFound),
                1 => hits[0],
                _ => return Err(TimerError::Ambiguous(hits.iter().map(|&i| inner.timers[i].clone()).collect())),
            }
        };
        let t = inner.timers.remove(idx);
        self.commit(&inner);
        Ok(t)
    }

    /// Removes every timer that is due; those more than the grace period late are dropped (logged
    /// without labels), the rest are returned.
    pub fn claim_due(&self) -> Vec<Due> {
        let now = self.now();
        let mut inner = self.inner.lock().unwrap();
        let (due, keep): (Vec<Timer>, Vec<Timer>) = inner.timers.drain(..).partition(|t| t.due <= now);
        inner.timers = keep;
        if due.is_empty() {
            return vec![];
        }
        self.commit(&inner);
        let mut out = vec![];
        for timer in due {
            let late_secs = now - timer.due;
            if late_secs > REMINDER_GRACE_SECS {
                eprintln!("timer: dropped id={} late_s={late_secs}", timer.id);
            } else {
                out.push(Due { timer, late_secs });
            }
        }
        out
    }

    pub fn next_due(&self) -> Option<i64> {
        self.inner.lock().unwrap().timers.iter().map(|t| t.due).min()
    }

    /// Bumped on every change to the set of timers.
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }
}

fn parse_at(text: &str) -> Result<i64, TimerError> {
    let bad = || TimerError::BadTime("I could not read that time. Use year, month, day, hour and minute.".into());
    let dt: DateTime = text.trim().parse().map_err(|_| bad())?;
    let az = tz().into_ambiguous_zoned(dt);
    if matches!(az.offset(), AmbiguousOffset::Gap { .. }) {
        return Err(TimerError::BadTime(format!(
            "{} does not exist on that day because the clocks change.",
            dt.strftime("%H:%M")
        )));
    }
    let z = az.earlier().map_err(|_| bad())?;
    Ok(z.timestamp().as_second())
}

/// `"18:42 today"`, `"09:00 tomorrow"`, else `"09:00 on Friday 13 November"`, local time.
pub fn when_words(due: i64, now: i64) -> String {
    let d = local(due);
    let n = local(now);
    let hm = d.strftime("%H:%M");
    let days = (d.date() - n.date()).get_days();
    match days {
        0 => format!("{hm} today"),
        1 => format!("{hm} tomorrow"),
        _ => format!("{hm} on {}", d.strftime("%A %-d %B")),
    }
}

pub fn rfc3339_local(due: i64) -> String {
    local(due).strftime("%Y-%m-%dT%H:%M:%S%:z").to_string()
}

pub fn spoken_reminder(d: &Due) -> String {
    if d.late_secs < 60 {
        format!("Reminder. {}.", d.timer.label)
    } else {
        format!("This was due at {}. {}.", local(d.timer.due).strftime("%H:%M"), d.timer.label)
    }
}
