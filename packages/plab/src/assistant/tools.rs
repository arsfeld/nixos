//! The assistant's read-only tools. Each returns a JSON string; a failure is a JSON
//! `{"error": …}` the model can read and correct, never an Err.

use serde_json::{Value, json};

use super::context::{Have, advisable, bounded};
use super::search::ReleaseSearch;
use crate::db::Db;
use crate::stash::Stash;

/// Results per tool call.
pub(crate) const LIMIT: usize = 20;
/// Lines `recent_views` returns: the whole lookback, in practice.
const RECENT_VIEWS: usize = 100;

/// The tool definitions; `search_releases` only when there is a search to run it.
pub fn definitions(search: bool) -> Value {
    let q = json!({"type": "object", "properties": {"q": {"type": "string"}}, "required": ["q"]});
    let mut tools = json!([
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
    ]);
    if search {
        tools.as_array_mut().expect("an array").push(json!({"type": "function", "function": {
            "name": "search_releases",
            "description": "Search the tracker and other indexers for releases not on plab's lists. Returns refs usable as stream or download picks.",
            "parameters": q}}));
    }
    tools
}

fn query(arguments: &str) -> Result<String, String> {
    let v: Value =
        serde_json::from_str(arguments).map_err(|e| format!("arguments are not JSON: {e}"))?;
    v.get("q")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|q| !q.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| "q is required".into())
}

/// Releases plab already has never reach the model, as on the shortlist: a search for a
/// followed studio otherwise turns up every scene the grab job already took.
fn search_lists(db: &Db, have: &Have, q: &str) -> anyhow::Result<Value> {
    let words: Vec<String> = q
        .to_lowercase()
        .split_whitespace()
        .map(str::to_owned)
        .collect();
    let out: Vec<Value> = advisable(db)?
        .into_iter()
        .filter(|(l, _)| {
            let title = l.topic.row.title.to_lowercase();
            words.iter().all(|w| title.contains(w.as_str()))
        })
        .filter(|(l, _)| !have.has(l.topic.row.id, &l.topic.row.title))
        .take(LIMIT)
        .map(|(l, _)| json!({"ref": format!("t:{}", l.topic.row.id), "title": l.topic.row.title}))
        .collect();
    Ok(Value::Array(out))
}

/// `search_releases`' results without the releases plab already has.
fn drop_owned(mut found: Value, have: &Have) -> Value {
    if let Some(results) = found.get_mut("results").and_then(Value::as_array_mut) {
        results.retain(|r| {
            let id = r
                .get("ref")
                .and_then(Value::as_str)
                .and_then(|s| s.strip_prefix("t:"))
                .and_then(|s| s.parse().ok());
            let title = r.get("title").and_then(Value::as_str);
            match (id, title) {
                (Some(id), Some(title)) => !have.has(id, title),
                _ => true,
            }
        });
    }
    found
}

#[allow(clippy::too_many_arguments)]
pub async fn run(
    stash: &Stash,
    db: &Db,
    hide: &crate::filters::HideRule,
    noise: &[String],
    search: Option<&dyn ReleaseSearch>,
    name: &str,
    arguments: &str,
    now: i64,
) -> String {
    let have = || Have::new(db, noise).map_err(|e| format!("{e:#}"));
    let r: Result<Value, String> = match name {
        "search_lists" => match query(arguments) {
            Ok(q) => have().and_then(|h| search_lists(db, &h, &q).map_err(|e| format!("{e:#}"))),
            Err(e) => Err(e),
        },
        "find_stash_scenes" => match query(arguments) {
            Ok(q) => bounded(stash.search_scenes(&q, LIMIT))
                .await
                .map(|scenes| {
                    let down = super::context::never_offer(db);
                    Value::Array(
                        scenes
                            .iter()
                            .filter(|s| !crate::filters::scene_hidden(hide, s))
                            .filter(|s| !down.contains(&s.id))
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
        "search_releases" => match (query(arguments), search) {
            (Err(e), _) => Err(e),
            (Ok(_), None) => Err("search is not available".into()),
            (Ok(q), Some(s)) => match s.search(&q, now).await {
                Ok(found) => have().map(|h| drop_owned(found, &h)),
                Err(e) => Err(format!("{e:#}")),
            },
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::{Listed, NewDownload, Section, Topic};
    use crate::tracker::parse::Row;

    fn listed(id: u64, title: &str) -> Listed {
        Listed {
            topic: Topic {
                row: Row {
                    id,
                    title: title.into(),
                    forum: 1875,
                    size: 1,
                    seeders: 1,
                    leechers: 0,
                    completed: 0,
                    added: 1000,
                },
                images: None,
                production: None,
            },
            filters: vec![],
            curated_reason: None,
        }
    }

    const GRABBED: &str = "[StudioB.com] Dana Lee - Close To You [2026-10-30, 1080p]";
    const NEW: &str = "[StudioB.com] Eve Ray - Rainy Day [2026-10-30, 1080p]";

    /// Two StudioB releases on the list, one of them already taken by the grab job from
    /// another indexer, under a title that shares no topic id.
    fn db_with_a_grab() -> Db {
        let db = Db::open_in_memory().unwrap();
        db.save_listing(
            Section::Video,
            &[listed(1, GRABBED), listed(2, NEW)],
            &[],
            1000,
        )
        .unwrap();
        db.mark_added(NewDownload {
            source: "grab",
            topic_id: None,
            release_title: "Studio B 26 10 30 Dana Lee Close To You 1080p MP4",
            section: Section::Video,
            download_dir: None,
            torrent_hash: None,
            now: 1000,
        })
        .unwrap();
        db
    }

    #[test]
    fn search_lists_leaves_out_what_plab_has() {
        let db = db_with_a_grab();
        let have = Have::new(&db, &[]).unwrap();
        let got = search_lists(&db, &have, "studiob").unwrap();
        assert_eq!(got, json!([{"ref": "t:2", "title": NEW}]));
    }

    #[test]
    fn search_releases_results_leave_out_what_plab_has() {
        let db = db_with_a_grab();
        let have = Have::new(&db, &[]).unwrap();
        let found = json!({"results": [
            {"ref": "t:1", "title": GRABBED, "source": "tracker"},
            // Another indexer's copy of the grabbed scene, under its own id.
            {"ref": "t:1099511627777", "title": "Studio B 26 10 30 Dana Lee Close To You 720p", "source": "Other"},
            {"ref": "t:2", "title": NEW, "source": "tracker"},
        ], "errors": ["Prowlarr: x"]});
        let got = drop_owned(found, &have);
        assert_eq!(
            got,
            json!({"results": [{"ref": "t:2", "title": NEW, "source": "tracker"}], "errors": ["Prowlarr: x"]})
        );
    }
}
