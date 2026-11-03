pub mod import;

use crate::tracker::parse::Row;
use anyhow::{Context, Result};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// How long a live search's results stay addable and their images servable.
pub const SEARCH_TTL: i64 = 86400;
pub const IDENTIFY_FAILURE_LIMIT: i64 = 3;

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

pub struct NewDownload<'a> {
    pub source: &'a str, // "plab" | "grab"
    pub topic_id: Option<u64>,
    pub release_title: &'a str,
    pub section: Section,
    pub download_dir: Option<&'a str>,
    pub torrent_hash: Option<&'a str>,
    pub now: i64,
}

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

/// One run of a job, for the jobs page; `finished` and `ok` are None while it runs.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct JobRunRow {
    pub started: i64,
    pub finished: Option<i64>,
    pub ok: Option<bool>,
    pub error: Option<String>,
}

/// A stream of the same release within this many seconds of the last is not a new view.
pub const STREAM_VIEW_GAP: i64 = 6 * 3600;

#[derive(Debug, Clone, PartialEq)]
pub struct ConversationRow {
    pub id: i64,
    pub title: String,
    pub kind: String,
    pub created_at: i64,
    pub updated_at: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MessageRow {
    pub seq: i64,
    pub role: String,
    pub content: String,
    pub at: i64,
}

fn conversation_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<ConversationRow> {
    Ok(ConversationRow {
        id: r.get(0)?,
        title: r.get(1)?,
        kind: r.get(2)?,
        created_at: r.get(3)?,
        updated_at: r.get(4)?,
    })
}

/// Runs kept per job in `job_history`.
const HISTORY_KEEP: i64 = 50;

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

    /// Record that `topic_id` started streaming, unless it already did in the last
    /// `STREAM_VIEW_GAP` seconds: a reopen or a file switch is not a second view.
    pub fn record_stream_view(&self, topic_id: u64, now: i64) -> Result<bool> {
        self.with(|c| {
            let last: Option<i64> = c.query_row(
                "SELECT MAX(started_at) FROM stream_view WHERE topic_id = ?1",
                params![topic_id],
                |r| r.get(0),
            )?;
            if last.is_some_and(|l| now - l < STREAM_VIEW_GAP) {
                return Ok(false);
            }
            c.execute(
                "INSERT INTO stream_view (topic_id, started_at) VALUES (?1, ?2)",
                params![topic_id, now],
            )?;
            Ok(true)
        })
    }

