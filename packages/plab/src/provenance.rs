//! Which download a Stash scene came from, and what became of each download.
//!
//! `sync` records a finished torrent's files (library-relative) from Transmission by hash.
//! It must run before prune takes a torrent out of Transmission, since the file list goes
//! with it: grabs are pruned as soon as they finish. Only video downloads are covered:
//! games land outside the Vault library, so they are never synced and get no status.
//!
//! Design: docs/superpowers/specs/2026-11-02-plab-provenance-identify-design.md

use std::collections::HashMap;
use std::path::PathBuf;

use crate::db::{Db, DownloadRow};
use crate::identify::Paths;
use crate::labels::labels;
use crate::stash::Scene;
use crate::transmission::{Detail, TorrentClient};

fn canonical(p: &str) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| PathBuf::from(p))
}

/// A torrent's complete files as library-relative paths, the form `Paths::rel_path` gives a
/// Stash scene's. The download dir is canonicalized, since Downloads/Vault is a symlink to
/// the library. Incomplete files (by `bytesCompleted`: the RPC's names never carry `.part`)
/// and files outside the library are left out.
pub fn library_paths(paths: &Paths, d: &Detail) -> Vec<String> {
    let dir = canonical(&d.download_dir);
    let root = canonical(&paths.host);
    let mut out = Vec::new();
    for f in &d.files {
        if f.length <= 0 || f.bytes_completed != f.length {
            continue;
        }
        let full = dir.join(&f.name);
        match full.strip_prefix(&root) {
            Ok(rel) => out.push(rel.to_string_lossy().into_owned()),
            Err(_) => tracing::warn!(
                "{} is outside the library {}",
                full.display(),
                root.display()
            ),
        }
    }
    out
}

/// Record the complete files of every download not yet fully recorded (only those with one
/// of `only`'s hashes, when given). A multi-file torrent's files are recorded as each one
/// completes, since identify runs on a file as soon as it appears; the download is synced
/// once the whole torrent is done. Returns how many were synced. An unfinished torrent, or
/// one Transmission no longer has, stays pending.
pub async fn sync<C: TorrentClient>(
    db: &Db,
    torrents: &C,
    paths: &Paths,
    only: Option<&[String]>,
) -> anyhow::Result<usize> {
    let pending: HashMap<String, i64> = db
        .unsynced_downloads()?
        .into_iter()
        .filter(|(_, h)| only.is_none_or(|o| o.contains(h)))
        .map(|(id, h)| (h, id))
        .collect();
    if pending.is_empty() {
        return Ok(0);
    }
    let mut hashes: Vec<String> = pending.keys().cloned().collect();
    hashes.sort();
    let mut n = 0;
    for d in torrents.details(&hashes).await? {
        let Some(id) = pending.get(&d.hash_string) else {
            continue;
        };
        let finished = d.percent_done >= 1.0;
        db.record_files(*id, &library_paths(paths, &d), finished)?;
        n += usize::from(finished);
    }
    Ok(n)
}

/// What a scene's download says about it.
#[derive(Debug, Clone, PartialEq)]
pub struct Provenance {
    /// The release title (tracker topic or Prowlarr result).
    pub title: String,
    /// A grab's rule studio, or the studio label of a plab add's title.
    pub studio: Option<String>,
    /// The studio is certain (a grab rule matched it): it overrides the parse and filters
    /// stash-box candidates.
    pub forced: bool,
    /// The copied tracker image (plab adds).
    pub cover: Option<PathBuf>,
}

impl From<crate::db::Link> for Provenance {
    fn from(l: crate::db::Link) -> Provenance {
        let grab = l.source == "grab";
        let studio = if grab {
            l.grab_studio
        } else {
            labels(&l.release_title, 0).studio // the forum only decides the category
        };
        Provenance {
            forced: grab && studio.is_some(),
            studio,
            title: l.release_title,
            cover: l.cover.map(PathBuf::from),
        }
    }
}

/// The scene's download, if its file came from one. With `write`, the file is linked to the
/// scene for the page's status. A database error is logged and counts as no download, so
/// the scene is identified as before.
pub fn link(db: &Db, paths: &Paths, scene: &Scene, write: bool) -> Option<Provenance> {
    let path = scene.first_path()?;
    let id = &scene.id;
    match db.link_scene(paths.rel_path(path), write.then_some(id.as_str())) {
        Ok(l) => l.map(Provenance::from),
        Err(e) => {
            tracing::warn!("[{id}] download lookup failed: {e:#}");
            None
        }
    }
}

/// "Title · Studio", either part optional; None when both are missing.
pub fn outcome_label(title: Option<&str>, studio: Option<&str>) -> Option<String> {
    let parts: Vec<&str> = [title, studio]
        .into_iter()
        .flatten()
        .filter(|s| !s.is_empty())
        .collect();
    (!parts.is_empty()).then(|| parts.join(" · "))
}

/// A torrent under 100% with no activity this long has stalled.
pub const STALLED_DAYS: i64 = 3;
/// A finished download with no Stash scene this long after it was added is lost.
pub const LOST_DAYS: i64 = 2;
/// Transmission's `error` for a local (disk) error, as opposed to a tracker's.
const LOCAL_ERROR: i64 = 3;

