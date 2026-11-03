use super::*;
use crate::db::{Db, NewDownload, Section};
use crate::transmission::{Added, Detail, Torrent, TorrentClient, TorrentFile, TorrentSource};
use std::sync::Mutex;

pub(crate) struct FakeTorrents {
    pub details: Vec<Detail>,
    pub fail: bool,
    pub asked: Mutex<Vec<Vec<String>>>,
}

impl FakeTorrents {
    pub fn new(details: Vec<Detail>) -> FakeTorrents {
        FakeTorrents {
            details,
            fail: false,
            asked: Mutex::new(vec![]),
        }
    }
}

impl TorrentClient for FakeTorrents {
    async fn add(&self, _: &TorrentSource, _: &str) -> anyhow::Result<Added> {
        unimplemented!()
    }
    async fn torrents(&self) -> anyhow::Result<Vec<Torrent>> {
        unimplemented!()
    }
    async fn remove(&self, _: &[i64]) -> anyhow::Result<()> {
        unimplemented!()
    }
    async fn details(&self, hashes: &[String]) -> anyhow::Result<Vec<Detail>> {
        self.asked.lock().unwrap().push(hashes.to_vec());
        if self.fail {
            anyhow::bail!("transmission down");
        }
        Ok(self
            .details
            .iter()
            .filter(|d| hashes.contains(&d.hash_string))
            .cloned()
            .collect())
    }
}

/// A torrent whose files are all complete when `done` is 1, and none otherwise.
pub(crate) fn detail(hash: &str, dir: &str, done: f64, files: &[&str]) -> Detail {
    let complete: Vec<(&str, bool)> = files.iter().map(|f| (*f, done >= 1.0)).collect();
    detail_files(hash, dir, done, &complete)
}

/// A torrent with each file complete or not.
pub(crate) fn detail_files(hash: &str, dir: &str, done: f64, files: &[(&str, bool)]) -> Detail {
    Detail {
        hash_string: hash.into(),
        download_dir: dir.into(),
        percent_done: done,
        error: 0,
        error_string: String::new(),
        activity_date: 0,
        files: files
            .iter()
            .map(|(f, complete)| TorrentFile {
                name: f.to_string(),
                length: 100,
                bytes_completed: if *complete { 100 } else { 40 },
            })
            .collect(),
    }
}

/// A library at <tmp>/Vault and a download dir <tmp>/Downloads/Vault symlinked to it, as
/// on galactica.
pub(crate) fn library() -> (tempfile::TempDir, Paths, String) {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    std::fs::create_dir_all(root.join("Vault/Studio A")).unwrap();
    std::fs::create_dir_all(root.join("Downloads")).unwrap();
    std::os::unix::fs::symlink(root.join("Vault"), root.join("Downloads/Vault")).unwrap();
    let paths = Paths {
        host: root.join("Vault").to_string_lossy().into_owned(),
        container: "/media/Vault".into(),
    };
    let dl = root.join("Downloads/Vault").to_string_lossy().into_owned();
    (tmp, paths, dl)
}

pub(crate) fn add(db: &Db, source: &str, topic: Option<u64>, title: &str, hash: &str) -> i64 {
    db.mark_added(NewDownload {
        source,
        topic_id: topic,
        release_title: title,
        section: Section::Video,
        download_dir: Some("/d"),
        torrent_hash: Some(hash),
        now: 1000,
    })
    .unwrap()
}

mod sync_tests {
    use super::*;

    #[test]
    fn paths_resolve_through_the_symlinked_download_dir() {
        let (_t, paths, dl) = library();
        let d = detail_files(
            "h",
            &format!("{dl}/Studio A"),
            0.7,
            &[("Rel/a.mp4", true), ("Rel/b.mp4", false)],
        );
        assert_eq!(
            library_paths(&paths, &d),
            vec!["Studio A/Rel/a.mp4".to_string()]
        );
    }

