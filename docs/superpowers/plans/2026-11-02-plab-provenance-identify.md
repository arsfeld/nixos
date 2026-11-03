# plab provenance identify, Stash status and tracker covers: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Link every new Stash scene to the plab/grab download it came from, and use that
link three ways: identify from the release title and grab studio, show each download's
status on the plab page, and use the tracker post's image as the cover when no scrape
supplies one.

**Architecture:** A new `download_file` table maps each download's library-relative file
paths, later with the Stash scene and the identify outcome. `provenance::sync` fills it
from Transmission's `torrent-get` by hash. It runs at the start of every identify pass,
and in prune before anything is removed. Identify looks a scene's path up in that table
to get a `Provenance` (title, studio, forced?, cover). The page derives a `Status` per
download from the database plus one live Transmission call.

**Tech Stack:** Rust (tokio, axum, rusqlite, reqwest, serde_json, wiremock for tests),
in `packages/plab`. NixOS module `modules/hosts/galactica/services/plab/default.nix`.

**Spec:** `docs/superpowers/specs/2026-11-02-plab-provenance-identify-design.md`

## Global Constraints

- Work on `master`, no branches or worktrees. Commit after each task with a conventional
  commit, scope `galactica`, e.g. `feat(galactica): plab …`. Never mention Claude.
- Run tests from `packages/plab` with `cargo test` (cargo is on PATH; baseline 520 pass).
  `cargo clippy --all-targets -- -D warnings` must stay clean. `cargo test` also runs in
  the Nix build's checkPhase, so a failing test fails galactica's build.
- Only scenes that appear after deploy are affected; never relink or re-identify existing
  ones.
- Unlinked scenes must behave exactly as today: `Llm::parse(path)`, no studio filter.
- Status windows: stalled after **3 days** without activity, lost after **2 days** with no
  scene, live lookup covers downloads from the last **30 days**, Recent grabs shows
  **14 days**, covers deleted after **90 days**, live Transmission call timeout **2 s**.
- Outcome strings are exactly `stash`, `scrape`, `llm`, `none`, `gave-up`.
- The schema migration is additive (new table, two new columns), so rollback is a revert.
- The golden pages (`tests/fixtures/golden_page*.html`) must stay byte-identical: the
  status badge is added only for downloads with a status, which the golden state does not
  have, and the Recent grabs strip renders nothing when empty.

### Deliberate refinements of the spec (apply them to the spec in Task 10)

1. Sync stores **every** completed file path (no video-extension filter): non-video
   paths never match a scene, so filtering only added a Stash dependency to prune.
2. The Transmission method is `TorrentClient::details(hashes)` returning `Detail`.
3. `download.cover` holds the cover's **absolute path**; covers are deleted 90 days after
   `added_at`, with no check on outcomes.
4. The card keeps its "Added ✓" button; the status is a badge **beside** it. That keeps
   the page JS unchanged and the goldens byte-identical, so they are not regenerated.
5. `identify::Clients` gains a `T: TorrentClient` parameter and `torrents: Option<&T>`.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/db/schema_v2.sql` (new) | v2 DDL: `download_file`, `download.files_synced`, `download.cover` |
| `src/db/mod.rs` | stepwise migration; download_file / cover / status-row accessors |
| `src/transmission.rs` | `Detail`, `TorrentFile`, `TorrentClient::details`, `hashString` in `FIELDS` |
| `src/provenance.rs` (new) | `sync`, `library_paths`, `Provenance`, `link`, `outcome_label`, `Status`, `status` |
| `src/provenance_tests.rs` (new) | tests for the above |
| `src/prune.rs`, `src/commands.rs` | prune syncs before removing; wiring of db/paths |
| `src/llm.rs` | `Llm::parse_with_title`, `TITLE_NOTE` |
| `src/identify/mod.rs`, `src/identify/matching.rs`, `src/identify/watch.rs` | link, provenance-aware parse, forced studio, outcomes, cover in `apply` |
| `src/stash.rs` | `SCENE_FIELDS` carries `studio { id name }` |
| `src/plab.rs` | `save_cover` on add; `prune_covers` in refresh |
| `src/page.rs`, `src/web.rs` | status badge, Recent grabs strip, async page with live lookup |
| `src/main.rs` | `mod provenance;` |
| `modules/hosts/galactica/services/plab/default.nix` | header comment names the new design |

---

### Task 1: Schema v2 and download_file accessors

**Files:**
- Create: `packages/plab/src/db/schema_v2.sql`
- Modify: `packages/plab/src/db/mod.rs` (constants at top, `migrate` at ~135, new methods after `mark_added` ~456, tests module)

**Interfaces:**
- Produces:
  - `pub struct Link { pub download_id: i64, pub source: String, pub release_title: String, pub grab_studio: Option<String>, pub cover: Option<String> }`
  - `Db::unsynced_downloads(&self) -> Result<Vec<(i64, String)>>` (id, hash)
  - `Db::save_files(&self, download_id: i64, paths: &[String]) -> Result<()>`
  - `Db::unsynced_among(&self, hashes: &[String]) -> Result<HashSet<String>>`
  - `Db::link_scene(&self, path: &str, scene_id: Option<&str>) -> Result<Option<Link>>` (None scene_id = read only)
  - `Db::record_outcome(&self, scene_id: &str, outcome: &str, label: Option<&str>) -> Result<()>`

- [ ] **Step 1: Write the failing tests** (append to the `tests` module in `db/mod.rs`; replace `migrations_set_user_version`)

```rust
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
        assert_eq!(db.user_version().unwrap(), 2);
        drop(db);
        assert_eq!(
            Db::open(&dir.path().join("state.db")).unwrap().user_version().unwrap(),
            2
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
            c.pragma_update(None, "user_version", 1).unwrap();
        }
        let db = Db::open(&p).unwrap();
        assert_eq!(db.user_version().unwrap(), 2);
        assert_eq!(db.unsynced_downloads().unwrap(), vec![(1, "h1".to_string())]);
    }

    #[test]
    fn save_files_marks_synced_and_link_finds_the_download() {
        let db = Db::open_in_memory().unwrap();
        let id = added(&db, "grab", None, "Rel", Some("h1"));
        db.record_grab("Studio A", &BTreeSet::from(["ep:1".to_string()]), "Rel", "x", Some(id))
            .unwrap();
        assert_eq!(db.unsynced_downloads().unwrap(), vec![(id, "h1".to_string())]);
        db.save_files(id, &["Studio A/Rel/a.mp4".into(), "Studio A/Rel/a.nfo".into()])
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

        assert!(db.link_scene("Studio A/Rel/a.mp4", Some("7")).unwrap().is_some());
        db.record_outcome("7", "scrape", Some("Title · Studio A")).unwrap();
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/plab && cargo test db::tests 2>&1 | tail -20`
Expected: compile errors (`unsynced_downloads`, `save_files`, `link_scene`, `record_outcome`, `unsynced_among` not found).

- [ ] **Step 3: Write the migration and the accessors**

`src/db/schema_v2.sql`:

```sql
CREATE TABLE download_file (
  download_id INTEGER NOT NULL REFERENCES download(id),
  path TEXT NOT NULL,              -- library-relative, the form Paths::rel_path gives
  scene_id TEXT,                   -- set once a Stash scene with this path is seen
  outcome TEXT,                    -- 'stash' | 'scrape' | 'llm' | 'none' | 'gave-up'
  label TEXT,                      -- "Title · Studio": what it was identified as
  PRIMARY KEY (download_id, path)
);
CREATE INDEX download_file_path ON download_file(path);
CREATE INDEX download_file_scene ON download_file(scene_id);
ALTER TABLE download ADD COLUMN files_synced INTEGER NOT NULL DEFAULT 0;
ALTER TABLE download ADD COLUMN cover TEXT;  -- absolute path of the copied tracker image
```

In `db/mod.rs`, replace the constants and `migrate`'s body:

```rust
const SCHEMA: &str = include_str!("schema.sql");
const SCHEMA_V2: &str = include_str!("schema_v2.sql");
const USER_VERSION: i64 = 2;
```

```rust
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
    tx.pragma_update(None, "user_version", USER_VERSION)?;
    tx.commit()?;
    Ok(())
}
```

Next to `NewDownload`:

```rust
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
```

After `mark_added`, a `// provenance` section:

```rust
    // provenance

    /// Added downloads whose files are not recorded yet: (id, torrent hash).
    pub fn unsynced_downloads(&self) -> Result<Vec<(i64, String)>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT id, torrent_hash FROM download
                 WHERE state = 'added' AND torrent_hash IS NOT NULL AND files_synced = 0 ORDER BY id",
            )?;
            Ok(stmt
                .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?)
        })
    }

    /// Record a finished download's library-relative file paths; it is synced from now on.
    pub fn save_files(&self, download_id: i64, paths: &[String]) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for p in paths {
                tx.execute(
                    "INSERT OR IGNORE INTO download_file (download_id, path) VALUES (?1, ?2)",
                    params![download_id, p],
                )?;
            }
            tx.execute("UPDATE download SET files_synced = 1 WHERE id = ?1", [download_id])?;
            tx.commit()?;
            Ok(())
        })
    }

    /// Those of `hashes` that belong to a download whose files are not recorded yet.
    pub fn unsynced_among(&self, hashes: &[String]) -> Result<HashSet<String>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT 1 FROM download WHERE torrent_hash = ?1 AND state = 'added' AND files_synced = 0",
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
```

