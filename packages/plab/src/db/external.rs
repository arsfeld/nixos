//! Releases from other indexers, curated hits, and album entries.

use super::*;

/// The first plab id of a release from another indexer: far above any tracker topic id,
/// and exact in JavaScript (below 2^53), so the ids pass through the API unchanged.
pub const EXTERNAL_BASE: u64 = 1 << 40;

/// Whether `id` names a release from another indexer rather than a tracker topic.
pub fn is_external(id: u64) -> bool {
    id >= EXTERNAL_BASE
}

/// A release from another indexer, as `external_release` holds it.
#[derive(Debug, Clone, PartialEq)]
pub struct External {
    pub id: u64,
    pub indexer: String,
    pub link: String,
    pub info_url: Option<String>,
    pub scene_id: Option<String>,
    pub kind: Kind,
    pub files: Option<u32>,
    pub first_seen: i64,
}

/// What an external release is. Only torrents can be streamed or added.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    Torrent,
    Album,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Torrent => "torrent",
            Kind::Album => "album",
        }
    }

    fn from_db(s: &str) -> Kind {
        if s == "album" {
            Kind::Album
        } else {
            Kind::Torrent
        }
    }
}

/// `seen`: now; stored as `first_seen` on insert only.
pub struct NewExternal<'a> {
    pub indexer: &'a str,
    pub guid: &'a str,
    pub link: &'a str,
    pub info_url: Option<&'a str>,
    pub kind: Kind,
    pub files: Option<u32>,
    pub seen: i64,
}

/// One curated hit: `topic_id` was found for `filter` by the term whose badge is `reason`.
#[derive(Debug, Clone, PartialEq)]
pub struct CuratedHit {
    pub topic_id: u64,
    pub filter: String,
    pub reason: String,
}

/// A stored curated hit with its topic. `kind`: None for a tracker topic.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredHit {
    pub topic: Topic,
    pub filter: String,
    pub reason: String,
    pub kind: Option<Kind>,
}

impl Db {
    // curated hits and external releases

