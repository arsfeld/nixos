//! Port of plab's test_main.py for the domain functions (the HTTP-handler tests are Task
//! 11's), plus test_store.py's `test_ensure_image_fetches_once`.
//!
//! Python's tests count `sleep(DELAY)` calls; here `Ctx.delay` is zero and the fakes'
//! records of tracker calls stand in for them (one sleep precedes every topic fetch and
//! every curated search).

use super::*;
use crate::albums::AlbumIndex;
use crate::curated::{Elsewhere, run_curated};
use crate::db::{Kind, Production};
use crate::scenes::SceneDb;
use crate::sources::Sources;
use crate::tracker::parse::Row;
use crate::transmission::{Added, Torrent};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Mutex;
use wiremock::matchers::{method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

const JPEG: &[u8] = b"\xff\xd8\xff\xe0jpeg";
const COVER: &str = "https://i128.fastpic.org/big/2026/1004/19/cover.jpg";
const NOW: i64 = 1_800_000_000;

fn fixture(name: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name);
    std::fs::read_to_string(path).unwrap()
}

fn row(id: u64) -> Row {
    titled(id, &format!("t{id}"))
}

fn titled(id: u64, title: &str) -> Row {
    Row {
        id,
        title: title.into(),
        forum: 1875,
        size: 1,
        seeders: 9,
        leechers: 0,
        completed: 0,
        added: 0,
    }
}

fn listed(row: Row, images: &[&str]) -> Listed {
    Listed {
        topic: Topic {
            row,
            images: Some(images.iter().map(|s| s.to_string()).collect()),
            production: None,
        },
        filters: vec![],
        curated_reason: None,
    }
}

/// A tracker failure, built fresh for each call (reqwest::Error is not Clone).
#[derive(Clone, Copy, Debug)]
enum Fail {
    Login,
    Limit,
    Tracker,
    Http,
}

fn http_error() -> reqwest::Error {
    reqwest::Client::new().get("not a url").build().unwrap_err()
}

impl Fail {
    fn err(self) -> TrackerError {
        match self {
            Fail::Login => TrackerError::Login("login needs captcha".into()),
            Fail::Limit => TrackerError::Limit(10),
            Fail::Tracker => TrackerError::Tracker("gone".into()),
            Fail::Http => TrackerError::Http(http_error()),
        }
    }
}

type SearchCall = (String, Option<u32>, usize, Option<usize>);

#[derive(Default)]
struct Calls {
    tops: Vec<Vec<u32>>,
    searches: Vec<SearchCall>,
    topics: Vec<u64>,
    fetched: Vec<String>,
    torrents: Vec<u64>,
}

/// FakeLab: scripted rows and failures; records every call.
struct FakeTracker {
    rows: Vec<Row>,
    searched: HashMap<String, Vec<Row>>,
    search_error: Option<Fail>,
    broken: HashSet<u64>,
    logged_out: HashSet<u64>,
    errors: HashMap<u64, Fail>,
    fetch_body: Vec<u8>,
    /// `top` over the games forums fails.
    games_down: bool,
    calls: Mutex<Calls>,
}

impl FakeTracker {
    fn new(rows: Vec<Row>) -> FakeTracker {
        FakeTracker {
            rows,
            searched: HashMap::new(),
            search_error: None,
            broken: HashSet::new(),
            logged_out: HashSet::new(),
            errors: HashMap::new(),
            fetch_body: JPEG.to_vec(),
            games_down: false,
            calls: Mutex::new(Calls::default()),
        }
    }

    fn with_errors(rows: Vec<Row>, errors: &[(u64, Fail)]) -> FakeTracker {
        FakeTracker {
            errors: errors.iter().copied().collect(),
            ..FakeTracker::new(rows)
        }
    }

    fn calls(&self) -> std::sync::MutexGuard<'_, Calls> {
        self.calls.lock().unwrap()
    }
}

fn keep(rows: &[Row], excludes: &[fancy_regex::Regex]) -> Vec<Row> {
    rows.iter()
        .filter(|r| !crate::filters::excluded(excludes, &r.title))
        .cloned()
        .collect()
}

impl TrackerApi for FakeTracker {
    async fn top(
        &self,
        forums: &[u32],
        _days: u32,
        _limit: usize,
        excludes: &[fancy_regex::Regex],
    ) -> Result<Vec<Row>, TrackerError> {
        self.calls().tops.push(forums.to_vec());
        if self.games_down && forums == crate::tracker::forums::games() {
            return Err(Fail::Http.err());
        }
        Ok(keep(&self.rows, excludes))
    }

    async fn search(
        &self,
        query: &str,
        _forums: &[u32],
        days: Option<u32>,
        limit: usize,
        excludes: &[fancy_regex::Regex],
        pages: Option<usize>,
    ) -> Result<Vec<Row>, TrackerError> {
        self.calls()
            .searches
            .push((query.to_string(), days, limit, pages));
        if let Some(f) = self.search_error {
            return Err(f.err());
        }
        Ok(keep(
            self.searched.get(query).map_or(&[][..], |v| &v[..]),
            excludes,
        ))
    }

    async fn topic(&self, topic_id: u64) -> Result<String, TrackerError> {
        self.calls().topics.push(topic_id);
        if self.logged_out.contains(&topic_id) {
            return Err(Fail::Login.err());
        }
        if self.broken.contains(&topic_id) {
            return Err(Fail::Http.err());
        }
        Ok(fixture("topic.html"))
    }

    async fn torrent(&self, topic_id: u64) -> Result<Vec<u8>, TrackerError> {
        self.calls().torrents.push(topic_id);
        if let Some(f) = self.errors.get(&topic_id) {
            return Err(f.err());
        }
        Ok(b"d4:infoe".to_vec())
    }

    async fn fetch(&self, url: &str) -> Result<Vec<u8>, TrackerError> {
        self.calls().fetched.push(url.to_string());
        Ok(self.fetch_body.clone())
    }
}

/// Transmission: records (torrent bytes, download dir); the first `fail` adds error.
struct FakeTorrents {
    name: String,
    fail: Mutex<usize>,
    calls: Mutex<Vec<(Vec<u8>, String)>>,
}

impl FakeTorrents {
    fn new() -> FakeTorrents {
        FakeTorrents {
            name: "Release".into(),
            fail: Mutex::new(0),
            calls: Mutex::new(vec![]),
        }
    }

    fn dirs(&self) -> Vec<String> {
        self.calls
            .lock()
            .unwrap()
            .iter()
            .map(|(_, d)| d.clone())
            .collect()
    }
}

impl TorrentClient for FakeTorrents {
    async fn add(&self, src: &TorrentSource, download_dir: &str) -> anyhow::Result<Added> {
        let bytes = match src {
            TorrentSource::Bytes(b) => b.clone(),
            TorrentSource::Magnet(m) => m.as_bytes().to_vec(),
        };
        {
            let mut fail = self.fail.lock().unwrap();
            if *fail > 0 {
                *fail -= 1;
                anyhow::bail!("transmission down");
            }
        }
        self.calls
            .lock()
            .unwrap()
            .push((bytes, download_dir.to_string()));
        Ok(Added {
            name: self.name.clone(),
            hash: Some("abc".into()),
        })
    }

    async fn torrents(&self) -> anyhow::Result<Vec<Torrent>> {
        Ok(vec![])
    }

    async fn remove(&self, _ids: &[i64]) -> anyhow::Result<()> {
        Ok(())
    }
}

/// The classifier: answers `answer` for every title, or fails when it is None.
struct FakeClassify {
    answer: Option<Production>,
    calls: Mutex<Vec<(String, String)>>,
}

impl FakeClassify {
    fn answering(class: &str, confidence: Option<f64>) -> FakeClassify {
        FakeClassify {
            answer: Some(Production {
                class: class.into(),
                confidence,
            }),
            calls: Mutex::new(vec![]),
        }
    }

    fn failing() -> FakeClassify {
        FakeClassify {
            answer: None,
            calls: Mutex::new(vec![]),
        }
    }

