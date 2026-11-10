//! Questions Claude has asked, held open until the board answers.

use std::collections::{BTreeMap, HashMap};
use std::sync::Mutex;

use serde_json::{Map, Value, json};
use tokio::sync::oneshot;

pub use claude_board_proto::{AskId, PendingAsk, Question, QuestionOption};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Answered {
    /// Question text -> chosen label (multi-select labels already comma-joined).
    Answers(BTreeMap<String, String>),
    /// The user chose to answer on the computer: no decision is returned.
    Declined,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnswerError {
    /// Never issued, expired, cancelled, already answered, or nobody is waiting.
    Unknown,
}

struct Entry {
    seq: u64,
    ask: PendingAsk,
    tx: oneshot::Sender<Answered>,
}

#[derive(Default)]
struct Inner {
    next_seq: u64,
    entries: HashMap<AskId, Entry>,
}

#[derive(Default)]
pub struct Asks {
    inner: Mutex<Inner>,
}

fn new_id() -> AskId {
    let mut b = [0u8; 16];
    getrandom::fill(&mut b).expect("system randomness");
    AskId(b.iter().map(|x| format!("{x:02x}")).collect())
}

impl Asks {
    pub fn new() -> Asks {
        Asks::default()
    }

    /// Hold a question open. The receiver resolves when it is answered and
    /// errors when it is cancelled.
    pub fn register(
        &self,
        host: &str,
        session: &str,
        project: &str,
        tool_input: Value,
    ) -> (AskId, oneshot::Receiver<Answered>) {
        let questions: Vec<Question> = tool_input
            .get("questions")
            .and_then(|q| serde_json::from_value(q.clone()).ok())
            .unwrap_or_default();
        let id = new_id();
        let (tx, rx) = oneshot::channel();
        let mut g = self.inner.lock().unwrap();
        let seq = g.next_seq;
        g.next_seq += 1;
        let ask = PendingAsk {
            id: id.clone(),
            host: host.into(),
            session: session.into(),
            project: project.into(),
            questions,
        };
        g.entries.insert(id.clone(), Entry { seq, ask, tx });
        (id, rx)
    }

    /// Single-use: the entry is removed whether or not anyone still listens.
    pub fn answer(&self, id: &AskId, a: Answered) -> Result<(), AnswerError> {
        let entry = self.inner.lock().unwrap().entries.remove(id).ok_or(AnswerError::Unknown)?;
        entry.tx.send(a).map_err(|_| AnswerError::Unknown)
    }

    pub fn cancel(&self, id: &AskId) {
        self.inner.lock().unwrap().entries.remove(id);
    }

    pub fn cancel_session(&self, host: &str, session: &str) -> Vec<AskId> {
        let mut g = self.inner.lock().unwrap();
        let mut hit: Vec<(u64, AskId)> = g
            .entries
            .values()
            .filter(|e| e.ask.host == host && e.ask.session == session)
            .map(|e| (e.seq, e.ask.id.clone()))
            .collect();
        hit.sort_by_key(|(s, _)| *s);
        for (_, id) in &hit {
            g.entries.remove(id);
        }
        hit.into_iter().map(|(_, id)| id).collect()
    }

    pub fn pending(&self) -> Vec<PendingAsk> {
        let g = self.inner.lock().unwrap();
        let mut v: Vec<&Entry> = g.entries.values().collect();
        v.sort_by_key(|e| e.seq);
        v.into_iter().map(|e| e.ask.clone()).collect()
    }
}

/// The hook output that answers the question tool: the original input plus an
/// `answers` map keyed by exact question text. A bare `allow` would leave the
/// question open.
pub fn build_decision(tool_input: &Value, answers: &BTreeMap<String, String>) -> Value {
    let mut updated = tool_input.clone();
    let map: Map<String, Value> = answers.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect();
    if let Some(obj) = updated.as_object_mut() {
        obj.insert("answers".into(), Value::Object(map));
    }
    json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest",
        "decision": {"behavior": "allow", "updatedInput": updated}}})
}
