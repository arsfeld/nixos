# plab Rust merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace galactica's three Python tools — plab, stash-identify and vault-grab — with one Rust daemon, `plab`, at feature parity, on one SQLite database.

**Architecture:** One crate in `packages/plab/` (auto-loaded as `pkgs.plab`). `plab serve` runs a supervisor that spawns tokio tasks — web, identify watcher, refresh, prune, grab — over one shared `App`. Every job is also a one-shot subcommand. State moves from JSON files to `/var/lib/plab/state.db`, imported once from the legacy files. Domain code is generic over small client traits so the Python suites' fakes port directly.

**Tech Stack:** Rust (nixpkgs rustc 1.98), tokio, axum, reqwest (rustls), rusqlite (bundled), regex, fancy-regex, encoding_rs, serde/serde_json, clap, notify, tracing, anyhow, thiserror, chrono, sha1; wiremock + tempfile for tests. Nix `rustPlatform.buildRustPackage`.

**Spec:** `docs/superpowers/specs/2026-11-01-plab-rust-merge-design.md`

## Global Constraints

- **The Python is the reference implementation.** Each porting task names its Python source; port behaviour exactly — constants, thresholds, log wording, error messages shown to the user, ordering. Where this plan shows code, it is binding; where it says "port `X` from `file.py`", the Python body is the spec for that function.
- **Every Python test is ported.** Each task names its Python test file(s). Every `def test_*` there becomes a `#[test]`/`#[tokio::test]` with the same name (minus `test_` prefix is fine) and the same inputs and expected values. A task is not done until `cargo test <module>` reports at least as many tests as the Python file has. Counts: test_parse 12, test_forums 5, test_labels 18, test_store 15, test_lab 30, test_transmission 6, test_prune 10, test_classify 5, test_main (plab) 82, test_page 59, vault-grab test_main 31, test_match 46, test_llm 2, stash-identify test_main 72.
- **Never touch the Python, its units, or its state until Task 18.** The Python keeps running on galactica throughout; tasks 1–16 change only `packages/plab/`. Task 17 adds only a CLI alias.
- **Commit straight to master**, conventional commits, scope `galactica`. No branches, no worktrees. Never mention Claude.
- **New files must be `git add`ed before `nix build`** — flakes only see tracked files.
- **Dev loop** (from `packages/plab/`): `nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc nixpkgs#rustfmt nixpkgs#clippy -c cargo test`. Written below as `cargo test …`; always run it through that `nix shell`. Final per-task gate: `nix build .#plab` from the repo root (runs the whole suite in the sandbox).
- **Rounding:** Python's `round()` is round-half-even. Use `f64::round_ties_even`, never `f64::round`.
- **HTML and JSON output must be byte-identical to Python's** for the page: use `py::escape` (twin of `html.escape(s, quote=True)`) and `py::json` (twin of `json.dumps` defaults) from Task 9.
- **Times** are `i64` Unix seconds unless a Python function uses fractional seconds (prune's idle days: `f64`).
- **Do not run `nix flake check` locally**, and never build/evaluate cylon-link.
- **Constants copied verbatim:** tracker base `https://tracker.example.org/forum/`, UA `Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0`, `LOGIN_BACKOFF = 300`, `DAYS = 7`, `GAMES_DAYS = 32`, `LIMIT = 100`, `DELAY = 1.0`, `CLASSIFY_FAILURE_LIMIT = 3`, `SEARCH_LIMIT = 50`, fetch slots 2, `SEARCH_TTL = 86400`, prune `RATIO = 2.0`/`IDLE_DAYS = 7`/`MAX_SEEDING = 50`, identify `SETTLE = 120`, sweep 24 h, `FAILURE_LIMIT = 3`, `PER_BOX = 6`, `DURATION_TOLERANCE = 10`, `LLM_TAG = "llm-identified"`, `JOB_TIMEOUT = 6*3600`, `JOB_POLL = 5`, models `typesafe/jev-1.13` and `~deepseek/deepseek-flash-latest`, grab `WINDOW = 30 days`, `MIN_NAME = 8`, `QUOTA_INDEXER = "Tracker"`.

---

## File Structure

```
packages/plab/
  package.nix            buildRustPackage; cargo test runs in checkPhase
  Cargo.toml, Cargo.lock, .gitignore (target/)
  assets/page.css        verbatim from assets.py CSS
  assets/page.js         verbatim from assets.py JS
  tests/fixtures/        tracker.html, topic.html, limit.html (moved from plab/fixtures)
  src/
    main.rs              clap CLI → commands; `serve` builds App and runs the supervisor
    config.rs            Config::from_env
    app.rs               App (shared clients + db + config)
    jobs.rs              Schedule, last_slot/next_slot, run_periodic, supervise
    db/mod.rs            Db handle, migrations, all queries
    db/schema.sql        migration 1
    db/import.rs         one-time legacy JSON import
    images.rs            image cache: key(), sniff(), ImageCache
    py.rs                html.escape / json.dumps / repr twins
    http.rs              shared reqwest client builder + JSON helpers
    tracker/mod.rs       Tracker client (TrackerApi impl), errors
    tracker/cookies.rs   CookieJar (Set-Cookie, Netscape import, JSON)
    tracker/parse.rs     parse.py
    tracker/forums.rs    forums.py
    labels.rs            labels.py
    filters.rs           load_filters, load_excludes, exclude_predicate, match_filters
    transmission.rs      Transmission RPC (TorrentClient impl)
    prune.rs             prune.py decide + run_prune
    llm.rs               OpenRouter: classify, parse, translate_title, choose
    plab.rs              refresh, add_topic, unqueue, drain_queue, run_refresh, run_search, topic_images, image_for
    page.rs              page.py
    web.rs               axum routes
    grab.rs              vault-grab
    prowlarr.rs          Prowlarr search/fetch/api_key
    stash.rs             Stash GraphQL client (StashApi impl)
    codedb.rs              the code database client
    identify/mod.rs      identify_scene, code_prop, fc2_prop, apply, run_pass, State helpers
    identify/matching.rs match.py
    identify/watch.rs    changed_dir, Debouncer, watch loop
modules/hosts/galactica/services/plab/default.nix   (Task 17 alias; Task 18 rewrite)
```

---

### Task 1: Crate skeleton, Nix package, CLI shell

**Files:**
- Create: `packages/plab/Cargo.toml`, `packages/plab/.gitignore`, `packages/plab/package.nix`, `packages/plab/src/main.rs`

**Interfaces:**
- Produces: binary `plab` with subcommands `serve`, `refresh`, `prune`, `grab`, `identify`, `set-cookie` (each returns `anyhow::bail!("not implemented yet")` until Task 16 wires it); `pkgs.plab`.

- [ ] **Step 1: Cargo.toml**

```toml
[package]
name = "plab"
version = "0.1.0"
edition = "2024"

[dependencies]
anyhow = "1"
thiserror = "2"
tokio = { version = "1", features = ["full"] }
axum = "0.8"
reqwest = { version = "0.12", default-features = false, features = ["rustls-tls", "json"] }
rusqlite = { version = "0.37", features = ["bundled"] }
regex = "1"
fancy-regex = "0.14"
encoding_rs = "0.8"
serde = { version = "1", features = ["derive"] }
serde_json = { version = "1", features = ["preserve_order"] }
clap = { version = "4", features = ["derive"] }
notify = "8"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
chrono = { version = "0.4", default-features = false, features = ["clock", "std"] }
sha1 = "0.10"
hex = "0.4"
base64 = "0.22"
form_urlencoded = "1"
url = "2"
futures = "0.3"

[dev-dependencies]
wiremock = "0.6"
tempfile = "3"
```

If a pinned major version does not resolve, take the newest release and adjust call sites; record it in the commit message. `preserve_order` matters: Python dicts keep insertion order and `py::json` must too.

- [ ] **Step 2: `.gitignore`** containing `target/`.

- [ ] **Step 3: `src/main.rs`**

```rust
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "plab")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// The daemon: page, identify watcher, and the periodic jobs.
    Serve {
        #[arg(long, default_value = "127.0.0.1")]
        bind: String,
        #[arg(long, default_value_t = 8577)]
        port: u16,
        /// Comma-separated subset of web,identify,refresh,prune,grab.
        #[arg(long, value_delimiter = ',', default_value = "web,identify,refresh,prune,grab")]
        tasks: Vec<String>,
    },
    /// Drain the download queues, then rebuild the video and games lists.
    Refresh,
    /// Take finished Vault and Games torrents out of Transmission.
    Prune {
        #[arg(long)]
        dry_run: bool,
    },
    /// Grab new scenes of the followed studios into Vault.
    Grab {
        #[arg(long)]
        dry_run: bool,
    },
    /// One identify pass. Without paths: the LLM step only (no Stash jobs).
    Identify {
        #[arg(long)]
        dry_run: bool,
        #[arg(long)]
        limit: Option<usize>,
        #[arg(long = "scene")]
        scenes: Vec<String>,
        #[arg(long)]
        no_jobs: bool,
        paths: Vec<String>,
    },
    /// Seed the tracker session by hand when a login hits a captcha.
    SetCookie { value: String },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_ansi(false)
        .without_time() // the journal timestamps lines
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| "info".into()))
        .init();
    let cli = Cli::parse();
    match cli.cmd {
        _ => anyhow::bail!("not implemented yet"),
    }
}
```

- [ ] **Step 4: Generate the lockfile and build**

Run (in `packages/plab/`): `nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc -c cargo build`
Expected: compiles; `Cargo.lock` created.

- [ ] **Step 5: `package.nix`**

```nix
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "plab";
  version = "0.1.0";
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./Cargo.toml
      ./Cargo.lock
      ./src
      (lib.fileset.maybeMissing ./assets)
      (lib.fileset.maybeMissing ./tests)
    ];
  };
  cargoLock.lockFile = ./Cargo.lock;
  # cargo test runs in checkPhase (the default): a failing test fails the galactica build.
  meta = {
    description = "plab: tracker page, Stash identification and studio grabs for galactica";
    mainProgram = "plab";
  };
}
```

- [ ] **Step 6: Build through Nix**

Run (repo root): `git add packages/plab && nix build .#plab && ./result/bin/plab --help`
Expected: help lists the six subcommands.

- [ ] **Step 7: Commit**

```bash
git add packages/plab
git commit -m "feat(galactica): plab rust crate skeleton"
```

---

### Task 2: Database — schema, migrations, queries

Replaces `store.py` (minus the image files, Task 4) and the state classes of stash-identify and vault-grab.

**Files:**
- Create: `src/db/mod.rs`, `src/db/schema.sql`, `src/db/import.rs` holding only the `LegacyPaths` struct from Task 5 (Task 5 fills in the rest)
- Modify: `src/main.rs` (`mod db;`)
- Test: `#[cfg(test)] mod tests` in `src/db/mod.rs` — port `plab/test_store.py` (15) for everything except images; image tests port in Task 4.

**Interfaces:**
- Consumes: `tracker::parse::Row` — define it here in `src/tracker/parse.rs` as a stub module containing only the struct (Task 3 fills the module):

```rust
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Row {
    pub id: u64,
    pub title: String,
    pub forum: u32,
    pub size: u64,
    pub seeders: u32,
    pub leechers: u32,
    pub completed: u32,
    pub added: i64,
}
```

- Produces (exact):

```rust
pub const SEARCH_TTL: i64 = 86400;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Section { Video, Games }
impl Section {
    pub const ALL: [Section; 2] = [Section::Video, Section::Games];
    pub fn as_str(self) -> &'static str;          // "video" | "games"
    pub fn parse(s: &str) -> Option<Section>;
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Production { #[serde(rename = "class")] pub class: String, pub confidence: Option<f64> }

#[derive(Debug, Clone, PartialEq)]
pub struct Topic { pub row: Row, pub images: Option<Vec<String>>, pub production: Option<Production> }

#[derive(Debug, Clone, PartialEq)]
pub struct Listed { pub topic: Topic, pub filters: Vec<String>, pub curated_reason: Option<String> }

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Listing { pub updated: i64, pub filters: Vec<String>, pub topics: Vec<Listed> }

#[derive(Clone)]
pub struct Db(std::sync::Arc<std::sync::Mutex<rusqlite::Connection>>);

impl Db {
    pub fn open(path: &std::path::Path) -> anyhow::Result<Db>;   // = open_with(path, None)
    pub fn open_with(path: &std::path::Path, legacy: Option<&import::LegacyPaths>) -> anyhow::Result<Db>; // WAL, busy_timeout 30s, migrate (+ import)
    pub fn open_in_memory() -> anyhow::Result<Db>;               // for tests
    pub fn user_version(&self) -> anyhow::Result<i64>;

    // lists
    pub fn listing(&self, section: Section) -> anyhow::Result<Listing>;
    pub fn save_listing(&self, section: Section, topics: &[Listed], filters: &[String], now: i64) -> anyhow::Result<()>;
    // search
    pub fn search_topics(&self, now: i64) -> anyhow::Result<std::collections::HashMap<u64, Topic>>;
    pub fn save_search(&self, rows: &[Row], now: i64) -> anyhow::Result<()>;
    pub fn set_images(&self, topic_id: u64, urls: &[String]) -> anyhow::Result<()>;
    // lookup
    pub fn find(&self, topic_id: u64, now: i64) -> anyhow::Result<Option<(Topic, Section)>>;
    pub fn image_urls(&self, now: i64) -> anyhow::Result<Vec<String>>;
    // downloads (replaces added.json / queued.json / games-queued.json)
    pub fn added(&self) -> anyhow::Result<std::collections::HashSet<u64>>;
    pub fn queued(&self, section: Section) -> anyhow::Result<Vec<u64>>;
    pub fn enqueue(&self, topic_id: u64, section: Section, now: i64) -> anyhow::Result<()>;
    pub fn dequeue(&self, topic_id: u64, section: Section) -> anyhow::Result<()>;
    pub fn mark_added(&self, a: NewDownload<'_>) -> anyhow::Result<i64>; // returns download id
    // grab
    pub fn grabbed(&self, studio: &str, keys: &std::collections::BTreeSet<String>) -> anyhow::Result<bool>;
    pub fn record_grab(&self, studio: &str, keys: &std::collections::BTreeSet<String>, title: &str, at: &str, download_id: Option<i64>) -> anyhow::Result<()>;
    // identify (replaces State)
    pub fn identify_done(&self, scene_id: &str) -> anyhow::Result<bool>;
    pub fn identify_mark_done(&self, scene_id: &str) -> anyhow::Result<()>;
    pub fn identify_fail(&self, scene_id: &str) -> anyhow::Result<bool>; // true = gave up (3rd failure)
    pub fn identify_clear_failures(&self, scene_id: &str) -> anyhow::Result<()>;
    // jobs
    pub fn job_last_started(&self, job: &str) -> anyhow::Result<Option<i64>>;
    pub fn job_started(&self, job: &str, now: i64) -> anyhow::Result<()>;
    pub fn job_finished(&self, job: &str, now: i64, error: Option<&str>) -> anyhow::Result<()>;
    // kv
    pub fn kv_get(&self, key: &str) -> anyhow::Result<Option<(String, i64)>>; // (value, rev)
    pub fn kv_set(&self, key: &str, value: &str) -> anyhow::Result<i64>;       // returns new rev
}

pub struct NewDownload<'a> {
    pub source: &'a str,                 // "plab" | "grab"
    pub topic_id: Option<u64>,
    pub release_title: &'a str,
    pub section: Section,
    pub download_dir: Option<&'a str>,
    pub torrent_hash: Option<&'a str>,
    pub now: i64,
}
pub const IDENTIFY_FAILURE_LIMIT: i64 = 3;
```

All methods lock the mutex for the duration of one statement/transaction only; they are called directly from async code (queries are sub-millisecond). Never hold the lock across an `.await`.

- [ ] **Step 1: `src/db/schema.sql`**

```sql
CREATE TABLE topic (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  forum INTEGER NOT NULL,
  size INTEGER NOT NULL,
  seeders INTEGER NOT NULL,
  leechers INTEGER NOT NULL,
  completed INTEGER NOT NULL,
  added INTEGER NOT NULL,          -- tracker upload time
  images TEXT,                     -- JSON array; NULL = not fetched yet
  production TEXT,                 -- JSON {"class","confidence"}; NULL = unclassified
  seen_at INTEGER NOT NULL
);
CREATE TABLE listing (
  section TEXT NOT NULL,
  position INTEGER NOT NULL,
  topic_id INTEGER NOT NULL REFERENCES topic(id),
  filters TEXT NOT NULL,           -- JSON array of curated filter names
  curated_reason TEXT,
  PRIMARY KEY (section, position)
);
CREATE TABLE listing_meta (
  section TEXT PRIMARY KEY,
  updated INTEGER NOT NULL,
  filters TEXT NOT NULL            -- JSON array, file order
);
CREATE TABLE search_hit (
  topic_id INTEGER PRIMARY KEY REFERENCES topic(id),
  at INTEGER NOT NULL
);
CREATE TABLE download (
  id INTEGER PRIMARY KEY,
  source TEXT NOT NULL,            -- 'plab' | 'grab'
  topic_id INTEGER,                -- plab only
  release_title TEXT NOT NULL,
  section TEXT NOT NULL,
  download_dir TEXT,               -- NULL for rows imported from added.json
  state TEXT NOT NULL,             -- 'queued' | 'added'
  torrent_hash TEXT,
  queued_at INTEGER,
  added_at INTEGER
);
CREATE UNIQUE INDEX download_topic ON download(topic_id) WHERE topic_id IS NOT NULL;
CREATE TABLE grab_seen (
  studio TEXT NOT NULL,
  scene_key TEXT NOT NULL,
  title TEXT NOT NULL,
  at TEXT NOT NULL,                -- ISO 8601, as vault-grab wrote it
  download_id INTEGER REFERENCES download(id),
  PRIMARY KEY (studio, scene_key)
);
CREATE TABLE identify_attempt (
  scene_id TEXT PRIMARY KEY,
  failures INTEGER NOT NULL DEFAULT 0,
  done INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE job_run (
  job TEXT PRIMARY KEY,
  last_started INTEGER,
  last_finished INTEGER,
  ok INTEGER,
  error TEXT
);
CREATE TABLE kv (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  rev INTEGER NOT NULL
);
```

- [ ] **Step 2: Write the failing tests** — port `test_store.py` (non-image tests), adapted to the table API. Required behaviours, each its own test:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::tracker::parse::Row;

    fn row(id: u64, title: &str) -> Row {
        Row { id, title: title.into(), forum: 1875, size: 1, seeders: 1, leechers: 0, completed: 0, added: 0 }
    }
    fn listed(id: u64) -> Listed {
        Listed { topic: Topic { row: row(id, "t"), images: Some(vec![format!("https://i/{id}.jpg")]), production: None },
                 filters: vec![], curated_reason: None }
    }

    #[test]
    fn empty_listing_is_default() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.listing(Section::Video).unwrap(), Listing::default());
    }

    #[test]
    fn save_listing_round_trips_in_order_per_section() {
        let db = Db::open_in_memory().unwrap();
        db.save_listing(Section::Video, &[listed(2), listed(1)], &["A".into()], 100).unwrap();
        db.save_listing(Section::Games, &[listed(3)], &[], 101).unwrap();
        let v = db.listing(Section::Video).unwrap();
        assert_eq!(v.updated, 100);
        assert_eq!(v.filters, vec!["A".to_string()]);
        assert_eq!(v.topics.iter().map(|t| t.topic.row.id).collect::<Vec<_>>(), vec![2, 1]);
        assert_eq!(db.listing(Section::Games).unwrap().topics.len(), 1);
    }

    #[test]
    fn enqueue_skips_added_and_duplicates() {
        let db = Db::open_in_memory().unwrap();
        db.enqueue(5, Section::Video, 1).unwrap();
        db.enqueue(5, Section::Video, 2).unwrap();
        assert_eq!(db.queued(Section::Video).unwrap(), vec![5]);
        db.mark_added(NewDownload { source: "plab", topic_id: Some(6), release_title: "x", section: Section::Video,
                                    download_dir: Some("/d"), torrent_hash: None, now: 3 }).unwrap();
        db.enqueue(6, Section::Video, 4).unwrap();
        assert_eq!(db.queued(Section::Video).unwrap(), vec![5]);
    }

    #[test]
    fn mark_added_promotes_a_queued_row() {
        let db = Db::open_in_memory().unwrap();
        db.enqueue(5, Section::Games, 1).unwrap();
        db.dequeue(5, Section::Games).unwrap();
        db.enqueue(5, Section::Games, 1).unwrap();
        db.mark_added(NewDownload { source: "plab", topic_id: Some(5), release_title: "x", section: Section::Games,
                                    download_dir: Some("/g"), torrent_hash: Some("abc"), now: 2 }).unwrap();
        assert!(db.queued(Section::Games).unwrap().is_empty());
        assert!(db.added().unwrap().contains(&5));
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
    fn find_prefers_lists_then_search_as_video() {
        let db = Db::open_in_memory().unwrap();
        db.save_listing(Section::Games, &[listed(3)], &[], 1).unwrap();
        db.save_search(&[row(4, "s")], 1).unwrap();
        assert_eq!(db.find(3, 1).unwrap().unwrap().1, Section::Games);
        assert_eq!(db.find(4, 1).unwrap().unwrap().1, Section::Video);
        assert!(db.find(5, 1).unwrap().is_none());
    }

    #[test]
    fn image_urls_cover_both_lists_and_live_searches() {
        let db = Db::open_in_memory().unwrap();
        db.save_listing(Section::Video, &[listed(1)], &[], 1).unwrap();
        db.save_listing(Section::Games, &[listed(2)], &[], 1).unwrap();
        db.save_search(&[row(3, "s")], 1).unwrap();
        db.set_images(3, &["https://i/3.jpg".into()]).unwrap();
        let mut urls = db.image_urls(1).unwrap();
        urls.sort();
        assert_eq!(urls, vec!["https://i/1.jpg", "https://i/2.jpg", "https://i/3.jpg"]);
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
    fn grabbed_matches_any_key() {
        let db = Db::open_in_memory().unwrap();
        let k = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<std::collections::BTreeSet<_>>();
        db.record_grab("Studio A", &k(&["ep:1", "name:abcdefgh"]), "t", "2026-10-24T00:00:00+00:00", None).unwrap();
        assert!(db.grabbed("Studio A", &k(&["name:abcdefgh"])).unwrap());
        assert!(!db.grabbed("Other", &k(&["ep:1"])).unwrap());
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
    fn job_run_records_start() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.job_last_started("prune").unwrap(), None);
        db.job_started("prune", 50).unwrap();
        db.job_finished("prune", 60, Some("boom")).unwrap();
        assert_eq!(db.job_last_started("prune").unwrap(), Some(50));
    }

    #[test]
    fn migrations_set_user_version() {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(&dir.path().join("state.db")).unwrap();
        assert_eq!(db.user_version().unwrap(), 1);
        drop(db);
        assert_eq!(Db::open(&dir.path().join("state.db")).unwrap().user_version().unwrap(), 1); // idempotent
    }
}
```

Then port any remaining `test_store.py` behaviour not covered above (read that file; e.g. corrupt-file handling has no SQLite equivalent — note it as N/A in a comment rather than inventing a test).

- [ ] **Step 3: Run tests to verify they fail** — `cargo test db::` → compile errors / failures.

- [ ] **Step 4: Implement `src/db/mod.rs`.** Rules:
  - `open(path)` = `open_with(path, None)`; `open_with(path, legacy: Option<&import::LegacyPaths>)` is what `App::build` calls (Task 16). `open`: create parent dir, `PRAGMA journal_mode=WAL; PRAGMA busy_timeout=30000; PRAGMA foreign_keys=ON;` then `migrate`.
  - `migrate(conn, legacy)`: if `user_version == 0`, in one transaction run `schema.sql` (`include_str!`), then — when `legacy` is `Some` — the import (added in Task 5; until then the branch is empty), then set `user_version = 1`, commit. `open_in_memory` passes `None`.
  - `save_listing`: one transaction: upsert each topic (`INSERT … ON CONFLICT(id) DO UPDATE` of row fields and `seen_at`; `images` set to the new value when `Some`, kept when `None`; `production` likewise), `DELETE FROM listing WHERE section=?`, insert positions 0.., upsert `listing_meta`. Then delete orphan topics: `DELETE FROM topic WHERE id NOT IN (SELECT topic_id FROM listing) AND id NOT IN (SELECT topic_id FROM search_hit WHERE at >= now - SEARCH_TTL) AND id NOT IN (SELECT topic_id FROM download WHERE topic_id IS NOT NULL)`, and expired `search_hit` rows first.
  - `save_search(rows, now)`: upsert topic row fields (keep `images`, keep `production`), upsert `search_hit(topic_id, at=now)`.
  - `search_topics(now)`: join `search_hit` with `at >= now - SEARCH_TTL`.
  - `find`: listing (video first, then games, per `Section::ALL`), else live search → `Section::Video`.
  - `image_urls(now)`: images of topics in any listing or live search hit.
  - `added()`: `topic_id` of `state='added'`. `queued(s)`: `state='queued' AND section=?` ordered by `queued_at, id`.
  - `enqueue`: no-op if any `download` row exists for the topic; else insert `state='queued'`, `source='plab'`, `release_title` = topic title if known else `""`.
  - `dequeue`: delete the `queued` row for that topic and section.
  - `mark_added`: if a row exists for `topic_id`, update it to `added` with dir/hash/added_at; else insert. Rows with `topic_id = None` always insert. Return the row id.
  - identify: `identify_fail` increments `failures`; at `IDENTIFY_FAILURE_LIMIT` sets `done=1` and returns true. `identify_mark_done` sets `done=1`. `identify_clear_failures` sets `failures=0`.
  - `kv_set`: `rev = COALESCE((SELECT max(rev) FROM kv), 0) + 1`.

- [ ] **Step 5: Run tests** — `cargo test db::` → all pass.

- [ ] **Step 6: Commit** — `git add packages/plab && git commit -m "feat(galactica): plab sqlite state"`

---

### Task 3: Tracker parsing, forums, labels, filters (pure)

**Files:**
- Create: `src/tracker/mod.rs` (just `pub mod parse; pub mod forums; pub mod cookies;` for now — cookies in Task 6), fill `src/tracker/parse.rs`, `src/tracker/forums.rs`, `src/labels.rs`, `src/filters.rs`
- Move: `modules/hosts/galactica/services/plab/fixtures/*` → **copy** (not move; the Python still uses them until Task 18) to `packages/plab/tests/fixtures/`
- Test: port `test_parse.py` (12), `test_forums.py` (5), `test_labels.py` (18); and the filter/exclude tests from plab `test_main.py` (`load_filters`, `load_excludes`, `exclude_predicate`, `match_filters` tests).

**Interfaces:**
- Produces:

```rust
// tracker/parse.rs  (port of parse.py; regex crate, (?s) where Python used re.S)
pub fn logged_in(page: &str) -> bool;
pub fn needs_captcha(page: &str) -> bool;
pub fn daily_limit(page: &str) -> Option<u32>;
pub fn info_message(page: &str) -> Option<String>;
pub fn rows(page: &str) -> Vec<Row>;
pub fn page_link(page: &str, start: usize) -> Option<String>;
pub fn images(page: &str) -> Vec<String>;
pub fn html_unescape(s: &str) -> String; // twin of html.unescape for the entities the tracker uses

// tracker/forums.rs
pub const GROUPS: &[(&str, &[u32])];   // verbatim, same order
pub const GAMES: &[u32];
pub fn forums() -> Vec<u32>;            // FORUMS: GROUPS flattened in order
pub fn category(forum: u32) -> &'static str; // "Other" if unknown

// labels.rs
#[derive(Debug, Clone, PartialEq)]
pub struct Labels { pub tags: Vec<String>, pub quality: Option<String>, pub studio: Option<String>,
                    pub category: &'static str, pub name: String }
pub fn labels(title: &str, forum: u32) -> Labels;
pub fn match_term(term: &str, title: &str) -> bool;
pub fn term_label(term: &str) -> String;
pub fn py_title(s: &str) -> String;     // str.title(): upper a cased char after a non-cased one, lower otherwise

// filters.rs
pub type Filters = Vec<(String, Vec<String>)>;
pub fn load_filters(path: Option<&std::path::Path>, state_dir: Option<&std::path::Path>) -> Filters;
pub fn load_excludes(path: Option<&std::path::Path>, state_dir: Option<&std::path::Path>) -> Vec<fancy_regex::Regex>;
pub fn excluded(patterns: &[fancy_regex::Regex], title: &str) -> bool; // exclude_predicate's negation
/// `found`: filter name → badge, for filters whose search returned the release.
pub fn match_filters(filters: &Filters, title: &str, found: Option<&std::collections::HashMap<String, String>>) -> (Vec<String>, Option<String>);
```

Port notes:
- `html.unescape`: implement named entities `&amp; &lt; &gt; &quot; &#39; &apos; &nbsp;` plus numeric `&#NNN;` and `&#xHH;`. Check the fixtures for any other named entity (`grep -o '&[a-z]*;' tests/fixtures/*.html | sort -u`) and add each one found.
- `_text`: strip tags with `<[^>]+>`, unescape, trim.
- `rows`: same split on `<tr class="tCenter">` within the `tor-tbl` tbody; same per-field regexes; missing field → 0.
- `labels._DATE` contains Cyrillic `г` — keep as is (regex crate is Unicode).
- `py_title` matches CPython for the ASCII + Cyrillic inputs the tests use: a char is "cased" if `is_alphabetic()`.
- Excludes are compiled case-insensitive with `fancy_regex::RegexBuilder` / `(?i)` prefix; Python `re.search` ⇒ `is_match`.
- `load_*` env fallback (`PLAB_FILTER_FILE`/`PLAB_EXCLUDE_FILE`) is NOT read here — `Config` passes the path in. When `path` is None, fall back to `<state_dir>/filter.txt` / `exclude.txt` as Python does.

- [ ] **Step 1: Copy fixtures** — `mkdir -p packages/plab/tests/fixtures && cp modules/hosts/galactica/services/plab/fixtures/* packages/plab/tests/fixtures/`. Mirror how `test_parse.py` reads them (UTF-8 or cp1251); the `fixture()` helper below handles both.
- [ ] **Step 2: Write failing tests** — port every named Python test, copying its literal expected values (ids, titles, sizes, counts) from the `.py` assertions on the same fixture. Load fixtures through one helper:

```rust
fn fixture(name: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name);
    let bytes = std::fs::read(path).unwrap();
    match std::str::from_utf8(&bytes) {
        Ok(s) => s.to_owned(),
        Err(_) => encoding_rs::WINDOWS_1251.decode(&bytes).0.into_owned(),
    }
}
```
- [ ] **Step 3: Run** `cargo test tracker:: labels:: filters::` → FAIL.
- [ ] **Step 4: Implement** the four modules per the Python.
- [ ] **Step 5: Run** → PASS; counts ≥ 12 / 5 / 18 plus the filter tests.
- [ ] **Step 6: Commit** — `git commit -m "feat(galactica): plab tracker parsing, labels and filters"`

---

### Task 4: Image cache and py helpers for bytes

**Files:**
- Create: `src/images.rs`
- Test: in-module; port `test_store.py`'s image tests (ensure_image, prune_images keeps tmp files) and plab `test_main.py`'s `sniff` tests.

**Interfaces:**
- Produces:

```rust
pub fn key(url: &str) -> String;                 // sha1 hex of the URL — MUST equal store.key(), so the imported img/ cache keeps working
pub fn sniff(data: &[u8]) -> Option<&'static str>;
pub struct ImageCache { pub dir: std::path::PathBuf }
impl ImageCache {
    pub fn new(dir: std::path::PathBuf) -> std::io::Result<ImageCache>;   // create_dir_all
    pub fn path(&self, url: &str) -> std::path::PathBuf;
    pub fn get(&self, url: &str) -> Option<Vec<u8>>;
    pub fn put(&self, url: &str, data: &[u8]) -> std::io::Result<std::path::PathBuf>; // tmp + rename, tmp name unique per call
    pub fn prune(&self, keep_urls: &[String]) -> std::io::Result<()>;       // skips names ending ".tmp"
}
```

`ensure_image` becomes an async helper in Task 8 (`get` or fetch→sniff→`put`).

- [ ] **Step 1: failing tests**

```rust
#[test]
fn key_is_sha1_hex_of_url() {
    assert_eq!(key("https://x/y.jpg").len(), 40);
    // hashlib.sha1(b"https://x/y.jpg").hexdigest()
    assert_eq!(key("https://x/y.jpg"), "a96fd4ace65037d5b2af3c163768cb4d3f3eaf44");
}
#[test]
fn sniff_types() {
    assert_eq!(sniff(b"\xff\xd8\xff\xe0"), Some("image/jpeg"));
    assert_eq!(sniff(b"\x89PNG\r\n\x1a\n...."), Some("image/png"));
    assert_eq!(sniff(b"GIF89a"), Some("image/gif"));
    assert_eq!(sniff(b"RIFF\0\0\0\0WEBPVP8 "), Some("image/webp"));
    assert_eq!(sniff(b"<html>"), None);
}
#[test]
fn prune_keeps_listed_and_tmp() {
    let d = tempfile::tempdir().unwrap();
    let c = ImageCache::new(d.path().into()).unwrap();
    c.put("a", b"1").unwrap(); c.put("b", b"2").unwrap();
    std::fs::write(d.path().join("x.tmp"), b"").unwrap();
    c.prune(&["a".into()]).unwrap();
    assert!(c.get("a").is_some()); assert!(c.get("b").is_none());
    assert!(d.path().join("x.tmp").exists());
}
```

- [ ] **Step 2: Run → FAIL. Step 3: Implement. Step 4: Run → PASS.**
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab image cache"`

---

### Task 5: Legacy JSON import

**Files:**
- Create: `src/db/import.rs`
- Modify: `src/db/mod.rs` (`open_with(path, Some(&legacy))` calls `import::run` inside migration 1's transaction)

**Interfaces:**
- Produces:

```rust
pub struct LegacyPaths {
    pub plab: std::path::PathBuf,           // dir with cache.json, games.json, search.json, added.json, queued.json, games-queued.json, cookies.txt
    pub stash_identify: std::path::PathBuf, // attempted.json, failures.json
    pub vault_grab: std::path::PathBuf,     // state.json
}
pub fn run(tx: &rusqlite::Transaction<'_>, legacy: &LegacyPaths, now: i64) -> anyhow::Result<ImportReport>;
#[derive(Debug, Default, PartialEq)]
pub struct ImportReport { pub video: usize, pub games: usize, pub search: usize, pub added: usize,
                          pub queued: usize, pub grab_keys: usize, pub identify: usize, pub cookies: bool }
```

- Consumes: `tracker::cookies::CookieJar::from_netscape` (Task 6). To keep task order, import stores the raw `cookies.txt` text in `kv` under `tracker_cookies_netscape`; Task 6's `Tracker` converts it on first load and replaces it with `tracker_cookies` JSON.

Mapping (exact):
- `cache.json` → topics + `listing(video)`; `listing_meta(video)` from `updated`/`filters` (missing `filters` → `[]`). Each topic's `filters`/`curated_reason` go on the listing row; `images`, `production` on the topic.
- `games.json` → same for `games`.
- `search.json` → `{id: {...row, images, at}}` → topic + `search_hit(at)`; skip entries with `now - at > SEARCH_TTL`.
- `added.json` (list of ints) → `download(source='plab', state='added', topic_id, section = section of the list containing it else 'video', release_title = known title else '', download_dir NULL, added_at NULL)`.
- `queued.json` / `games-queued.json` → `download(state='queued', section, queued_at = now + index)` (keeps order) unless the id is already added.
- vault-grab `state.json` `{"studios": {studio: {key: {"title","at"}}}}` → `grab_seen`.
- `attempted.json` (list of string ids) → `identify_attempt(done=1)`; `failures.json` `{id: n}` → `failures = n` (upsert).
- Missing file: skip. Unparseable file: `bail!("legacy import: {path}: {err}")` — aborts the transaction; the daemon exits.
- Log one line with the report: `imported legacy state: …`.

- [ ] **Step 1: failing tests** — build a tempdir with small JSON files mirroring the real shapes (copy the shapes from the Task 0 investigation: `cache.json` keys `updated, topics, filters`; topic keys `id,title,forum,size,seeders,leechers,completed,added,images,filters,curated_reason,production`). Tests:
  - `imports_everything` — full set; assert `ImportReport` counts and that `Db` queries return the imported data (open via `Db::open_with`).
  - `missing_files_are_skipped` — empty dirs → `ImportReport::default()`, `user_version == 1`.
  - `corrupt_file_aborts` — `added.json` = `"[1,"` → `Db::open_with` errors mentioning `added.json`; reopening with a fixed file succeeds (transaction rolled back, `user_version` still 0 before).
  - `queued_already_added_is_dropped`.
  - `expired_search_entries_are_skipped`.
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab one-time import of the legacy json state"`

---

### Task 6: Tracker client (session, login, torrent)

**Files:**
- Create: `src/tracker/cookies.rs`, fill `src/tracker/mod.rs`, create `src/http.rs`
- Test: port `test_lab.py` (30) using wiremock as the tracker (`Tracker::new` takes `base`).

**Interfaces:**
- Produces:

```rust
// http.rs
pub fn client(timeout_secs: u64) -> reqwest::Client;   // rustls, no redirects (Policy::none()), given timeout
pub async fn post_json(c: &reqwest::Client, url: &str, body: &serde_json::Value, headers: &[(&str, String)]) -> anyhow::Result<serde_json::Value>; // error_for_status
pub async fn get_json(c: &reqwest::Client, url: &str, headers: &[(&str, String)]) -> anyhow::Result<serde_json::Value>;

// tracker/cookies.rs
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CookieJar(pub std::collections::BTreeMap<String, String>);
impl CookieJar {
    pub fn header(&self) -> Option<String>;                    // "a=1; b=2"
    pub fn apply_set_cookie(&mut self, header: &str);          // Max-Age<=0 or Expires in the past → remove
    pub fn from_netscape(text: &str) -> CookieJar;             // cookies.txt; keeps tracker.example.org cookies
    pub fn set(&mut self, name: &str, value: &str);
}

// tracker/mod.rs
#[derive(Debug, thiserror::Error)]
pub enum TrackerError {
    #[error("{0}")] Login(String),               // LoginError
    #[error("daily download limit reached ({0}/day)")] Limit(u32),   // LimitError
    #[error("{0}")] Tracker(String),             // TrackerError
    #[error(transparent)] Http(#[from] reqwest::Error),
}
pub const BASE: &str = "https://tracker.example.org/forum/";

pub trait TrackerApi: Send + Sync {
    fn top(&self, forums: &[u32], days: u32, limit: usize, excludes: &[fancy_regex::Regex])
        -> impl std::future::Future<Output = Result<Vec<Row>, TrackerError>> + Send;
    fn search(&self, query: &str, forums: &[u32], days: Option<u32>, limit: usize,
              excludes: &[fancy_regex::Regex], pages: Option<usize>)
        -> impl std::future::Future<Output = Result<Vec<Row>, TrackerError>> + Send;
    fn topic(&self, topic_id: u64) -> impl std::future::Future<Output = Result<String, TrackerError>> + Send;
    fn torrent(&self, topic_id: u64) -> impl std::future::Future<Output = Result<Vec<u8>, TrackerError>> + Send;
    fn fetch(&self, url: &str) -> impl std::future::Future<Output = Result<Vec<u8>, TrackerError>> + Send;
}

pub struct Tracker { /* http, base, username, password, db, jar: std::sync::Mutex<(CookieJar, i64 /*kv rev loaded*/)>,
                       login: tokio::sync::Mutex<LoginState>, logins: AtomicU64 */ }