    fn titles(&self) -> Vec<String> {
        self.calls
            .lock()
            .unwrap()
            .iter()
            .map(|(t, _)| t.clone())
            .collect()
    }
}

impl Classify for FakeClassify {
    async fn classify(&self, title: &str, category: &str) -> anyhow::Result<Production> {
        self.calls
            .lock()
            .unwrap()
            .push((title.to_string(), category.to_string()));
        self.answer
            .clone()
            .ok_or_else(|| anyhow::anyhow!("openrouter hung"))
    }
}

/// The state directory, its database and image cache, and the Transmission fake.
struct Env {
    dir: tempfile::TempDir,
    db: Db,
    images: ImageCache,
    torrents: FakeTorrents,
    slots: tokio::sync::Semaphore,
    exclude_file: Option<PathBuf>,
    filter_file: Option<PathBuf>,
    games_dir: Option<String>,
    prowlarr: Option<Prowlarr>,
}

impl Env {
    fn new() -> Env {
        let dir = tempfile::tempdir().unwrap();
        let db = Db::open(&dir.path().join("plab.db")).unwrap();
        let images = ImageCache::new(dir.path().join("img")).unwrap();
        Env {
            dir,
            db,
            images,
            torrents: FakeTorrents::new(),
            slots: tokio::sync::Semaphore::new(2),
            exclude_file: None,
            filter_file: None,
            games_dir: None,
            prowlarr: None,
        }
    }

    /// With `topics` as the video list.
    fn listing(topics: Vec<Listed>) -> Env {
        let env = Env::new();
        env.db
            .save_listing(Section::Video, &topics, &[], NOW)
            .unwrap();
        env
    }

    fn write(&self, name: &str, text: &str) -> PathBuf {
        let path = self.dir.path().join(name);
        std::fs::write(&path, text).unwrap();
        path
    }

    fn ctx<'a>(&'a self, tracker: &'a FakeTracker) -> Ctx<'a, FakeTracker, FakeTorrents> {
        Ctx {
            tracker,
            torrents: &self.torrents,
            db: &self.db,
            images: &self.images,
            state_dir: self.dir.path(),
            exclude_file: self.exclude_file.as_deref(),
            filter_file: self.filter_file.as_deref(),
            download_dir: "/vault",
            games_dir: self.games_dir.as_deref(),
            delay: Duration::ZERO,
            fetch_slots: &self.slots,
            prowlarr: self.prowlarr.as_ref(),
        }
    }

    async fn refresh(&self, lab: &FakeTracker) -> anyhow::Result<()> {
        refresh::<_, _, FakeClassify>(&self.ctx(lab), Section::Video, None, NOW).await
    }

    async fn refresh_classified(&self, lab: &FakeTracker, k: &FakeClassify) -> anyhow::Result<()> {
        refresh(&self.ctx(lab), Section::Video, Some(k), NOW).await
    }

    async fn refresh_games(&self, lab: &FakeTracker) -> anyhow::Result<()> {
        refresh::<_, _, FakeClassify>(&self.ctx(lab), Section::Games, None, NOW).await
    }

    async fn run_refresh(&self, lab: &FakeTracker) -> anyhow::Result<()> {
        run_refresh::<_, _, FakeClassify>(&self.ctx(lab), None, NOW).await
    }

    async fn drain(&self, lab: &FakeTracker) -> Result<bool, TrackerError> {
        drain_queue(&self.ctx(lab), Section::Video, "/vault", NOW).await
    }

    fn topics(&self, section: Section) -> Vec<Listed> {
        self.db.listing(section).unwrap().topics
    }

    fn ids(&self, section: Section) -> Vec<u64> {
        self.topics(section)
            .iter()
            .map(|l| l.topic.row.id)
            .collect()
    }

    fn by_id(&self) -> HashMap<u64, Listed> {
        self.topics(Section::Video)
            .into_iter()
            .map(|l| (l.topic.row.id, l))
            .collect()
    }

    fn queued(&self, section: Section) -> Vec<u64> {
        self.db.queued(section).unwrap()
    }

    fn added(&self) -> HashSet<u64> {
        self.db.added().unwrap()
    }

    fn enqueue(&self, ids: &[u64], section: Section) {
        for &id in ids {
            self.db.enqueue(id, section, NOW).unwrap();
        }
    }
}

fn is_login(e: &anyhow::Error) -> bool {
    matches!(
        e.downcast_ref::<TrackerError>(),
        Some(TrackerError::Login(_))
    )
}

fn not_listed(e: &anyhow::Error) -> Option<u64> {
    e.downcast_ref::<NotListed>().map(|n| n.0)
}

fn s(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| s.to_string()).collect()
}

// test_store.py

#[tokio::test]
async fn ensure_image_fetches_once() {
    let env = Env::new();
    let lab = FakeTracker::new(vec![]);
    let path = ensure_image(&lab, &env.images, "https://x/a.jpg")
        .await
        .unwrap();
    ensure_image(&lab, &env.images, "https://x/a.jpg")
        .await
        .unwrap();
    assert_eq!(lab.calls().fetched, s(&["https://x/a.jpg"]));
    assert_eq!(
        path.file_name().unwrap().to_str().unwrap(),
        crate::images::key("https://x/a.jpg")
    );
    assert_eq!(std::fs::read(&path).unwrap(), JPEG);
}

// Refresh

#[tokio::test]
async fn fetches_topics_and_first_image() {
    let env = Env::new();
    let lab = FakeTracker::new(vec![row(1), row(2)]);
    env.refresh(&lab).await.unwrap();
    let topics = env.topics(Section::Video);
    assert_eq!(env.ids(Section::Video), [1, 2]);
    assert_eq!(topics[0].topic.images.as_ref().unwrap()[0], COVER);
    assert_eq!(lab.calls().fetched, s(&[COVER])); // same cover for both; fetched once
    // Python: sleeps == [DELAY] * 2. No filter file: no searches, two topic fetches.
    assert_eq!(lab.calls().topics, [1, 2]);
    assert!(lab.calls().searches.is_empty());
    assert_eq!(lab.calls().tops, [crate::tracker::forums::forums()]);
}

#[tokio::test]
async fn reuses_cached_images() {
    let env = Env::new();
    env.refresh(&FakeTracker::new(vec![row(1)])).await.unwrap();
    let lab = FakeTracker::new(vec![row(1)]);
    env.refresh(&lab).await.unwrap();
    assert!(lab.calls().topics.is_empty());
}

#[tokio::test]
async fn broken_topic_is_kept_without_images_and_retried() {
    let env = Env::new();
    let lab = FakeTracker {
        broken: [1].into(),
        ..FakeTracker::new(vec![row(1)])
    };
    env.refresh(&lab).await.unwrap();
    assert_eq!(env.topics(Section::Video)[0].topic.images, Some(vec![]));
    let lab = FakeTracker::new(vec![row(1)]);
    env.refresh(&lab).await.unwrap();
    assert_eq!(lab.calls().topics, [1]);
}

#[tokio::test]
async fn no_rows_keeps_old_cache() {
    let env = Env::new();
    env.refresh(&FakeTracker::new(vec![row(1)])).await.unwrap();
    let err = env.refresh(&FakeTracker::new(vec![])).await.unwrap_err();
    assert_eq!(err.to_string(), "tracker returned no rows");
    assert_eq!(env.ids(Section::Video), [1]);
}

#[tokio::test]
async fn login_error_aborts_refresh_and_keeps_cache() {
    let env = Env::new();
    env.refresh(&FakeTracker::new(vec![row(1)])).await.unwrap();
    let lab = FakeTracker {
        logged_out: [2].into(),
        ..FakeTracker::new(vec![row(2), row(3), row(4)])
    };
    let err = env.refresh(&lab).await.unwrap_err();
    assert!(is_login(&err), "{err}");
    assert_eq!(lab.calls().topics, [2]);
    assert_eq!(env.ids(Section::Video), [1]);
}

