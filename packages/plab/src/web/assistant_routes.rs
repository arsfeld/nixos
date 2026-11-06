//! The assistant's routes (`/api/assistant/…`) and its transcript DTO. Picks resolve here,
//! at read time, so a release card shows its live status rather than the status it had
//! when the model named it.

use crate::backends::Backends;
use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Method, Response};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{WebState, json_body, not_found, now, send, text};
use crate::api::TopicDto;
use crate::assistant::context::{advisable, bounded};
use crate::assistant::{self, Assistant, Kind, TurnError};
use crate::db::{ConversationRow, Section};
use crate::stash::library::LibScene;

/// Request bodies are a chat message: 16 KB is generous.
const BODY_LIMIT: usize = 16 * 1024;

const NO_KEY: &str = "the assistant needs an OpenRouter key";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConversationSummaryDto {
    id: i64,
    title: String,
    kind: String,
    updated_at: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ConversationDto {
    id: i64,
    title: String,
    kind: String,
    updated_at: i64,
    now: i64,
    topic_url: String,
    /// What was missing when the conversation was built (from its system message).
    degraded: Vec<String>,
    /// Stash did not answer for this read, so the watch picks could not be resolved.
    scenes_unavailable: bool,
    turns: Vec<TurnDto>,
    topics: Vec<PickedTopic>,
    scenes: Vec<SceneDto>,
}

/// A picked release and the list it is on, which its card needs.
#[derive(Serialize)]
struct PickedTopic {
    #[serde(flatten)]
    topic: TopicDto,
    section: &'static str,
    /// Drawn from a stored search result whose search hit has expired: shown, not actionable.
    expired: bool,
}

#[derive(Serialize)]
struct TurnDto {
    seq: i64,
    role: &'static str,
    text: String,
    picks: Vec<PickDto>,
    error: Option<String>,
}

#[derive(Serialize)]
struct PickDto {
    #[serde(rename = "ref")]
    ref_: String,
    action: String,
    reason: String,
}

#[derive(Serialize)]
struct SceneDto {
    #[serde(rename = "ref")]
    ref_: String,
    id: String,
    title: String,
    studio: Option<String>,
    performers: Vec<String>,
    screenshot: Option<String>,
    link: Option<String>,
}

#[derive(Deserialize)]
struct TextBody {
    text: String,
}

/// Run a turn on its own task and wait for it. A turn runs for as long as the model takes,
/// and Cloudflare cuts a request at about 100 s; inside the handler future, the client
/// hanging up would cancel the turn wherever it stood. On a task it finishes regardless,
/// and the app finds the answer when it reloads the conversation.
async fn detached<R: Send + 'static>(
    turn: impl Future<Output = Result<R, TurnError>> + Send + 'static,
) -> Result<R, TurnError> {
    tokio::spawn(turn)
        .await
        .unwrap_or_else(|e| Err(TurnError::Failed(anyhow::anyhow!("the turn's task: {e}"))))
}

fn turn_error(e: TurnError) -> Response<Body> {
    let code = match e {
        TurnError::NotReady(_) => 503,
        TurnError::NotFound => 404,
        TurnError::Busy => 409,
        TurnError::Failed(_) => 500,
    };
    text(code, e.to_string())
}

async fn read_text(body: Body) -> Result<String, Box<Response<Body>>> {
    let bytes = axum::body::to_bytes(body, BODY_LIMIT)
        .await
        .map_err(|_| Box::new(text(413, "the message is too long")))?;
    let b: TextBody = serde_json::from_slice(&bytes)
        .map_err(|e| Box::new(text(400, format!("bad body: {e}"))))?;
    let t = b.text.trim();
    if t.is_empty() {
        return Err(Box::new(text(400, "text is required")));
    }
    Ok(t.to_string())
}

/// `conversations/<id>` and `conversations/<id>/<action>`.
fn conversation_path(rest: &str) -> Option<(i64, Option<&str>)> {
    let tail = rest.strip_prefix("conversations/")?;
    let (id, action) = match tail.split_once('/') {
        Some((id, a)) => (id, Some(a)),
        None => (tail, None),
    };
    Some((id.parse().ok()?, action))
}