impl Tracker {
    pub fn new(base: &str, username: String, password: String, db: Db) -> Tracker;
    pub async fn page(&self, path: &str) -> Result<String, TrackerError>;
    pub async fn login(&self, seen: u64) -> Result<(), TrackerError>;
    pub fn set_cookie(db: &Db, value: &str) -> anyhow::Result<()>; // used by `plab set-cookie`: load jar from kv, set bb_data, save
}
impl TrackerApi for Tracker { … }
```

Behaviour (port of `lab.py`, with the cookie file replaced by `kv`):
- `open(url, form)`: build request with UA and `Cookie: jar.header()`; on response apply every `Set-Cookie`; on 301/302/303/307 with `Location`, resolve against the request URL and GET it (max 5 hops; POST becomes GET, as urllib does). Return body bytes. Timeout 60 s.
- Decode pages with `encoding_rs::WINDOWS_1251` (replacement on error).
- Login body: form-urlencoded `login_username`, `login_password`, `login=Вход`, **encoded as cp1251** (`form_urlencoded::Serializer::new(String::new()).encoding_override(Some(&|s| std::borrow::Cow::Owned(encoding_rs::WINDOWS_1251.encode(s).0.into_owned())))`).
- Persistence: after every logged-in page/torrent, if the kv rev hasn't moved since we loaded (`_save_session`), save jar JSON to `kv["tracker_cookies"]` and remember the new rev. Before trying a login, `reload_if_newer`: if `kv` rev > loaded rev, reload the jar and clear the login backoff. On first load, if `tracker_cookies` is absent but `tracker_cookies_netscape` exists, convert it with `from_netscape`, store as `tracker_cookies`, and delete the netscape key.
- `login(seen)`: under the tokio mutex: if `logins != seen` return Ok (someone else logged in); if last failure < 300 s ago return that error again; else post; on captcha → `Login("login needs captcha")`; not logged in → `Login("login failed")`.
- `page` and `torrent`: the same retry state machine as Python (one reload, then at most one login, then `Login("still logged out after login: …")`). `torrent` checks `^d\d+:` on bytes; a logged-in non-torrent reply → `Limit(n)` via `daily_limit` or `Tracker(info_message or "no torrent for topic {id}")`.
- `top`/`search`: query built with `form_urlencoded` (`f[]` repeated, `o=10`, `s=2`, `tm`/`nm`), pager via `page_link` starting at 50 step 50, filtering rows by `!filters::excluded(excludes, &row.title)`.
- `fetch(url)`: plain GET (no cookies needed beyond the jar; follow redirects as above).

- [ ] **Step 1: failing tests** — port `test_lab.py`. The Python tests use a fake opener; replace with a wiremock `MockServer` whose base URI + `/forum/` is passed as `base`. Example:

```rust
#[tokio::test]
async fn page_logs_in_once_when_logged_out() {
    let server = wiremock::MockServer::start().await;
    let db = Db::open_in_memory().unwrap();
    let logged_out = "<html>login</html>";
    let logged_in = "<html>{logout: 1}</html>";
    wiremock::Mock::given(wiremock::matchers::method("GET")).and(wiremock::matchers::path("/forum/x.php"))
        .respond_with(wiremock::ResponseTemplate::new(200).set_body_string(logged_out))
        .up_to_n_times(1).mount(&server).await;
    wiremock::Mock::given(wiremock::matchers::method("POST")).and(wiremock::matchers::path("/forum/login.php"))
        .respond_with(wiremock::ResponseTemplate::new(200).set_body_string(logged_in)
            .insert_header("Set-Cookie", "bb_data=abc; path=/forum/"))
        .expect(1).mount(&server).await;
    wiremock::Mock::given(wiremock::matchers::method("GET")).and(wiremock::matchers::path("/forum/x.php"))
        .and(wiremock::matchers::header("Cookie", "bb_data=abc"))
        .respond_with(wiremock::ResponseTemplate::new(200).set_body_string(logged_in))
        .mount(&server).await;
    let t = Tracker::new(&format!("{}/forum/", server.uri()), "u".into(), "p".into(), db.clone());
    assert!(t.page("x.php").await.unwrap().contains("{logout: 1}"));
    assert!(db.kv_get("tracker_cookies").unwrap().unwrap().0.contains("abc"));
}
```

  Plus cookie-jar unit tests: `apply_set_cookie` add/replace/delete (`Max-Age=0`), `from_netscape` on a sample with a `#HttpOnly_.tracker.example.org` line (MozillaCookieJar writes that prefix — strip it), `header` ordering.