#[tokio::test]
async fn prunes_images_of_dropped_topics() {
    let env = Env::new();
    env.images.put("https://old/gone.jpg", JPEG).unwrap();
    env.refresh(&FakeTracker::new(vec![row(1)])).await.unwrap();
    assert!(!env.images.path("https://old/gone.jpg").exists());
    assert!(env.images.path(COVER).exists());
}

#[tokio::test]
async fn refresh_assigns_top_list_rows_to_filters_by_title() {
    let mut env = Env::new();
    env.filter_file = Some(env.write(
        "filters.txt",
        "[Group A]\nAlpha Studio\n[Group B]\n\"beta word\"\n",
    ));
    let lab = FakeTracker::new(vec![
        titled(1, "[AlphaStudio.com] Movie [1080p]"),
        titled(2, "Regular Movie [1080p]"),
        titled(3, "Alpha Studio - Beta Word Scene"),
    ]);
    env.refresh(&lab).await.unwrap();
    assert_eq!(
        env.db.listing(Section::Video).unwrap().filters,
        s(&["Group A", "Group B"])
    );
    let by_id = env.by_id();
    assert_eq!(by_id[&1].filters, s(&["Group A"]));
    assert_eq!(by_id[&1].curated_reason.as_deref(), Some("Alpha Studio"));
    assert!(by_id[&2].filters.is_empty());
    assert_eq!(by_id[&2].curated_reason, None);
    assert_eq!(by_id[&3].filters, s(&["Group A", "Group B"]));
}

#[tokio::test]
async fn curated_merges_search_results_into_their_filter() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("filters.txt", "[Group A]\nAlpha\n[Group B]\nBeta\n"));
    let lab = FakeTracker {
        searched: [
            ("Alpha".to_string(), vec![titled(2, "Unrelated Title")]),
            (
                "Beta".to_string(),
                vec![
                    titled(1, "Mainstream Top 100"),
                    titled(2, "Unrelated Title"),
                ],
            ),
        ]
        .into(),
        ..FakeTracker::new(vec![titled(1, "Mainstream Top 100")])
    };
    env.curated(&lab).await.unwrap();
    assert_eq!(env.ids(Section::Video), [1, 2]);
    let by_id = env.by_id();
    assert_eq!(by_id[&1].filters, s(&["Group B"]));
    assert_eq!(by_id[&1].curated_reason.as_deref(), Some("Beta"));
    assert_eq!(by_id[&2].filters, s(&["Group A", "Group B"]));
    assert_eq!(by_id[&2].curated_reason.as_deref(), Some("Alpha"));
    // Each term searched over 32 days, 20 rows.
    assert_eq!(
        lab.calls().searches,
        [
            ("Alpha".to_string(), Some(32), 20, None),
            ("Beta".to_string(), Some(32), 20, None)
        ]
    );
}

#[tokio::test]
async fn search_failure_continues_curated() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("filters.txt", "Alpha\n"));
    let lab = FakeTracker {
        search_error: Some(Fail::Http),
        ..FakeTracker::new(vec![titled(1, "Top 1")])
    };
    env.curated(&lab).await.unwrap();
    assert_eq!(env.ids(Section::Video), [1]);
}

#[tokio::test]
async fn search_login_error_aborts_curated() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("filters.txt", "Alpha\n"));
    let lab = FakeTracker {
        search_error: Some(Fail::Login),
        ..FakeTracker::new(vec![titled(1, "Top 1")])
    };
    let err = env.curated(&lab).await.unwrap_err();
    assert!(is_login(&err), "{err}");
}

#[tokio::test]
async fn classifies_new_topics() {
    let env = Env::new();
    let k = FakeClassify::answering("amateur", Some(0.8));
    env.refresh_classified(&FakeTracker::new(vec![titled(1, "[SiteA.com] A")]), &k)
        .await
        .unwrap();
    assert_eq!(
        *k.calls.lock().unwrap(),
        [("[SiteA.com] A".to_string(), "Clips".to_string())]
    );
    assert_eq!(
        env.topics(Section::Video)[0].topic.production,
        Some(Production {
            class: "amateur".into(),
            confidence: Some(0.8)
        })
    );
}

#[tokio::test]
async fn reuses_stored_production() {
    let env = Env::new();
    env.refresh_classified(
        &FakeTracker::new(vec![row(1)]),
        &FakeClassify::answering("industrial", None),
    )
    .await
    .unwrap();
    let k = FakeClassify::answering("amateur", None);
    env.refresh_classified(&FakeTracker::new(vec![row(1), row(2)]), &k)
        .await
        .unwrap();
    assert_eq!(k.titles(), s(&["t2"]));
    let topics = env.by_id();
    assert_eq!(
        topics[&1].topic.production.as_ref().unwrap().class,
        "industrial"
    );
    assert_eq!(
        topics[&2].topic.production.as_ref().unwrap().class,
        "amateur"
    );
}

#[tokio::test]
async fn repeated_classifier_failures_stop_the_refresh_classifying() {
    let env = Env::new();
    let k = FakeClassify::failing();
    env.refresh_classified(&FakeTracker::new((1..=5).map(row).collect()), &k)
        .await
        .unwrap();
    assert_eq!(k.titles().len(), CLASSIFY_FAILURE_LIMIT as usize);
    assert_eq!(env.ids(Section::Video), [1, 2, 3, 4, 5]);
    assert!(
        env.topics(Section::Video)
            .iter()
            .all(|l| l.topic.production.is_none())
    );
}

#[tokio::test]
async fn classifier_failure_leaves_topic_unclassified() {
    let env = Env::new();
    env.refresh_classified(&FakeTracker::new(vec![row(1)]), &FakeClassify::failing())
        .await
        .unwrap();
    assert_eq!(env.ids(Section::Video), [1]);
    assert_eq!(env.topics(Section::Video)[0].topic.production, None);
}

#[tokio::test]
async fn without_classifier_no_production() {
    let env = Env::new();
    env.refresh(&FakeTracker::new(vec![row(1)])).await.unwrap();
    assert_eq!(env.topics(Section::Video)[0].topic.production, None);
}

// Drain

#[tokio::test]
async fn drains_oldest_first_without_cache() {
    let env = Env::new();
    env.enqueue(&[3, 1, 2], Section::Video);
    let lab = FakeTracker::new(vec![]);
    assert!(env.drain(&lab).await.unwrap());
    assert_eq!(lab.calls().torrents, [3, 1, 2]);
    assert!(env.queued(Section::Video).is_empty());
    assert_eq!(env.added(), [1, 2, 3].into());
    assert_eq!(
        env.torrents.calls.lock().unwrap()[0],
        (b"d4:infoe".to_vec(), "/vault".to_string())
    );
}

#[tokio::test]
async fn stops_at_limit_and_keeps_the_rest() {
    let env = Env::new();
    env.enqueue(&[1, 2, 3], Section::Video);
    let lab = FakeTracker::with_errors(vec![], &[(2, Fail::Limit)]);
    assert!(!env.drain(&lab).await.unwrap());
    assert_eq!(lab.calls().torrents, [1, 2]);
    assert_eq!(env.queued(Section::Video), [2, 3]);
    assert_eq!(env.added(), [1].into());
}

#[tokio::test]
async fn tracker_error_dequeues_and_continues() {
    let env = Env::new();
    env.enqueue(&[1, 2], Section::Video);
    let lab = FakeTracker::with_errors(vec![], &[(1, Fail::Tracker)]);
    assert!(env.drain(&lab).await.unwrap());
    assert!(env.queued(Section::Video).is_empty());
    assert_eq!(env.added(), [2].into());
}

#[tokio::test]
async fn other_errors_keep_queued_and_continue() {
    let env = Env::new();
    env.enqueue(&[1, 2], Section::Video);
    *env.torrents.fail.lock().unwrap() = 1;
    let lab = FakeTracker::new(vec![]);
    assert!(env.drain(&lab).await.unwrap());
    assert_eq!(lab.calls().torrents, [1, 2]);
    assert_eq!(env.queued(Section::Video), [1]);
    assert_eq!(env.added(), [2].into());
}

