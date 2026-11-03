//! Downloads, their files, and the scenes those files became.

use super::*;

/// The download a library file came from, as `link_scene` finds it.
#[derive(Debug, Clone, PartialEq)]
pub struct Link {
    pub download_id: i64,
    pub source: String,
    pub release_title: String,
    /// The grab rule's studio (grabs only).
    pub grab_studio: Option<String>,
    /// Absolute path of the copied tracker image (plab adds only).
    pub cover: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct FileRow {
    pub path: String,
    pub scene_id: Option<String>,
    pub outcome: Option<String>,
    pub label: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DownloadRow {
    pub id: i64,
    pub source: String,
    pub topic_id: Option<u64>,
    pub release_title: String,
    /// The grab rule's studio (grabs only).
    pub studio: Option<String>,
    pub state: String,
    pub hash: Option<String>,
    pub added_at: Option<i64>,
    /// The torrent finished and its files are all recorded (`files_synced = 1`).
    pub files_synced: bool,
    pub files: Vec<FileRow>,
}

impl Db {
    // provenance

    /// Added downloads whose files are not recorded yet: (id, torrent hash). Provenance
    /// covers videos only: games land outside the Vault library, so they never pend.
    pub fn unsynced_downloads(&self) -> Result<Vec<(i64, String)>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT id, torrent_hash FROM download
                 WHERE state = 'added' AND section = 'video' AND torrent_hash IS NOT NULL
                   AND files_synced = 0 ORDER BY id",
            )?;
            all(stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?)
        })
    }

    /// Record some of a download's library-relative file paths (those already recorded are
    /// kept). With `finished`, the torrent is done and the download is synced from now on.
    pub fn record_files(&self, download_id: i64, paths: &[String], finished: bool) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for p in paths {
                tx.execute(
                    "INSERT OR IGNORE INTO download_file (download_id, path) VALUES (?1, ?2)",
                    params![download_id, p],
                )?;
            }
            if finished {
                tx.execute(
                    "UPDATE download SET files_synced = 1 WHERE id = ?1",
                    [download_id],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    /// A finished download's files, recorded and synced.
    #[cfg(test)]
    pub fn save_files(&self, download_id: i64, paths: &[String]) -> Result<()> {
        self.record_files(download_id, paths, true)
    }

    /// Those of `hashes` that belong to a video download whose files are not recorded yet
    /// (a games hash never is, so prune never holds one back).
    pub fn unsynced_among(&self, hashes: &[String]) -> Result<HashSet<String>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT 1 FROM download
                 WHERE torrent_hash = ?1 AND state = 'added' AND section = 'video' AND files_synced = 0",
            )?;
            let mut out = HashSet::new();
            for h in hashes {
                if stmt.exists([h])? {
                    out.insert(h.clone());
                }
            }
            Ok(out)
        })
    }

    /// The download a library file came from (the newest, if several recorded it). With a
    /// scene id, the file is linked to that scene too.
    pub fn link_scene(&self, path: &str, scene_id: Option<&str>) -> Result<Option<Link>> {
        self.with(|c| {
            let link = c
                .query_row(
                    "SELECT d.id, d.source, d.release_title,
                            (SELECT g.studio FROM grab_seen g WHERE g.download_id = d.id LIMIT 1),
                            d.cover
                     FROM download_file f JOIN download d ON d.id = f.download_id
                     WHERE f.path = ?1 ORDER BY d.id DESC LIMIT 1",
                    [path],
                    |r| {
                        Ok(Link {
                            download_id: r.get(0)?,
                            source: r.get(1)?,
                            release_title: r.get(2)?,
                            grab_studio: r.get(3)?,
                            cover: r.get(4)?,
                        })
                    },
                )
                .optional()?;
            if let (Some(l), Some(sid)) = (&link, scene_id) {
                c.execute(
                    "UPDATE download_file SET scene_id = ?3 WHERE download_id = ?1 AND path = ?2",
                    params![l.download_id, path, sid],
                )?;
            }
            Ok(link)
        })
    }

    /// What identify made of a linked scene. A scene no download file is linked to is a no-op.
    pub fn record_outcome(&self, scene_id: &str, outcome: &str, label: Option<&str>) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE download_file SET outcome = ?2, label = ?3 WHERE scene_id = ?1",
                params![scene_id, outcome, label],
            )?;
            Ok(())
        })
    }

    #[cfg(test)]
    pub fn outcome_of(&self, scene_id: &str) -> Result<(Option<String>, Option<String>)> {
        self.with(|c| {
            Ok(c.query_row(
                "SELECT outcome, label FROM download_file WHERE scene_id = ?1",
                [scene_id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )?)
        })
    }

    // grab

    pub fn grabbed(&self, studio: &str, keys: &BTreeSet<String>) -> Result<bool> {
        self.with(|c| {
            let mut stmt =
                c.prepare("SELECT 1 FROM grab_seen WHERE studio = ?1 AND scene_key = ?2")?;
            for k in keys {
                if stmt.exists(params![studio, k])? {
                    return Ok(true);
                }
            }
            Ok(false)
        })
    }

    pub fn record_grab(
        &self,
        studio: &str,
        keys: &BTreeSet<String>,
        title: &str,
        at: &str,
        download_id: Option<i64>,
    ) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for k in keys {
                tx.execute(
                    "INSERT OR REPLACE INTO grab_seen (studio, scene_key, title, at, download_id) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![studio, k, title, at, download_id],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    /// Every queued video download, and those added at or after `since`, newest first, with
    /// their files: the downloads that get a status. Games are outside provenance, and so
    /// are downloads added before it existed (`files_synced = 2`).
    pub fn download_rows(&self, since: i64) -> Result<Vec<DownloadRow>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT d.id, d.source, d.topic_id, d.release_title,
                        (SELECT g.studio FROM grab_seen g WHERE g.download_id = d.id LIMIT 1),
                        d.state, d.torrent_hash, d.added_at, d.files_synced
                 FROM download d
                 WHERE d.section = 'video' AND d.files_synced != 2
                   AND (d.state = 'queued' OR d.added_at >= ?1)
                 ORDER BY COALESCE(d.added_at, d.queued_at) DESC, d.id DESC",
            )?;
            let mut rows = all(stmt.query_map([since], |r| {
                    Ok(DownloadRow {
                        id: r.get(0)?,
                        source: r.get(1)?,
                        topic_id: r.get(2)?,
                        release_title: r.get(3)?,
                        studio: r.get(4)?,
                        state: r.get(5)?,
                        hash: r.get(6)?,
                        added_at: r.get(7)?,
                        files_synced: r.get::<_, i64>(8)? == 1,
                        files: vec![],
                    })
                })?)?;
            let mut files = c.prepare(
                "SELECT path, scene_id, outcome, label FROM download_file WHERE download_id = ?1 ORDER BY path",
            )?;
            for row in &mut rows {
                row.files = all(files.query_map([row.id], |r| {
                        Ok(FileRow {
                            path: r.get(0)?,
                            scene_id: r.get(1)?,
                            outcome: r.get(2)?,
                            label: r.get(3)?,
                        })
                    })?)?;
            }
            Ok(rows)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::*;
    use super::*;

    #[test]
    fn grabbed_matches_any_key() {
        let db = Db::open_in_memory().unwrap();
        let k = |v: &[&str]| {
            v.iter()
                .map(|s| s.to_string())
                .collect::<std::collections::BTreeSet<_>>()
        };
        db.record_grab(
            "StudioL",
            &k(&["ep:1", "name:abcdefgh"]),
            "t",
            "2026-10-24T00:00:00+00:00",
            None,
        )
        .unwrap();
        assert!(db.grabbed("StudioL", &k(&["name:abcdefgh"])).unwrap());
        assert!(!db.grabbed("Other", &k(&["ep:1"])).unwrap());
        assert!(!db.grabbed("StudioL", &k(&[])).unwrap());
    }

    #[test]
    fn save_files_marks_synced_and_link_finds_the_download() {
        let db = Db::open_in_memory().unwrap();
        let id = added(&db, "grab", None, "Rel", Some("h1"));
        db.record_grab(
            "Studio A",
            &BTreeSet::from(["ep:1".to_string()]),
            "Rel",
            "x",
            Some(id),
        )
        .unwrap();
        assert_eq!(
            db.unsynced_downloads().unwrap(),
            vec![(id, "h1".to_string())]
        );
        db.save_files(
            id,
            &["Studio A/Rel/a.mp4".into(), "Studio A/Rel/a.nfo".into()],
        )
        .unwrap();
        assert!(db.unsynced_downloads().unwrap().is_empty());

        // read-only lookup writes no scene id
        let l = db.link_scene("Studio A/Rel/a.mp4", None).unwrap().unwrap();
        assert_eq!(l.download_id, id);
        assert_eq!(l.source, "grab");
        assert_eq!(l.release_title, "Rel");
        assert_eq!(l.grab_studio.as_deref(), Some("Studio A"));
        assert_eq!(l.cover, None);
        db.record_outcome("7", "llm", Some("T")).unwrap(); // no row has scene 7 yet: no-op

        assert!(
            db.link_scene("Studio A/Rel/a.mp4", Some("7"))
                .unwrap()
                .is_some()
        );
        db.record_outcome("7", "scrape", Some("Title · Studio A"))
            .unwrap();
        let (sid, outcome, label): (Option<String>, Option<String>, Option<String>) = db
            .with(|c| {
                Ok(c.query_row(
                    "SELECT scene_id, outcome, label FROM download_file WHERE path = 'Studio A/Rel/a.mp4'",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
                )?)
            })
            .unwrap();
        assert_eq!(sid.as_deref(), Some("7"));
        assert_eq!(outcome.as_deref(), Some("scrape"));
        assert_eq!(label.as_deref(), Some("Title · Studio A"));
        assert!(db.link_scene("nowhere.mp4", Some("8")).unwrap().is_none());
    }

    #[test]
    fn re_adding_a_topic_with_a_new_torrent_forgets_the_old_files() {
        let db = Db::open_in_memory().unwrap();
        let id = added(&db, "plab", Some(5), "A", Some("h1"));
        db.save_files(id, &["A/x.mp4".into()]).unwrap();
        // the same torrent again: nothing to redo
        assert_eq!(added(&db, "plab", Some(5), "A", Some("h1")), id);
        assert!(db.unsynced_downloads().unwrap().is_empty());
        assert!(db.link_scene("A/x.mp4", None).unwrap().is_some());
        // a new torrent: its files are the ones to record
        assert_eq!(added(&db, "plab", Some(5), "A", Some("h2")), id);
        assert_eq!(
            db.unsynced_downloads().unwrap(),
            vec![(id, "h2".to_string())]
        );
        assert!(db.link_scene("A/x.mp4", None).unwrap().is_none());
    }

    #[test]
    fn unsynced_among_names_only_known_unsynced_hashes() {
        let db = Db::open_in_memory().unwrap();
        let a = added(&db, "plab", Some(1), "A", Some("ha"));
        added(&db, "plab", Some(2), "B", Some("hb"));
        db.save_files(a, &["A/x.mp4".into()]).unwrap();
        let got = db
            .unsynced_among(&["ha".into(), "hb".into(), "hz".into()])
            .unwrap();
        assert_eq!(got, HashSet::from(["hb".to_string()]));
    }
}
