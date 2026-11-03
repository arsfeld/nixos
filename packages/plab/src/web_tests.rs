//! The HTTP-handler tests of plab's test_main.py (SearchRoutes, Static, the exclude and
//! games route tests) plus the add/unqueue/img/404 routes, driven through the router with
//! `oneshot` and fake clients.

use super::*;
use crate::db::{Listed, Topic};
use crate::events::Event;
use crate::tracker::TrackerError;
use crate::tracker::parse::Row;
use crate::transmission::{Added, Torrent, TorrentSource};
use axum::http::Request;
use futures::StreamExt;
use http_body_util::BodyExt;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;
use tower::ServiceExt;

const JPEG: &[u8] = b"\xff\xd8\xff\xe0jpeg";
const COVER: &str = "https://i128.fastpic.org/big/2026/1004/19/cover.jpg";

fn row(id: u64, title: &str) -> Row {
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

type SearchCall = (String, Option<u32>, usize, Option<usize>);

#[derive(Default)]
struct FakeTracker {
    searched: HashMap<String, Vec<Row>>,
    search_error: Mutex<Option<String>>,
    broken: Mutex<HashSet<u64>>,
    limit: HashSet<u64>,
    fetch_body: Option<Vec<u8>>,
    searches: Mutex<Vec<SearchCall>>,
    topics: Mutex<Vec<u64>>,
    torrents: Mutex<Vec<u64>>,
    fetched: Mutex<Vec<String>>,
}

impl TrackerApi for FakeTracker {
    async fn top(
        &self,
        _: &[u32],
        _: u32,
        _: usize,
        _: &crate::filters::Excludes,
    ) -> Result<Vec<Row>, TrackerError> {
        Ok(vec![])
    }

    async fn search(
        &self,
        query: &str,
        _: &[u32],
        days: Option<u32>,
        limit: usize,
        _: &crate::filters::Excludes,
        pages: Option<usize>,
    ) -> Result<Vec<Row>, TrackerError> {
        self.searches
            .lock()
            .unwrap()
            .push((query.into(), days, limit, pages));
        if let Some(m) = self.search_error.lock().unwrap().clone() {
            return Err(TrackerError::Login(m));
        }
        Ok(self.searched.get(query).cloned().unwrap_or_default())
    }

    async fn topic(&self, id: u64) -> Result<String, TrackerError> {
        self.topics.lock().unwrap().push(id);
        if self.broken.lock().unwrap().contains(&id) {
            return Err(TrackerError::Tracker("boom".into()));
        }
        let path =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/topic.html");
        Ok(std::fs::read_to_string(path).unwrap())
    }

    async fn torrent(&self, id: u64) -> Result<Vec<u8>, TrackerError> {
        self.torrents.lock().unwrap().push(id);
        if self.limit.contains(&id) {
            return Err(TrackerError::Limit(10));
        }
        Ok(b"d4:infoe".to_vec())
    }

    async fn fetch(&self, url: &str) -> Result<Vec<u8>, TrackerError> {
        self.fetched.lock().unwrap().push(url.into());
        Ok(self.fetch_body.clone().unwrap_or_else(|| JPEG.to_vec()))
    }
}

#[derive(Default)]
struct FakeTorrents {
    details: Vec<crate::transmission::Detail>,
    details_fail: bool,
    calls: Mutex<Vec<(Vec<u8>, String)>>,
}

impl TorrentClient for FakeTorrents {
    async fn add(&self, src: &TorrentSource, dir: &str) -> anyhow::Result<Added> {
        let TorrentSource::Bytes(b) = src else {
            unreachable!()
        };
        self.calls.lock().unwrap().push((b.clone(), dir.into()));
        Ok(Added {
            name: "Release".into(),
            hash: Some("abc".into()),
        })
    }

    async fn details(&self, hashes: &[String]) -> anyhow::Result<Vec<crate::transmission::Detail>> {
        if self.details_fail {
            anyhow::bail!("transmission down");
        }
        Ok(self
            .details
            .iter()
            .filter(|d| hashes.contains(&d.hash_string))
            .cloned()
            .collect())
    }

    async fn torrents(&self) -> anyhow::Result<Vec<Torrent>> {
        Ok(vec![])
    }

    async fn remove(&self, _: &[i64]) -> anyhow::Result<()> {
        Ok(())
    }
}

struct Fx {
    _dir: tempfile::TempDir,
    state: Arc<WebState<FakeTracker, FakeTorrents>>,
}

struct Reply {
    status: u16,
    headers: axum::http::HeaderMap,
    body: Vec<u8>,
}

impl Reply {
    fn header(&self, name: &str) -> &str {
        self.headers[name].to_str().unwrap()
    }

    fn json(&self) -> Value {
        serde_json::from_str(&self.text()).unwrap()
    }

    fn text(&self) -> String {
        String::from_utf8(self.body.clone()).unwrap()
    }
}

impl Fx {
    fn new() -> Fx {
        Fx::with(FakeTracker::default(), |_, _| {})
    }

    fn with(
        tracker: FakeTracker,
        setup: impl FnOnce(&std::path::Path, &mut WebState<FakeTracker, FakeTorrents>),
    ) -> Fx {
        let dir = tempfile::tempdir().unwrap();
        let mut state = WebState {
            tracker: Arc::new(tracker),
            torrents: Arc::new(FakeTorrents::default()),
            db: Db::open(&dir.path().join("plab.db")).unwrap(),
            images: ImageCache::new(dir.path().join("img")).unwrap(),
            state_dir: dir.path().to_path_buf(),
            exclude_file: None,
            filter_file: None,
            download_dir: "/vault".into(),
            games_dir: None,
            stash_web_url: None,
            static_dir: None,
            events: crate::events::Events::default(),
            monitor: crate::monitor::Monitor::default(),
            fetch_slots: Arc::new(tokio::sync::Semaphore::new(2)),
            add_lock: Arc::new(tokio::sync::Mutex::new(())),
            engine: None,
            streams: Arc::new(crate::stream::Streams::default()),
            stream_public_url: Some("https://plab-stream.example".into()),
            prowlarr: None,
            assistant: None,
        };
        setup(dir.path(), &mut state);
        Fx {
            _dir: dir,
            state: Arc::new(state),
        }
    }

    fn save_video(&self, topics: &[Listed]) {
        self.state
            .db
            .save_listing(Section::Video, topics, &[], now())
            .unwrap();
    }

    async fn send_to(
        &self,
        router: Router,
        method: &str,
        path: &str,
        range: Option<&str>,
        body: Option<Vec<u8>>,
    ) -> Reply {
        let mut req = Request::builder().method(method).uri(path);
        if let Some(r) = range {
            req = req.header("range", r);
        }
        let body = match body {
            Some(b) => {
                req = req.header("content-type", "application/json");
                Body::from(b)
            }
            None => Body::empty(),
        };
        let resp = router.oneshot(req.body(body).unwrap()).await.unwrap();
        let (parts, body) = resp.into_parts();
        Reply {
            status: parts.status.as_u16(),
            headers: parts.headers,
            body: body.collect().await.unwrap().to_bytes().to_vec(),
        }
    }

    async fn send_body(&self, method: &str, path: &str, body: Vec<u8>) -> Reply {
        self.send_to(router(self.state.clone()), method, path, None, Some(body))
            .await
    }

    async fn post_json(&self, path: &str, v: Value) -> Reply {
        self.send_body("POST", path, v.to_string().into_bytes())
            .await
    }

    async fn request(&self, method: &str, path: &str) -> Reply {
        self.page(method, path, None).await
    }

    async fn page(&self, method: &str, path: &str, range: Option<&str>) -> Reply {
        self.send_to(router(self.state.clone()), method, path, range, None)
            .await
    }

    async fn tailnet(&self, method: &str, path: &str) -> Reply {
        self.send_to(stream_router(self.state.clone()), method, path, None, None)
            .await
    }

    async fn get(&self, path: &str) -> Reply {
        self.request("GET", path).await
    }

    async fn post(&self, path: &str) -> Reply {
        self.request("POST", path).await
    }
}

fn searching() -> FakeTracker {
    let mut t = FakeTracker::default();
    t.searched.insert("alpha".into(), vec![row(5, "Alpha One")]);
    t
}

// Search

#[tokio::test]
async fn a_blank_search_is_400() {
    assert_eq!(Fx::new().get("/api/search?q=+").await.status, 400);
}

#[tokio::test]
async fn search_returns_its_results_as_json() {
    let fx = Fx::with(searching(), |_, _| {});
    let r = fx.get("/api/search?q=alpha").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.header("content-type"), "application/json");
    assert_eq!(r.header("cache-control"), "no-store");
    let v = r.json();
    assert_eq!(
        (v["query"].clone(), v["error"].clone()),
        (json!("alpha"), Value::Null)
    );
    assert_eq!(v["topics"][0]["id"], 5);
    assert_eq!(v["topics"][0]["images"], Value::Null);
    assert_eq!(
        *fx.state.tracker.searches.lock().unwrap(),
        vec![("alpha".to_string(), None, plab::SEARCH_LIMIT, Some(1))]
    );
}