#[tokio::test]
async fn network_error_fetching_keeps_queued() {
    let env = Env::new();
    env.enqueue(&[1], Section::Video);
    env.drain(&FakeTracker::with_errors(vec![], &[(1, Fail::Http)]))
        .await
        .unwrap();
    assert_eq!(env.queued(Section::Video), [1]);
}

#[tokio::test]
async fn login_error_propagates() {
    let env = Env::new();
    env.enqueue(&[1, 2], Section::Video);
    let lab = FakeTracker::with_errors(vec![], &[(1, Fail::Login)]);
    let err = env.drain(&lab).await.unwrap_err();
    assert!(matches!(err, TrackerError::Login(_)), "{err}");
    assert_eq!(lab.calls().torrents, [1]);
    assert_eq!(env.queued(Section::Video), [1, 2]);
}

#[tokio::test]
async fn drain_records_the_download() {
    let env = Env::listing(vec![listed(titled(1, "A Release"), &[])]);
    env.enqueue(&[1], Section::Video);
    env.drain(&FakeTracker::new(vec![])).await.unwrap();
    let conn = rusqlite::Connection::open(env.dir.path().join("plab.db")).unwrap();
    let got: (String, String, String, Option<String>, Option<String>) = conn
        .query_row(
            "SELECT state, release_title, section, download_dir, torrent_hash FROM download WHERE topic_id = 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .unwrap();
    assert_eq!(
        got,
        (
            "added".into(),
            "A Release".into(),
            "video".into(),
            Some("/vault".into()),
            Some("abc".into())
        )
    );
}

// RunRefresh

#[tokio::test]
async fn drain_failure_does_not_stop_refresh() {
    let env = Env::new();
    // A queue row the database cannot read back: `queued` fails, so the drain does.
    rusqlite::Connection::open(env.dir.path().join("plab.db"))
        .unwrap()
        .execute(
            "INSERT INTO download (source, topic_id, release_title, section, state, queued_at)
             VALUES ('plab', 'abc', '', 'video', 'queued', 0)",
            [],
        )
        .unwrap();
    assert!(env.db.queued(Section::Video).is_err());
    let lab = FakeTracker::new(vec![row(5)]);
    env.run_refresh(&lab).await.unwrap();
    assert!(lab.calls().torrents.is_empty());
    assert_eq!(lab.calls().tops.len(), 1); // the refresh ran
    assert_eq!(env.ids(Section::Video), [5]);
}

#[tokio::test]
async fn login_error_aborts_before_refresh() {
    let env = Env::new();
    env.enqueue(&[1], Section::Video);
    let lab = FakeTracker::with_errors(vec![row(5)], &[(1, Fail::Login)]);
    let err = env.run_refresh(&lab).await.unwrap_err();
    assert!(is_login(&err), "{err}");
    assert_eq!(lab.calls().torrents, [1]);
    assert!(lab.calls().tops.is_empty()); // refresh never ran
}

#[tokio::test]
async fn run_refresh_passes_filter_file() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("filter-elsewhere.txt", "Alpha\n"));
    let lab = FakeTracker::new(vec![titled(1, "Alpha One")]);
    env.run_refresh(&lab).await.unwrap();
    // Matched by title; refresh searches nothing, the curated job does.
    assert_eq!(env.by_id()[&1].filters, s(&["Curated"]));
    assert!(lab.calls().searches.is_empty());
}

#[tokio::test]
async fn run_refresh_passes_classifier() {
    let env = Env::new();
    let k = FakeClassify::answering("amateur", None);
    let lab = FakeTracker::new(vec![row(1)]);
    run_refresh(&env.ctx(&lab), Some(&k), NOW).await.unwrap();
    assert_eq!(k.titles(), s(&["t1"]));
}

// Routes

fn routes() -> Env {
    Env::listing(vec![listed(row(1), &[COVER, "https://x/b.jpg"])])
}

#[tokio::test]
async fn add_known_topic() {
    let env = routes();
    let lab = FakeTracker::new(vec![]);
    let result = add_topic(&env.ctx(&lab), 1, NOW).await.unwrap();
    assert_eq!(
        result,
        AddResult::Added {
            name: "Release".into()
        }
    );
    assert_eq!(
        *env.torrents.calls.lock().unwrap(),
        [(b"d4:infoe".to_vec(), "/vault".to_string())]
    );
    assert_eq!(env.added(), [1].into());
}

#[tokio::test]
async fn add_over_the_limit_is_queued() {
    let env = routes();
    let lab = FakeTracker::with_errors(vec![], &[(1, Fail::Limit)]);
    let result = add_topic(&env.ctx(&lab), 1, NOW).await.unwrap();
    assert_eq!(
        result,
        AddResult::Queued {
            message: "daily download limit reached (10/day)".into()
        }
    );
    assert_eq!(env.queued(Section::Video), [1]);
    assert!(env.added().is_empty());
}

#[tokio::test]
async fn add_already_added_topic_skips_fetch() {
    let env = routes();
    env.db
        .mark_added(NewDownload {
            source: "plab",
            topic_id: Some(1),
            release_title: "t1",
            section: Section::Video,
            download_dir: None,
            torrent_hash: None,
            now: NOW,
        })
        .unwrap();
    let lab = FakeTracker::new(vec![]);
    let result = add_topic(&env.ctx(&lab), 1, NOW).await.unwrap();
    assert_eq!(result, AddResult::AlreadyAdded);
    assert!(lab.calls().torrents.is_empty());
}

#[tokio::test]
async fn unqueue_removes_from_queue() {
    let env = routes();
    env.enqueue(&[1, 2], Section::Video);
    unqueue_topic(&env.db, 1).unwrap();
    assert_eq!(env.queued(Section::Video), [2]);
}

#[tokio::test]
async fn unqueue_is_idempotent() {
    let env = routes();
    unqueue_topic(&env.db, 1).unwrap();
    assert!(env.queued(Section::Video).is_empty());
}

#[tokio::test]
async fn add_unknown_topic_rejected() {
    let env = routes();
    let lab = FakeTracker::new(vec![]);
    let err = add_topic(&env.ctx(&lab), 99, NOW).await.unwrap_err();
    assert_eq!(not_listed(&err), Some(99));
    assert_eq!(err.to_string(), "topic 99 is not on the list");
    assert!(lab.calls().torrents.is_empty());
}

#[tokio::test]
async fn image_for_listed_url_is_fetched_lazily() {
    let env = routes();
    let lab = FakeTracker::new(vec![]);
    let found = image_for(&env.ctx(&lab), &key("https://x/b.jpg"), NOW)
        .await
        .unwrap();
    assert_eq!(found, Some((JPEG.to_vec(), "image/jpeg")));
    assert_eq!(lab.calls().fetched, s(&["https://x/b.jpg"]));
}

#[tokio::test]
async fn image_for_unlisted_key() {
    let env = routes();
    let lab = FakeTracker::new(vec![]);
    let found = image_for(&env.ctx(&lab), &key("https://evil/x"), NOW)
        .await
        .unwrap();
    assert_eq!(found, None);
}

#[tokio::test]
async fn image_that_is_not_an_image_is_refused() {
    let env = routes();
    let lab = FakeTracker {
        fetch_body: b"<html>".to_vec(),
        ..FakeTracker::new(vec![])
    };
    let err = image_for(&env.ctx(&lab), &key("https://x/b.jpg"), NOW)
        .await
        .unwrap_err();
    assert_eq!(err.to_string(), "not an image: https://x/b.jpg");
    assert!(!env.images.path("https://x/b.jpg").exists());
}

// Search

fn search_env() -> (Env, FakeTracker) {
    let env = Env::listing(vec![listed(row(1), &[COVER])]);
    let lab = FakeTracker {
        searched: [(
            "alpha".to_string(),
            vec![titled(5, "Alpha One"), titled(6, "Ripe Cherry")],
        )]
        .into(),
        ..FakeTracker::new(vec![])
    };
    (env, lab)
}