    pub fn stream_views(&self, since: i64) -> Result<Vec<(u64, i64)>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT topic_id, started_at FROM stream_view WHERE started_at >= ?1
                 ORDER BY started_at DESC, id DESC",
            )?;
            let rows = s.query_map(params![since], |r| Ok((r.get(0)?, r.get(1)?)))?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    pub fn create_conversation(&self, title: &str, kind: &str, now: i64) -> Result<i64> {
        self.with(|c| {
            c.execute(
                "INSERT INTO conversation (title, kind, created_at, updated_at) VALUES (?1, ?2, ?3, ?3)",
                params![title, kind, now],
            )?;
            Ok(c.last_insert_rowid())
        })
    }

    #[allow(dead_code)] // used by the assistant's routes (task 7)
    pub fn conversations(&self) -> Result<Vec<ConversationRow>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT id, title, kind, created_at, updated_at FROM conversation
                 ORDER BY updated_at DESC, id DESC",
            )?;
            let rows = s.query_map([], conversation_row)?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    pub fn conversation(&self, id: i64) -> Result<Option<ConversationRow>> {
        self.with(|c| {
            Ok(c.query_row(
                "SELECT id, title, kind, created_at, updated_at FROM conversation WHERE id = ?1",
                params![id],
                conversation_row,
            )
            .optional()?)
        })
    }

    #[allow(dead_code)] // used by the assistant's routes (task 7)
    pub fn delete_conversation(&self, id: i64) -> Result<bool> {
        self.with(|c| Ok(c.execute("DELETE FROM conversation WHERE id = ?1", params![id])? > 0))
    }

    pub fn append_message(
        &self,
        conversation: i64,
        role: &str,
        content: &str,
        now: i64,
    ) -> Result<i64> {
        self.with(|c| {
            let tx = c.transaction()?;
            let seq: i64 = tx.query_row(
                "SELECT COALESCE(MAX(seq) + 1, 0) FROM message WHERE conversation_id = ?1",
                params![conversation],
                |r| r.get(0),
            )?;
            tx.execute(
                "INSERT INTO message (conversation_id, seq, role, content, at) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![conversation, seq, role, content, now],
            )?;
            tx.execute(
                "UPDATE conversation SET updated_at = ?2 WHERE id = ?1",
                params![conversation, now],
            )?;
            tx.commit()?;
            Ok(seq)
        })
    }

    pub fn messages(&self, conversation: i64) -> Result<Vec<MessageRow>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT seq, role, content, at FROM message WHERE conversation_id = ?1 ORDER BY seq",
            )?;
            let rows = s.query_map(params![conversation], |r| {
                Ok(MessageRow {
                    seq: r.get(0)?,
                    role: r.get(1)?,
                    content: r.get(2)?,
                    at: r.get(3)?,
                })
            })?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    pub fn delete_messages_from(&self, conversation: i64, seq: i64) -> Result<()> {
        self.with(|c| {
            c.execute(
                "DELETE FROM message WHERE conversation_id = ?1 AND seq >= ?2",
                params![conversation, seq],
            )?;
            Ok(())
        })
    }

    #[cfg(test)]
    pub fn user_version(&self) -> Result<i64> {
        self.with(|c| Ok(c.pragma_query_value(None, "user_version", |r| r.get(0))?))
    }

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
            Ok(stmt.query_map([section.as_str()], |r| r.get(0))?.collect::<rusqlite::Result<Vec<u64>>>()?)
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
            Ok(stmt
                .query_map([before], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?)
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
            Ok(stmt
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?)
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
            let mut rows = stmt
                .query_map([since], |r| {
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
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            let mut files = c.prepare(
                "SELECT path, scene_id, outcome, label FROM download_file WHERE download_id = ?1 ORDER BY path",
            )?;
            for row in &mut rows {
                row.files = files
                    .query_map([row.id], |r| {
                        Ok(FileRow {
                            path: r.get(0)?,
                            scene_id: r.get(1)?,
                            outcome: r.get(2)?,
                            label: r.get(3)?,
                        })
                    })?
                    .collect::<rusqlite::Result<Vec<_>>>()?;
            }
            Ok(rows)
        })
    }

    // identify

    pub fn identify_done(&self, scene_id: &str) -> Result<bool> {
        self.with(|c| {
            let done: Option<i64> = c
                .query_row(
                    "SELECT done FROM identify_attempt WHERE scene_id = ?1",
                    [scene_id],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(done == Some(1))
        })
    }

    pub fn identify_mark_done(&self, scene_id: &str) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO identify_attempt (scene_id, done) VALUES (?1, 1)
                 ON CONFLICT(scene_id) DO UPDATE SET done = 1",
                [scene_id],
            )?;
            Ok(())
        })
    }

    /// Count a failure; the third gives up (marks the scene done) and returns true.
    pub fn identify_fail(&self, scene_id: &str) -> Result<bool> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute(
                "INSERT INTO identify_attempt (scene_id, failures) VALUES (?1, 1)
                 ON CONFLICT(scene_id) DO UPDATE SET failures = failures + 1",
                [scene_id],
            )?;
            let failures: i64 = tx.query_row(
                "SELECT failures FROM identify_attempt WHERE scene_id = ?1",
                [scene_id],
                |r| r.get(0),
            )?;
            let gave_up = failures >= IDENTIFY_FAILURE_LIMIT;
            if gave_up {
                tx.execute(
                    "UPDATE identify_attempt SET done = 1 WHERE scene_id = ?1",
                    [scene_id],
                )?;
            }
            tx.commit()?;
            Ok(gave_up)
        })
    }

    /// The failure count `identify_fail` has reached for a scene (0 when never failed).
    #[cfg(test)]
    pub fn identify_failures(&self, scene_id: &str) -> Result<i64> {
        self.with(|c| {
            let n: Option<i64> = c
                .query_row(
                    "SELECT failures FROM identify_attempt WHERE scene_id = ?1",
                    [scene_id],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(n.unwrap_or(0))
        })
    }

    pub fn identify_clear_failures(&self, scene_id: &str) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE identify_attempt SET failures = 0 WHERE scene_id = ?1",
                [scene_id],
            )?;
            Ok(())
        })
    }

    // jobs

    pub fn job_last_started(&self, job: &str) -> Result<Option<i64>> {
        self.with(|c| {
            let v: Option<Option<i64>> = c
                .query_row(
                    "SELECT last_started FROM job_run WHERE job = ?1",
                    [job],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(v.flatten())
        })
    }

    pub fn job_started(&self, job: &str, now: i64) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO job_run (job, last_started) VALUES (?1, ?2)
                 ON CONFLICT(job) DO UPDATE SET last_started = excluded.last_started",
                params![job, now],
            )?;
            Ok(())
        })
    }

    pub fn job_finished(&self, job: &str, now: i64, error: Option<&str>) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO job_run (job, last_finished, ok, error) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(job) DO UPDATE SET last_finished = excluded.last_finished, ok = excluded.ok, error = excluded.error",
                params![job, now, error.is_none(), error],
            )?;
            Ok(())
        })
    }

    pub fn history_start(&self, job: &str, now: i64) -> Result<i64> {
        self.with(|c| {
            c.execute(
                "INSERT INTO job_history (job, started) VALUES (?1, ?2)",
                params![job, now],
            )?;
            Ok(c.last_insert_rowid())
        })
    }

    /// Close run `id`, then drop all but the job's newest `HISTORY_KEEP` runs.
    pub fn history_finish(&self, id: i64, job: &str, now: i64, error: Option<&str>) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute(
                "UPDATE job_history SET finished = ?2, ok = ?3, error = ?4 WHERE id = ?1",
                params![id, now, error.is_none(), error],
            )?;
            tx.execute(
                "DELETE FROM job_history WHERE job = ?1 AND id NOT IN
                   (SELECT id FROM job_history WHERE job = ?1
                    ORDER BY started DESC, id DESC LIMIT ?2)",
                params![job, HISTORY_KEEP],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    /// At daemon start: a run left unfinished was cut off by the restart.
    pub fn close_interrupted(&self) -> Result<usize> {
        self.with(|c| {
            Ok(c.execute(
                "UPDATE job_history SET finished = started, ok = 0, error = 'interrupted'
                 WHERE finished IS NULL",
                [],
            )?)
        })
    }

    pub fn job_history(&self, job: &str, limit: usize) -> Result<Vec<JobRunRow>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT started, finished, ok, error FROM job_history WHERE job = ?1
                 ORDER BY started DESC, id DESC LIMIT ?2",
            )?;
            let rows = stmt
                .query_map(params![job, limit as i64], |r| {
                    Ok(JobRunRow {
                        started: r.get(0)?,
                        finished: r.get(1)?,
                        ok: r.get(2)?,
                        error: r.get(3)?,
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(rows)
        })
    }

    // kv

    pub fn kv_get(&self, key: &str) -> Result<Option<(String, i64)>> {
        self.with(|c| {
            Ok(
                c.query_row("SELECT value, rev FROM kv WHERE key = ?1", [key], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .optional()?,
            )
        })
    }

    pub fn kv_set(&self, key: &str, value: &str) -> Result<i64> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute(
                "INSERT INTO kv (key, value, rev) VALUES (?1, ?2, COALESCE((SELECT max(rev) FROM kv), 0) + 1)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, rev = excluded.rev",
                params![key, value],
            )?;
            let rev = tx.query_row("SELECT rev FROM kv WHERE key = ?1", [key], |r| r.get(0))?;
            tx.commit()?;
            Ok(rev)
        })
    }

    pub fn kv_delete(&self, key: &str) -> Result<()> {
        self.with(|c| {
            c.execute("DELETE FROM kv WHERE key = ?1", [key])?;
            Ok(())
        })
    }

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
            let raw = stmt
                .query_map([], |r| {
                    Ok((
                        raw_topic(r)?,
                        r.get::<_, String>(10)?,
                        r.get::<_, String>(11)?,
                        r.get::<_, Option<String>>(12)?,
                    ))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
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

    pub fn topic(&self, id: u64) -> Result<Option<Topic>> {
        self.with(|c| {
            let sql = format!("SELECT {TOPIC_COLS} FROM topic t WHERE t.id = ?1");
            let raw = c.query_row(&sql, [id], raw_topic).optional()?;
            raw.map(topic_of).transpose()
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
                Some(id) => stmt
                    .query_map([id], map)?
                    .collect::<rusqlite::Result<Vec<_>>>()?,
                None => stmt
                    .query_map([], map)?
                    .collect::<rusqlite::Result<Vec<_>>>()?,
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
    use super::*;
    use crate::tracker::parse::Row;

    fn row(id: u64, title: &str) -> Row {
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
    fn listed(id: u64) -> Listed {
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
    fn dl(topic: u64, section: Section, now: i64) -> NewDownload<'static> {
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
    fn empty_listing_is_default() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.listing(Section::Video).unwrap(), Listing::default());
    }

    #[test]
    fn empty_defaults() {
        // test_empty_defaults: no added topics, no search results.
        let db = Db::open_in_memory().unwrap();
        assert!(db.added().unwrap().is_empty());
        assert!(db.search_topics(1).unwrap().is_empty());
        assert!(db.queued(Section::Video).unwrap().is_empty());
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
    fn identify_gives_up_on_third_failure_and_clears() {
        let db = Db::open_in_memory().unwrap();
        assert!(!db.identify_fail("7").unwrap());
        db.identify_clear_failures("7").unwrap();
        assert!(!db.identify_fail("7").unwrap());
        assert!(!db.identify_fail("7").unwrap());
        assert!(db.identify_fail("7").unwrap());
        assert!(db.identify_done("7").unwrap());
    }

    #[test]
    fn identify_mark_done() {
        let db = Db::open_in_memory().unwrap();
        assert!(!db.identify_done("1").unwrap());
        db.identify_mark_done("1").unwrap();
        assert!(db.identify_done("1").unwrap());
    }

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
    fn kv_rev_increments() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.kv_get("k").unwrap(), None);
        let r1 = db.kv_set("k", "a").unwrap();
        let r2 = db.kv_set("k", "b").unwrap();
        assert!(r2 > r1);
        assert_eq!(db.kv_get("k").unwrap(), Some(("b".into(), r2)));
    }

    #[test]
    fn kv_delete_removes_the_key() {
        let db = Db::open_in_memory().unwrap();
        db.kv_set("k", "a").unwrap();
        db.kv_delete("k").unwrap();
        assert_eq!(db.kv_get("k").unwrap(), None);
        db.kv_delete("k").unwrap(); // absent: no error
    }

    #[test]
    fn job_run_records_start() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.job_last_started("prune").unwrap(), None);
        db.job_started("prune", 50).unwrap();
        db.job_finished("prune", 60, Some("boom")).unwrap();
        assert_eq!(db.job_last_started("prune").unwrap(), Some(50));
    }

    fn added(db: &Db, source: &str, topic: Option<u64>, title: &str, hash: Option<&str>) -> i64 {
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

    #[test]
    fn torrent_files_round_trip_and_replace() {
        let db = Db::open_in_memory().unwrap();
        assert!(db.torrent_file(7).unwrap().is_none());
        db.store_torrent_file(7, b"d4:infoe", 10).unwrap();
        assert_eq!(db.torrent_file(7).unwrap().unwrap(), b"d4:infoe");
        db.store_torrent_file(7, b"d4:newe", 11).unwrap();
        assert_eq!(db.torrent_file(7).unwrap().unwrap(), b"d4:newe");
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

    // test_corrupt_json_reads_as_defaults: N/A, SQLite has no half-written-file state.
    // test_ensure_image_fetches_once, test_prune_images, test_prune_keeps_in_flight_temp_files:
    // image files, ported in Task 4.

    #[test]
    fn job_history_records_runs_newest_first() {
        let db = Db::open_in_memory().unwrap();
        let a = db.history_start("grab", 100).unwrap();
        db.history_finish(a, "grab", 110, None).unwrap();
        let b = db.history_start("grab", 200).unwrap();
        db.history_finish(b, "grab", 230, Some("boom")).unwrap();
        db.history_start("prune", 300).unwrap();
        assert_eq!(
            db.job_history("grab", 10).unwrap(),
            vec![
                JobRunRow {
                    started: 200,
                    finished: Some(230),
                    ok: Some(false),
                    error: Some("boom".into())
                },
                JobRunRow {
                    started: 100,
                    finished: Some(110),
                    ok: Some(true),
                    error: None
                },
            ]
        );
        assert_eq!(
            db.job_history("prune", 10).unwrap(),
            vec![JobRunRow {
                started: 300,
                finished: None,
                ok: None,
                error: None
            }]
        );
    }

    #[test]
    fn job_history_keeps_fifty_per_job() {
        let db = Db::open_in_memory().unwrap();
        for t in 0..60 {
            let id = db.history_start("grab", t).unwrap();
            db.history_finish(id, "grab", t, None).unwrap();
        }
        let other = db.history_start("prune", 0).unwrap();
        db.history_finish(other, "prune", 0, None).unwrap();
        let rows = db.job_history("grab", 100).unwrap();
        assert_eq!(rows.len(), 50);
        assert_eq!((rows[0].started, rows[49].started), (59, 10));
        assert_eq!(db.job_history("prune", 100).unwrap().len(), 1);
    }

    #[test]
    fn unfinished_runs_close_as_interrupted() {
        let db = Db::open_in_memory().unwrap();
        db.history_start("refresh", 500).unwrap();
        assert_eq!(db.close_interrupted().unwrap(), 1);
        assert_eq!(
            db.job_history("refresh", 1).unwrap(),
            vec![JobRunRow {
                started: 500,
                finished: Some(500),
                ok: Some(false),
                error: Some("interrupted".into())
            }]
        );
        assert_eq!(db.close_interrupted().unwrap(), 0);
    }

    const NOW: i64 = 1_800_000_000;

    fn topic(id: u64, title: &str) -> Topic {
        Topic {
            row: row(id, title),
            images: None,
            production: None,
        }
    }

    fn new_ext<'a>(guid: &'a str, link: &'a str) -> NewExternal<'a> {
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
    fn sections_parse_by_id() {
        assert_eq!(Section::parse("albums"), Some(Section::Albums));
        assert_eq!(Section::parse("indexers"), Some(Section::Indexers));
        assert_eq!(Section::parse("video"), Some(Section::Video));
        assert_eq!(Section::parse("nope"), None);
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

    #[test]
    fn stream_views_dedupe_within_gap() {
        let db = Db::open_in_memory().unwrap();
        assert!(db.record_stream_view(7, 1_000).unwrap());
        assert!(
            !db.record_stream_view(7, 1_000 + STREAM_VIEW_GAP - 1)
                .unwrap()
        );
        assert!(db.record_stream_view(7, 1_000 + STREAM_VIEW_GAP).unwrap());
        assert!(db.record_stream_view(8, 1_001).unwrap());
        assert_eq!(
            db.stream_views(0).unwrap(),
            vec![(7, 1_000 + STREAM_VIEW_GAP), (8, 1_001), (7, 1_000)]
        );
        assert_eq!(db.stream_views(1_001).unwrap().len(), 2);
    }

    #[test]
    fn conversations_round_trip() {
        let db = Db::open_in_memory().unwrap();
        let a = db.create_conversation("first", "chat", 10).unwrap();
        let b = db.create_conversation("second", "recommend", 20).unwrap();
        assert_eq!(
            db.append_message(a, "user", r#"{"role":"user","content":"hi"}"#, 30)
                .unwrap(),
            0
        );
        assert_eq!(db.append_message(a, "assistant", "{}", 31).unwrap(), 1);
        let list = db.conversations().unwrap();
        assert_eq!(list.iter().map(|c| c.id).collect::<Vec<_>>(), vec![a, b]);
        assert_eq!(list[0].updated_at, 31);
        let msgs = db.messages(a).unwrap();
        assert_eq!(
            msgs.iter()
                .map(|m| (m.seq, m.role.as_str()))
                .collect::<Vec<_>>(),
            vec![(0, "user"), (1, "assistant")]
        );
        db.delete_messages_from(a, 1).unwrap();
        assert_eq!(db.messages(a).unwrap().len(), 1);
        assert!(db.delete_conversation(a).unwrap());
        assert!(!db.delete_conversation(a).unwrap());
        assert!(db.messages(a).unwrap().is_empty());
        assert_eq!(db.conversation(b).unwrap().unwrap().kind, "recommend");
        assert!(db.conversation(a).unwrap().is_none());
    }
}