#[tokio::test]
async fn a_search_failure_is_its_error() {
    let t = searching();
    *t.search_error.lock().unwrap() = Some("login needs captcha".into());
    let v = Fx::with(t, |_, _| {})
        .get("/api/search?q=alpha")
        .await
        .json();
    assert!(
        v["error"].as_str().unwrap().contains("login needs captcha"),
        "{v}"
    );
    assert_eq!(v["topics"], json!([]));
}

#[tokio::test]
async fn thumb_redirects_to_the_cached_image() {
    let fx = Fx::with(searching(), |_, _| {});
    fx.get("/api/search?q=alpha").await;
    let r = fx.get("/api/thumb/5").await;
    assert_eq!(
        (r.status, r.header("location")),
        (302, format!("../img/{}", key(COVER)).as_str())
    );
    assert!(fx.state.images.path(COVER).exists());
}

#[tokio::test]
async fn thumb_unknown_topic_is_404() {
    let fx = Fx::new();
    let r = fx.get("/api/thumb/99").await;
    assert_eq!(r.status, 404);
    assert_eq!(r.text(), "topic 99 is not on the list");
    assert!(fx.state.tracker.topics.lock().unwrap().is_empty());
}

#[tokio::test]
async fn thumb_topic_without_images_is_404() {
    let fx = Fx::with(searching(), |_, _| {});
    fx.get("/api/search?q=alpha").await;
    fx.state.db.set_images(5, &[]).unwrap();
    let r = fx.get("/api/thumb/5").await;
    assert_eq!((r.status, r.text().as_str()), (404, "no images"));
}

