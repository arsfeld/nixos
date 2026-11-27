//! Deleting Stash scenes from plab (`POST /api/scenes/delete`): the scene and its files go
//! from Stash and plab never shows or offers it again. Not a vote: taste is untouched.

use axum::body::Body;
use axum::http::Response;
use serde::{Deserialize, Serialize};

use super::{WebState, json_body, now, text};
use crate::backends::Backends;
use crate::events::Event;
use crate::transmission::TorrentClient;

/// A list of scene ids: a few KB at most.
const BODY_LIMIT: usize = 64 * 1024;

#[derive(Deserialize)]
struct DeleteBody {
    scenes: Vec<String>,
}

#[derive(Serialize)]
struct DeletedDto {
    ids: Vec<String>,
}

/// In order: record the scenes as deleted, so they are hidden whatever fails next; drop
/// them from the watchlist; take their torrents out of the client (keeping data, as prune
/// does) so it does not seed files about to vanish; then delete them in Stash with their
/// files. A Stash failure leaves them recorded and hidden, and pressing delete again
/// retries it.
pub async fn delete<B: Backends>(st: &WebState<B>, body: Body) -> Response<Body> {
    let Some(stash) = &st.stash else {
        return text(502, "Stash is not configured");
    };
    let Ok(bytes) = axum::body::to_bytes(body, BODY_LIMIT).await else {
        return text(413, "too many scenes");
    };
    let b: DeleteBody = match serde_json::from_slice(&bytes) {
        Ok(b) => b,
        Err(e) => return text(400, format!("bad body: {e}")),
    };
    let mut ids = b.scenes;
    ids.sort();
    ids.dedup();
    if ids.is_empty() {
        return text(400, "scenes is required");
    }
    if let Err(e) = st.db.deleted_add(&ids, now()) {
        return text(500, e.to_string());
    }
    st.events.publish(Event::Deleted { ids: ids.clone() });
    match st.db.watch_remove(&ids).and_then(|()| st.db.watch_ids()) {
        Ok(watch) => st.events.publish(Event::Watchlist { ids: watch }),
        Err(e) => tracing::info!(job = "web", "delete: watchlist: {e:#}"),
    }
    if let Err(e) = remove_torrents(st, &ids).await {
        tracing::info!(job = "web", "delete: torrents: {e:#}");
    }
    if let Err(e) = stash.destroy_scenes(&ids).await {
        return text(502, format!("Stash: {e:#}"));
    }
    tracing::info!(job = "web", "deleted scenes {}", ids.join(","));
    json_body(&DeletedDto { ids })
}

async fn remove_torrents<B: Backends>(st: &WebState<B>, ids: &[String]) -> anyhow::Result<()> {
    let hashes = st.db.hashes_of_scenes(ids)?;
    if hashes.is_empty() {
        return Ok(());
    }
    let torrents: Vec<i64> = st
        .torrents
        .torrents()
        .await?
        .into_iter()
        .filter(|t| hashes.contains(&t.hash_string))
        .map(|t| t.id)
        .collect();
    if torrents.is_empty() {
        return Ok(());
    }
    st.torrents.remove(&torrents).await
}