pub(super) async fn route<B: Backends>(
    st: &WebState<B>,
    method: &Method,
    rest: &str,
    body: Body,
) -> Response<Body> {
    match (method, rest) {
        (&Method::GET, "daily") => return daily(st, false).await,
        (&Method::POST, "daily/refresh") => return daily(st, true).await,
        _ => {}
    }
    let Some(arc) = st.assistant.clone() else {
        return text(503, NO_KEY);
    };
    let a: &Assistant = &arc;
    let t = now();
    // A turn owns its assistant and database handles, so it can outlive the request.
    let owned = || (Arc::clone(&arc), st.db.clone());
    match (method, rest) {
        (&Method::GET, "conversations") => {
            let rows = a.ready().and_then(|()| {
                let mut out = vec![];
                for c in st.db.conversations()? {
                    if c.kind != Kind::Recommend.as_str()
                        || assistant::daily::followed_up(&st.db, c.id)?
                    {
                        out.push(c);
                    }
                }
                Ok(out)
            });
            match rows {
                Ok(rows) => json_body(
                    &rows
                        .into_iter()
                        .map(|c| ConversationSummaryDto {
                            id: c.id,
                            title: c.title,
                            kind: c.kind,
                            updated_at: c.updated_at,
                        })
                        .collect::<Vec<_>>(),
                ),
                Err(e) => turn_error(e),
            }
        }
        (&Method::POST, "conversations") => match read_text(body).await {
            Err(r) => *r,
            Ok(msg) => {
                let (a2, db) = owned();
                match detached(async move { a2.start(&db, Kind::Chat, Some(&msg), t).await }).await
                {
                    Ok(id) => transcript(st, a, id).await,
                    Err(e) => turn_error(e),
                }
            }
        },
        _ => match (method, conversation_path(rest)) {
            (&Method::GET, Some((id, None))) => transcript(st, a, id).await,
            (&Method::DELETE, Some((id, None))) => {
                // A turn in flight would write into a conversation that no longer exists.
                let _guard = match a.lock(id) {
                    Ok(g) => g,
                    Err(e) => return turn_error(e),
                };
                match st.db.delete_conversation(id) {
                    Ok(true) => send(204, Vec::new(), "text/plain", "no-store"),
                    Ok(false) => not_found(),
                    Err(e) => text(500, format!("{e:#}")),
                }
            }
            (&Method::POST, Some((id, Some("messages")))) => match read_text(body).await {
                Err(r) => *r,
                Ok(msg) => {
                    let (a2, db) = owned();
                    match detached(async move { a2.turn(&db, id, Some(&msg), t).await }).await {
                        Ok(()) => transcript(st, a, id).await,
                        Err(e) => turn_error(e),
                    }
                }
            },
            (&Method::POST, Some((id, Some("retry")))) => {
                let (a2, db) = owned();
                match detached(async move { a2.turn(&db, id, None, t).await }).await {
                    Ok(()) => transcript(st, a, id).await,
                    Err(e) => turn_error(e),
                }
            }
            _ => not_found(),
        },
    }
}

/// Stash's own screenshot URL names the address plab reached it at; the browser needs
/// Stash's public address with the same path. Only `<scheme>://<authority>/<path>` or a
/// rooted `/<path>` carry a path worth keeping; anything else yields None.
fn rebase(url: &str, web: &str) -> Option<String> {
    let path = if let Some((_, rest)) = url.split_once("://") {
        &rest[rest.find('/')?..]
    } else if url.starts_with('/') && !url.starts_with("//") {
        url
    } else {
        return None;
    };
    Some(format!("{}{path}", web.trim_end_matches('/')))
}

/// What a pick points at; None for a ref/action pair that does not fit together.
enum Target {
    Topic(u64),
    Scene(String),
}

fn pick_target(p: &assistant::Pick) -> Option<Target> {
    match (p.ref_.split_once(':')?, p.action.as_str()) {
        (("t", id), "stream" | "download") => id.parse().ok().map(Target::Topic),
        (("s", id), "watch") => Some(Target::Scene(id.to_string())),
        _ => None,
    }
}

fn scene_dto(s: &LibScene, web: Option<&str>) -> SceneDto {
    SceneDto {
        ref_: format!("s:{}", s.id),
        id: s.id.clone(),
        title: s.label(),
        studio: s.studio.as_ref().map(|x| x.name.clone()),
        performers: s.performers.iter().map(|p| p.name.clone()).collect(),
        screenshot: web.and_then(|w| s.paths.screenshot.as_deref().and_then(|u| rebase(u, w))),
        link: web.map(|w| format!("{}/scenes/{}", w.trim_end_matches('/'), s.id)),
    }
}

