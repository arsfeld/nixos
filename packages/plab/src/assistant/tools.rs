//! The assistant's read-only tools. Each returns a JSON string; a failure is a JSON
//! `{"error": …}` the model can read and correct, never an Err.

use serde_json::{Value, json};

use super::context::{advisable, bounded};
use crate::db::Db;
use crate::stash::Stash;

/// Results per tool call.
const LIMIT: usize = 20;
/// Lines `recent_views` returns: the whole lookback, in practice.
const RECENT_VIEWS: usize = 100;

pub fn definitions() -> Value {
    let q = json!({"type": "object", "properties": {"q": {"type": "string"}}, "required": ["q"]});
    json!([
        {"type": "function", "function": {
            "name": "search_lists",
            "description": "Search the releases currently on plab's lists by words in their titles. Returns refs usable as stream or download picks.",
            "parameters": q}},
        {"type": "function", "function": {
            "name": "find_stash_scenes",
            "description": "Search the Stash library. Returns refs usable as watch picks, with play counts.",
            "parameters": q}},
        {"type": "function", "function": {
            "name": "recent_views",
            "description": "The full list of recent views, newest first.",
            "parameters": {"type": "object", "properties": {}}}}
    ])
}

fn query(arguments: &str) -> Result<String, String> {
    let v: Value = serde_json::from_str(arguments).map_err(|e| format!("arguments are not JSON: {e}"))?;
    v.get("q")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|q| !q.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| "q is required".into())
}

fn search_lists(db: &Db, q: &str) -> anyhow::Result<Value> {
    let words: Vec<String> = q.to_lowercase().split_whitespace().map(str::to_owned).collect();
    let out: Vec<Value> = advisable(db)?
        .into_iter()
        .filter(|(l, _)| {
            let title = l.topic.row.title.to_lowercase();
            words.iter().all(|w| title.contains(w.as_str()))
        })
        .take(LIMIT)
        .map(|(l, _)| json!({"ref": format!("t:{}", l.topic.row.id), "title": l.topic.row.title}))
        .collect();
    Ok(Value::Array(out))
}

pub async fn run(stash: &Stash, db: &Db, hide: &crate::filters::HideRule, name: &str, arguments: &str, now: i64) -> String {
    let r: Result<Value, String> = match name {
        "search_lists" => match query(arguments) {
            Ok(q) => search_lists(db, &q).map_err(|e| format!("{e:#}")),
            Err(e) => Err(e),
        },
        "find_stash_scenes" => match query(arguments) {
            Ok(q) => bounded(stash.search_scenes(&q, LIMIT))
                .await
                .map(|scenes| {
                    Value::Array(
                        scenes
                            .iter()
                            .filter(|s| !crate::filters::scene_hidden(hide, s))
                            .map(|s| {
                                json!({
                                    "ref": format!("s:{}", s.id),
                                    "title": s.label(),
                                    "studio": s.studio.as_ref().map(|x| &x.name),
                                    "performers": s.performers.iter().map(|p| &p.name).collect::<Vec<_>>(),
                                    "plays": s.play_count.unwrap_or(0),
                                })
                            })
                            .collect(),
                    )
                })
                .map_err(|e| format!("Stash: {e:#}")),
            Err(e) => Err(e),
        },
        "recent_views" => {
            let (views, _) = super::context::views(db, stash, now).await;
            Ok(json!(crate::taste::recent(&views, RECENT_VIEWS)))
        }
        other => Err(format!("unknown tool {other}")),
    };
    match r {
        Ok(v) => v.to_string(),
        Err(e) => json!({"error": e}).to_string(),
    }
}
