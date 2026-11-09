//! Live session list derived from hook events.

use std::collections::HashMap;

use crate::protocol::{Event, EventKind, Session, State};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    Upsert(Session),
    Remove { host: String, session: String },
}

struct Entry {
    session: Session,
    last_seen: i64,
}

pub struct Registry {
    expire_secs: i64,
    sessions: HashMap<(String, String), Entry>,
}

/// The last path component of `cwd`, ignoring trailing slashes.
pub fn project_of(cwd: &str) -> String {
    let name = cwd.trim_end_matches('/').rsplit('/').next().unwrap_or("");
    if name.is_empty() { "unknown".into() } else { name.into() }
}

impl Registry {
    pub fn new(expire_secs: i64) -> Registry {
        Registry { expire_secs, sessions: HashMap::new() }
    }

    pub fn apply(&mut self, e: &Event) -> Option<Change> {
        let target = match &e.event {
            EventKind::SessionEnd => {
                return self
                    .sessions
                    .remove(&(e.host.clone(), e.session.clone()))
                    .map(|_| Change::Remove { host: e.host.clone(), session: e.session.clone() });
            }
            EventKind::SessionStart => State::Idle,
            EventKind::UserPromptSubmit => State::Working,
            EventKind::Stop => State::Done,
            EventKind::StopFailure => State::Error,
            EventKind::Notification { kind } => match kind.as_str() {
                "permission_prompt" => State::Waiting,
                "idle_prompt" => State::Idle,
                _ => return None,
            },
        };
        self.transition(&e.host, &e.session, &e.cwd, target, e.ts)
    }

    /// A held question request marks its session as waiting on the user.
    pub fn set_waiting(&mut self, host: &str, session: &str, cwd: &str, ts: i64) -> Option<Change> {
        self.transition(host, session, cwd, State::Waiting, ts)
    }

    /// A held question was answered: Claude carries on.
    pub fn set_working(&mut self, host: &str, session: &str, cwd: &str, ts: i64) -> Option<Change> {
        self.transition(host, session, cwd, State::Working, ts)
    }

    fn transition(&mut self, host: &str, session: &str, cwd: &str, state: State, ts: i64) -> Option<Change> {
        let key = (host.to_string(), session.to_string());
        match self.sessions.get_mut(&key) {
            Some(entry) => {
                entry.last_seen = ts;
                let new_cwd = if cwd.is_empty() { entry.session.cwd.clone() } else { cwd.to_string() };
                let changed_state = entry.session.state != state;
                if !changed_state && new_cwd == entry.session.cwd {
                    return None;
                }
                if changed_state {
                    entry.session.state = state;
                    entry.session.since = ts;
                }
                entry.session.project = project_of(&new_cwd);
                entry.session.cwd = new_cwd;
                Some(Change::Upsert(entry.session.clone()))
            }
            None => {
                let s = Session {
                    host: host.into(),
                    session: session.into(),
                    project: project_of(cwd),
                    cwd: cwd.into(),
                    state,
                    since: ts,
                };
                self.sessions.insert(key, Entry { session: s.clone(), last_seen: ts });
                Some(Change::Upsert(s))
            }
        }
    }

    /// Drop sessions that have had no event for more than `expire_secs`.
    pub fn expire(&mut self, now: i64) -> Vec<Change> {
        let limit = self.expire_secs;
        let stale: Vec<_> = self
            .sessions
            .iter()
            .filter(|(_, v)| now - v.last_seen > limit)
            .map(|(k, _)| k.clone())
            .collect();
        stale
            .into_iter()
            .map(|k| {
                self.sessions.remove(&k);
                Change::Remove { host: k.0, session: k.1 }
            })
            .collect()
    }

    /// Waiting sessions first, then newest state change first.
    pub fn snapshot(&self) -> Vec<Session> {
        let mut v: Vec<Session> = self.sessions.values().map(|e| e.session.clone()).collect();
        v.sort_by(|a, b| {
            (b.state == State::Waiting)
                .cmp(&(a.state == State::Waiting))
                .then(b.since.cmp(&a.since))
                .then(a.host.cmp(&b.host))
                .then(a.session.cmp(&b.session))
        });
        v
    }
}