The test reads the table through `db.with`; it is private but tests live in the same module, so that compiles.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass (the existing import tests still pass, since a fresh db runs v1 then v2).

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/db/schema_v2.sql packages/plab/src/db/mod.rs
git commit -m "feat(galactica): plab schema v2 records each download's files and their scenes"
```

---

### Task 2: Transmission `details` by hash

**Files:**
- Modify: `packages/plab/src/transmission.rs`

**Interfaces:**
- Produces:
  - `pub struct TorrentFile { pub name: String }`
  - `pub struct Detail { pub hash_string: String, pub download_dir: String, pub percent_done: f64, pub error: i64, pub error_string: String, pub activity_date: i64, pub files: Vec<TorrentFile> }` (Deserialize, Clone, Debug)
  - `TorrentClient::details(&self, hashes: &[String]) -> impl Future<Output = Result<Vec<Detail>>> + Send` with a default body returning `Ok(vec![])`, so the existing test fakes need no change
  - `Torrent.hash_string: String` (serde default), `FIELDS` gains `"hashString"` (now 9 entries)

- [ ] **Step 1: Write the failing tests** (in `transmission.rs`'s tests module)

```rust
    #[tokio::test]
    async fn details_asks_by_hash_for_files() {
        let s = stub(json!({"result": "success", "arguments": {"torrents": [{
            "hashString": "abcd", "downloadDir": "/d", "percentDone": 1.0, "error": 0,
            "errorString": "", "activityDate": 9,
            "files": [{"name": "Rel/a.mp4", "length": 5, "bytesCompleted": 5}]}]}}))
        .await;
        let got = Transmission::new(&s.uri())
            .details(&["abcd".into()])
            .await
            .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].hash_string, "abcd");
        assert_eq!(got[0].files[0].name, "Rel/a.mp4");
        let (_, body) = sent(&s, 1);
        assert_eq!(body["method"], "torrent-get");
        assert_eq!(body["arguments"]["ids"], json!(["abcd"]));
        assert!(body["arguments"]["fields"].as_array().unwrap().contains(&json!("files")));
    }

    #[tokio::test]
    async fn details_of_no_hashes_makes_no_call() {
        // torrent-get with an empty ids list would answer every torrent.
        let s = stub(json!({"result": "success", "arguments": {"torrents": []}})).await;
        assert!(Transmission::new(&s.uri()).details(&[]).await.unwrap().is_empty());
        assert!(s.received_requests().await.unwrap().is_empty());
    }
```

In `torrents_lists_with_fields`, add `"hashString": "h1"` to the stubbed torrent and assert:

```rust
        assert_eq!(list[0].hash_string, "h1");
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/plab && cargo test transmission:: 2>&1 | tail -15`
Expected: compile error, no `details` method / `hash_string` field.

- [ ] **Step 3: Implement**

```rust
/// What `torrents` asks for: the fields prune::decide reads, and the hash prune syncs by.
pub const FIELDS: [&str; 9] = [
    "id",
    "name",
    "hashString",
    "downloadDir",
    "percentDone",
    "uploadRatio",
    "doneDate",
    "activityDate",
    "trackers",
];

/// What `details` asks for.
pub const DETAIL_FIELDS: [&str; 7] = [
    "hashString",
    "downloadDir",
    "percentDone",
    "error",
    "errorString",
    "activityDate",
    "files",
];
```

Add to `Torrent`:

```rust
    #[serde(default)]
    pub hash_string: String,
```

New types:

```rust
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
pub struct TorrentFile {
    /// Relative to the torrent's downloadDir; `.part` while unfinished.
    pub name: String,
}

/// One torrent's state and files, by hash.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Detail {
    pub hash_string: String,
    pub download_dir: String,
    pub percent_done: f64,
    #[serde(default)]
    pub error: i64,
    #[serde(default)]
    pub error_string: String,
    #[serde(default)]
    pub activity_date: i64,
    #[serde(default)]
    pub files: Vec<TorrentFile>,
}
```

In `trait TorrentClient`:

```rust
    /// The torrents with these hashes that are still in the client. Unknown hashes are
    /// simply absent from the reply.
    fn details(&self, _hashes: &[String]) -> impl Future<Output = Result<Vec<Detail>>> + Send {
        async { Ok(Vec::new()) }
    }
```

In `impl TorrentClient for Transmission`:

```rust
    async fn details(&self, hashes: &[String]) -> Result<Vec<Detail>> {
        if hashes.is_empty() {
            return Ok(vec![]); // an empty ids list means every torrent
        }
        let mut reply = self
            .call("torrent-get", json!({"ids": hashes, "fields": DETAIL_FIELDS}))
            .await?;
        let list = reply
            .get_mut("torrents")
            .map(Value::take)
            .ok_or_else(|| anyhow!("no torrents in reply"))?;
        Ok(serde_json::from_value(list)?)
    }
```

- [ ] **Step 4: Run all tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/transmission.rs
git commit -m "feat(galactica): plab asks transmission for a torrent's files by hash"
```

---

### Task 3: `provenance::sync`

**Files:**
- Create: `packages/plab/src/provenance.rs`, `packages/plab/src/provenance_tests.rs`
- Modify: `packages/plab/src/main.rs` (add `mod provenance;` beside the other `mod` lines)

**Interfaces:**
- Consumes: `Db::unsynced_downloads`, `Db::save_files` (Task 1); `TorrentClient::details`, `Detail` (Task 2); `identify::Paths { host, container }`.
- Produces:
  - `pub fn library_paths(paths: &Paths, d: &Detail) -> Vec<String>`
  - `pub async fn sync<C: TorrentClient>(db: &Db, torrents: &C, paths: &Paths, only: Option<&[String]>) -> anyhow::Result<usize>` (returns downloads synced)

- [ ] **Step 1: Write the failing tests** (`src/provenance_tests.rs`)

```rust
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
        FakeTorrents { details, fail: false, asked: Mutex::new(vec![]) }
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

pub(crate) fn detail(hash: &str, dir: &str, done: f64, files: &[&str]) -> Detail {
    Detail {
        hash_string: hash.into(),
        download_dir: dir.into(),
        percent_done: done,
        error: 0,
        error_string: String::new(),
        activity_date: 0,
        files: files.iter().map(|f| TorrentFile { name: f.to_string() }).collect(),
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
        let d = detail("h", &format!("{dl}/Studio A"), 1.0, &["Rel/a.mp4", "Rel/b.mp4.part"]);
        assert_eq!(library_paths(&paths, &d), vec!["Studio A/Rel/a.mp4".to_string()]);
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
            detail("h2", &format!("{dl}/Studio A"), 0.5, &["Busy/a.mp4.part"]),
        ]);
        assert_eq!(sync(&db, &t, &paths, None).await.unwrap(), 1);
        assert_eq!(db.unsynced_downloads().unwrap(), vec![(done + 1, "h2".to_string())]);
        let l = db.link_scene("Studio A/Done/a.mp4", None).unwrap().unwrap();
        assert_eq!(l.download_id, done);
    }

    #[tokio::test]
    async fn sync_only_asks_for_the_given_hashes_and_nothing_when_none_pending() {
        let (_t, paths, _dl) = library();
        let db = Db::open_in_memory().unwrap();
        add(&db, "grab", None, "A", "h1");
        add(&db, "grab", None, "B", "h2");
        let t = FakeTorrents::new(vec![]);
        sync(&db, &t, &paths, Some(&["h2".to_string()])).await.unwrap();
        sync(&db, &t, &paths, Some(&["zz".to_string()])).await.unwrap();
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
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/plab && cargo test provenance 2>&1 | tail -15`
Expected: compile error, `provenance` module / `sync` / `library_paths` missing.

- [ ] **Step 3: Implement** (`src/provenance.rs`)

```rust
//! Which download a Stash scene came from, and what became of each download.
//!
//! `sync` records a finished torrent's files (library-relative) from Transmission by hash.
//! It must run before prune takes a torrent out of Transmission, since the file list goes
//! with it: grabs are pruned as soon as they finish.
//!
//! Design: docs/superpowers/specs/2026-11-02-plab-provenance-identify-design.md

use std::collections::HashMap;
use std::path::PathBuf;

use crate::db::Db;
use crate::identify::Paths;
use crate::transmission::{Detail, TorrentClient};

fn canonical(p: &str) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| PathBuf::from(p))
}

/// A finished torrent's files as library-relative paths, the form `Paths::rel_path` gives a
/// Stash scene's. The download dir is canonicalized, since Downloads/Vault is a symlink to
/// the library. Unfinished (`.part`) files and files outside the library are left out.
pub fn library_paths(paths: &Paths, d: &Detail) -> Vec<String> {
    let dir = canonical(&d.download_dir);
    let root = canonical(&paths.host);
    let mut out = Vec::new();
    for f in &d.files {
        if f.name.ends_with(".part") {
            continue;
        }
        let full = dir.join(&f.name);
        match full.strip_prefix(&root) {
            Ok(rel) => out.push(rel.to_string_lossy().into_owned()),
            Err(_) => tracing::warn!("{} is outside the library {}", full.display(), root.display()),
        }
    }
    out
}

/// Record the files of every finished, not yet recorded download (only those with one of
/// `only`'s hashes, when given). Returns how many were recorded. An unfinished torrent, or
/// one Transmission no longer has, stays pending.
pub async fn sync<C: TorrentClient>(
    db: &Db,
    torrents: &C,
    paths: &Paths,
    only: Option<&[String]>,
) -> anyhow::Result<usize> {
    let pending: HashMap<String, i64> = db
        .unsynced_downloads()?
        .into_iter()
        .filter(|(_, h)| only.is_none_or(|o| o.contains(h)))
        .map(|(id, h)| (h, id))
        .collect();
    if pending.is_empty() {
        return Ok(0);
    }
    let mut hashes: Vec<String> = pending.keys().cloned().collect();
    hashes.sort();
    let mut n = 0;
    for d in torrents.details(&hashes).await? {
        let Some(id) = pending.get(&d.hash_string) else {
            continue;
        };
        if d.percent_done < 1.0 {
            continue;
        }
        db.save_files(*id, &library_paths(paths, &d))?;
        n += 1;
    }
    Ok(n)
}

#[cfg(test)]
#[path = "provenance_tests.rs"]
pub(crate) mod tests;
```

