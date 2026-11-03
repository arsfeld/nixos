//! The identify watcher: inotify on the library, debounced into one pass per burst of
//! changes. Port of stash-identify `main.py`'s Debouncer/changed_dir/watch. The 24 h sweep
//! is a scheduled job (Task 16), not part of this loop.

use std::collections::{BTreeSet, HashSet};
use std::path::Path;
use std::time::{Duration, Instant};

use notify::event::{AccessKind, AccessMode, ModifyKind, RenameMode};
use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use tokio::sync::mpsc::{UnboundedReceiver, unbounded_channel};

use super::Clients;
use crate::codedb::CodeSearch;
use crate::db::Db;
use crate::llm::Llm;
use crate::stash::StashApi;
use crate::transmission::TorrentClient;

/// Quiet time without events before a pass runs.
pub const SETTLE: Duration = Duration::from_secs(120);

pub struct Debouncer {
    quiet: Duration,
    pending: BTreeSet<String>,
    last: Instant,
}

impl Debouncer {
    pub fn new(quiet: Duration) -> Self {
        Debouncer {
            quiet,
            pending: BTreeSet::new(),
            last: Instant::now(),
        }
    }

    pub fn add(&mut self, path: String, now: Instant) {
        self.pending.insert(path);
        self.last = now;
    }

    /// How many folders wait for the quiet period.
    pub fn pending(&self) -> usize {
        self.pending.len()
    }

