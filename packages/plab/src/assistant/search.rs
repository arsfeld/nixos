//! The assistant's release search: the tracker, as the search box asks it, and the other
//! indexers through Prowlarr, as the curated job asks them. Every hit is stored as a search
//! hit, so a pick of it streams and downloads like any search result for `SEARCH_TTL`.
//! Design: docs/superpowers/specs/2026-11-06-plab-assistant-search-design.md

use std::future::Future;
use std::pin::Pin;
use std::time::Duration;

use serde_json::{Value, json};

use crate::backends::Backends;
use crate::db::{Kind, NewExternal};
use crate::external::{Candidate, collapse};
use crate::filters::{HideRule, title_terms};
use crate::plab::Ctx;
use crate::same::{SceneSig, duplicate, sig};
use crate::sources::Sources;
use crate::tracker::parse::Row;

/// The search the assistant's `search_releases` tool runs. A trait object because the
/// assistant's turns run on detached tasks and cannot borrow the web task's `Ctx`.
pub trait ReleaseSearch: Send + Sync {
    fn search<'a>(
        &'a self,
        q: &'a str,
        now: i64,
    ) -> Pin<Box<dyn Future<Output = anyhow::Result<Value>> + Send + 'a>>;
}

fn hidden(hide: &HideRule, title: &str) -> bool {
    hide.hides(&title_terms(title))
}

fn hit(
    id: u64,
    title: &str,
    source: &str,
    size: u64,
    seeders: u32,
    leechers: u32,
    published: i64,
) -> Value {
    json!({"ref": format!("t:{id}"), "title": title, "source": source, "size": size,
           "seeders": seeders, "leechers": leechers, "published": published})
}

/// The other indexers' results for `q`, collapsed, without the tracker's own and the hidden.
async fn prowlarr_candidates<B: Backends>(
    ctx: &Ctx<'_, B>,
    sources: Option<&Sources>,
    hide: &HideRule,
    q: &str,
) -> anyhow::Result<Vec<Candidate>> {
    let Some(prowlarr) = ctx.prowlarr else {
        return Ok(vec![]);
    };
    let sources = sources
        .filter(|s| !s.categories.is_empty())
        .ok_or_else(|| anyhow::anyhow!("plab-sources names no categories"))?;
    let ids: Vec<u32> = prowlarr
        .indexers()
        .await?
        .into_iter()
        .filter(|i| i.enable && i.protocol == "torrent")
        .filter(|i| sources.primary_indexer.as_deref() != Some(i.name.as_str()))
        .map(|i| i.id)
        .collect();
    anyhow::ensure!(!ids.is_empty(), "no enabled indexer besides the tracker's");
    let excludes = crate::filters::load_excludes(ctx.exclude_file, Some(ctx.state_dir));
    let found: Vec<Candidate> = prowlarr
        .search_in(q, &sources.categories, &ids)
        .await?
        .iter()
        // A search asks for anything, not only what is new: no age cutoff.
        .filter_map(|r| crate::curated::candidate(r, i64::MIN))
        .filter(|c| !excludes.excluded(&c.title) && !hidden(hide, &c.title))
        .collect();
    Ok(collapse(found, &sources.noise))
}

/// How long either half may take: a turn waits on its tools, and its conversation is busy
/// meanwhile, while Prowlarr's own client waits minutes.
const HALF_TIMEOUT: Duration = if cfg!(test) {
    Duration::from_secs(1)
} else {
    Duration::from_secs(45)
};
/// The tracker's share of `tools::LIMIT` when both halves have more: room for the others.
const TRACKER_SHARE: usize = 12;

async fn bounded_half<T>(f: impl Future<Output = anyhow::Result<T>>) -> anyhow::Result<T> {
    tokio::time::timeout(HALF_TIMEOUT, f)
        .await
        .map_err(|_| anyhow::anyhow!("timed out after {}s", HALF_TIMEOUT.as_secs()))?
}

/// `{"results": [...], "errors": [...]}`: tracker hits first, then the other indexers' by
/// seeders, at most `tools::LIMIT`, of which the tracker takes `TRACKER_SHARE` when the
/// others can fill the rest. Both halves run at once, each bounded by `HALF_TIMEOUT`;
/// either failing is an `errors` entry. Only returned hits are stored, and failing to
/// store one is the Err, since a hit that was not stored cannot be picked.
pub async fn search_releases<B: Backends>(
    ctx: &Ctx<'_, B>,
    sources: Option<&Sources>,
    hide: &HideRule,
    q: &str,
    now: i64,
) -> anyhow::Result<Value> {
    let limit = super::tools::LIMIT;
    let mut errors: Vec<String> = vec![];
    let (tracker, others) = tokio::join!(
        bounded_half(crate::plab::run_search(ctx, q, now)),
        bounded_half(prowlarr_candidates(ctx, sources, hide, q)),
    );
    let mut tracker_titles: Vec<String> = vec![];
    let mut tracker_hits = vec![];
    match tracker {
        Ok(listed) => {
            for l in listed {
                let r = &l.topic.row;
                tracker_titles.push(r.title.clone());
                if !hidden(hide, &r.title) {
                    tracker_hits.push(hit(
                        r.id, &r.title, "tracker", r.size, r.seeders, r.leechers, r.added,
                    ));
                }
            }
        }
        Err(e) => errors.push(format!("Tracker: {e:#}")),
    }
    let mut found: Vec<Candidate> = match others {
        Ok(found) => {
            let noise = sources.map_or(&[][..], |s| &s.noise[..]);
            // No stop words: `q` is often the very names a duplicate shares.
            let tracker: Vec<SceneSig> = tracker_titles
                .iter()
                .filter_map(|t| sig(t, noise, &[]))
                .collect();
            found
                .into_iter()
                .filter(|c| !duplicate(&c.title, &tracker, noise, &[]))
                .collect()
        }
        Err(e) => {
            errors.push(format!("Prowlarr: {e:#}"));
            vec![]
        }
    };
    found.sort_by_key(|c| std::cmp::Reverse(c.seeders));
    found.truncate(limit - tracker_hits.len().min(TRACKER_SHARE));
    tracker_hits.truncate(limit - found.len());
    let mut results = tracker_hits;
    for c in found {
        let id = ctx.db.upsert_external(&NewExternal {
            indexer: &c.indexer,
            guid: &c.guid,
            link: &c.link,
            info_url: c.info_url.as_deref(),
            kind: Kind::Torrent,
            files: None,
            seen: now,
        })?;
        let row = Row {
            id,
            title: c.title.clone(),
            forum: 0,
            size: c.size,
            seeders: c.seeders,
            leechers: c.leechers,
            completed: 0,
            added: c.published,
        };
        ctx.db.save_search(&[row], now)?;
        results.push(hit(
            id,
            &c.title,
            &c.indexer,
            c.size,
            c.seeders,
            c.leechers,
            c.published,
        ));
    }
    let mut out = json!({"results": results});
    if !errors.is_empty() {
        out["errors"] = json!(errors);
    }
    Ok(out)
}
