//! Which finished Vault and Games torrents to take out of Transmission (data kept).
//!
//! The tracker is a ratio tracker, so its torrents seed until they reach RATIO or sit IDLE_DAYS
//! without an upload, and at most MAX_SEEDING of them stay. Every other tracker earns
//! nothing by seeding, so those go as soon as they finish. Nothing outside the given dirs,
//! and nothing still downloading, is ever chosen. MAX_SEEDING is one cap across all of them.
//!
//! Design: docs/superpowers/specs/2026-10-30-vault-seed-prune-design.md

use crate::db::Db;
use crate::identify::Paths;
use crate::transmission::{Torrent, TorrentClient};

pub const RATIO: f64 = 2.0;
pub const IDLE_DAYS: f64 = 7.0;
pub const MAX_SEEDING: usize = 50;

fn is_lab(t: &Torrent) -> bool {
    t.trackers.iter().any(|tr| {
        let host = url::Url::parse(&tr.announce)
            .ok()
            .and_then(|u| u.host_str().map(str::to_string))
            .unwrap_or_default();
        let site = crate::site::get();
        site.announce_hosts
            .iter()
            .any(|h| host.contains(h.as_str()))
    })
}

fn idle_days(t: &Torrent, now: f64) -> f64 {
    // Counted from completion too, so a torrent that just finished gets the full window.
    (now - t.done_date.max(t.activity_date) as f64) / 86400.0
}

fn under(path: &str, dirs: &[String]) -> bool {
    let path = path.trim_end_matches('/');
    dirs.iter().any(|d| {
        path == d
            || path
                .strip_prefix(d.as_str())
                .is_some_and(|r| r.starts_with('/'))
    })
}

/// (id, name, reason) for each torrent to remove from under any of `dirs`.
pub fn decide(torrents: &[Torrent], now: f64, dirs: &[String]) -> Vec<(i64, String, String)> {
    let dirs: Vec<String> = dirs
        .iter()
        .map(|d| d.trim_end_matches('/').to_string())
        .collect();
    let mut out = Vec::new();
    let mut seeding: Vec<(f64, &Torrent)> = Vec::new();
    for t in torrents
        .iter()
        .filter(|t| t.percent_done >= 1.0 && under(&t.download_dir, &dirs))
    {
        let idle = idle_days(t, now);
        let reason = if !is_lab(t) {
            "complete, not the tracker's".to_string()
        } else if t.upload_ratio >= RATIO {
            format!("ratio {:.2}", t.upload_ratio)
        } else if idle >= IDLE_DAYS {
            format!("idle {:.1}d, ratio {:.2}", idle, t.upload_ratio)
        } else {
            seeding.push((idle, t));
            continue;
        };
        out.push((t.id, t.name.clone(), reason));
    }
    seeding.sort_by(|a, b| b.0.total_cmp(&a.0)); // longest idle first, stable
    let over = seeding.len().saturating_sub(MAX_SEEDING);
    for (idle, t) in &seeding[..over] {
        out.push((
            t.id,
            t.name.clone(),
            format!(
                "over {} seeding, idle {:.1}d, ratio {:.2}",
                MAX_SEEDING, idle, t.upload_ratio
            ),
        ));
    }
    out
}

