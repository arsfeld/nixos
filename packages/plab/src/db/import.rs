//! One-time import of the Python tools' JSON state files into SQLite, run inside the
//! transaction that creates the schema, so a failed import leaves the database unmigrated.

use super::{Production, SEARCH_TTL, Section, upsert_topic};
use crate::tracker::parse::Row;
use anyhow::{Result, bail};
use rusqlite::{Transaction, params};
use serde::Deserialize;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};

pub struct LegacyPaths {
    pub plab: PathBuf, // cache.json, games.json, search.json, added.json, queued.json, games-queued.json, cookies.txt
    pub stash_identify: PathBuf, // attempted.json, failures.json
    pub vault_grab: PathBuf, // state.json
}

#[derive(Debug, Default, PartialEq)]
pub struct ImportReport {
    pub video: usize,
    pub games: usize,
    pub search: usize,
    pub added: usize,
    pub queued: usize,
    pub grab_keys: usize,
    pub identify: usize,
    pub cookies: bool,
}

#[derive(Deserialize)]
struct ListFile {
    #[serde(default)]
    updated: i64,
    #[serde(default)]
    topics: Vec<ListTopic>,
    #[serde(default)]
    filters: Vec<String>,
}

#[derive(Deserialize)]
struct ListTopic {
    #[serde(flatten)]
    row: Row,
    #[serde(default)]
    images: Option<Vec<String>>,
    #[serde(default)]
    filters: Vec<String>,
    #[serde(default)]
    curated_reason: Option<String>,
    #[serde(default)]
    production: Option<Production>,
}

#[derive(Deserialize)]
struct SearchEntry {
    #[serde(flatten)]
    row: Row,
    #[serde(default)]
    images: Option<Vec<String>>,
    at: f64,
}

#[derive(Deserialize)]
struct GrabState {
    #[serde(default)]
    studios: BTreeMap<String, BTreeMap<String, GrabEntry>>,
}

#[derive(Deserialize)]
struct GrabEntry {
    #[serde(default)]
    title: String,
    #[serde(default)]
    at: String,
}

/// Parse a legacy JSON file; `None` when it does not exist.
fn read<T: serde::de::DeserializeOwned>(dir: &Path, name: &str) -> Result<Option<T>> {
    let path = dir.join(name);
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => bail!("legacy import: {}: {e}", path.display()),
    };
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|e| anyhow::anyhow!("legacy import: {}: {e}", path.display()))
}

fn to_json<T: serde::Serialize>(v: &Option<T>) -> Result<Option<String>> {
    Ok(v.as_ref().map(serde_json::to_string).transpose()?)
}