    /// The pending paths (sorted), once `quiet` has passed since the last event.
    pub fn ready(&mut self, now: Instant) -> Option<Vec<String>> {
        if !self.pending.is_empty() && now.saturating_duration_since(self.last) >= self.quiet {
            Some(std::mem::take(&mut self.pending).into_iter().collect())
        } else {
            None
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Change {
    CloseWrite,
    MovedTo,
}

/// One change event -> the folder Stash should scan.
pub fn changed_dir(
    _change: Change,
    path: &Path,
    is_dir: bool,
    video_exts: &HashSet<String>,
) -> Option<String> {
    if is_dir {
        return Some(path.to_string_lossy().into_owned());
    }
    let ext = path.extension()?.to_string_lossy().to_lowercase();
    if video_exts.contains(&ext) {
        return Some(path.parent()?.to_string_lossy().into_owned());
    }
    None
}

/// `(change, path)` pairs a notify event stands for; everything but close-write and
/// moved-to is ignored, as `inotifywait -e close_write,moved_to` did.
fn changes(ev: &Event) -> Vec<(Change, &Path)> {
    match ev.kind {
        EventKind::Access(AccessKind::Close(AccessMode::Write)) => ev
            .paths
            .iter()
            .map(|p| (Change::CloseWrite, p.as_path()))
            .collect(),
        EventKind::Modify(ModifyKind::Name(RenameMode::To)) => ev
            .paths
            .iter()
            .map(|p| (Change::MovedTo, p.as_path()))
            .collect(),
        EventKind::Modify(ModifyKind::Name(RenameMode::Both)) => ev
            .paths
            .get(1)
            .map(|p| (Change::MovedTo, p.as_path()))
            .into_iter()
            .collect(),
        _ => Vec::new(),
    }
}

/// A recursive watcher on `root`, delivering the folders to scan (or the watcher's error).
/// Keep the returned watcher alive.
pub fn start_watcher(
    root: &Path,
    exts: HashSet<String>,
) -> notify::Result<(
    RecommendedWatcher,
    UnboundedReceiver<notify::Result<String>>,
)> {
    let (tx, rx) = unbounded_channel();
    let mut watcher = RecommendedWatcher::new(
        move |res: notify::Result<Event>| match res {
            Ok(ev) => {
                for (change, path) in changes(&ev) {
                    if let Some(d) = changed_dir(change, path, path.is_dir(), &exts) {
                        let _ = tx.send(Ok(d));
                    }
                }
            }
            Err(e) => {
                let _ = tx.send(Err(e));
            }
        },
        // inotifywait -r did not follow symlinks.
        notify::Config::default().with_follow_symlinks(false),
    )?;
    watcher.watch(root, RecursiveMode::Recursive)?;
    Ok((watcher, rx))
}

/// Watch the library and run a pass over the changed folders after `SETTLE` of quiet.
/// A watcher error or a closed channel is an `Err`, for the supervisor to restart.
/// Each pass holds `pass_lock`, shared with the daily sweep (see `locked_pass`).
pub async fn watch<S: StashApi, L: Llm, J: CodeSearch, T: TorrentClient>(
    c: &Clients<'_, S, L, J, T>,
    db: &Db,
    pass_lock: &tokio::sync::Mutex<()>,
) -> anyhow::Result<()> {
    let exts: HashSet<String> = c
        .stash
        .video_extensions()
        .await?
        .into_iter()
        .map(|e| e.to_lowercase())
        .collect();
    let (_watcher, mut rx) = start_watcher(Path::new(&c.paths.host), exts)?;
    let mut debouncer = Debouncer::new(SETTLE);
    let mut tick = tokio::time::interval(Duration::from_secs(10));
    let mon = crate::monitor::global();
    let mut shown = usize::MAX; // forces the first Watching below
    loop {
        tokio::select! {
            ev = rx.recv() => match ev {
                Some(Ok(dir)) => debouncer.add(dir, Instant::now()),
                Some(Err(e)) => return Err(anyhow::anyhow!("watcher failed: {e}")),
                None => anyhow::bail!("watcher channel closed"),
            },
            _ = tick.tick() => {}
        }
        if let Some(dirs) = debouncer.ready(Instant::now()) {
            tracing::info!("changed: {dirs:?}");
            let pass = super::locked_pass(c, db, pass_lock, Some(dirs));
            if let Err(e) = crate::jobs::record(db, "identify", pass).await {
                tracing::error!("pass failed: {e:#}");
            }
            shown = usize::MAX; // record left Watching { pending: 0 }
        }
        if debouncer.pending() != shown {
            shown = debouncer.pending();
            mon.set_state(
                "identify",
                crate::monitor::LiveState::Watching { pending: shown },
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn exts() -> HashSet<String> {
        ["mp4", "mkv"].iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn debouncer_fires_once_after_quiet() {
        let t0 = Instant::now();
        let at = |s: u64| t0 + Duration::from_secs(s);
        let mut d = Debouncer::new(Duration::from_secs(120));
        assert_eq!(d.ready(at(0)), None);
        d.add("/v/a".into(), at(0));
        d.add("/v/b".into(), at(100));
        assert_eq!(d.ready(at(219)), None); // 119 s since the last event
        assert_eq!(
            d.ready(at(220)),
            Some(vec!["/v/a".to_string(), "/v/b".into()])
        );
        assert_eq!(d.ready(at(1000)), None); // drained
    }

    #[test]
    fn pending_dirs_after_quiet_triggers_pass() {
        let t0 = Instant::now();
        let mut d = Debouncer::new(Duration::from_secs(120));
        d.add("/dir/a".into(), t0);
        d.add("/dir/b".into(), t0 + Duration::from_secs(50));
        // 120.1 s after the last event
        let now = t0 + Duration::from_millis(170_100);
        assert_eq!(
            d.ready(now),
            Some(vec!["/dir/a".to_string(), "/dir/b".into()])
        );
    }

    #[test]
    fn nothing_due_returns_none() {
        let t0 = Instant::now();
        let mut d = Debouncer::new(Duration::from_secs(120));
        assert_eq!(d.ready(t0 + Duration::from_secs(200)), None);
        // pending but not yet quiet
        d.add("/dir/a".into(), t0 + Duration::from_secs(190));
        assert_eq!(d.ready(t0 + Duration::from_secs(200)), None);
    }

    #[test]
    fn video_file_gives_its_folder() {
        // CLOSE_WRITE,CLOSE|/v/a b/x.MP4
        let got = changed_dir(
            Change::CloseWrite,
            Path::new("/v/a b/x.MP4"),
            false,
            &exts(),
        );
        assert_eq!(got.as_deref(), Some("/v/a b"));
    }

    #[test]
    fn moved_in_folder_gives_itself() {
        // MOVED_TO,ISDIR|/v/New Folder
        let got = changed_dir(Change::MovedTo, Path::new("/v/New Folder"), true, &exts());
        assert_eq!(got.as_deref(), Some("/v/New Folder"));
    }

    #[test]
    fn other_files_ignored() {
        // CLOSE_WRITE,CLOSE|/v/x.nfo
        assert_eq!(
            changed_dir(Change::CloseWrite, Path::new("/v/x.nfo"), false, &exts()),
            None
        );
        // "garbage" has no separator in Python; here, a path with no extension
        assert_eq!(
            changed_dir(Change::CloseWrite, Path::new("garbage"), false, &exts()),
            None
        );
    }

    #[tokio::test]
    async fn real_watcher_reports_the_folder_of_a_new_video() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap();
        std::fs::create_dir(root.join("a")).unwrap();
        let (_w, mut rx) = start_watcher(&root, exts()).unwrap();
        // let the recursive watch on a/ settle before writing
        tokio::time::sleep(Duration::from_millis(200)).await;
        std::fs::write(root.join("a/x.mp4"), b"x").unwrap();
        let got = tokio::time::timeout(Duration::from_secs(5), rx.recv())
            .await
            .expect("no event within 5 s")
            .expect("channel closed")
            .expect("watcher error");
        assert_eq!(got, root.join("a").to_string_lossy());
    }

    #[tokio::test]
    async fn watcher_does_not_follow_symlinks() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().canonicalize().unwrap().join("lib");
        let outside = tmp.path().canonicalize().unwrap().join("outside");
        std::fs::create_dir_all(root.join("a")).unwrap();
        std::fs::create_dir(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("link")).unwrap();
        let (_w, mut rx) = start_watcher(&root, exts()).unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;
        // through the real path, not the link: only a followed symlink would see it
        std::fs::write(outside.join("x.mp4"), b"x").unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
        // control: a real folder under the root does report
        std::fs::write(root.join("a/y.mp4"), b"y").unwrap();
        let got = tokio::time::timeout(Duration::from_secs(5), rx.recv())
            .await
            .expect("no event within 5 s")
            .expect("channel closed")
            .expect("watcher error");
        assert_eq!(got, root.join("a").to_string_lossy());
    }
}
