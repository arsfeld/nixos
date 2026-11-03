//! Streams: one release's file played from the swarm through rqbit, kept only while it is
//! being read. The table lives in memory; plab-stream.service is PartOf plab.service, so a
//! restart of either empties both.

use std::collections::HashMap;
use std::sync::Mutex;

use serde::Serialize;
use tracing::warn;

use crate::db::Db;
use crate::prowlarr::Prowlarr;
use crate::rqbit::{AlreadyManaged, EngineFile, EngineStats, Gone, Rqbit, Upstream};
use crate::tracker::{TrackerApi, TrackerError};
use crate::transmission::TorrentSource;

pub const MAX_STREAMS: usize = 2;
/// A stream unread this long is deleted with its data.
pub const IDLE_SECS: i64 = 1800;
const VIDEO: [&str; 8] = ["mp4", "mkv", "avi", "wmv", "mov", "m4v", "ts", "webm"];

#[derive(Debug, thiserror::Error)]
pub enum StreamError {
    #[error("{0}")]
    Limit(String),
    #[error("no video file in this release")]
    NoVideo,
    #[error("no such file in this release")]
    BadFile,
    #[error("not streaming")]
    Unknown,
    #[error("the stream engine lost this stream; start it again")]
    Gone,
    #[error("no peers for metadata")]
    NoMetadata,
    #[error("stream engine down: {0}")]
    Engine(String),
    #[error("{0}")]
    Tracker(String),
}

impl StreamError {
    pub fn status(&self) -> u16 {
        match self {
            StreamError::Limit(_) => 429,
            StreamError::NoVideo | StreamError::BadFile => 400,
            StreamError::Unknown => 404,
            StreamError::Gone => 410,
            // 502, not 503: the gateway replaces 500/503 bodies with its HTML error page.
            StreamError::NoMetadata => 502,
            StreamError::Engine(_) => 502,
            StreamError::Tracker(_) => 502,
        }
    }
}

fn engine_err(e: anyhow::Error) -> StreamError {
    if e.downcast_ref::<Gone>().is_some() {
        StreamError::Gone
    } else if e.downcast_ref::<crate::rqbit::NoMetadata>().is_some() {
        StreamError::NoMetadata
    } else {
        StreamError::Engine(format!("{e:#}"))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StreamInfo {
    pub topic: u64,
    pub files: Vec<EngineFile>,
    pub selected: usize,
}

struct Entry {
    /// The torrent's info hash, which is how rqbit is asked about it: its numeric ids
    /// restart from 1 with rqbit, so one can come to name another topic's torrent.
    engine_id: String,
    files: Vec<EngineFile>,
    selected: usize,
    last_read: i64,
}

/// What a start in progress is doing, for the page's poll while its POST is pending.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Starting {
    pub step: &'static str,
    /// Unix seconds the start began.
    pub since: i64,
}

/// A topic's state for the poll: still starting, or live in the engine.
#[derive(Debug)]
pub enum StreamStatus {
    Starting(Starting),
    Live(EngineStats),
}

/// Removes its topic's `Starting` entry when the start ends, however it ends.
pub struct StartGuard<'a> {
    streams: &'a Streams,
    topic: u64,
}

impl StartGuard<'_> {
    pub fn step(&self, step: &'static str) {
        if let Some(s) = self.streams.progress().get_mut(&self.topic) {
            s.step = step;
        }
    }
}

impl Drop for StartGuard<'_> {
    fn drop(&mut self) {
        self.streams.progress().remove(&self.topic);
    }
}

#[derive(Default)]
pub struct Streams {
    table: Mutex<HashMap<u64, Entry>>,
    /// Starts in progress, by topic. Never held across an await.
    progress: Mutex<HashMap<u64, Starting>>,
    /// Starts one at a time, so a double click never adds a torrent twice.
    starting: tokio::sync::Mutex<()>,
    /// Info hashes whose delete failed; `reap_and_delete` (or a 409 on add) retries them.
    orphans: Mutex<Vec<String>>,
}

fn extension(name: &str) -> String {
    name.rsplit_once('.')
        .map_or(String::new(), |(_, e)| e.to_ascii_lowercase())
}

pub fn default_file(files: &[EngineFile]) -> Option<usize> {
    files
        .iter()
        .filter(|f| VIDEO.contains(&extension(&f.name).as_str()))
        .max_by_key(|f| f.length)
        .map(|f| f.index)
}

