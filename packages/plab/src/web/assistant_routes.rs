//! The assistant's routes (`/api/assistant/…`) and its transcript DTO. Picks resolve here,
//! at read time, so a release card shows its live status rather than the status it had
//! when the model named it.

use std::collections::{HashMap, HashSet};

use axum::body::Body;
use axum::http::{Method, Response};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::{WebState, json_body, not_found, now, send, text};
use crate::api::TopicDto;
use crate::assistant::{self, Assistant, Kind, TurnError};
use crate::db::{ConversationRow, Listed, Section};
use crate::stash::library::LibScene;
use crate::tracker::TrackerApi;
use crate::transmission::TorrentClient;

/// Request bodies are a chat message: 16 KB is generous.
const BODY_LIMIT: usize = 16 * 1024;

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
    degraded: Vec<String>,
    turns: Vec<TurnDto>,
    topics: Vec<TopicDto>,
    scenes: Vec<SceneDto>,
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
    let b: TextBody =
        serde_json::from_slice(&bytes).map_err(|e| Box::new(text(400, format!("bad body: {e}"))))?;
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

pub(super) async fn route<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    method: &Method,
    rest: &str,
    body: Body,
) -> Response<Body> {
    let Some(a) = st.assistant.as_deref() else {
        return text(503, "the assistant needs an OpenRouter key");
    };
    let t = now();
    match (method, rest) {
        (&Method::GET, "conversations") => match st.db.conversations() {
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
            Err(e) => text(500, format!("{e:#}")),
        },
        (&Method::POST, "recommend") => match a.start(&st.db, Kind::Recommend, None, t).await {
            Ok(id) => transcript(st, a, id).await,
            Err(e) => turn_error(e),
        },
        (&Method::POST, "conversations") => match read_text(body).await {
            Err(r) => *r,
            Ok(msg) => match a.start(&st.db, Kind::Chat, Some(&msg), t).await {
                Ok(id) => transcript(st, a, id).await,
                Err(e) => turn_error(e),
            },
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
                Ok(msg) => match a.turn(&st.db, id, Some(&msg), t).await {
                    Ok(()) => transcript(st, a, id).await,
                    Err(e) => turn_error(e),
                },
            },
            (&Method::POST, Some((id, Some("retry")))) => {
                match a.turn(&st.db, id, None, t).await {
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

type RawTurn = (i64, &'static str, String, Vec<assistant::Pick>, Option<String>);

async fn transcript<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    a: &Assistant,
    id: i64,
) -> Response<Body> {
    let t = now();
    let row: ConversationRow = match st.db.conversation(id) {
        Ok(Some(r)) => r,
        Ok(None) => return not_found(),
        Err(e) => return text(500, format!("{e:#}")),
    };
    let msgs = match st.db.messages(id) {
        Ok(m) => m,
        Err(e) => return text(500, format!("{e:#}")),
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
            turns.push((m.seq, "assistant", String::new(), vec![], Some(err.to_string())));
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
    let topics: Vec<TopicDto> = match resolve_topics(st, &topic_ids, &downloads, t) {
        Ok(v) => v,
        Err(e) => return text(500, format!("{e:#}")),
    };
    let scenes: Vec<SceneDto> = match a.stash().lib_scenes(&scene_ids).await {
        Ok(s) => s
            .iter()
            .map(|s| scene_dto(s, st.stash_web_url.as_deref()))
            .collect(),
        Err(e) => {
            tracing::info!(job = "web", "assistant scenes: {e:#}");
            if !degraded.iter().any(|d| d == "stash") {
                degraded.push("stash".into());
            }
            vec![]
        }
    };
    let known: HashSet<String> = topics
        .iter()
        .map(|t| format!("t:{}", t.id))
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
    json_body(&ConversationDto {
        id: row.id,
        title: row.title,
        kind: row.kind,
        updated_at: row.updated_at,
        now: t,
        topic_url: crate::site::get().topic_url(),
        degraded,
        turns,
        topics,
        scenes,
    })
}

fn resolve_topics<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    ids: &[u64],
    downloads: &crate::api::Downloads,
    now: i64,
) -> anyhow::Result<Vec<TopicDto>> {
    let added = st.db.added()?;
    let mut queued: HashSet<u64> = HashSet::new();
    for s in [Section::Video, Section::Indexers] {
        queued.extend(st.db.queued(s)?);
    }
    let externals: HashMap<u64, crate::db::External> = st.db.externals()?;
    let mut out = vec![];
    for &id in ids {
        if let Some((topic, _)) = st.db.find(id, now)? {
            let listed = Listed {
                topic,
                filters: vec![],
                curated_reason: None,
            };
            out.push(crate::api::topic(&listed, &added, &queued, downloads, &externals));
        }
    }
    Ok(out)
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