- [ ] **Step 2–4:** FAIL → implement → PASS (≥ 30 ported + jar tests).
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab tracker client with the session in sqlite"`

---

### Task 7: Transmission, prune, Prowlarr client

**Files:**
- Create: `src/transmission.rs`, `src/prune.rs`, `src/prowlarr.rs`
- Test: port `test_transmission.py` (6), `test_prune.py` (10), and the `api_key`/`search`/`fetch` tests from vault-grab `test_main.py`; plab `test_main.py`'s `run_prune` tests.

**Interfaces:**
- Produces:

```rust
// transmission.rs
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackerAnnounce { #[serde(default)] pub announce: String }
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Torrent { pub id: i64, pub name: String, pub download_dir: String, pub percent_done: f64,
                     pub upload_ratio: f64, pub done_date: i64, pub activity_date: i64,
                     #[serde(default)] pub trackers: Vec<TrackerAnnounce> }
pub enum TorrentSource { Bytes(Vec<u8>), Magnet(String) }
#[derive(Debug, Clone, PartialEq)]
pub struct Added { pub name: String, pub hash: Option<String> }
pub const FIELDS: [&str; 8] = ["id", "name", "downloadDir", "percentDone", "uploadRatio", "doneDate", "activityDate", "trackers"];
pub trait TorrentClient: Send + Sync {
    fn add(&self, src: &TorrentSource, download_dir: &str) -> impl std::future::Future<Output = anyhow::Result<Added>> + Send;
    fn torrents(&self) -> impl std::future::Future<Output = anyhow::Result<Vec<Torrent>>> + Send;
    fn remove(&self, ids: &[i64]) -> impl std::future::Future<Output = anyhow::Result<()>> + Send;
}
pub struct Transmission { /* http, url, session: std::sync::Mutex<String> */ }
impl Transmission { pub fn new(url: &str) -> Transmission; }
// add asks Transmission for torrent-added / torrent-duplicate {name, hashString}; duplicate is not an error.
// Session id: retry once on 409 with X-Transmission-Session-Id; remember it for later calls.
// Errors: "HTTP {code}", reply result != "success" → that string, "no session id after 409".

// prune.rs
pub fn decide(torrents: &[Torrent], now: f64, dirs: &[String]) -> Vec<(i64, String, String)>;
pub async fn run_prune<C: TorrentClient>(c: &C, dirs: &[String], now: f64, dry_run: bool) -> anyhow::Result<Vec<(i64, String, String)>>;
// logs "would remove {name}: {reason}" / "removed {name}: {reason}"; one remove call.

// prowlarr.rs
pub fn api_key(config_xml: &std::path::Path) -> anyhow::Result<String>;
pub struct Prowlarr { /* http (300 s timeout), base, key */ }
impl Prowlarr {
    pub fn new(base: &str, key: String) -> Prowlarr;
    pub async fn search(&self, query: &str) -> anyhow::Result<Vec<serde_json::Value>>; // /api/v1/search?query=&type=search&limit=100, X-Api-Key
    pub async fn fetch(&self, url: &str) -> anyhow::Result<TorrentSource>; // 3xx Location magnet: → Magnet; body must start with b'd' else "not a .torrent ({first 40 bytes:?})"
}
```

