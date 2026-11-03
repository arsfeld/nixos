//! The plab assistant: on-demand recommendations and chat over OpenRouter, with read-only
//! tools. Every conversation is stored (`conversation`/`message` in state.db).
//! Design: docs/superpowers/specs/2026-11-03-plab-assistant-design.md

pub mod context;
pub mod tools;

use std::collections::HashSet;
use std::sync::Mutex;

use anyhow::Context as _;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::db::Db;
use crate::llm::OpenRouter;
use crate::stash::Stash;

pub const MAX_ROUNDS: usize = 6;
pub const RECOMMEND_ASK: &str = "Based on my recent views, recommend up to 5 scenes to watch and up to 5 releases to stream or download.";
const REASK: &str = "Reply with only the JSON object the instructions describe.";
const TITLE_CHARS: usize = 60;

/// How a final answer is shaped. Format, not content: it lives here, not in the secret.
const FINAL_FORMAT: &str = r#"When you answer, reply with only a JSON object:
{"text": "<your answer>", "picks": [{"ref": "<ref>", "action": "watch" | "stream" | "download", "reason": "<one line>"}]}
Use only refs given in CANDIDATES or returned by a tool. "watch" is for s: refs; "stream" and "download" are for t: refs. picks may be empty."#;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Recommend,
    Chat,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Recommend => "recommend",
            Kind::Chat => "chat",
        }
    }
}

#[derive(Debug)]
pub enum TurnError {
    NotReady(&'static str),
    NotFound,
    Busy,
    Failed(anyhow::Error),
}

impl std::fmt::Display for TurnError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TurnError::NotReady(why) => f.write_str(why),
            TurnError::NotFound => f.write_str("no such conversation"),
            TurnError::Busy => f.write_str("a reply is already being written"),
            TurnError::Failed(e) => write!(f, "{e:#}"),
        }
    }
}

impl From<anyhow::Error> for TurnError {
    fn from(e: anyhow::Error) -> Self {
        TurnError::Failed(e)
    }
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Pick {
    #[serde(rename = "ref")]
    pub ref_: String,
    pub action: String,
    #[serde(default)]
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Final {
    pub text: String,
    #[serde(default)]
    pub picks: Vec<Pick>,
}

pub fn parse_final(content: &str) -> Option<Final> {
    let s = content.trim();
    let s = s.strip_prefix("```json").or_else(|| s.strip_prefix("```")).unwrap_or(s);
    let s = s.strip_suffix("```").unwrap_or(s).trim();
    let v: Value = serde_json::from_str(s).ok()?;
    if !v.is_object() {
        return None;
    }
    serde_json::from_value(v).ok()
}

pub fn is_hidden(msg: &Value) -> bool {
    msg.get("plab_hidden").and_then(Value::as_bool) == Some(true)
}

pub fn error_of(msg: &Value) -> Option<&str> {
    msg.get("plab_error").and_then(Value::as_str)
}

pub fn degraded_of(msg: &Value) -> Vec<String> {
    msg.get("plab_degraded")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

fn title(kind: Kind, text: Option<&str>, now: i64) -> String {
    match kind {
        Kind::Recommend => format!("Recommendations · {}", crate::taste::ymd(now)),
        Kind::Chat => text.unwrap_or("").trim().chars().take(TITLE_CHARS).collect(),
    }
}

/// The stored message with plab's own keys removed: what the model is sent.
fn wire(mut msg: Value) -> Value {
    if let Some(o) = msg.as_object_mut() {
        o.retain(|k, _| !k.starts_with("plab_"));
    }
    msg
}

fn call_ids(msg: &Value) -> Option<Vec<Option<&str>>> {
    let calls = msg.get("tool_calls")?.as_array()?;
    (!calls.is_empty()).then(|| calls.iter().map(|c| c.get("id").and_then(Value::as_str)).collect())
}

/// Keep only complete tool rounds: an assistant `tool_calls` message survives only when
/// the tool messages right after it answer every one of its call ids, and a tool message
/// survives only inside such a round. Rounds are stored atomically, so this is a backstop
/// for a history written before that was true; the provider rejects any other shape, and
/// would reject every later turn of the conversation with it.
fn complete_rounds(msgs: Vec<Value>) -> Vec<Value> {
    let is_tool = |m: &Value| m.get("role").and_then(Value::as_str) == Some("tool");
    let mut out = vec![];
    let mut i = 0;
    while i < msgs.len() {
        let Some(ids) = call_ids(&msgs[i]) else {
            if !is_tool(&msgs[i]) {
                out.push(msgs[i].clone());
            }
            i += 1;
            continue;
        };
        let end = (i + 1..msgs.len()).find(|&j| !is_tool(&msgs[j])).unwrap_or(msgs.len());
        let answered: HashSet<&str> = msgs[i + 1..end]
            .iter()
            .filter_map(|m| m.get("tool_call_id").and_then(Value::as_str))
            .collect();
        if ids.iter().all(|id| id.is_some_and(|id| answered.contains(id))) {
            out.extend_from_slice(&msgs[i..end]);
        } else {
            tracing::info!(job = "assistant", "dropping an unanswered tool round from the history");
        }
        i = end;
    }
    out
}

pub struct TurnGuard<'a> {
    busy: &'a Mutex<HashSet<i64>>,
    id: i64,
}

impl Drop for TurnGuard<'_> {
    fn drop(&mut self) {
        self.busy.lock().unwrap_or_else(|e| e.into_inner()).remove(&self.id);
    }
}

pub struct Assistant {
    llm: OpenRouter,
    stash: Stash,
    model: String,
    prompt: String,
    busy: Mutex<HashSet<i64>>,
    hide: crate::filters::HideRule,
}

impl Assistant {
    pub fn new(llm: OpenRouter, stash: Stash, model: String, prompt: String) -> Assistant {
        Assistant { llm, stash, model, prompt, busy: Mutex::new(HashSet::new()), hide: crate::filters::HideRule::default() }
    }

