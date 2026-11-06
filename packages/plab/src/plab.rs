//! plab's domain: the list refresh, adds and the download queue, live search, and the
//! image proxy. Port of main.py's `refresh`, `add_topic`, `unqueue_topic`, `drain_queue`,
//! `run_refresh`, `image_for`, `run_search` and `topic_images`.

use crate::backends::Backends;
use crate::db::{Db, Listed, NewDownload, Section, Topic};
use crate::filters::{Filters, load_excludes, load_filters, match_filters};
use crate::images::{ImageCache, key, sniff};
use crate::llm::Classify;
use crate::prowlarr::Prowlarr;
use crate::tracker::forums::{self, category};
use crate::tracker::{TrackerApi, TrackerError, parse};
use crate::transmission::{TorrentClient, TorrentSource};
use anyhow::{Context, bail};
use std::collections::hash_map::Entry;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::time::Duration;
use tracing::{info, warn};

pub const DAYS: u32 = 7;
/// Game uploads are far rarer than video. 32, not 30: the tracker's time select has no 30.
pub const GAMES_DAYS: u32 = 32;
pub const LIMIT: usize = 100;
/// Between topic fetches and curated searches; be gentle with the tracker.
pub const DELAY: Duration = Duration::from_secs(1);
/// Consecutive classifier failures after which one refresh stops asking; the next refresh
/// retries.
pub const CLASSIFY_FAILURE_LIMIT: u32 = 3;
/// One results page per live search: a single tracker request.
pub const SEARCH_LIMIT: usize = 50;

pub struct Ctx<'a, B: Backends> {
    pub tracker: &'a B::Tracker,
    pub torrents: &'a B::Torrents,
    pub db: &'a Db,
    pub images: &'a ImageCache,
    pub state_dir: &'a Path,
    pub exclude_file: Option<&'a Path>,
    pub filter_file: Option<&'a Path>,
    pub download_dir: &'a str,
    pub games_dir: Option<&'a str>,
    /// DELAY in production, ZERO in tests.
    pub delay: Duration,
    /// Topic pages fetched at once for search thumbnails (2 permits): one results page must
    /// not burst the tracker.
    pub fetch_slots: &'a tokio::sync::Semaphore,
    /// Prowlarr, for curated releases from other indexers; None turns them off.
    pub prowlarr: Option<&'a Prowlarr>,
}

#[derive(Debug, thiserror::Error)]
#[error("topic {0} is not on the list")]
pub struct NotListed(pub u64);

#[derive(Debug, Clone, PartialEq)]
pub enum AddResult {
    Added { name: String },
    AlreadyAdded,
    Queued { message: String },
}

/// The cached image of `url`, fetched on first use. An image host's error page must not be
/// cached as the image.
pub async fn ensure_image<T: TrackerApi>(
    tracker: &T,
    images: &ImageCache,
    url: &str,
) -> anyhow::Result<PathBuf> {
    let path = images.path(url);
    if path.exists() {
        return Ok(path);
    }
    let data = tracker.fetch(url).await?;
    if sniff(&data).is_none() {
        bail!("not an image: {url}");
    }
    Ok(images.put(url, &data)?)
}

fn is_login(e: &anyhow::Error) -> bool {
    matches!(
        e.downcast_ref::<TrackerError>(),
        Some(TrackerError::Login(_))
    )
}