    #[test]
    fn an_empty_file_is_never_complete() {
        let (_t, paths, dl) = library();
        let mut d = detail("h", &format!("{dl}/Studio A"), 1.0, &["Rel/empty"]);
        d.files[0].length = 0;
        d.files[0].bytes_completed = 0;
        assert!(library_paths(&paths, &d).is_empty());
    }

    #[test]
    fn paths_outside_the_library_are_skipped() {
        let (_t, paths, _dl) = library();
        let d = detail("h", "/elsewhere", 1.0, &["a.mp4"]);
        assert!(library_paths(&paths, &d).is_empty());
    }

    #[tokio::test]
    async fn sync_records_finished_torrents_only() {
        let (_t, paths, dl) = library();
        let db = Db::open_in_memory().unwrap();
        let done = add(&db, "grab", None, "Done", "h1");
        add(&db, "grab", None, "Busy", "h2");
        let t = FakeTorrents::new(vec![
            detail("h1", &format!("{dl}/Studio A"), 1.0, &["Done/a.mp4"]),
            detail("h2", &format!("{dl}/Studio A"), 0.5, &["Busy/a.mp4"]),
        ]);
        assert_eq!(sync(&db, &t, &paths, None).await.unwrap(), 1);
        assert_eq!(
            db.unsynced_downloads().unwrap(),
            vec![(done + 1, "h2".to_string())]
        );
        let l = db.link_scene("Studio A/Done/a.mp4", None).unwrap().unwrap();
        assert_eq!(l.download_id, done);
    }

    #[tokio::test]
    async fn sync_records_a_partial_torrents_finished_files_and_keeps_it_pending() {
        // With rename-partial-files each file loses .part as it completes, and the watcher
        // runs a pass then: that file must be recorded before the whole torrent is done.
        let (_t, paths, dl) = library();
        let db = Db::open_in_memory().unwrap();
        let id = add(&db, "grab", None, "Multi", "h1");
        let dir = format!("{dl}/Studio A");
        let t = FakeTorrents::new(vec![detail_files(
            "h1",
            &dir,
            0.5,
            &[("M/a.mp4", true), ("M/b.mp4", false)],
        )]);
        assert_eq!(sync(&db, &t, &paths, None).await.unwrap(), 0);
        assert_eq!(
            db.unsynced_downloads().unwrap(),
            vec![(id, "h1".to_string())]
        );
        assert_eq!(
            db.link_scene("Studio A/M/a.mp4", None)
                .unwrap()
                .unwrap()
                .download_id,
            id
        );
        assert!(db.link_scene("Studio A/M/b.mp4", None).unwrap().is_none());

        let t = FakeTorrents::new(vec![detail("h1", &dir, 1.0, &["M/a.mp4", "M/b.mp4"])]);
        assert_eq!(sync(&db, &t, &paths, None).await.unwrap(), 1);
        assert!(db.unsynced_downloads().unwrap().is_empty());
        assert!(db.link_scene("Studio A/M/b.mp4", None).unwrap().is_some());
    }

    #[tokio::test]
    async fn sync_only_asks_for_the_given_hashes_and_nothing_when_none_pending() {
        let (_t, paths, _dl) = library();
        let db = Db::open_in_memory().unwrap();
        add(&db, "grab", None, "A", "h1");
        add(&db, "grab", None, "B", "h2");
        let t = FakeTorrents::new(vec![]);
        sync(&db, &t, &paths, Some(&["h2".to_string()]))
            .await
            .unwrap();
        sync(&db, &t, &paths, Some(&["zz".to_string()]))
            .await
            .unwrap();
        assert_eq!(*t.asked.lock().unwrap(), vec![vec!["h2".to_string()]]);
    }

    #[tokio::test]
    async fn sync_failure_is_an_error() {
        let (_t, paths, _dl) = library();
        let db = Db::open_in_memory().unwrap();
        add(&db, "grab", None, "A", "h1");
        let mut t = FakeTorrents::new(vec![]);
        t.fail = true;
        assert!(sync(&db, &t, &paths, None).await.is_err());
        assert_eq!(db.unsynced_downloads().unwrap().len(), 1);
    }
}