Reason strings in `decide` must match Python exactly, e.g. `format!("ratio {:.2}", ratio)`, `format!("idle {:.1}d, ratio {:.2}", idle, ratio)`, `format!("over {} seeding, idle {:.1}d, ratio {:.2}", MAX_SEEDING, idle, ratio)`, `"complete, not the tracker's"`. `_is_lab`: tracker hostname (via `url::Url::parse(...).host_str()`) contains one of the tracker's host names. Sort seeding by idle desc with a stable sort.

- [ ] **Step 1: failing tests** (port; transmission tests via wiremock including the 409 handshake).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab transmission, prune and prowlarr clients"`

---

### Task 8: OpenRouter client (classifier, parse, translate, Jev choice)

**Files:**
- Create: `src/llm.rs`
- Test: port `test_classify.py` (5) and `test_llm.py` (2) via wiremock.

**Interfaces:**
- Produces:

```rust
pub const CHAT_PATH: &str = "/api/v1/chat/completions";
pub const DECISIONS_PATH: &str = "/api/alpha/decisions";
pub const OPENROUTER: &str = "https://openrouter.ai";
pub struct OpenRouter { /* http (120 s), base, key, parse_model, jev_model, translations: std::sync::Mutex<HashMap<String,String>> */ }
impl OpenRouter {
    pub fn new(base: &str, key: String, parse_model: String, jev_model: String) -> OpenRouter;
}
pub trait Classify: Send + Sync {
    fn classify(&self, title: &str, category: &str) -> impl std::future::Future<Output = anyhow::Result<crate::db::Production>> + Send;
}
pub trait Llm: Send + Sync {
    fn parse(&self, path: &str) -> impl std::future::Future<Output = anyhow::Result<serde_json::Value>> + Send;
    fn translate_title(&self, title: &str) -> impl std::future::Future<Output = anyhow::Result<String>> + Send;
    /// One Jev decision; `state`/`questions` come from `identify::matching::jev_request` (Task 13).
    /// Returns `answers.match`.
    fn choose(&self, state: serde_json::Value, questions: serde_json::Value)
        -> impl std::future::Future<Output = anyhow::Result<serde_json::Value>> + Send;
}
impl Classify for OpenRouter { … }   // INSTRUCTIONS, CRITERIA verbatim from classify.py; CRITERIA in insertion order
impl Llm for OpenRouter { … }        // PARSE_PROMPT, TRANSLATE_PROMPT verbatim from llm.py; one re-ask on malformed JSON
```

