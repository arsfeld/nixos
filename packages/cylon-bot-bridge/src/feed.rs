//! A bounded, in-memory activity feed per session.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

use cylon_bot_proto::fit;

use crate::protocol::{FeedEntry, FeedKind};

/// Entries kept per session.
const KEEP: usize = 200;

fn cap(kind: FeedKind) -> usize {
    match kind {
        FeedKind::Prompt => 2048,
        FeedKind::Tool => 1200,
        FeedKind::Result => 16,
        FeedKind::Reply => 4096,
        FeedKind::Other => 1200,
    }
}

#[derive(Default)]
struct Log {
    /// The `n` of the last entry appended.
    last: u64,
    entries: VecDeque<FeedEntry>,
}

#[derive(Default)]
pub struct Feed {
    inner: Mutex<HashMap<(String, String), Log>>,
}

impl Feed {
    pub fn new() -> Feed {
        Feed::default()
    }

    /// Store a line, cut to the kind's byte cap on a character boundary.
    pub fn append(&self, host: &str, session: &str, kind: FeedKind, text: &str, ts: i64) -> FeedEntry {
        let text = text[..fit(text, cap(kind))].to_string();
        let mut g = self.inner.lock().unwrap();
        let log = g.entry((host.into(), session.into())).or_default();
        log.last += 1;
        let entry = FeedEntry { n: log.last, ts, kind, text };
        log.entries.push_back(entry.clone());
        if log.entries.len() > KEEP {
            log.entries.pop_front();
        }
        entry
    }

    /// The newest `limit` entries, oldest first.
    pub fn history(&self, host: &str, session: &str, limit: usize) -> Vec<FeedEntry> {
        let g = self.inner.lock().unwrap();
        match g.get(&(host.to_string(), session.to_string())) {
            Some(log) => log.entries.iter().skip(log.entries.len().saturating_sub(limit)).cloned().collect(),
            None => Vec::new(),
        }
    }

    /// The newest entries, oldest first: at most `limit` of them, and no more than fit in `budget` bytes of
    /// JSON (each entry serialised, plus the comma between it and the next). Oldest entries are dropped first.
    pub fn history_within(&self, host: &str, session: &str, limit: usize, budget: usize) -> Vec<FeedEntry> {
        let mut newest_first = Vec::new();
        let mut used = 0;
        for e in self.history(host, session, limit).into_iter().rev() {
            let size = serde_json::to_string(&e).expect("FeedEntry serialises").len() + 1;
            if used + size > budget {
                break;
            }
            used += size;
            newest_first.push(e);
        }
        newest_first.reverse();
        newest_first
    }

    /// Keep only the logs whose (host, session) the predicate accepts.
    pub fn retain(&self, mut keep: impl FnMut(&str, &str) -> bool) {
        self.inner.lock().unwrap().retain(|(h, s), _| keep(h, s));
    }

    pub fn drop_session(&self, host: &str, session: &str) {
        self.inner.lock().unwrap().remove(&(host.to_string(), session.to_string()));
    }
}