    /// The exclude file's hide rule, applied to the Stash scenes the model sees.
    pub fn with_hide(mut self, hide: crate::filters::HideRule) -> Assistant {
        self.hide = hide;
        self
    }

    pub fn stash(&self) -> &Stash {
        &self.stash
    }

    pub fn ready(&self) -> Result<(), TurnError> {
        if self.prompt.trim().is_empty() {
            return Err(TurnError::NotReady("the assistant prompt is not set in plab-site"));
        }
        Ok(())
    }

    pub fn lock(&self, conversation: i64) -> Result<TurnGuard<'_>, TurnError> {
        let mut busy = self.busy.lock().unwrap_or_else(|e| e.into_inner());
        if !busy.insert(conversation) {
            return Err(TurnError::Busy);
        }
        Ok(TurnGuard { busy: &self.busy, id: conversation })
    }

    pub async fn start(&self, db: &Db, kind: Kind, text: Option<&str>, now: i64) -> Result<i64, TurnError> {
        self.ready()?;
        let ctx = context::gather(db, &self.stash, &self.hide, now).await?;
        let mut content = format!(
            "{}\n\nPROFILE:\n{}\n\nCANDIDATES:\n{}",
            self.prompt,
            serde_json::to_string(&ctx.profile).context("profile")?,
            serde_json::to_string(&ctx.candidates).context("candidates")?,
        );
        if !ctx.degraded.is_empty() {
            content.push_str("\n\nStash could not be reached: the profile has only plab's stream log, and there are no watch candidates.");
        }
        content.push_str("\n\n");
        content.push_str(FINAL_FORMAT);
        let id = db.create_conversation(&title(kind, text, now), kind.as_str(), now)?;
        let system = json!({"role": "system", "content": content, "plab_degraded": ctx.degraded});
        db.append_message(id, "system", &system.to_string(), now)?;
        self.turn(db, id, Some(text.unwrap_or(RECOMMEND_ASK)), now).await?;
        Ok(id)
    }

    fn store(&self, db: &Db, id: i64, msg: &Value, now: i64) -> anyhow::Result<()> {
        let role = msg.get("role").and_then(Value::as_str).unwrap_or("assistant");
        db.append_message(id, role, &msg.to_string(), now)?;
        Ok(())
    }

    fn fail(&self, db: &Db, id: i64, why: &str, now: i64) -> Result<(), TurnError> {
        tracing::info!(job = "assistant", "conversation {id}: {why}");
        self.store(db, id, &json!({"role": "assistant", "content": "", "plab_error": why}), now)?;
        Ok(())
    }

    /// The stored history as the model is sent it: errors and incomplete tool rounds
    /// dropped, plab keys stripped.
    fn history(&self, db: &Db, id: i64) -> anyhow::Result<Vec<Value>> {
        let mut out = vec![];
        for m in db.messages(id)? {
            let v: Value = serde_json::from_str(&m.content).context("stored message")?;
            if error_of(&v).is_none() {
                out.push(wire(v));
            }
        }
        Ok(complete_rounds(out))
    }

