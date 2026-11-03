//! The JSON the app reads: a section's list, a search, recent grabs, and the jobs. Pure:
//! the handlers in `web` gather the data, these functions shape it. Every rule about a
//! topic (its labels, rank, production class, status) is decided here, never in the app.

use crate::db::{Db, DownloadRow, JobRunRow, Listed, Listing, Section};
use crate::images::key;
use crate::jobs;
use crate::labels::labels;
use crate::monitor::{JobLive, Line, LiveState, Monitor};
use crate::provenance::{self, Failure, Status};
use serde::Serialize;
use std::collections::{HashMap, HashSet};

/// Seeders count for more or less by how the release was produced, so mass-produced releases
/// sink below amateur and artistic ones. Unclassified counts as 1.0.
fn weight(class: Option<&str>) -> f64 {
    match class {
        Some("amateur") => 1.5,
        Some("pro_artistic") => 1.0,
        Some("industrial") => 0.25,
        _ => 1.0,
    }
}

pub fn production(t: &Listed) -> Option<&str> {
    t.topic.production.as_ref().map(|p| p.class.as_str())
}

/// A production class as the page names it (its badge and Production filter).
fn production_name(class: Option<&str>) -> Option<&'static str> {
    match class {
        Some("amateur") => Some("amateur"),
        Some("pro_artistic") => Some("artistic"),
        Some("industrial") => Some("industrial"),
        _ => None,
    }
}

pub fn score(t: &Listed) -> f64 {
    t.topic.row.seeders as f64 * weight(production(t))
}

/// What became of the downloads the app shows: plab's by topic, and recent grabs.
#[derive(Debug, Default)]
pub struct Downloads {
    pub by_topic: HashMap<u64, Status>,
    pub grabs: Vec<(DownloadRow, Status)>,
    /// Stash's web address, for links to a download's scenes; None gives no links.
    pub stash: Option<String>,
}

impl Downloads {
    pub(crate) fn link(&self, s: &Status) -> Option<String> {
        provenance::stash_link(self.stash.as_deref()?, s)
    }

