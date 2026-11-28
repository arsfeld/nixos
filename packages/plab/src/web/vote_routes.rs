//! Votes on Stash scenes (`/api/votes`), the voted scenes themselves (`/api/votes/scenes`)
//! and the scenes recently watched, to vote on (`/api/recent`, really watched lately, and
//! `/api/plays`, every play however short). Design: docs/superpowers/specs/2026-11-26-plab-taste-feedback-design.md.

use std::collections::BTreeMap;

use axum::body::Body;
use axum::http::{Method, Response};
use serde::{Deserialize, Serialize};

use super::scene_dto::{SceneDto, scene_dto};
use super::{WebState, json_body, not_found, now, text};
use crate::assistant::context::bounded;
use crate::backends::Backends;
use crate::events::Event;
use crate::taste::{Play, play, watched_secs};

/// A list of scene ids: a few KB at most.
const BODY_LIMIT: usize = 64 * 1024;
/// How far back Recently watched reaches.
const RECENT_DAYS: i64 = 14;
/// Plays asked of Stash for Recently watched.
const RECENT_PLAYS: usize = 100;

#[derive(Serialize)]
struct VotesDto {
    votes: BTreeMap<String, i8>,
}

#[derive(Deserialize)]
struct VoteBody {
    scenes: Vec<String>,
    vote: i8,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct VotedSceneDto {
    #[serde(flatten)]
    scene: SceneDto,
    vote: i8,
    voted_at: i64,
}

#[derive(Serialize)]
struct VotedDto {
    now: i64,
    scenes: Vec<VotedSceneDto>,
    error: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct PlayedSceneDto {
    #[serde(flatten)]
    scene: SceneDto,
    /// Unix seconds; None when Stash's timestamp does not parse.
    last_played_at: Option<i64>,
    /// Seconds played in all; None when Stash never timed it.
    played_secs: Option<u32>,
}

#[derive(Serialize)]
struct PlaysDto {
    scenes: Vec<PlayedSceneDto>,
}

#[derive(Serialize)]
struct RecentDto {
    scenes: Vec<SceneDto>,
}

fn all_votes<B: Backends>(st: &WebState<B>) -> anyhow::Result<BTreeMap<String, i8>> {
    Ok(st
        .db
        .votes()?
        .into_iter()
        .map(|(id, vote, _)| (id, vote))
        .collect())
}

pub async fn votes<B: Backends>(st: &WebState<B>, method: &Method, body: Body) -> Response<Body> {
    match *method {
        Method::GET => match all_votes(st) {
            Ok(votes) => json_body(&VotesDto { votes }),
            Err(e) => text(500, e.to_string()),
        },
        Method::POST => {
            let Ok(bytes) = axum::body::to_bytes(body, BODY_LIMIT).await else {
                return text(413, "too many scenes");
            };
            let b: VoteBody = match serde_json::from_slice(&bytes) {
                Ok(b) => b,
                Err(e) => return text(400, format!("bad body: {e}")),
            };
            if b.scenes.is_empty() {
                return text(400, "scenes is required");
            }
            if !(-1..=1).contains(&b.vote) {
                return text(400, "vote is 1, -1 or 0");
            }
            let at = now();
            let changed = b.scenes.iter().try_for_each(|id| match b.vote {
                0 => st.db.vote_clear(id),
                v => st.db.vote_set(id, v, at),
            });
            match changed.and_then(|()| all_votes(st)) {
                Ok(votes) => {
                    st.events.publish(Event::Votes {
                        votes: votes.clone(),
                    });
                    json_body(&VotesDto { votes })
                }
                Err(e) => text(500, e.to_string()),
            }
        }
        _ => not_found(),
    }
}

/// Every voted scene Stash still has, newest vote first, less those deleted from plab. A
/// Stash failure is reported in `error`, as the watchlist does, rather than as a status.
pub async fn voted<B: Backends>(st: &WebState<B>) -> Response<Body> {
    let at = now();
    let failed = |error: String| {
        json_body(&VotedDto {
            now: at,
            scenes: vec![],
            error: Some(error),
        })
    };
    let mut rows = match st.db.votes() {
        Ok(r) => r,
        Err(e) => return text(500, e.to_string()),
    };
    let deleted = st.db.deleted_ids().unwrap_or_else(|e| {
        tracing::info!(job = "web", "deleted scenes: {e:#}");
        Default::default()
    });
    rows.retain(|(id, _, _)| !deleted.contains(id));
    rows.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(&b.0)));
    let Some(stash) = &st.stash else {
        return failed("Stash is not configured".into());
    };
    let ids: Vec<String> = rows.iter().map(|(id, _, _)| id.clone()).collect();
    let found = match bounded(stash.lib_scenes(&ids)).await {
        Ok(s) => s,
        Err(e) => return failed(format!("Stash: {e:#}")),
    };
    let web = st.stash_web_url.as_deref();
    let scenes = rows
        .iter()
        .filter_map(|(id, vote, voted_at)| {
            let s = found.iter().find(|s| &s.id == id)?;
            Some(VotedSceneDto {
                scene: scene_dto(s, web),
                vote: *vote,
                voted_at: *voted_at,
            })
        })
        .collect();
    json_body(&VotedDto {
        now: at,
        scenes,
        error: None,
    })
}

/// The scenes really watched (`taste::play`) in the last `RECENT_DAYS`, newest first, less
/// those deleted from plab.
pub async fn recent<B: Backends>(st: &WebState<B>) -> Response<Body> {
    let Some(stash) = &st.stash else {
        return text(502, "Stash is not configured");
    };
    let scenes = match bounded(stash.recent_plays(RECENT_PLAYS)).await {
        Ok(s) => s,
        Err(e) => return text(502, format!("Stash: {e:#}")),
    };
    let since = now() - RECENT_DAYS * 86400;
    let web = st.stash_web_url.as_deref();
    let deleted = st.db.deleted_ids().unwrap_or_else(|e| {
        tracing::info!(job = "web", "deleted scenes: {e:#}");
        Default::default()
    });
    let scenes = scenes
        .iter()
        .filter(|s| !deleted.contains(&s.id))
        .filter(|s| {
            let played = s
                .last_played_at
                .as_deref()
                .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
                .is_some_and(|t| t.timestamp() >= since);
            let secs = watched_secs(s.play_duration);
            played && play(secs, s.o_counter.unwrap_or(0), s.rating100) == Play::Watched
        })
        .map(|s| scene_dto(s, web))
        .collect();
    json_body(&RecentDto { scenes })
}

/// Stash's last `RECENT_PLAYS` plays, newest first, however short and however old, less
/// the scenes deleted from plab: the Votes page's list to vote on.
pub async fn plays<B: Backends>(st: &WebState<B>) -> Response<Body> {
    let Some(stash) = &st.stash else {
        return text(502, "Stash is not configured");
    };
    let scenes = match bounded(stash.recent_plays(RECENT_PLAYS)).await {
        Ok(s) => s,
        Err(e) => return text(502, format!("Stash: {e:#}")),
    };
    let web = st.stash_web_url.as_deref();
    let deleted = st.db.deleted_ids().unwrap_or_else(|e| {
        tracing::info!(job = "web", "deleted scenes: {e:#}");
        Default::default()
    });
    let scenes = scenes
        .iter()
        .filter(|s| !deleted.contains(&s.id))
        .map(|s| PlayedSceneDto {
            scene: scene_dto(s, web),
            last_played_at: s
                .last_played_at
                .as_deref()
                .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
                .map(|t| t.timestamp()),
            played_secs: watched_secs(s.play_duration),
        })
        .collect();
    json_body(&PlaysDto { scenes })
}
