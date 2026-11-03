//! The `curated` job, daily: every curated filter's terms searched on the tracker over
//! `WINDOW_DAYS`, and the terms marked `@` through Prowlarr's other indexers. Releases
//! from other indexers are collapsed to one per release, dropped when the tracker has
//! them, classified (the down-ranked class is dropped) and given scene images when the
//! scene database knows them. The hits replace `curated_hit`, then the video list is
//! rebuilt so they show at once.

use std::collections::{HashMap, HashSet};

use anyhow::{Context, bail};
use tracing::{info, warn};

use crate::db::{CuratedHit, Kind, NewExternal, Section, Topic};
use crate::external::{Candidate, collapse, is_duplicate, scene_query};
use crate::filters::{FilterTerms, excluded, load_excludes, load_filter_terms};
use crate::labels::term_label;
use crate::llm::Classify;
use crate::plab::{CLASSIFY_FAILURE_LIMIT, Ctx, ensure_image, refresh};
use crate::prowlarr::ProwlarrResult;
use crate::scenes::{SceneDb, accept};
use crate::sources::Sources;
use crate::tracker::forums::{self, category};
use crate::tracker::parse::Row;
use crate::tracker::{TrackerApi, TrackerError};
use crate::transmission::TorrentClient;

pub const WINDOW_DAYS: u32 = 32;
/// Tracker results per term.
const PER_TERM: usize = 20;
/// The production class whose releases from other indexers are not shown.
pub const DOWN_RANKED: &str = "industrial";

/// What the external pass needs besides `Ctx`.
pub struct Elsewhere<'a> {
    pub sources: &'a Sources,
    pub scenes: Option<&'a SceneDb>,
}

pub async fn run_curated<T: TrackerApi, C: TorrentClient, K: Classify>(
    ctx: &Ctx<'_, T, C>,
    classify: Option<&K>,
    elsewhere: Option<Elsewhere<'_>>,
    now: i64,
) -> anyhow::Result<()> {
    let filters = load_filter_terms(ctx.filter_file, Some(ctx.state_dir));
    let excludes = load_excludes(ctx.exclude_file, Some(ctx.state_dir));
    let forums = forums::forums();
    let mut topics: Vec<Topic> = vec![];
    let mut hits: Vec<CuratedHit> = vec![];
    let mut seen: HashSet<(u64, String)> = HashSet::new();
    // filter name -> the tracker titles it found, for the duplicate check
    let mut tracker_titles: HashMap<String, Vec<String>> = HashMap::new();
    let total: usize = filters.iter().map(|(_, t)| t.len()).sum();
    let mut done = 0usize;
    for (name, terms) in &filters {
        for term in terms {
            done += 1;
            info!(done, total, "search {:?}", term.text);
            tokio::time::sleep(ctx.delay).await;
            let results = match ctx
                .tracker
                .search(
                    &term.text,
                    &forums,
                    Some(WINDOW_DAYS),
                    PER_TERM,
                    &excludes,
                    None,
                )
                .await
            {
                Ok(r) => r,
                Err(e @ TrackerError::Login(_)) => return Err(e.into()),
                // One failed search must not sink the run.
                Err(e) => {
                    warn!("search failed for {:?}: {e}", term.text);
                    continue;
                }
            };
            for r in results {
                tracker_titles
                    .entry(name.clone())
                    .or_default()
                    .push(r.title.clone());
                if seen.insert((r.id, name.clone())) {
                    hits.push(CuratedHit {
                        topic_id: r.id,
                        filter: name.clone(),
                        reason: term_label(&term.text),
                    });
                }
                topics.push(Topic {
                    row: r,
                    images: None,
                    production: None,
                });
            }
        }
    }
    if let Some(e) = elsewhere {
        match external_pass(ctx, classify, &e, &filters, &tracker_titles, &excludes, now).await {
            Ok((t, h)) => {
                topics.extend(t);
                hits.extend(
                    h.into_iter()
                        .filter(|h| seen.insert((h.topic_id, h.filter.clone()))),
                );
            }
            // The tracker's hits are still stored.
            Err(err) => warn!("other indexers skipped: {err:#}"),
        }
    }
    ctx.db.save_curated(&topics, &hits, now)?;
    info!("curated: {} hits", hits.len());
    refresh(ctx, Section::Video, classify, now).await
}

fn candidate(r: &ProwlarrResult, cutoff: i64) -> Option<Candidate> {
    if r.protocol.as_deref() != Some("torrent") {
        return None;
    }
    let published = chrono::DateTime::parse_from_rfc3339(r.publish_date.as_deref()?)
        .ok()?
        .timestamp();
    if published < cutoff {
        return None;
    }
    Some(Candidate {
        indexer: r.indexer.clone()?,
        guid: r.guid.clone()?,
        link: r.download_url.clone()?,
        info_url: r.info_url.clone(),
        title: r.title.clone()?,
        size: r.size.unwrap_or(0.0) as u64,
        seeders: r.seeders.unwrap_or(0.0) as u32,
        leechers: r.leechers.unwrap_or(0.0) as u32,
        published,
    })
}