mod status_tests {
    use super::*;
    use crate::db::{DownloadRow, FileRow};
    use std::collections::HashMap;

    const NOW: i64 = 10 * 86400;

    fn row() -> DownloadRow {
        DownloadRow {
            id: 1,
            source: "grab".into(),
            topic_id: None,
            release_title: "R".into(),
            studio: Some("Studio A".into()),
            state: "added".into(),
            hash: Some("h".into()),
            added_at: Some(NOW - 3600),
            files_synced: false,
            files: vec![],
        }
    }

    fn file(scene: Option<&str>, outcome: Option<&str>, label: Option<&str>) -> FileRow {
        FileRow {
            path: format!("p{}", scene.unwrap_or("-")),
            scene_id: scene.map(Into::into),
            outcome: outcome.map(Into::into),
            label: label.map(Into::into),
        }
    }

    fn live(d: Detail) -> HashMap<String, Detail> {
        HashMap::from([(d.hash_string.clone(), d)])
    }

    fn synced(files: Vec<FileRow>) -> DownloadRow {
        DownloadRow {
            files_synced: true,
            files,
            ..row()
        }
    }

    #[test]
    fn queued() {
        let d = DownloadRow {
            state: "queued".into(),
            hash: None,
            added_at: None,
            ..row()
        };
        assert_eq!(status(&d, None, NOW), Status::Queued);
    }

    #[test]
    fn transmission_error_and_stall() {
        let mut t = detail("h", "/d", 0.4, &[]);
        t.error = 3;
        t.error_string = "No data found".into();
        assert_eq!(
            status(&row(), Some(&live(t)), NOW),
            Status::Failed(Failure::Transmission("No data found".into()))
        );
        let mut t = detail("h", "/d", 0.4, &[]);
        t.activity_date = NOW - 4 * 86400;
        let old = DownloadRow {
            added_at: Some(NOW - 5 * 86400),
            ..row()
        };
        assert!(matches!(
            status(&old, Some(&live(t)), NOW),
            Status::Failed(Failure::Transmission(_))
        ));
    }

    #[test]
    fn a_tracker_error_on_a_finished_torrent_is_not_a_failure() {
        // Transmission's error: 1 tracker warning, 2 tracker error, 3 local error.
        let d = synced(vec![file(Some("1"), Some("scrape"), Some("A · S"))]);
        let mut t = detail("h", "/d", 1.0, &[]);
        t.error = 2;
        t.error_string = "Tracker gave HTTP response code 404".into();
        assert_eq!(
            status(&d, Some(&live(t.clone())), NOW),
            Status::Identified {
                label: "A · S".into(),
                more: 0,
                guess: false,
                scenes: vec!["1".into()],
                folder: None
            }
        );
        // a local error counts at any time
        t.error = 3;
        t.error_string = "No space left on device".into();
        assert_eq!(
            status(&d, Some(&live(t)), NOW),
            Status::Failed(Failure::Transmission("No space left on device".into()))
        );
        // while unfinished, a tracker error is still the download's failure
        let mut t = detail("h", "/d", 0.4, &[]);
        t.error = 2;
        t.activity_date = NOW;
        assert_eq!(
            status(&row(), Some(&live(t)), NOW),
            Status::Failed(Failure::Transmission("error 2".into()))
        );
    }

    #[test]
    fn downloading() {
        let mut t = detail("h", "/d", 0.42, &[]);
        t.activity_date = NOW;
        assert_eq!(status(&row(), Some(&live(t)), NOW), Status::Downloading(42));
    }