#[derive(Debug, Clone, PartialEq)]
pub enum Failure {
    /// Transmission's error string, or "stalled".
    Transmission(String),
    /// identify gave up or found nothing.
    Identify,
    /// The torrent is gone and no scene came of it.
    Lost,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Status {
    Queued,
    Downloading(u8),
    /// In Transmission or finished, no scene yet.
    Added,
    InStash {
        scenes: Vec<String>,
        folder: Option<String>,
    },
    Identified {
        label: String,
        more: usize,
        guess: bool,
        scenes: Vec<String>,
        folder: Option<String>,
    },
    Failed(Failure),
}

/// The last component of the deepest directory every path is under, or None when they
/// share none (or there are no paths). "Studio A/Rel/a.mp4" and "Studio A/Rel/b.mp4"
/// share "Rel".
pub fn shared_folder(paths: &[&str]) -> Option<String> {
    let dirs: Vec<Vec<&str>> = paths
        .iter()
        .map(|p| {
            let mut parts: Vec<&str> = p.split('/').collect();
            parts.pop(); // the file name
            parts
        })
        .collect();
    let first = dirs.first()?;
    let depth = (0..first.len())
        .take_while(|&i| dirs.iter().all(|d| d.get(i) == first.get(i)))
        .count();
    depth
        .checked_sub(1)
        .map(|i| first[i])
        .filter(|f| !f.is_empty())
        .map(str::to_string)
}

/// Where a download's scenes are in Stash's web UI, at `base`: the scene, or for several,
/// Stash's scene search by their shared folder name (which Stash matches against paths),
/// as a quoted phrase so its search grammar (ANDed words, `-word`, `OR`) takes the name
/// literally. A folder containing `"` cannot be quoted, so it gets no link.
/// Only statuses with scenes link.
pub fn stash_link(base: &str, status: &Status) -> Option<String> {
    let base = base.trim_end_matches('/');
    if base.is_empty() {
        return None;
    }
    let (Status::InStash { scenes, folder } | Status::Identified { scenes, folder, .. }) = status
    else {
        return None;
    };
    match (scenes.as_slice(), folder) {
        ([one], _) => Some(format!("{base}/scenes/{one}")),
        ([_, _, ..], Some(folder)) if !folder.contains('"') => {
            let phrase = format!("\"{folder}\"");
            let q: String = form_urlencoded::byte_serialize(phrase.as_bytes()).collect();
            Some(format!("{base}/scenes?q={q}"))
        }
        _ => None,
    }
}

/// A download's status. `live` is Transmission's reply for the recent downloads' hashes, or
/// None when it could not be asked; without it nothing is inferred from a torrent's absence.
/// Rules in order; the first that matches wins (spec, "Status").
pub fn status(d: &DownloadRow, live: Option<&HashMap<String, Detail>>, now: i64) -> Status {
    if d.state == "queued" {
        return Status::Queued;
    }
    let torrent = d.hash.as_ref().and_then(|h| live.and_then(|l| l.get(h)));
    if let Some(t) = torrent {
        // Transmission's error is 1 for a tracker warning, 2 a tracker error, 3 a local
        // error. A tracker's complaint stops nothing once the data is all here.
        if t.error == LOCAL_ERROR || (t.error != 0 && t.percent_done < 1.0) {
            let why = if t.error_string.is_empty() {
                format!("error {}", t.error)
            } else {
                t.error_string.clone()
            };
            return Status::Failed(Failure::Transmission(why));
        }
        if t.percent_done < 1.0 {
            let last = t.activity_date.max(d.added_at.unwrap_or(0));
            if now - last > STALLED_DAYS * 86400 {
                return Status::Failed(Failure::Transmission("stalled".into()));
            }
            return Status::Downloading((t.percent_done * 100.0).floor() as u8);
        }
    }
    let linked: Vec<_> = d.files.iter().filter(|f| f.scene_id.is_some()).collect();
    fn outcome<'a>(f: &&'a crate::db::FileRow) -> Option<&'a str> {
        f.outcome.as_deref()
    }
    if linked
        .iter()
        .any(|f| matches!(outcome(f), Some("gave-up" | "none")))
    {
        return Status::Failed(Failure::Identify);
    }
    let mut scenes: Vec<String> = Vec::new();
    for id in linked.iter().filter_map(|f| f.scene_id.clone()) {
        if !scenes.contains(&id) {
            scenes.push(id);
        }
    }
    let folder = shared_folder(&linked.iter().map(|f| f.path.as_str()).collect::<Vec<_>>());
    if !linked.is_empty()
        && linked
            .iter()
            .all(|f| matches!(outcome(f), Some("stash" | "scrape" | "llm")))
    {
        let labels: Vec<&str> = linked.iter().filter_map(|f| f.label.as_deref()).collect();
        return Status::Identified {
            label: labels
                .first()
                .map_or_else(|| d.release_title.clone(), |l| l.to_string()),
            more: linked.len() - 1,
            guess: linked.iter().any(|f| outcome(f) == Some("llm")),
            scenes,
            folder,
        };
    }
    if !linked.is_empty() {
        return Status::InStash { scenes, folder };
    }
    let gone = d.hash.is_some() && live.is_some() && torrent.is_none();
    let old = d.added_at.is_some_and(|a| now - a > LOST_DAYS * 86400);
    if (!d.files_synced && gone) || (d.files_synced && old) {
        return Status::Failed(Failure::Lost);
    }
    Status::Added
}

#[cfg(test)]
#[path = "provenance_tests.rs"]
pub(crate) mod tests;