    /// Insert the topics (images and production kept when `None`) and replace every
    /// curated hit with `hits`, in one transaction.
    pub fn save_curated(&self, topics: &[Topic], hits: &[CuratedHit], now: i64) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for t in topics {
                let images = t.images.as_ref().map(serde_json::to_string).transpose()?;
                let production = t.production.as_ref().map(serde_json::to_string).transpose()?;
                upsert_topic(&tx, &t.row, images.as_deref(), production.as_deref(), now)?;
            }
            tx.execute("DELETE FROM curated_hit", [])?;
            for h in hits {
                tx.execute(
                    "INSERT OR IGNORE INTO curated_hit (topic_id, filter, reason) VALUES (?1, ?2, ?3)",
                    params![h.topic_id, h.filter, h.reason],
                )?;
            }
            // Only the curated job writes external releases, so only it prunes them: a
            // refresh can never delete a row this job is still working on. Album rows are
            // kept: see schema_v6.sql.
            tx.execute(
                "DELETE FROM external_release WHERE kind = 'torrent' AND id NOT IN (SELECT id FROM topic)",
                [],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    /// Every curated hit with its topic and release kind, in the order the last run stored them.
    pub fn curated_hits(&self) -> Result<Vec<StoredHit>> {
        self.with(|c| {
            let sql = format!(
                "SELECT {TOPIC_COLS}, h.filter, h.reason, e.kind FROM curated_hit h
                 JOIN topic t ON t.id = h.topic_id
                 LEFT JOIN external_release e ON e.id = h.topic_id
                 ORDER BY h.rowid"
            );
            let mut stmt = c.prepare(&sql)?;
            let raw = all(stmt.query_map([], |r| {
                Ok((
                    raw_topic(r)?,
                    r.get::<_, String>(10)?,
                    r.get::<_, String>(11)?,
                    r.get::<_, Option<String>>(12)?,
                ))
            })?)?;
            raw.into_iter()
                .map(|(t, filter, reason, kind)| {
                    Ok(StoredHit {
                        topic: topic_of(t)?,
                        filter,
                        reason,
                        kind: kind.as_deref().map(Kind::from_db),
                    })
                })
                .collect()
        })
    }

    /// The plab id of (indexer, guid), allocated by SQLite from `EXTERNAL_BASE` on first sight; the
    /// link and page are refreshed every time.
    pub fn upsert_external(&self, e: &NewExternal<'_>) -> Result<u64> {
        self.with(|c| {
            Ok(c.query_row(
                "INSERT INTO external_release (id, indexer, guid, link, info_url, kind, files, first_seen)
                 VALUES (NULL, ?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(indexer, guid) DO UPDATE SET
                   link = excluded.link, info_url = excluded.info_url, files = excluded.files
                 RETURNING id",
                params![e.indexer, e.guid, e.link, e.info_url, e.kind.as_str(), e.files, e.seen],
                |r| r.get(0),
            )?)
        })
    }

    pub fn external(&self, id: u64) -> Result<Option<External>> {
        Ok(self.externals_where("WHERE id = ?1", Some(id))?.remove(&id))
    }

    /// Every external release, by id. The table holds only what the lists show.
    pub fn externals(&self) -> Result<HashMap<u64, External>> {
        self.externals_where("", None)
    }

    fn externals_where(&self, filter: &str, id: Option<u64>) -> Result<HashMap<u64, External>> {
        self.with(|c| {
            let sql = format!(
                "SELECT id, indexer, link, info_url, scene_id, kind, files, first_seen
                 FROM external_release {filter}"
            );
            let mut stmt = c.prepare(&sql)?;
            let map = |r: &rusqlite::Row<'_>| {
                Ok(External {
                    id: r.get(0)?,
                    indexer: r.get(1)?,
                    link: r.get(2)?,
                    info_url: r.get(3)?,
                    scene_id: r.get(4)?,
                    kind: Kind::from_db(&r.get::<_, String>(5)?),
                    files: r.get(6)?,
                    first_seen: r.get(7)?,
                })
            };
            let rows = match id {
                Some(id) => all(stmt.query_map([id], map)?)?,
                None => all(stmt.query_map([], map)?)?,
            };
            Ok(rows.into_iter().map(|e| (e.id, e)).collect())
        })
    }

    /// Whether `id` is an album index entry: linked to, never streamed or added.
    pub fn is_album(&self, id: u64) -> Result<bool> {
        Ok(is_external(id) && self.external(id)?.is_some_and(|e| e.kind == Kind::Album))
    }

    pub fn set_scene(&self, id: u64, scene_id: &str) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE external_release SET scene_id = ?1 WHERE id = ?2",
                params![scene_id, id],
            )?;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::*;
    use super::*;

    #[test]
    fn album_rows_keep_their_first_sight_and_are_never_pruned() {
        let db = Db::open_in_memory().unwrap();
        let album = |seen| NewExternal {
            indexer: "Album index A",
            guid: "AbC123",
            link: "https://files.example/a/AbC123",
            info_url: Some("https://files.example/a/AbC123"),
            kind: Kind::Album,
            files: Some(3),
            seen,
        };
        let id = db.upsert_external(&album(NOW)).unwrap();
        assert_eq!(db.upsert_external(&album(NOW + 99)).unwrap(), id);
        let e = db.external(id).unwrap().unwrap();
        assert_eq!((e.kind, e.files, e.first_seen), (Kind::Album, Some(3), NOW));
        assert!(db.is_album(id).unwrap());
        // No topic and no hit: a torrent row would be pruned here, an album row is kept.
        db.save_curated(&[], &[], NOW).unwrap();
        assert!(db.external(id).unwrap().is_some());
    }