    #[test]
    fn identified_with_more_and_guess() {
        let d = synced(vec![
            file(Some("1"), Some("scrape"), Some("A · S")),
            file(Some("2"), Some("llm"), Some("B · S")),
            file(None, None, None), // the .nfo: never a scene
        ]);
        assert_eq!(
            status(&d, None, NOW),
            Status::Identified {
                label: "A · S".into(),
                more: 1,
                guess: true,
                scenes: vec!["1".into(), "2".into()],
                folder: None
            }
        );
    }

    #[test]
    fn identify_failures() {
        for o in ["gave-up", "none"] {
            let d = synced(vec![
                file(Some("1"), Some("scrape"), Some("A")),
                file(Some("2"), Some(o), None),
            ]);
            assert_eq!(status(&d, None, NOW), Status::Failed(Failure::Identify));
        }
    }

    #[test]
    fn in_stash() {
        let d = synced(vec![file(Some("1"), None, None)]);
        assert_eq!(
            status(&d, None, NOW),
            Status::InStash {
                scenes: vec!["1".into()],
                folder: None
            }
        );
    }

    #[test]
    fn scenes_are_deduplicated() {
        let mut a = file(Some("5"), None, None);
        a.path = "Rel/a.mp4".into();
        let mut b = file(Some("5"), None, None);
        b.path = "Rel/b.mp4".into();
        let s = status(&synced(vec![a, b]), None, NOW);
        assert_eq!(
            s,
            Status::InStash {
                scenes: vec!["5".into()],
                folder: Some("Rel".into())
            }
        );
        assert_eq!(
            stash_link("https://s", &s),
            Some("https://s/scenes/5".into())
        );
    }

    #[test]
    fn scenes_and_folder_come_from_linked_files_only() {
        let mut a = file(Some("1"), None, None);
        a.path = "Studio A/Rel/a.mp4".into();
        let mut b = file(Some("2"), None, None);
        b.path = "Studio A/Rel/b.mp4".into();
        let mut nfo = file(None, None, None);
        nfo.path = "Studio A/Other/x.nfo".into();
        let d = synced(vec![a, b, nfo]);
        assert_eq!(
            status(&d, None, NOW),
            Status::InStash {
                scenes: vec!["1".into(), "2".into()],
                folder: Some("Rel".into())
            }
        );
    }

    #[test]
    fn lost() {
        // never synced, and Transmission answered without it
        assert_eq!(
            status(&row(), Some(&HashMap::new()), NOW),
            Status::Failed(Failure::Lost)
        );
        // synced, no scene after two days
        let old = DownloadRow {
            added_at: Some(NOW - 3 * 86400),
            ..synced(vec![file(None, None, None)])
        };
        assert_eq!(status(&old, None, NOW), Status::Failed(Failure::Lost));
    }

    #[test]
    fn added_while_waiting_or_transmission_unknown() {
        assert_eq!(status(&row(), None, NOW), Status::Added); // lookup failed
        assert_eq!(
            status(&synced(vec![file(None, None, None)]), None, NOW),
            Status::Added
        );
        let no_hash = DownloadRow {
            hash: None,
            ..row()
        };
        assert_eq!(status(&no_hash, Some(&HashMap::new()), NOW), Status::Added);
    }

    #[test]
    fn games_downloads_are_outside_provenance() {
        // A synced Games row three days old would otherwise read Lost: it gets no row (so
        // no badge), and is never pending a sync.
        let db = Db::open_in_memory().unwrap();
        let g = db
            .mark_added(NewDownload {
                source: "plab",
                topic_id: Some(4),
                release_title: "A Game",
                section: Section::Games,
                download_dir: Some("/games"),
                torrent_hash: Some("g1"),
                now: NOW - 3 * 86400,
            })
            .unwrap();
        db.enqueue(5, Section::Games, NOW).unwrap();
        assert!(db.unsynced_downloads().unwrap().is_empty());
        assert!(db.unsynced_among(&["g1".to_string()]).unwrap().is_empty());
        db.save_files(g, &[]).unwrap();
        assert!(db.download_rows(0).unwrap().is_empty());
    }