#[tokio::test]
async fn thumb_fetch_failure_is_502() {
    let fx = Fx::with(searching(), |_, _| {});
    fx.get("/api/search?q=alpha").await;
    fx.state.tracker.broken.lock().unwrap().insert(5);
    let r = fx.get("/api/thumb/5").await;
    assert_eq!((r.status, r.text().as_str()), (502, "images unavailable"));
}

#[tokio::test]
async fn thumb_that_is_not_an_image_is_404() {
    let mut t = searching();
    t.fetch_body = Some(b"<html>".to_vec());
    let fx = Fx::with(t, |_, _| {});
    fx.get("/api/search?q=alpha").await;
    let r = fx.get("/api/thumb/5").await;
    assert_eq!(r.status, 404);
    assert!(r.text().starts_with("not an image: "));
}

#[tokio::test]
async fn images_lists_keys() {
    let fx = Fx::with(searching(), |_, _| {});
    fx.get("/api/search?q=alpha").await;
    let r = fx.get("/api/images/5").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.header("content-type"), "application/json");
    assert_eq!(r.json()["images"][0], key(COVER));
}

// The app

fn app_fx() -> Fx {
    Fx::with(FakeTracker::default(), |dir, st| {
        let dist = dir.join("dist");
        std::fs::create_dir_all(dist.join("assets")).unwrap();
        std::fs::write(dist.join("index.html"), "<!doctype html>app").unwrap();
        std::fs::write(dist.join("assets/index-abc123.js"), "js").unwrap();
        std::fs::write(dist.join("assets/index-abc123.css"), "css").unwrap();
        std::fs::write(dist.join("secret.txt"), "secret").unwrap();
        st.static_dir = Some(dist);
    })
}

#[tokio::test]
async fn app_routes_serve_the_index() {
    let fx = app_fx();
    for path in ["/", "/games", "/jobs", "/search?q=x", "/anything/else"] {
        let r = fx.get(path).await;
        assert_eq!(r.status, 200, "{path}");
        assert_eq!(r.header("content-type"), "text/html; charset=utf-8");
        assert_eq!(r.header("cache-control"), "no-cache");
        assert_eq!(r.text(), "<!doctype html>app");
    }
}

#[tokio::test]
async fn assets_are_served_immutable_with_their_types() {
    let fx = app_fx();
    for (name, ctype, body) in [
        ("index-abc123.js", "text/javascript; charset=utf-8", "js"),
        ("index-abc123.css", "text/css; charset=utf-8", "css"),
    ] {
        let r = fx.get(&format!("/assets/{name}")).await;
        assert_eq!(r.status, 200, "{name}");
        assert_eq!(r.header("content-type"), ctype);
        assert_eq!(
            r.header("cache-control"),
            "private, max-age=31536000, immutable"
        );
        assert_eq!(r.text(), body);
    }
}

#[tokio::test]
async fn asset_traversal_unknown_types_and_missing_files_are_404() {
    let fx = app_fx();
    for name in [
        "../secret.txt",
        "..%2fsecret.txt",
        "sub/x.js",
        ".hidden.js",
        "index-abc123.txt",
        "",
        "gone.js",
    ] {
        assert_eq!(
            fx.get(&format!("/assets/{name}")).await.status,
            404,
            "{name}"
        );
    }
}

#[tokio::test]
async fn without_a_built_app_the_index_is_503() {
    let r = Fx::new().get("/").await;
    assert_eq!(r.status, 503);
}

#[tokio::test]
async fn unrouted_api_paths_are_404_text() {
    let fx = Fx::new();
    for (method, path) in [
        ("GET", "/api/nope"),
        ("GET", "/api/img/xyz"),
        ("GET", "/api/thumb/abc"),
        ("GET", "/api/thumb/"),
        ("POST", "/"),
        ("POST", "/api/add/x"),
        ("POST", "/api/search"),
        ("POST", "/add/1"),
        ("DELETE", "/api/list"),
    ] {
        let r = fx.request(method, path).await;
        assert_eq!(
            (r.status, r.text().as_str()),
            (404, "not found"),
            "{method} {path}"
        );
        assert_eq!(r.header("content-type"), "text/plain");
    }
    assert_eq!(fx.get("/api/list?section=x").await.status, 400);
}

// Lists

#[tokio::test]
async fn the_list_leaves_out_excluded_topics() {
    let fx = Fx::with(FakeTracker::default(), |dir, st| {
        let path = dir.join("exclude.txt");
        std::fs::write(&path, "cherry\n").unwrap();
        st.exclude_file = Some(path);
    });
    fx.save_video(&[
        listed(row(1, "Fresh Apple"), &[]),
        listed(row(2, "Ripe Cherry"), &[]),
    ]);
    for path in ["/api/list", "/api/list?section=video"] {
        let r = fx.get(path).await;
        assert_eq!((r.status, r.header("cache-control")), (200, "no-store"));
        let v = r.json();
        assert_eq!(v["section"], "video");
        assert_eq!(v["topics"].as_array().unwrap().len(), 1);
        assert_eq!(v["topics"][0]["title"], "Fresh Apple");
    }
}