`choose` posts `{"model": jev_model, "state": state, "questions": questions}` to the decisions endpoint. Task 14 builds `(state, questions)` with `jev_request` and calls it.

Classifier errors: unexpected choice → `bail!("unexpected production choice: {choice:?}")` formatted like Python's `{!r}` (use `py::repr` from Task 9 if already present; otherwise `format!("'{}'", s)` for strings and `None` for null).

- [ ] **Step 1: failing tests** (port; assert request bodies with `wiremock::matchers::body_partial_json`).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab openrouter client"`

---

### Task 9: Page renderer (byte-identical)

**Files:**
- Create: `src/py.rs`, `src/page.rs`, `assets/page.css`, `assets/page.js`
- Test: port `test_page.py` (59).

**Interfaces:**
- Produces:

```rust
// py.rs
pub fn escape(s: &str) -> String;                    // html.escape(s, quote=True): & < > " '  →  &amp; &lt; &gt; &quot; &#x27;
pub fn json(v: &serde_json::Value) -> String;        // json.dumps defaults: ", " / ": ", ensure_ascii (\uNNNN, surrogate pairs), floats like Python repr
pub fn repr_str(s: Option<&str>) -> String;          // repr() of a str or None
// page.rs
pub const TOPIC_URL: &str = "https://tracker.example.org/forum/viewtopic.php?t=";
pub fn score(t: &crate::db::Listed) -> f64;
pub fn size(n: u64) -> String;
pub fn age(updated: i64, now: i64) -> String;
pub struct SearchInfo<'a> { pub query: &'a str, pub error: Option<&'a str> }
pub fn render(listing: &crate::db::Listing, added: &std::collections::HashSet<u64>, queued: &std::collections::HashSet<u64>,
              now: i64, search: Option<SearchInfo<'_>>, section: crate::db::Section) -> String;
```

Port notes:
- `assets/page.css` = the `CSS` string from `assets.py` exactly (starts with a newline); `assets/page.js` = `JS` exactly (`FILTER_JS` is empty). Extract them with Python to avoid hand-copy errors:
  `cd modules/hosts/galactica/services/plab && python3 -c 'import assets;open("../../../../../packages/plab/assets/page.css","w").write(assets.CSS);open("../../../../../packages/plab/assets/page.js","w").write(assets.JS)'`
- `render` uses `include_str!("../assets/page.css")` / `page.js`.
- `_card`'s `cfg` and `keys_json` go through `py::json` then `py::escape`; tag literals inside `:class`/`@click` use `py::json(&Value::String(tag))`.
- `Counter` ordering: sort `(-count, value)`.
- `time.strftime("%Y-%m-%d", gmtime(added))` → `chrono::DateTime::from_timestamp(added, 0).format("%Y-%m-%d")`.
- `size()`: Python divides `n /= 1024` as float after the first step; replicate (`f64`), `"{n} B"` uses the integer.
- `score` sorting: stable `sort_by` descending with `partial_cmp`, ties keep listing order.
- `py::json` float formatting: Python prints `0.87` as `0.87`, `1.0` as `1.0`; use Rust `{:?}` for f64 (shortest round-trip, prints `1.0`) — confirm with a test against `json.dumps({"c": 1.0, "d": 0.1})` → `{"c": 1.0, "d": 0.1}`.

- [ ] **Step 1: Extract assets** (command above), `git add packages/plab/assets`.
- [ ] **Step 2: failing tests** — port all 59. Plus a golden test: generate a golden page from Python for a fixed state and compare byte-for-byte:

```bash
cd modules/hosts/galactica/services/plab && python3 - <<'EOF' > ../../../../../packages/plab/tests/fixtures/golden_page.html
import page
cache = {"updated": 1700000000, "filters": ["Fav"], "topics": [
  {"id": 1, "title": "[Studio.com] Jane Doe - Title [2026 г., Alpha, Beta, 1080p]", "forum": 1875, "size": 829307737,
   "seeders": 292, "leechers": 3, "completed": 1, "added": 1700000000 - 3600,
   "images": ["https://i/a.jpg", "https://i/b.jpg"], "filters": ["Fav"], "curated_reason": "Jane",
   "production": {"class": "amateur", "confidence": 0.9}},
  {"id": 2, "title": "Плохой \"title\" <x> & 'y'", "forum": 1823, "size": 500, "seeders": 5, "leechers": 0,
   "completed": 0, "added": 1600000000, "images": [], "filters": []},
  {"id": 3, "title": "Search hit", "forum": 1, "size": 2048, "seeders": 1, "leechers": 1, "completed": 0,
   "added": 1690000000, "images": None, "filters": []}]}
print(page.render(cache, {2}, {1}, 1700000000), end="")
EOF
```

  and the Rust test builds the same `Listing` and asserts `render(...) == include_str!("../tests/fixtures/golden_page.html")`. Add a second golden for `section=games` and a third for a search with an error (`search={"query": "q", "error": "boom"}`).
- [ ] **Step 3–5:** FAIL → implement → PASS.
- [ ] **Step 6: Commit** — `git commit -m "feat(galactica): plab page renderer, byte-identical to page.py"`

---

### Task 10: plab domain — refresh, add, queue, search, images

**Files:**
- Create: `src/plab.rs`
- Test: port plab `test_main.py` (82) — every test except HTTP-handler ones (Task 11) and those already ported in Tasks 3/4/7. Fakes: `FakeTracker` implementing `TrackerApi` (scripted rows/topic pages/torrents/errors, records calls), `FakeTorrents` implementing `TorrentClient`, `FakeClassify` implementing `Classify`.

**Interfaces:**
- Consumes: `TrackerApi`, `TorrentClient`, `Classify`, `Db`, `ImageCache`, `filters::*`, `forums::*`, `tracker::parse::images`, `images::{key, sniff}`.
- Produces:

```rust
pub const DAYS: u32 = 7;
pub const GAMES_DAYS: u32 = 32;
pub const LIMIT: usize = 100;
pub const DELAY: std::time::Duration = std::time::Duration::from_secs(1);
pub const CLASSIFY_FAILURE_LIMIT: u32 = 3;
pub const SEARCH_LIMIT: usize = 50;

pub struct Ctx<'a, T: TrackerApi, C: TorrentClient> {
    pub tracker: &'a T, pub torrents: &'a C, pub db: &'a Db, pub images: &'a ImageCache,
    pub state_dir: &'a std::path::Path, pub exclude_file: Option<&'a std::path::Path>,
    pub filter_file: Option<&'a std::path::Path>, pub download_dir: &'a str, pub games_dir: Option<&'a str>,
    pub delay: std::time::Duration,   // DELAY in production, ZERO in tests
    pub fetch_slots: &'a tokio::sync::Semaphore, // 2 permits
}

pub async fn ensure_image<T: TrackerApi>(tracker: &T, images: &ImageCache, url: &str) -> anyhow::Result<std::path::PathBuf>; // "not an image: {url}"
pub async fn refresh<T, C, K: Classify>(ctx: &Ctx<'_, T, C>, section: Section, classify: Option<&K>, now: i64) -> anyhow::Result<()>;
pub enum AddResult { Added { name: String }, AlreadyAdded, Queued { message: String } }
pub async fn add_topic<T, C>(ctx: &Ctx<'_, T, C>, topic_id: u64, now: i64) -> anyhow::Result<AddResult>;
pub fn unqueue_topic(db: &Db, topic_id: u64) -> anyhow::Result<()>;
pub async fn drain_queue<T, C>(ctx: &Ctx<'_, T, C>, section: Section, dir: &str, now: i64) -> Result<bool, TrackerError>;
pub async fn run_refresh<T, C, K: Classify>(ctx: &Ctx<'_, T, C>, classify: Option<&K>, now: i64) -> anyhow::Result<()>;
pub async fn run_search<T, C>(ctx: &Ctx<'_, T, C>, query: &str, now: i64) -> anyhow::Result<Vec<Listed>>;
pub async fn topic_images<T, C>(ctx: &Ctx<'_, T, C>, topic_id: u64, now: i64) -> anyhow::Result<Vec<String>>; // NotListed error → 404
pub async fn image_for<T, C>(ctx: &Ctx<'_, T, C>, image_key: &str, now: i64) -> anyhow::Result<Option<(Vec<u8>, &'static str)>>;
#[derive(Debug, thiserror::Error)] #[error("topic {0} is not on the list")] pub struct NotListed(pub u64);
```

Port notes:
- `refresh(section)`: video uses `forums()`, `DAYS`, filters + classify; games uses `GAMES`, `GAMES_DAYS`, no filters, no classify — exactly `run_refresh`'s two runs. `previous` images/production come from the existing listing. Errors: `TrackerError::Login` propagates immediately everywhere Python re-raises `LoginError`. After `save_listing`, `images.prune(&db.image_urls(now)?)`. Final log line verbatim: `refreshed {section}: {n} topics ({c} curated, {k} classified)`.
- `add_topic`: `AlreadyAdded` reply maps to Python's `{"name": "already added"}` in Task 11. On success call `db.mark_added(NewDownload { source: "plab", topic_id: Some(id), release_title: &topic.row.title, section, download_dir: Some(dir), torrent_hash: added.hash.as_deref(), now })`. On `Limit` → `db.enqueue` and `Queued { message: err.to_string() }`.
- `drain_queue`: dequeue-then-mark order preserved as Python (`dequeue` first, then `mark_added`).
- `run_refresh`: drain video then games (stop at first `false`), list refreshes each isolated; `Login` propagates; first other error returned at the end.
- `topic_images`: when images are `None`, take a `fetch_slots` permit, re-check, fetch, `db.set_images`.
- `image_for`: only keys of `db.image_urls(now)` resolve.

- [ ] **Step 1: failing tests** (port 82 minus handler/already-ported; keep names).
- [ ] **Step 2–4:** FAIL → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab refresh, add, queue and search"`

---

### Task 11: Web server

**Files:**
- Create: `src/web.rs`
- Test: port the HTTP-handler tests of plab `test_main.py` using `axum::Router` + `tower::ServiceExt::oneshot` (add `tower = { version = "0.5", features = ["util"] }` to dev-dependencies) with fake clients.

**Interfaces:**
- Consumes: Task 10 functions, `page::render`.
- Produces:

```rust
pub struct WebState<T: TrackerApi, C: TorrentClient> {
    pub tracker: std::sync::Arc<T>, pub torrents: std::sync::Arc<C>, pub db: Db, pub images: ImageCache,
    pub cfg: std::sync::Arc<crate::config::Config>, pub fetch_slots: std::sync::Arc<tokio::sync::Semaphore>,
    pub add_lock: std::sync::Arc<tokio::sync::Mutex<()>>,
}
pub fn router<T: TrackerApi + 'static, C: TorrentClient + 'static>(state: std::sync::Arc<WebState<T, C>>) -> axum::Router;
pub async fn serve(router: axum::Router, bind: &str, port: u16) -> anyhow::Result<()>;
pub const STATIC: [(&str, &str); 4] = [("daisyui.css", "text/css; charset=utf-8"), ("themes.css", "text/css; charset=utf-8"),
    ("tailwind.js", "text/javascript; charset=utf-8"), ("alpine.js", "text/javascript; charset=utf-8")];
```

Routes, status codes, headers and bodies exactly as `make_handler`:
- `GET /` and `/games` → list (excludes applied at render), `Cache-Control: no-store`.
- `GET /search?q=` → empty q → `302 Location: ./`; error text rendered on the page.
- `GET /thumb/{id}` → `302 ../img/<key>` or `404 no images` / `404 <NotListed msg>` / `502 images unavailable`; `GET /images/{id}` → `{"images": [keys]}` JSON.
- `GET /static/{name}` → allowlist only, `Cache-Control: public, max-age=86400`.
- `GET /img/{40 hex}` → `private, max-age=604800`; `502 image unavailable` on error; otherwise `404 not found`.
- `POST /add/{id}`, `POST /unqueue/{id}` under `add_lock` → `{"ok": true, ...}` (`name` / `queued`+`message`) or `502 {"ok": false, "error": ...}`. JSON bodies via `py::json` so key order and spacing match Python.
- Anything else → `404 not found` `text/plain`.
- Log lines `"{action} {id}: {result}"` / `"… failed: {e}"` at info level with `job="web"`.

