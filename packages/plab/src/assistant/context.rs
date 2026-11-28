//! What the assistant knows before it is asked anything: recent views, the taste profile,
//! the shortlist. Stash being down degrades it to plab's own data rather than failing.

use std::collections::{HashMap, HashSet};
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
    Named {
        name: n.name.clone(),
        id: Some(n.id.clone()),
    }
}

fn played_at(s: &LibScene) -> Option<i64> {
    let t = s.last_played_at.as_deref()?;
    chrono::DateTime::parse_from_rfc3339(t)
        .ok()
        .map(|d| d.timestamp())
}

fn view_of(s: &LibScene, at: i64, streamed: bool) -> View {
    View {
        at,
        title: s.label(),
        studio: s.studio.as_ref().map(named),
        performers: s.performers.iter().map(named).collect(),
        tags: s.tags.iter().map(|t| t.name.clone()).collect(),
        o_count: if streamed {
            0
        } else {
            s.o_counter.unwrap_or(0)
        },
        rating: if streamed { None } else { s.rating100 },
        streamed,
        watched_secs: if streamed {
            None
        } else {
            taste::watched_secs(s.play_duration)
        },
        ..View::default()
    }
}

/// The user's votes, by scene id; none when the db cannot be read.
fn votes(db: &Db) -> HashMap<String, (i8, i64)> {
    db.votes()
        .unwrap_or_else(|e| {
            tracing::info!(job = "assistant", "votes: {e:#}");
            vec![]
        })
        .into_iter()
        .map(|(id, vote, at)| (id, (vote, at)))
        .collect()
}

/// The scenes never offered, whatever they match: those voted −1 and those deleted from
/// plab. Needs no Stash.
pub fn never_offer(db: &Db) -> HashSet<String> {
    let mut out: HashSet<String> = votes(db)
        .into_iter()
        .filter(|(_, (v, _))| *v < 0)
        .map(|(id, _)| id)
        .collect();
    match db.deleted_ids() {
        Ok(ids) => out.extend(ids),
        Err(e) => tracing::info!(job = "assistant", "deleted scenes: {e:#}"),
    }
    out
}

/// Stash plays and plab streams from the last `LOOKBACK`, each Stash play carrying its
/// vote, plus every other voted scene Stash still has, and whether Stash answered.
pub async fn views(db: &Db, stash: &Stash, now: i64) -> (Vec<View>, bool) {
    let since = now - LOOKBACK;
    let mut ok = true;
    let mut votes = votes(db);
    let mut out: Vec<View> = match bounded(stash.recent_plays(PLAYS)).await {
        Ok(scenes) => scenes
            .iter()
            .filter_map(|s| {
                played_at(s).filter(|&at| at >= since).map(|at| View {
                    vote: votes.remove(&s.id),
                    ..view_of(s, at, false)
                })
            })
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
        let title = db
            .topic(topic)
            .ok()
            .flatten()
            .map(|t| t.row.title)
            .unwrap_or_else(|| format!("release {topic}"));
        let scene = db.external(topic).ok().flatten().and_then(|e| e.scene_id);
        by_scene.push((at, title, scene));
    }
    let mut ids: Vec<String> = by_scene.iter().filter_map(|(_, _, s)| s.clone()).collect();
    // Voted scenes not played within the lookback come in through their vote alone.
    ids.extend(votes.keys().cloned());
    let scenes = if ok && !ids.is_empty() {
        bounded(stash.lib_scenes(&ids)).await.unwrap_or_else(|e| {
            tracing::info!(job = "assistant", "Stash scenes: {e:#}");
            ok = false;
            vec![]
        })
    } else {
        vec![]
    };
    for s in &scenes {
        if let Some(&(vote, at)) = votes.get(&s.id) {
            out.push(View {
                vote: Some((vote, at)),
                vote_only: true,
                ..view_of(s, at, false)
            });
        }
    }
    for (at, title, scene) in by_scene {
        match scene.and_then(|id| scenes.iter().find(|s| s.id == id)) {
            Some(s) => out.push(View {
                title,
                ..view_of(s, at, true)
            }),
            None => out.push(View {
                at,
                title,
                streamed: true,
                ..View::default()
            }),
        }
    }
    (out, ok)
}

