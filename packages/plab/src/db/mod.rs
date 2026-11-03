pub mod import;
mod topics;
mod added;
mod downloads;
mod identify;
mod jobs;
mod assistant;
mod external;
mod kv;

pub use topics::*;
pub use added::*;
pub use downloads::*;
pub use identify::*;
pub use jobs::*;
pub use assistant::*;
pub use external::*;

use crate::tracker::parse::Row;
use anyhow::{Context, Result};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;










const SCHEMA: &str = include_str!("schema.sql");
const SCHEMA_V2: &str = include_str!("schema_v2.sql");
const SCHEMA_V3: &str = include_str!("schema_v3.sql");
const SCHEMA_V4: &str = include_str!("schema_v4.sql");
const SCHEMA_V5: &str = include_str!("schema_v5.sql");
const SCHEMA_V6: &str = include_str!("schema_v6.sql");
const SCHEMA_V7: &str = include_str!("schema_v7.sql");
const USER_VERSION: i64 = 7;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Section {
    Video,
    Games,
    Indexers,
    Albums,
}

impl Section {
    pub const ALL: [Section; 4] = [
        Section::Video,
        Section::Games,
        Section::Indexers,
        Section::Albums,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Section::Video => "video",
            Section::Games => "games",
            Section::Indexers => "indexers",
            Section::Albums => "albums",
        }
    }

    pub fn parse(s: &str) -> Option<Section> {
        Section::ALL.into_iter().find(|x| x.as_str() == s)
    }
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Production {
    #[serde(rename = "class")]
    pub class: String,
    pub confidence: Option<f64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Topic {
    pub row: Row,
    pub images: Option<Vec<String>>,
    pub production: Option<Production>,
}







#[derive(Clone)]
pub struct Db(Arc<Mutex<Connection>>);

/// The topic columns, in the order `raw_topic` reads them.
const TOPIC_COLS: &str = "t.id, t.title, t.forum, t.size, t.seeders, t.leechers, t.completed, t.added, t.images, t.production";

type RawTopic = (Row, Option<String>, Option<String>);

fn raw_topic(r: &rusqlite::Row<'_>) -> rusqlite::Result<RawTopic> {
    Ok((
        Row {
            id: r.get(0)?,
            title: r.get(1)?,
            forum: r.get(2)?,
            size: r.get(3)?,
            seeders: r.get(4)?,
            leechers: r.get(5)?,
            completed: r.get(6)?,
            added: r.get(7)?,
        },
        r.get(8)?,
        r.get(9)?,
    ))
}

fn topic_of((row, images, production): RawTopic) -> Result<Topic> {
    Ok(Topic {
        row,
        images: images
            .map(|s| serde_json::from_str(&s))
            .transpose()
            .context("topic.images")?,
        production: production
            .map(|s| serde_json::from_str(&s))
            .transpose()
            .context("topic.production")?,
    })
}

/// Insert or update a topic's tracker fields. `images`/`production` are written when `Some`
/// and kept when `None`.
fn upsert_topic(
    conn: &Connection,
    row: &Row,
    images: Option<&str>,
    production: Option<&str>,
    now: i64,
) -> Result<()> {
    conn.execute(
        "INSERT INTO topic (id, title, forum, size, seeders, leechers, completed, added, images, production, seen_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT(id) DO UPDATE SET
           title = excluded.title, forum = excluded.forum, size = excluded.size,
           seeders = excluded.seeders, leechers = excluded.leechers, completed = excluded.completed,
           added = excluded.added, seen_at = excluded.seen_at,
           images = COALESCE(excluded.images, topic.images),
           production = COALESCE(excluded.production, topic.production)",
        params![row.id, row.title, row.forum, row.size, row.seeders, row.leechers, row.completed, row.added, images, production, now],
    )?;
    Ok(())
}

fn migrate(conn: &mut Connection, legacy: Option<&import::LegacyPaths>, now: i64) -> Result<()> {
    let version = |c: &Connection| -> Result<i64> {
        Ok(c.pragma_query_value(None, "user_version", |r| r.get(0))?)
    };
    if version(conn)? >= USER_VERSION {
        return Ok(());
    }
    // Immediate takes the write lock up front, so a second process opening the same fresh
    // database waits here and then sees the first one's work instead of racing it.
    let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let from = version(&tx)?;
    if from >= USER_VERSION {
        return Ok(());
    }
    // Stepwise: a fresh database runs every step, a v1 one only what it lacks.
    if from < 1 {
        tx.execute_batch(SCHEMA)?;
        if let Some(legacy) = legacy {
            import::run(&tx, legacy, now)?;
        }
    }
    if from < 2 {
        tx.execute_batch(SCHEMA_V2)?;
    }
    if from < 3 {
        tx.execute_batch(SCHEMA_V3)?;
    }
    if from < 4 {
        tx.execute_batch(SCHEMA_V4)?;
    }
    if from < 5 {
        tx.execute_batch(SCHEMA_V5)?;
    }
    if from < 6 {
        tx.execute_batch(SCHEMA_V6)?;
    }
    if from < 7 {
        tx.execute_batch(SCHEMA_V7)?;
    }
    tx.pragma_update(None, "user_version", USER_VERSION)?;
    tx.commit()?;
    Ok(())
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

impl Db {
    #[cfg(test)]
    pub fn open(path: &Path) -> Result<Db> {
        Self::open_with(path, None)
    }

    pub fn open_with(path: &Path, legacy: Option<&import::LegacyPaths>) -> Result<Db> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        let mut conn =
            Connection::open(path).with_context(|| format!("opening {}", path.display()))?;
        conn.busy_timeout(Duration::from_secs(30))?;
        // Switching to WAL needs a lock the busy handler is not consulted for, so a second
        // process opening a fresh database at the same moment gets SQLITE_BUSY at once: retry.
        let deadline = std::time::Instant::now() + Duration::from_secs(30);
        loop {
            match conn.pragma_update(None, "journal_mode", "WAL") {
                Err(rusqlite::Error::SqliteFailure(e, _))
                    if e.code == rusqlite::ErrorCode::DatabaseBusy
                        && std::time::Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(20));
                }
                r => break r?,
            }
        }
        conn.pragma_update(None, "foreign_keys", true)?;
        migrate(&mut conn, legacy, unix_now())?;
        Ok(Db(Arc::new(Mutex::new(conn))))
    }

    #[cfg(test)]
    pub fn open_in_memory() -> Result<Db> {
        let mut conn = Connection::open_in_memory()?;
        conn.pragma_update(None, "foreign_keys", true)?;
        migrate(&mut conn, None, 0)?;
        Ok(Db(Arc::new(Mutex::new(conn))))
    }

    /// Run `f` with the connection locked. Never call this across an `.await`.
    fn with<R>(&self, f: impl FnOnce(&mut Connection) -> Result<R>) -> Result<R> {
        let mut conn = self.0.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut conn)
    }

    /// Run raw SQL, for a test that needs the database in a state no method makes.
    #[cfg(test)]
    pub fn exec(&self, sql: &str) -> Result<()> {
        self.with(|c| Ok(c.execute_batch(sql)?))
    }












    #[cfg(test)]
    pub fn user_version(&self) -> Result<i64> {
        self.with(|c| Ok(c.pragma_query_value(None, "user_version", |r| r.get(0))?))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tracker::parse::Row;

    pub(super) fn row(id: u64, title: &str) -> Row {
        Row {
            id,
            title: title.into(),
            forum: 1875,
            size: 1,
            seeders: 1,
            leechers: 0,
            completed: 0,
            added: 0,
        }
    }
    pub(super) fn listed(id: u64) -> Listed {
        Listed {
            topic: Topic {
                row: row(id, "t"),
                images: Some(vec![format!("https://i/{id}.jpg")]),
                production: None,
            },
            filters: vec![],
            curated_reason: None,
        }
    }
    pub(super) fn dl(topic: u64, section: Section, now: i64) -> NewDownload<'static> {
        NewDownload {
            source: "plab",
            topic_id: Some(topic),
            release_title: "x",
            section,
            download_dir: Some("/d"),
            torrent_hash: None,
            now,
        }
    }


    #[test]
    fn empty_defaults() {
        // test_empty_defaults: no added topics, no search results.
        let db = Db::open_in_memory().unwrap();
        assert!(db.added().unwrap().is_empty());
        assert!(db.search_topics(1).unwrap().is_empty());
        assert!(db.queued(Section::Video).unwrap().is_empty());
    }

























    pub(super) fn added(db: &Db, source: &str, topic: Option<u64>, title: &str, hash: Option<&str>) -> i64 {
        db.mark_added(NewDownload {
            source,
            topic_id: topic,
            release_title: title,
            section: Section::Video,
            download_dir: Some("/d"),
            torrent_hash: hash,
            now: 100,
        })
        .unwrap()
    }

    #[test]
    fn migrations_set_user_version() {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(&dir.path().join("state.db")).unwrap();
        assert_eq!(db.user_version().unwrap(), USER_VERSION);
        drop(db);
        assert_eq!(
            Db::open(&dir.path().join("state.db"))
                .unwrap()
                .user_version()
                .unwrap(),
            USER_VERSION
        ); // idempotent
    }

    #[test]
    fn v1_database_migrates_to_v2_keeping_rows() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("state.db");
        {
            let c = Connection::open(&p).unwrap();
            c.execute_batch(SCHEMA).unwrap();
            c.execute(
                "INSERT INTO download (source, release_title, section, state, torrent_hash, added_at)
                 VALUES ('grab', 'Old', 'video', 'added', 'h1', 5)",
                [],
            )
            .unwrap();
            c.execute(
                "INSERT INTO download (source, topic_id, release_title, section, state, queued_at)
                 VALUES ('plab', 9, 'Waiting', 'video', 'queued', 6)",
                [],
            )
            .unwrap();
            c.pragma_update(None, "user_version", 1).unwrap();
        }
        let db = Db::open(&p).unwrap();
        assert_eq!(db.user_version().unwrap(), USER_VERSION);
        // An added download predates provenance: its files were never recorded and cannot be
        // now, so it is not pending and gets no status (it would read "failed: lost").
        let marked: i64 = db
            .with(|c| {
                Ok(
                    c.query_row("SELECT files_synced FROM download WHERE id = 1", [], |r| {
                        r.get(0)
                    })?,
                )
            })
            .unwrap();
        assert_eq!(marked, 2);
        assert!(db.unsynced_downloads().unwrap().is_empty());
        assert!(db.unsynced_among(&["h1".to_string()]).unwrap().is_empty());
        let rows = db.download_rows(0).unwrap();
        assert_eq!(rows.iter().map(|r| r.id).collect::<Vec<_>>(), vec![2]); // the queued one only
        assert!(!rows[0].files_synced);
    }





    #[test]
    fn a_version_2_database_gains_torrent_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("v2.db");
        {
            let c = Connection::open(&path).unwrap();
            c.execute_batch(SCHEMA).unwrap();
            c.execute_batch(SCHEMA_V2).unwrap();
            c.pragma_update(None, "user_version", 2).unwrap();
        }
        let db = Db::open(&path).unwrap();
        assert_eq!(db.user_version().unwrap(), USER_VERSION);
        db.store_torrent_file(1, b"x", 1).unwrap();
        assert_eq!(db.torrent_file(1).unwrap().unwrap(), b"x");
    }




    pub(super) const NOW: i64 = 1_800_000_000;

    pub(super) fn topic(id: u64, title: &str) -> Topic {
        Topic {
            row: row(id, title),
            images: None,
            production: None,
        }
    }

    pub(super) fn new_ext<'a>(guid: &'a str, link: &'a str) -> NewExternal<'a> {
        NewExternal {
            indexer: "Indexer A",
            guid,
            link,
            info_url: Some("http://a/1"),
            kind: Kind::Torrent,
            files: None,
            seen: NOW,
        }
    }



    #[test]
    fn sections_parse_by_id() {
        assert_eq!(Section::parse("albums"), Some(Section::Albums));
        assert_eq!(Section::parse("indexers"), Some(Section::Indexers));
        assert_eq!(Section::parse("video"), Some(Section::Video));
        assert_eq!(Section::parse("nope"), None);
    }



    #[test]
    fn save_curated_drops_orphan_external_rows_and_save_listing_keeps_curated_topics() {
        let db = Db::open_in_memory().unwrap();
        let ext = db.upsert_external(&new_ext("g1", "http://p/1")).unwrap();
        let gone = db.upsert_external(&new_ext("g2", "http://p/2")).unwrap();
        let hit = CuratedHit {
            topic_id: ext,
            filter: "A".into(),
            reason: "Alpha".into(),
        };
        db.save_curated(&[topic(ext, "kept")], &[hit], NOW).unwrap();
        // `gone` has no topic row: the curated save drops it, and keeps the one with a topic.
        assert!(db.external(gone).unwrap().is_none());
        assert!(db.external(ext).unwrap().is_some());
        // A listing without the curated topic does not prune it, nor its release row.
        db.save_listing(Section::Video, &[], &[], NOW).unwrap();
        assert!(db.topic(ext).unwrap().is_some());
        assert!(db.external(ext).unwrap().is_some());
    }

    #[test]
    fn save_listing_leaves_external_rows_alone() {
        let db = Db::open_in_memory().unwrap();
        let ext = db.upsert_external(&new_ext("g1", "http://p/1")).unwrap();
        db.save_listing(Section::Video, &[], &[], NOW).unwrap();
        assert!(db.external(ext).unwrap().is_some());
    }
}