- [ ] **Step 1–4:** failing tests → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab web routes"`

---

### Task 12: Grab (vault-grab)

**Files:**
- Create: `src/grab.rs`
- Test: port the remaining vault-grab `test_main.py` tests (31 total minus those done in Task 7).

**Interfaces:**
- Produces:

```rust
pub struct Rule { pub name: String, pub query: String, pub pattern: fancy_regex::Regex /* (?i)^(?:<match>) */ }
pub fn load_rules(path: &std::path::Path) -> anyhow::Result<Vec<Rule>>;   // errors: "{path}:{n}: unexpected line {line:?}", "[{name}] is missing {fields}", "[{name}] match: {err}"
pub fn skip_reason(rule: &Rule, result: &serde_json::Value, now: chrono::DateTime<chrono::Utc>) -> anyhow::Result<Option<&'static str>>;
pub fn scene_keys(rule: &Rule, title: &str) -> std::collections::BTreeSet<String>;
pub fn choose(cands: Vec<(serde_json::Value, std::collections::BTreeSet<String>)>) -> Vec<(serde_json::Value, std::collections::BTreeSet<String>)>;
pub trait GrabSource: Send + Sync {
    fn search(&self, query: &str) -> impl std::future::Future<Output = anyhow::Result<Vec<serde_json::Value>>> + Send;
    fn fetch(&self, url: &str) -> impl std::future::Future<Output = anyhow::Result<crate::transmission::TorrentSource>> + Send;
}
impl GrabSource for crate::prowlarr::Prowlarr { … }
pub async fn run<S: GrabSource, C: TorrentClient>(rules: &[Rule], src: &S, torrents: &C, db: &Db, download_root: &str,
    now: chrono::DateTime<chrono::Utc>, dry_run: bool) -> anyhow::Result<i32>; // exit status: 1 if any studio's search failed
```

Port notes:
- `YEAR` uses lookaround → `fancy_regex`. `HD`, `JUNK`, `EPISODE` → `regex` with `(?i)`.
- Rule `match` is anchored like Python `re.match`: compile `(?i)^(?:{match})`, and `scene_keys` uses the end of that match.
- `choose` merges groups transitively and ranks by `(indexer == "Tracker", -seeders)`, `min` = first minimal in insertion order (Python `min` keeps the first).
- On a grab: `torrents.add(src, &format!("{root}/{name}"))`, then `db.mark_added(NewDownload { source: "grab", topic_id: None, release_title: title, section: Section::Video, download_dir: Some(dir), torrent_hash, now })`, then `db.record_grab(rule, keys, title, now.to_rfc3339(), Some(id))`. `at` must look like Python's `isoformat()` (`2026-10-24T19:17:41.530317+00:00`): use `now.format("%Y-%m-%dT%H:%M:%S%.6f%:z")`.
- Log lines verbatim (`[{name}] {n} results, {s} scenes, {k} new`, `would grab …`, `grabbed … as {name:?}` with Python repr quoting via `py::repr_str`).

- [ ] **Step 1–4:** failing tests → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab grab, ported from vault-grab"`

---

### Task 13: Identify matching (pure)

**Files:**
- Create: `src/identify/matching.rs`, `src/identify/mod.rs` (`pub mod matching;` only for now)
- Test: port `test_match.py` (46).

**Interfaces:**
- Produces (all on `serde_json::Value` shapes, as Python dicts):

```rust
pub const DURATION_TOLERANCE: f64 = 10.0;
pub fn norm(s: Option<&str>) -> String;
pub fn studio_name(c: &Value) -> Option<String>;
pub fn scene_key(c: &Value) -> (String, String);
pub fn duration_ok(c: &Value, file_duration: f64) -> bool;
pub fn dedupe(cands: Vec<(String, Value)>) -> Vec<(String, Value)>;
pub fn deterministic_match(cands: &[(String, Value)], parse: &Value) -> Option<(String, Value)>;
pub fn twins(chosen: &(String, Value), all: &[(String, Value)], file_duration: f64) -> Vec<(String, Value)>;
pub fn product_code(path: &str) -> Option<String>;
pub fn fc2_number(code: &str) -> Option<String>;
pub fn code_key(s: Option<&str>) -> Option<(String, u64)>;
pub fn single_scene(cands: Vec<Value>) -> Option<Value>;
pub fn codedb_scene(hit: &Value) -> Value;
pub fn fc2_scene(hit: &Value, title: &str) -> Value;
pub fn describe(c: &Value) -> String;
pub fn stash_ids_for(endpoint: &str, remote_id: Option<&str>) -> Vec<Value>;
pub fn performer_create_input(p: &Value, endpoint: &str) -> Value;
pub fn studio_create_input(s: &Value, endpoint: &str, parent_id: Option<&str>) -> Value;
pub fn alias_ok(name: &str) -> bool;
pub fn pick_by_name(records: &[Value], name: &str, alias_field: &str, allow_alias: bool) -> Option<String>;
pub fn scrape_update(scene: &Value, primary: &Value, stash_ids: &[Value], studio_id: Option<&str>, performer_ids: &[String],
                     tag_ids: &[String], drop_tag_ids: &std::collections::HashSet<String>, overwrite: bool) -> Value;
pub fn display_title(parse: &Value) -> Option<String>;
pub fn llm_update(scene: &Value, parse: &Value, studio_id: Option<&str>, performer_ids: &[String], llm_tag_id: &str) -> Value;
pub fn jev_request(path: &str, duration: f64, parse: &Value, cands: &[(String, Value)]) -> (Value, Value);
pub fn jev_pick(answer: &Value, cands: &[(String, Value)]) -> anyhow::Result<Option<(String, Value)>>;
```

Port notes: Python truthiness — `c.get("x")` falsy for `None`, `""`, `0`, `[]`, `{}`; write one helper `fn truthy(v: Option<&Value>) -> bool` and use it everywhere Python tests truthiness. `_compact` drops `None`, `""`, `[]`. `jev_request` rounds duration with `round_ties_even`. Output `Value` objects must keep Python's key insertion order (`preserve_order`).

- [ ] **Step 1–4:** failing tests → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab identify matching"`

---

### Task 14: Stash and code-database clients, identify pass

**Files:**
- Create: `src/stash.rs`, `src/codedb.rs`; fill `src/identify/mod.rs`
- Test: port stash-identify `test_main.py` (72) except watcher tests (Task 15), using `FakeStash`, `FakeLlm`, `FakeCodeDb` implementing the traits below.

**Interfaces:**
- Produces:

```rust
// stash.rs — queries verbatim from stash.py (SCENE_FIELDS, SCRAPED_FIELDS, DEFAULTS_QUERY, …)
#[derive(Debug, thiserror::Error)] #[error("{0}")] pub struct GqlError(pub String);   // Python RuntimeError(errors)
#[derive(Debug, thiserror::Error)] #[error("{0}")] pub struct JobFailed(pub String);
pub trait StashApi: Send + Sync {
    fn defaults(&self) -> impl Future<Output = anyhow::Result<Value>> + Send;
    fn video_extensions(&self) -> impl Future<Output = anyhow::Result<Vec<String>>> + Send;
    fn codedb_api_key(&self) -> impl Future<Output = anyhow::Result<Option<String>>> + Send;
    fn scan(&self, paths: Option<Vec<String>>, options: &Value) -> impl Future<Output = anyhow::Result<()>> + Send;
    fn generate(&self, scene_ids: Option<Vec<String>>, options: &Value) -> impl Future<Output = anyhow::Result<()>> + Send;
    fn identify(&self, scene_ids: Vec<String>, options: &Value) -> impl Future<Output = anyhow::Result<()>> + Send;
    fn max_scene_id(&self) -> impl Future<Output = anyhow::Result<i64>> + Send;
    fn scene_ids_after(&self, id: i64) -> impl Future<Output = anyhow::Result<Vec<String>>> + Send;
    fn scenes(&self, ids: &[String]) -> impl Future<Output = anyhow::Result<Vec<Value>>> + Send;
    fn bare_scenes(&self) -> impl Future<Output = anyhow::Result<Vec<Value>>> + Send;
    fn scenes_with_tag(&self, tag_id: &str) -> impl Future<Output = anyhow::Result<Vec<Value>>> + Send;
    fn search(&self, endpoint: &str, query: &str) -> impl Future<Output = anyhow::Result<Vec<Value>>> + Send;
    fn scrape_url(&self, url: &str) -> impl Future<Output = anyhow::Result<Option<Value>>> + Send;
    fn performer_by_stash_id(&self, endpoint: &str, id: &str) -> impl Future<Output = anyhow::Result<Option<String>>> + Send;
    fn studio_by_stash_id(&self, endpoint: &str, id: &str) -> impl Future<Output = anyhow::Result<Option<String>>> + Send;
    fn performers_like(&self, name: &str) -> impl Future<Output = anyhow::Result<Vec<Value>>> + Send;
    fn studios_like(&self, name: &str) -> impl Future<Output = anyhow::Result<Vec<Value>>> + Send;
    fn tag_id(&self, name: &str, create: bool) -> impl Future<Output = anyhow::Result<Option<String>>> + Send;
    fn create_performer(&self, inp: &Value) -> impl Future<Output = anyhow::Result<String>> + Send;
    fn create_studio(&self, inp: &Value) -> impl Future<Output = anyhow::Result<String>> + Send;
    fn update_scene(&self, inp: &Value) -> impl Future<Output = anyhow::Result<()>> + Send;
}
pub struct Stash { /* http (120 s), url, api_key: Option<String> */ }
impl Stash { pub fn new(url: &str, api_key: Option<String>) -> Stash; }
// _run_job polls every JOB_POLL (5 s) up to JOB_TIMEOUT (6 h) with tokio::time::sleep.

// codedb.rs
pub const CODE_URL: &str = "https://api.codedb.example.org/codes";
pub trait CodeSearch: Send + Sync {
    fn code_search(&self, code: &str) -> impl Future<Output = Result<Vec<Value>, CodeDbError>> + Send;
}
#[derive(Debug, thiserror::Error)]
pub enum CodeDbError { #[error("HTTP {0}")] Status(u16), #[error(transparent)] Other(#[from] anyhow::Error) }
pub struct CodeDb { /* http, base, key; headers Authorization Bearer, Accept json, User-Agent "stash-identify" */ }

// identify/mod.rs
pub const STASHDB: &str = "https://stashdb.org/graphql";
pub const BOXES: [&str; 2] = ["https://codedb.example.org/graphql", STASHDB];
pub const PER_BOX: usize = 6;
pub const LLM_TAG: &str = "llm-identified";
pub const FC2_ARTICLE: &str = "https://fc2.example.org/article/{}/";
#[derive(Debug, thiserror::Error)] #[error("{0}")] pub struct Transient(pub String);
/// True for `Transient` and for any `reqwest::Error` anywhere in the chain (connect, timeout, HTTP status).
pub fn is_transient(e: &anyhow::Error) -> bool;
pub struct Paths { pub host: String, pub container: String }   // /mnt/storage/media/Vault ↔ /media/Vault
pub struct Proposal { pub kind: Kind, pub rule: Option<String>, pub source: Option<String>, pub parse: Option<Value>,
                      pub primary: Option<Value>, pub primary_endpoint: Option<String>, pub stash_ids: Vec<Value>,
                      pub confidence: Option<f64>, pub delta: Option<i64> }
#[derive(Debug, Clone, Copy, PartialEq)] pub enum Kind { None, Llm, Scrape }
pub struct Clients<'a, S: StashApi, L: Llm, J: CodeSearch> { pub stash: &'a S, pub llm: &'a L, pub codedb: Option<&'a J>, pub paths: &'a Paths }
pub async fn identify_scene<S, L, J>(c: &Clients<'_, S, L, J>, scene: &Value) -> anyhow::Result<Proposal>;
pub async fn code_prop<S, L, J>(c: &Clients<'_, S, L, J>, scene: &Value) -> anyhow::Result<Option<Proposal>>;
pub async fn fc2_prop<S, L, J>(c: &Clients<'_, S, L, J>, scene: &Value, number: &str) -> anyhow::Result<Option<Proposal>>;
pub async fn apply<S, L, J>(c: &Clients<'_, S, L, J>, scene: &Value, prop: &Proposal, skip_tag_ids: &HashSet<String>, overwrite: bool) -> anyhow::Result<()>;
pub fn format_line(paths: &Paths, scene: &Value, prop: &Proposal) -> String;
pub fn is_upgrade(paths: &Paths, scene: &Value, llm_tag_id: Option<&str>) -> bool;
pub fn skip_tags(defaults: &Value) -> HashSet<String>;
pub struct PassOpts { pub jobs: bool, pub dry_run: bool, pub limit: Option<usize>, pub scene_ids: Option<Vec<String>> }
pub async fn run_pass<S, L, J>(c: &Clients<'_, S, L, J>, db: &Db, defaults: &Value, paths: Option<Vec<String>>, opts: &PassOpts) -> anyhow::Result<()>;
```