type RawTurn = (
    i64,
    &'static str,
    String,
    Vec<assistant::Pick>,
    Option<String>,
);

async fn transcript<B: Backends>(st: &WebState<B>, a: &Assistant, id: i64) -> Response<Body> {
    match build(st, a, id).await {
        Ok(c) => json_body(&c),
        Err(r) => r,
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct DailyDto {
    conversation: Option<ConversationDto>,
    generated_on: Option<String>,
    refreshing: bool,
    error: Option<String>,
    /// The assistant can make picks: false without a key or a prompt, so Refresh is hidden.
    ready: bool,
}

/// For you. A GET starts today's picks if they have not been attempted; Refresh (`force`)
/// starts new ones regardless. Either way the answer is the picks to show now, and a
/// generation in flight ends with an `assistantDaily` event. A GET answers 200 even when
/// the assistant is not ready: the landing page must render, so the reason goes in `error`.
async fn daily<B: Backends>(st: &WebState<B>, force: bool) -> Response<Body> {
    let t = now();
    let Some(arc) = st.assistant.clone() else {
        if force {
            return text(503, NO_KEY);
        }
        return json_body(&DailyDto {
            conversation: None,
            generated_on: None,
            refreshing: false,
            error: Some(NO_KEY.into()),
            ready: false,
        });
    };
    let mut not_ready = None;
    match arc.ensure_daily(&st.db, &st.events, t, force) {
        Ok(_) => {}
        Err(TurnError::NotReady(why)) if !force => not_ready = Some(why.to_string()),
        Err(e) => return turn_error(e),
    }
    let d = match assistant::daily::state(&st.db, t) {
        Ok(d) => d,
        Err(e) => return text(500, format!("{e:#}")),
    };
    let conversation = match &d.shown {
        Some(row) => match build(st, &arc, row.id).await {
            Ok(c) => Some(c),
            Err(r) => return r,
        },
        None => None,
    };
    // Read last, so a generation that ended meanwhile is not reported as still running: its
    // `assistantDaily` event is published after the flag clears, and a client's refetch on
    // it must be able to land after (and win over) this answer.
    let refreshing = arc.daily_running();
    json_body(&DailyDto {
        conversation,
        generated_on: d
            .shown
            .as_ref()
            .map(|r| assistant::daily::local_ymd(r.created_at)),
        refreshing,
        ready: not_ready.is_none(),
        error: not_ready.or(if refreshing { None } else { d.error }),
    })
}

/// The assistant's release search over the web task's backends. Weak: the web state owns
/// the assistant that holds this.
pub struct WebSearch<B: Backends>(pub std::sync::Weak<WebState<B>>);

impl<B: Backends> assistant::search::ReleaseSearch for WebSearch<B> {
    fn search<'a>(
        &'a self,
        q: &'a str,
        now: i64,
    ) -> std::pin::Pin<Box<dyn std::future::Future<Output = anyhow::Result<Value>> + Send + 'a>>
    {
        Box::pin(async move {
            let st = self
                .0
                .upgrade()
                .ok_or_else(|| anyhow::anyhow!("plab is shutting down"))?;
            let hide =
                crate::filters::load_excludes(st.exclude_file.as_deref(), Some(&st.state_dir)).rule;
            let sources = crate::sources::load(st.sources_file.as_deref());
            assistant::search::search_releases(&st.ctx(), sources.as_ref(), &hide, q, now).await
        })
    }
}

// The Err is a ready response, returned as-is by both callers; boxing it buys nothing.
#[allow(clippy::result_large_err)]
async fn build<B: Backends>(
    st: &WebState<B>,
    a: &Assistant,
    id: i64,
) -> Result<ConversationDto, Response<Body>> {
    let t = now();
    let row: ConversationRow = match st.db.conversation(id) {
        Ok(Some(r)) => r,
        Ok(None) => return Err(not_found()),
        Err(e) => return Err(text(500, format!("{e:#}"))),
    };
    let msgs = match st.db.messages(id) {
        Ok(m) => m,
        Err(e) => return Err(text(500, format!("{e:#}"))),
    };
    let mut degraded = vec![];
    let mut turns: Vec<RawTurn> = vec![];
    for m in &msgs {
        let Ok(v) = serde_json::from_str::<Value>(&m.content) else {
            continue;
        };
        if m.role == "system" {
            degraded = assistant::degraded_of(&v);
            continue;
        }
        if assistant::is_hidden(&v) || (m.role != "user" && m.role != "assistant") {
            continue;
        }
        if v.get("tool_calls")
            .is_some_and(|c| c.as_array().is_some_and(|a| !a.is_empty()))
        {
            continue;
        }
        let content = v.get("content").and_then(Value::as_str).unwrap_or("");
        if m.role == "user" {
            turns.push((m.seq, "user", content.to_string(), vec![], None));
        } else if let Some(err) = assistant::error_of(&v) {
            turns.push((
                m.seq,
                "assistant",
                String::new(),
                vec![],
                Some(err.to_string()),
            ));
        } else if let Some(f) = assistant::parse_final(content) {
            turns.push((m.seq, "assistant", f.text, f.picks, None));
        }
    }
    // Resolve every ref once.
    let mut topic_ids: Vec<u64> = vec![];
    let mut scene_ids: Vec<String> = vec![];
    for (_, _, _, picks, _) in &turns {
        for p in picks {
            match pick_target(p) {
                Some(Target::Topic(id)) if !topic_ids.contains(&id) => topic_ids.push(id),
                Some(Target::Scene(id)) if !scene_ids.contains(&id) => scene_ids.push(id),
                _ => {}
            }
        }
    }
    let downloads = super::downloads(st, t).await;
    let searched = searched_hits(&msgs);
    let topics = match resolve_topics(st, &topic_ids, &downloads, &searched, t) {
        Ok(v) => v,
        Err(e) => return Err(text(500, format!("{e:#}"))),
    };
    let mut scenes_unavailable = false;
    let scenes: Vec<SceneDto> = match bounded(a.stash().lib_scenes(&scene_ids)).await {
        Ok(s) => s
            .iter()
            .map(|s| scene_dto(s, st.stash_web_url.as_deref()))
            .collect(),
        Err(e) => {
            tracing::info!(job = "web", "assistant scenes: {e:#}");
            scenes_unavailable = true;
            vec![]
        }
    };
    let known: HashSet<String> = topics
        .iter()
        .map(|t| format!("t:{}", t.topic.id))
        .chain(scenes.iter().map(|s| s.ref_.clone()))
        .collect();
    let turns = turns
        .into_iter()
        .map(|(seq, role, text, picks, error)| TurnDto {
            seq,
            role,
            text,
            picks: picks
                .into_iter()
                .filter(|p| {
                    let ok = pick_target(p).is_some() && known.contains(&p.ref_);
                    if !ok {
                        tracing::debug!(
                            job = "web",
                            "assistant pick {} ({}) dropped",
                            p.ref_,
                            p.action
                        );
                    }
                    ok
                })
                .map(|p| PickDto {
                    ref_: p.ref_,
                    action: p.action,
                    reason: p.reason,
                })
                .collect(),
            error,
        })
        .collect();
    Ok(ConversationDto {
        id: row.id,
        title: row.title,
        kind: row.kind,
        updated_at: row.updated_at,
        now: t,
        topic_url: crate::site::get().topic_url(),
        degraded,
        scenes_unavailable,
        turns,
        topics,
        scenes,
    })
}

/// The latest `search_releases` hit for each release in this conversation's stored tool
/// results, by id. A result that does not parse is skipped.
fn searched_hits(msgs: &[crate::db::MessageRow]) -> HashMap<u64, Value> {
    let mut calls: HashSet<String> = HashSet::new();
    let mut out = HashMap::new();
    for m in msgs {
        let Ok(v) = serde_json::from_str::<Value>(&m.content) else {
            continue;
        };
        if m.role == "assistant" {
            for c in v
                .get("tool_calls")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if c.pointer("/function/name").and_then(Value::as_str) == Some("search_releases")
                    && let Some(id) = c.get("id").and_then(Value::as_str)
                {
                    calls.insert(id.to_string());
                }
            }
        } else if m.role == "tool"
            && v.get("tool_call_id")
                .and_then(Value::as_str)
                .is_some_and(|id| calls.contains(id))
        {
            let Some(result) = v
                .get("content")
                .and_then(Value::as_str)
                .and_then(|c| serde_json::from_str::<Value>(c).ok())
            else {
                continue;
            };
            for h in result
                .get("results")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
            {
                if let Some(id) = h
                    .get("ref")
                    .and_then(Value::as_str)
                    .and_then(|r| r.strip_prefix("t:"))
                    .and_then(|i| i.parse().ok())
                {
                    out.insert(id, h.clone());
                }
            }
        }
    }
    out
}