    pub async fn turn(&self, db: &Db, id: i64, text: Option<&str>, now: i64) -> Result<(), TurnError> {
        self.ready()?;
        let _guard = self.lock(id)?;
        if db.conversation(id)?.is_none() {
            return Err(TurnError::NotFound);
        }
        match text {
            Some(t) => self.store(db, id, &json!({"role": "user", "content": t}), now)?,
            None => {
                // Retry: drop what the failed turn left after its user message.
                let msgs = db.messages(id)?;
                let Some(user) = msgs.iter().rev().find(|m| {
                    m.role == "user"
                        && serde_json::from_str::<Value>(&m.content).is_ok_and(|v| !is_hidden(&v))
                }) else {
                    return Err(TurnError::NotFound);
                };
                db.delete_messages_from(id, user.seq + 1)?;
            }
        }
        let mut reasked = false;
        for _ in 0..MAX_ROUNDS {
            let body = json!({"model": self.model, "messages": self.history(db, id)?, "tools": tools::definitions()});
            let reply = match self.llm.chat(&body).await {
                Ok(r) => r,
                Err(e) => return self.fail(db, id, &format!("OpenRouter: {e:#}"), now),
            };
            let Some(msg) = reply.pointer("/choices/0/message").cloned() else {
                return self.fail(db, id, "OpenRouter: no message in the reply", now);
            };
            let calls = msg.get("tool_calls").and_then(Value::as_array).cloned().unwrap_or_default();
            if !calls.is_empty() {
                // The call and its results are stored together or not at all: a round
                // stored half-way is a history the provider rejects from then on.
                let mut round = vec![("assistant", msg.to_string())];
                for c in calls {
                    let name = c.pointer("/function/name").and_then(Value::as_str).unwrap_or("");
                    let args = c.pointer("/function/arguments").and_then(Value::as_str).unwrap_or("{}");
                    let result = tools::run(&self.stash, db, &self.hide, name, args, now).await;
                    let call_id = c.get("id").cloned().unwrap_or(Value::Null);
                    round.push(("tool", json!({"role": "tool", "tool_call_id": call_id, "content": result}).to_string()));
                }
                db.append_messages(id, &round, now)?;
                continue;
            }
            let content = msg.get("content").and_then(Value::as_str).unwrap_or("");
            if parse_final(content).is_some() {
                self.store(db, id, &json!({"role": "assistant", "content": content}), now)?;
                return Ok(());
            }
            if reasked {
                return self.fail(db, id, "the reply was not the JSON answer, twice", now);
            }
            reasked = true;
            self.store(db, id, &json!({"role": "assistant", "content": content, "plab_hidden": true}), now)?;
            self.store(db, id, &json!({"role": "user", "content": REASK, "plab_hidden": true}), now)?;
        }
        self.fail(db, id, &format!("the assistant used its {MAX_ROUNDS} rounds without answering"), now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use wiremock::matchers::{body_string_contains, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn reply(message: Value) -> ResponseTemplate {
        ResponseTemplate::new(200).set_body_json(json!({"choices": [{"message": message}]}))
    }

    fn final_reply(text: &str, picks: Value) -> ResponseTemplate {
        reply(json!({"role": "assistant", "content": json!({"text": text, "picks": picks}).to_string()}))
    }

    fn tool_call(name: &str, args: &str) -> ResponseTemplate {
        reply(json!({"role": "assistant", "content": null, "tool_calls": [
            {"id": "c1", "type": "function", "function": {"name": name, "arguments": args}}
        ]}))
    }

    /// OpenRouter and Stash on one mock server; Stash answers every query with no scenes.
    async fn fixture() -> (MockServer, Assistant, Db) {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/graphql"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"data": {"findScenes": {"scenes": []}}})))
            .mount(&server)
            .await;
        let llm = OpenRouter::new(&server.uri(), "k".into(), "p".into(), "j".into());
        let stash = Stash::new(&format!("{}/graphql", server.uri()), None);
        let a = Assistant::new(llm, stash, "m".into(), "Be helpful.".into());
        (server, a, Db::open_in_memory().unwrap())
    }

    /// The bodies of every chat request the mock received.
    async fn sent(server: &MockServer) -> Vec<String> {
        server
            .received_requests()
            .await
            .unwrap()
            .into_iter()
            .filter(|r| r.url.path() == crate::llm::CHAT_PATH)
            .map(|r| String::from_utf8(r.body).unwrap())
            .collect()
    }

    fn roles(db: &Db, id: i64) -> Vec<String> {
        db.messages(id).unwrap().into_iter().map(|m| m.role).collect()
    }

    fn last(db: &Db, id: i64) -> Value {
        serde_json::from_str(&db.messages(id).unwrap().last().unwrap().content).unwrap()
    }

    #[tokio::test]
    async fn a_tool_round_then_an_answer() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .and(body_string_contains("tool_call_id"))
            .respond_with(final_reply("Try these.", json!([{"ref": "t:1", "action": "download", "reason": "r"}])))
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(tool_call("search_lists", r#"{"q":"alpha"}"#))
            .with_priority(2)
            .mount(&server)
            .await;
        let id = a.start(&db, Kind::Recommend, None, 86400).await.unwrap();
        assert_eq!(roles(&db, id), vec!["system", "user", "assistant", "tool", "assistant"]);
        assert!(sent(&server).await.iter().all(|b| !b.contains("plab_")));
        let f = parse_final(last(&db, id)["content"].as_str().unwrap()).unwrap();
        assert_eq!(f.text, "Try these.");
        assert_eq!(f.picks[0].ref_, "t:1");
        let c = db.conversation(id).unwrap().unwrap();
        assert_eq!((c.kind.as_str(), c.title.as_str()), ("recommend", "Recommendations · 1970-01-02"));
    }

    /// Covers the tool path only: a fresh profile has no views, so `gather` never queries
    /// Stash for candidates and the scenes reach the model through `find_stash_scenes`.
    #[tokio::test]
    async fn hidden_scenes_never_reach_the_model() {
        let server = MockServer::start().await;
        let scenes = json!({"data": {"findScenes": {"scenes": [
            {"id": "1", "title": "Pear Scene", "tags": [{"id": "t1", "name": "Pear"}],
             "performers": [{"id": "p1", "name": "Ann", "gender": "FEMALE"}], "play_count": 0},
            {"id": "2", "title": "Fig Scene", "tags": [{"id": "t2", "name": "Fig"}],
             "performers": [{"id": "p1", "name": "Ann", "gender": "FEMALE"}], "play_count": 0}
        ]}}});
        Mock::given(path("/graphql"))
            .respond_with(ResponseTemplate::new(200).set_body_json(scenes))
            .mount(&server)
            .await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(tool_call("find_stash_scenes", r#"{"q":"scene"}"#))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(final_reply("ok", json!([])))
            .mount(&server)
            .await;
        let llm = OpenRouter::new(&server.uri(), "k".into(), "p".into(), "j".into());
        let stash = Stash::new(&format!("{}/graphql", server.uri()), None);
        let rule = crate::filters::HideRule { hide: vec!["pear".into()], keep: vec![] };
        let a = Assistant::new(llm, stash, "m".into(), "x".into()).with_hide(rule);
        let db = Db::open_in_memory().unwrap();
        a.start(&db, Kind::Chat, Some("hi"), 0).await.unwrap();
        let all = sent(&server).await.join("\n");
        assert!(all.contains("Fig Scene"));
        assert!(!all.contains("Pear Scene"));
    }

    #[tokio::test]
    async fn the_round_cap_stores_an_error() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(tool_call("recent_views", "{}"))
            .expect(MAX_ROUNDS as u64)
            .mount(&server)
            .await;
        let id = a.start(&db, Kind::Chat, Some("hello"), 0).await.unwrap();
        assert!(error_of(&last(&db, id)).unwrap().contains("rounds"));
    }

    #[tokio::test]
    async fn a_malformed_answer_is_re_asked_once() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(reply(json!({"role": "assistant", "content": "not json"})))
            .expect(2)
            .mount(&server)
            .await;
        let id = a.start(&db, Kind::Chat, Some("hello"), 0).await.unwrap();
        let msgs: Vec<Value> = db.messages(id).unwrap().iter().map(|m| serde_json::from_str(&m.content).unwrap()).collect();
        assert!(msgs.iter().any(is_hidden));
        assert!(error_of(msgs.last().unwrap()).is_some());
        // The re-ask resends the hidden messages, without plab's own keys.
        let bodies = sent(&server).await;
        assert_eq!(bodies.len(), 2);
        assert!(bodies[1].contains(REASK));
        assert!(bodies.iter().all(|b| !b.contains("plab_")), "{bodies:?}");
    }

    #[tokio::test]
    async fn an_unanswered_tool_round_is_not_sent() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH)).respond_with(final_reply("ok", json!([]))).mount(&server).await;
        let id = db.create_conversation("t", "chat", 0).unwrap();
        for m in [
            json!({"role": "system", "content": "s", "plab_degraded": []}),
            json!({"role": "user", "content": "first"}),
            // A turn cancelled between storing the call and storing its result.
            json!({"role": "assistant", "content": null, "tool_calls": [
                {"id": "dangling", "type": "function", "function": {"name": "recent_views", "arguments": "{}"}}
            ]}),
            json!({"role": "tool", "tool_call_id": "orphan", "content": "[]"}),
        ] {
            db.append_message(id, m["role"].as_str().unwrap(), &m.to_string(), 0).unwrap();
        }
        a.turn(&db, id, Some("again"), 1).await.unwrap();
        assert!(error_of(&last(&db, id)).is_none());
        let body = sent(&server).await.pop().unwrap();
        assert!(!body.contains("dangling") && !body.contains("orphan"), "{body}");
        assert!(body.contains("first") && body.contains("again"));
        assert!(!body.contains("plab_"), "{body}");
    }

    #[test]
    fn complete_rounds_keep_answered_calls() {
        let call = |ids: &[&str]| {
            json!({"role": "assistant", "tool_calls": ids.iter().map(|i| json!({"id": i})).collect::<Vec<_>>()})
        };
        let result = |id: &str| json!({"role": "tool", "tool_call_id": id});
        let user = json!({"role": "user", "content": "u"});
        let full = vec![user.clone(), call(&["a", "b"]), result("b"), result("a"), user.clone()];
        assert_eq!(complete_rounds(full.clone()), full);
        let partial = vec![user.clone(), call(&["a", "b"]), result("a"), user.clone()];
        assert_eq!(complete_rounds(partial), vec![user.clone(), user.clone()]);
    }

    #[tokio::test]
    async fn retry_replaces_the_error() {
        let (server, a, db) = fixture().await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(ResponseTemplate::new(500))
            .up_to_n_times(1)
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(final_reply("ok", json!([])))
            .with_priority(2)
            .mount(&server)
            .await;
        let id = a.start(&db, Kind::Chat, Some("hello"), 0).await.unwrap();
        assert!(error_of(&last(&db, id)).is_some());
        a.turn(&db, id, None, 1).await.unwrap();
        assert_eq!(roles(&db, id), vec!["system", "user", "assistant"]);
        assert!(error_of(&last(&db, id)).is_none());
    }

    #[tokio::test]
    async fn stash_down_is_degraded_not_fatal() {
        let server = MockServer::start().await;
        Mock::given(path("/graphql")).respond_with(ResponseTemplate::new(500)).mount(&server).await;
        Mock::given(path(crate::llm::CHAT_PATH)).respond_with(final_reply("ok", json!([]))).mount(&server).await;
        let llm = OpenRouter::new(&server.uri(), "k".into(), "p".into(), "j".into());
        let a = Assistant::new(llm, Stash::new(&format!("{}/graphql", server.uri()), None), "m".into(), "x".into());
        let db = Db::open_in_memory().unwrap();
        let id = a.start(&db, Kind::Chat, Some("hi"), 0).await.unwrap();
        let system: Value = serde_json::from_str(&db.messages(id).unwrap()[0].content).unwrap();
        assert_eq!(degraded_of(&system), vec!["stash"]);
        let bodies = sent(&server).await;
        assert!(!bodies.is_empty() && bodies.iter().all(|b| !b.contains("plab_")), "{bodies:?}");
    }

    #[tokio::test]
    async fn busy_and_missing() {
        let (_server, a, db) = fixture().await;
        let id = db.create_conversation("t", "chat", 0).unwrap();
        let _g = a.lock(id).unwrap();
        assert!(matches!(a.turn(&db, id, Some("x"), 0).await, Err(TurnError::Busy)));
        assert!(matches!(a.turn(&db, 999, Some("x"), 0).await, Err(TurnError::NotFound)));
    }

    #[test]
    fn not_ready_without_a_prompt() {
        let llm = OpenRouter::new("http://x", "k".into(), "p".into(), "j".into());
        let a = Assistant::new(llm, Stash::new("http://x", None), "m".into(), "  ".into());
        assert!(matches!(a.ready(), Err(TurnError::NotReady(_))));
    }

    #[test]
    fn parse_final_tolerates_a_fence() {
        let f = parse_final("```json\n{\"text\": \"hi\"}\n```").unwrap();
        assert_eq!(f.text, "hi");
        assert!(f.picks.is_empty());
        assert!(parse_final("[1]").is_none());
    }

    #[test]
    fn chat_titles_are_truncated() {
        assert_eq!(title(Kind::Chat, Some(&"x".repeat(80)), 0).chars().count(), 60);
    }
}
