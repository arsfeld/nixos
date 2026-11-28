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
    /// Every scene it became was deleted from plab: by id when linked, else because a
    /// deleted scene's file sat in its release folder and Stash now has none there.
    deleted: bool,
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
    // A grab with no linked scene is looked up by its release folder: identify links a file
    // only while the scene is new, and misses one whose files were never all recorded.
    let mut folders: Vec<String> = log
        .grabs
        .iter()
        .filter(|g| g.scene_ids.is_empty())
        .flat_map(|g| g.folders.clone())
        .collect();
    folders.sort();
    folders.dedup();
    let (found, by_folder, error) = match &st.stash {
        None => (vec![], vec![], Some("Stash is not configured".to_string())),
        Some(stash) => {
            let (found, by_folder) = futures::join!(
                bounded(stash.lib_scenes(&ids)),
                bounded(stash.lib_scenes_by_path(&folders))
            );
            let mut errors = vec![];
            let found = found.unwrap_or_else(|e| {
                errors.push(format!("{e:#}"));
                vec![]
            });
            let by_folder = by_folder.unwrap_or_else(|e| {
                errors.push(format!("{e:#}"));
                vec![]
            });
            for e in &errors {
                tracing::info!(job = "web", "grab scenes: {e}");
            }
            let error = (!errors.is_empty()).then(|| format!("Stash: {}", errors.join("; ")));
            (found, by_folder, error)
        }
    };
    let gone = st.db.deleted_ids().unwrap_or_else(|e| {
        tracing::info!(job = "web", "deleted scenes: {e:#}");
        Default::default()
    });
    let gone_paths = st.db.deleted_paths().unwrap_or_else(|e| {
        tracing::info!(job = "web", "deleted paths: {e:#}");
        vec![]
    });
    let web = st.stash_web_url.as_deref();
    let by_id: HashMap<&str, _> = found.iter().map(|s| (s.id.as_str(), s)).collect();
    let in_folder: HashMap<&str, &Vec<_>> = folders
        .iter()
        .map(String::as_str)
        .zip(by_folder.iter())
        .collect();
    let grabs = log
        .grabs
        .into_iter()
        .map(|g| {
            let mut seen = std::collections::HashSet::new();
            let scenes: Vec<SceneDto> = if g.scene_ids.is_empty() {
                g.folders
                    .iter()
                    .filter_map(|f| in_folder.get(f.as_str()))
                    .flat_map(|v| v.iter())
                    .filter(|s| seen.insert(s.id.as_str()))
                    .filter(|s| !gone.contains(&s.id))
                    .map(|s| scene_dto(s, web))
                    .collect()
            } else {
                // A scene Stash no longer has is left out.
                g.scene_ids
                    .iter()
                    .filter(|id| !gone.contains(*id))
                    .filter_map(|id| by_id.get(id.as_str()))
                    .map(|s| scene_dto(s, web))
                    .collect()
            };
            let deleted = if g.scene_ids.is_empty() {
                // `seen` holds every scene Stash still has in its folders, deleted or not.
                scenes.is_empty()
                    && (!seen.is_empty()
                        || g.folders
                            .iter()
                            .any(|f| gone_paths.iter().any(|p| p.contains(f.as_str()))))
            } else {
                g.scene_ids.iter().all(|id| gone.contains(id))
            };
            GrabCardDto {
                scenes,
                deleted,
                grab: g,
            }
        })
        .collect();
    json_body(&GrabCardsDto {
        now: log.now,
        grabs,
        error,
    })
}