#[tokio::test]
async fn run_search_all_time_excludes_and_records() {
    let (mut env, lab) = search_env();
    env.exclude_file = Some(env.write("ex.txt", "cherry\n"));
    let topics = run_search(&env.ctx(&lab), "alpha", NOW).await.unwrap();
    assert_eq!(
        topics.iter().map(|l| l.topic.row.id).collect::<Vec<_>>(),
        [5]
    );
    assert_eq!(
        lab.calls().searches,
        [("alpha".to_string(), None, SEARCH_LIMIT, Some(1))]
    );
    assert_eq!(topics[0].topic.images, None);
    assert_eq!(
        env.db
            .search_topics(NOW)
            .unwrap()
            .into_keys()
            .collect::<HashSet<_>>(),
        [5].into()
    );
    assert_eq!(env.ids(Section::Video), [1]); // the weekly list is untouched
}

#[tokio::test]
async fn run_search_marks_curated_by_title() {
    let (mut env, lab) = search_env();
    env.filter_file = Some(env.write("f.txt", "[Fav]\nalpha\n[Other]\nzulu\n"));
    let topics = run_search(&env.ctx(&lab), "alpha", NOW).await.unwrap();
    assert_eq!(topics[0].filters, s(&["Fav"]));
    assert_eq!(topics[0].curated_reason.as_deref(), Some("Alpha"));
    assert!(topics[1].filters.is_empty());
}

#[tokio::test]
async fn topic_images_fetches_a_searched_topic_once() {
    let (env, lab) = search_env();
    let ctx = env.ctx(&lab);
    run_search(&ctx, "alpha", NOW).await.unwrap();
    assert_eq!(topic_images(&ctx, 5, NOW).await.unwrap()[0], COVER);
    assert_eq!(topic_images(&ctx, 5, NOW).await.unwrap()[0], COVER);
    assert_eq!(lab.calls().topics, [5]);
    assert_eq!(
        env.db.search_topics(NOW).unwrap()[&5]
            .images
            .as_ref()
            .unwrap()[0],
        COVER
    );
}

#[tokio::test]
async fn topic_images_of_a_listed_topic_needs_no_fetch() {
    let (env, lab) = search_env();
    assert_eq!(
        topic_images(&env.ctx(&lab), 1, NOW).await.unwrap(),
        s(&[COVER])
    );
    assert!(lab.calls().topics.is_empty());
}

#[tokio::test]
async fn topic_images_unknown_topic_rejected() {
    let (env, lab) = search_env();
    let err = topic_images(&env.ctx(&lab), 99, NOW).await.unwrap_err();
    assert_eq!(not_listed(&err), Some(99));
    assert!(lab.calls().topics.is_empty());
}

#[tokio::test]
async fn add_accepts_a_searched_topic() {
    let (env, lab) = search_env();
    let ctx = env.ctx(&lab);
    run_search(&ctx, "alpha", NOW).await.unwrap();
    let result = add_topic(&ctx, 5, NOW).await.unwrap();
    assert_eq!(
        result,
        AddResult::Added {
            name: "Release".into()
        }
    );
    assert_eq!(env.added(), [5].into());
}

#[tokio::test]
async fn image_for_accepts_a_searched_topics_image() {
    let (env, lab) = search_env();
    let ctx = env.ctx(&lab);
    run_search(&ctx, "alpha", NOW).await.unwrap();
    env.db.set_images(5, &s(&["https://s/only.jpg"])).unwrap();
    let found = image_for(&ctx, &key("https://s/only.jpg"), NOW)
        .await
        .unwrap();
    assert_eq!(found, Some((JPEG.to_vec(), "image/jpeg")));
}

#[tokio::test]
async fn refresh_keeps_images_of_searched_topics() {
    let (env, lab) = search_env();
    run_search(&env.ctx(&lab), "alpha", NOW).await.unwrap();
    env.db.set_images(5, &s(&["https://s/only.jpg"])).unwrap();
    let path = ensure_image(&lab, &env.images, "https://s/only.jpg")
        .await
        .unwrap();
    env.refresh(&FakeTracker::new(vec![row(1)])).await.unwrap();
    assert!(path.exists());
}

// ExcludeTest

#[tokio::test]
async fn refresh_filters_releases_with_exclude_file() {
    let mut env = Env::new();
    env.exclude_file = Some(env.write("exclude.txt", "cherry\n"));
    let lab = FakeTracker::new(vec![
        titled(1, "Fresh Apple"),
        titled(2, "Ripe Cherry"),
        titled(3, "Sweet Banana"),
    ]);
    env.refresh(&lab).await.unwrap();
    assert_eq!(env.ids(Section::Video), [1, 3]);
}

// Games

fn games_env() -> Env {
    Env {
        games_dir: Some("/games".into()),
        ..Env::new()
    }
}

#[tokio::test]
async fn games_refresh_writes_its_own_list() {
    let env = games_env();
    env.refresh(&FakeTracker::new(vec![row(1)])).await.unwrap();
    let lab = FakeTracker::new(vec![row(2)]);
    env.refresh_games(&lab).await.unwrap();
    assert_eq!(env.ids(Section::Video), [1]);
    assert_eq!(env.ids(Section::Games), [2]);
    assert_eq!(lab.calls().tops, [crate::tracker::forums::games().to_vec()]);
}

#[tokio::test]
async fn games_refresh_runs_no_curated_searches() {
    let mut env = games_env();
    env.filter_file = Some(env.write("f.txt", "[Alpha]\nalpha\n"));
    let lab = FakeTracker::new(vec![row(2)]);
    env.refresh_games(&lab).await.unwrap();
    assert!(lab.calls().searches.is_empty());
}

#[tokio::test]
async fn each_refresh_keeps_the_other_lists_images() {
    let env = games_env();
    env.refresh_games(&FakeTracker::new(vec![row(2)]))
        .await
        .unwrap();
    let games_img = env
        .images
        .path(&env.topics(Section::Games)[0].topic.images.as_ref().unwrap()[0]);
    env.refresh(&FakeTracker::new(vec![titled(1, "other")]))
        .await
        .unwrap();
    assert!(games_img.exists());
}

#[tokio::test]
async fn add_sends_games_to_the_games_dir() {
    let env = games_env();
    env.refresh(&FakeTracker::new(vec![row(1)])).await.unwrap();
    env.refresh_games(&FakeTracker::new(vec![row(2)]))
        .await
        .unwrap();
    let lab = FakeTracker::new(vec![]);
    add_topic(&env.ctx(&lab), 1, NOW).await.unwrap();
    add_topic(&env.ctx(&lab), 2, NOW).await.unwrap();
    assert_eq!(env.torrents.dirs(), s(&["/vault", "/games"]));
}

#[tokio::test]
async fn limit_queues_into_the_games_queue() {
    let env = games_env();
    env.refresh_games(&FakeTracker::new(vec![row(2)]))
        .await
        .unwrap();
    let lab = FakeTracker::with_errors(vec![], &[(2, Fail::Limit)]);
    let result = add_topic(&env.ctx(&lab), 2, NOW).await.unwrap();
    assert!(matches!(result, AddResult::Queued { .. }));
    assert_eq!(
        (env.queued(Section::Video), env.queued(Section::Games)),
        (vec![], vec![2])
    );
    unqueue_topic(&env.db, 2).unwrap();
    assert!(env.queued(Section::Games).is_empty());
}

#[tokio::test]
async fn drain_uses_the_sections_queue_and_dir() {
    let env = games_env();
    env.enqueue(&[1], Section::Video);
    env.enqueue(&[2], Section::Games);
    drain_queue(
        &env.ctx(&FakeTracker::new(vec![])),
        Section::Games,
        "/games",
        NOW,
    )
    .await
    .unwrap();
    assert_eq!(
        (env.torrents.dirs(), env.added()),
        (s(&["/games"]), [2].into())
    );
    assert_eq!(
        (env.queued(Section::Video), env.queued(Section::Games)),
        (vec![1], vec![])
    );
}