/// Rebuild a section's list. Errors, leaving the old list in place, if the list fails.
/// Curated filters and `classify` belong to the video list only.
pub async fn refresh<B: Backends, K: Classify>(
    ctx: &Ctx<'_, B>,
    section: Section,
    classify: Option<&K>,
    now: i64,
) -> anyhow::Result<()> {
    let (forums, days, classify) = match section {
        Section::Video => (forums::forums(), DAYS, classify),
        Section::Games => (forums::games().to_vec(), GAMES_DAYS, None),
        Section::Indexers | Section::Albums => bail!(
            "the {} list is rebuilt from curated hits, not refreshed",
            section.as_str()
        ),
    };
    let excludes = load_excludes(ctx.exclude_file, Some(ctx.state_dir));
    let rows = ctx.tracker.top(&forums, days, LIMIT, &excludes).await?;
    if rows.is_empty() {
        bail!("tracker returned no rows");
    }

    let filters: Filters = match section {
        Section::Video => load_filters(ctx.filter_file, Some(ctx.state_dir)),
        _ => vec![],
    };
    // The curated job's stored hits on the tracker (video only); other sources have
    // their own lists (`curated::rebuild_external`).
    let hits: Vec<crate::db::StoredHit> = match section {
        Section::Video => ctx
            .db
            .curated_hits()?
            .into_iter()
            .filter(|h| h.kind.is_none())
            .collect(),
        _ => vec![],
    };
    // topic id -> {filter name: badge of the first term that found it}
    let mut found: HashMap<u64, HashMap<String, String>> = HashMap::new();
    let mut stored: HashMap<u64, Topic> = HashMap::new();
    let mut extra_rows = vec![];
    for h in hits {
        let (topic, filter, reason) = (h.topic, h.filter, h.reason);
        found
            .entry(topic.row.id)
            .or_default()
            .entry(filter)
            .or_insert(reason);
        if let Entry::Vacant(slot) = stored.entry(topic.row.id) {
            extra_rows.push(topic.row.clone());
            slot.insert(topic);
        }
    }

    // Combine and deduplicate rows by id.
    let mut seen = HashSet::new();
    let combined: Vec<_> = rows
        .into_iter()
        .chain(extra_rows)
        .filter(|r| seen.insert(r.id))
        .collect();

    let previous: HashMap<u64, Topic> = ctx
        .db
        .listing(section)?
        .topics
        .into_iter()
        .map(|l| (l.topic.row.id, l.topic))
        .collect();
    let mut topics = vec![];
    let mut classify_failures = 0;
    for row in combined {
        let prev = previous.get(&row.id).or_else(|| stored.get(&row.id));
        let mut images = prev.and_then(|t| t.images.clone()).unwrap_or_default();
        // A release from another indexer has only the images the curated job gave it.
        if images.is_empty() && !crate::db::is_external(row.id) {
            tokio::time::sleep(ctx.delay).await;
            match ctx.tracker.topic(row.id).await {
                Ok(page) => images = parse::images(&page),
                // The session is gone: stop, don't log in once per remaining topic.
                Err(e @ TrackerError::Login(_)) => return Err(e.into()),
                // One bad topic must not sink the refresh.
                Err(e) => warn!("topic {}: {e}", row.id),
            }
        }
        if let Some(first) = images.first()
            && let Err(e) = ensure_image(ctx.tracker, ctx.images, first).await
        {
            warn!("image {first}: {e:#}");
        }
        // A top-list release whose title names a term belongs to that filter too.
        let (names, reason) = match_filters(&filters, &row.title, found.get(&row.id));
        // Judged once per release; an unclassified one ranks on seeders alone until retried.
        let mut production = prev.and_then(|t| t.production.clone());
        if let Some(k) =
            classify.filter(|_| production.is_none() && classify_failures < CLASSIFY_FAILURE_LIMIT)
        {
            match k.classify(&row.title, category(row.forum)).await {
                Ok(p) => {
                    production = Some(p);
                    classify_failures = 0;
                }
                // Classification must never sink the refresh.
                Err(e) => {
                    classify_failures += 1;
                    warn!("classify {}: {e:#}", row.id);
                    if classify_failures == CLASSIFY_FAILURE_LIMIT {
                        warn!(
                            "classify: {CLASSIFY_FAILURE_LIMIT} failures in a row, skipping the rest of this refresh"
                        );
                    }
                }
            }
        }
        topics.push(Listed {
            topic: Topic {
                row,
                images: Some(images),
                production,
            },
            filters: names,
            curated_reason: reason,
        });
    }
    let names: Vec<String> = filters.into_iter().map(|(name, _)| name).collect();
    ctx.db.save_listing(section, &topics, &names, now)?;
    crate::events::publish(crate::events::Event::Listing {
        section: section.as_str(),
    });
    // After save_listing: both lists, plus searches.
    ctx.images.prune(&ctx.db.image_urls(now)?)?;
    info!(
        "refreshed {}: {} topics ({} curated, {} classified)",
        section.as_str(),
        topics.len(),
        topics.iter().filter(|t| !t.filters.is_empty()).count(),
        topics
            .iter()
            .filter(|t| t.topic.production.is_some())
            .count()
    );
    Ok(())
}