`pub(crate)` on the test module lets the prune and identify tests reuse its fakes
(`FakeTorrents`, `detail`, `library`, `add`).

- [ ] **Step 4: Run the tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass. (`Option::is_none_or` needs Rust ≥ 1.82; the crate already uses let-chains, so the toolchain is newer.)

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/provenance.rs packages/plab/src/provenance_tests.rs packages/plab/src/main.rs
git commit -m "feat(galactica): plab records a finished download's library files"
```

---

### Task 4: Prune records files before removing

**Files:**
- Modify: `packages/plab/src/prune.rs` (`run_prune` ~line 81, tests module)
- Modify: `packages/plab/src/commands.rs` (`prune_with`, its two callers in `serve` and `prune`)

**Interfaces:**
- Consumes: `provenance::sync`, `Db::unsynced_among`.
- Produces: `run_prune<C: TorrentClient>(c: &C, dirs: &[String], now: f64, dry_run: bool, record: Option<(&Db, &Paths)>) -> anyhow::Result<Vec<(i64, String, String)>>`, where the result lists what was actually removed (or would be, in a dry run).

- [ ] **Step 1: Write the failing tests** (prune.rs tests module; give its `Fake` a `details` override and hashes)

The `run_prune` fake is `struct Fake { torrents: Vec<Torrent>, removed: Mutex<Vec<Vec<i64>>> }`
at `prune.rs` ~line 311, built by `fake()` with torrent 1 (`"public"`, removed at once)
and torrent 2 (`"lab"`, kept seeding). Extend it:

```rust
    struct Fake {
        torrents: Vec<Torrent>,
        removed: Mutex<Vec<Vec<i64>>>,
        details: Vec<Detail>,
        details_fail: bool,
    }
```

```rust
        async fn details(&self, hashes: &[String]) -> anyhow::Result<Vec<Detail>> {
            if self.details_fail {
                anyhow::bail!("down");
            }
            Ok(self.details.iter().filter(|d| hashes.contains(&d.hash_string)).cloned().collect())
        }
