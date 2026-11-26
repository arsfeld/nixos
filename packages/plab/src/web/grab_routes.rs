//! The Grabs tab (`/api/grabs/all`): every grab, why it was taken, and the Stash scenes it
//! became, as poster cards.

use std::collections::HashMap;

use axum::body::Body;
use axum::http::Response;
use serde::Serialize;

use super::scene_dto::{SceneDto, scene_dto};
use super::{WebState, downloads, json_body, now, text};
use crate::api::{self, GrabLogDto};
use crate::assistant::context::bounded;
use crate::backends::Backends;

#[derive(Serialize)]
struct GrabCardDto {
    #[serde(flatten)]
    grab: GrabLogDto,
    scenes: Vec<SceneDto>,
}

#[derive(Serialize)]
struct GrabCardsDto {
    now: i64,
    grabs: Vec<GrabCardDto>,
    /// Why there are no posters: Stash is unconfigured or did not answer. The grabs are
    /// still listed.
    error: Option<String>,
}

pub(super) async fn all<B: Backends>(st: &WebState<B>) -> Response<Body> {
    let t = now();
    let entries = match st.db.grab_history() {
        Ok(e) => e,
        Err(e) => {
            tracing::info!(job = "web", "grab history: {e:#}");
            return text(500, "grab history unavailable");
        }
    };
    let log = api::grab_log(entries, &downloads(st, t).await, t);
    let mut ids: Vec<String> = log.grabs.iter().flat_map(|g| g.scene_ids.clone()).collect();
    ids.sort();
    ids.dedup();
    let (found, error) = match &st.stash {
        None => (vec![], Some("Stash is not configured".to_string())),
        Some(_) if ids.is_empty() => (vec![], None),
        Some(stash) => match bounded(stash.lib_scenes(&ids)).await {
            Ok(s) => (s, None),
            Err(e) => {
                tracing::info!(job = "web", "grab scenes: {e:#}");
                (vec![], Some(format!("Stash: {e:#}")))
            }
        },
    };
    let web = st.stash_web_url.as_deref();
    let by_id: HashMap<&str, _> = found.iter().map(|s| (s.id.as_str(), s)).collect();
    let grabs = log
        .grabs
        .into_iter()
        .map(|g| GrabCardDto {
            // A scene Stash no longer has is left out.
            scenes: g
                .scene_ids
                .iter()
                .filter_map(|id| by_id.get(id.as_str()))
                .map(|s| scene_dto(s, web))
                .collect(),
            grab: g,
        })
        .collect();
    json_body(&GrabCardsDto {
        now: log.now,
        grabs,
        error,
    })
}
