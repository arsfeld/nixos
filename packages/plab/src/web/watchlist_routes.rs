//! The watchlist's routes (`/api/watchlist…`): Stash scenes queued to watch. Reading the
//! list drops scenes Stash has played since they were queued, or no longer has.
//! Design: docs/superpowers/specs/2026-11-16-plab-watchlist-design.md.

use crate::backends::Backends;

use axum::body::Body;
use axum::http::{Method, Response};
use serde::{Deserialize, Serialize};

use super::scene_dto::{SceneDto, scene_dto};
use super::{WebState, json_body, not_found, now, text};
use crate::assistant::context::bounded;
use crate::events::Event;

/// A list of scene ids: a few KB at most.
const BODY_LIMIT: usize = 64 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct WatchSceneDto {
    #[serde(flatten)]
    scene: SceneDto,
    added_at: i64,
}

#[derive(Serialize)]
struct WatchlistDto {
    now: i64,
    scenes: Vec<WatchSceneDto>,
    error: Option<String>,
}

#[derive(Serialize)]
struct IdsDto {
    ids: Vec<String>,
}

#[derive(Deserialize)]
struct ScenesBody {
    scenes: Vec<String>,
}

pub async fn route<B: Backends>(
    st: &WebState<B>,
    method: &Method,
    rest: &str,
    body: Body,
) -> Response<Body> {
    match (method, rest) {
        (&Method::GET, "") => list(st).await,
        (&Method::GET, "/ids") => match st.db.watch_ids() {
            Ok(ids) => json_body(&IdsDto { ids }),
            Err(e) => text(500, e.to_string()),
        },
        (&Method::POST, "/add" | "/remove") => {
            let ids = match read_scenes(body).await {
                Ok(ids) => ids,
                Err(r) => return *r,
            };
            let changed = if rest == "/add" {
                st.db.watch_add(&ids, now())
            } else {
                st.db.watch_remove(&ids)
            };
            match changed.and_then(|()| st.db.watch_ids()) {
                Ok(ids) => {
                    st.events.publish(Event::Watchlist { ids: ids.clone() });
                    json_body(&IdsDto { ids })
                }
                Err(e) => text(500, e.to_string()),
            }
        }
        _ => not_found(),
    }
}

/// The queued scenes, oldest first, after dropping the expired ones. With Stash
/// unreachable nothing is dropped: an outage must not read as "every scene is gone".
async fn list<B: Backends>(st: &WebState<B>) -> Response<Body> {
    let at = now();
    let rows = match st.db.watch_list() {
        Ok(r) => r,
        Err(e) => return text(500, e.to_string()),
    };
    let failed = |error: String| {
        json_body(&WatchlistDto {
            now: at,
            scenes: vec![],
            error: Some(error),
        })
    };
    let Some(stash) = &st.stash else {
        return failed("Stash is not configured".into());
    };
    let ids: Vec<String> = rows.iter().map(|(id, _)| id.clone()).collect();
    let found = match bounded(stash.lib_scenes(&ids)).await {
        Ok(s) => s,
        Err(e) => return failed(format!("Stash: {e:#}")),
    };
    let gone = crate::watchlist::expired(&rows, &found);
    if !gone.is_empty() {
        let judged: Vec<(String, i64)> = rows
            .iter()
            .filter(|(id, _)| gone.contains(id))
            .cloned()
            .collect();
        // Every page's stars follow, as they do an add or a remove.
        match st.db.watch_expire(&judged).and_then(|()| st.db.watch_ids()) {
            Ok(ids) => st.events.publish(Event::Watchlist { ids }),
            Err(e) => return text(500, e.to_string()),
        }
    }
    let web = st.stash_web_url.as_deref();
    let scenes = rows
        .iter()
        .filter(|(id, _)| !gone.contains(id))
        .filter_map(|(id, added_at)| {
            let s = found.iter().find(|s| &s.id == id)?;
            Some(WatchSceneDto {
                scene: scene_dto(s, web),
                added_at: *added_at,
            })
        })
        .collect();
    json_body(&WatchlistDto {
        now: at,
        scenes,
        error: None,
    })
}

async fn read_scenes(body: Body) -> Result<Vec<String>, Box<Response<Body>>> {
    let bytes = axum::body::to_bytes(body, BODY_LIMIT)
        .await
        .map_err(|_| Box::new(text(413, "too many scenes")))?;
    let b: ScenesBody = serde_json::from_slice(&bytes)
        .map_err(|e| Box::new(text(400, format!("bad body: {e}"))))?;
    if b.scenes.is_empty() {
        return Err(Box::new(text(400, "scenes is required")));
    }
    Ok(b.scenes)
}