    pub fn status_of(&self, s: &Status) -> StatusDto {
        status(s, self.link(s))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StatusDto {
    Queued,
    Downloading {
        percent: u8,
    },
    Added,
    InStash {
        link: Option<String>,
    },
    Identified {
        label: String,
        more: usize,
        guess: bool,
        link: Option<String>,
    },
    Failed {
        reason: &'static str,
        detail: String,
    },
}

pub fn status(s: &Status, link: Option<String>) -> StatusDto {
    match s {
        Status::Queued => StatusDto::Queued,
        Status::Downloading(p) => StatusDto::Downloading { percent: *p },
        Status::Added => StatusDto::Added,
        Status::InStash { .. } => StatusDto::InStash { link },
        Status::Identified {
            label, more, guess, ..
        } => StatusDto::Identified {
            label: label.clone(),
            more: *more,
            guess: *guess,
            link,
        },
        Status::Failed(f) => {
            let (reason, detail) = match f {
                Failure::Transmission(why) => ("download", why.clone()),
                Failure::Identify => ("identify", "identify found nothing or gave up".into()),
                Failure::Lost => ("lost", "the torrent is gone and no scene came of it".into()),
            };
            StatusDto::Failed { reason, detail }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TopicDto {
    pub id: u64,
    pub title: String,
    pub name: String,
    pub studio: Option<String>,
    pub quality: Option<String>,
    pub category: &'static str,
    pub production: Option<&'static str>,
    pub tags: Vec<String>,
    pub filters: Vec<String>,
    pub size: u64,
    pub seeders: u32,
    pub leechers: u32,
    pub added: i64,
    /// None: a live search result whose images come lazily through /api/thumb.
    pub images: Option<Vec<String>>,
    pub state: &'static str,
    pub status: Option<StatusDto>,
    /// The indexer a release from another indexer came from; None for the tracker's own.
    pub source: Option<String>,
    /// That release's page; None for the tracker's own (the app builds the tracker link).
    pub link: Option<String>,
    /// "tracker", or the external release's kind: "torrent" or "album".
    pub kind: &'static str,
    /// An album's file count.
    pub files: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct SearchReply {
    pub query: String,
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListDto {
    pub now: i64,
    pub section: &'static str,
    pub updated: i64,
    pub topic_url: String,
    /// The filter file's names, in file order.
    pub curated_filters: Vec<String>,
    /// Queued and not yet added.
    pub pending: usize,
    pub topics: Vec<TopicDto>,
    #[serde(flatten)]
    pub search: Option<SearchReply>,
}

#[allow(clippy::too_many_arguments)] // one argument per input of the page; a struct would only rename them
pub fn list(
    listing: &Listing,
    added: &HashSet<u64>,
    queued: &HashSet<u64>,
    now: i64,
    section: Section,
    downloads: &Downloads,
    search: Option<SearchReply>,
    externals: &HashMap<u64, crate::db::External>,
) -> ListDto {
    // A stable sort, descending: equal scores keep the tracker's order.
    let mut topics: Vec<&Listed> = listing.topics.iter().collect();
    topics.sort_by(|a, b| score(b).partial_cmp(&score(a)).unwrap());
    ListDto {
        now,
        section: section.as_str(),
        updated: listing.updated,
        topic_url: crate::site::get().topic_url(),
        curated_filters: listing.filters.clone(),
        pending: queued.difference(added).count(),
        topics: topics
            .into_iter()
            .map(|t| topic(t, added, queued, downloads, externals))
            .collect(),
        search,
    }
}

fn topic(
    t: &Listed,
    added: &HashSet<u64>,
    queued: &HashSet<u64>,
    downloads: &Downloads,
    externals: &HashMap<u64, crate::db::External>,
) -> TopicDto {
    let row = &t.topic.row;
    let ext = externals.get(&row.id);
    let l = labels(&row.title, row.forum);
    let state = if added.contains(&row.id) {
        "added"
    } else if queued.contains(&row.id) {
        "queued"
    } else {
        ""
    };
    TopicDto {
        id: row.id,
        title: row.title.clone(),
        name: l.name,
        studio: l.studio,
        quality: l.quality,
        category: l.category,
        production: production_name(production(t)),
        tags: l.tags,
        filters: t.filters.clone(),
        size: row.size,
        seeders: row.seeders,
        leechers: row.leechers,
        added: row.added,
        images: t
            .topic
            .images
            .as_ref()
            .map(|v| v.iter().map(|u| key(u)).collect()),
        state,
        status: downloads
            .by_topic
            .get(&row.id)
            .map(|s| downloads.status_of(s)),
        source: ext.map(|e| e.indexer.clone()),
        link: ext
            .and_then(|e| e.info_url.as_deref())
            .filter(|u| is_http_url(u))
            .map(str::to_owned),
        kind: match ext.map(|e| e.kind) {
            None => "tracker",
            Some(crate::db::Kind::Torrent) => "torrent",
            Some(crate::db::Kind::Album) => "album",
        },
        files: ext.and_then(|e| e.files),
    }
}

/// An indexer's page address is untrusted; only web schemes may reach an href.
fn is_http_url(u: &str) -> bool {
    let u = u.trim_start().to_ascii_lowercase();
    u.starts_with("http://") || u.starts_with("https://")
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GrabDto {
    pub studio: Option<String>,
    pub title: String,
    pub added_at: Option<i64>,
    pub status: StatusDto,
}

#[derive(Debug, Serialize)]
pub struct GrabsDto {
    pub now: i64,
    pub grabs: Vec<GrabDto>,
}

pub fn grabs(d: &Downloads, now: i64) -> GrabsDto {
    GrabsDto {
        now,
        grabs: d
            .grabs
            .iter()
            .map(|(r, s)| GrabDto {
                studio: r.studio.clone(),
                title: r.release_title.clone(),
                added_at: r.added_at,
                status: d.status_of(s),
            })
            .collect(),
    }
}

/// One job as the jobs spec's `/jobs.json` entry; its keys are that spec's, unchanged.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct JobDto {
    pub name: String,
    pub state: &'static str,
    pub since: Option<i64>,
    pub pending: Option<usize>,
    pub restart_at: Option<i64>,
    pub next: Option<i64>,
    pub step: Option<Line>,
    pub progress: Option<(u64, u64)>,
    pub lines: Vec<Line>,
    pub runs: Vec<JobRunRow>,
}

#[derive(Debug, Serialize)]
pub struct JobsDto {
    pub now: i64,
    pub jobs: Vec<JobDto>,
}

/// Runs shown per job.
const RUNS: usize = 10;

pub fn job(name: &str, live: &JobLive, db: &Db, now: i64) -> JobDto {
    let (state, since, pending, restart_at) = match live.state {
        LiveState::Idle => ("idle", None, None, None),
        LiveState::Running { since } => ("running", Some(since), None, None),
        LiveState::Watching { pending } => ("watching", None, Some(pending), None),
        LiveState::Restarting { at } => ("restarting", None, None, Some(at)),
    };
    // A failed history read still serves the live state.
    let runs = db.job_history(name, RUNS).unwrap_or_else(|e| {
        tracing::info!(job = "web", "job history {name}: {e:#}");
        vec![]
    });
    JobDto {
        name: name.to_string(),
        state,
        since,
        pending,
        restart_at,
        next: jobs::schedule(name).map(|s| jobs::next_slot(s, now)),
        step: live.step.clone(),
        progress: live.progress,
        lines: live.lines.iter().cloned().collect(),
        runs,
    }
}

pub fn jobs(m: &Monitor, db: &Db, now: i64) -> JobsDto {
    JobsDto {
        now,
        jobs: m
            .snapshot()
            .iter()
            .map(|(n, l)| job(n, l, db, now))
            .collect(),
    }
}

#[cfg(test)]
#[path = "api_tests.rs"]
mod tests;