#[tokio::test]
async fn run_refresh_drains_each_queue_into_its_dir() {
    let env = games_env();
    env.enqueue(&[1], Section::Video);
    env.enqueue(&[2], Section::Games);
    env.run_refresh(&FakeTracker::new(vec![row(5)]))
        .await
        .unwrap();
    assert_eq!(env.torrents.dirs(), s(&["/vault", "/games"]));
}

#[tokio::test]
async fn limit_in_video_queue_skips_games_queue() {
    let env = games_env();
    env.enqueue(&[1], Section::Video);
    env.enqueue(&[2], Section::Games);
    let lab = FakeTracker::with_errors(vec![row(5)], &[(1, Fail::Limit)]);
    env.run_refresh(&lab).await.unwrap();
    assert_eq!(lab.calls().torrents, [1]);
    assert_eq!(env.queued(Section::Games), [2]);
}

#[tokio::test]
async fn games_failure_leaves_video_refreshed_and_raises() {
    let env = games_env();
    let lab = FakeTracker {
        games_down: true,
        ..FakeTracker::new(vec![row(1)])
    };
    let err = env.run_refresh(&lab).await.unwrap_err();
    assert!(
        matches!(
            err.downcast_ref::<TrackerError>(),
            Some(TrackerError::Http(_))
        ),
        "{err}"
    );
    assert_eq!(env.ids(Section::Video), [1]);
}

/// The daemon spawns these on tokio: their futures must be Send with the real clients.
#[test]
fn futures_are_send() {
    fn send<F: std::future::Future + Send>(_: F) {}
    fn check<'a>(
        ctx: &'a Ctx<'a, crate::tracker::Tracker, crate::transmission::Transmission>,
        k: Option<&'a crate::llm::OpenRouter>,
    ) {
        send(run_refresh(ctx, k, 0));
        send(run_curated(ctx, k, None, 0));
        send(add_topic(ctx, 1, 0));
        send(run_search(ctx, "q", 0));
        send(topic_images(ctx, 1, 0));
        send(image_for(ctx, "k", 0));
    }
    let _ = check;
}

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

// The curated job

impl Env {
    async fn curated(&self, lab: &FakeTracker) -> anyhow::Result<()> {
        run_curated::<_, _, FakeClassify>(&self.ctx(lab), None, None, NOW).await
    }
}

/// Prowlarr with two torrent indexers besides the tracker's ("Primary"): "Indexer A"
/// (id 2) enabled, "Indexer B" (id 3) disabled. A search for `term` returns `results`.
async fn prowlarr(term: &str, results: serde_json::Value) -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/api/v1/indexer"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
            {"id": 1, "name": "Primary", "enable": true, "protocol": "torrent"},
            {"id": 2, "name": "Indexer A", "enable": true, "protocol": "torrent"},
            {"id": 3, "name": "Indexer B", "enable": false, "protocol": "torrent"}
        ])))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/api/v1/search"))
        .and(query_param("query", term))
        .and(query_param("categories", "100"))
        .and(query_param("indexerIds", "2"))
        .respond_with(ResponseTemplate::new(200).set_body_json(results))
        .mount(&server)
        .await;
    server
}

fn ext_result(guid: &str, title: &str, seeders: u32, published: &str) -> serde_json::Value {
    serde_json::json!({"guid": guid, "title": title, "seeders": seeders, "leechers": 1,
        "size": 10, "protocol": "torrent", "indexer": "Indexer A",
        "downloadUrl": format!("http://p/{guid}"), "infoUrl": format!("http://a/{guid}"),
        "publishDate": published})
}

fn sources() -> Sources {
    Sources {
        primary_indexer: Some("Primary".into()),
        categories: vec![100],
        scene_url: None,
        noise: vec![],
        ..Default::default()
    }
}

/// NOW is 2027-01-15; these are within the 32-day window, OLD is not.
const RECENT: &str = "2027-01-10T00:00:00Z";
const OLD: &str = "2026-11-01T00:00:00Z";

#[tokio::test]
async fn refresh_searches_nothing_and_merges_stored_curated_hits() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\nAlpha\n"));
    let lab = FakeTracker::new(vec![row(1)]);
    env.db
        .save_curated(
            &[Topic {
                row: titled(9, "Alpha nine"),
                images: None,
                production: None,
            }],
            &[crate::db::CuratedHit {
                topic_id: 9,
                filter: "Group A".into(),
                reason: "Alpha".into(),
            }],
            NOW,
        )
        .unwrap();
    env.refresh(&lab).await.unwrap();
    assert!(lab.calls().searches.is_empty());
    let listing = env.db.listing(Section::Video).unwrap();
    let nine = listing.topics.iter().find(|l| l.topic.row.id == 9).unwrap();
    assert_eq!(nine.filters, vec!["Group A".to_string()]);
    assert_eq!(nine.curated_reason.as_deref(), Some("Alpha"));
}

#[tokio::test]
async fn curated_searches_every_term_over_the_window_and_lists_the_hits() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n[Group B]\nBeta\n"));
    let mut lab = FakeTracker::new(vec![row(1)]);
    lab.searched
        .insert("Alpha".into(), vec![titled(5, "Alpha five")]);
    lab.searched
        .insert("Beta".into(), vec![titled(6, "Beta six")]);
    env.curated(&lab).await.unwrap();
    let searches = lab.calls().searches.clone();
    assert_eq!(
        searches
            .iter()
            .map(|s| (s.0.as_str(), s.1))
            .collect::<Vec<_>>(),
        vec![("Alpha", Some(32)), ("Beta", Some(32))]
    );
    let listing = env.db.listing(Section::Video).unwrap();
    let ids: Vec<u64> = listing.topics.iter().map(|l| l.topic.row.id).collect();
    assert!(ids.contains(&5) && ids.contains(&6), "{ids:?}");
}

#[tokio::test]
async fn curated_lists_classified_releases_from_other_indexers() {
    let server = prowlarr(
        "Alpha",
        serde_json::json!([
            ext_result("g1", "Alpha Ann Lazy Sunday 480p MP4", 5, RECENT),
            ext_result("g2", "Alpha.Ann.Lazy.Sunday.1080p.MP4", 9, RECENT),
            ext_result("g3", "Alpha Old One 720p", 50, OLD),
        ]),
    )
    .await;
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let lab = FakeTracker::new(vec![row(1)]);
    let k = FakeClassify::answering("pro_artistic", Some(0.9));
    let s = sources();
    run_curated(
        &env.ctx(&lab),
        Some(&k),
        Some(Elsewhere {
            sources: &s,
            scenes: None,
            albums: None,
        }),
        NOW,
    )
    .await
    .unwrap();
    let listing = env.db.listing(Section::Indexers).unwrap();
    let ext: Vec<_> = listing
        .topics
        .iter()
        .filter(|l| crate::db::is_external(l.topic.row.id))
        .collect();
    // Two variants collapse to the best seeded; the old one is out of the window.
    assert_eq!(ext.len(), 1);
    assert_eq!(ext[0].topic.row.seeders, 9);
    assert_eq!(ext[0].filters, vec!["Group A".to_string()]);
    let e = env.db.external(ext[0].topic.row.id).unwrap().unwrap();
    assert_eq!(
        (e.indexer.as_str(), e.link.as_str()),
        ("Indexer A", "http://p/g2")
    );
    // The external release's page is never fetched from the tracker.
    assert!(!lab.calls().topics.contains(&ext[0].topic.row.id));
}

#[tokio::test]
async fn curated_drops_the_down_ranked_class_and_holds_back_unclassified() {
    let server = prowlarr(
        "Alpha",
        serde_json::json!([ext_result("g1", "Alpha Ann Lazy", 5, RECENT)]),
    )
    .await;
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let lab = FakeTracker::new(vec![row(1)]);
    let s = sources();
    for k in [
        FakeClassify::answering(crate::curated::DOWN_RANKED, None),
        FakeClassify::failing(),
    ] {
        run_curated(
            &env.ctx(&lab),
            Some(&k),
            Some(Elsewhere {
                sources: &s,
                scenes: None,
                albums: None,
            }),
            NOW,
        )
        .await
        .unwrap();
        let listing = env.db.listing(Section::Video).unwrap();
        assert!(
            !listing
                .topics
                .iter()
                .any(|l| crate::db::is_external(l.topic.row.id))
        );
    }
}

