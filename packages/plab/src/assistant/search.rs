//! The assistant's release search: the tracker, as the search box asks it, and the other
//! indexers through Prowlarr, as the curated job asks them. Every hit is stored as a search
//! hit, so a pick of it streams and downloads like any search result for `SEARCH_TTL`.
//! Design: docs/superpowers/specs/2026-11-06-plab-assistant-search-design.md

use std::future::Future;
use std::pin::Pin;

use serde_json::{Value, json};

use crate::backends::Backends;
use crate::db::{Kind, NewExternal};
use crate::external::{Candidate, collapse, is_duplicate};
use crate::filters::{HideRule, title_terms};
use crate::plab::Ctx;
use crate::sources::Sources;
use crate::tracker::parse::Row;

/// The search the assistant's `search_releases` tool runs. A trait object because the
/// assistant's turns run on detached tasks and cannot borrow the web task's `Ctx`.
pub trait ReleaseSearch: Send + Sync {
    fn search<'a>(&'a self, q: &'a str, now: i64) -> Pin<Box<dyn Future<Output = anyhow::Result<Value>> + Send + 'a>>;
}

fn hidden(hide: &HideRule, title: &str) -> bool {
    hide.hides(&title_terms(title))
}

fn hit(id: u64, title: &str, source: &str, size: u64, seeders: u32, leechers: u32, published: i64) -> Value {
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

/// `{"results": [...], "errors": [...]}`: tracker hits first, then the other indexers' by
/// seeders, at most `tools::LIMIT`. Either source failing is an `errors` entry; failing to
/// store a hit is the Err, since a hit that was not stored cannot be picked.
pub async fn search_releases<B: Backends>(
    ctx: &Ctx<'_, B>,
    sources: Option<&Sources>,
    hide: &HideRule,
    q: &str,
    now: i64,
) -> anyhow::Result<Value> {
    let mut results = vec![];
    let mut errors: Vec<String> = vec![];
    let mut tracker_titles: Vec<String> = vec![];
    match crate::plab::run_search(ctx, q, now).await {
        Ok(listed) => {
            for l in listed {
                let r = &l.topic.row;
                tracker_titles.push(r.title.clone());
                if !hidden(hide, &r.title) {
                    results.push(hit(r.id, &r.title, "tracker", r.size, r.seeders, r.leechers, r.added));
                }
            }
        }
        Err(e) => errors.push(format!("Tracker: {e:#}")),
    }
    match prowlarr_candidates(ctx, sources, hide, q).await {
        Ok(found) => {
            let noise = sources.map_or(&[][..], |s| &s.noise[..]);
            let titles: Vec<&str> = tracker_titles.iter().map(String::as_str).collect();
            let mut found: Vec<Candidate> =
                found.into_iter().filter(|c| !is_duplicate(&c.title, &titles, q, noise)).collect();
            found.sort_by_key(|c| std::cmp::Reverse(c.seeders));
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
                results.push(hit(id, &c.title, &c.indexer, c.size, c.seeders, c.leechers, c.published));
            }
        }
        Err(e) => errors.push(format!("Prowlarr: {e:#}")),
    }
    results.truncate(super::tools::LIMIT);
    let mut out = json!({"results": results});
    if !errors.is_empty() {
        out["errors"] = json!(errors);
    }
    Ok(out)
}