/// Whether plab already has a release's scene, through it or another release
/// (`same::Owned`): a grab from another indexer counts, though it shares no topic id.
pub struct Have<'a> {
    owned: crate::same::Owned,
    noise: &'a [String],
}

impl<'a> Have<'a> {
    pub fn new(db: &Db, noise: &'a [String]) -> anyhow::Result<Have<'a>> {
        Ok(Have {
            owned: crate::same::Owned::new(&db.download_titles()?, noise),
            noise,
        })
    }

    pub fn has(&self, id: u64, title: &str) -> bool {
        self.owned
            .of(id, crate::same::sig(title, self.noise, &[]).as_ref())
            .is_some()
    }
}

/// The releases on the Video and Indexers lists, as candidates' input.
fn releases(db: &Db, noise: &[String]) -> anyhow::Result<Vec<ReleaseIn>> {
    let have = Have::new(db, noise)?;
    let externals = db.externals()?;
    Ok(advisable(db)?
        .into_iter()
        .map(|(l, _)| {
            let row = &l.topic.row;
            ReleaseIn {
                id: row.id,
                title: row.title.clone(),
                studio: crate::labels::labels(&row.title, row.forum).studio,
                downloaded: have.has(row.id, &row.title),
                album: externals
                    .get(&row.id)
                    .is_some_and(|e| e.kind == Kind::Album),
            }
        })
        .collect())
}

pub async fn gather(
    db: &Db,
    stash: &Stash,
    hide: &crate::filters::HideRule,
    noise: &[String],
    now: i64,
) -> anyhow::Result<Context> {
    let (views, mut ok) = views(db, stash, now).await;
    let profile = taste::profile(&views, now);
    let ids = |ws: &[taste::Weighted], n: usize| -> Vec<String> {
        ws.iter().filter_map(|w| w.id.clone()).take(n).collect()
    };
    let scenes = if ok {
        match bounded(stash.unwatched(
            &ids(&profile.performers, 8),
            &ids(&profile.studios, 5),
            UNWATCHED,
        ))
        .await
        {
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
        .filter(|s| !crate::filters::scene_hidden(hide, s))
        .map(|s| SceneIn {
            id: s.id.clone(),
            title: s.label(),
            studio: s.studio.as_ref().map(|x| x.name.clone()),
            performers: s.performers.iter().map(|p| p.name.clone()).collect(),
            tags: s.tags.iter().map(|t| t.name.clone()).collect(),
            plays: s.play_count.unwrap_or(0),
        })
        .collect();
    let candidates =
        candidates::candidates(&profile, &scenes, &releases(db, noise)?, &never_offer(db));
    Ok(Context {
        profile,
        candidates,
        degraded: if ok { vec![] } else { vec!["stash"] },
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::body_string_contains;
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test(start_paused = true)]
    async fn a_stash_read_that_never_answers_is_a_failure() {
        let r: anyhow::Result<()> = bounded(std::future::pending()).await;
        assert!(r.unwrap_err().to_string().contains("no answer"));
    }
    fn listed(id: u64, title: &str) -> Listed {
        Listed {
            topic: crate::db::Topic {
                row: crate::tracker::parse::Row {
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

    #[test]
    fn a_release_owned_through_another_source_is_downloaded() {
        let db = Db::open_in_memory().unwrap();
        db.save_listing(
            Section::Video,
            &[
                listed(
                    1,
                    "[StudioB.com] Dana Lee, Cara Kim - Close To You [2026-10-30, 1080p]",
                ),
                listed(2, "[StudioB.com] Eve Ray - Rainy Day [2026-10-30, 1080p]"),
            ],
            &[],
            1000,
        )
        .unwrap();
        // A grab of the same scene from another indexer: no topic id to match by.
        db.mark_added(crate::db::NewDownload {
            source: "grab",
            topic_id: None,
            release_title: "Studio B 26 10 30 Cara Kim And Dana Lee Close To You 1080p MP4",
            section: Section::Video,
            download_dir: None,
            torrent_hash: None,
            now: 1000,
        })
        .unwrap();
        let got: Vec<(u64, bool)> = releases(&db, &[])
            .unwrap()
            .into_iter()
            .map(|r| (r.id, r.downloaded))
            .collect();
        assert_eq!(got, vec![(1, true), (2, false)]);
    }

    #[test]
    fn play_duration_becomes_watched_secs() {
        let s: LibScene =
            serde_json::from_value(serde_json::json!({"id": "1", "play_duration": 271.6})).unwrap();
        assert_eq!(view_of(&s, 0, false).watched_secs, Some(271));
    }

    async fn mock_stash(
        plays: serde_json::Value,
        by_ids: serde_json::Value,
    ) -> (MockServer, Stash) {
        let server = MockServer::start().await;
        let body = |v: serde_json::Value| {
            ResponseTemplate::new(200)
                .set_body_json(serde_json::json!({"data": {"findScenes": {"scenes": v}}}))
        };
        Mock::given(body_string_contains("GREATER_THAN"))
            .respond_with(body(plays))
            .mount(&server)
            .await;
        Mock::given(body_string_contains("$ids"))
            .respond_with(body(by_ids))
            .mount(&server)
            .await;
        let stash = Stash::new(&format!("{}/graphql", server.uri()), None);
        (server, stash)
    }

    #[tokio::test]
    async fn a_voted_never_played_scene_shapes_the_profile() {
        let now = 1_000_000;
        let db = Db::open_in_memory().unwrap();
        db.vote_set("9", -1, now).unwrap();
        let (_server, stash) = mock_stash(
            serde_json::json!([]),
            serde_json::json!([{"id": "9", "title": "Nine", "studio": {"id": "s9", "name": "Studio X"}}]),
        )
        .await;
        let (views, ok) = views(&db, &stash, now).await;
        assert!(ok);
        assert_eq!(views.len(), 1);
        assert!(views[0].vote_only);
        assert_eq!(views[0].at, now);
        let p = taste::profile(&views, now);
        assert_eq!(p.voted_down.studios[0].name, "Studio X");
    }

    #[tokio::test]
    async fn a_played_scene_carries_its_vote() {
        let now = 1_000_000;
        let db = Db::open_in_memory().unwrap();
        db.vote_set("4", 1, now).unwrap();
        let played = serde_json::json!([{"id": "4", "title": "Four", "play_count": 1,
            "play_duration": 300.0, "last_played_at": "1970-01-12T13:46:40Z"}]);
        let (_server, stash) = mock_stash(played, serde_json::json!([])).await;
        let (views, _) = views(&db, &stash, now).await;
        assert_eq!(views.len(), 1);
        assert_eq!((views[0].vote, views[0].vote_only), (Some((1, now)), false));
        assert_eq!(views[0].watched_secs, Some(300));
    }

    #[tokio::test]
    async fn a_vote_on_a_scene_stash_lost_is_skipped() {
        let db = Db::open_in_memory().unwrap();
        db.vote_set("9", -1, 100).unwrap();
        let (_server, stash) = mock_stash(serde_json::json!([]), serde_json::json!([])).await;
        let (views, ok) = views(&db, &stash, 100).await;
        assert!(ok);
        assert!(views.is_empty());
    }

    #[test]
    fn never_offer_is_voted_down_and_deleted_and_needs_no_stash() {
        let db = Db::open_in_memory().unwrap();
        db.vote_set("9", -1, 100).unwrap();
        db.vote_set("4", 1, 100).unwrap();
        db.deleted_add(&["7".to_string()], 100).unwrap();
        assert_eq!(
            never_offer(&db),
            HashSet::from(["9".to_string(), "7".to_string()])
        );
    }
}