/// A stored search hit as the topic it was when found.
fn snapshot(id: u64, h: &Value) -> crate::db::Listed {
    let n = |k: &str| h.get(k).and_then(Value::as_u64).unwrap_or(0);
    crate::db::Listed {
        topic: crate::db::Topic {
            row: crate::tracker::parse::Row {
                id,
                title: h
                    .get("title")
                    .and_then(Value::as_str)
                    .unwrap_or("?")
                    .to_string(),
                forum: 0,
                size: n("size"),
                seeders: n("seeders") as u32,
                leechers: n("leechers") as u32,
                completed: 0,
                added: h.get("published").and_then(Value::as_i64).unwrap_or(0),
            },
            images: None,
            production: None,
        },
        filters: vec![],
        curated_reason: None,
    }
}

/// The picked releases still on a list the assistant advises from, in one pass over those
/// lists, else found by this conversation's own `search_releases`: live while its search
/// hit is, then drawn from the stored result and marked expired. Any other pick does not
/// resolve, and is dropped.
fn resolve_topics<B: Backends>(
    st: &WebState<B>,
    ids: &[u64],
    downloads: &crate::api::Downloads,
    searched: &HashMap<u64, Value>,
    now: i64,
) -> anyhow::Result<Vec<PickedTopic>> {
    if ids.is_empty() {
        return Ok(vec![]);
    }
    let added = st.db.added()?;
    let mut queued: HashSet<u64> = HashSet::new();
    for s in [Section::Video, Section::Indexers] {
        queued.extend(st.db.queued(s)?);
    }
    let externals: HashMap<u64, crate::db::External> = st.db.externals()?;
    let wanted: HashSet<u64> = ids.iter().copied().collect();
    let mut found: HashMap<u64, PickedTopic> = advisable(&st.db)?
        .into_iter()
        .filter(|(l, _)| wanted.contains(&l.topic.row.id))
        .map(|(l, section)| {
            let topic = crate::api::topic(&l, &added, &queued, downloads, &externals);
            (
                topic.id,
                PickedTopic {
                    topic,
                    section: section.as_str(),
                    expired: false,
                },
            )
        })
        .collect();
    for id in ids {
        let Some(h) = searched.get(id).filter(|_| !found.contains_key(id)) else {
            continue;
        };
        let (listed, expired) = match st.db.find(*id, now)? {
            Some((topic, _)) => (
                crate::db::Listed {
                    topic,
                    filters: vec![],
                    curated_reason: None,
                },
                false,
            ),
            None => (snapshot(*id, h), true),
        };
        let mut topic = crate::api::topic(&listed, &added, &queued, downloads, &externals);
        if expired
            && let Some(src) = h
                .get("source")
                .and_then(Value::as_str)
                .filter(|s| *s != "tracker")
        {
            // The external row went with the search hit; the snapshot still names its indexer.
            topic.source = Some(src.to_string());
            topic.kind = "torrent";
        }
        found.insert(
            *id,
            PickedTopic {
                topic,
                section: Section::Video.as_str(),
                expired,
            },
        );
    }
    // In the order the picks first named them.
    Ok(ids.iter().filter_map(|id| found.remove(id)).collect())
}

#[cfg(test)]
mod tests {
    use super::rebase;

    #[test]
    fn rebase_keeps_only_a_rooted_path() {
        let w = "https://stash.example/";
        assert_eq!(
            rebase("http://localhost:9999/scene/4/screenshot?t=1", w).as_deref(),
            Some("https://stash.example/scene/4/screenshot?t=1")
        );
        assert_eq!(
            rebase("/scene/4/screenshot", w).as_deref(),
            Some("https://stash.example/scene/4/screenshot")
        );
        assert_eq!(rebase("scene/4/screenshot", w), None);
        assert_eq!(rebase("http://host?x", w), None);
        assert_eq!(rebase("javascript:alert(1)", w), None);
        assert_eq!(rebase("//evil.example/x", w), None);
    }
}