pub fn content_type(name: &str) -> &'static str {
    match extension(name).as_str() {
        "mp4" | "m4v" => "video/mp4",
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        "avi" => "video/x-msvideo",
        "wmv" => "video/x-ms-wmv",
        "mov" => "video/quicktime",
        "ts" => "video/mp2t",
        _ => "application/octet-stream",
    }
}

/// The topic's `.torrent`: the stored copy, or one grab from the tracker, stored before it
/// is returned so the grab is never spent twice.
pub async fn torrent_bytes<T: TrackerApi>(
    tracker: &T,
    db: &Db,
    topic: u64,
    now: i64,
) -> Result<Vec<u8>, StreamError> {
    let internal = |e: anyhow::Error| StreamError::Tracker(format!("{e:#}"));
    if let Some(bytes) = db.torrent_file(topic).map_err(internal)? {
        return Ok(bytes);
    }
    let bytes = tracker.torrent(topic).await.map_err(|e| match e {
        TrackerError::Limit(_) => StreamError::Limit(e.to_string()),
        e => StreamError::Tracker(e.to_string()),
    })?;
    db.store_torrent_file(topic, &bytes, now)
        .map_err(internal)?;
    Ok(bytes)
}

impl Streams {
    fn table(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Entry>> {
        self.table.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn progress(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Starting>> {
        self.progress.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Record a start of `topic` in progress. A second start of the same topic, waiting
    /// behind the first, keeps the first's entry.
    fn begin(&self, topic: u64, now: i64) -> StartGuard<'_> {
        self.progress().entry(topic).or_insert(Starting {
            step: "Waiting for another start",
            since: now,
        });
        StartGuard {
            streams: self,
            topic,
        }
    }

    fn status(&self, topic: u64) -> Option<Starting> {
        self.progress().get(&topic).cloned()
    }

    fn info(&self, topic: u64) -> Option<StreamInfo> {
        self.table().get(&topic).map(|e| StreamInfo {
            topic,
            files: e.files.clone(),
            selected: e.selected,
        })
    }

    fn engine_id(&self, topic: u64) -> Result<String, StreamError> {
        self.table()
            .get(&topic)
            .map(|e| e.engine_id.clone())
            .ok_or(StreamError::Unknown)
    }

    /// Drop a topic whose torrent rqbit no longer has, and say so.
    /// Only if the entry still holds the id the failed call used: a topic stopped and
    /// started again meanwhile has a new torrent that must survive.
    fn forget_if_gone(&self, topic: u64, engine_id: &str, e: StreamError) -> StreamError {
        if matches!(e, StreamError::Gone) {
            let mut table = self.table();
            if table.get(&topic).is_some_and(|x| x.engine_id == engine_id) {
                table.remove(&topic);
            }
        }
        e
    }

    fn orphans(&self) -> std::sync::MutexGuard<'_, Vec<String>> {
        self.orphans.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Delete a torrent from rqbit; a failure queues the hash for `reap_and_delete`.
    async fn delete_or_queue(&self, engine: &Rqbit, id: String) -> anyhow::Result<()> {
        let r = engine.delete(&id).await;
        if r.is_err() {
            self.orphans().push(id);
        }
        r
    }

    /// Retry every queued delete now; failures go back on the queue.
    async fn delete_orphans(&self, engine: &Rqbit) {
        let ids = std::mem::take(&mut *self.orphans());
        for id in ids {
            if let Err(e) = self.delete_or_queue(engine, id.clone()).await {
                warn!(job = "stream", "deleting rqbit torrent {id}: {e:#}");
            }
        }
    }

    /// Add, and on a 409 (rqbit still has this hash: a stop or eviction whose delete
    /// failed and is queued) delete the queued hashes and add once more.
    async fn add(
        &self,
        engine: &Rqbit,
        torrent: &TorrentSource,
        file: usize,
    ) -> anyhow::Result<String> {
        match engine.add(torrent, file).await {
            Err(e) if e.downcast_ref::<AlreadyManaged>().is_some() => {
                self.delete_orphans(engine).await;
                engine.add(torrent, file).await
            }
            r => r,
        }
    }

    pub async fn start<T: TrackerApi>(
        &self,
        tracker: &T,
        prowlarr: Option<&Prowlarr>,
        db: &Db,
        engine: &Rqbit,
        topic: u64,
        now: i64,
    ) -> Result<StreamInfo, StreamError> {
        let progress = self.begin(topic, now);
        let _one = self.starting.lock().await;
        if let Some(info) = self.info(topic) {
            self.touch(topic, now);
            return Ok(info);
        }
        let source = if crate::db::is_external(topic) {
            progress.step("Fetching torrent from indexer");
            crate::plab::external_torrent(prowlarr, db, topic, now)
                .await
                .map_err(|e| StreamError::Tracker(format!("{e:#}")))?
        } else {
            let stored = db
                .torrent_file(topic)
                .map_err(|e| StreamError::Tracker(format!("{e:#}")))?;
            TorrentSource::Bytes(match stored {
                Some(bytes) => {
                    progress.step("Using stored torrent");
                    bytes
                }
                None => {
                    progress.step("Fetching torrent from tracker");
                    torrent_bytes(tracker, db, topic, now).await?
                }
            })
        };
        progress.step(if matches!(source, TorrentSource::Magnet(_)) {
            "Resolving magnet"
        } else {
            "Reading file list"
        });
        let files = engine.list(&source).await.map_err(engine_err)?;
        let selected = default_file(&files).ok_or(StreamError::NoVideo)?;
        progress.step("Adding to engine");
        let engine_id = self
            .add(engine, &source, selected)
            .await
            .map_err(engine_err)?;
        let evicted = {
            let mut table = self.table();
            table.insert(
                topic,
                Entry {
                    engine_id,
                    files: files.clone(),
                    selected,
                    last_read: now,
                },
            );
            Self::evict(&mut table, topic)
        };
        for id in evicted {
            if let Err(e) = self.delete_or_queue(engine, id.clone()).await {
                warn!(job = "stream", "evicting rqbit torrent {id}: {e:#}");
            }
        }
        Ok(StreamInfo {
            topic,
            files,
            selected,
        })
    }

    /// Remove least-recently-read entries, never `keep`, until the table fits; their hashes.
    fn evict(table: &mut HashMap<u64, Entry>, keep: u64) -> Vec<String> {
        let mut evicted = vec![];
        while table.len() > MAX_STREAMS {
            let Some(topic) = table
                .iter()
                .filter(|(t, _)| **t != keep)
                .min_by_key(|(_, e)| e.last_read)
                .map(|(&t, _)| t)
            else {
                break;
            };
            evicted.extend(table.remove(&topic).map(|e| e.engine_id));
        }
        evicted
    }

    pub async fn select(
        &self,
        engine: &Rqbit,
        topic: u64,
        file: usize,
        now: i64,
    ) -> Result<StreamInfo, StreamError> {
        let id = self.engine_id(topic)?;
        let known = self
            .table()
            .get(&topic)
            .is_some_and(|e| file < e.files.len());
        if !known {
            return Err(StreamError::BadFile);
        }
        engine
            .select(&id, file)
            .await
            .map_err(|e| self.forget_if_gone(topic, &id, engine_err(e)))?;
        if let Some(e) = self.table().get_mut(&topic) {
            e.selected = file;
            e.last_read = e.last_read.max(now);
        }
        self.info(topic).ok_or(StreamError::Unknown)
    }

    /// The page's poll. It counts as a read: a paused player with the modal open reads no
    /// bytes, and must not be reaped from under the person watching it.
    pub async fn stats(
        &self,
        engine: &Rqbit,
        topic: u64,
        now: i64,
    ) -> Result<StreamStatus, StreamError> {
        let id = match self.engine_id(topic) {
            Ok(id) => id,
            Err(e) => return self.status(topic).map(StreamStatus::Starting).ok_or(e),
        };
        self.touch(topic, now);
        engine
            .stats(&id)
            .await
            .map(StreamStatus::Live)
            .map_err(|e| self.forget_if_gone(topic, &id, engine_err(e)))
    }

    pub async fn open(
        &self,
        engine: &Rqbit,
        topic: u64,
        file: usize,
        range: Option<&str>,
        now: i64,
    ) -> Result<(Upstream, String), StreamError> {
        let (id, name) = {
            let table = self.table();
            let e = table.get(&topic).ok_or(StreamError::Unknown)?;
            if file != e.selected {
                return Err(StreamError::BadFile);
            }
            (e.engine_id.clone(), e.files[file].name.clone())
        };
        self.touch(topic, now);
        let up = engine
            .open(&id, file, range)
            .await
            .map_err(|e| self.forget_if_gone(topic, &id, engine_err(e)))?;
        Ok((up, name))
    }

    pub async fn stop(&self, engine: &Rqbit, topic: u64) -> Result<(), StreamError> {
        let id = self
            .table()
            .remove(&topic)
            .map(|e| e.engine_id)
            .ok_or(StreamError::Unknown)?;
        self.delete_or_queue(engine, id).await.map_err(engine_err)
    }

    pub fn touch(&self, topic: u64, now: i64) {
        if let Some(e) = self.table().get_mut(&topic) {
            e.last_read = e.last_read.max(now);
        }
    }

    /// The minute task: delete idle streams and retry every earlier failed delete.
    pub async fn reap_and_delete(&self, engine: &Rqbit, now: i64) {
        let ids = self.reap(now);
        self.orphans().extend(ids);
        self.delete_orphans(engine).await;
    }

    pub fn reap(&self, now: i64) -> Vec<String> {
        let mut table = self.table();
        let idle: Vec<u64> = table
            .iter()
            .filter(|(_, e)| now - e.last_read > IDLE_SECS)
            .map(|(&t, _)| t)
            .collect();
        idle.iter()
            .filter_map(|t| table.remove(t))
            .map(|e| e.engine_id)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tracker::parse::Row;
    use serde_json::json;
    use std::sync::Mutex;
    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[derive(Default)]
    struct Tracker {
        limit: bool,
        calls: Mutex<u32>,
        /// When set, `torrent` waits for a notification before answering.
        gate: Option<std::sync::Arc<tokio::sync::Notify>>,
    }

    impl TrackerApi for Tracker {
        async fn top(
            &self,
            _: &[u32],
            _: u32,
            _: usize,
            _: &[fancy_regex::Regex],
        ) -> Result<Vec<Row>, TrackerError> {
            Ok(vec![])
        }
        async fn search(
            &self,
            _: &str,
            _: &[u32],
            _: Option<u32>,
            _: usize,
            _: &[fancy_regex::Regex],
            _: Option<usize>,
        ) -> Result<Vec<Row>, TrackerError> {
            Ok(vec![])
        }
        async fn topic(&self, _: u64) -> Result<String, TrackerError> {
            Ok(String::new())
        }
        async fn torrent(&self, _: u64) -> Result<Vec<u8>, TrackerError> {
            *self.calls.lock().unwrap() += 1;
            if let Some(g) = &self.gate {
                g.notified().await;
            }
            if self.limit {
                Err(TrackerError::Limit(10))
            } else {
                Ok(b"d4:infoe".to_vec())
            }
        }
        async fn fetch(&self, _: &str) -> Result<Vec<u8>, TrackerError> {
            Ok(vec![])
        }
    }

    fn file(index: usize, name: &str, length: u64) -> EngineFile {
        EngineFile {
            index,
            name: name.into(),
            length,
        }
    }

    fn files_json(files: &[(&str, u64)]) -> serde_json::Value {
        let files: Vec<_> = files
            .iter()
            .map(|(n, l)| {
                json!({"name": n, "components": [n],
            "length": l, "included": true, "attributes": {}})
            })
            .collect();
        json!({"id": null, "output_folder": "/s", "seen_peers": null,
            "details": {"info_hash": "aa", "name": "Rel", "output_folder": "/s", "files": files}})
    }

    /// An rqbit that lists `files` and hands out info hashes aa1, aa2, aa3… in add order.
    async fn engine(files: &[(&str, u64)]) -> (MockServer, Rqbit) {
        engine_with(files, 5, false, false).await
    }

    /// `engine` with only `adds` adds succeeding (then 500s if `fail_after`), and the first
    /// delete of torrent aa2 failing if `flaky_delete`.
    async fn engine_with(
        files: &[(&str, u64)],
        adds: usize,
        fail_after: bool,
        flaky_delete: bool,
    ) -> (MockServer, Rqbit) {
        let s = MockServer::start().await;
        if flaky_delete {
            Mock::given(method("POST"))
                .and(path("/torrents/aa2/delete"))
                .respond_with(ResponseTemplate::new(500))
                .up_to_n_times(1)
                .mount(&s)
                .await;
        }
        Mock::given(method("POST"))
            .and(path("/torrents"))
            .and(query_param("list_only", "true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(files_json(files)))
            .mount(&s)
            .await;
        for id in 1..=adds {
            let mut reply = files_json(files);
            reply["id"] = json!(id);
            reply["details"]["info_hash"] = json!(format!("aa{id}"));
            Mock::given(method("POST"))
                .and(path("/torrents"))
                .and(query_param("overwrite", "true"))
                .respond_with(ResponseTemplate::new(200).set_body_json(reply))
                .up_to_n_times(1)
                .mount(&s)
                .await;
        }
        if fail_after {
            Mock::given(method("POST"))
                .and(query_param("overwrite", "true"))
                .respond_with(ResponseTemplate::new(500))
                .mount(&s)
                .await;
        }
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
            .mount(&s)
            .await;
        let r = Rqbit::new(&s.uri());
        (s, r)
    }

    async fn deleted(s: &MockServer) -> Vec<String> {
        s.received_requests()
            .await
            .unwrap()
            .iter()
            .map(|r| r.url.path().to_string())
            .filter(|p| p.ends_with("/delete"))
            .collect()
    }

    #[test]
    fn default_file_is_the_largest_video() {
        let files = [
            file(0, "a/cover.jpg", 9_000),
            file(1, "a/s.MP4", 10),
            file(2, "a/m.mkv", 900),
        ];
        assert_eq!(default_file(&files), Some(2));
        assert_eq!(default_file(&[file(0, "x.nfo", 1)]), None);
    }

    #[test]
    fn content_types() {
        assert_eq!(content_type("a/b.MP4"), "video/mp4");
        assert_eq!(content_type("b.mkv"), "video/x-matroska");
        assert_eq!(content_type("b.bin"), "application/octet-stream");
    }

    #[tokio::test]
    async fn a_stored_torrent_needs_no_tracker_call() {
        let db = Db::open_in_memory().unwrap();
        db.store_torrent_file(5, b"stored", 1).unwrap();
        let t = Tracker::default();
        assert_eq!(torrent_bytes(&t, &db, 5, 2).await.unwrap(), b"stored");
        assert_eq!(*t.calls.lock().unwrap(), 0);
    }

    #[tokio::test]
    async fn a_miss_fetches_once_and_stores() {
        let db = Db::open_in_memory().unwrap();
        let t = Tracker::default();
        torrent_bytes(&t, &db, 5, 2).await.unwrap();
        torrent_bytes(&t, &db, 5, 3).await.unwrap();
        assert_eq!(*t.calls.lock().unwrap(), 1);
        assert_eq!(db.torrent_file(5).unwrap().unwrap(), b"d4:infoe");
    }

    #[tokio::test]
    async fn the_limit_is_429_and_queues_nothing() {
        let db = Db::open_in_memory().unwrap();
        let t = Tracker {
            limit: true,
            ..Default::default()
        };
        let e = torrent_bytes(&t, &db, 5, 2).await.unwrap_err();
        assert_eq!(e.status(), 429);
        assert!(db.queued(crate::db::Section::Video).unwrap().is_empty());
    }

    #[tokio::test]
    async fn the_torrent_is_kept_when_the_engine_fails() {
        let db = Db::open_in_memory().unwrap();
        let s = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&s)
            .await;
        let e = Streams::default()
            .start(&Tracker::default(), None, &db, &Rqbit::new(&s.uri()), 5, 1)
            .await
            .unwrap_err();
        assert_eq!(e.status(), 502);
        assert!(db.torrent_file(5).unwrap().is_some());
    }

    #[tokio::test]
    async fn an_external_release_streams_from_its_magnet() {
        let db = Db::open_in_memory().unwrap();
        let magnet = "magnet:?xt=urn:btih:00";
        let indexer = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/dl/1"))
            .respond_with(ResponseTemplate::new(302).insert_header("Location", magnet))
            .mount(&indexer)
            .await;
        let link = format!("{}/dl/1", indexer.uri());
        let id = db
            .upsert_external(&crate::db::NewExternal {
                indexer: "Indexer A",
                guid: "1",
                link: &link,
                info_url: None,
            })
            .unwrap();
        let (s, r) = engine(&[("m.mkv", 900)]).await;
        let p = Prowlarr::new(&indexer.uri(), "k".into());
        let t = Tracker::default();
        let info = Streams::default()
            .start(&t, Some(&p), &db, &r, id, 1)
            .await
            .unwrap();
        assert_eq!(info.selected, 0);
        assert_eq!(*t.calls.lock().unwrap(), 0, "the tracker is never asked");
        let bodies: Vec<_> = s
            .received_requests()
            .await
            .unwrap()
            .into_iter()
            .filter(|q| q.url.path() == "/torrents")
            .map(|q| q.body)
            .collect();
        assert_eq!(bodies.len(), 2, "a list and an add");
        assert!(bodies.iter().all(|b| b == magnet.as_bytes()));
    }

    #[test]
    fn no_metadata_is_its_own_502() {
        let e = engine_err(crate::rqbit::NoMetadata.into());
        assert!(matches!(e, StreamError::NoMetadata), "{e:?}");
        assert_eq!(e.status(), 502);
    }

    #[tokio::test]
    async fn start_picks_the_largest_video_and_is_idempotent() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("s.mp4", 10), ("m.mkv", 900)]).await;
        let st = Streams::default();
        let a = st
            .start(&Tracker::default(), None, &db, &r, 5, 1)
            .await
            .unwrap();
        let b = st
            .start(&Tracker::default(), None, &db, &r, 5, 2)
            .await
            .unwrap();
        assert_eq!(a.selected, 1);
        assert_eq!(a, b);
        let adds = s
            .received_requests()
            .await
            .unwrap()
            .iter()
            .filter(|q| q.url.query().is_some_and(|q| q.contains("overwrite")))
            .count();
        assert_eq!(adds, 1);
    }

    #[tokio::test]
    async fn no_video_is_refused_before_adding() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("readme.nfo", 10)]).await;
        let e = Streams::default()
            .start(&Tracker::default(), None, &db, &r, 5, 1)
            .await
            .unwrap_err();
        assert_eq!(e.status(), 400);
        let adds = s
            .received_requests()
            .await
            .unwrap()
            .iter()
            .filter(|q| q.url.query().is_some_and(|q| q.contains("overwrite")))
            .count();
        assert_eq!(adds, 0);
    }

    fn live_stats_stub(s: &MockServer, id: &str) -> impl std::future::Future<Output = ()> {
        let m = Mock::given(method("GET"))
            .and(path(format!("/torrents/{id}/stats/v1")))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "state": "live", "error": null,
                "progress_bytes": 0, "total_bytes": 9, "finished": false, "live": null
            })));
        m.mount(s)
    }

    #[tokio::test]
    async fn a_slow_tracker_fetch_is_reported_as_the_step() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("m.mp4", 9)]).await;
        live_stats_stub(&s, "aa1").await;
        let gate = std::sync::Arc::new(tokio::sync::Notify::new());
        let t = Tracker {
            gate: Some(gate.clone()),
            ..Default::default()
        };
        let st = Streams::default();
        let watch = async {
            let seen = loop {
                if let Ok(StreamStatus::Starting(s)) = st.stats(&r, 5, 100).await
                    && s.step == "Fetching torrent from tracker"
                {
                    break s;
                }
                tokio::task::yield_now().await;
            };
            gate.notify_one();
            seen
        };
        let (started, seen) = tokio::time::timeout(std::time::Duration::from_secs(10), async {
            tokio::join!(st.start(&t, None, &db, &r, 5, 100), watch)
        })
        .await
        .unwrap();
        started.unwrap();
        assert_eq!(seen.since, 100);
        assert!(matches!(
            st.stats(&r, 5, 101).await.unwrap(),
            StreamStatus::Live(_)
        ));
    }

    #[test]
    fn the_starting_guard_clears_its_step_on_drop() {
        let st = Streams::default();
        let g = st.begin(5, 7);
        g.step("Reading file list");
        assert_eq!(
            st.status(5),
            Some(Starting {
                step: "Reading file list",
                since: 7
            })
        );
        drop(g);
        assert_eq!(st.status(5), None);
    }

    #[tokio::test]
    async fn a_failed_start_leaves_no_starting_entry() {
        let db = Db::open_in_memory().unwrap();
        let (_s, r) = engine(&[("m.mp4", 9)]).await;
        let t = Tracker {
            limit: true,
            ..Default::default()
        };
        let st = Streams::default();
        assert_eq!(
            st.start(&t, None, &db, &r, 5, 1)
                .await
                .unwrap_err()
                .status(),
            429
        );
        assert_eq!(st.stats(&r, 5, 2).await.err().unwrap().status(), 404);
        assert_eq!(st.status(5), None);
    }

    #[tokio::test]
    async fn a_third_stream_evicts_the_least_recently_read() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("m.mp4", 9)]).await;
        let st = Streams::default();
        let t = Tracker::default();
        st.start(&t, None, &db, &r, 1, 100).await.unwrap(); // aa1
        st.start(&t, None, &db, &r, 2, 100).await.unwrap(); // aa2
        st.touch(1, 150); // topic 2 is now the least recently read
        st.start(&t, None, &db, &r, 3, 200).await.unwrap();
        assert_eq!(deleted(&s).await, vec!["/torrents/aa2/delete"]);
        assert_eq!(st.stats(&r, 2, 200).await.unwrap_err().status(), 404);
    }

    #[tokio::test]
    async fn a_failed_add_leaves_a_full_table_and_rqbit_untouched() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine_with(&[("m.mp4", 9)], 2, true, false).await;
        let st = Streams::default();
        let t = Tracker::default();
        st.start(&t, None, &db, &r, 1, 100).await.unwrap();
        st.start(&t, None, &db, &r, 2, 100).await.unwrap();
        let e = st.start(&t, None, &db, &r, 3, 200).await.unwrap_err();
        assert_eq!(e.status(), 502);
        assert!(st.info(1).is_some() && st.info(2).is_some() && st.info(3).is_none());
        assert!(deleted(&s).await.is_empty());
    }

    #[tokio::test]
    async fn a_failed_eviction_delete_is_retried_by_the_reaper() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine_with(&[("m.mp4", 9)], 5, false, true).await;
        let st = Streams::default();
        let t = Tracker::default();
        st.start(&t, None, &db, &r, 1, 100).await.unwrap();
        st.start(&t, None, &db, &r, 2, 100).await.unwrap();
        st.touch(1, 150);
        st.start(&t, None, &db, &r, 3, 200).await.unwrap();
        assert!(st.info(2).is_none() && st.info(1).is_some() && st.info(3).is_some());
        assert_eq!(*st.orphans(), vec!["aa2".to_string()]);
        st.reap_and_delete(&r, 200).await;
        assert!(st.orphans().is_empty());
        assert_eq!(
            deleted(&s).await,
            vec!["/torrents/aa2/delete", "/torrents/aa2/delete"]
        );
        st.reap_and_delete(&r, 200).await;
        assert_eq!(deleted(&s).await.len(), 2);
    }

    #[tokio::test]
    async fn concurrent_starts_of_one_topic_add_once() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("m.mp4", 9)]).await;
        let st = Streams::default();
        let t = Tracker::default();
        let (a, b) = tokio::join!(
            st.start(&t, None, &db, &r, 5, 1),
            st.start(&t, None, &db, &r, 5, 1)
        );
        assert_eq!(a.unwrap(), b.unwrap());
        let adds = s
            .received_requests()
            .await
            .unwrap()
            .iter()
            .filter(|q| q.url.query().is_some_and(|q| q.contains("overwrite")))
            .count();
        assert_eq!(adds, 1);
    }

    #[tokio::test]
    async fn a_stale_gone_keeps_a_restarted_topics_entry() {
        let db = Db::open_in_memory().unwrap();
        let (_s, r) = engine(&[("m.mp4", 9)]).await;
        let st = Streams::default();
        let t = Tracker::default();
        st.start(&t, None, &db, &r, 5, 0).await.unwrap(); // aa1
        st.stop(&r, 5).await.unwrap();
        st.start(&t, None, &db, &r, 5, 1).await.unwrap(); // aa2
        let e = st.forget_if_gone(5, "aa1", StreamError::Gone);
        assert_eq!(e.status(), 410);
        assert_eq!(st.engine_id(5).unwrap(), "aa2");
        st.forget_if_gone(5, "aa2", StreamError::Gone);
        assert!(st.info(5).is_none());
    }

    #[tokio::test]
    async fn the_reaper_takes_idle_streams_only() {
        let db = Db::open_in_memory().unwrap();
        let (_s, r) = engine(&[("m.mp4", 9)]).await;
        let st = Streams::default();
        let t = Tracker::default();
        st.start(&t, None, &db, &r, 1, 0).await.unwrap();
        st.start(&t, None, &db, &r, 2, 0).await.unwrap();
        st.touch(2, 1000);
        assert!(st.reap(IDLE_SECS).is_empty()); // exactly the limit: kept
        assert_eq!(st.reap(IDLE_SECS + 1), vec!["aa1".to_string()]);
        assert!(st.reap(IDLE_SECS + 1).is_empty());
    }

    #[tokio::test]
    async fn a_lost_torrent_is_410_and_forgotten() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("m.mp4", 9)]).await;
        Mock::given(method("GET"))
            .and(path("/torrents/aa1/stats/v1"))
            .respond_with(ResponseTemplate::new(404))
            .mount(&s)
            .await;
        let st = Streams::default();
        st.start(&Tracker::default(), None, &db, &r, 5, 0)
            .await
            .unwrap();
        assert_eq!(st.stats(&r, 5, 1).await.unwrap_err().status(), 410);
        assert_eq!(st.stats(&r, 5, 1).await.unwrap_err().status(), 404);
    }

    #[tokio::test]
    async fn select_rejects_an_unknown_file_and_open_only_the_selected_one() {
        let db = Db::open_in_memory().unwrap();
        let (_s, r) = engine(&[("a.mp4", 9), ("b.mp4", 8)]).await;
        let st = Streams::default();
        st.start(&Tracker::default(), None, &db, &r, 5, 0)
            .await
            .unwrap();
        assert_eq!(st.select(&r, 5, 7, 1).await.unwrap_err().status(), 400);
        assert_eq!(st.select(&r, 5, 1, 1).await.unwrap().selected, 1);
        assert_eq!(
            st.open(&r, 5, 0, None, 1).await.err().unwrap().status(),
            400
        );
    }

    #[tokio::test]
    async fn stop_deletes_now() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("m.mp4", 9)]).await;
        let st = Streams::default();
        st.start(&Tracker::default(), None, &db, &r, 5, 0)
            .await
            .unwrap();
        st.stop(&r, 5).await.unwrap();
        assert_eq!(deleted(&s).await, vec!["/torrents/aa1/delete"]);
        assert_eq!(st.stop(&r, 5).await.unwrap_err().status(), 404);
    }

    #[tokio::test]
    async fn the_stats_poll_keeps_a_paused_stream_from_the_reaper() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("m.mp4", 9)]).await;
        Mock::given(method("GET"))
            .and(path("/torrents/aa1/stats/v1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "state": "live", "error": null,
                "progress_bytes": 0, "total_bytes": 9, "finished": false, "live": null
            })))
            .mount(&s)
            .await;
        let st = Streams::default();
        st.start(&Tracker::default(), None, &db, &r, 5, 0)
            .await
            .unwrap();
        st.stats(&r, 5, 1000).await.unwrap();
        assert!(st.reap(IDLE_SECS + 1).is_empty());
        assert_eq!(st.reap(1000 + IDLE_SECS + 1), vec!["aa1".to_string()]);
    }

    /// A topic stopped while rqbit was failing deletes, then streamed again: rqbit still
    /// has the hash and answers 409, so the queued delete runs and the add is retried.
    #[tokio::test]
    async fn a_409_re_add_deletes_the_orphan_and_retries() {
        let db = Db::open_in_memory().unwrap();
        let s = MockServer::start().await;
        let mut reply = files_json(&[("m.mp4", 9)]);
        reply["id"] = json!(1);
        reply["details"]["info_hash"] = json!("aa1");
        Mock::given(method("POST"))
            .and(path("/torrents"))
            .and(query_param("list_only", "true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(files_json(&[("m.mp4", 9)])))
            .mount(&s)
            .await;
        Mock::given(method("POST"))
            .and(path("/torrents/aa1/delete"))
            .respond_with(ResponseTemplate::new(500))
            .up_to_n_times(1)
            .mount(&s)
            .await;
        Mock::given(method("POST"))
            .and(query_param("overwrite", "true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(reply.clone()))
            .up_to_n_times(1)
            .mount(&s)
            .await;
        Mock::given(method("POST"))
            .and(query_param("overwrite", "true"))
            .respond_with(
                ResponseTemplate::new(409).set_body_string("aa1 is already managed, id=1"),
            )
            .up_to_n_times(1)
            .mount(&s)
            .await;
        Mock::given(method("POST"))
            .and(query_param("overwrite", "true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(reply))
            .mount(&s)
            .await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
            .mount(&s)
            .await;
        let r = Rqbit::new(&s.uri());
        let st = Streams::default();
        let t = Tracker::default();
        st.start(&t, None, &db, &r, 5, 0).await.unwrap();
        assert_eq!(st.stop(&r, 5).await.unwrap_err().status(), 502);
        assert_eq!(*st.orphans(), vec!["aa1".to_string()]);
        st.start(&t, None, &db, &r, 5, 1).await.unwrap();
        assert!(st.orphans().is_empty());
        assert_eq!(st.engine_id(5).unwrap(), "aa1");
        assert_eq!(
            deleted(&s).await,
            vec!["/torrents/aa1/delete", "/torrents/aa1/delete"]
        );
        let adds = s
            .received_requests()
            .await
            .unwrap()
            .iter()
            .filter(|q| q.url.query().is_some_and(|q| q.contains("overwrite")))
            .count();
        assert_eq!(adds, 3);
    }
}