    #[test]
    fn curated_hits_carry_the_release_kind() {
        let db = Db::open_in_memory().unwrap();
        let torrent = db.upsert_external(&new_ext("g1", "http://p/1")).unwrap();
        let hit = |id: u64| CuratedHit {
            topic_id: id,
            filter: "A".into(),
            reason: "Alpha".into(),
        };
        db.save_curated(
            &[topic(5, "five"), topic(torrent, "ext")],
            &[hit(5), hit(torrent)],
            NOW,
        )
        .unwrap();
        let kinds: Vec<_> = db
            .curated_hits()
            .unwrap()
            .into_iter()
            .map(|h| (h.topic.row.id, h.kind))
            .collect();
        assert_eq!(kinds, vec![(5, None), (torrent, Some(Kind::Torrent))]);
        assert!(!db.is_album(torrent).unwrap());
        assert!(!db.is_album(5).unwrap());
    }

    #[test]
    fn external_ids_start_at_the_base_and_are_stable_per_guid() {
        let db = Db::open_in_memory().unwrap();
        let a = db.upsert_external(&new_ext("g1", "http://p/1")).unwrap();
        let b = db.upsert_external(&new_ext("g2", "http://p/2")).unwrap();
        assert_eq!(a, EXTERNAL_BASE);
        assert_eq!(b, EXTERNAL_BASE + 1);
        assert!(is_external(a) && !is_external(7_000_000));
        // Same (indexer, guid): same id, link refreshed.
        assert_eq!(db.upsert_external(&new_ext("g1", "http://p/9")).unwrap(), a);
        let e = db.external(a).unwrap().unwrap();
        assert_eq!(
            (e.indexer.as_str(), e.link.as_str()),
            ("Indexer A", "http://p/9")
        );
        assert_eq!(e.info_url.as_deref(), Some("http://a/1"));
        db.set_scene(a, "s1").unwrap();
        assert_eq!(db.externals().unwrap()[&a].scene_id.as_deref(), Some("s1"));
    }

    #[test]
    fn save_curated_replaces_the_hits_and_keeps_images() {
        let db = Db::open_in_memory().unwrap();
        let mut t1 = topic(1, "one");
        t1.images = Some(vec!["http://i/1.jpg".into()]);
        let hit = |id, f: &str| CuratedHit {
            topic_id: id,
            filter: f.into(),
            reason: "Alpha".into(),
        };
        db.save_curated(&[t1, topic(2, "two")], &[hit(2, "B"), hit(1, "A")], NOW)
            .unwrap();
        let hits = db.curated_hits().unwrap();
        assert_eq!(
            hits.iter()
                .map(|h| (h.topic.row.id, h.filter.as_str()))
                .collect::<Vec<_>>(),
            vec![(2, "B"), (1, "A")]
        );
        // A later run without images must not erase them; its hits replace the old ones.
        db.save_curated(&[topic(1, "one")], &[hit(1, "A")], NOW)
            .unwrap();
        let hits = db.curated_hits().unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(
            hits[0].topic.images,
            Some(vec!["http://i/1.jpg".to_string()])
        );
        assert_eq!(db.topic(1).unwrap().unwrap().row.title, "one");
        assert_eq!(db.topic(99).unwrap(), None);
    }

    #[test]
    fn a_pruned_external_id_is_never_handed_out_again() {
        let db = Db::open_in_memory().unwrap();
        let a = db.upsert_external(&new_ext("g1", "http://p/1")).unwrap();
        let b = db.upsert_external(&new_ext("g2", "http://p/2")).unwrap();
        assert_eq!((a, b), (EXTERNAL_BASE, EXTERNAL_BASE + 1));
        db.save_curated(&[], &[], NOW).unwrap(); // prunes both
        assert!(db.external(b).unwrap().is_none());
        let c = db.upsert_external(&new_ext("g3", "http://p/3")).unwrap();
        assert_eq!(c, EXTERNAL_BASE + 2);
    }
}
