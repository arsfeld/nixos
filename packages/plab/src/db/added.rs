//! The added set and the per-section download queue.

use super::*;

pub struct NewDownload<'a> {
    pub source: &'a str, // "plab" | "grab"
    pub topic_id: Option<u64>,
    pub release_title: &'a str,
    pub section: Section,
    pub download_dir: Option<&'a str>,
    pub torrent_hash: Option<&'a str>,
    pub now: i64,
}

impl Db {
    // downloads

    pub fn added(&self) -> Result<HashSet<u64>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT topic_id FROM download WHERE state = 'added' AND topic_id IS NOT NULL",
            )?;
            Ok(stmt
                .query_map([], |r| r.get(0))?
                .collect::<rusqlite::Result<HashSet<u64>>>()?)
        })
    }

    pub fn queued(&self, section: Section) -> Result<Vec<u64>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT topic_id FROM download WHERE state = 'queued' AND section = ?1 AND topic_id IS NOT NULL
                 ORDER BY queued_at, id",
            )?;
            all::<u64>(stmt.query_map([section.as_str()], |r| r.get(0))?)
        })
    }

    /// The release title to record for a queued topic: the topic's, else the one it was
    /// queued with, else "".
    pub fn queued_title(&self, topic_id: u64) -> Result<String> {
        self.with(|c| {
            Ok(c.query_row(
                "SELECT COALESCE((SELECT title FROM topic WHERE id = ?1),
                                 (SELECT release_title FROM download WHERE topic_id = ?1), '')",
                [topic_id],
                |r| r.get(0),
            )?)
        })
    }

    pub fn enqueue(&self, topic_id: u64, section: Section, now: i64) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO download (source, topic_id, release_title, section, state, queued_at)
                 SELECT 'plab', ?1, COALESCE((SELECT title FROM topic WHERE id = ?1), ''), ?2, 'queued', ?3
                 WHERE NOT EXISTS (SELECT 1 FROM download WHERE topic_id = ?1)",
                params![topic_id, section.as_str(), now],
            )?;
            Ok(())
        })
    }

    pub fn dequeue(&self, topic_id: u64, section: Section) -> Result<()> {
        self.with(|c| {
            c.execute(
                "DELETE FROM download WHERE topic_id = ?1 AND section = ?2 AND state = 'queued'",
                params![topic_id, section.as_str()],
            )?;
            Ok(())
        })
    }

    pub fn set_cover(&self, download_id: i64, path: &str) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE download SET cover = ?2 WHERE id = ?1",
                params![download_id, path],
            )?;
            Ok(())
        })
    }

    /// Covers of downloads added before `before`: (download id, path).
    pub fn stale_covers(&self, before: i64) -> Result<Vec<(i64, String)>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT id, cover FROM download WHERE cover IS NOT NULL AND added_at < ?1 ORDER BY id",
            )?;
            all(stmt.query_map([before], |r| Ok((r.get(0)?, r.get(1)?)))?)
        })
    }

    pub fn clear_cover(&self, download_id: i64) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE download SET cover = NULL WHERE id = ?1",
                [download_id],
            )?;
            Ok(())
        })
    }

    pub fn mark_added(&self, a: NewDownload<'_>) -> Result<i64> {
        self.with(|c| {
            let tx = c.transaction()?;
            let existing: Option<i64> = match a.topic_id {
                Some(t) => tx.query_row("SELECT id FROM download WHERE topic_id = ?1", [t], |r| r.get(0)).optional()?,
                None => None,
            };
            let id = match existing {
                Some(id) => {
                    // A new torrent (or a queued row's first) has files of its own: forget
                    // any recorded for the old one, so they are synced afresh.
                    tx.execute(
                        "DELETE FROM download_file WHERE download_id = ?1
                           AND (SELECT torrent_hash FROM download WHERE id = ?1) IS NOT ?2",
                        params![id, a.torrent_hash],
                    )?;
                    tx.execute(
                        "UPDATE download SET state = 'added', release_title = ?2, section = ?3, download_dir = ?4,
                           files_synced = CASE WHEN torrent_hash IS ?5 THEN files_synced ELSE 0 END,
                           torrent_hash = ?5, added_at = ?6 WHERE id = ?1",
                        params![id, a.release_title, a.section.as_str(), a.download_dir, a.torrent_hash, a.now],
                    )?;
                    id
                }
                None => {
                    tx.execute(
                        "INSERT INTO download (source, topic_id, release_title, section, download_dir, state, torrent_hash, added_at)
                         VALUES (?1, ?2, ?3, ?4, ?5, 'added', ?6, ?7)",
                        params![a.source, a.topic_id, a.release_title, a.section.as_str(), a.download_dir, a.torrent_hash, a.now],
                    )?;
                    tx.last_insert_rowid()
                }
            };
            tx.commit()?;
            Ok(id)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::*;
    use super::*;

    #[test]
    fn queued_title_prefers_the_topic_then_the_queue_row() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.queued_title(7).unwrap(), "");
        db.save_search(&[row(7, "Seven")], 0).unwrap();
        db.enqueue(7, Section::Video, 0).unwrap();
        assert_eq!(db.queued_title(7).unwrap(), "Seven");
        db.save_listing(Section::Video, &[], &[], 2 * SEARCH_TTL)
            .unwrap(); // topic kept: it is queued
        db.save_search(&[row(7, "Renamed")], 0).unwrap();
        assert_eq!(db.queued_title(7).unwrap(), "Renamed");
    }

    #[test]
    fn enqueue_skips_added_and_duplicates() {
        let db = Db::open_in_memory().unwrap();
        db.enqueue(5, Section::Video, 1).unwrap();
        db.enqueue(5, Section::Video, 2).unwrap();
        assert_eq!(db.queued(Section::Video).unwrap(), vec![5]);
        db.mark_added(NewDownload {
            source: "plab",
            topic_id: Some(6),
            release_title: "x",
            section: Section::Video,
            download_dir: Some("/d"),
            torrent_hash: None,
            now: 3,
        })
        .unwrap();
        db.enqueue(6, Section::Video, 4).unwrap();
        assert_eq!(db.queued(Section::Video).unwrap(), vec![5]);
    }

    #[test]
    fn queue_is_oldest_first_and_dequeue_unknown_is_a_no_op() {
        let db = Db::open_in_memory().unwrap();
        db.enqueue(5, Section::Video, 1).unwrap();
        db.enqueue(3, Section::Video, 2).unwrap();
        db.enqueue(5, Section::Video, 3).unwrap(); // no duplicates
        assert_eq!(db.queued(Section::Video).unwrap(), vec![5, 3]);
        db.dequeue(5, Section::Video).unwrap();
        db.dequeue(99, Section::Video).unwrap();
        assert_eq!(db.queued(Section::Video).unwrap(), vec![3]);
    }

    #[test]
    fn queues_are_per_section() {
        let db = Db::open_in_memory().unwrap();
        db.enqueue(1, Section::Video, 1).unwrap();
        db.enqueue(2, Section::Games, 1).unwrap();
        assert_eq!(db.queued(Section::Video).unwrap(), vec![1]);
        assert_eq!(db.queued(Section::Games).unwrap(), vec![2]);
        db.dequeue(1, Section::Games).unwrap(); // wrong section: no-op
        assert_eq!(db.queued(Section::Video).unwrap(), vec![1]);
    }

    #[test]
    fn mark_added_promotes_a_queued_row() {
        let db = Db::open_in_memory().unwrap();
        db.enqueue(5, Section::Games, 1).unwrap();
        db.dequeue(5, Section::Games).unwrap();
        db.enqueue(5, Section::Games, 1).unwrap();
        db.mark_added(NewDownload {
            source: "plab",
            topic_id: Some(5),
            release_title: "x",
            section: Section::Games,
            download_dir: Some("/g"),
            torrent_hash: Some("abc"),
            now: 2,
        })
        .unwrap();
        assert!(db.queued(Section::Games).unwrap().is_empty());
        assert!(db.added().unwrap().contains(&5));
    }

    #[test]
    fn mark_added_persists_across_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.db");
        let db = Db::open(&path).unwrap();
        db.mark_added(dl(5, Section::Video, 1)).unwrap();
        db.mark_added(dl(3, Section::Video, 2)).unwrap();
        drop(db);
        let added = Db::open(&path).unwrap().added().unwrap();
        assert_eq!(added, [3u64, 5].into_iter().collect());
    }

    #[test]
    fn mark_added_without_topic_always_inserts() {
        let db = Db::open_in_memory().unwrap();
        let mk = |now| NewDownload {
            source: "grab",
            topic_id: None,
            release_title: "r",
            section: Section::Video,
            download_dir: None,
            torrent_hash: None,
            now,
        };
        let a = db.mark_added(mk(1)).unwrap();
        let b = db.mark_added(mk(2)).unwrap();
        assert_ne!(a, b);
    }
}
