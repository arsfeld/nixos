//! Topic listings, live-search results, images and cached torrent files.

use super::*;

/// How long a live search's results stay addable and their images servable.
pub const SEARCH_TTL: i64 = 86400;

#[derive(Debug, Clone, PartialEq)]
pub struct Listed {
    pub topic: Topic,
    pub filters: Vec<String>,
    pub curated_reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Listing {
    pub updated: i64,
    pub filters: Vec<String>,
    pub topics: Vec<Listed>,
}

impl Db {
    // lists

    pub fn listing(&self, section: Section) -> Result<Listing> {
        self.with(|c| {
            let meta: Option<(i64, String)> = c
                .query_row("SELECT updated, filters FROM listing_meta WHERE section = ?1", [section.as_str()], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .optional()?;
            let Some((updated, filters)) = meta else {
                return Ok(Listing::default());
            };
            let sql = format!(
                "SELECT {TOPIC_COLS}, l.filters, l.curated_reason FROM listing l JOIN topic t ON t.id = l.topic_id
                 WHERE l.section = ?1 ORDER BY l.position"
            );
            let mut stmt = c.prepare(&sql)?;
            let raw = stmt
                .query_map([section.as_str()], |r| Ok((raw_topic(r)?, r.get::<_, String>(10)?, r.get::<_, Option<String>>(11)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let topics = raw
                .into_iter()
                .map(|(t, filters, curated_reason)| {
                    Ok(Listed {
                        topic: topic_of(t)?,
                        filters: serde_json::from_str(&filters).context("listing.filters")?,
                        curated_reason,
                    })
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(Listing { updated, filters: serde_json::from_str(&filters).context("listing_meta.filters")?, topics })
        })
    }

    pub fn save_listing(
        &self,
        section: Section,
        topics: &[Listed],
        filters: &[String],
        now: i64,
    ) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for l in topics {
                let images = l.topic.images.as_ref().map(serde_json::to_string).transpose()?;
                let production = l.topic.production.as_ref().map(serde_json::to_string).transpose()?;
                upsert_topic(&tx, &l.topic.row, images.as_deref(), production.as_deref(), now)?;
            }
            tx.execute("DELETE FROM listing WHERE section = ?1", [section.as_str()])?;
            for (pos, l) in topics.iter().enumerate() {
                tx.execute(
                    "INSERT INTO listing (section, position, topic_id, filters, curated_reason) VALUES (?1, ?2, ?3, ?4, ?5)",
                    params![section.as_str(), pos as i64, l.topic.row.id, serde_json::to_string(&l.filters)?, l.curated_reason],
                )?;
            }
            tx.execute(
                "INSERT INTO listing_meta (section, updated, filters) VALUES (?1, ?2, ?3)
                 ON CONFLICT(section) DO UPDATE SET updated = excluded.updated, filters = excluded.filters",
                params![section.as_str(), now, serde_json::to_string(filters)?],
            )?;
            tx.execute("DELETE FROM search_hit WHERE at < ?1", [now - SEARCH_TTL])?;
            tx.execute(
                "DELETE FROM topic WHERE id NOT IN (SELECT topic_id FROM listing)
                   AND id NOT IN (SELECT topic_id FROM search_hit)
                   AND id NOT IN (SELECT topic_id FROM curated_hit)
                   AND id NOT IN (SELECT topic_id FROM download WHERE topic_id IS NOT NULL)",
                [],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    // search

    pub fn search_topics(&self, now: i64) -> Result<HashMap<u64, Topic>> {
        self.with(|c| {
            let sql = format!(
                "SELECT {TOPIC_COLS} FROM search_hit h JOIN topic t ON t.id = h.topic_id WHERE h.at >= ?1"
            );
            let mut stmt = c.prepare(&sql)?;
            let raw = stmt.query_map([now - SEARCH_TTL], raw_topic)?.collect::<rusqlite::Result<Vec<_>>>()?;
            raw.into_iter().map(|t| topic_of(t).map(|t| (t.row.id, t))).collect()
        })
    }

    pub fn save_search(&self, rows: &[Row], now: i64) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for row in rows {
                upsert_topic(&tx, row, None, None, now)?;
                tx.execute(
                    "INSERT INTO search_hit (topic_id, at) VALUES (?1, ?2)
                     ON CONFLICT(topic_id) DO UPDATE SET at = excluded.at",
                    params![row.id, now],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    /// A no-op for an unknown topic.
    pub fn set_images(&self, topic_id: u64, urls: &[String]) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE topic SET images = ?1 WHERE id = ?2",
                params![serde_json::to_string(urls)?, topic_id],
            )?;
            Ok(())
        })
    }

    // lookup

    pub fn find(&self, topic_id: u64, now: i64) -> Result<Option<(Topic, Section)>> {
        for section in Section::ALL {
            if let Some(l) = self
                .listing(section)?
                .topics
                .into_iter()
                .find(|l| l.topic.row.id == topic_id)
            {
                return Ok(Some((l.topic, section)));
            }
        }
        Ok(self
            .search_topics(now)?
            .remove(&topic_id)
            .map(|t| (t, Section::Video)))
    }

    pub fn image_urls(&self, now: i64) -> Result<Vec<String>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT t.images FROM topic t WHERE t.images IS NOT NULL AND (
                   t.id IN (SELECT topic_id FROM listing)
                   OR t.id IN (SELECT topic_id FROM search_hit WHERE at >= ?1))",
            )?;
            let raw = stmt
                .query_map([now - SEARCH_TTL], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let mut seen = HashSet::new();
            let mut urls = Vec::new();
            for s in raw {
                for u in serde_json::from_str::<Vec<String>>(&s).context("topic.images")? {
                    if seen.insert(u.clone()) {
                        urls.push(u);
                    }
                }
            }
            Ok(urls)
        })
    }

    pub fn topic(&self, id: u64) -> Result<Option<Topic>> {
        self.with(|c| {
            let sql = format!("SELECT {TOPIC_COLS} FROM topic t WHERE t.id = ?1");
            let raw = c.query_row(&sql, [id], raw_topic).optional()?;
            raw.map(topic_of).transpose()
        })
    }

    // torrent files

    pub fn torrent_file(&self, topic_id: u64) -> Result<Option<Vec<u8>>> {
        self.with(|c| {
            Ok(c.query_row(
                "SELECT data FROM torrent_file WHERE topic_id = ?1",
                [topic_id],
                |r| r.get(0),
            )
            .optional()?)
        })
    }

    pub fn store_torrent_file(&self, topic_id: u64, data: &[u8], now: i64) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT OR REPLACE INTO torrent_file (topic_id, data, fetched) VALUES (?1, ?2, ?3)",
                params![topic_id, data, now],
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
    fn empty_listing_is_default() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.listing(Section::Video).unwrap(), Listing::default());
    }