/// Remove the torrents `decide` picks under `dirs`, in one call; return them. With `record`,
/// the files of each chosen download plab added are recorded first (provenance::sync); one
/// whose files cannot be recorded stays in Transmission until a later run, since removing
/// it would lose which scene came from which download.
pub async fn run_prune<C: TorrentClient>(
    c: &C,
    dirs: &[String],
    now: f64,
    dry_run: bool,
    record: Option<(&Db, &Paths)>,
) -> anyhow::Result<Vec<(i64, String, String)>> {
    let torrents = c.torrents().await?;
    let mut chosen = decide(&torrents, now, dirs);
    if let (Some((db, paths)), false) = (record, dry_run) {
        let hash_of: std::collections::HashMap<i64, &str> = torrents
            .iter()
            .map(|t| (t.id, t.hash_string.as_str()))
            .collect();
        let hashes: Vec<String> = chosen
            .iter()
            .filter_map(|(id, _, _)| hash_of.get(id).map(|h| h.to_string()))
            .collect();
        if let Err(e) = crate::provenance::sync(db, c, paths, Some(&hashes)).await {
            tracing::warn!("recording files before prune failed: {e:#}");
        }
        let unsynced = db.unsynced_among(&hashes)?;
        chosen.retain(|(id, name, _)| {
            let keep = hash_of.get(id).is_some_and(|h| unsynced.contains(*h));
            if keep {
                tracing::info!("kept {name}: its files are not recorded yet");
            }
            !keep
        });
    }
    for (_, name, reason) in &chosen {
        tracing::info!(
            "{} {name}: {reason}",
            if dry_run { "would remove" } else { "removed" }
        );
    }
    if !chosen.is_empty() && !dry_run {
        let ids: Vec<i64> = chosen.iter().map(|c| c.0).collect();
        c.remove(&ids).await?;
    }
    Ok(chosen)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transmission::{Added, Detail, TorrentSource, TrackerAnnounce};
    use std::sync::Mutex;

    const VAULT: &str = "/mnt/storage/media/Downloads/Vault";
    const NOW: i64 = 1_800_000_000;
    const DAY: i64 = 86400;

    fn lab() -> Vec<&'static str> {
        vec!["http://bt.tracker.example/ann?uk=x"]
    }
    fn public() -> Vec<&'static str> {
        vec!["udp://tracker.opentrackr.org:1337/announce"]
    }

    struct T {
        id: i64,
        trackers: Vec<&'static str>,
        done: f64,
        ratio: f64,
        done_ago: i64,
        active_ago: Option<i64>,
        dir: String,
    }
    fn t(id: i64) -> T {
        T {
            id,
            trackers: lab(),
            done: 1.0,
            ratio: 0.0,
            done_ago: 1,
            active_ago: None,
            dir: VAULT.into(),
        }
    }
    impl T {
        fn tr(mut self, v: Vec<&'static str>) -> T {
            self.trackers = v;
            self
        }
        fn done(mut self, v: f64) -> T {
            self.done = v;
            self
        }
        fn ratio(mut self, v: f64) -> T {
            self.ratio = v;
            self
        }
        fn done_ago(mut self, v: i64) -> T {
            self.done_ago = v;
            self
        }
        fn active_ago(mut self, v: i64) -> T {
            self.active_ago = Some(v);
            self
        }
        fn dir(mut self, v: &str) -> T {
            self.dir = v.into();
            self
        }
        fn build(self) -> Torrent {
            Torrent {
                id: self.id,
                name: format!("t{}", self.id),
                hash_string: String::new(),
                download_dir: self.dir,
                percent_done: self.done,
                upload_ratio: self.ratio,
                done_date: if self.done == 1.0 {
                    NOW - self.done_ago * DAY
                } else {
                    0
                },
                activity_date: NOW - self.active_ago.unwrap_or(self.done_ago) * DAY,
                trackers: self
                    .trackers
                    .into_iter()
                    .map(|a| TrackerAnnounce {
                        announce: a.to_string(),
                    })
                    .collect(),
            }
        }
    }

    fn ids(ts: Vec<T>) -> Vec<i64> {
        let ts: Vec<Torrent> = ts.into_iter().map(T::build).collect();
        decide(&ts, NOW as f64, &[VAULT.to_string()])
            .into_iter()
            .map(|c| c.0)
            .collect()
    }

    #[test]
    fn public_removed_once_complete() {
        assert_eq!(
            ids(vec![t(1).tr(public()), t(2).tr(public()).done(0.5)]),
            [1]
        );
    }

    #[test]
    fn lab_ratio() {
        assert_eq!(
            ids(vec![
                t(1).ratio(2.0),
                t(2).ratio(1.9).done_ago(10).active_ago(1)
            ]),
            [1]
        );
    }

    #[test]
    fn lab_idle_counts_from_completion() {
        // done 8 days ago, last upload 7 days ago: idle. Done 2 days ago, nothing since: not yet.
        assert_eq!(
            ids(vec![
                t(1).done_ago(8).active_ago(7),
                t(2).done_ago(2).active_ago(20)
            ]),
            [1]
        );
    }

    #[test]
    fn lab_still_downloading_kept() {
        assert!(ids(vec![t(1).done(0.4).ratio(5.0).active_ago(30)]).is_empty());
    }

    #[test]
    fn outside_vault_never_removed() {
        assert!(
            ids(vec![
                t(1).tr(public()).dir("/mnt/storage/media/Downloads"),
                t(2).tr(public()).dir(&format!("{VAULT}2")),
                t(3).ratio(9.0).dir("/mnt/storage/media/Downloads/radarr"),
            ])
            .is_empty()
        );
    }

    #[test]
    fn studio_subdirectory_is_vault() {
        assert_eq!(
            ids(vec![t(1).tr(public()).dir(&format!("{VAULT}/Some Studio"))]),
            [1]
        );
    }

    #[test]
    fn cap_trims_longest_idle() {
        let mut seeding: Vec<T> = (0..50).map(|i| t(i).done_ago(1).active_ago(0)).collect();
        seeding.push(t(100).done_ago(6));
        seeding.push(t(101).done_ago(5));
        let mut got = ids(seeding);
        got.sort();
        assert_eq!(got, [100, 101]);
    }

    #[test]
    fn lab_on_any_tracker() {
        let mixed = vec![public()[0], "http://tracker.example/ann"];
        assert!(ids(vec![t(1).tr(mixed).done_ago(1)]).is_empty());
    }

    #[test]
    fn reasons() {
        let ts: Vec<Torrent> = vec![
            t(1).tr(public()).build(),
            t(2).ratio(3.0).build(),
            t(3).done_ago(9).build(),
        ];
        let r: std::collections::HashMap<i64, String> =
            decide(&ts, NOW as f64, &[VAULT.to_string()])
                .into_iter()
                .map(|(i, _, r)| (i, r))
                .collect();
        assert_eq!(r[&1], "complete, not the tracker's");
        assert_eq!(r[&2], "ratio 3.00");
        assert_eq!(r[&3], "idle 9.0d, ratio 0.00");
    }

    #[test]
    fn cap_reason_text() {
        let mut seeding: Vec<T> = (0..50).map(|i| t(i).done_ago(1).active_ago(0)).collect();
        seeding.push(t(100).done_ago(6));
        let ts: Vec<Torrent> = seeding.into_iter().map(T::build).collect();
        let got = decide(&ts, NOW as f64, &[VAULT.to_string()]);
        assert_eq!(got[0].2, "over 50 seeding, idle 6.0d, ratio 0.00");
    }

    #[test]
    fn every_dir_is_pruned() {
        let games = "/mnt/storage/media/Downloads/Games";
        let ts: Vec<Torrent> = vec![
            t(1).tr(public()).build(),
            t(2).tr(public()).dir(games).build(),
            t(3).tr(public()).dir("/elsewhere").build(),
        ];
        let got = decide(&ts, NOW as f64, &[VAULT.to_string(), games.to_string()]);
        assert_eq!(got.iter().map(|c| c.0).collect::<Vec<_>>(), [1, 2]);
    }

    // run_prune (plab test_main RunPrune)
    struct Fake {
        torrents: Vec<Torrent>,
        removed: Mutex<Vec<Vec<i64>>>,
        details: Vec<Detail>,
        details_fail: bool,
    }
    impl TorrentClient for Fake {
        async fn add(&self, _: &TorrentSource, _: &str) -> anyhow::Result<Added> {
            unimplemented!()
        }
        async fn torrents(&self) -> anyhow::Result<Vec<Torrent>> {
            Ok(self.torrents.clone())
        }
        async fn remove(&self, ids: &[i64]) -> anyhow::Result<()> {
            self.removed.lock().unwrap().push(ids.to_vec());
            Ok(())
        }
        async fn details(&self, hashes: &[String]) -> anyhow::Result<Vec<Detail>> {
            if self.details_fail {
                anyhow::bail!("down");
            }
            Ok(self
                .details
                .iter()
                .filter(|d| hashes.contains(&d.hash_string))
                .cloned()
                .collect())
        }
    }
    fn fake() -> Fake {
        let mk = |id: i64, name: &str, ratio: f64, a: &str| Torrent {
            id,
            name: name.into(),
            hash_string: format!("h{id}"),
            download_dir: "/v/Vault".into(),
            percent_done: 1.0,
            upload_ratio: ratio,
            done_date: 100,
            activity_date: 100,
            trackers: vec![TrackerAnnounce { announce: a.into() }],
        };
        Fake {
            torrents: vec![
                mk(1, "public", 0.0, "udp://open.example:1337"),
                mk(2, "lab", 0.1, "http://bt.tracker.example/ann"),
            ],
            removed: Mutex::new(vec![]),
            details: vec![],
            details_fail: false,
        }
    }

    #[tokio::test]
    async fn run_prune_removes_chosen_in_one_call() {
        let f = fake();
        let chosen = run_prune(&f, &["/v/Vault".to_string()], 200.0, false, None)
            .await
            .unwrap();
        assert_eq!(chosen.iter().map(|c| c.0).collect::<Vec<_>>(), [1]);
        assert_eq!(*f.removed.lock().unwrap(), vec![vec![1]]);
    }

    #[tokio::test]
    async fn run_prune_dry_run_removes_nothing() {
        let f = fake();
        run_prune(&f, &["/v/Vault".to_string()], 200.0, true, None)
            .await
            .unwrap();
        assert!(f.removed.lock().unwrap().is_empty());
    }

    fn recorded(db: &Db, id: i64) -> i64 {
        db.mark_added(crate::db::NewDownload {
            source: "grab",
            topic_id: None,
            release_title: "x",
            section: crate::db::Section::Video,
            download_dir: Some(VAULT),
            torrent_hash: Some(&format!("h{id}")),
            now: 0,
        })
        .unwrap()
    }

    #[tokio::test]
    async fn run_prune_records_files_before_removing() {
        let (_t, paths, dl) = crate::provenance::tests::library();
        let db = Db::open_in_memory().unwrap();
        let mut f = fake();
        let id = 1; // "public": finished, not the tracker's, so decide removes it
        recorded(&db, id);
        f.details = vec![crate::provenance::tests::detail(
            &format!("h{id}"),
            &dl,
            1.0,
            &["R/a.mp4"],
        )];
        run_prune(&f, &["/v/Vault".into()], 200.0, false, Some((&db, &paths)))
            .await
            .unwrap();
        assert!(db.link_scene("R/a.mp4", None).unwrap().is_some());
        assert_eq!(*f.removed.lock().unwrap(), vec![vec![id]]);
    }

    #[tokio::test]
    async fn run_prune_keeps_a_torrent_whose_files_could_not_be_recorded() {
        let (_t, paths, _dl) = crate::provenance::tests::library();
        let db = Db::open_in_memory().unwrap();
        let mut f = fake();
        recorded(&db, 1);
        f.details_fail = true;
        let got = run_prune(&f, &["/v/Vault".into()], 200.0, false, Some((&db, &paths)))
            .await
            .unwrap();
        assert!(got.is_empty());
        assert!(f.removed.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn run_prune_removes_a_finished_games_torrent_plab_added() {
        // Provenance covers Vault videos only: a games download is never held back.
        let (_t, paths, _dl) = crate::provenance::tests::library();
        let db = Db::open_in_memory().unwrap();
        let mut f = fake();
        db.mark_added(crate::db::NewDownload {
            source: "plab",
            topic_id: Some(7),
            release_title: "A Game",
            section: crate::db::Section::Games,
            download_dir: Some("/v/Vault"),
            torrent_hash: Some("h1"),
            now: 0,
        })
        .unwrap();
        f.details_fail = true; // irrelevant: a games row never needs syncing
        let got = run_prune(&f, &["/v/Vault".into()], 200.0, false, Some((&db, &paths)))
            .await
            .unwrap();
        assert_eq!(got.iter().map(|c| c.0).collect::<Vec<_>>(), [1]);
        assert_eq!(*f.removed.lock().unwrap(), vec![vec![1]]);
    }

    #[tokio::test]
    async fn run_prune_removes_torrents_plab_never_added() {
        let (_t, paths, _dl) = crate::provenance::tests::library();
        let db = Db::open_in_memory().unwrap();
        let mut f = fake();
        f.details_fail = true; // irrelevant: no download row needs syncing
        let got = run_prune(&f, &["/v/Vault".into()], 200.0, false, Some((&db, &paths)))
            .await
            .unwrap();
        assert_eq!(got.len(), 1);
    }
}