async fn external_pass<T: TrackerApi, C: TorrentClient, K: Classify>(
    ctx: &Ctx<'_, T, C>,
    classify: Option<&K>,
    e: &Elsewhere<'_>,
    filters: &FilterTerms,
    tracker_titles: &HashMap<String, Vec<String>>,
    excludes: &[fancy_regex::Regex],
    now: i64,
) -> anyhow::Result<(Vec<Topic>, Vec<CuratedHit>)> {
    if !filters
        .iter()
        .any(|(_, terms)| terms.iter().any(|t| t.elsewhere))
    {
        return Ok((vec![], vec![]));
    }
    if e.sources.categories.is_empty() {
        info!("plab-sources names no categories: other indexers are not searched");
        return Ok((vec![], vec![]));
    }
    let prowlarr = ctx.prowlarr.context("Prowlarr is not configured")?;
    let classify = classify
        .context("no classifier: releases from other indexers are shown only classified")?;
    let ids: Vec<u32> = prowlarr
        .indexers()
        .await?
        .into_iter()
        .filter(|i| i.enable && i.protocol == "torrent")
        .filter(|i| e.sources.primary_indexer.as_deref() != Some(i.name.as_str()))
        .map(|i| i.id)
        .collect();
    if ids.is_empty() {
        bail!("no enabled indexer besides the tracker's");
    }
    let cutoff = now - i64::from(WINDOW_DAYS) * 86400;
    let noise = &e.sources.noise;
    let mut topics = vec![];
    let mut hits = vec![];
    let mut classify_failures = 0u32;
    for (name, terms) in filters {
        let titles: Vec<&str> = tracker_titles
            .get(name)
            .map(|v| v.iter().map(String::as_str).collect())
            .unwrap_or_default();
        for term in terms.iter().filter(|t| t.elsewhere) {
            let results = match prowlarr
                .search_in(&term.text, &e.sources.categories, &ids)
                .await
            {
                Ok(r) => r,
                Err(err) => {
                    warn!("other indexers: search failed for {:?}: {err:#}", term.text);
                    continue;
                }
            };
            let found: Vec<Candidate> = results
                .iter()
                .filter_map(|r| candidate(r, cutoff))
                // The tracker applies the exclude list to its own searches; these never
                // pass through it, so apply it here, before anything is classified.
                .filter(|c| !excluded(excludes, &c.title))
                .collect();
            for c in collapse(found, noise) {
                if is_duplicate(&c.title, &titles, &term.text, noise) {
                    continue;
                }
                let id = ctx.db.upsert_external(&NewExternal {
                    indexer: &c.indexer,
                    guid: &c.guid,
                    link: &c.link,
                    info_url: c.info_url.as_deref(),
                    kind: Kind::Torrent,
                    files: None,
                    seen: now,
                })?;
                let known = ctx.db.topic(id)?;
                let production = match known.as_ref().and_then(|t| t.production.clone()) {
                    Some(p) => p,
                    None if classify_failures >= CLASSIFY_FAILURE_LIMIT => continue,
                    None => match classify.classify(&c.title, category(0)).await {
                        Ok(p) => {
                            classify_failures = 0;
                            p
                        }
                        // Held back until the next run: never shown unclassified.
                        Err(err) => {
                            classify_failures += 1;
                            warn!("classify {:?}: {err:#}", c.title);
                            continue;
                        }
                    },
                };
                if production.class == DOWN_RANKED {
                    continue;
                }
                let mut images = known.and_then(|t| t.images).filter(|v| !v.is_empty());
                if images.is_none()
                    && let Some(scenes) = e.scenes
                {
                    match scenes.search(&scene_query(&c.title, noise)).await {
                        Ok(Some(hit))
                            if accept(&hit, &term.text, &c.title) && !hit.images.is_empty() =>
                        {
                            ctx.db.set_scene(id, &hit.id)?;
                            if let Err(err) =
                                ensure_image(ctx.tracker, ctx.images, &hit.images[0]).await
                            {
                                warn!("image {}: {err:#}", hit.images[0]);
                            }
                            images = Some(hit.images);
                        }
                        Ok(_) => {}
                        Err(err) => warn!("scene search for {:?}: {err:#}", c.title),
                    }
                }
                topics.push(Topic {
                    row: Row {
                        id,
                        title: c.title.clone(),
                        forum: 0,
                        size: c.size,
                        seeders: c.seeders,
                        leechers: c.leechers,
                        completed: 0,
                        added: c.published,
                    },
                    images,
                    production: Some(production),
                });
                hits.push(CuratedHit {
                    topic_id: id,
                    filter: name.clone(),
                    reason: term_label(&term.text),
                });
            }
        }
    }
    Ok((topics, hits))
}