    #[test]
    fn download_rows_carry_files_and_grab_studio() {
        let db = Db::open_in_memory().unwrap();
        let id = add(&db, "grab", None, "R", "h1");
        db.record_grab(
            "Studio A",
            &std::collections::BTreeSet::from(["ep:1".to_string()]),
            "R",
            "x",
            Some(id),
        )
        .unwrap();
        db.save_files(id, &["a.mp4".into()]).unwrap();
        db.enqueue(5, crate::db::Section::Video, 900).unwrap();
        let rows = db.download_rows(0).unwrap();
        assert_eq!(rows.len(), 2);
        let g = rows.iter().find(|r| r.id == id).unwrap();
        assert_eq!(g.studio.as_deref(), Some("Studio A"));
        assert!(g.files_synced);
        assert_eq!(g.files[0].path, "a.mp4");
        assert!(
            rows.iter()
                .any(|r| r.state == "queued" && r.topic_id == Some(5))
        );
        assert!(
            db.download_rows(2000)
                .unwrap()
                .iter()
                .all(|r| r.state == "queued")
        );
    }
}

mod link_tests {
    use super::*;

    fn in_stash(scenes: &[&str], folder: Option<&str>) -> Status {
        Status::InStash {
            scenes: scenes.iter().map(|s| s.to_string()).collect(),
            folder: folder.map(str::to_string),
        }
    }

    #[test]
    fn shared_folder_is_the_deepest_common_directory() {
        assert_eq!(
            shared_folder(&["Studio A/Rel/a.mp4", "Studio A/Rel/b.mp4"]),
            Some("Rel".into())
        );
        assert_eq!(
            shared_folder(&["Studio A/Rel/x/a.mp4", "Studio A/Rel/y/b.mp4"]),
            Some("Rel".into())
        );
        assert_eq!(shared_folder(&["Rel/a.mp4"]), Some("Rel".into()));
        assert_eq!(shared_folder(&["a.mp4", "b.mp4"]), None);
        assert_eq!(shared_folder(&["A/a.mp4", "B/b.mp4"]), None);
        assert_eq!(shared_folder(&[]), None);
        assert_eq!(shared_folder(&["/a.mp4", "/b.mp4"]), None);
    }

    #[test]
    fn one_scene_links_to_the_scene() {
        assert_eq!(
            stash_link("https://stash.example/", &in_stash(&["42"], Some("Rel"))),
            Some("https://stash.example/scenes/42".into())
        );
    }

    #[test]
    fn a_pack_links_to_a_search_by_its_folder() {
        let s = Status::Identified {
            label: "T".into(),
            more: 1,
            guess: false,
            scenes: vec!["1".into(), "2".into()],
            folder: Some("Jane & Joe Pack".into()),
        };
        assert_eq!(
            stash_link("https://stash.example", &s),
            Some("https://stash.example/scenes?q=%22Jane+%26+Joe+Pack%22".into())
        );
    }

    #[test]
    fn a_pack_search_is_a_quoted_phrase() {
        let pack = |f: &str| Status::InStash {
            scenes: vec!["1".into(), "2".into()],
            folder: Some(f.into()),
        };
        assert_eq!(
            stash_link("https://s", &pack("Rel - Title -Uncut")),
            Some("https://s/scenes?q=%22Rel+-+Title+-Uncut%22".into())
        );
        assert_eq!(stash_link("https://s", &pack("Say \"Hi\" Pack")), None);
    }

    #[test]
    fn no_link_without_a_folder_base_or_linkable_status() {
        assert_eq!(stash_link("https://s", &in_stash(&["1", "2"], None)), None);
        assert_eq!(stash_link("", &in_stash(&["1"], None)), None);
        for s in [
            Status::Queued,
            Status::Downloading(5),
            Status::Added,
            Status::Failed(Failure::Lost),
        ] {
            assert_eq!(stash_link("https://s", &s), None, "{s:?}");
        }
    }
}