#[tokio::test]
async fn the_games_list() {
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.games_dir = Some("/games".into())
    });
    fx.state
        .db
        .save_listing(Section::Games, &[listed(row(2, "A Game"), &[])], &[], now())
        .unwrap();
    let v = fx.get("/api/list?section=games").await.json();
    assert_eq!(
        (v["section"].clone(), v["topics"][0]["title"].clone()),
        (json!("games"), json!("A Game"))
    );
}

fn mark(fx: &Fx, id: u64, section: Section, dir: &str, hash: &str, at: i64) -> i64 {
    fx.state
        .db
        .mark_added(crate::db::NewDownload {
            source: "plab",
            topic_id: Some(id),
            release_title: "Fresh Apple",
            section,
            download_dir: Some(dir),
            torrent_hash: Some(hash),
            now: at,
        })
        .unwrap()
}

#[tokio::test]
async fn a_downloaded_topic_links_to_its_stash_scene() {
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.stash_web_url = Some("https://stash.example".into());
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[])]);
    let id = mark(&fx, 1, Section::Video, "/vault", "abc", now());
    fx.state.db.save_files(id, &["Rel/a.mp4".into()]).unwrap();
    fx.state.db.link_scene("Rel/a.mp4", Some("42")).unwrap();
    let v = fx.get("/api/list").await.json();
    assert_eq!(
        v["topics"][0]["status"]["link"], "https://stash.example/scenes/42",
        "{v}"
    );
}

#[tokio::test]
async fn a_downloading_topic_carries_its_progress() {
    let mut d = crate::provenance::tests::detail("abc", "/d", 0.5, &[]);
    d.activity_date = now();
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.torrents = Arc::new(FakeTorrents {
            details: vec![d],
            ..Default::default()
        });
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[])]);
    mark(&fx, 1, Section::Video, "/vault", "abc", now());
    let v = fx.get("/api/list").await.json();
    assert_eq!(
        v["topics"][0]["status"],
        json!({"kind": "downloading", "percent": 50})
    );
}

#[tokio::test]
async fn a_games_download_has_no_status() {
    // Games land outside the Vault library, so provenance never covers them: an old one
    // Transmission no longer has must not read "failed: lost".
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.games_dir = Some("/games".into())
    });
    fx.state
        .db
        .save_listing(Section::Games, &[listed(row(2, "A Game"), &[])], &[], now())
        .unwrap();
    mark(&fx, 2, Section::Games, "/games", "g1", now() - 3 * 86400);
    let v = fx.get("/api/list?section=games").await.json();
    assert_eq!(v["topics"][0]["status"], Value::Null);
}

#[tokio::test]
async fn the_list_still_serves_when_transmission_fails() {
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.torrents = Arc::new(FakeTorrents {
            details_fail: true,
            ..Default::default()
        });
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[])]);
    mark(&fx, 1, Section::Video, "/vault", "abc", now());
    let r = fx.get("/api/list").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json()["topics"][0]["status"], json!({"kind": "added"}));
}

#[tokio::test]
async fn grabs_and_jobs_are_json() {
    let fx = Fx::new();
    fx.state.monitor.register("prune");
    fx.state.monitor.register("identify");
    let g = fx.get("/api/grabs").await;
    assert_eq!((g.status, g.json()["grabs"].clone()), (200, json!([])));
    let j = fx.get("/api/jobs").await.json();
    let names: Vec<&str> = j["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .map(|x| x["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["identify", "prune"]);
    assert!(j["jobs"][1]["next"].is_i64());
}

// Events

#[tokio::test]
async fn add_and_unqueue_publish_the_topic_state() {
    let mut t = FakeTracker::default();
    t.limit.insert(2);
    let fx = Fx::with(t, |_, _| {});
    fx.save_video(&[listed(row(1, "t1"), &[]), listed(row(2, "t2"), &[])]);
    let mut rx = fx.state.events.subscribe();
    fx.post("/api/add/1").await;
    fx.post("/api/add/2").await;
    fx.post("/api/unqueue/2").await;
    fx.post("/api/add/99").await; // fails: publishes nothing
    let got: Vec<Event> = std::iter::from_fn(|| rx.try_recv().ok()).collect();
    assert_eq!(
        got,
        vec![
            Event::TopicState {
                id: 1,
                state: "added"
            },
            Event::TopicState {
                id: 2,
                state: "queued"
            },
            Event::TopicState { id: 2, state: "" },
        ]
    );
}

#[tokio::test]
async fn events_is_an_event_stream() {
    let fx = Fx::new();
    let resp = router(fx.state.clone())
        .oneshot(Request::get("/api/events").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.headers()["content-type"], "text/event-stream");
    let mut body = resp.into_body().into_data_stream();
    fx.state.events.publish(Event::Listing { section: "video" });
    let chunk = tokio::time::timeout(std::time::Duration::from_secs(2), body.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(
        std::str::from_utf8(&chunk).unwrap(),
        "data: {\"type\":\"listing\",\"section\":\"video\"}\n\n"
    );
}

// Add / unqueue

fn listed_fx(t: FakeTracker) -> Fx {
    let fx = Fx::with(t, |_, _| {});
    fx.save_video(&[listed(row(1, "t1"), &[COVER, "https://x/b.jpg"])]);
    fx
}

#[tokio::test]
async fn add_known_topic() {
    let fx = listed_fx(FakeTracker::default());
    let r = fx.post("/api/add/1").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.header("content-type"), "application/json");
    assert_eq!(r.json(), json!({"ok": true, "name": "Release"}));
    assert_eq!(
        *fx.state.torrents.calls.lock().unwrap(),
        vec![(b"d4:infoe".to_vec(), "/vault".to_string())]
    );
    assert_eq!(fx.state.db.added().unwrap(), HashSet::from([1]));
}