Port notes:
- Error classification mirrors Python's `TRANSIENT`: Python's `urllib.error.HTTPError` is a `URLError`, so **every** reqwest error (connect, timeout, HTTP status) is transient; GraphQL errors (`GqlError`) and malformed LLM replies are not. `fc2_prop`: `GqlError` → miss (log, `None`); reqwest error → `Transient`. `code_prop`: the code database `Status(401|403)` → log "the code database refused the key ({code}); treating as a miss", empty hits.
- `delta`: `(primary.duration - file.duration).round_ties_even() as i64`.
- `format_line`: `{p.get('title')!r}` → `py::repr_str`; `conf={:.2}`; `Δ{:+}s` (`format!("Δ{:+}s", d)`), `Δ?` when None; `src` from `source` or the sorted `+`-joined second-level domain labels of `stash_ids` endpoints. Print to **stdout** (Python `print`), not the log.
- `run_pass`: identical control flow, including re-fetch before write, "edited meanwhile" (skip + mark done + clear failures), "gone" (skip + clear failures), and failure accounting via `db.identify_fail` / `identify_mark_done` / `identify_clear_failures`; dry-run writes nothing.

- [ ] **Step 1–4:** failing tests (72 minus watcher ones) → implement → PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab identify pass, stash and codedb clients"`

---

### Task 15: Identify watcher

**Files:**
- Create: `src/identify/watch.rs`
- Test: port the `Debouncer`, `changed_dir` and `next_action` tests from stash-identify `test_main.py`.

**Interfaces:**
- Produces:

```rust
pub const SETTLE: std::time::Duration = std::time::Duration::from_secs(120);
pub struct Debouncer { /* quiet, pending: BTreeSet<String>, last: Instant */ }
impl Debouncer { pub fn new(quiet: Duration) -> Self; pub fn add(&mut self, path: String, now: Instant); pub fn ready(&mut self, now: Instant) -> Option<Vec<String>>; }
pub enum Change { CloseWrite, MovedTo }
pub fn changed_dir(change: Change, path: &std::path::Path, is_dir: bool, video_exts: &HashSet<String>) -> Option<String>;
pub async fn watch<S, L, J>(c: &Clients<'_, S, L, J>, db: &Db, sweep: impl Fn() -> futures::future::BoxFuture<'static, anyhow::Result<()>>) -> anyhow::Result<()>;
```

Behaviour:
- `notify::RecommendedWatcher` recursive on `paths.host`; map `EventKind::Access(AccessKind::Close(AccessMode::Write))` → `CloseWrite`, `EventKind::Modify(ModifyKind::Name(RenameMode::To))` and `ModifyKind::Name(RenameMode::Both)` (second path) → `MovedTo`. `is_dir` via `path.is_dir()` at event time. Ignore everything else (Python only listened to `close_write,moved_to`).
- `changed_dir`: dir → the path itself; file with extension (lower-cased) in Stash's `video_extensions()` → its parent; else None.
- Loop: `tokio::select!` on the event channel and a 10 s tick; on `Debouncer::ready` run `run_pass(..., Some(dirs), jobs=true)`, logging and swallowing a pass error (`pass failed: {e}`). A watcher error or a closed channel returns `Err` (the supervisor restarts the task).
- The 24 h sweep is **not** in this loop — it is the `sweep` job in Task 16 (`run_pass(None, jobs=true)`).

- [ ] **Step 1–4:** failing tests → implement → PASS. Add one integration test with a tempdir: write `a/x.mp4` and assert `changed_dir` → `a` fires through a real `notify` watcher within 2 s.
- [ ] **Step 5: Commit** — `git commit -m "feat(galactica): plab identify watcher"`

---

### Task 16: Config, App, scheduler, supervisor, CLI wiring

**Files:**
- Create: `src/config.rs`, `src/app.rs`, `src/jobs.rs`
- Modify: `src/main.rs`
- Test: `config` and `jobs` unit tests; one end-to-end smoke test of `plab prune --dry-run` against a wiremock Transmission (`assert_cmd`-free: call `commands::prune(&cfg, true)` directly).

**Interfaces:**
- Produces:

```rust
// config.rs
pub struct Config {
    pub state_dir: PathBuf,                 // PLAB_STATE_DIR, default /var/lib/plab
    pub username_file: Option<PathBuf>,     // PLAB_USERNAME_FILE
    pub password_file: Option<PathBuf>,     // PLAB_PASSWORD_FILE
    pub transmission_url: Option<String>,   // PLAB_TRANSMISSION_URL
    pub download_dir: Option<String>,       // PLAB_DOWNLOAD_DIR
    pub games_dir: Option<String>,          // PLAB_GAMES_DIR
    pub static_dir: Option<PathBuf>,        // PLAB_STATIC_DIR
    pub exclude_file: Option<PathBuf>,      // PLAB_EXCLUDE_FILE
    pub filter_file: Option<PathBuf>,       // PLAB_FILTER_FILE
    pub openrouter_key_file: Option<PathBuf>, // PLAB_OPENROUTER_KEY_FILE
    pub jev_model: String,                  // PLAB_JEV_MODEL, default typesafe/jev-1.13
    pub parse_model: String,                // PLAB_PARSE_MODEL, default ~deepseek/deepseek-flash-latest
    pub stash_url: String,                  // PLAB_STASH_URL, default http://localhost:9999/graphql
    pub stash_api_key: Option<String>,      // PLAB_STASH_API_KEY
    pub library_host: String,               // PLAB_LIBRARY_HOST, default /mnt/storage/media/Vault
    pub library_container: String,          // PLAB_LIBRARY_CONTAINER, default /media/Vault
    pub grab_rules_file: Option<PathBuf>,   // PLAB_GRAB_RULES_FILE
    pub prowlarr_url: String,               // PLAB_PROWLARR_URL, default http://127.0.0.1:9696
    pub prowlarr_config: Option<PathBuf>,   // PLAB_PROWLARR_CONFIG
    pub legacy: LegacyPaths,                // PLAB_LEGACY_PLAB_DIR (default = state_dir), PLAB_LEGACY_STASH_IDENTIFY_DIR (/var/lib/stash-identify), PLAB_LEGACY_VAULT_GRAB_DIR (/var/lib/vault-grab)
}
impl Config {
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> Config;
    pub fn require<'a, T>(v: &'a Option<T>, var: &str) -> anyhow::Result<&'a T>; // "{var} is not set"
    pub fn secret(path: &Option<PathBuf>, var: &str) -> anyhow::Result<String>;   // read + trim
}

// jobs.rs
#[derive(Clone, Copy)] pub struct Schedule { pub period: i64, pub offset: i64 } // seconds, UTC-aligned slots
pub const REFRESH: Schedule = Schedule { period: 3 * 3600, offset: 0 };
pub const GRAB: Schedule = Schedule { period: 3 * 3600, offset: 3600 + 1800 };
pub const PRUNE: Schedule = Schedule { period: 3600, offset: 0 };
pub const SWEEP: Schedule = Schedule { period: 24 * 3600, offset: 4 * 3600 };
pub fn last_slot(s: Schedule, now: i64) -> i64;  // greatest t <= now with (t - offset) % period == 0
pub fn next_slot(s: Schedule, now: i64) -> i64;  // smallest t > now
pub fn overdue(s: Schedule, last_started: Option<i64>, now: i64) -> bool; // None or < last_slot
pub async fn run_periodic<F, Fut>(db: Db, name: &'static str, s: Schedule, job: F) -> anyhow::Result<()>
    where F: Fn() -> Fut, Fut: Future<Output = anyhow::Result<()>>;
    // loop: if overdue → job_started, run, job_finished(err string), log "{name} failed: {e}" on error;
    //       sleep until next_slot. Never returns Ok in normal operation.
pub async fn supervise<F, Fut>(name: &'static str, task: F)
    where F: Fn() -> Fut + Send + Sync + 'static, Fut: Future<Output = anyhow::Result<()>> + Send + 'static;
    // tokio::spawn(task()); on Err or panic log "task {name} stopped: {e}", sleep backoff (30 s doubling to 600 s;
    // reset to 30 s if it ran ≥ 10 min), restart. Logs include job=name via tracing span.

// app.rs
pub struct App { pub cfg: Arc<Config>, pub db: Db, pub images: ImageCache, pub tracker: Arc<Tracker>,
                 pub transmission: Arc<Transmission>, pub stash: Stash, pub openrouter: Option<OpenRouter>,
                 pub codedb: Option<CodeDb>, pub fetch_slots: Arc<Semaphore> }
impl App { pub async fn build(cfg: Config) -> anyhow::Result<App>; } // opens Db with legacy import; codedb key from stash.codedb_api_key() (log + None on failure, as Python)
```