/// Send a listed (or recently searched) topic's torrent to Transmission: into
/// `download_dir`, or `games_dir` for a topic of the games list. Past the tracker's daily
/// download limit the topic waits in its section's queue for `drain_queue`.
pub async fn add_topic<B: Backends>(
    ctx: &Ctx<'_, B>,
    topic_id: u64,
    now: i64,
) -> anyhow::Result<AddResult> {
    if ctx.db.added()?.contains(&topic_id) {
        return Ok(AddResult::AlreadyAdded); // a stale page must not burn a daily-quota slot
    }
    let Some((topic, section)) = ctx.db.find(topic_id, now)? else {
        return Err(NotListed(topic_id).into());
    };
    // A download row's section names the Vault it lands in, not the list it was added
    // from: an Indexers release is a Vault video download, so provenance sync, card status
    // and prune hold-back (all keyed on 'video') see it.
    let section = if section == Section::Indexers {
        Section::Video
    } else {
        section
    };
    let dir = match section {
        Section::Video | Section::Indexers => Some(ctx.download_dir),
        Section::Games => ctx.games_dir,
        Section::Albums => None,
    }
    .filter(|d| !d.is_empty())
    .with_context(|| format!("no download directory for {}", section.as_str()))?;
    let torrent = if crate::db::is_external(topic_id) {
        // Not the tracker: no daily limit, never queued.
        external_torrent(ctx.prowlarr, ctx.db, topic_id, now).await?
    } else {
        match ctx.tracker.torrent(topic_id).await {
            Ok(t) => TorrentSource::Bytes(t),
            Err(e @ TrackerError::Limit(_)) => {
                ctx.db.enqueue(topic_id, section, now)?;
                return Ok(AddResult::Queued {
                    message: e.to_string(),
                });
            }
            Err(e) => return Err(e.into()),
        }
    };
    let added = ctx.torrents.add(&torrent, dir).await?;
    let download_id = ctx.db.mark_added(NewDownload {
        source: "plab",
        topic_id: Some(topic_id),
        release_title: &topic.row.title,
        section,
        download_dir: Some(dir),
        torrent_hash: added.hash.as_deref(),
        now,
    })?;
    save_cover(ctx, topic_id, download_id, now).await;
    Ok(AddResult::Added { name: added.name })
}

/// How long a download's tracker cover is kept: identify uses it within hours.
pub const COVER_DAYS: i64 = 90;

/// Copy a just-added topic's first image out of the image cache, which forgets it once the
/// topic leaves the lists, to <state_dir>/covers/<download id>, for identify to use as the
/// scene's cover. The add has already happened, so a failure is only logged.
pub async fn save_cover<B: Backends>(ctx: &Ctx<'_, B>, topic_id: u64, download_id: i64, now: i64) {
    let result: anyhow::Result<()> = async {
        let images = topic_images(ctx, topic_id, now).await?;
        let Some(first) = images.first() else {
            return Ok(());
        };
        let cached = ensure_image(ctx.tracker, ctx.images, first).await?;
        let dir = ctx.state_dir.join("covers");
        std::fs::create_dir_all(&dir)?;
        let dest = dir.join(download_id.to_string());
        std::fs::copy(&cached, &dest)?;
        ctx.db.set_cover(download_id, &dest.to_string_lossy())?;
        Ok(())
    }
    .await;
    if let Err(e) = result {
        warn!("cover for topic {topic_id}: {e:#}");
    }
}

/// Delete covers older than COVER_DAYS.
pub fn prune_covers(db: &Db, now: i64) {
    let stale = match db.stale_covers(now - COVER_DAYS * 86400) {
        Ok(s) => s,
        Err(e) => return warn!("covers: {e:#}"),
    };
    for (id, path) in stale {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                warn!("cover {path}: {e}");
                continue;
            }
        }
        if let Err(e) = db.clear_cover(id) {
            warn!("cover {id}: {e:#}");
        }
    }
}

/// Take a topic off whichever queue holds it. Idempotent: a topic that is not queued is fine.
pub fn unqueue_topic(db: &Db, topic_id: u64) -> anyhow::Result<()> {
    for section in Section::ALL {
        db.dequeue(topic_id, section)?;
    }
    Ok(())
}

fn db_error(e: anyhow::Error) -> TrackerError {
    TrackerError::Tracker(format!("{e:#}"))
}

