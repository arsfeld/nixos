//! What the assistant knows before it is asked anything: recent views, the taste profile,
//! the shortlist. Stash being down degrades it to plab's own data rather than failing.

use std::collections::HashSet;
use std::future::Future;
use std::time::Duration;

use crate::candidates::{self, Candidate, ReleaseIn, SceneIn};
use crate::db::{Db, Kind, Listed, Section};
use crate::stash::Stash;
use crate::stash::library::LibScene;
use crate::taste::{self, Named, Profile, View};

/// How far back views count.
pub const LOOKBACK: i64 = 60 * 86400;
/// Played scenes asked of Stash.
const PLAYS: usize = 100;
/// Unwatched scenes asked of Stash, per criterion.
const UNWATCHED: usize = 60;
/// The longest the assistant waits on any one Stash read before treating Stash as down.
pub const STASH_TIMEOUT: Duration = Duration::from_secs(10);

/// A Stash read bounded by `STASH_TIMEOUT`; running out of time is a failure like any other.
pub async fn bounded<T>(read: impl Future<Output = anyhow::Result<T>>) -> anyhow::Result<T> {
    tokio::time::timeout(STASH_TIMEOUT, read)
        .await
        .unwrap_or_else(|_| Err(anyhow::anyhow!("no answer in {}s", STASH_TIMEOUT.as_secs())))
}

/// The releases the assistant may advise on: the Video list, then the Indexers list, each
/// topic once (the first section it appears in).
pub fn advisable(db: &Db) -> anyhow::Result<Vec<(Listed, Section)>> {
    let mut seen = HashSet::new();
    let mut out = vec![];
    for section in [Section::Video, Section::Indexers] {
        for l in db.listing(section)?.topics {
            if seen.insert(l.topic.row.id) {
                out.push((l, section));
            }
        }
    }
    Ok(out)
}

pub struct Context {
    pub profile: Profile,
    pub candidates: Vec<Candidate>,
    pub degraded: Vec<&'static str>,
}

fn named(n: &crate::stash::library::Named) -> Named {
    Named { name: n.name.clone(), id: Some(n.id.clone()) }
}

fn played_at(s: &LibScene) -> Option<i64> {
    let t = s.last_played_at.as_deref()?;
    chrono::DateTime::parse_from_rfc3339(t).ok().map(|d| d.timestamp())
}

fn view_of(s: &LibScene, at: i64, streamed: bool) -> View {
    View {
        at,
        title: s.label(),
        studio: s.studio.as_ref().map(named),
        performers: s.performers.iter().map(named).collect(),
        tags: s.tags.iter().map(|t| t.name.clone()).collect(),
        o_count: if streamed { 0 } else { s.o_counter.unwrap_or(0) },
        rating: if streamed { None } else { s.rating100 },
        streamed,
    }
}

/// Stash plays and plab streams from the last `LOOKBACK`, and whether Stash answered.
pub async fn views(db: &Db, stash: &Stash, now: i64) -> (Vec<View>, bool) {
    let since = now - LOOKBACK;
    let mut ok = true;
    let mut out: Vec<View> = match bounded(stash.recent_plays(PLAYS)).await {
        Ok(scenes) => scenes
            .iter()
            .filter_map(|s| played_at(s).filter(|&at| at >= since).map(|at| view_of(s, at, false)))
            .collect(),
        Err(e) => {
            tracing::info!(job = "assistant", "Stash plays: {e:#}");
            ok = false;
            vec![]
        }
    };
    let streams = db.stream_views(since).unwrap_or_else(|e| {
        tracing::info!(job = "assistant", "stream views: {e:#}");
        vec![]
    });
    // A streamed release matched to a scene takes that scene's studio, performers, tags.
    let mut by_scene: Vec<(i64, String, Option<String>)> = vec![]; // (at, title, scene id)
    for (topic, at) in streams {
        let title = db.topic(topic).ok().flatten().map(|t| t.row.title).unwrap_or_else(|| format!("release {topic}"));
        let scene = db.external(topic).ok().flatten().and_then(|e| e.scene_id);
        by_scene.push((at, title, scene));
    }
    let ids: Vec<String> = by_scene.iter().filter_map(|(_, _, s)| s.clone()).collect();
    let scenes = if ok && !ids.is_empty() {
        bounded(stash.lib_scenes(&ids)).await.unwrap_or_else(|e| {
            tracing::info!(job = "assistant", "Stash scenes: {e:#}");
            ok = false;
            vec![]
        })
    } else {
        vec![]
    };
    for (at, title, scene) in by_scene {
        match scene.and_then(|id| scenes.iter().find(|s| s.id == id)) {
            Some(s) => out.push(View { title, ..view_of(s, at, true) }),
            None => out.push(View { at, title, streamed: true, ..View::default() }),
        }
    }
    (out, ok)
}

/// The releases on the Video and Indexers lists, as candidates' input.
fn releases(db: &Db) -> anyhow::Result<Vec<ReleaseIn>> {
    let added = db.added()?;
    let externals = db.externals()?;
    Ok(advisable(db)?
        .into_iter()
        .map(|(l, _)| {
            let row = &l.topic.row;
            ReleaseIn {
                id: row.id,
                title: row.title.clone(),
                studio: crate::labels::labels(&row.title, row.forum).studio,
                downloaded: added.contains(&row.id),
                album: externals.get(&row.id).is_some_and(|e| e.kind == Kind::Album),
            }
        })
        .collect())
}

pub async fn gather(db: &Db, stash: &Stash, now: i64) -> anyhow::Result<Context> {
    let (views, mut ok) = views(db, stash, now).await;
    let profile = taste::profile(&views, now);
    let ids = |ws: &[taste::Weighted], n: usize| -> Vec<String> {
        ws.iter().filter_map(|w| w.id.clone()).take(n).collect()
    };
    let scenes = if ok {
        match bounded(stash.unwatched(&ids(&profile.performers, 8), &ids(&profile.studios, 5), UNWATCHED)).await {
            Ok(s) => s,
            Err(e) => {
                tracing::info!(job = "assistant", "Stash unwatched: {e:#}");
                ok = false;
                vec![]
            }
        }
    } else {
        vec![]
    };
    let scenes: Vec<SceneIn> = scenes
        .iter()
        .map(|s| SceneIn {
            id: s.id.clone(),
            title: s.label(),
            studio: s.studio.as_ref().map(|x| x.name.clone()),
            performers: s.performers.iter().map(|p| p.name.clone()).collect(),
            tags: s.tags.iter().map(|t| t.name.clone()).collect(),
            plays: s.play_count.unwrap_or(0),
        })
        .collect();
    let candidates = candidates::candidates(&profile, &scenes, &releases(db)?);
    Ok(Context { profile, candidates, degraded: if ok { vec![] } else { vec!["stash"] } })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(start_paused = true)]
    async fn a_stash_read_that_never_answers_is_a_failure() {
        let r: anyhow::Result<()> = bounded(std::future::pending()).await;
        assert!(r.unwrap_err().to_string().contains("no answer"));
    }
}