    #[test]
    fn save_listing_round_trips_in_order_per_section() {
        let db = Db::open_in_memory().unwrap();
        db.save_listing(Section::Video, &[listed(2), listed(1)], &["A".into()], 100)
            .unwrap();
        db.save_listing(Section::Games, &[listed(3)], &[], 101)
            .unwrap();
        let v = db.listing(Section::Video).unwrap();
        assert_eq!(v.updated, 100);
        assert_eq!(v.filters, vec!["A".to_string()]);
        assert_eq!(
            v.topics.iter().map(|t| t.topic.row.id).collect::<Vec<_>>(),
            vec![2, 1]
        );
        assert_eq!(db.listing(Section::Games).unwrap().topics.len(), 1);
    }

    #[test]
    fn save_listing_round_trips_topic_fields() {
        let db = Db::open_in_memory().unwrap();
        let l = Listed {
            topic: Topic {
                row: row(8, "eight"),
                images: Some(vec!["https://i/a".into(), "https://i/b".into()]),
                production: Some(Production {
                    class: "pro".into(),
                    confidence: Some(0.5),
                }),
            },
            filters: vec!["F".into()],
            curated_reason: Some("because".into()),
        };
        db.save_listing(Section::Video, std::slice::from_ref(&l), &["F".into()], 5)
            .unwrap();
        assert_eq!(db.listing(Section::Video).unwrap().topics, vec![l]);
    }

    #[test]
    fn save_listing_replaces_section_and_drops_orphans() {
        let db = Db::open_in_memory().unwrap();
        db.save_listing(Section::Video, &[listed(1), listed(2)], &[], 1)
            .unwrap();
        db.save_listing(Section::Video, &[listed(2)], &[], 2)
            .unwrap();
        assert!(db.find(1, 2).unwrap().is_none());
        assert!(db.find(2, 2).unwrap().is_some());
    }