/// Add a section's queued topics into `dir`, oldest first. Stops at the first limit reply,
/// returning false: every further attempt, in any queue, would only fetch the limit page
/// again. Returns true otherwise. A database failure reading the queue comes back as
/// `TrackerError::Tracker`.
pub async fn drain_queue<B: Backends>(
    ctx: &Ctx<'_, B>,
    section: Section,
    dir: &str,
    now: i64,
) -> Result<bool, TrackerError> {
    for topic_id in ctx.db.queued(section).map_err(db_error)? {
        let torrent = match ctx.tracker.torrent(topic_id).await {
            Ok(t) => t,
            Err(e @ TrackerError::Limit(_)) => {
                let left = ctx.db.queued(section).map_err(db_error)?.len();
                info!("queue: {e}; {left} still queued in {}", section.as_str());
                return Ok(false);
            }
            Err(e @ TrackerError::Login(_)) => return Err(e), // never loop logins
            // Permanent (deleted topic, no access): drop it.
            Err(e @ TrackerError::Tracker(_)) => {
                ctx.db.dequeue(topic_id, section).map_err(db_error)?;
                info!("queued {topic_id} dropped: {e}");
                crate::events::publish(crate::events::Event::TopicState {
                    id: topic_id,
                    state: "",
                });
                continue;
            }
            // Network: retry next time.
            Err(e @ TrackerError::Http(_)) => {
                warn!("queued {topic_id} kept: {e}");
                continue;
            }
        };
        // Transmission or the database: retry next time.
        let result: anyhow::Result<i64> = async {
            let title = ctx.db.queued_title(topic_id)?;
            let added = ctx
                .torrents
                .add(&TorrentSource::Bytes(torrent), dir)
                .await?;
            ctx.db.dequeue(topic_id, section)?; // first: a crash between the two must not re-download
            ctx.db.mark_added(NewDownload {
                source: "plab",
                topic_id: Some(topic_id),
                release_title: &title,
                section,
                download_dir: Some(dir),
                torrent_hash: added.hash.as_deref(),
                now,
            })
        }
        .await;
        match result {
            Ok(id) => {
                save_cover(ctx, topic_id, id, now).await;
                info!("queued {topic_id}: added");
                crate::events::publish(crate::events::Event::TopicState {
                    id: topic_id,
                    state: "added",
                });
            }
            Err(e) => warn!("queued {topic_id} kept: {e:#}"),
        }
    }
    Ok(true)
}

/// The `refresh` job: drain the queues, then rebuild the video list and, with a
/// `games_dir`, the games list. A failure of one list leaves the other refreshed; the first
/// error is returned at the end. A login failure stops everything at once.
pub async fn run_refresh<B: Backends, K: Classify>(
    ctx: &Ctx<'_, B>,
    classify: Option<&K>,
    now: i64,
) -> anyhow::Result<()> {
    let dirs = [
        (Section::Video, Some(ctx.download_dir)),
        (Section::Games, ctx.games_dir),
    ];
    let drained: Result<(), TrackerError> = async {
        for (section, dir) in dirs {
            let Some(dir) = dir.filter(|d| !d.is_empty()) else {
                continue;
            };
            if !drain_queue(ctx, section, dir, now).await? {
                break; // the daily limit: the next queue would only hit it too
            }
        }
        Ok(())
    }
    .await;
    match drained {
        Ok(()) => {}
        // The session is gone; the list refresh would only fail the same way.
        Err(e @ TrackerError::Login(_)) => return Err(e.into()),
        // The list refresh must still run.
        Err(e) => warn!("queue drain failed: {e}"),
    }
    // Cheap (no tracker request), and fills the source lists on the first start after a
    // deploy, before the next curated run.
    if let Err(e) = crate::curated::rebuild_external(ctx, now).await {
        warn!("rebuilding the source lists failed: {e:#}");
    }
    let mut runs = vec![Section::Video];
    if ctx.games_dir.is_some_and(|d| !d.is_empty()) {
        runs.push(Section::Games);
    }
    let mut first_error = None;
    for section in runs {
        match refresh(ctx, section, classify, now).await {
            Ok(()) => {}
            Err(e) if is_login(&e) => return Err(e),
            // One list failing must not stop the other.
            Err(e) => {
                warn!("refresh {} failed: {e:#}", section.as_str());
                first_error.get_or_insert(e);
            }
        }
    }
    prune_covers(ctx.db, now);
    first_error.map_or(Ok(()), Err)
}