main.rs commands:
- `serve`: `App::build`, then for each name in `--tasks` call `supervise`: `web` → `web::serve`; `identify` → `watch`; `refresh` → `run_periodic(REFRESH, run_refresh)`; `prune` → `run_periodic(PRUNE, run_prune(dirs=[download_dir, games_dir?]))`; `grab` → `run_periodic(GRAB, grab::run)` (exit status 1 → `Err("some studio searches failed")`); `identify` also spawns `run_periodic(SWEEP, run_pass(None, jobs=true))` named `sweep`. Then `tokio::signal::ctrl_c` / SIGTERM → exit 0. Unknown task name → error at startup.
- `refresh`, `prune [--dry-run]`, `grab [--dry-run]`, `identify …`, `set-cookie` call the same functions once. `prune` needs only Transmission config (no tracker credentials). `identify` with no paths: `PassOpts { jobs: false }` (Python's `run`); with paths: `jobs: !no_jobs`.
- Every one-shot command records `job_started`/`job_finished` too, so a manual refresh counts as the slot's run.

- [ ] **Step 1: failing tests**

```rust
#[test]
fn slots_align_to_utc() {
    // 2026-11-01T02:59:59Z
    let now = 1_793_501_999;
    assert_eq!(last_slot(REFRESH, now) % (3 * 3600), 0);
    assert_eq!(next_slot(REFRESH, now) - last_slot(REFRESH, now), 3 * 3600);
    assert_eq!((last_slot(GRAB, now) - 5400).rem_euclid(3 * 3600), 0);
}
#[test]
fn overdue_when_never_run_or_missed_a_slot() {
    let now = 1_793_501_999;
    assert!(overdue(PRUNE, None, now));
    assert!(overdue(PRUNE, Some(last_slot(PRUNE, now) - 1), now));
    assert!(!overdue(PRUNE, Some(last_slot(PRUNE, now)), now));
}
#[test]
fn config_defaults() {
    let c = Config::from_env(|_| None);
    assert_eq!(c.state_dir, std::path::PathBuf::from("/var/lib/plab"));
    assert_eq!(c.legacy.plab, c.state_dir);
    assert_eq!(c.stash_url, "http://localhost:9999/graphql");
    assert!(Config::require(&c.transmission_url, "PLAB_TRANSMISSION_URL").unwrap_err().to_string().contains("PLAB_TRANSMISSION_URL"));
}
#[tokio::test(start_paused = true)]
async fn supervise_restarts_a_failing_task() {
    let n = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let n2 = n.clone();
    tokio::spawn(supervise("t", move || { let n = n2.clone(); async move { n.fetch_add(1, std::sync::atomic::Ordering::SeqCst); anyhow::bail!("x") } }));
    tokio::time::sleep(std::time::Duration::from_secs(100)).await;
    assert!(n.load(std::sync::atomic::Ordering::SeqCst) >= 3);
}
```

- [ ] **Step 2–4:** FAIL → implement → PASS. Then `nix build .#plab` from the repo root.
- [ ] **Step 5: Local smoke run** (raider, no galactica access needed): `PLAB_STATE_DIR=$(mktemp -d) PLAB_TRANSMISSION_URL=http://127.0.0.1:1/x PLAB_DOWNLOAD_DIR=/tmp ./result/bin/plab prune --dry-run` → exits non-zero with a connection error mentioning the URL (proves wiring; no state touched beyond the temp dir).
- [ ] **Step 6: Commit** — `git commit -m "feat(galactica): plab daemon, scheduler and cli"`

---

### Task 17: Install `plab-rs` on galactica and run the parity check

**Files:**
- Modify: `modules/hosts/galactica/services/plab/default.nix` (add only the alias to `environment.systemPackages`)

- [ ] **Step 1: Add the alias**, in the `let`:

```nix
    # The Rust port, side by side with the Python until the cutover
    # (docs/superpowers/specs/2026-11-01-plab-rust-merge-design.md). Named plab-rs so it
    # cannot shadow `plab`.
    plabRs = pkgs.runCommand "plab-rs" {} ''
      mkdir -p $out/bin
      ln -s ${pkgs.plab}/bin/plab $out/bin/plab-rs
    '';
```

  and `environment.systemPackages = [plab plabRs];`.
- [ ] **Step 2: Build** — `just build galactica` → succeeds.
- [ ] **Step 3: Commit and deploy** — `git commit -m "feat(galactica): install the plab rust port as plab-rs"`; `git push`; `just deploy galactica`.
- [ ] **Step 4: Parity environment** on galactica (as `media`):

```bash
ssh galactica.bat-boa.ts.net
S=/tmp/plab-parity; sudo rm -rf $S; sudo mkdir -p $S/{plab,stash-identify,vault-grab,state}
sudo cp -a /var/lib/plab/. $S/plab/; sudo cp -a /var/lib/stash-identify/. $S/stash-identify/; sudo cp -a /var/lib/vault-grab/. $S/vault-grab/
sudo chown -R media:media $S
# The Python wrappers export every variable; reuse them for the Rust binary:
grep -h '^export' $(readlink -f $(which plab)) $(readlink -f $(which vault-grab)) $(readlink -f $(which stash-identify))
```

  Build one env file `$S/env` mapping those to the `PLAB_*` names of Task 16 (VAULT_GRAB_* → PLAB_GRAB_RULES_FILE / PLAB_PROWLARR_URL / PLAB_PROWLARR_CONFIG; OPENROUTER_API_KEY_FILE → PLAB_OPENROUTER_KEY_FILE), with `PLAB_STATE_DIR=$S/state`, `PLAB_LEGACY_PLAB_DIR=$S/plab`, `PLAB_LEGACY_STASH_IDENTIFY_DIR=$S/stash-identify`, `PLAB_LEGACY_VAULT_GRAB_DIR=$S/vault-grab`. Run each command as `sudo -u media env $(cat $S/env) plab-rs …`.
- [ ] **Step 5: Compare** (each must hold before moving on; record results in the Task 18 commit message):
  - Import: `sqlite3 $S/state/state.db 'select section,count(*) from listing group by 1; select state,count(*) from download group by 1; select count(*) from grab_seen; select count(*) from identify_attempt where done;'` equals `jq '.topics|length' cache.json games.json`, `jq length added.json queued.json games-queued.json`, `jq '[.studios[]|length]|add' state.json`, `jq length attempted.json`.
  - Prune: `plab-rs prune --dry-run` vs `sudo -u media plab prune --dry-run` — same `would remove` lines (sort both).
  - Grab: `plab-rs grab --dry-run` vs `sudo -u media vault-grab run --dry-run` — same `would grab` lines.
  - Identify: pick 20 scene ids (`sqlite3`-free: from `jq '.[-20:]' attempted.json`, plus 5 coded files); `plab-rs identify --dry-run --no-jobs --scene …` vs `stash-identify run --dry-run --scene …`. Product-code/FC2/date-rule lines must match exactly; Jev/LLM lines may differ in wording only.
  - Page: `plab-rs serve --tasks web --port 8599 &`; `curl -s localhost:8599/ > rs.html`; `curl -s localhost:8577/ > py.html`; `diff <(sed 's/updated [0-9]* \(min\|h\) ago//' py.html) <(sed 's/updated [0-9]* \(min\|h\) ago//' rs.html)` → empty (fresh-badge minute counts may differ by one if a minute ticks over; re-run once). Same for `/games` and `/search?q=<a term>`.
  - One real add: on `localhost:8599`, `curl -X POST localhost:8599/add/<a throwaway topic id from rs.html>` → `{"ok": true, "name": …}`; the torrent appears in Transmission under Downloads/Vault; remove it by hand.
  - Stop the test server; `sudo rm -rf /tmp/plab-parity`.

---

### Task 18: Cutover

**Files:**
- Rewrite: `modules/hosts/galactica/services/plab/default.nix`
- Delete: `modules/hosts/galactica/services/plab/*.py`, `plab/fixtures/`, `plab/__pycache__` (untracked), `modules/hosts/galactica/services/stash-identify/`, `modules/hosts/galactica/services/vault-grab/`
- Modify: `CLAUDE.md` (host-local module list: drop `stash-identify/`; add `plab` is now a Rust daemon in `packages/plab`)

- [ ] **Step 1: Rewrite `default.nix`**

```nix
# plab: one Rust daemon (packages/plab) for three jobs that used to be separate Python
# tools: the tracker page (Videos and Games, "Add to Vault"/"Add to Games"), Stash
# identification of every new Vault file (was stash-identify), and studio grabs through
# Prowlarr (was vault-grab), plus pruning finished torrents. Its tasks share one tracker
# session and one SQLite database, /var/lib/plab/state.db.
#
# Design: docs/superpowers/specs/2026-11-01-plab-rust-merge-design.md
# Earlier designs: 2026-10-09-plab-design.md, 2026-09-27-stash-llm-identify-design.md,
# 2026-10-24-vault-grab-design.md (behaviour unchanged by the port).
#
# Every job also runs once from the CLI, beside the daemon:
#   sudo -u media plab prune --dry-run      what prune would remove
#   sudo -u media plab grab --dry-run       what grab would add
#   sudo -u media plab identify --dry-run --scene <id>
#   sudo -u media plab refresh
# If a login ever hits a captcha: log in once in a browser and run
# `sudo -u media plab set-cookie <bb_data cookie value>`. No restart needed.
#
# Rollback: revert this commit. The legacy JSON state under /var/lib/{plab,stash-identify,
# vault-grab} is never modified by the daemon, so the Python resumes where it stopped.
{
  configurations.nixos.galactica.module = {
    config,
    pkgs,
    ...
  }: let
    vars = config.media.config;
    secrets = config.sops.secrets;
    port = 8577;

    # (keep the existing `static` linkFarm block verbatim)
    static = …;

    # Run as `plab …` with the daemon's environment, so a one-shot sees what the daemon sees.
    plab = pkgs.writeShellApplication {
      name = "plab";
      text = ''
        export PLAB_USERNAME_FILE="''${PLAB_USERNAME_FILE:-${secrets.plab-username.path}}"
        export PLAB_PASSWORD_FILE="''${PLAB_PASSWORD_FILE:-${secrets.plab-password.path}}"
        export PLAB_STATE_DIR="''${PLAB_STATE_DIR:-/var/lib/plab}"
        # Straight into the PIA namespace, never through the Authelia-gated
        # transmission vhost (see transmission-vpn.nix).
        export PLAB_TRANSMISSION_URL="http://${config.constellation.pia.namespaceAddress}:9091/transmission/rpc"
        # The path Prowlarr's `Vault` category produces too; a symlink to ../Vault.
        export PLAB_DOWNLOAD_DIR="${vars.storageDir}/media/Downloads/Vault"
        export PLAB_GAMES_DIR="${vars.storageDir}/media/Downloads/Games"
        export PLAB_STATIC_DIR="''${PLAB_STATIC_DIR:-${static}}"
        export PLAB_EXCLUDE_FILE="''${PLAB_EXCLUDE_FILE:-${secrets.plab-exclude.path}}"
        export PLAB_FILTER_FILE="''${PLAB_FILTER_FILE:-${secrets.plab-filter.path}}"
        export PLAB_OPENROUTER_KEY_FILE="''${PLAB_OPENROUTER_KEY_FILE:-${secrets.openrouter-api-key.path}}"
        export PLAB_GRAB_RULES_FILE="''${PLAB_GRAB_RULES_FILE:-${secrets.vault-grab-rules.path}}"
        export PLAB_PROWLARR_URL="http://127.0.0.1:9696"
        # Read at run time: Prowlarr owns the key, so there is no second copy to drift.
        export PLAB_PROWLARR_CONFIG="${vars.configDir}/prowlarr/config.xml"
        exec ${pkgs.plab}/bin/plab "$@"
      '';
    };
  in {
    sops.secrets.plab-username.owner = vars.user;
    sops.secrets.plab-password.owner = vars.user;
    sops.secrets.plab-exclude.owner = vars.user;
    sops.secrets.plab-filter.owner = vars.user;
    sops.secrets.openrouter-api-key.owner = vars.user;
    sops.secrets.vault-grab-rules.owner = vars.user;

    environment.systemPackages = [plab];

    # host: the default (the hostname) resolves to 127.0.0.2 here, and plab listens
    # on 127.0.0.1 only. Authelia-gated: no bypassAuth.
    media.services.plab = {
      inherit port;
      host = "127.0.0.1";
    };

    systemd.services.plab = let
      stash = "${config.virtualisation.oci-containers.backend}-stash.service";
    in {
      description = "plab: page, Stash identification, refresh, prune and grab";
      wantedBy = ["multi-user.target"];
      # Wants transmission so a start brings it up if it is down (it was, for hours,
      # after the 2026-10-31 activation panic); prune would otherwise fail every hour.
      after = ["network-online.target" "transmission.service" stash "mnt-storage.mount"];
      wants = ["network-online.target" "transmission.service" stash];
      requires = ["mnt-storage.mount"];
      serviceConfig = {
        ExecStart = "${plab}/bin/plab serve --bind 127.0.0.1 --port ${toString port}";
        User = vars.user;
        Group = vars.group;
        StateDirectory = "plab";
        UMask = "0077"; # state.db holds the tracker session
        Restart = "always";
        RestartSec = "10s";
      };
    };
  };
}
```

  Replace `static = …;` with the exact `static` linkFarm block from the current file (unchanged).
- [ ] **Step 2: Delete the Python** — `git rm -r modules/hosts/galactica/services/stash-identify modules/hosts/galactica/services/vault-grab modules/hosts/galactica/services/plab/fixtures && git rm modules/hosts/galactica/services/plab/*.py`
- [ ] **Step 3: Check nothing else referenced them** — `grep -rn "stash-identify\|vault-grab\|plab-refresh\|plab-prune" modules/ just/ justfile .github/` → only comments/docs; fix any live reference.
- [ ] **Step 4: Update `CLAUDE.md`** host-local list: replace `stash-identify/` with `plab` (and note "Rust daemon in `packages/plab`").
- [ ] **Step 5: Format and build** — `just fmt && just build galactica` → succeeds.
- [ ] **Step 6: Commit** — message includes the Task 17 parity results:

```bash
git add -A modules/hosts/galactica/services CLAUDE.md
git commit -m "feat(galactica): cut plab, stash-identify and vault-grab over to the rust daemon

Parity on a copy of live state: <import counts>, prune/grab dry-runs identical,
<n>/20 identify proposals identical (the rest differ only in LLM wording), page diff empty."
git push
```

- [ ] **Step 7: Deploy** — `just deploy galactica`.
- [ ] **Step 8: Verify on galactica**:
  - `systemctl status plab` active; `systemctl list-timers | grep -E 'plab|vault-grab'` → none left.
  - `journalctl -u plab -b` shows `imported legacy state: …` once, and task start lines for web, identify, sweep, refresh, prune, grab.
  - `sqlite3 /var/lib/plab/state.db 'select job, last_started, ok, error from job_run'` — within 3 h every job has `ok=1` (prune within 1 h).
  - `https://plab.arsfeld.one/` renders both tabs; an add works.
  - Drop a test video into a Vault folder (or wait for a real download) and see `identify` log a pass and the scene get identified in Stash.
- [ ] **Step 9: Calendar reminder** — after two clean weeks, delete `/var/lib/stash-identify`, `/var/lib/vault-grab` and the legacy JSON in `/var/lib/plab` by hand (keep `img/`). Use `mcp__claude-code-remote__send_later` (or tell the user) for 2026-11-15.