    #[test]
    fn search_topics_expire_after_ttl_and_keep_images() {
        let db = Db::open_in_memory().unwrap();
        db.save_search(&[row(9, "a")], 1000).unwrap();
        db.set_images(9, &["https://i/9".into()]).unwrap();
        db.save_search(&[row(9, "a2")], 2000).unwrap(); // re-search keeps fetched images
        let s = db.search_topics(2000).unwrap();
        assert_eq!(s[&9].images, Some(vec!["https://i/9".to_string()]));
        assert_eq!(s[&9].row.title, "a2");
        assert!(db.search_topics(2000 + SEARCH_TTL + 1).unwrap().is_empty());
    }

    #[test]
    fn save_search_records_rows_without_images() {
        let db = Db::open_in_memory().unwrap();
        db.save_search(&[row(5, "a")], 1000).unwrap();
        let s = db.search_topics(1000).unwrap();
        assert_eq!(
            s[&5],
            Topic {
                row: row(5, "a"),
                images: None,
                production: None
            }
        );
    }

    #[test]
    fn search_entries_exactly_a_day_old_are_kept() {
        let db = Db::open_in_memory().unwrap();
        db.save_search(&[row(5, "a")], 1000).unwrap();
        assert!(
            db.search_topics(1000 + SEARCH_TTL)
                .unwrap()
                .contains_key(&5)
        );
        assert!(db.search_topics(1000 + SEARCH_TTL + 1).unwrap().is_empty());
    }

    #[test]
    fn save_search_drops_entries_older_than_a_day() {
        let db = Db::open_in_memory().unwrap();
        db.save_search(&[row(5, "a")], 1000).unwrap();
        db.save_search(&[row(6, "b")], 1000 + SEARCH_TTL).unwrap();
        let ids = |now| {
            let mut v: Vec<u64> = db.search_topics(now).unwrap().into_keys().collect();
            v.sort();
            v
        };
        assert_eq!(ids(1000 + SEARCH_TTL), vec![5, 6]); // exactly a day: kept
        db.save_search(&[row(7, "c")], 1001 + SEARCH_TTL).unwrap();
        assert_eq!(ids(1001 + SEARCH_TTL), vec![6, 7]);
    }

    #[test]
    fn search_topics_does_not_write() {
        // Reads hide expired entries; only a save removes them.
        let db = Db::open_in_memory().unwrap();
        db.save_search(&[row(5, "a")], 1000).unwrap();
        assert!(db.search_topics(1000 + SEARCH_TTL + 5).unwrap().is_empty());
        assert!(db.search_topics(1000).unwrap().contains_key(&5));
    }

    #[test]
    fn set_images_unknown_topic_is_a_no_op() {
        let db = Db::open_in_memory().unwrap();
        db.set_images(9, &["https://i/1.jpg".into()]).unwrap();
        assert!(db.search_topics(1).unwrap().is_empty());
        assert!(db.find(9, 1).unwrap().is_none());
    }

    #[test]
    fn find_prefers_lists_then_search_as_video() {
        let db = Db::open_in_memory().unwrap();
        db.save_listing(Section::Games, &[listed(3)], &[], 1)
            .unwrap();
        db.save_search(&[row(4, "s")], 1).unwrap();
        assert_eq!(db.find(3, 1).unwrap().unwrap().1, Section::Games);
        assert_eq!(db.find(4, 1).unwrap().unwrap().1, Section::Video);
        assert!(db.find(5, 1).unwrap().is_none());
    }

    #[test]
    fn image_urls_cover_both_lists_and_live_searches() {
        let db = Db::open_in_memory().unwrap();
        db.save_listing(Section::Video, &[listed(1)], &[], 1)
            .unwrap();
        db.save_listing(Section::Games, &[listed(2)], &[], 1)
            .unwrap();
        db.save_search(&[row(3, "s")], 1).unwrap();
        db.set_images(3, &["https://i/3.jpg".into()]).unwrap();
        let mut urls = db.image_urls(1).unwrap();
        urls.sort();
        assert_eq!(
            urls,
            vec!["https://i/1.jpg", "https://i/2.jpg", "https://i/3.jpg"]
        );
    }

    #[test]
    fn torrent_files_round_trip_and_replace() {
        let db = Db::open_in_memory().unwrap();
        assert!(db.torrent_file(7).unwrap().is_none());
        db.store_torrent_file(7, b"d4:infoe", 10).unwrap();
        assert_eq!(db.torrent_file(7).unwrap().unwrap(), b"d4:infoe");
        db.store_torrent_file(7, b"d4:newe", 11).unwrap();
        assert_eq!(db.torrent_file(7).unwrap().unwrap(), b"d4:newe");
    }
}