#[tokio::test]
async fn add_over_the_limit_is_queued() {
    let mut t = FakeTracker::default();
    t.limit.insert(1);
    let fx = listed_fx(t);
    let r = fx.post("/api/add/1").await;
    assert_eq!(r.status, 200);
    assert_eq!(
        r.json(),
        json!({"ok": true, "queued": true, "message": "daily download limit reached (10/day)"})
    );
    // The wire order is part of the contract.
    assert!(
        r.text()
            .starts_with(r#"{"ok":true,"queued":true,"message":"#)
    );
    assert_eq!(fx.state.db.queued(Section::Video).unwrap(), vec![1]);
    assert!(fx.state.db.added().unwrap().is_empty());
}

#[tokio::test]
async fn add_already_added_topic_skips_fetch() {
    let fx = listed_fx(FakeTracker::default());
    fx.post("/api/add/1").await;
    let r = fx.post("/api/add/1").await;
    assert_eq!(r.json(), json!({"ok": true, "name": "already added"}));
    assert_eq!(*fx.state.tracker.torrents.lock().unwrap(), vec![1]);
}

#[tokio::test]
async fn add_unknown_topic_is_502_with_the_reason() {
    let fx = listed_fx(FakeTracker::default());
    let r = fx.post("/api/add/99").await;
    assert_eq!(r.status, 502);
    assert_eq!(r.header("content-type"), "application/json");
    assert_eq!(
        r.json(),
        json!({"ok": false, "error": "topic 99 is not on the list"})
    );
    assert!(fx.state.tracker.torrents.lock().unwrap().is_empty());
}

#[tokio::test]
async fn unqueue_removes_from_queue_and_is_idempotent() {
    let fx = listed_fx(FakeTracker::default());
    for id in [1, 2] {
        fx.state.db.enqueue(id, Section::Video, now()).unwrap();
    }
    let r = fx.post("/api/unqueue/1").await;
    assert_eq!((r.status, r.json()), (200, json!({"ok": true})));
    assert_eq!(fx.state.db.queued(Section::Video).unwrap(), vec![2]);
    assert_eq!(fx.post("/api/unqueue/1").await.json(), json!({"ok": true}));
    assert_eq!(fx.state.db.queued(Section::Video).unwrap(), vec![2]);
}

// Images and everything else

#[tokio::test]
async fn img_of_a_listed_url_is_fetched_lazily() {
    let fx = listed_fx(FakeTracker::default());
    let r = fx
        .get(&format!("/api/img/{}", key("https://x/b.jpg")))
        .await;
    assert_eq!(r.status, 200);
    assert_eq!(r.header("content-type"), "image/jpeg");
    assert_eq!(r.header("cache-control"), "private, max-age=604800");
    assert_eq!(r.body, JPEG);
    assert_eq!(
        *fx.state.tracker.fetched.lock().unwrap(),
        vec!["https://x/b.jpg".to_string()]
    );
}

#[tokio::test]
async fn img_of_an_unlisted_key_is_404() {
    let fx = listed_fx(FakeTracker::default());
    let r = fx.get(&format!("/api/img/{}", key("https://evil/x"))).await;
    assert_eq!((r.status, r.text().as_str()), (404, "not found"));
}

#[tokio::test]
async fn img_that_is_not_an_image_is_502() {
    let fx = listed_fx(FakeTracker {
        fetch_body: Some(b"<html>".to_vec()),
        ..Default::default()
    });
    let r = fx
        .get(&format!("/api/img/{}", key("https://x/b.jpg")))
        .await;
    assert_eq!((r.status, r.text().as_str()), (502, "image unavailable"));
    assert!(!fx.state.images.path("https://x/b.jpg").exists());
}

// Streaming

use wiremock::matchers::{header as h, method as m, path as p, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

async fn rqbit() -> MockServer {
    let s = MockServer::start().await;
    let files = json!([{"name": "Rel/m.mp4", "components": ["Rel", "m.mp4"],
        "length": 900, "included": true, "attributes": {}}]);
    Mock::given(m("POST"))
        .and(p("/torrents"))
        .and(query_param("list_only", "true"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!(
            {"id": null, "output_folder": "/s", "seen_peers": null,
             "details": {"info_hash": "aa", "name": "Rel", "output_folder": "/s", "files": files}})))
        .mount(&s)
        .await;
    Mock::given(m("POST"))
        .and(p("/torrents"))
        .and(query_param("overwrite", "true"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!(
            {"id": 1, "output_folder": "/s", "seen_peers": null,
             "details": {"info_hash": "aa1", "name": "Rel", "output_folder": "/s", "files": files}})))
        .mount(&s)
        .await;
    Mock::given(m("GET"))
        .and(p("/torrents/aa1/stream/0"))
        .and(h("range", "bytes=0-3"))
        .respond_with(
            ResponseTemplate::new(206)
                .insert_header("content-range", "bytes 0-3/900")
                .set_body_bytes(b"\0\0\0\x18".to_vec()),
        )
        .mount(&s)
        .await;
    s
}

fn streaming(server: &MockServer) -> Fx {
    let uri = server.uri();
    Fx::with(FakeTracker::default(), move |_, st| {
        st.engine = Some(crate::rqbit::Rqbit::new(&uri))
    })
}

#[tokio::test]
async fn an_album_is_never_added_or_streamed() {
    let fx = Fx::new();
    let id = fx
        .state
        .db
        .upsert_external(&crate::db::NewExternal {
            indexer: "Album index A",
            guid: "AbC123",
            link: "https://files.example/a/AbC123",
            info_url: Some("https://files.example/a/AbC123"),
            kind: crate::db::Kind::Album,
            files: Some(3),
            seen: 0,
        })
        .unwrap();
    assert_eq!(fx.post(&format!("/api/add/{id}")).await.status, 400);
    assert_eq!(
        fx.page("POST", &format!("/api/stream/{id}"), None)
            .await
            .status,
        400
    );
}

#[tokio::test]
async fn every_section_has_a_list() {
    let fx = Fx::new();
    for s in ["video", "games", "indexers", "albums"] {
        let r = fx.get(&format!("/api/list?section={s}")).await;
        assert_eq!(r.status, 200, "{s}");
        assert_eq!(r.json()["section"], s);
    }
    assert_eq!(fx.get("/api/list?section=nope").await.status, 400);
}

#[tokio::test]
async fn stream_start_reports_files_and_the_tailnet_url() {
    let s = rqbit().await;
    let fx = streaming(&s);
    let r = fx.page("POST", "/api/stream/5", None).await;
    assert_eq!(r.status, 200, "{}", r.text());
    let j: Value = serde_json::from_slice(&r.body).unwrap();
    assert_eq!(j["ok"], true);
    assert_eq!(j["selected"], 0);
    assert_eq!(j["files"][0]["name"], "Rel/m.mp4");
    assert_eq!(j["external"], "https://plab-stream.example/stream/5/0");
    assert!(fx.state.db.torrent_file(5).unwrap().is_some());
}

#[tokio::test]
async fn a_poll_during_a_pending_start_reports_the_step() {
    let s = rqbit().await;
    // A list that answers slowly keeps the start pending; mounted last, it wins.
    Mock::given(m("POST"))
        .and(p("/torrents"))
        .and(query_param("list_only", "true"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_delay(std::time::Duration::from_millis(800))
                .set_body_json(
                    json!({"id": null, "output_folder": "/s", "seen_peers": null,
                    "details": {"info_hash": "aa", "name": "Rel", "output_folder": "/s",
                    "files": [{"name": "Rel/m.mp4", "components": ["Rel", "m.mp4"],
                        "length": 900, "included": true, "attributes": {}}]}}),
                ),
        )
        .with_priority(1)
        .mount(&s)
        .await;
    let fx = streaming(&s);
    let (started, polled) = tokio::join!(fx.page("POST", "/api/stream/5", None), async {
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        fx.page("GET", "/api/stream/5", None).await
    });
    assert_eq!(started.status, 200, "{}", started.text());
    assert_eq!(polled.status, 200, "{}", polled.text());
    let j: Value = serde_json::from_slice(&polled.body).unwrap();
    assert_eq!(j["ok"], true);
    assert_eq!(j["starting"]["step"], "Reading file list");
    assert!(j["starting"]["since"].as_i64().unwrap() > 0);
    assert!(j.get("stats").is_none());
}

#[tokio::test]
async fn stream_bytes_forward_the_range() {
    let s = rqbit().await;
    let fx = streaming(&s);
    fx.page("POST", "/api/stream/5", None).await;
    let r = fx.page("GET", "/api/stream/5/0", Some("bytes=0-3")).await;
    assert_eq!(r.status, 206);
    assert_eq!(r.header("content-range"), "bytes 0-3/900");
    assert_eq!(r.header("content-type"), "video/mp4");
    assert_eq!(r.body, b"\0\0\0\x18");
}

#[tokio::test]
async fn the_tailnet_listener_only_reads() {
    let s = rqbit().await;
    let fx = streaming(&s);
    fx.page("POST", "/api/stream/5", None).await;
    assert_eq!(fx.tailnet("POST", "/stream/5").await.status, 405);
    assert_eq!(fx.tailnet("DELETE", "/stream/5").await.status, 405);
    assert_eq!(fx.tailnet("GET", "/stream/5").await.status, 404);
    assert_eq!(fx.tailnet("GET", "/").await.status, 404);
    // The rqbit stub only answers the ranged request, as a player sends it.
    let r = fx
        .send_to(
            stream_router(fx.state.clone()),
            "GET",
            "/stream/5/0",
            Some("bytes=0-3"),
            None,
        )
        .await;
    assert_eq!(r.status, 206);
}

#[tokio::test]
async fn the_tailnet_listener_answers_head_like_get() {
    let s = rqbit().await;
    let fx = streaming(&s);
    fx.page("POST", "/api/stream/5", None).await;
    let r = fx
        .send_to(
            stream_router(fx.state.clone()),
            "HEAD",
            "/stream/5/0",
            Some("bytes=0-3"),
            None,
        )
        .await;
    assert_eq!(r.status, 206);
    assert_eq!(r.header("content-range"), "bytes 0-3/900");
    assert_eq!(r.header("content-type"), "video/mp4");
}

#[tokio::test]
async fn the_stats_poll_counts_as_a_read() {
    let s = rqbit().await;
    Mock::given(m("GET"))
        .and(p("/torrents/aa1/stats/v1"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({
            "state": "live", "error": null, "progress_bytes": 0, "total_bytes": 900, "finished": false, "live": null
        })))
        .mount(&s)
        .await;
    let fx = streaming(&s);
    // Started (and last read) at the epoch: idle for decades unless the poll counts.
    let engine = fx.state.engine.clone().unwrap();
    fx.state
        .streams
        .start(&*fx.state.tracker, None, &fx.state.db, &engine, 5, 0)
        .await
        .unwrap();
    assert_eq!(fx.page("GET", "/api/stream/5", None).await.status, 200);
    assert!(fx.state.streams.reap(now()).is_empty());
    assert_eq!(
        fx.state
            .streams
            .reap(now() + crate::stream::IDLE_SECS + 5)
            .len(),
        1
    );
}

#[tokio::test]
async fn stream_limit_is_429_and_not_queued() {
    let s = rqbit().await;
    let uri = s.uri();
    let mut t = FakeTracker::default();
    t.limit.insert(5);
    let fx = Fx::with(t, move |_, st| {
        st.engine = Some(crate::rqbit::Rqbit::new(&uri))
    });
    let r = fx.page("POST", "/api/stream/5", None).await;
    assert_eq!(r.status, 429);
    assert!(r.text().contains("daily download limit"));
    assert!(fx.state.db.queued(Section::Video).unwrap().is_empty());
}

#[tokio::test]
async fn stream_without_an_engine_is_502() {
    let fx = Fx::new();
    assert_eq!(fx.page("POST", "/api/stream/5", None).await.status, 502);
}

#[tokio::test]
async fn stream_unknown_topic_is_404_and_stop_deletes() {
    let s = rqbit().await;
    Mock::given(m("POST"))
        .and(p("/torrents/aa1/delete"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
        .expect(1)
        .mount(&s)
        .await;
    let fx = streaming(&s);
    assert_eq!(fx.page("GET", "/api/stream/9", None).await.status, 404);
    fx.page("POST", "/api/stream/5", None).await;
    assert_eq!(fx.page("DELETE", "/api/stream/5", None).await.status, 200);
    assert_eq!(fx.page("GET", "/api/stream/5", None).await.status, 404);
}

// Assistant

async fn assistant_fx(server: &wiremock::MockServer) -> Fx {
    assistant_fx_with(server, "x").await
}

async fn assistant_fx_with(server: &wiremock::MockServer, prompt: &str) -> Fx {
    use wiremock::{Mock, ResponseTemplate, matchers::path};
    Mock::given(path("/graphql"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"data": {"findScenes": {"scenes": [
            {"id": "4", "title": "Alpha", "performers": [{"id": "p", "name": "Performer B"}],
             "paths": {"screenshot": "http://localhost:9999/scene/4/screenshot?t=1"}}
        ]}}})))
        .mount(server)
        .await;
    let uri = server.uri();
    let prompt = prompt.to_string();
    Fx::with(FakeTracker::default(), move |_, st| {
        let llm = crate::llm::OpenRouter::new(&uri, "k".into(), "p".into(), "j".into());
        let stash = crate::stash::Stash::new(&format!("{uri}/graphql"), None);
        st.assistant = Some(Arc::new(crate::assistant::Assistant::new(
            llm,
            stash,
            "m".into(),
            prompt,
        )));
        st.stash_web_url = Some("https://stash.example".into());
    })
}

fn answer(picks: Value) -> wiremock::ResponseTemplate {
    wiremock::ResponseTemplate::new(200).set_body_json(json!({"choices": [{"message": {
        "role": "assistant", "content": json!({"text": "Here.", "picks": picks}).to_string()
    }}]}))
}

#[tokio::test]
async fn assistant_off_without_a_key() {
    let fx = Fx::new();
    let r = fx.post("/api/assistant/recommend").await;
    assert_eq!(r.status, 503);
    assert!(r.text().contains("OpenRouter"));
}

#[tokio::test]
async fn recommend_resolves_picks_and_drops_unknown_refs() {
    let server = wiremock::MockServer::start().await;
    wiremock::Mock::given(wiremock::matchers::path(crate::llm::CHAT_PATH))
        .respond_with(answer(json!([
            {"ref": "t:5", "action": "download", "reason": "same studio"},
            {"ref": "s:4", "action": "watch", "reason": "same performer"},
            {"ref": "t:999", "action": "stream", "reason": "gone"},
            {"ref": "s:4", "action": "download", "reason": "wrong action for a scene"}
        ])))
        .mount(&server)
        .await;
    let fx = assistant_fx(&server).await;
    fx.save_video(&[listed(row(5, "Alpha One"), &[COVER])]);
    let r = fx.post("/api/assistant/recommend").await;
    assert_eq!(r.status, 200, "{}", r.text());
    let j = r.json();
    let turn = j["turns"].as_array().unwrap().last().unwrap().clone();
    assert_eq!(turn["role"], "assistant");
    assert_eq!(turn["text"], "Here.");
    let refs: Vec<&str> = turn["picks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|p| p["ref"].as_str().unwrap())
        .collect();
    assert_eq!(refs, vec!["t:5", "s:4"]);
    assert_eq!(j["topics"][0]["id"], 5);
    assert_eq!(j["topics"][0]["section"], "video");
    assert_eq!(j["scenesUnavailable"], false);
    assert_eq!(j["scenes"][0]["link"], "https://stash.example/scenes/4");
    assert_eq!(
        j["scenes"][0]["screenshot"],
        "https://stash.example/scene/4/screenshot?t=1"
    );
    // The user's turn is the canned ask; system and tool messages are not shown.
    assert_eq!(j["turns"].as_array().unwrap().len(), 2);
    let list = fx.get("/api/assistant/conversations").await.json();
    assert_eq!(list[0]["kind"], "recommend");
}

#[tokio::test]
async fn the_conversation_list_says_why_the_assistant_is_not_ready() {
    let server = wiremock::MockServer::start().await;
    let fx = assistant_fx_with(&server, "  ").await;
    let r = fx.get("/api/assistant/conversations").await;
    assert_eq!(r.status, 503);
    assert!(r.text().contains("prompt"), "{}", r.text());
}

#[tokio::test]
async fn picks_off_the_advised_lists_are_dropped() {
    let server = wiremock::MockServer::start().await;
    wiremock::Mock::given(wiremock::matchers::path(crate::llm::CHAT_PATH))
        .respond_with(answer(json!([
            {"ref": "t:5", "action": "download", "reason": "a game"},
            {"ref": "t:6", "action": "download", "reason": "an indexer release"}
        ])))
        .mount(&server)
        .await;
    let fx = assistant_fx(&server).await;
    let db = &fx.state.db;
    db.save_listing(Section::Games, &[listed(row(5, "Alpha One"), &[COVER])], &[], now())
        .unwrap();
    db.save_listing(Section::Indexers, &[listed(row(6, "Alpha Two"), &[COVER])], &[], now())
        .unwrap();
    let j = fx.post("/api/assistant/recommend").await.json();
    let topics = j["topics"].as_array().unwrap();
    assert_eq!(topics.len(), 1);
    assert_eq!((topics[0]["id"].as_u64(), topics[0]["section"].as_str()), (Some(6), Some("indexers")));
    let picks = j["turns"][1]["picks"].as_array().unwrap();
    assert_eq!(picks.len(), 1);
    assert_eq!(picks[0]["ref"], "t:6");
}

#[tokio::test]
async fn chat_messages_get_and_delete() {
    let server = wiremock::MockServer::start().await;
    wiremock::Mock::given(wiremock::matchers::path(crate::llm::CHAT_PATH))
        .respond_with(answer(json!([])))
        .mount(&server)
        .await;
    let fx = assistant_fx(&server).await;
    let r = fx
        .post_json("/api/assistant/conversations", json!({"text": "something short"}))
        .await;
    assert_eq!(r.status, 200, "{}", r.text());
    let id = r.json()["id"].as_i64().unwrap();
    assert_eq!(r.json()["title"], "something short");
    let r = fx
        .post_json(
            &format!("/api/assistant/conversations/{id}/messages"),
            json!({"text": "more"}),
        )
        .await;
    assert_eq!(r.json()["turns"].as_array().unwrap().len(), 4);
    assert_eq!(
        fx.get(&format!("/api/assistant/conversations/{id}"))
            .await
            .status,
        200
    );
    assert_eq!(
        fx.request("DELETE", &format!("/api/assistant/conversations/{id}"))
            .await
            .status,
        204
    );
    assert_eq!(
        fx.get(&format!("/api/assistant/conversations/{id}"))
            .await
            .status,
        404
    );
}

#[tokio::test]
async fn assistant_rejects_bad_bodies_and_busy_conversations() {
    let server = wiremock::MockServer::start().await;
    let fx = assistant_fx(&server).await;
    let big = vec![b'a'; 16 * 1024 + 1];
    assert_eq!(
        fx.send_body("POST", "/api/assistant/conversations", big)
            .await
            .status,
        413
    );
    assert_eq!(
        fx.post_json("/api/assistant/conversations", json!({"text": "  "}))
            .await
            .status,
        400
    );
    assert_eq!(
        fx.send_body("POST", "/api/assistant/conversations", b"{".to_vec())
            .await
            .status,
        400
    );
    let id = fx.state.db.create_conversation("t", "chat", 0).unwrap();
    let a = fx.state.assistant.clone().unwrap();
    let _g = a.lock(id).unwrap();
    let r = fx
        .post_json(
            &format!("/api/assistant/conversations/{id}/messages"),
            json!({"text": "x"}),
        )
        .await;
    assert_eq!(r.status, 409);
    let r = fx
        .request("DELETE", &format!("/api/assistant/conversations/{id}"))
        .await;
    assert_eq!(r.status, 409);
}
