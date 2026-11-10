//! The Hermes session id the creature talks under. It starts as the configured
//! base, can be reset to `<base>-<unix seconds>` to start a fresh conversation,
//! and is kept on disk so a bridge restart continues the same conversation.
//! The id itself is never logged.

use std::path::PathBuf;
use std::sync::Mutex;

pub struct SessionId {
    base: String,
    path: Option<PathBuf>,
    current: Mutex<String>,
}

impl SessionId {
    /// The saved id if the file holds a non-blank one, otherwise `base`.
    pub fn load(base: String, path: Option<PathBuf>) -> SessionId {
        let saved = path
            .as_ref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        let current = saved.unwrap_or_else(|| base.clone());
        SessionId { base, path, current: Mutex::new(current) }
    }

    pub fn current(&self) -> String {
        self.current.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Switch to a fresh id and save it. A failed write is logged (error kind
    /// only) and the new id stays in memory.
    pub fn reset(&self, now_secs: i64) -> String {
        let id = format!("{}-{now_secs}", self.base);
        let mut cur = self.current.lock().unwrap_or_else(|e| e.into_inner());
        *cur = id.clone();
        if let Some(p) = &self.path {
            if let Err(e) = std::fs::write(p, &id) {
                eprintln!("voice: session id not saved: {:?}", e.kind());
            }
        }
        id
    }
}