pub fn run(tx: &Transaction<'_>, legacy: &LegacyPaths, now: i64) -> Result<ImportReport> {
    let mut report = ImportReport::default();
    let mut list_section: HashMap<u64, Section> = HashMap::new();

    for (section, file) in [
        (Section::Video, "cache.json"),
        (Section::Games, "games.json"),
    ] {
        let Some(list) = read::<ListFile>(&legacy.plab, file)? else {
            continue;
        };
        for (pos, t) in list.topics.iter().enumerate() {
            upsert_topic(
                tx,
                &t.row,
                to_json(&t.images)?.as_deref(),
                to_json(&t.production)?.as_deref(),
                now,
            )?;
            tx.execute(
                "INSERT INTO listing (section, position, topic_id, filters, curated_reason) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![section.as_str(), pos as i64, t.row.id, serde_json::to_string(&t.filters)?, t.curated_reason],
            )?;
            list_section.entry(t.row.id).or_insert(section);
        }
        tx.execute(
            "INSERT INTO listing_meta (section, updated, filters) VALUES (?1, ?2, ?3)",
            params![
                section.as_str(),
                list.updated,
                serde_json::to_string(&list.filters)?
            ],
        )?;
        match section {
            Section::Video => report.video = list.topics.len(),
            Section::Games => report.games = list.topics.len(),
            Section::Indexers | Section::Albums => {}
        }
    }

    if let Some(search) = read::<BTreeMap<String, SearchEntry>>(&legacy.plab, "search.json")? {
        for e in search.values() {
            let at = e.at as i64;
            if now - at > SEARCH_TTL {
                continue;
            }
            upsert_topic(tx, &e.row, to_json(&e.images)?.as_deref(), None, now)?;
            tx.execute(
                "INSERT INTO search_hit (topic_id, at) VALUES (?1, ?2)
                 ON CONFLICT(topic_id) DO UPDATE SET at = excluded.at",
                params![e.row.id, at],
            )?;
            report.search += 1;
        }
    }

    let known_title = |id: u64| -> Result<String> {
        Ok(tx
            .query_row("SELECT title FROM topic WHERE id = ?1", [id], |r| r.get(0))
            .or_else(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => Ok(String::new()),
                e => Err(e),
            })?)
    };

    if let Some(ids) = read::<Vec<u64>>(&legacy.plab, "added.json")? {
        for id in ids {
            let section = list_section.get(&id).copied().unwrap_or(Section::Video);
            let n = tx.execute(
                "INSERT OR IGNORE INTO download (source, topic_id, release_title, section, download_dir, state, added_at)
                 VALUES ('plab', ?1, ?2, ?3, NULL, 'added', NULL)",
                params![id, known_title(id)?, section.as_str()],
            )?;
            report.added += n;
        }
    }

    for (section, file) in [
        (Section::Video, "queued.json"),
        (Section::Games, "games-queued.json"),
    ] {
        let Some(ids) = read::<Vec<u64>>(&legacy.plab, file)? else {
            continue;
        };
        for (i, id) in ids.into_iter().enumerate() {
            // The unique topic index drops ids that are already added (or queued elsewhere).
            let n = tx.execute(
                "INSERT OR IGNORE INTO download (source, topic_id, release_title, section, state, queued_at)
                 VALUES ('plab', ?1, ?2, ?3, 'queued', ?4)",
                params![id, known_title(id)?, section.as_str(), now + i as i64],
            )?;
            report.queued += n;
        }
    }

    match std::fs::read_to_string(legacy.plab.join("cookies.txt")) {
        Ok(text) => {
            tx.execute(
                "INSERT INTO kv (key, value, rev) VALUES ('tracker_cookies_netscape', ?1, COALESCE((SELECT max(rev) FROM kv), 0) + 1)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, rev = excluded.rev",
                [text],
            )?;
            report.cookies = true;
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => bail!(
            "legacy import: {}: {e}",
            legacy.plab.join("cookies.txt").display()
        ),
    }

    if let Some(state) = read::<GrabState>(&legacy.vault_grab, "state.json")? {
        for (studio, keys) in &state.studios {
            for (key, e) in keys {
                tx.execute(
                    "INSERT OR REPLACE INTO grab_seen (studio, scene_key, title, at) VALUES (?1, ?2, ?3, ?4)",
                    params![studio, key, e.title, e.at],
                )?;
                report.grab_keys += 1;
            }
        }
    }

    let mut scenes: HashSet<String> = HashSet::new();
    if let Some(ids) = read::<Vec<String>>(&legacy.stash_identify, "attempted.json")? {
        for id in ids {
            tx.execute(
                "INSERT INTO identify_attempt (scene_id, done) VALUES (?1, 1) ON CONFLICT(scene_id) DO UPDATE SET done = 1",
                [&id],
            )?;
            scenes.insert(id);
        }
    }
    if let Some(failures) = read::<BTreeMap<String, i64>>(&legacy.stash_identify, "failures.json")?
    {
        for (id, n) in failures {
            tx.execute(
                "INSERT INTO identify_attempt (scene_id, failures) VALUES (?1, ?2) ON CONFLICT(scene_id) DO UPDATE SET failures = excluded.failures",
                params![id, n],
            )?;
            scenes.insert(id);
        }
    }
    report.identify = scenes.len();

    tracing::info!("imported legacy state: {report:?}");
    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::super::{Db, USER_VERSION};
    use super::*;
    use std::fs;

    const NOW: i64 = 1_700_001_000;

    struct Dirs {
        _root: tempfile::TempDir,
        legacy: LegacyPaths,
        db: PathBuf,
    }

    fn dirs() -> Dirs {
        let root = tempfile::tempdir().unwrap();
        let legacy = LegacyPaths {
            plab: root.path().join("plab"),
            stash_identify: root.path().join("identify"),
            vault_grab: root.path().join("grab"),
        };
        for d in [&legacy.plab, &legacy.stash_identify, &legacy.vault_grab] {
            fs::create_dir_all(d).unwrap();
        }
        let db = root.path().join("state.db");
        Dirs {
            _root: root,
            legacy,
            db,
        }
    }

    fn topic_json(id: u64, title: &str, extra: &str) -> String {
        format!(
            r#"{{"id":{id},"title":"{title}","forum":1875,"size":100,"seeders":3,"leechers":1,"completed":7,"added":1700000000,
               "images":["https://i/{id}.jpg"],"filters":["Fav"],"curated_reason":"why"{extra}}}"#
        )
    }

    fn write(d: &Path, name: &str, text: &str) {
        fs::write(d.join(name), text).unwrap();
    }

    fn full(d: &Dirs) {
        let p = &d.legacy.plab;
        let pro = r#","production":{"class":"pro","confidence":0.9}"#;
        write(
            p,
            "cache.json",
            &format!(
                r#"{{"updated":1700000100,"filters":["Fav","Other"],"topics":[{},{}]}}"#,
                topic_json(1, "one", pro),
                topic_json(2, "two", "")
            ),
        );
        write(
            p,
            "games.json",
            &format!(
                r#"{{"updated":1700000200,"topics":[{}]}}"#,
                topic_json(3, "three", "")
            ),
        );
        write(
            p,
            "search.json",
            &format!(
                r#"{{"4":{{"id":4,"title":"four","forum":1,"size":1,"seeders":1,"leechers":0,"completed":0,"added":5,"images":null,"at":{}.5}}}}"#,
                NOW - 10
            ),
        );
        write(p, "added.json", "[3, 99]");
        write(p, "queued.json", "[2, 1, 3]");
        write(p, "games-queued.json", "[50]");
        write(p, "cookies.txt", "# Netscape HTTP Cookie File\n");
        write(
            &d.legacy.vault_grab,
            "state.json",
            r#"{"studios":{"StudioL":{"ep:1":{"at":"2026-10-24T00:00:00+00:00","title":"T1"},"name:abcdefgh":{"at":"2026-10-24T00:00:00+00:00","title":"T1"}}}}"#,
        );
        write(&d.legacy.stash_identify, "attempted.json", r#"["7","8"]"#);
        write(
            &d.legacy.stash_identify,
            "failures.json",
            r#"{"8":2,"9":1}"#,
        );
    }

    /// Run the import in a fresh database at a fixed `now`, as migration 1 would.
    fn import(d: &Dirs) -> Result<ImportReport> {
        let mut conn = rusqlite::Connection::open(&d.db)?;
        let tx = conn.transaction()?;
        tx.execute_batch(include_str!("schema.sql"))?;
        let r = run(&tx, &d.legacy, NOW)?;
        tx.pragma_update(None, "user_version", 1)?;
        tx.commit()?;
        Ok(r)
    }

    #[test]
    fn imports_everything() {
        let d = dirs();
        full(&d);
        let report = import(&d).unwrap();
        assert_eq!(
            report,
            ImportReport {
                video: 2,
                games: 1,
                search: 1,
                added: 2,
                queued: 3,
                grab_keys: 2,
                identify: 3,
                cookies: true
            }
        );
        let db = Db::open(&d.db).unwrap();
        let v = db.listing(Section::Video).unwrap();
        assert_eq!(v.updated, 1700000100);
        assert_eq!(v.filters, vec!["Fav".to_string(), "Other".into()]);
        assert_eq!(
            v.topics.iter().map(|t| t.topic.row.id).collect::<Vec<_>>(),
            vec![1, 2]
        );
        assert_eq!(
            v.topics[0].topic.images,
            Some(vec!["https://i/1.jpg".to_string()])
        );
        assert_eq!(
            v.topics[0].topic.production,
            Some(Production {
                class: "pro".into(),
                confidence: Some(0.9)
            })
        );
        assert_eq!(v.topics[0].filters, vec!["Fav".to_string()]);
        assert_eq!(v.topics[0].curated_reason.as_deref(), Some("why"));
        let g = db.listing(Section::Games).unwrap();
        assert_eq!(g.filters, Vec::<String>::new());
        assert_eq!(g.topics.len(), 1);
        let s = db.search_topics(NOW).unwrap();
        assert_eq!(s[&4].row.title, "four");
        assert_eq!(s[&4].images, None);
        assert_eq!(db.added().unwrap(), [3u64, 99].into_iter().collect());
        assert_eq!(db.queued(Section::Video).unwrap(), vec![2, 1]);
        assert_eq!(db.queued(Section::Games).unwrap(), vec![50]);
        let k = |v: &[&str]| v.iter().map(|s| s.to_string()).collect();
        assert!(db.grabbed("StudioL", &k(&["name:abcdefgh"])).unwrap());
        assert!(db.identify_done("7").unwrap());
        assert!(db.identify_done("8").unwrap());
        assert!(!db.identify_done("9").unwrap());
        assert!(!db.identify_fail("9").unwrap()); // imported 1 failure, now 2
        assert!(db.identify_fail("9").unwrap()); // the third gives up
        assert_eq!(
            db.kv_get("tracker_cookies_netscape").unwrap().unwrap().0,
            "# Netscape HTTP Cookie File\n"
        );
    }

    #[test]
    fn added_topics_take_section_and_title_from_the_lists() {
        let d = dirs();
        full(&d);
        import(&d).unwrap();
        let conn = rusqlite::Connection::open(&d.db).unwrap();
        let row = |id: i64| -> (String, String, Option<String>, Option<i64>) {
            conn.query_row(
                "SELECT section, release_title, download_dir, added_at FROM download WHERE topic_id = ?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap()
        };
        assert_eq!(row(3), ("games".into(), "three".into(), None, None));
        assert_eq!(row(99), ("video".into(), "".into(), None, None));
    }

    #[test]
    fn missing_files_are_skipped() {
        let d = dirs();
        assert_eq!(import(&d).unwrap(), ImportReport::default());
        let db = Db::open_with(&d.db, Some(&d.legacy)).unwrap();
        assert_eq!(db.user_version().unwrap(), USER_VERSION);
        let d2 = dirs();
        let db = Db::open_with(&d2.db, Some(&d2.legacy)).unwrap();
        assert_eq!(db.user_version().unwrap(), USER_VERSION);
        assert!(db.added().unwrap().is_empty());
    }

    #[test]
    fn corrupt_file_aborts_and_rolls_back() {
        let d = dirs();
        full(&d);
        write(&d.legacy.plab, "added.json", "[1,");
        let err = Db::open_with(&d.db, Some(&d.legacy))
            .err()
            .expect("must fail");
        assert!(format!("{err:#}").contains("added.json"), "{err:#}");
        let conn = rusqlite::Connection::open(&d.db).unwrap();
        assert_eq!(
            conn.pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
                .unwrap(),
            0
        );
        let tables: i64 = conn
            .query_row(
                "SELECT count(*) FROM sqlite_master WHERE type = 'table'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(tables, 0);
        drop(conn);
        write(&d.legacy.plab, "added.json", "[3]");
        let db = Db::open_with(&d.db, Some(&d.legacy)).unwrap();
        assert_eq!(db.user_version().unwrap(), USER_VERSION);
        assert_eq!(db.added().unwrap(), [3u64].into_iter().collect());
    }

    #[test]
    fn queued_already_added_is_dropped() {
        let d = dirs();
        write(&d.legacy.plab, "added.json", "[5]");
        write(&d.legacy.plab, "queued.json", "[5, 6]");
        write(&d.legacy.plab, "games-queued.json", "[6, 7]");
        let r = import(&d).unwrap();
        assert_eq!((r.added, r.queued), (1, 2));
        let db = Db::open(&d.db).unwrap();
        assert_eq!(db.queued(Section::Video).unwrap(), vec![6]);
        assert_eq!(db.queued(Section::Games).unwrap(), vec![7]);
        assert_eq!(db.added().unwrap(), [5u64].into_iter().collect());
    }

    #[test]
    fn expired_search_entries_are_skipped() {
        let d = dirs();
        let e = |id: u64, at: i64| {
            format!(
                r#""{id}":{{"id":{id},"title":"t","forum":1,"size":1,"seeders":1,"leechers":0,"completed":0,"added":5,"images":null,"at":{at}.0}}"#
            )
        };
        write(
            &d.legacy.plab,
            "search.json",
            &format!(
                "{{{},{},{}}}",
                e(1, NOW - SEARCH_TTL),
                e(2, NOW - SEARCH_TTL - 1),
                e(3, NOW)
            ),
        );
        let r = import(&d).unwrap();
        assert_eq!(r.search, 2);
        let db = Db::open(&d.db).unwrap();
        let mut ids: Vec<u64> = db.search_topics(NOW).unwrap().into_keys().collect();
        ids.sort();
        assert_eq!(ids, vec![1, 3]);
    }

    #[test]
    fn concurrent_opens_import_once() {
        let d = dirs();
        write(&d.legacy.plab, "queued.json", "[1, 2]");
        let barrier = std::sync::Barrier::new(2);
        std::thread::scope(|s| {
            let hs: Vec<_> = (0..2)
                .map(|_| {
                    s.spawn(|| {
                        barrier.wait();
                        Db::open_with(&d.db, Some(&d.legacy)).map(|_| ())
                    })
                })
                .collect();
            for h in hs {
                h.join().unwrap().unwrap();
            }
        });
        let db = Db::open(&d.db).unwrap();
        assert_eq!(db.user_version().unwrap(), USER_VERSION);
        assert_eq!(db.queued(Section::Video).unwrap(), vec![1, 2]);
    }
}