```

In `fake()`, the `mk` closure sets `hash_string: format!("h{id}")`, and the struct literal
adds `details: vec![], details_fail: false`. The `T` builder used by the `decide` tests
(its `build`) sets `hash_string: String::new()`. Import `crate::db::Db` and
`crate::transmission::Detail` in the tests module. Then:

```rust
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
        f.details = vec![crate::provenance::tests::detail(&format!("h{id}"), &dl, 1.0, &["R/a.mp4"])];
        run_prune(&f, &[VAULT.into()], NOW as f64, false, Some((&db, &paths))).await.unwrap();
        assert!(db.link_scene("R/a.mp4", None).unwrap().is_some());
        assert_eq!(*f.removed.lock().unwrap(), vec![vec![id]]);
    }

    #[tokio::test]
    async fn run_prune_keeps_a_torrent_whose_files_could_not_be_recorded() {
        let (_t, paths, _dl) = crate::provenance::tests::library();
        let db = Db::open_in_memory().unwrap();
        let mut f = fake();
        let id = 1;
        recorded(&db, id);
        f.details_fail = true;
        let got = run_prune(&f, &[VAULT.into()], NOW as f64, false, Some((&db, &paths))).await.unwrap();
        assert!(got.is_empty());
        assert!(f.removed.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn run_prune_removes_torrents_plab_never_added() {
        let (_t, paths, _dl) = crate::provenance::tests::library();
        let db = Db::open_in_memory().unwrap();
        let mut f = fake();
        f.details_fail = true; // irrelevant: no download row needs syncing
        let got = run_prune(&f, &[VAULT.into()], NOW as f64, false, Some((&db, &paths))).await.unwrap();
        assert_eq!(got.len(), 1);
    }
```

Update the two existing `run_prune` test calls to pass `None` as the last argument.

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/plab && cargo test prune 2>&1 | tail -15`
Expected: compile error, `run_prune` takes 4 arguments.

- [ ] **Step 3: Implement**

`prune.rs`:

```rust
use crate::db::Db;
use crate::identify::Paths;

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
        let hash_of: std::collections::HashMap<i64, &str> =
            torrents.iter().map(|t| (t.id, t.hash_string.as_str())).collect();
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
```

`commands.rs`:

```rust
async fn prune_with(
    cfg: &Config,
    torrents: &Transmission,
    db: Option<&Db>,
    dry_run: bool,
) -> anyhow::Result<Vec<(i64, String, String)>> {
    let paths = app::paths(cfg);
    let record = db.map(|db| (db, &paths));
    prune_mod::run_prune(torrents, &prune_dirs(cfg)?, now_f64(), dry_run, record).await
}
```

Callers: in `serve`'s `Task::Prune`, `prune_with(&a.cfg, &a.transmission, Some(&a.db), false)`;
in `prune()`, the dry run passes `None`, the real run `Some(&db)`.

- [ ] **Step 4: Run all tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass, including the `commands` prune tests against wiremock (their Transmission
stub answers `torrent-get` for any arguments; their torrents have no download row, so
nothing is kept back).

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/prune.rs packages/plab/src/commands.rs packages/plab/src/provenance.rs
git commit -m "feat(galactica): plab prune records a download's files before removing it"
```

---

### Task 5: `Llm::parse_with_title`

**Files:**
- Modify: `packages/plab/src/llm.rs`, `packages/plab/src/identify/tests.rs` (FakeLlm)

**Interfaces:**
- Produces: `Llm::parse_with_title(&self, path: &str, title: &str, studio: Option<&str>) -> impl Future<Output = anyhow::Result<Value>> + Send`

- [ ] **Step 1: Write the failing test** (llm.rs tests)

```rust
    #[tokio::test]
    async fn parse_with_title_sends_title_file_and_studio() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(CHAT_PATH))
            .and(body_partial_json(json!({
                "messages": [
                    {"role": "system", "content": format!("{PARSE_PROMPT}\n\n{TITLE_NOTE}")},
                    {"role": "user", "content": json!({
                        "release_title": "[StudioA.com] Jane - Title [2026, 1080p]",
                        "file": "Studio A/Rel/a.mp4",
                        "studio": "Studio A",
                    }).to_string()},
                ],
            })))
            .respond_with(chat_reply(r#"{"studio": "Studio A", "query": "q"}"#))
            .expect(1)
            .mount(&server)
            .await;
        let v = client(&server)
            .await
            .parse_with_title(
                "Studio A/Rel/a.mp4",
                "[StudioA.com] Jane - Title [2026, 1080p]",
                Some("Studio A"),
            )
            .await
            .unwrap();
        assert_eq!(v["studio"], "Studio A");
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/plab && cargo test llm:: 2>&1 | tail -10`
Expected: compile error, no `TITLE_NOTE` / `parse_with_title`.

- [ ] **Step 3: Implement**

```rust
/// Appended to PARSE_PROMPT when the scene's download is known. PARSE_PROMPT itself stays
/// byte-identical to the Python's (prompts_match_the_python_text).
const TITLE_NOTE: &str = r#"The input is JSON: "release_title" is the title the release was
published under, and describes the whole download; "file" is this scene's path, which picks
it out when the download holds several scenes; "studio", when present, is the studio the
download is known to be from. Prefer the release title for names and dates, and the file
path to tell scenes of one download apart."#;
```

In `trait Llm`:

```rust
    /// `parse`, for a file whose download is known: its release title and, when known,
    /// its studio.
    fn parse_with_title(
        &self,
        path: &str,
        title: &str,
        studio: Option<&str>,
    ) -> impl std::future::Future<Output = anyhow::Result<Value>> + Send;
```

In `impl Llm for OpenRouter`:

```rust
    async fn parse_with_title(
        &self,
        path: &str,
        title: &str,
        studio: Option<&str>,
    ) -> anyhow::Result<Value> {
        let mut input = json!({"release_title": title, "file": path});
        if let Some(s) = studio {
            input["studio"] = json!(s);
        }
        self.chat_json(&format!("{PARSE_PROMPT}\n\n{TITLE_NOTE}"), &input.to_string())
            .await
    }
```

`FakeLlm` in `identify/tests.rs` gains `titled: Mutex<Vec<(String, String, Option<String>)>>` (initialize it in `llm()`) and:

```rust
    async fn parse_with_title(
        &self,
        path: &str,
        title: &str,
        studio: Option<&str>,
    ) -> anyhow::Result<Value> {
        self.titled
            .lock()
            .unwrap()
            .push((path.into(), title.into(), studio.map(str::to_string)));
        self.parse.clone().map_err(|f| f.err())
    }
```

- [ ] **Step 4: Run all tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/llm.rs packages/plab/src/identify/tests.rs
git commit -m "feat(galactica): plab parses a scene with its release title"
```

---

### Task 6: Identify links scenes and matches from provenance

**Files:**
- Modify: `packages/plab/src/provenance.rs`, `packages/plab/src/identify/mod.rs`, `packages/plab/src/identify/matching.rs`, `packages/plab/src/identify/watch.rs`, `packages/plab/src/identify/tests.rs`, `packages/plab/src/commands.rs`, `packages/plab/src/stash.rs`

**Interfaces:**
- Consumes: `Db::link_scene`, `Db::record_outcome` (Task 1), `provenance::sync` (Task 3), `Llm::parse_with_title` (Task 5).
- Produces:
  - `pub struct Provenance { pub title: String, pub studio: Option<String>, pub forced: bool, pub cover: Option<PathBuf> }`
  - `pub fn link(db: &Db, paths: &Paths, scene: &Value, write: bool) -> Option<Provenance>`
  - `pub fn outcome_label(title: Option<&str>, studio: Option<&str>) -> Option<String>`
  - `matching::studio_matches(c: &Value, name: &str) -> bool`
  - `Clients<'a, S, L, J, T>` with `pub torrents: Option<&'a T>`; every `<S: StashApi, L: Llm, J: CodeSearch>` in `identify/` and `watch.rs` gains `T: TorrentClient`
  - `identify_scene(c, scene, prov: Option<&Provenance>)`

- [ ] **Step 1: Thread `T` through `Clients` (mechanical, no behaviour change)**

In `identify/mod.rs`:

```rust
pub struct Clients<'a, S: StashApi, L: Llm, J: CodeSearch, T: TorrentClient> {
    pub stash: &'a S,
    pub llm: &'a L,
    pub codedb: Option<&'a J>,
    pub paths: &'a Paths,
    /// Transmission, for recording download files at the start of a pass; None in a
    /// dry run's tests.
    pub torrents: Option<&'a T>,
}
```

Then in `identify/mod.rs` and `identify/watch.rs` replace every
`<S: StashApi, L: Llm, J: CodeSearch>` with `<S: StashApi, L: Llm, J: CodeSearch, T: TorrentClient>`
and every `Clients<'_, S, L, J>` with `Clients<'_, S, L, J, T>` (use `sed -i`), and
import `crate::transmission::TorrentClient`. In `commands.rs`, `clients()` returns
`Clients<'a, Stash, OpenRouter, CodeDb, Transmission>` with `torrents: Some(&a.transmission)`,
and the one-shot `identify()` builds an `app::transmission(cfg)?` and passes
`torrents: Some(&torrents)`. In `identify/tests.rs`, `clients()` returns
`Clients<'a, FakeStash, FakeLlm, FakeCodeDb, crate::provenance::tests::FakeTorrents>` with
`torrents: None`, and the one direct `Clients {` construction gets `torrents: None` too.

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|error\["`
Expected: all pass. Commit:

```bash
git add -A packages/plab/src
git commit -m "refactor(galactica): plab identify clients carry the torrent client"
```

- [ ] **Step 2: Write the failing tests** (`identify/tests.rs`, new section at the end)

```rust
// --- provenance --------------------------------------------------------------------

use crate::provenance::tests::{FakeTorrents, add, detail};

/// A grab of "Studio A" whose file is the scene's, recorded and ready to link.
fn grabbed(db: &Db, path_in_library: &str) -> i64 {
    let id = add(db, "grab", None, "[StudioA.com] Jane - Real Title [2026, 1080p]", "h1");
    db.record_grab("Studio A", &std::collections::BTreeSet::from(["ep:1".to_string()]), "t", "x", Some(id))
        .unwrap();
    db.save_files(id, &[path_in_library.to_string()]).unwrap();
    id
}

fn studio_hit(title: &str, studio: &str, rid: &str) -> Value {
    scraped(title, studio, json!("2026-01-02"), json!(600), rid)
}

#[tokio::test]
async fn linked_scene_parses_with_the_release_title_and_forced_studio() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash::pass(vec![scene()]);
    let l = llm(json!({"studio": "Wrong", "title": "Real Title", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let titled = l.titled.lock().unwrap().clone();
    assert_eq!(
        titled,
        vec![(
            "dir/file.mp4".to_string(),
            "[StudioA.com] Jane - Real Title [2026, 1080p]".to_string(),
            Some("Studio A".to_string())
        )]
    );
    // nothing on the boxes: an llm guess, under the rule's studio, not the parse's
    let created = st.created();
    assert!(created.iter().any(|(k, v)| k == "studio" && v["name"] == "Studio A"), "{created:?}");
}

#[tokio::test]
async fn forced_studio_drops_another_studios_candidate() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash {
        results: [(CODEDB.to_string(), Ok(vec![studio_hit("Real Title", "Other Studio", "r1")]))]
            .into_iter()
            .collect(),
        ..FakeStash::pass(vec![scene()])
    };
    let l = llm(json!({"title": "Real Title", "date": "2026-01-02", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let up = &st.updates()[0];
    assert!(up.get("stash_ids").is_none_or(|s| s.as_array().unwrap().is_empty()), "{up}");
}

#[tokio::test]
async fn forced_studio_keeps_its_own_candidate() {
    // The forced studio also lets deterministic_match (same studio and date) pick it.
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash {
        results: [(CODEDB.to_string(), Ok(vec![studio_hit("Real Title", "Studio A", "r1")]))]
            .into_iter()
            .collect(),
        ..FakeStash::pass(vec![scene()])
    };
    let l = llm(json!({"title": "Real Title", "date": "2026-01-02", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert_eq!(st.updates()[0]["title"], "Real Title");
    assert!(!st.updates()[0]["stash_ids"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn hinted_studio_filters_nothing() {
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(9), "[StudioB.com] Jane - Real Title [2026, 1080p]", "h1");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    let st = FakeStash {
        results: [(CODEDB.to_string(), Ok(vec![studio_hit("Real Title", "Other Studio", "r1")]))]
            .into_iter()
            .collect(),
        ..FakeStash::pass(vec![scene()])
    };
    // The parse names the other studio, so deterministic_match picks its scene: only a
    // forced studio would have dropped it.
    let l = llm(json!({"studio": "Other Studio", "title": "Real Title", "date": "2026-01-02",
                       "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert!(l.titled.lock().unwrap()[0].2.is_some()); // the title's studio label, as a hint
    assert!(!st.updates()[0]["stash_ids"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn unlinked_scene_parses_the_path_as_before() {
    let db = Db::open_in_memory().unwrap();
    let st = FakeStash::pass(vec![scene()]);
    let l = llm(json!({"title": "T", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert!(l.titled.lock().unwrap().is_empty());
}

#[tokio::test]
async fn outcomes_are_recorded_for_linked_scenes() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash::pass(vec![scene()]);
    let l = llm(json!({"title": "Real Title", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let row = db.link_scene("dir/file.mp4", None).unwrap().unwrap();
    assert_eq!(row.download_id, 1);
    let (outcome, label): (Option<String>, Option<String>) = outcome_of(&db, "5");
    assert_eq!(outcome.as_deref(), Some("llm"));
    assert_eq!(label.as_deref(), Some("Real Title · Studio A"));
}

#[tokio::test]
async fn nothing_found_is_recorded_none() {
    // A grab always has its studio (so at least an llm guess); a plab add whose title has
    // no studio label can find nothing.
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(3), "x", "h2");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    let st = FakeStash::pass(vec![scene()]);
    let l = llm(json!({"performers": [], "query": ""}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert_eq!(outcome_of(&db, "5").0.as_deref(), Some("none"));
}

#[tokio::test]
async fn giving_up_is_recorded() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash::pass(vec![scene()]);
    let l = llm_failing(Fail::Msg("malformed"));
    for _ in 0..IDENTIFY_FAILURE_LIMIT {
        pass(&st, &l, None, &db, None, opts()).await;
    }
    assert_eq!(outcome_of(&db, "5").0.as_deref(), Some("gave-up"));
}

#[tokio::test]
async fn a_new_scene_stash_filled_is_recorded_stash() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let filled = merge(
        scene_id("11"),
        json!({"title": "From Fingerprint", "studio": {"id": "s1", "name": "Studio A"}}),
    );
    let st = FakeStash {
        scenes_dict: [("11".to_string(), filled)].into_iter().collect(),
        ..FakeStash::pass(vec![])
    };
    let l = llm(json!({}));
    pass(&st, &l, None, &db, Some(vec!["/mnt/storage/media/Vault/dir".into()]), opts()).await;
    let (outcome, label) = outcome_of(&db, "11");
    assert_eq!(outcome.as_deref(), Some("stash"));
    assert_eq!(label.as_deref(), Some("From Fingerprint · Studio A"));
}

#[tokio::test]
async fn a_pass_records_download_files_first() {
    let db = Db::open_in_memory().unwrap();
    add(&db, "grab", None, "R", "h1");
    let torrents = FakeTorrents::new(vec![detail("h1", "/mnt/storage/media/Vault", 1.0, &["dir/file.mp4"])]);
    let st = FakeStash::pass(vec![]);
    let l = llm(json!({}));
    let c = Clients { torrents: Some(&torrents), ..clients(&st, &l, None) };
    run_pass(&c, &db, &defaults(), None, &opts()).await.unwrap();
    assert_eq!(torrents.asked.lock().unwrap().len(), 1);
    assert!(db.link_scene("dir/file.mp4", None).unwrap().is_some());
}

fn manual_for(id: &str) -> PassOpts {
    PassOpts { scene_ids: Some(vec![id.to_string()]), ..manual() }
}

fn outcome_of(db: &Db, scene_id: &str) -> (Option<String>, Option<String>) {
    db.outcome_of(scene_id).unwrap()
}
```

and in `db/mod.rs` (`Db::with` is private to the db module):

```rust
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
```

Notes: `a_pass_records_download_files_first` relies on the default `Paths`
(`/mnt/storage/media/Vault`) not existing where tests run (the Nix sandbox, or raider):
`canonical` falls back to the literal path, so `library_paths` strips the literal prefix.
`opts()` is `jobs: true, dry_run: false`; `manual()` is the same with `jobs: false`.
`nothing_found` assumes `labels("x", 0).studio` is `None`; if it is not, pick a title that
yields none.

- [ ] **Step 3: Run them to verify they fail**

Run: `cd packages/plab && cargo test identify::tests 2>&1 | grep -E "^test .*(provenance|linked|forced|hinted|unlinked|outcome|nothing_found|giving_up|stash_filled|records_download)|error" | head -20`
Expected: compile errors (`link`, `Provenance`, …) or failures.

- [ ] **Step 4: Implement**

`provenance.rs`, add:

```rust
use serde_json::Value;

use crate::identify::matching::id_str;
use crate::labels::labels;

/// What a scene's download says about it.
#[derive(Debug, Clone, PartialEq)]
pub struct Provenance {
    /// The release title (tracker topic or Prowlarr result).
    pub title: String,
    /// A grab's rule studio, or the studio label of a plab add's title.
    pub studio: Option<String>,
    /// The studio is certain (a grab rule matched it): it overrides the parse and filters
    /// stash-box candidates.
    pub forced: bool,
    /// The copied tracker image (plab adds).
    pub cover: Option<PathBuf>,
}

impl From<crate::db::Link> for Provenance {
    fn from(l: crate::db::Link) -> Provenance {
        let grab = l.source == "grab";
        let studio = if grab {
            l.grab_studio
        } else {
            labels(&l.release_title, 0).studio // the forum only decides the category
        };
        Provenance {
            forced: grab && studio.is_some(),
            studio,
            title: l.release_title,
            cover: l.cover.map(PathBuf::from),
        }
    }
}

/// The scene's download, if its file came from one. With `write`, the file is linked to the
/// scene for the page's status. A database error is logged and counts as no download, so
/// the scene is identified as before.
pub fn link(db: &Db, paths: &Paths, scene: &Value, write: bool) -> Option<Provenance> {
    let path = scene.pointer("/files/0/path")?.as_str()?;
    let id = id_str(&scene["id"]);
    match db.link_scene(paths.rel_path(path), write.then_some(id.as_str())) {
        Ok(l) => l.map(Provenance::from),
        Err(e) => {
            tracing::warn!("[{id}] download lookup failed: {e:#}");
            None
        }
    }
}

/// "Title · Studio", either part optional; None when both are missing.
pub fn outcome_label(title: Option<&str>, studio: Option<&str>) -> Option<String> {
    let parts: Vec<&str> = [title, studio]
        .into_iter()
        .flatten()
        .filter(|s| !s.is_empty())
        .collect();
    (!parts.is_empty()).then(|| parts.join(" · "))
}
```

(Check `matching::id_str` is `pub`; it is imported by `identify/mod.rs` already.)

`matching.rs`:

```rust
fn squash(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect()
}

/// Whether a stash-box candidate is `name`'s scene: its studio, an alias of it, or its
/// parent network, compared without case, spaces or punctuation ("Studio A" = "StudioA").
pub fn studio_matches(c: &Value, name: &str) -> bool {
    let want = squash(name);
    let Some(s) = get(c, "studio").filter(|s| truthy(Some(s))) else {
        return false;
    };
    let names = [as_str(s.get("name")), s.get("parent").and_then(|p| as_str(p.get("name")))];
    let aliases = s
        .get("aliases")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(Value::as_str);
    names.into_iter().flatten().chain(aliases).any(|n| squash(n) == want)
}
```

with a unit test in `matching_tests.rs`:

```rust
#[test]
fn studio_matches_by_name_alias_or_parent() {
    let c = |s: serde_json::Value| serde_json::json!({"studio": s});
    assert!(studio_matches(&c(serde_json::json!({"name": "StudioA"})), "Studio A"));
    assert!(studio_matches(&c(serde_json::json!({"name": "X", "aliases": ["Studio-A"]})), "Studio A"));
    assert!(studio_matches(&c(serde_json::json!({"name": "X", "parent": {"name": "studio a"}})), "Studio A"));
    assert!(!studio_matches(&c(serde_json::json!({"name": "Other"})), "Studio A"));
    assert!(!studio_matches(&serde_json::json!({"studio": null}), "Studio A"));
}
```

`identify/mod.rs`:

1. `identify_scene` gains `prov: Option<&Provenance>` (import `crate::provenance::{self, Provenance}`). Replace the parse line and add the filter:

```rust
    let mut parse = match prov {
        Some(p) => c.llm.parse_with_title(path, &p.title, p.studio.as_deref()).await?,
        None => c.llm.parse(path).await?,
    };
    // A grab's studio is certain: it overrides the parse, and only its scenes are candidates.
    let forced = prov.filter(|p| p.forced).and_then(|p| p.studio.as_deref());
    if let (Some(s), Some(obj)) = (forced, parse.as_object_mut()) {
        obj.insert("studio".into(), Value::String(s.to_string()));
    }
```

and right after the search loop fills `everything`:

```rust
    if let Some(s) = forced {
        everything.retain(|(_, h)| matching::studio_matches(h, s));
    }
```

Update the two test helpers `identify`/`identify_with` and the direct calls at tests.rs ~815 and ~922 to pass `None`.

2. `stash_jobs` returns the new scene ids:

```rust
async fn stash_jobs<S: StashApi>(…) -> anyhow::Result<Vec<String>> {
    …
    Ok(new)
}
```

3. In `run_pass`, before the jobs:

```rust
    if !opts.dry_run
        && let Some(t) = c.torrents
        && let Err(e) = provenance::sync(db, t, c.paths, None).await
    {
        tracing::warn!("recording download files failed, continuing: {e:#}");
    }
    let mut new = Vec::new();
    if opts.jobs && !opts.dry_run {
        match stash_jobs(stash, c.paths, defaults, paths.as_ref()).await {
            Ok(ids) => new = ids,
            Err(e) => tracing::warn!("stash jobs failed, continuing to the LLM step: {e:#}"),
        }
    }
    if !new.is_empty() {
        record_new(c, db, &new).await;
    }
```

(replacing the existing `if opts.jobs && … stash_jobs` block), with:

```rust
/// Link the scenes a scan just made to their downloads; one Stash already filled (by
/// fingerprint) is done, and recorded as such. Failures are logged: the page's status is
/// all that depends on this.
async fn record_new<S: StashApi, L: Llm, J: CodeSearch, T: TorrentClient>(
    c: &Clients<'_, S, L, J, T>,
    db: &Db,
    ids: &[String],
) {
    let scenes = match c.stash.scenes(ids).await {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("reading new scenes failed: {e:#}");
            return;
        }
    };
    for s in &scenes {
        if provenance::link(db, c.paths, s, true).is_none() || !filled(s) {
            continue;
        }
        let label = provenance::outcome_label(
            s.get("title").and_then(Value::as_str),
            matching::studio_name(s).as_deref(),
        );
        if let Err(e) = db.record_outcome(&id_str(&s["id"]), "stash", label.as_deref()) {
            tracing::warn!("recording [{}] failed: {e:#}", id_str(&s["id"]));
        }
    }
}

/// Has a title, studio or performers: what `bare_scenes` leaves out.
fn filled(scene: &Value) -> bool {
    truthy(scene.get("title")) || truthy(scene.get("studio")) || truthy(scene.get("performers"))
}
```

Use `filled(&fresh)` in `pass_scene`'s `edited` computation instead of repeating the
three `truthy` calls.

4. In `run_pass`'s failure branch, when `db.identify_fail(&id)?` is true, before `continue`:

```rust
                db.record_outcome(&id, "gave-up", None)?;
```

5. `pass_scene`: link first and pass it on; record the outcome after `apply`:

```rust
    let prov = provenance::link(db, c.paths, scene, !opts.dry_run);
    let prop = if upgrade {
        …unchanged…
    } else {
        identify_scene(c, scene, prov.as_ref()).await?
    };
    …
    apply(c, &fresh, &prop, &skip, upgrade).await?;
    let (outcome, label) = outcome_of(&prop);
    db.record_outcome(id, outcome, label.as_deref())?;
    db.identify_mark_done(id)?;
```

```rust
/// The outcome and label `pass_scene` records for a proposal.
fn outcome_of(prop: &Proposal) -> (&'static str, Option<String>) {
    match prop.kind {
        Kind::Scrape => {
            let p = prop.primary.as_ref().unwrap_or(&Value::Null);
            (
                "scrape",
                provenance::outcome_label(str_of(p, "title"), matching::studio_name(p).as_deref()),
            )
        }
        Kind::Llm => {
            let q = prop.parse.as_ref().unwrap_or(&Value::Null);
            (
                "llm",
                provenance::outcome_label(
                    matching::display_title(q).as_deref(),
                    str_of(q, "studio"),
                ),
            )
        }
        Kind::None => ("none", None),
    }
}
```

6. `stash.rs`: `SCENE_FIELDS` gets `studio { id name }`, so `record_new` can label it. Run the stash tests; if one asserts the exact query text, update that string.

- [ ] **Step 5: Run all tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"` and `cargo clippy --all-targets -- -D warnings`
Expected: all pass, no warnings.

- [ ] **Step 6: Commit**

```bash
git add -A packages/plab/src
git commit -m "feat(galactica): plab identifies a scene from its download's title and studio"
```

---

### Task 7: Tracker covers

**Files:**
- Modify: `packages/plab/src/db/mod.rs`, `packages/plab/src/plab.rs`, `packages/plab/src/plab_tests.rs`, `packages/plab/src/identify/mod.rs`, `packages/plab/src/identify/tests.rs`

**Interfaces:**
- Consumes: `Provenance.cover` (Task 6), `mark_added` returning the download id.
- Produces:
  - `Db::set_cover(&self, download_id: i64, path: &str) -> Result<()>`
  - `Db::stale_covers(&self, before: i64) -> Result<Vec<(i64, String)>>`, `Db::clear_cover(&self, download_id: i64) -> Result<()>`
  - `plab::save_cover(ctx, topic_id: u64, download_id: i64, now: i64)` (async, logs its own errors)
  - `plab::prune_covers(db: &Db, now: i64)`
  - `apply(c, scene, prop, skip, overwrite, cover: Option<&Path>)`

- [ ] **Step 1: Write the failing tests**

`plab_tests.rs` (fixtures: `routes()` lists topic 1 with images `[COVER, "https://x/b.jpg"]`;
`FakeTracker::fetch` answers `JPEG`; `env.ctx(&lab)`; `NOW`):

```rust
#[tokio::test]
async fn add_copies_the_first_image_as_the_cover() {
    let env = routes();
    let lab = FakeTracker::new(vec![]);
    add_topic(&env.ctx(&lab), 1, NOW).await.unwrap();
    let covers = env.db.stale_covers(i64::MAX).unwrap();
    assert_eq!(covers.len(), 1);
    let (_, path) = &covers[0];
    assert!(path.ends_with("covers/1"), "{path}");
    assert_eq!(std::fs::read(path).unwrap(), JPEG);
}

#[tokio::test]
async fn prune_covers_deletes_old_ones() {
    let env = routes();
    let lab = FakeTracker::new(vec![]);
    add_topic(&env.ctx(&lab), 1, NOW).await.unwrap();
    let (_, path) = env.db.stale_covers(i64::MAX).unwrap()[0].clone();
    prune_covers(&env.db, NOW + 89 * 86400);
    assert!(std::path::Path::new(&path).exists());
    prune_covers(&env.db, NOW + 91 * 86400);
    assert!(!std::path::Path::new(&path).exists());
    assert!(env.db.stale_covers(i64::MAX).unwrap().is_empty());
}
```

An existing add or drain test that asserts the tracker fetched nothing (`lab.fetched`) now
sees the cover fetch: update that assertion to expect `COVER` rather than weakening it.

`identify/tests.rs`:

```rust
fn cover_file() -> (tempfile::TempDir, PathBuf) {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("1");
    std::fs::write(&p, b"\xff\xd8\xffJPEG").unwrap();
    (d, p)
}

#[tokio::test]
async fn tracker_cover_fills_an_llm_guess() {
    let (_d, cover) = cover_file();
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(1), "[StudioB.com] Jane - T [2026]", "h1");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    db.set_cover(id, cover.to_str().unwrap()).unwrap();
    let st = FakeStash::pass(vec![scene()]);
    let l = llm(json!({"title": "T", "performers": [], "query": ""}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let up = &st.updates()[0];
    assert!(up["cover_image"].as_str().unwrap().starts_with("data:image/jpeg;base64,"));
}

#[tokio::test]
async fn tracker_cover_alone_for_nothing_found() {
    let (_d, cover) = cover_file();
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(1), "x", "h1");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    db.set_cover(id, cover.to_str().unwrap()).unwrap();
    let st = FakeStash::pass(vec![scene()]);
    let l = llm(json!({"performers": [], "query": ""}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let up = &st.updates()[0];
    assert_eq!(up.as_object().unwrap().len(), 2, "{up}"); // id and cover_image only
}

#[tokio::test]
async fn a_scrape_image_wins_over_the_tracker_cover() {
    let (_d, cover) = cover_file();
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(1), "x", "h1");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    db.set_cover(id, cover.to_str().unwrap()).unwrap();
    let st = FakeStash {
        results: [(CODEDB.to_string(), Ok(vec![studio_hit("Real Title", "S", "r1")]))]
            .into_iter()
            .collect(),
        ..FakeStash::pass(vec![scene()])
    };
    let l = llm(json!({"title": "Real Title", "date": "2026-01-02", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert_eq!(st.updates()[0]["cover_image"], "data:img"); // scraped()'s image
}

#[tokio::test]
async fn a_missing_cover_file_is_skipped() {
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(1), "x", "h1");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    db.set_cover(id, "/nonexistent/cover").unwrap();
    let st = FakeStash::pass(vec![scene()]);
    let l = llm(json!({"title": "T", "performers": [], "query": ""}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert!(st.updates()[0].get("cover_image").is_none());
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/plab && cargo test cover 2>&1 | tail -15`
Expected: compile errors (`set_cover`, `stale_covers`, `prune_covers`).

- [ ] **Step 3: Implement**

`db/mod.rs`, in the provenance section:

```rust
    pub fn set_cover(&self, download_id: i64, path: &str) -> Result<()> {
        self.with(|c| {
            c.execute("UPDATE download SET cover = ?2 WHERE id = ?1", params![download_id, path])?;
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
            c.execute("UPDATE download SET cover = NULL WHERE id = ?1", [download_id])?;
            Ok(())
        })
    }
```

`plab.rs`:

```rust
/// How long a download's tracker cover is kept: identify uses it within hours.
pub const COVER_DAYS: i64 = 90;

/// Copy a just-added topic's first image out of the image cache, which forgets it once the
/// topic leaves the lists, to <state_dir>/covers/<download id>, for identify to use as the
/// scene's cover. The add has already happened, so a failure is only logged.
pub async fn save_cover<T: TrackerApi, C: TorrentClient>(
    ctx: &Ctx<'_, T, C>,
    topic_id: u64,
    download_id: i64,
    now: i64,
) {
    let result: anyhow::Result<()> = async {
        let images = topic_images(ctx, topic_id, now).await?;
        let Some(first) = images.first() else { return Ok(()) };
        let cached = ensure_image(ctx.tracker, ctx.images, first).await?;
        let dir = ctx.state_dir.join("covers");
        std::fs::create_dir_all(&dir)?;
        let dest = dir.join(download_id.to_string());
        std::fs::copy(&cached, &dest)?;
        ctx.db.set_cover(download_id, &dest.to_string_lossy())?;
        Ok(())
    }
    .await;
    if let Err(e) = result {
        warn!("cover for topic {topic_id}: {e:#}");
    }
}

/// Delete covers older than COVER_DAYS.
pub fn prune_covers(db: &Db, now: i64) {
    let stale = match db.stale_covers(now - COVER_DAYS * 86400) {
        Ok(s) => s,
        Err(e) => return warn!("covers: {e:#}"),
    };
    for (id, path) in stale {
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                warn!("cover {path}: {e}");
                continue;
            }
        }
        if let Err(e) = db.clear_cover(id) {
            warn!("cover {id}: {e:#}");
        }
    }
}
```

In `add_topic`, keep `mark_added`'s id and save the cover before returning:

```rust
    let download_id = ctx.db.mark_added(NewDownload { … })?;
    save_cover(ctx, topic_id, download_id, now).await;
    Ok(AddResult::Added { name: added.name })
```

In `drain_queue`, have the inner block return the id (`Ok(id)` after `mark_added`), and on
`Ok(id)` call `save_cover(ctx, topic_id, id, now).await` before logging `added`.

In `run_refresh`, after the queues drain and lists refresh (read it first; add it once,
just before its final return): `prune_covers(ctx.db, now);`.

`identify/mod.rs`:

```rust
/// The file as a `data:` URI for Stash's cover_image, or None (logged) if unreadable or not
/// an image.
fn cover_uri(path: &Path) -> Option<String> {
    use base64::Engine;
    let data = match std::fs::read(path) {
        Ok(d) => d,
        Err(e) => {
            tracing::info!("cover {}: {e}", path.display());
            return None;
        }
    };
    let ctype = crate::images::sniff(&data)?;
    Some(format!(
        "data:{ctype};base64,{}",
        base64::engine::general_purpose::STANDARD.encode(&data)
    ))
}

/// Add the tracker cover to an update that sets none.
fn with_cover(mut up: Value, cover: Option<&Path>) -> Value {
    if let (Some(path), Some(obj)) = (cover, up.as_object_mut())
        && !obj.contains_key("cover_image")
        && let Some(uri) = cover_uri(path)
    {
        obj.insert("cover_image".into(), Value::String(uri));
    }
    up
}
```

`apply` gains `cover: Option<&Path>`; wrap both `update_scene` arguments:
`stash.update_scene(&with_cover(matching::scrape_update(…), cover))` and likewise for
`llm_update`; and replace `Kind::None => Ok(())` with:

```rust
        Kind::None => {
            let up = with_cover(serde_json::json!({"id": scene["id"].clone()}), cover);
            if up.as_object().is_some_and(|o| o.len() > 1) {
                stash.update_scene(&up).await?;
            }
            Ok(())
        }
```

In `pass_scene`: `apply(c, &fresh, &prop, &skip, upgrade, prov.as_ref().and_then(|p| p.cover.as_deref())).await?;`.
Update the five `apply(` calls in `identify/tests.rs` with a trailing `None`. Import
`std::path::Path` in `identify/mod.rs`.

- [ ] **Step 4: Run all tests and clippy**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"; cargo clippy --all-targets -- -D warnings`
Expected: all pass, clean.

- [ ] **Step 5: Commit**

```bash
git add -A packages/plab/src
git commit -m "feat(galactica): plab uses the tracker post's image as a scene's cover"
```

---

### Task 8: Download status

**Files:**
- Modify: `packages/plab/src/db/mod.rs`, `packages/plab/src/provenance.rs`, `packages/plab/src/provenance_tests.rs`

**Interfaces:**
- Produces:
  - `pub struct FileRow { pub path: String, pub scene_id: Option<String>, pub outcome: Option<String>, pub label: Option<String> }`
  - `pub struct DownloadRow { pub id: i64, pub source: String, pub topic_id: Option<u64>, pub release_title: String, pub studio: Option<String>, pub state: String, pub hash: Option<String>, pub added_at: Option<i64>, pub files_synced: bool, pub files: Vec<FileRow> }` (in `db`)
  - `Db::download_rows(&self, since: i64) -> Result<Vec<DownloadRow>>` (queued, or added at/after `since`; newest first; studio from grab_seen)
  - `pub enum Failure { Transmission(String), Identify, Lost }`
  - `pub enum Status { Queued, Downloading(u8), Added, InStash, Identified { label: String, more: usize, guess: bool }, Failed(Failure) }`
  - `pub fn status(d: &DownloadRow, live: Option<&HashMap<String, Detail>>, now: i64) -> Status`
  - consts `STALLED_DAYS = 3`, `LOST_DAYS = 2`

- [ ] **Step 1: Write the failing tests** (`provenance_tests.rs`)

```rust
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
        DownloadRow { files_synced: true, files, ..row() }
    }

    #[test]
    fn queued() {
        let d = DownloadRow { state: "queued".into(), hash: None, added_at: None, ..row() };
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
        let old = DownloadRow { added_at: Some(NOW - 5 * 86400), ..row() };
        assert!(matches!(status(&old, Some(&live(t)), NOW), Status::Failed(Failure::Transmission(_))));
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
            Status::Identified { label: "A · S".into(), more: 1, guess: true }
        );
    }

    #[test]
    fn identify_failures() {
        for o in ["gave-up", "none"] {
            let d = synced(vec![file(Some("1"), Some("scrape"), Some("A")), file(Some("2"), Some(o), None)]);
            assert_eq!(status(&d, None, NOW), Status::Failed(Failure::Identify));
        }
    }

    #[test]
    fn in_stash() {
        let d = synced(vec![file(Some("1"), None, None)]);
        assert_eq!(status(&d, None, NOW), Status::InStash);
    }

    #[test]
    fn lost() {
        // never synced, and Transmission answered without it
        assert_eq!(status(&row(), Some(&HashMap::new()), NOW), Status::Failed(Failure::Lost));
        // synced, no scene after two days
        let old = DownloadRow { added_at: Some(NOW - 3 * 86400), ..synced(vec![file(None, None, None)]) };
        assert_eq!(status(&old, None, NOW), Status::Failed(Failure::Lost));
    }

    #[test]
    fn added_while_waiting_or_transmission_unknown() {
        assert_eq!(status(&row(), None, NOW), Status::Added); // lookup failed
        assert_eq!(status(&synced(vec![file(None, None, None)]), None, NOW), Status::Added);
        let no_hash = DownloadRow { hash: None, ..row() };
        assert_eq!(status(&no_hash, Some(&HashMap::new()), NOW), Status::Added);
    }

    #[test]
    fn download_rows_carry_files_and_grab_studio() {
        let db = Db::open_in_memory().unwrap();
        let id = add(&db, "grab", None, "R", "h1");
        db.record_grab("Studio A", &std::collections::BTreeSet::from(["ep:1".to_string()]), "R", "x", Some(id))
            .unwrap();
        db.save_files(id, &["a.mp4".into()]).unwrap();
        db.enqueue(5, crate::db::Section::Video, 900).unwrap();
        let rows = db.download_rows(0).unwrap();
        assert_eq!(rows.len(), 2);
        let g = rows.iter().find(|r| r.id == id).unwrap();
        assert_eq!(g.studio.as_deref(), Some("Studio A"));
        assert!(g.files_synced);
        assert_eq!(g.files[0].path, "a.mp4");
        assert!(rows.iter().any(|r| r.state == "queued" && r.topic_id == Some(5)));
        assert!(db.download_rows(2000).unwrap().iter().all(|r| r.state == "queued"));
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/plab && cargo test status_tests 2>&1 | tail -10`
Expected: compile errors.

- [ ] **Step 3: Implement**

`db/mod.rs` (types beside `Link`, method in the provenance section):

```rust
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
    pub files_synced: bool,
    pub files: Vec<FileRow>,
}
```

```rust
    /// Every queued download, and those added at or after `since`, newest first, with
    /// their files.
    pub fn download_rows(&self, since: i64) -> Result<Vec<DownloadRow>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT d.id, d.source, d.topic_id, d.release_title,
                        (SELECT g.studio FROM grab_seen g WHERE g.download_id = d.id LIMIT 1),
                        d.state, d.torrent_hash, d.added_at, d.files_synced
                 FROM download d
                 WHERE d.state = 'queued' OR d.added_at >= ?1
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
                        files_synced: r.get::<_, i64>(8)? != 0,
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
```

`provenance.rs`:

```rust
use crate::db::DownloadRow;

/// A torrent under 100% with no activity this long has stalled.
pub const STALLED_DAYS: i64 = 3;
/// A finished download with no Stash scene this long after it was added is lost.
pub const LOST_DAYS: i64 = 2;

#[derive(Debug, Clone, PartialEq)]
pub enum Failure {
    /// Transmission's error string, or "stalled".
    Transmission(String),
    /// identify gave up or found nothing.
    Identify,
    /// The torrent is gone and no scene came of it.
    Lost,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Status {
    Queued,
    Downloading(u8),
    /// In Transmission or finished, no scene yet.
    Added,
    InStash,
    Identified { label: String, more: usize, guess: bool },
    Failed(Failure),
}

/// A download's status. `live` is Transmission's reply for the recent downloads' hashes, or
/// None when it could not be asked; without it nothing is inferred from a torrent's absence.
/// Rules in order; the first that matches wins (spec, "Status").
pub fn status(d: &DownloadRow, live: Option<&HashMap<String, Detail>>, now: i64) -> Status {
    if d.state == "queued" {
        return Status::Queued;
    }
    let torrent = d.hash.as_ref().and_then(|h| live.and_then(|l| l.get(h)));
    if let Some(t) = torrent {
        if t.error != 0 {
            let why = if t.error_string.is_empty() { format!("error {}", t.error) } else { t.error_string.clone() };
            return Status::Failed(Failure::Transmission(why));
        }
        if t.percent_done < 1.0 {
            let last = t.activity_date.max(d.added_at.unwrap_or(0));
            if now - last > STALLED_DAYS * 86400 {
                return Status::Failed(Failure::Transmission("stalled".into()));
            }
            return Status::Downloading((t.percent_done * 100.0).floor() as u8);
        }
    }
    let linked: Vec<_> = d.files.iter().filter(|f| f.scene_id.is_some()).collect();
    let outcome = |f: &&crate::db::FileRow| f.outcome.as_deref();
    if linked.iter().any(|f| matches!(outcome(f), Some("gave-up" | "none"))) {
        return Status::Failed(Failure::Identify);
    }
    if !linked.is_empty() && linked.iter().all(|f| matches!(outcome(f), Some("stash" | "scrape" | "llm"))) {
        let labels: Vec<&str> = linked.iter().filter_map(|f| f.label.as_deref()).collect();
        return Status::Identified {
            label: labels.first().map_or_else(|| d.release_title.clone(), |l| l.to_string()),
            more: linked.len() - 1,
            guess: linked.iter().any(|f| outcome(f) == Some("llm")),
        };
    }
    if !linked.is_empty() {
        return Status::InStash;
    }
    let gone = d.hash.is_some() && live.is_some() && torrent.is_none();
    let old = d.added_at.is_some_and(|a| now - a > LOST_DAYS * 86400);
    if (!d.files_synced && gone) || (d.files_synced && old) {
        return Status::Failed(Failure::Lost);
    }
    Status::Added
}
```

- [ ] **Step 4: Run all tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A packages/plab/src
git commit -m "feat(galactica): plab derives each download's status"
```

---

### Task 9: Status badges and Recent grabs on the page

**Files:**
- Modify: `packages/plab/src/page.rs` (`card`, `render`, new `grabs_strip`), `packages/plab/src/page_tests.rs`, `packages/plab/src/web.rs` (`list`, `search`), `packages/plab/src/web_tests.rs`

**Interfaces:**
- Consumes: `Db::download_rows`, `provenance::{status, Status, Failure}`, `TorrentClient::details`.
- Produces:
  - `pub struct Downloads { pub by_topic: HashMap<u64, Status>, pub grabs: Vec<(DownloadRow, Status)> }` in `page.rs`, `Default`
  - `render(listing, added, queued, now, search, section, downloads: &Downloads)` (new last argument)
  - `pub fn status_badge(s: &Status) -> String`
  - `web::downloads(st, now) -> Downloads` (async)

- [ ] **Step 1: Write the failing tests** (`page_tests.rs`)

Extend both `render` helpers in `render_tests` and the golden tests to pass
`&Downloads::default()`, then add:

```rust
mod status_tests {
    use super::*;
    use crate::db::DownloadRow;
    use crate::provenance::{Failure, Status};

    fn grab(id: i64, title: &str) -> DownloadRow {
        DownloadRow {
            id,
            source: "grab".into(),
            topic_id: None,
            release_title: title.into(),
            studio: Some("Studio A".into()),
            state: "added".into(),
            hash: None,
            added_at: Some(ADDED),
            files_synced: true,
            files: vec![],
        }
    }

    #[test]
    fn badges() {
        assert!(status_badge(&Status::Queued).contains("badge-warning"));
        assert!(status_badge(&Status::Downloading(42)).contains("42%"));
        assert!(status_badge(&Status::InStash).contains("in Stash"));
        let b = status_badge(&Status::Identified { label: "T · <S>".into(), more: 2, guess: true });
        assert!(b.contains("badge-success") && b.contains("T · &lt;S&gt; +2") && b.contains("guess"), "{b}");
        let b = status_badge(&Status::Failed(Failure::Transmission("No data".into())));
        assert!(b.contains("badge-error") && b.contains(r#"title="No data""#), "{b}");
        assert!(status_badge(&Status::Failed(Failure::Lost)).contains("lost"));
    }

    #[test]
    fn an_added_card_shows_its_status_beside_the_button() {
        let downloads = Downloads {
            by_topic: HashMap::from([(1, Status::InStash)]),
            grabs: vec![],
        };
        let out = super::render(
            &listing(ADDED, vec![tp(1, "[S.com] A - B")]),
            &set(&[1]),
            &set(&[]),
            ADDED + 7200,
            None,
            Section::Video,
            &downloads,
        );
        assert!(out.contains("Added ✓"));
        assert!(out.contains(r#"class="status badge"#));
    }

    #[test]
    fn recent_grabs_strip_lists_grabs_on_videos_only() {
        let downloads = Downloads {
            by_topic: HashMap::new(),
            grabs: vec![(grab(1, "StudioA E1 Jane <x>"), Status::Downloading(10))],
        };
        let r = |section| {
            super::render(&listing(ADDED, vec![]), &set(&[]), &set(&[]), ADDED + 7200, None, section, &downloads)
        };
        let video = r(Section::Video);
        assert!(video.contains("Recent grabs (1)"), "{video}");
        assert!(video.contains("StudioA E1 Jane &lt;x&gt;"));
        assert!(!r(Section::Games).contains("Recent grabs"));
    }
}
```

(`listing`, `tp`, `set`, `ADDED` are the existing helpers at the top of `page_tests.rs`.)

`web_tests.rs`: its `FakeTorrents` (`#[derive(Default)]`, ~line 113) gains
`details: Vec<Detail>` and `details_fail: bool`, and:

```rust
    async fn details(&self, hashes: &[String]) -> anyhow::Result<Vec<Detail>> {
        if self.details_fail {
            anyhow::bail!("transmission down");
        }
        Ok(self.details.iter().filter(|d| hashes.contains(&d.hash_string)).cloned().collect())
    }
```

```rust
#[tokio::test]
async fn a_downloading_topic_shows_its_progress() {
    let mut d = crate::provenance::tests::detail("abc", "/d", 0.5, &[]);
    d.activity_date = now();
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.torrents = Arc::new(FakeTorrents { details: vec![d], ..Default::default() });
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[])]);
    fx.state.db.mark_added(crate::db::NewDownload {
        source: "plab",
        topic_id: Some(1),
        release_title: "Fresh Apple",
        section: Section::Video,
        download_dir: Some("/vault"),
        torrent_hash: Some("abc"),
        now: now(),
    })
    .unwrap();
    let r = fx.get("/").await;
    assert!(r.text().contains("downloading 50%"), "{}", r.text());
}

#[tokio::test]
async fn the_page_still_renders_when_transmission_fails() {
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.torrents = Arc::new(FakeTorrents { details_fail: true, ..Default::default() });
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[])]);
    fx.state.db.mark_added(crate::db::NewDownload {
        source: "plab",
        topic_id: Some(1),
        release_title: "Fresh Apple",
        section: Section::Video,
        download_dir: Some("/vault"),
        torrent_hash: Some("abc"),
        now: now(),
    })
    .unwrap();
    let r = fx.get("/").await;
    assert_eq!(r.status, 200);
    assert!(r.text().contains(">added<"), "{}", r.text());
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `cd packages/plab && cargo test page 2>&1 | tail -15`
Expected: compile errors.

- [ ] **Step 3: Implement**

`page.rs`:

```rust
use crate::db::DownloadRow;
use crate::provenance::{Failure, Status};

/// What became of the downloads the page shows: plab's by topic, and recent grabs.
#[derive(Debug, Default)]
pub struct Downloads {
    pub by_topic: HashMap<u64, Status>,
    pub grabs: Vec<(DownloadRow, Status)>,
}

/// A download's status as a daisyUI badge; a failure's reason is its tooltip.
pub fn status_badge(s: &Status) -> String {
    let (color, text, tip) = match s {
        Status::Queued => ("badge-warning", "queued".to_string(), String::new()),
        Status::Downloading(p) => ("badge-info", format!("downloading {p}%"), String::new()),
        Status::Added => ("badge-ghost", "added".to_string(), String::new()),
        Status::InStash => ("badge-neutral", "in Stash".to_string(), String::new()),
        Status::Identified { label, more, guess } => {
            let more = if *more > 0 { format!(" +{more}") } else { String::new() };
            let guess = if *guess { " (guess)" } else { "" };
            ("badge-success", format!("{label}{more}{guess}"), String::new())
        }
        Status::Failed(f) => {
            let tip = match f {
                Failure::Transmission(why) => why.clone(),
                Failure::Identify => "identify found nothing or gave up".into(),
                Failure::Lost => "the torrent is gone and no scene came of it".into(),
            };
            let what = match f {
                Failure::Transmission(_) => "failed: download",
                Failure::Identify => "failed: identify",
                Failure::Lost => "failed: lost",
            };
            ("badge-error", what.to_string(), tip)
        }
    };
    let tip = if tip.is_empty() { String::new() } else { format!(r#" title="{}""#, e(&tip)) };
    format!(r#"<span class="status badge {color} badge-sm max-w-full truncate"{tip}>{}</span>"#, e(&text))
}

/// The Videos tab's collapsible list of recent grabs; nothing when there are none.
fn grabs_strip(grabs: &[(DownloadRow, Status)], now: i64) -> String {
    if grabs.is_empty() {
        return String::new();
    }
    let rows: String = grabs
        .iter()
        .map(|(d, s)| {
            format!(
                concat!(
                    r#"<li class="flex flex-wrap items-center gap-2 text-sm">"#,
                    r#"<span class="studio font-semibold uppercase text-xs text-primary">{studio}</span>"#,
                    r#"<span class="break-all">{title}</span>{badge}"#,
                    r#"<span class="text-xs text-base-content/60">{age}</span></li>"#
                ),
                studio = e(d.studio.as_deref().unwrap_or("")),
                title = e(&d.release_title),
                badge = status_badge(s),
                age = d.added_at.map_or(String::new(), |a| age(a, now)),
            )
        })
        .collect();
    format!(
        r#"<details id="grabs" class="mb-4 rounded-box bg-base-200 p-3"><summary class="cursor-pointer font-semibold">Recent grabs ({})</summary><ul class="mt-2 flex flex-col gap-1">{rows}</ul></details>"#,
        grabs.len()
    )
}
```

`card` gains `status: Option<&Status>` and appends the badge inside `card-actions`:

```rust
    let badge_html = status.map(status_badge).unwrap_or_default();
    …
    r#"<div class="card-actions mt-auto items-center">{button}{status}</div></div></div>"#,
    …
    status = badge_html,
```

`render` gains `downloads: &Downloads`; in the cards map pass
`downloads.by_topic.get(&t.topic.row.id)`; and in the template insert
`{grabs}` right before `<div id="grid"`, with
`grabs = if section == Section::Video && search.is_none() { grabs_strip(&downloads.grabs, now) } else { String::new() }`.
Because the golden state passes `Downloads::default()`, its output is unchanged.

`web.rs`:

```rust
use crate::page::Downloads;
use crate::provenance::{self, Status};
use std::collections::HashMap;

/// How far back the page looks up downloads in Transmission, and shows grabs.
const LIVE_DAYS: i64 = 30;
const GRAB_DAYS: i64 = 14;

/// Each recent download's status. Transmission is asked once, briefly; if it does not
/// answer, statuses come from the database alone.
async fn downloads<T: TrackerApi, C: TorrentClient>(st: &WebState<T, C>, now: i64) -> Downloads {
    let rows = match st.db.download_rows(now - LIVE_DAYS * 86400) {
        Ok(r) => r,
        Err(e) => {
            info!(job = "web", "download rows: {e:#}");
            return Downloads::default();
        }
    };
    let hashes: Vec<String> = rows.iter().filter_map(|r| r.hash.clone()).collect();
    let live = match tokio::time::timeout(std::time::Duration::from_secs(2), st.torrents.details(&hashes)).await {
        Ok(Ok(list)) => Some(list.into_iter().map(|d| (d.hash_string.clone(), d)).collect::<HashMap<_, _>>()),
        Ok(Err(e)) => {
            info!(job = "web", "transmission: {e:#}");
            None
        }
        Err(_) => {
            info!(job = "web", "transmission: no answer in 2 s");
            None
        }
    };
    let mut out = Downloads::default();
    for r in rows {
        let s: Status = provenance::status(&r, live.as_ref(), now);
        if let Some(t) = r.topic_id {
            out.by_topic.insert(t, s);
        } else if r.source == "grab" && r.added_at.is_some_and(|a| a >= now - GRAB_DAYS * 86400) {
            out.grabs.push((r, s));
        }
    }
    out
}
```

Make `list` async (`async fn list(...)`, `return list(st, Section::Video).await` in `get`),
compute `let downloads = downloads(st, t).await;` before the `db.listing` closure, and pass
`&downloads` as `render`'s last argument. Do the same in `search`.

- [ ] **Step 4: Run all tests and clippy**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"; cargo clippy --all-targets -- -D warnings`
Expected: all pass, the three golden tests included, clean.

- [ ] **Step 5: Commit**

```bash
git add -A packages/plab/src
git commit -m "feat(galactica): plab page shows each download's status and recent grabs"
```

---

### Task 10: Docs, build, deploy

**Files:**
- Modify: `modules/hosts/galactica/services/plab/default.nix` (header comment)
- Modify: `docs/superpowers/specs/2026-11-02-plab-provenance-identify-design.md` (the five refinements in Global Constraints)

- [ ] **Step 1: Update the module header**

In `default.nix`, after the `# Design:` line add:

```nix
# Provenance (which download a scene came from, its status on the page, tracker covers):
# docs/superpowers/specs/2026-11-02-plab-provenance-identify-design.md
```

and after the one-shot list, add a line explaining why prune holds a torrent back:

```nix
# prune keeps a finished torrent until its files are recorded (plab.state.db,
# download_file): grabs are removed as soon as they finish, and the file list goes with them.
```

- [ ] **Step 2: Update the spec** with the five refinements listed under Global Constraints
(sync stores every file path; `details`/`Detail`; absolute cover path and 90-day cleanup by
age; badge beside the button with goldens unchanged; `Clients` gains `T`). Edit the
sentences that say otherwise; don't append a changelog.

- [ ] **Step 3: Build galactica**

Run: `cd ~/Code/nixos && nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link 2>&1 | tail -5`
Expected: success (its checkPhase runs `cargo test`).

- [ ] **Step 4: Commit and push**

```bash
just fmt
git add modules/hosts/galactica/services/plab/default.nix docs/superpowers/specs/2026-11-02-plab-provenance-identify-design.md
git commit -m "docs(galactica): plab provenance spec and module notes match the implementation"
git push -u origin master
```

- [ ] **Step 5: Deploy (ask the user first) and smoke test**

`just deploy galactica` from raider. Then:

```bash
ssh galactica.bat-boa.ts.net 'sudo sqlite3 /var/lib/plab/state.db "PRAGMA user_version; SELECT count(*) FROM download_file;"'
ssh galactica.bat-boa.ts.net 'journalctl -u plab --since -10min | grep -Ei "record|prune|kept" | tail'
```

Expected: `user_version` is 2. After the next grab lands: `download_file` has rows, a
`sudo -u media plab identify --dry-run --scene <id>` on its scene shows the release title in
the parse, and the page's Recent grabs strip shows the row moving through its states.