/// (bytes, content type) for an image of a listed or searched topic, fetching it on first
/// use. Only those topics' URLs resolve, so this is not an open proxy.
pub async fn image_for<B: Backends>(
    ctx: &Ctx<'_, B>,
    image_key: &str,
    now: i64,
) -> anyhow::Result<Option<(Vec<u8>, &'static str)>> {
    let Some(url) = ctx
        .db
        .image_urls(now)?
        .into_iter()
        .find(|u| key(u) == image_key)
    else {
        return Ok(None);
    };
    let path = ensure_image(ctx.tracker, ctx.images, &url).await?;
    let data = std::fs::read(&path).with_context(|| format!("reading {}", path.display()))?;
    // Python handed sniff()'s None on; a cached file always sniffs (ensure_image checks).
    let ctype = sniff(&data).unwrap_or("application/octet-stream");
    Ok(Some((data, ctype)))
}

/// A live tracker search over all time, recorded in the database; the entries in tracker
/// order, with their curated filters. Never touches the lists.
pub async fn run_search<B: Backends>(
    ctx: &Ctx<'_, B>,
    query: &str,
    now: i64,
) -> anyhow::Result<Vec<Listed>> {
    let excludes = load_excludes(ctx.exclude_file, Some(ctx.state_dir));
    let rows = ctx
        .tracker
        .search(
            query,
            &forums::forums(),
            None,
            SEARCH_LIMIT,
            &excludes,
            Some(1),
        )
        .await?;
    ctx.db.save_search(&rows, now)?;
    let known = ctx.db.search_topics(now)?;
    let filters = load_filters(ctx.filter_file, Some(ctx.state_dir));
    rows.iter()
        .map(|r| {
            let (filters, curated_reason) = match_filters(&filters, &r.title, None);
            let topic = known
                .get(&r.id)
                .cloned()
                .with_context(|| format!("search hit {} was not recorded", r.id))?;
            Ok(Listed {
                topic,
                filters,
                curated_reason,
            })
        })
        .collect()
}

/// A release from another indexer's torrent: the stored `.torrent`, else Prowlarr's
/// download link, whose `.torrent` answer is stored for next time (a magnet is used as is).
pub async fn external_torrent(
    prowlarr: Option<&Prowlarr>,
    db: &Db,
    id: u64,
    now: i64,
) -> anyhow::Result<TorrentSource> {
    if let Some(bytes) = db.torrent_file(id)? {
        return Ok(TorrentSource::Bytes(bytes));
    }
    let ext = db
        .external(id)?
        .with_context(|| format!("release {id} is not known"))?;
    if ext.kind == crate::db::Kind::Album {
        bail!("release {id} is an album, not a torrent");
    }
    let prowlarr = prowlarr.context("Prowlarr is not configured")?;
    let src = prowlarr.fetch(&ext.link).await?;
    if let TorrentSource::Bytes(b) = &src {
        db.store_torrent_file(id, b, now)?;
    }
    Ok(src)
}

/// The image URLs of a listed or searched topic, fetching a searched one's on first use.
pub async fn topic_images<B: Backends>(
    ctx: &Ctx<'_, B>,
    topic_id: u64,
    now: i64,
) -> anyhow::Result<Vec<String>> {
    let images = |db: &Db| -> anyhow::Result<Option<Option<Vec<String>>>> {
        Ok(db.find(topic_id, now)?.map(|(t, _)| t.images))
    };
    let Some(found) = images(ctx.db)? else {
        return Err(NotListed(topic_id).into());
    };
    if let Some(found) = found {
        return Ok(found);
    }
    // A release from another indexer has only the images the curated job found for it.
    if crate::db::is_external(topic_id) {
        return Ok(vec![]);
    }
    let _slot = ctx.fetch_slots.acquire().await?;
    // Another request may have fetched them while this one waited.
    if let Some(Some(found)) = images(ctx.db)? {
        return Ok(found);
    }
    let found = parse::images(&ctx.tracker.topic(topic_id).await?);
    ctx.db.set_images(topic_id, &found)?;
    Ok(found)
}

#[cfg(test)]
#[path = "plab_tests.rs"]
mod tests;