#[tokio::test]
async fn curated_drops_excluded_releases_from_other_indexers_before_classifying() {
    let server = prowlarr(
        "Alpha",
        serde_json::json!([
            ext_result("g1", "Alpha Ann Lazy", 5, RECENT),
            ext_result("g2", "Alpha KIWI Rain", 9, RECENT),
        ]),
    )
    .await;
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    env.exclude_file = Some(env.write("x.txt", "\\bkiwi\\b\n"));
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let lab = FakeTracker::new(vec![row(1)]);
    let k = FakeClassify::answering("pro_artistic", None);
    let s = sources();
    run_curated(
        &env.ctx(&lab),
        Some(&k),
        Some(Elsewhere {
            sources: &s,
            scenes: None,
            albums: None,
        }),
        NOW,
    )
    .await
    .unwrap();
    let titles: Vec<String> = env
        .db
        .listing(Section::Indexers)
        .unwrap()
        .topics
        .into_iter()
        .filter(|l| crate::db::is_external(l.topic.row.id))
        .map(|l| l.topic.row.title)
        .collect();
    assert_eq!(titles, vec!["Alpha Ann Lazy".to_string()]);
    // Never sent to the classifier (the rebuild also classifies the tracker's topics).
    assert!(
        !k.titles().iter().any(|t| t.contains("KIWI")),
        "{:?}",
        k.titles()
    );
}

#[tokio::test]
async fn curated_drops_what_the_tracker_already_has() {
    let server = prowlarr(
        "Alpha",
        serde_json::json!([ext_result(
            "g1",
            "Alpha 27 01 05 Ann And Ben Lazy Sunday 1080p",
            5,
            RECENT
        )]),
    )
    .await;
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let mut lab = FakeTracker::new(vec![row(1)]);
    lab.searched.insert(
        "Alpha".into(),
        vec![titled(
            5,
            "[Alpha.com] Ann Doe, Ben Roe - Lazy Sunday (05.01.2027)",
        )],
    );
    let k = FakeClassify::answering("pro_artistic", None);
    let s = sources();
    run_curated(
        &env.ctx(&lab),
        Some(&k),
        Some(Elsewhere {
            sources: &s,
            scenes: None,
            albums: None,
        }),
        NOW,
    )
    .await
    .unwrap();
    let listing = env.db.listing(Section::Video).unwrap();
    assert!(
        !listing
            .topics
            .iter()
            .any(|l| crate::db::is_external(l.topic.row.id))
    );
    assert!(listing.topics.iter().any(|l| l.topic.row.id == 5));
}

#[tokio::test]
async fn curated_keeps_tracker_hits_when_prowlarr_is_down_and_ids_stay_stable() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    // Nothing listens on port 1: Prowlarr is down.
    env.prowlarr = Some(Prowlarr::new("http://127.0.0.1:1", "k".into()));
    let mut lab = FakeTracker::new(vec![row(1)]);
    lab.searched
        .insert("Alpha".into(), vec![titled(5, "Alpha five")]);
    let k = FakeClassify::answering("pro_artistic", None);
    let s = sources();
    run_curated(
        &env.ctx(&lab),
        Some(&k),
        Some(Elsewhere {
            sources: &s,
            scenes: None,
            albums: None,
        }),
        NOW,
    )
    .await
    .unwrap();
    let ids: Vec<u64> = env
        .db
        .listing(Section::Video)
        .unwrap()
        .topics
        .iter()
        .map(|l| l.topic.row.id)
        .collect();
    assert!(ids.contains(&5));

    // The same guid on a later run keeps its id.
    let server = prowlarr(
        "Alpha",
        serde_json::json!([ext_result("g1", "Alpha Ann Lazy", 5, RECENT)]),
    )
    .await;
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    for _ in 0..2 {
        run_curated(
            &env.ctx(&lab),
            Some(&k),
            Some(Elsewhere {
                sources: &s,
                scenes: None,
                albums: None,
            }),
            NOW,
        )
        .await
        .unwrap();
    }
    assert_eq!(
        env.db
            .externals()
            .unwrap()
            .keys()
            .copied()
            .collect::<Vec<_>>(),
        vec![crate::db::EXTERNAL_BASE]
    );
}

#[tokio::test]
async fn curated_sets_scene_images_on_an_accepted_hit_only() {
    let server = prowlarr(
        "Alpha",
        serde_json::json!([
            ext_result("g1", "Alpha Ann Lazy", 5, RECENT),
            ext_result("g2", "Alpha Cat Rain", 4, RECENT),
        ]),
    )
    .await;
    let scenes = MockServer::start().await;
    Mock::given(method("GET"))
        .and(query_param("parse", "alpha ann lazy"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": [
            {"id": "s1", "site": {"name": "Alpha"}, "poster": "http://i/p.jpg"}]})),
        )
        .mount(&scenes)
        .await;
    Mock::given(method("GET"))
        .and(query_param("parse", "alpha cat rain"))
        .respond_with(
            ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": [
            {"id": "s2", "site": {"name": "Unrelated"}, "poster": "http://i/q.jpg"}]})),
        )
        .mount(&scenes)
        .await;
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let lab = FakeTracker::new(vec![row(1)]);
    let k = FakeClassify::answering("pro_artistic", None);
    let s = sources();
    let db = SceneDb::new(&scenes.uri(), "k");
    run_curated(
        &env.ctx(&lab),
        Some(&k),
        Some(Elsewhere {
            sources: &s,
            scenes: Some(&db),
            albums: None,
        }),
        NOW,
    )
    .await
    .unwrap();
    let ext = env.db.externals().unwrap();
    let by_title = |t: &str| {
        env.db
            .listing(Section::Indexers)
            .unwrap()
            .topics
            .into_iter()
            .find(|l| l.topic.row.title == t)
            .unwrap()
    };
    let ann = by_title("Alpha Ann Lazy");
    assert_eq!(ann.topic.images, Some(vec!["http://i/p.jpg".to_string()]));
    assert_eq!(ext[&ann.topic.row.id].scene_id.as_deref(), Some("s1"));
    let cat = by_title("Alpha Cat Rain");
    assert_eq!(cat.topic.images.unwrap_or_default(), Vec::<String>::new());
    assert_eq!(ext[&cat.topic.row.id].scene_id, None);
}

#[tokio::test]
async fn external_torrent_stores_a_torrent_and_passes_a_magnet() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/dl/1"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"d4:infod1:xi1eee".to_vec()))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/dl/2"))
        .respond_with(
            ResponseTemplate::new(302).insert_header("Location", "magnet:?xt=urn:btih:00"),
        )
        .mount(&server)
        .await;
    let env = Env::new();
    let p = Prowlarr::new(&server.uri(), "k".into());
    let (l1, l2) = (
        format!("{}/dl/1", server.uri()),
        format!("{}/dl/2", server.uri()),
    );
    let mk = |guid, link| crate::db::NewExternal {
        indexer: "Indexer A",
        guid,
        link,
        info_url: None,
        kind: crate::db::Kind::Torrent,
        files: None,
        seen: 0,
    };
    let a = env.db.upsert_external(&mk("1", &l1)).unwrap();
    let b = env.db.upsert_external(&mk("2", &l2)).unwrap();
    for _ in 0..2 {
        // The second call reads the stored file: the mock expects one fetch.
        assert!(matches!(
            external_torrent(Some(&p), &env.db, a, NOW).await.unwrap(),
            TorrentSource::Bytes(_)
        ));
    }
    assert!(matches!(
        external_torrent(Some(&p), &env.db, b, NOW).await.unwrap(),
        TorrentSource::Magnet(m) if m.starts_with("magnet:")
    ));
}

