//! Votes on Stash scenes (`/api/votes`) and the scenes recently watched, to vote on
//! (`/api/recent`). Design: docs/superpowers/specs/2026-11-26-plab-taste-feedback-design.md.

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