#[tokio::test]
async fn adding_an_external_release_never_touches_the_tracker() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/dl/1"))
        .respond_with(
            ResponseTemplate::new(302).insert_header("Location", "magnet:?xt=urn:btih:00"),
        )
        .mount(&server)
        .await;
    let mut env = Env::new();
    let link = format!("{}/dl/1", server.uri());
    let id = env
        .db
        .upsert_external(&crate::db::NewExternal {
            indexer: "Indexer A",
            guid: "1",
            link: &link,
            info_url: None,
            kind: crate::db::Kind::Torrent,
            files: None,
            seen: 0,
        })
        .unwrap();
    env.db
        .save_curated(
            &[Topic {
                row: titled(id, "Alpha one"),
                images: None,
                production: None,
            }],
            &[crate::db::CuratedHit {
                topic_id: id,
                filter: "A".into(),
                reason: "Alpha".into(),
            }],
            NOW,
        )
        .unwrap();
    let lab = FakeTracker::new(vec![row(1)]);
    crate::curated::rebuild_external(&env.ctx(&lab), NOW)
        .await
        .unwrap(); // lists it
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let r = add_topic(&env.ctx(&lab), id, NOW).await.unwrap();
    assert!(matches!(r, AddResult::Added { .. }), "{r:?}");
    assert!(lab.calls().torrents.is_empty());
    // FakeTorrents records a magnet as its string: the link's magnet, not a `.torrent`.
    let added: Vec<Vec<u8>> = env
        .torrents
        .calls
        .lock()
        .unwrap()
        .iter()
        .map(|(b, _)| b.clone())
        .collect();
    assert_eq!(added, vec![b"magnet:?xt=urn:btih:00".to_vec()]);
    assert!(
        env.db.torrent_file(id).unwrap().is_none(),
        "a magnet is not stored"
    );
    assert!(
        topic_images(&env.ctx(&lab), id, NOW)
            .await
            .unwrap()
            .is_empty()
    );
    // Listed under Indexers, but a Vault video download all the same: provenance sync
    // must see it.
    assert_eq!(
        env.db.unsynced_downloads().unwrap(),
        vec![(1, "abc".to_string())]
    );
}

/// An album index answering every search with the placeholder fixture page.
async fn album_index() -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/"))
        .respond_with(ResponseTemplate::new(200).set_body_string(fixture("albums_search.html")))
        .mount(&server)
        .await;
    server
}

impl Env {
    async fn curated_albums(&self, lab: &FakeTracker, index: &AlbumIndex, now: i64) {
        let s = Sources::default();
        run_curated::<_, _, FakeClassify>(
            &self.ctx(lab),
            None,
            Some(Elsewhere {
                sources: &s,
                scenes: None,
                albums: Some(index),
            }),
            now,
        )
        .await
        .unwrap();
    }

    fn album_hits(&self) -> Vec<(String, i64, Option<Vec<String>>)> {
        self.db
            .curated_hits()
            .unwrap()
            .into_iter()
            .filter(|h| h.kind == Some(Kind::Album))
            .map(|h| (h.topic.row.title, h.topic.row.added, h.topic.images))
            .collect()
    }
}

#[tokio::test]
async fn curated_searches_only_percent_terms_on_the_album_index() {
    let server = album_index().await;
    let index = AlbumIndex::new(&format!("{}/", server.uri()), "Album index A", "strict");
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n%Alpha\nBeta\n"));
    let lab = FakeTracker::new(vec![row(1)]);
    env.curated_albums(&lab, &index, NOW).await;
    let asked: Vec<String> = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter_map(|r| {
            r.url
                .query_pairs()
                .find(|(k, _)| k == "search")
                .map(|(_, v)| v.into_owned())
        })
        .collect();
    assert_eq!(asked, vec!["Alpha".to_string()]);
    let hits = env.album_hits();
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].0, "Alpha One & Two");
    assert_eq!(hits[0].1, NOW);
    assert_eq!(
        hits[0].2,
        Some(vec!["https://cdn.example/thumbs/one-&-two.png".to_string()])
    );
    // Both are still searched on the tracker as before.
    assert_eq!(lab.calls().searches.len(), 2);
}

#[tokio::test]
async fn an_album_keeps_its_first_sight_and_ages_out_for_good() {
    let server = album_index().await;
    let index = AlbumIndex::new(&format!("{}/", server.uri()), "Album index A", "strict");
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n%Alpha\n"));
    let lab = FakeTracker::new(vec![row(1)]);
    env.curated_albums(&lab, &index, NOW).await;
    env.curated_albums(&lab, &index, NOW + 10 * 86400).await;
    assert!(env.album_hits().iter().all(|h| h.1 == NOW));
    // 33 days after first sight: out of the window, although the page still lists them.
    env.curated_albums(&lab, &index, NOW + 33 * 86400).await;
    assert!(env.album_hits().is_empty());
    // And not re-seen as new once their topics are gone.
    env.curated_albums(&lab, &index, NOW + 34 * 86400).await;
    assert!(env.album_hits().is_empty());
}

#[tokio::test]
async fn percent_terms_without_an_album_index_still_store_the_tracker_hits() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n%Alpha\n"));
    let mut lab = FakeTracker::new(vec![row(1)]);
    lab.searched
        .insert("Alpha".into(), vec![titled(5, "Alpha five")]);
    env.curated(&lab).await.unwrap();
    let ids: Vec<u64> = env
        .db
        .curated_hits()
        .unwrap()
        .iter()
        .map(|h| h.topic.row.id)
        .collect();
    assert_eq!(ids, vec![5]);
}

#[tokio::test]
async fn each_source_kind_gets_its_own_list() {
    let mut env = Env::new();
    env.filter_file = Some(env.write(
        "f.txt",
        "[Group A]\nAlpha\n[Group B]\nBeta\n[Group C]\nGamma\n",
    ));
    fn ext(guid: &str, kind: Kind) -> crate::db::NewExternal<'_> {
        crate::db::NewExternal {
            indexer: "Indexer A",
            guid,
            link: "http://p/1",
            info_url: Some("http://a/1"),
            kind,
            files: None,
            seen: NOW,
        }
    }
    let torrent = env.db.upsert_external(&ext("g1", Kind::Torrent)).unwrap();
    let album = env.db.upsert_external(&ext("a1", Kind::Album)).unwrap();
    let hit = |id: u64, f: &str| crate::db::CuratedHit {
        topic_id: id,
        filter: f.into(),
        reason: "Alpha".into(),
    };
    let t = |id: u64, title: &str| Topic {
        row: titled(id, title),
        images: None,
        production: None,
    };
    env.db
        .save_curated(
            &[
                t(9, "Alpha nine"),
                t(torrent, "Beta ext"),
                t(album, "Gamma album"),
            ],
            &[
                hit(9, "Group A"),
                hit(torrent, "Group B"),
                hit(album, "Group C"),
            ],
            NOW,
        )
        .unwrap();
    let lab = FakeTracker::new(vec![row(1)]);
    env.refresh(&lab).await.unwrap();
    crate::curated::rebuild_external(&env.ctx(&lab), NOW)
        .await
        .unwrap();
    let ids = |s| -> Vec<u64> {
        env.db
            .listing(s)
            .unwrap()
            .topics
            .iter()
            .map(|l| l.topic.row.id)
            .collect()
    };
    let video = ids(Section::Video);
    assert!(video.contains(&9) && !video.contains(&torrent) && !video.contains(&album));
    assert_eq!(ids(Section::Indexers), vec![torrent]);
    assert_eq!(ids(Section::Albums), vec![album]);
    // A list names only the filters it holds hits of.
    assert_eq!(
        env.db.listing(Section::Indexers).unwrap().filters,
        vec!["Group B".to_string()]
    );
    assert_eq!(
        env.db.listing(Section::Albums).unwrap().filters,
        vec!["Group C".to_string()]
    );
    // No tracker page is fetched for an external release.
    assert!(!lab.calls().topics.contains(&torrent) && !lab.calls().topics.contains(&album));
}
