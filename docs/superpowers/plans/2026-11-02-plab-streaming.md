# plab streaming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Stream button on plab's cards that plays a release from the swarm through a
stream-only rqbit in the PIA namespace, keeping every grabbed `.torrent` and none of the
media.

**Architecture:** A new `plab-stream.service` runs `rqbit server` confined to the PIA
namespace with no persistence and a scratch folder wiped on start. plab gains an rqbit
HTTP client (`rqbit.rs`), an in-memory stream table with an idle reaper (`stream.rs`), a
`torrent_file` table in `state.db`, `/stream/…` routes on the Authelia-gated page, and a
second GET-only listener that a tsnsrv node exposes on the tailnet for VLC.

**Tech Stack:** Rust (axum 0.8, reqwest 0.12, rusqlite, tokio, wiremock for tests),
Alpine.js page, NixOS (VPN-Confinement, tsnsrv), rqbit 8.1.1 from nixpkgs.

**Spec:** `docs/superpowers/specs/2026-11-02-plab-streaming-design.md`

## Global Constraints

- Peer traffic only inside the PIA namespace: plab never opens peer connections; rqbit runs with `vpnConfinement.vpnNamespace = config.constellation.pia.namespace`.
- Limits: at most **2** concurrent streams (a third evicts the least recently read); a stream idle **30 min** (1800 s) is deleted; reaper runs every **60 s**.
- Video extensions: `mp4 mkv avi wmv mov m4v ts webm` (case-insensitive). Default file = largest video file.
- Ports: plab page `8577` (unchanged), tailnet stream listener `127.0.0.1:8578`, rqbit API `<pia.namespaceAddress>:3031` (3030 is loki's).
- Scratch folder: `${vars.storageDir}/media/Downloads/.plab-stream`, emptied on every `plab-stream` start; rqbit runs with `--disable-persistence`.
- `.torrent` files are kept indefinitely in `torrent_file`; a stream reads the table first and stores a fetched file **before** handing it to rqbit. On `TrackerError::Limit` with nothing stored: `429`, nothing queued.
- Error statuses: engine unreachable `503`, limit `429`, no video file / bad file index `400`, unknown topic `404`, rqbit lost the torrent `410`, non-GET on the tailnet listener `405`, other tracker errors `502`.
- Dev loop, from `packages/plab/`: `nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc nixpkgs#rustfmt nixpkgs#clippy -c cargo test <filter>` (written below as `cargo test …`). Per-task gate from the repo root: `nix build .#plab` (runs the whole suite in the sandbox).
- New files are invisible to `nix build` until `git add`ed.
- Commits: conventional, scope `galactica`, straight to master. Never mention Claude.
- No firewall rules beyond the VPN-Confinement port mapping; no host networking.

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `packages/plab/Cargo.toml` | modify | reqwest `stream` feature |
| `packages/plab/src/db/mod.rs` | modify | schema v2 (`torrent_file`), `torrent_file` / `store_torrent_file` |
| `packages/plab/src/rqbit.rs` | create | rqbit HTTP API client |
| `packages/plab/src/stream.rs` | create | stream table, torrent acquisition, file choice, reaper, errors |
| `packages/plab/src/web.rs` | modify | `/stream/…` routes, tailnet `stream_router` |
| `packages/plab/src/web_tests.rs` | modify | route tests |
| `packages/plab/src/config.rs`, `app.rs`, `main.rs`, `commands.rs` | modify | `PLAB_RQBIT_URL`, `PLAB_STREAM_PUBLIC_URL`, `--stream-port`, reaper task |
| `packages/plab/src/page.rs`, `page_tests.rs`, `assets/page.js` | modify | Stream button, modal, JS |
| `modules/hosts/galactica/services/plab/default.nix` | modify | `plab-stream` unit, port mapping, tsnsrv node, env |

---

### Task 1: `torrent_file` table

**Files:**
- Create: `packages/plab/src/db/schema_v3.sql`
- Modify: `packages/plab/src/db/mod.rs` (constants near line 15, the stepwise `migrate` near line 172, a new section of `impl Db`)

Schema v2 is already taken (`schema_v2.sql`, download provenance). `migrate` is already
stepwise (`if from < 1 {…} if from < 2 {…}`); this task adds step 3 the same way.

**Interfaces:**
- Produces: `Db::torrent_file(&self, topic_id: u64) -> anyhow::Result<Option<Vec<u8>>>`, `Db::store_torrent_file(&self, topic_id: u64, data: &[u8], now: i64) -> anyhow::Result<()>`

- [ ] **Step 1: Write the failing tests** — append to the `tests` module at the bottom of `db/mod.rs`:

```rust
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
```

If an existing test asserts the user version with a literal `2`, change it to `USER_VERSION`.

- [ ] **Step 2: Run to verify failure**

Run: `cargo test db::tests::torrent_file db::tests::a_version_2`
Expected: compile error, `no method named torrent_file`.

- [ ] **Step 3: Implement.** Create `src/db/schema_v3.sql`:

```sql
-- Every .torrent plab grabs. The tracker caps grabs per day, so a grab is kept rather
-- than spent twice; only the media a stream fetches is scratch.
CREATE TABLE torrent_file (
  topic_id INTEGER PRIMARY KEY,
  data BLOB NOT NULL,              -- the .torrent bytes as the tracker served them
  fetched INTEGER NOT NULL         -- unix time
);
```

In `db/mod.rs`: add `const SCHEMA_V3: &str = include_str!("schema_v3.sql");` beside `SCHEMA_V2`, set `const USER_VERSION: i64 = 3;`, and in `migrate` after the `if from < 2 { … }` step add:

```rust
    if from < 3 {
        tx.execute_batch(SCHEMA_V3)?;
    }
```

Add a section to `impl Db` (after the `kv` methods):

```rust
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
```

- [ ] **Step 4: Run tests**

Run: `cargo test db::`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/db/mod.rs packages/plab/src/db/schema_v3.sql
git commit -m "feat(galactica): plab keeps every grabbed torrent file"
```

---

### Task 2: rqbit client

**Files:**
- Create: `packages/plab/src/rqbit.rs`
- Modify: `packages/plab/src/main.rs` (add `mod rqbit;`), `packages/plab/Cargo.toml` (reqwest features → `["rustls-tls", "json", "stream"]`), `packages/plab/Cargo.lock` (refreshed by cargo)

**Interfaces:**
- Produces:
  - `pub struct Rqbit` (`Clone`), `Rqbit::new(base: &str) -> Rqbit`
  - `pub struct EngineFile { pub index: usize, pub name: String, pub length: u64 }` (`Debug, Clone, PartialEq, Serialize`)
  - `pub struct EngineStats { pub progress: u64, pub total: u64, pub finished: bool, pub mbps: f64, pub peers: usize }` (`Debug, Clone, PartialEq, Serialize`)
  - `pub struct Upstream { pub status: u16, pub headers: Vec<(String, String)>, pub body: axum::body::Body }`
  - `pub struct Gone(pub usize)` — error type, `downcast_ref::<Gone>()` on the anyhow error means rqbit answered 404
  - `async fn list(&self, torrent: &[u8]) -> Result<Vec<EngineFile>>`
  - `async fn add(&self, torrent: &[u8], file: usize) -> Result<usize>`
  - `async fn select(&self, id: usize, file: usize) -> Result<()>`
  - `async fn stats(&self, id: usize) -> Result<EngineStats>`
  - `async fn delete(&self, id: usize) -> Result<()>` (404 is success)
  - `async fn open(&self, id: usize, file: usize, range: Option<&str>) -> Result<Upstream>`

- [ ] **Step 1: Write the module with its tests first, bodies `todo!()`.** Create `src/rqbit.rs`:

```rust
//! rqbit's HTTP API: the stream-only engine plab-stream.service runs in the PIA namespace.
//! plab adds one file of a torrent, proxies rqbit's range-aware stream endpoint, and
//! deletes the torrent with its files when the stream ends.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use axum::body::Body;
use serde::Deserialize;

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct EngineFile {
    pub index: usize,
    pub name: String,
    pub length: u64,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct EngineStats {
    pub progress: u64,
    pub total: u64,
    pub finished: bool,
    /// rqbit's download speed, MiB/s.
    pub mbps: f64,
    pub peers: usize,
}

/// A stream response to pass through: status, the range headers, and the body.
pub struct Upstream {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Body,
}

/// rqbit answered 404 for this torrent id: it restarted on its own, or it was deleted.
#[derive(Debug, thiserror::Error)]
#[error("torrent {0} is gone from the stream engine")]
pub struct Gone(pub usize);

#[derive(Clone)]
pub struct Rqbit {
    base: String,
    /// Bounded calls: list, add, select, stats, delete.
    http: reqwest::Client,
    /// Streams run for hours: a connect timeout only.
    stream_http: reqwest::Client,
}

#[derive(Deserialize)]
struct AddReply {
    id: Option<usize>,
    details: Details,
}

#[derive(Deserialize)]
struct Details {
    #[serde(default)]
    files: Option<Vec<RawFile>>,
}

#[derive(Deserialize)]
struct RawFile {
    name: String,
    length: u64,
}

#[derive(Deserialize)]
struct RawStats {
    progress_bytes: u64,
    total_bytes: u64,
    finished: bool,
    live: Option<RawLive>,
}

#[derive(Deserialize)]
struct RawLive {
    download_speed: RawSpeed,
    snapshot: RawSnapshot,
}

#[derive(Deserialize)]
struct RawSpeed {
    mbps: f64,
}

#[derive(Deserialize)]
struct RawSnapshot {
    peer_stats: RawPeers,
}

#[derive(Deserialize)]
struct RawPeers {
    live: usize,
}

/// The headers a range response needs to reach the player unchanged.
const PASSED: [reqwest::header::HeaderName; 3] = [
    reqwest::header::CONTENT_RANGE,
    reqwest::header::CONTENT_LENGTH,
    reqwest::header::ACCEPT_RANGES,
];

impl Rqbit {
    pub fn new(base: &str) -> Rqbit {
        todo!()
    }

    pub async fn list(&self, torrent: &[u8]) -> Result<Vec<EngineFile>> {
        todo!()
    }

    pub async fn add(&self, torrent: &[u8], file: usize) -> Result<usize> {
        todo!()
    }

    pub async fn select(&self, id: usize, file: usize) -> Result<()> {
        todo!()
    }

    pub async fn stats(&self, id: usize) -> Result<EngineStats> {
        todo!()
    }

    pub async fn delete(&self, id: usize) -> Result<()> {
        todo!()
    }

    pub async fn open(&self, id: usize, file: usize, range: Option<&str>) -> Result<Upstream> {
        todo!()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use http_body_util::BodyExt;
    use serde_json::json;
    use wiremock::matchers::{body_bytes, body_json, header, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn add_reply(id: Option<usize>) -> serde_json::Value {
        json!({"id": id, "output_folder": "/s", "seen_peers": null, "details": {
            "info_hash": "aa", "name": "Rel", "output_folder": "/s",
            "files": [
                {"name": "Rel/sample.mp4", "components": ["Rel", "sample.mp4"], "length": 10,
                 "included": true, "attributes": {}},
                {"name": "Rel/movie.mkv", "components": ["Rel", "movie.mkv"], "length": 900,
                 "included": true, "attributes": {}}
            ]}})
    }

    #[tokio::test]
    async fn list_only_reads_the_files() {
        let s = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/torrents"))
            .and(query_param("list_only", "true"))
            .and(body_bytes(b"d4:infoe".to_vec()))
            .respond_with(ResponseTemplate::new(200).set_body_json(add_reply(None)))
            .expect(1)
            .mount(&s)
            .await;
        let files = Rqbit::new(&s.uri()).list(b"d4:infoe").await.unwrap();
        assert_eq!(
            files,
            vec![
                EngineFile { index: 0, name: "Rel/sample.mp4".into(), length: 10 },
                EngineFile { index: 1, name: "Rel/movie.mkv".into(), length: 900 },
            ]
        );
    }

    #[tokio::test]
    async fn add_fetches_only_the_chosen_file() {
        let s = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/torrents"))
            .and(query_param("only_files", "1"))
            .and(query_param("overwrite", "true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(add_reply(Some(4))))
            .expect(1)
            .mount(&s)
            .await;
        assert_eq!(Rqbit::new(&s.uri()).add(b"t", 1).await.unwrap(), 4);
    }

    #[tokio::test]
    async fn select_replaces_only_files() {
        let s = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/torrents/4/update_only_files"))
            .and(body_json(json!({"only_files": [0]})))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
            .expect(1)
            .mount(&s)
            .await;
        Rqbit::new(&s.uri()).select(4, 0).await.unwrap();
    }

    #[tokio::test]
    async fn stats_decode_with_and_without_live() {
        let s = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/torrents/4/stats/v1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "state": "live", "file_progress": [0, 300], "error": null,
                "progress_bytes": 300, "uploaded_bytes": 0, "total_bytes": 900,
                "finished": false,
                "live": {"snapshot": {"peer_stats": {"queued": 0, "connecting": 1, "live": 7,
                    "seen": 20, "dead": 0, "not_needed": 0, "steals": 0}},
                    "download_speed": {"mbps": 2.5, "human_readable": "2.5 MiB/s"},
                    "upload_speed": {"mbps": 0.0, "human_readable": "0 MiB/s"},
                    "average_piece_download_time": null, "time_remaining": null}
            })))
            .mount(&s)
            .await;
        Mock::given(method("GET"))
            .and(path("/torrents/5/stats/v1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "state": "initializing", "file_progress": [], "error": null,
                "progress_bytes": 0, "uploaded_bytes": 0, "total_bytes": 900,
                "finished": false, "live": null
            })))
            .mount(&s)
            .await;
        let r = Rqbit::new(&s.uri());
        assert_eq!(
            r.stats(4).await.unwrap(),
            EngineStats { progress: 300, total: 900, finished: false, mbps: 2.5, peers: 7 }
        );
        assert_eq!(r.stats(5).await.unwrap().peers, 0);
    }

    #[tokio::test]
    async fn a_404_is_gone_and_delete_tolerates_it() {
        let s = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/torrents/9/stats/v1"))
            .respond_with(ResponseTemplate::new(404).set_body_string("torrent 9 not found"))
            .mount(&s)
            .await;
        Mock::given(method("POST"))
            .and(path("/torrents/9/delete"))
            .respond_with(ResponseTemplate::new(404))
            .expect(1)
            .mount(&s)
            .await;
        let r = Rqbit::new(&s.uri());
        let e = r.stats(9).await.unwrap_err();
        assert!(e.downcast_ref::<Gone>().is_some(), "{e:#}");
        r.delete(9).await.unwrap();
    }

    #[tokio::test]
    async fn open_forwards_range_and_passes_range_headers_back() {
        let s = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/torrents/4/stream/1"))
            .and(header("range", "bytes=2-5"))
            .respond_with(
                ResponseTemplate::new(206)
                    .insert_header("content-range", "bytes 2-5/900")
                    .insert_header("accept-ranges", "bytes")
                    .set_body_bytes(b"abcd".to_vec()),
            )
            .mount(&s)
            .await;
        let up = Rqbit::new(&s.uri()).open(4, 1, Some("bytes=2-5")).await.unwrap();
        assert_eq!(up.status, 206);
        assert!(up.headers.contains(&("content-range".into(), "bytes 2-5/900".into())));
        assert!(up.headers.contains(&("accept-ranges".into(), "bytes".into())));
        let body = up.body.collect().await.unwrap().to_bytes();
        assert_eq!(&body[..], b"abcd");
    }

    #[tokio::test]
    async fn other_failures_are_errors_not_gone() {
        let s = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/torrents"))
            .respond_with(ResponseTemplate::new(500).set_body_string("disk full"))
            .mount(&s)
            .await;
        let e = Rqbit::new(&s.uri()).list(b"t").await.unwrap_err();
        assert!(e.downcast_ref::<Gone>().is_none());
        assert!(format!("{e:#}").contains("disk full"));
    }
}
```

Add `mod rqbit;` to `main.rs` (alphabetical, after `mod py;`). Change reqwest's features in `Cargo.toml` to `["rustls-tls", "json", "stream"]`.

- [ ] **Step 2: Run to verify failure**

Run: `cargo test rqbit::`
Expected: compiles (Cargo.lock updates), every test panics with `not yet implemented`.

- [ ] **Step 3: Implement the bodies**

```rust
    pub fn new(base: &str) -> Rqbit {
        Rqbit {
            base: base.trim_end_matches('/').to_string(),
            http: crate::http::client(60),
            stream_http: reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(10))
                .build()
                .expect("the stream client's static configuration is valid"),
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}/{path}", self.base)
    }

    async fn post_torrent(&self, torrent: &[u8], query: &[(&str, String)]) -> Result<AddReply> {
        let resp = self
            .http
            .post(self.url("torrents"))
            .query(query)
            .body(torrent.to_vec())
            .send()
            .await
            .context("rqbit unreachable")?;
        Ok(checked(resp, None).await?.json().await?)
    }

    pub async fn list(&self, torrent: &[u8]) -> Result<Vec<EngineFile>> {
        let reply = self
            .post_torrent(torrent, &[("list_only", "true".into())])
            .await?;
        Ok(reply
            .details
            .files
            .unwrap_or_default()
            .into_iter()
            .enumerate()
            .map(|(index, f)| EngineFile { index, name: f.name, length: f.length })
            .collect())
    }

    pub async fn add(&self, torrent: &[u8], file: usize) -> Result<usize> {
        let reply = self
            .post_torrent(
                torrent,
                &[("only_files", file.to_string()), ("overwrite", "true".into())],
            )
            .await?;
        reply.id.context("rqbit added the torrent without an id")
    }

    pub async fn select(&self, id: usize, file: usize) -> Result<()> {
        let resp = self
            .http
            .post(self.url(&format!("torrents/{id}/update_only_files")))
            .json(&serde_json::json!({ "only_files": [file] }))
            .send()
            .await
            .context("rqbit unreachable")?;
        checked(resp, Some(id)).await?;
        Ok(())
    }

    pub async fn stats(&self, id: usize) -> Result<EngineStats> {
        let resp = self
            .http
            .get(self.url(&format!("torrents/{id}/stats/v1")))
            .send()
            .await
            .context("rqbit unreachable")?;
        let raw: RawStats = checked(resp, Some(id)).await?.json().await?;
        Ok(EngineStats {
            progress: raw.progress_bytes,
            total: raw.total_bytes,
            finished: raw.finished,
            mbps: raw.live.as_ref().map_or(0.0, |l| l.download_speed.mbps),
            peers: raw.live.as_ref().map_or(0, |l| l.snapshot.peer_stats.live),
        })
    }

    pub async fn delete(&self, id: usize) -> Result<()> {
        let resp = self
            .http
            .post(self.url(&format!("torrents/{id}/delete")))
            .send()
            .await
            .context("rqbit unreachable")?;
        match checked(resp, Some(id)).await {
            Err(e) if e.downcast_ref::<Gone>().is_some() => Ok(()),
            r => r.map(|_| ()),
        }
    }

    pub async fn open(&self, id: usize, file: usize, range: Option<&str>) -> Result<Upstream> {
        let mut req = self
            .stream_http
            .get(self.url(&format!("torrents/{id}/stream/{file}")));
        if let Some(r) = range {
            req = req.header(reqwest::header::RANGE, r);
        }
        let resp = req.send().await.context("rqbit unreachable")?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(Gone(id).into());
        }
        let headers = PASSED
            .iter()
            .filter_map(|h| {
                let v = resp.headers().get(h)?.to_str().ok()?;
                Some((h.as_str().to_string(), v.to_string()))
            })
            .collect();
        Ok(Upstream {
            status: resp.status().as_u16(),
            headers,
            body: Body::from_stream(resp.bytes_stream()),
        })
    }
```

Below the `impl`:

```rust
/// A 2xx response, `Gone` for a 404 on a torrent id, an error carrying rqbit's body otherwise.
async fn checked(resp: reqwest::Response, id: Option<usize>) -> Result<reqwest::Response> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    if let (reqwest::StatusCode::NOT_FOUND, Some(id)) = (status, id) {
        return Err(Gone(id).into());
    }
    let body = resp.text().await.unwrap_or_default();
    bail!("rqbit {status}: {}", body.trim())
}
```

- [ ] **Step 4: Run tests**

Run: `cargo test rqbit::`
Expected: 7 PASS.

- [ ] **Step 5: Gate and commit**

Run from the repo root: `git add packages/plab && nix build .#plab`
Expected: builds (tests pass in the sandbox).

```bash
git add packages/plab/Cargo.toml packages/plab/Cargo.lock packages/plab/src/main.rs packages/plab/src/rqbit.rs
git commit -m "feat(galactica): plab rqbit client"
```

---

### Task 3: stream table

**Files:**
- Create: `packages/plab/src/stream.rs`
- Modify: `packages/plab/src/main.rs` (add `mod stream;`)

**Interfaces:**
- Consumes: `Db::torrent_file`, `Db::store_torrent_file` (Task 1); `Rqbit`, `EngineFile`, `EngineStats`, `Upstream`, `Gone` (Task 2); `crate::tracker::{TrackerApi, TrackerError}`.
- Produces:
  - `pub const MAX_STREAMS: usize = 2; pub const IDLE_SECS: i64 = 1800;`
  - `pub enum StreamError { Limit(String), NoVideo, BadFile, Unknown, Gone, Engine(String), Tracker(String) }` with `fn status(&self) -> u16`
  - `pub struct StreamInfo { pub topic: u64, pub files: Vec<EngineFile>, pub selected: usize }` (`Serialize`)
  - `pub struct Streams` (`Default`), methods:
    - `async fn start<T: TrackerApi>(&self, tracker: &T, db: &Db, engine: &Rqbit, topic: u64, now: i64) -> Result<StreamInfo, StreamError>`
    - `async fn select(&self, engine: &Rqbit, topic: u64, file: usize, now: i64) -> Result<StreamInfo, StreamError>`
    - `async fn stats(&self, engine: &Rqbit, topic: u64) -> Result<EngineStats, StreamError>`
    - `async fn open(&self, engine: &Rqbit, topic: u64, file: usize, range: Option<&str>, now: i64) -> Result<(Upstream, String), StreamError>` — the `String` is the file name
    - `async fn stop(&self, engine: &Rqbit, topic: u64) -> Result<(), StreamError>`
    - `fn touch(&self, topic: u64, now: i64)`
    - `fn reap(&self, now: i64) -> Vec<usize>` — removes idle entries, returns their rqbit ids
  - `pub async fn torrent_bytes<T: TrackerApi>(tracker: &T, db: &Db, topic: u64, now: i64) -> Result<Vec<u8>, StreamError>`
  - `pub fn default_file(files: &[EngineFile]) -> Option<usize>`
  - `pub fn content_type(name: &str) -> &'static str`

- [ ] **Step 1: Write the failing tests.** Create `src/stream.rs` with the full public surface as `todo!()` and this test module:

```rust
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
    }

    impl TrackerApi for Tracker {
        async fn top(&self, _: &[u32], _: u32, _: usize, _: &[fancy_regex::Regex])
            -> Result<Vec<Row>, TrackerError> { Ok(vec![]) }
        async fn search(&self, _: &str, _: &[u32], _: Option<u32>, _: usize,
            _: &[fancy_regex::Regex], _: Option<usize>) -> Result<Vec<Row>, TrackerError> { Ok(vec![]) }
        async fn topic(&self, _: u64) -> Result<String, TrackerError> { Ok(String::new()) }
        async fn torrent(&self, _: u64) -> Result<Vec<u8>, TrackerError> {
            *self.calls.lock().unwrap() += 1;
            if self.limit { Err(TrackerError::Limit(10)) } else { Ok(b"d4:infoe".to_vec()) }
        }
        async fn fetch(&self, _: &str) -> Result<Vec<u8>, TrackerError> { Ok(vec![]) }
    }

    fn file(index: usize, name: &str, length: u64) -> EngineFile {
        EngineFile { index, name: name.into(), length }
    }

    fn files_json(files: &[(&str, u64)]) -> serde_json::Value {
        let files: Vec<_> = files.iter().map(|(n, l)| json!({"name": n, "components": [n],
            "length": l, "included": true, "attributes": {}})).collect();
        json!({"id": null, "output_folder": "/s", "seen_peers": null,
            "details": {"info_hash": "aa", "name": "Rel", "output_folder": "/s", "files": files}})
    }

    /// An rqbit that lists `files` and hands out ids 1, 2, 3… in add order.
    async fn engine(files: &[(&str, u64)]) -> (MockServer, Rqbit) {
        let s = MockServer::start().await;
        Mock::given(method("POST")).and(path("/torrents")).and(query_param("list_only", "true"))
            .respond_with(ResponseTemplate::new(200).set_body_json(files_json(files)))
            .mount(&s).await;
        for id in 1..=5usize {
            let mut reply = files_json(files);
            reply["id"] = json!(id);
            Mock::given(method("POST")).and(path("/torrents")).and(query_param("overwrite", "true"))
                .respond_with(ResponseTemplate::new(200).set_body_json(reply))
                .up_to_n_times(1).mount(&s).await;
        }
        Mock::given(method("POST")).respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
            .mount(&s).await;
        let r = Rqbit::new(&s.uri());
        (s, r)
    }

    async fn deleted(s: &MockServer) -> Vec<String> {
        s.received_requests().await.unwrap().iter()
            .map(|r| r.url.path().to_string())
            .filter(|p| p.ends_with("/delete")).collect()
    }

    #[test]
    fn default_file_is_the_largest_video() {
        let files = [file(0, "a/cover.jpg", 9_000), file(1, "a/s.MP4", 10), file(2, "a/m.mkv", 900)];
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
        let t = Tracker { limit: true, ..Default::default() };
        let e = torrent_bytes(&t, &db, 5, 2).await.unwrap_err();
        assert_eq!(e.status(), 429);
        assert!(db.queued(crate::db::Section::Video).unwrap().is_empty());
    }

    #[tokio::test]
    async fn the_torrent_is_kept_when_the_engine_fails() {
        let db = Db::open_in_memory().unwrap();
        let s = MockServer::start().await;
        Mock::given(method("POST")).respond_with(ResponseTemplate::new(500)).mount(&s).await;
        let e = Streams::default()
            .start(&Tracker::default(), &db, &Rqbit::new(&s.uri()), 5, 1).await.unwrap_err();
        assert_eq!(e.status(), 503);
        assert!(db.torrent_file(5).unwrap().is_some());
    }

    #[tokio::test]
    async fn start_picks_the_largest_video_and_is_idempotent() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("s.mp4", 10), ("m.mkv", 900)]).await;
        let st = Streams::default();
        let a = st.start(&Tracker::default(), &db, &r, 5, 1).await.unwrap();
        let b = st.start(&Tracker::default(), &db, &r, 5, 2).await.unwrap();
        assert_eq!(a.selected, 1);
        assert_eq!(a, b);
        let adds = s.received_requests().await.unwrap().iter()
            .filter(|q| q.url.query().is_some_and(|q| q.contains("overwrite"))).count();
        assert_eq!(adds, 1);
    }

    #[tokio::test]
    async fn no_video_is_refused_before_adding() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("readme.nfo", 10)]).await;
        let e = Streams::default().start(&Tracker::default(), &db, &r, 5, 1).await.unwrap_err();
        assert_eq!(e.status(), 400);
        let adds = s.received_requests().await.unwrap().iter()
            .filter(|q| q.url.query().is_some_and(|q| q.contains("overwrite"))).count();
        assert_eq!(adds, 0);
    }

    #[tokio::test]
    async fn a_third_stream_evicts_the_least_recently_read() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("m.mp4", 9)]).await;
        let st = Streams::default();
        let t = Tracker::default();
        st.start(&t, &db, &r, 1, 100).await.unwrap(); // rqbit id 1
        st.start(&t, &db, &r, 2, 100).await.unwrap(); // rqbit id 2
        st.touch(1, 150); // topic 2 is now the least recently read
        st.start(&t, &db, &r, 3, 200).await.unwrap();
        assert_eq!(deleted(&s).await, vec!["/torrents/2/delete"]);
        assert_eq!(st.stats(&r, 2).await.unwrap_err().status(), 404);
    }

    #[tokio::test]
    async fn the_reaper_takes_idle_streams_only() {
        let db = Db::open_in_memory().unwrap();
        let (_s, r) = engine(&[("m.mp4", 9)]).await;
        let st = Streams::default();
        let t = Tracker::default();
        st.start(&t, &db, &r, 1, 0).await.unwrap();
        st.start(&t, &db, &r, 2, 0).await.unwrap();
        st.touch(2, 1000);
        assert!(st.reap(IDLE_SECS).is_empty()); // exactly the limit: kept
        assert_eq!(st.reap(IDLE_SECS + 1), vec![1]);
        assert!(st.reap(IDLE_SECS + 1).is_empty());
    }

    #[tokio::test]
    async fn a_lost_torrent_is_410_and_forgotten() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("m.mp4", 9)]).await;
        Mock::given(method("GET")).and(path("/torrents/1/stats/v1"))
            .respond_with(ResponseTemplate::new(404)).mount(&s).await;
        let st = Streams::default();
        st.start(&Tracker::default(), &db, &r, 5, 0).await.unwrap();
        assert_eq!(st.stats(&r, 5).await.unwrap_err().status(), 410);
        assert_eq!(st.stats(&r, 5).await.unwrap_err().status(), 404);
    }

    #[tokio::test]
    async fn select_rejects_an_unknown_file_and_open_only_the_selected_one() {
        let db = Db::open_in_memory().unwrap();
        let (_s, r) = engine(&[("a.mp4", 9), ("b.mp4", 8)]).await;
        let st = Streams::default();
        st.start(&Tracker::default(), &db, &r, 5, 0).await.unwrap();
        assert_eq!(st.select(&r, 5, 7, 1).await.unwrap_err().status(), 400);
        assert_eq!(st.select(&r, 5, 1, 1).await.unwrap().selected, 1);
        assert_eq!(st.open(&r, 5, 0, None, 1).await.err().unwrap().status(), 400);
    }

    #[tokio::test]
    async fn stop_deletes_now() {
        let db = Db::open_in_memory().unwrap();
        let (s, r) = engine(&[("m.mp4", 9)]).await;
        let st = Streams::default();
        st.start(&Tracker::default(), &db, &r, 5, 0).await.unwrap();
        st.stop(&r, 5).await.unwrap();
        assert_eq!(deleted(&s).await, vec!["/torrents/1/delete"]);
        assert_eq!(st.stop(&r, 5).await.unwrap_err().status(), 404);
    }
}
```

Add `mod stream;` to `main.rs` (after `mod stash;`).

- [ ] **Step 2: Run to verify failure**

Run: `cargo test stream::`
Expected: compiles; tests panic with `not yet implemented`.

- [ ] **Step 3: Implement**

```rust
//! Streams: one release's file played from the swarm through rqbit, kept only while it is
//! being read. The table lives in memory; plab-stream.service is PartOf plab.service, so a
//! restart of either empties both.

use std::collections::HashMap;
use std::sync::Mutex;

use serde::Serialize;
use tracing::warn;

use crate::db::Db;
use crate::rqbit::{EngineFile, EngineStats, Gone, Rqbit, Upstream};
use crate::tracker::{TrackerApi, TrackerError};

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
            StreamError::Engine(_) => 503,
            StreamError::Tracker(_) => 502,
        }
    }
}

fn engine_err(e: anyhow::Error) -> StreamError {
    if e.downcast_ref::<Gone>().is_some() {
        StreamError::Gone
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
    engine_id: usize,
    files: Vec<EngineFile>,
    selected: usize,
    last_read: i64,
}

#[derive(Default)]
pub struct Streams {
    table: Mutex<HashMap<u64, Entry>>,
    /// Starts one at a time, so a double click never adds a torrent twice.
    starting: tokio::sync::Mutex<()>,
}

fn extension(name: &str) -> String {
    name.rsplit_once('.').map_or(String::new(), |(_, e)| e.to_ascii_lowercase())
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
    db.store_torrent_file(topic, &bytes, now).map_err(internal)?;
    Ok(bytes)
}

impl Streams {
    fn table(&self) -> std::sync::MutexGuard<'_, HashMap<u64, Entry>> {
        self.table.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn info(&self, topic: u64) -> Option<StreamInfo> {
        self.table().get(&topic).map(|e| StreamInfo {
            topic,
            files: e.files.clone(),
            selected: e.selected,
        })
    }

    fn engine_id(&self, topic: u64) -> Result<usize, StreamError> {
        self.table().get(&topic).map(|e| e.engine_id).ok_or(StreamError::Unknown)
    }

    /// Drop a topic whose torrent rqbit no longer has, and say so.
    fn forget_if_gone(&self, topic: u64, e: StreamError) -> StreamError {
        if matches!(e, StreamError::Gone) {
            self.table().remove(&topic);
        }
        e
    }

    pub async fn start<T: TrackerApi>(
        &self,
        tracker: &T,
        db: &Db,
        engine: &Rqbit,
        topic: u64,
        now: i64,
    ) -> Result<StreamInfo, StreamError> {
        let _one = self.starting.lock().await;
        if let Some(info) = self.info(topic) {
            self.touch(topic, now);
            return Ok(info);
        }
        let bytes = torrent_bytes(tracker, db, topic, now).await?;
        let files = engine.list(&bytes).await.map_err(engine_err)?;
        let selected = default_file(&files).ok_or(StreamError::NoVideo)?;
        for id in self.make_room() {
            if let Err(e) = engine.delete(id).await {
                warn!(job = "stream", "evicting rqbit torrent {id}: {e:#}");
            }
        }
        let engine_id = engine.add(&bytes, selected).await.map_err(engine_err)?;
        self.table().insert(
            topic,
            Entry { engine_id, files: files.clone(), selected, last_read: now },
        );
        Ok(StreamInfo { topic, files, selected })
    }

    /// Remove least-recently-read entries until one more fits; their rqbit ids.
    fn make_room(&self) -> Vec<usize> {
        let mut table = self.table();
        let mut evicted = vec![];
        while table.len() >= MAX_STREAMS {
            let Some((&topic, _)) = table.iter().min_by_key(|(_, e)| e.last_read) else {
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
        let known = self.table().get(&topic).is_some_and(|e| file < e.files.len());
        if !known {
            return Err(StreamError::BadFile);
        }
        engine
            .select(id, file)
            .await
            .map_err(|e| self.forget_if_gone(topic, engine_err(e)))?;
        if let Some(e) = self.table().get_mut(&topic) {
            e.selected = file;
            e.last_read = now;
        }
        self.info(topic).ok_or(StreamError::Unknown)
    }

    pub async fn stats(&self, engine: &Rqbit, topic: u64) -> Result<EngineStats, StreamError> {
        let id = self.engine_id(topic)?;
        engine
            .stats(id)
            .await
            .map_err(|e| self.forget_if_gone(topic, engine_err(e)))
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
            (e.engine_id, e.files[file].name.clone())
        };
        self.touch(topic, now);
        let up = engine
            .open(id, file, range)
            .await
            .map_err(|e| self.forget_if_gone(topic, engine_err(e)))?;
        Ok((up, name))
    }

    pub async fn stop(&self, engine: &Rqbit, topic: u64) -> Result<(), StreamError> {
        let id = self
            .table()
            .remove(&topic)
            .map(|e| e.engine_id)
            .ok_or(StreamError::Unknown)?;
        engine.delete(id).await.map_err(engine_err)
    }

    pub fn touch(&self, topic: u64, now: i64) {
        if let Some(e) = self.table().get_mut(&topic) {
            e.last_read = e.last_read.max(now);
        }
    }

    pub fn reap(&self, now: i64) -> Vec<usize> {
        let mut table = self.table();
        let idle: Vec<u64> = table
            .iter()
            .filter(|(_, e)| now - e.last_read > IDLE_SECS)
            .map(|(&t, _)| t)
            .collect();
        idle.iter().filter_map(|t| table.remove(t)).map(|e| e.engine_id).collect()
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cargo test stream::`
Expected: 13 PASS.

- [ ] **Step 5: Gate and commit**

Run: `git add packages/plab && nix build .#plab` (from the repo root).

```bash
git add packages/plab/src/main.rs packages/plab/src/stream.rs
git commit -m "feat(galactica): plab stream table, torrent reuse and idle reaper"
```

---

### Task 4: `/stream/…` routes and the tailnet listener

**Files:**
- Modify: `packages/plab/src/web.rs`, `packages/plab/src/web_tests.rs`, `packages/plab/src/commands.rs` (the one `WebState { … }` literal, near line 186: add the three new fields as `None` / `Arc::new(Streams::default())` / `None` for now; Task 5 wires them)

**Interfaces:**
- Consumes: everything Task 3 produces.
- Produces:
  - `WebState` gains `pub engine: Option<Rqbit>`, `pub streams: Arc<Streams>`, `pub stream_public_url: Option<String>`
  - `pub fn stream_router<T: TrackerApi + 'static, C: TorrentClient + 'static>(state: Arc<WebState<T, C>>) -> Router`
  - Start/select JSON: `{"ok": true, "topic": u64, "files": [{"index","name","length"}], "selected": usize, "external": "<stream_public_url>/stream/<topic>/<selected>" | null}`; stats JSON: `{"ok": true, "stats": {"progress","total","finished","mbps","peers"}}`; errors `{"ok": false, "error": "<message>"}` with `StreamError::status()`.

- [ ] **Step 1: Write the failing tests.** In `web_tests.rs`:

Add to the `Fx::with` `WebState` literal: `engine: None, streams: Arc::new(crate::stream::Streams::default()), stream_public_url: Some("https://plab-stream.example".into()),`.

Add to `impl Fx`:

```rust
    async fn send_to(&self, router: Router, method: &str, path: &str, range: Option<&str>) -> Reply {
        let mut req = Request::builder().method(method).uri(path);
        if let Some(r) = range {
            req = req.header("range", r);
        }
        let resp = router.oneshot(req.body(Body::empty()).unwrap()).await.unwrap();
        let (parts, body) = resp.into_parts();
        Reply {
            status: parts.status.as_u16(),
            headers: parts.headers,
            body: body.collect().await.unwrap().to_bytes().to_vec(),
        }
    }

    async fn page(&self, method: &str, path: &str, range: Option<&str>) -> Reply {
        self.send_to(router(self.state.clone()), method, path, range).await
    }

    async fn tailnet(&self, method: &str, path: &str) -> Reply {
        self.send_to(stream_router(self.state.clone()), method, path, None).await
    }
```

And the tests (with `use wiremock::{Mock, MockServer, ResponseTemplate}; use wiremock::matchers::{method as m, path as p, query_param, header as h};` at the top of the new block):

```rust
// Streaming

async fn rqbit() -> MockServer {
    let s = MockServer::start().await;
    let files = serde_json::json!([{"name": "Rel/m.mp4", "components": ["Rel", "m.mp4"],
        "length": 900, "included": true, "attributes": {}}]);
    Mock::given(m("POST")).and(p("/torrents")).and(query_param("list_only", "true"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!(
            {"id": null, "output_folder": "/s", "seen_peers": null,
             "details": {"info_hash": "aa", "name": "Rel", "output_folder": "/s", "files": files}})))
        .mount(&s).await;
    Mock::given(m("POST")).and(p("/torrents")).and(query_param("overwrite", "true"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!(
            {"id": 1, "output_folder": "/s", "seen_peers": null,
             "details": {"info_hash": "aa", "name": "Rel", "output_folder": "/s", "files": files}})))
        .mount(&s).await;
    Mock::given(m("GET")).and(p("/torrents/1/stream/0")).and(h("range", "bytes=0-3"))
        .respond_with(ResponseTemplate::new(206)
            .insert_header("content-range", "bytes 0-3/900")
            .set_body_bytes(b"\0\0\0\x18".to_vec()))
        .mount(&s).await;
    s
}

fn streaming(server: &MockServer) -> Fx {
    let uri = server.uri();
    Fx::with(FakeTracker::default(), move |_, st| st.engine = Some(crate::rqbit::Rqbit::new(&uri)))
}

#[tokio::test]
async fn stream_start_reports_files_and_the_tailnet_url() {
    let s = rqbit().await;
    let fx = streaming(&s);
    let r = fx.page("POST", "/stream/5", None).await;
    assert_eq!(r.status, 200, "{}", r.text());
    let j: Value = serde_json::from_slice(&r.body).unwrap();
    assert_eq!(j["ok"], true);
    assert_eq!(j["selected"], 0);
    assert_eq!(j["files"][0]["name"], "Rel/m.mp4");
    assert_eq!(j["external"], "https://plab-stream.example/stream/5/0");
    assert!(fx.state.db.torrent_file(5).unwrap().is_some());
}

#[tokio::test]
async fn stream_bytes_forward_the_range() {
    let s = rqbit().await;
    let fx = streaming(&s);
    fx.page("POST", "/stream/5", None).await;
    let r = fx.page("GET", "/stream/5/0", Some("bytes=0-3")).await;
    assert_eq!(r.status, 206);
    assert_eq!(r.header("content-range"), "bytes 0-3/900");
    assert_eq!(r.header("content-type"), "video/mp4");
    assert_eq!(r.body, b"\0\0\0\x18");
}

#[tokio::test]
async fn the_tailnet_listener_only_reads() {
    let s = rqbit().await;
    let fx = streaming(&s);
    fx.page("POST", "/stream/5", None).await;
    assert_eq!(fx.tailnet("POST", "/stream/5").await.status, 405);
    assert_eq!(fx.tailnet("DELETE", "/stream/5").await.status, 405);
    assert_eq!(fx.tailnet("GET", "/stream/5").await.status, 404);
    assert_eq!(fx.tailnet("GET", "/").await.status, 404);
    // The rqbit stub only answers the ranged request, as a player sends it.
    let r = fx
        .send_to(stream_router(fx.state.clone()), "GET", "/stream/5/0", Some("bytes=0-3"))
        .await;
    assert_eq!(r.status, 206);
}

#[tokio::test]
async fn stream_limit_is_429_and_not_queued() {
    let s = rqbit().await;
    let uri = s.uri();
    let mut t = FakeTracker::default();
    t.limit.insert(5);
    let fx = Fx::with(t, move |_, st| st.engine = Some(crate::rqbit::Rqbit::new(&uri)));
    let r = fx.page("POST", "/stream/5", None).await;
    assert_eq!(r.status, 429);
    assert!(r.text().contains("daily download limit"));
    assert!(fx.state.db.queued(Section::Video).unwrap().is_empty());
}

#[tokio::test]
async fn stream_without_an_engine_is_503() {
    let fx = Fx::new();
    assert_eq!(fx.page("POST", "/stream/5", None).await.status, 503);
}

#[tokio::test]
async fn stream_unknown_topic_is_404_and_stop_deletes() {
    let s = rqbit().await;
    Mock::given(m("POST")).and(p("/torrents/1/delete"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({})))
        .expect(1).mount(&s).await;
    let fx = streaming(&s);
    assert_eq!(fx.page("GET", "/stream/9", None).await.status, 404);
    fx.page("POST", "/stream/5", None).await;
    assert_eq!(fx.page("DELETE", "/stream/5", None).await.status, 200);
    assert_eq!(fx.page("GET", "/stream/5", None).await.status, 404);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test web::tests::stream web::tests::the_tailnet`
Expected: compile errors (`stream_router`, missing fields).

- [ ] **Step 3: Implement in `web.rs`.**

Imports: add `use crate::rqbit::Rqbit; use crate::stream::{self, StreamError, Streams};`, `use axum::http::HeaderMap;`, `use futures::StreamExt;`, `use serde::Serialize;`.

Fields on `WebState`:

```rust
    /// The stream engine; None when PLAB_RQBIT_URL is unset (streams answer 503).
    pub engine: Option<Rqbit>,
    pub streams: Arc<Streams>,
    /// The tailnet listener's public base, for the "Copy URL for VLC" button.
    pub stream_public_url: Option<String>,
```

Routing helpers:

```rust
#[derive(Debug, Clone, Copy, PartialEq)]
enum StreamRoute {
    Topic(u64),
    Select(u64, usize),
    File(u64, usize),
}

fn stream_route(path: &str) -> Option<StreamRoute> {
    fn num(s: &str) -> Option<u64> {
        (!s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())).then(|| s.parse().ok())?
    }
    let parts: Vec<&str> = path.strip_prefix("/stream/")?.split('/').collect();
    match parts.as_slice() {
        [t] => Some(StreamRoute::Topic(num(t)?)),
        [t, "select", f] => Some(StreamRoute::Select(num(t)?, num(f)? as usize)),
        [t, f] => Some(StreamRoute::File(num(t)?, num(f)? as usize)),
        _ => None,
    }
}

fn json_reply(code: u16, v: Value) -> Response<Body> {
    send(code, v.to_string(), "application/json", "no-store")
}

fn stream_error(e: StreamError) -> Response<Body> {
    info!(job = "web", "stream: {e}");
    json_reply(e.status(), json!({"ok": false, "error": e.to_string()}))
}

/// `{"ok": true}` merged with the value's own fields.
fn ok_reply<V: Serialize>(v: V, extra: Value) -> Response<Body> {
    let mut m = Map::new();
    m.insert("ok".into(), true.into());
    if let Value::Object(fields) = serde_json::to_value(v).unwrap_or(Value::Null) {
        m.extend(fields);
    }
    if let Value::Object(fields) = extra {
        m.extend(fields);
    }
    json_reply(200, Value::Object(m))
}
```

Change `handle` to take headers and route `/stream/` first:

```rust
async fn handle<T: TrackerApi + 'static, C: TorrentClient + 'static>(
    State(st): State<Arc<WebState<T, C>>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
) -> Response<Body> {
    if let Some(route) = stream_route(uri.path()) {
        let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
        return stream_page(&st, method, route, range).await;
    }
    // … existing body unchanged …
}
```

Handlers:

```rust
async fn stream_page<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    method: Method,
    route: StreamRoute,
    range: Option<&str>,
) -> Response<Body> {
    let Some(engine) = &st.engine else {
        return stream_error(StreamError::Engine("PLAB_RQBIT_URL is not set".into()));
    };
    let external = |topic: u64, file: usize| {
        st.stream_public_url
            .as_ref()
            .map(|b| format!("{}/stream/{topic}/{file}", b.trim_end_matches('/')))
    };
    let started = |r: Result<stream::StreamInfo, StreamError>| match r {
        Ok(info) => {
            let ext = external(info.topic, info.selected);
            ok_reply(info, json!({ "external": ext }))
        }
        Err(e) => stream_error(e),
    };
    match (method, route) {
        (Method::GET, StreamRoute::File(t, f)) => stream_file(&st.streams, engine, t, f, range).await,
        (Method::GET, StreamRoute::Topic(t)) => match st.streams.stats(engine, t).await {
            Ok(stats) => ok_reply(json!({}), json!({ "stats": stats })),
            Err(e) => stream_error(e),
        },
        (Method::POST, StreamRoute::Topic(t)) => {
            started(st.streams.start(&*st.tracker, &st.db, engine, t, now()).await)
        }
        (Method::POST, StreamRoute::Select(t, f)) => {
            started(st.streams.select(engine, t, f, now()).await)
        }
        (Method::DELETE, StreamRoute::Topic(t)) => match st.streams.stop(engine, t).await {
            Ok(()) => ok_reply(json!({}), json!({})),
            Err(e) => stream_error(e),
        },
        _ => text(405, "method not allowed"),
    }
}

/// The bytes of a stream, passed through from rqbit. Each chunk that reaches the client
/// counts as a read, so one long-running request keeps its stream from the reaper.
async fn stream_file(
    streams: &Arc<Streams>,
    engine: &Rqbit,
    topic: u64,
    file: usize,
    range: Option<&str>,
) -> Response<Body> {
    let (up, name) = match streams.open(engine, topic, file, range, now()).await {
        Ok(v) => v,
        Err(e) => return stream_error(e),
    };
    let reads = streams.clone();
    let body = Body::from_stream(
        up.body
            .into_data_stream()
            .inspect(move |_| reads.touch(topic, now())),
    );
    let mut resp = Response::builder()
        .status(up.status)
        .header(header::CONTENT_TYPE, stream::content_type(&name))
        .header(header::CACHE_CONTROL, "no-store");
    for (k, v) in up.headers {
        resp = resp.header(k, v);
    }
    resp.body(body).unwrap()
}

/// The tailnet listener: reads a stream that was started on the gated page, nothing else.
pub fn stream_router<T: TrackerApi + 'static, C: TorrentClient + 'static>(
    state: Arc<WebState<T, C>>,
) -> Router {
    Router::new().fallback(tailnet::<T, C>).with_state(state)
}

async fn tailnet<T: TrackerApi + 'static, C: TorrentClient + 'static>(
    State(st): State<Arc<WebState<T, C>>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
) -> Response<Body> {
    if method != Method::GET {
        return text(405, "method not allowed");
    }
    let Some(StreamRoute::File(topic, file)) = stream_route(uri.path()) else {
        return not_found();
    };
    let Some(engine) = &st.engine else {
        return stream_error(StreamError::Engine("PLAB_RQBIT_URL is not set".into()));
    };
    let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
    stream_file(&st.streams, engine, topic, file, range).await
}
```

In `commands.rs`' `WebState { … }` literal add `engine: None, streams: Arc::new(crate::stream::Streams::default()), stream_public_url: None,` (replaced in Task 5).

- [ ] **Step 4: Run tests**

Run: `cargo test web::`
Expected: all PASS, including the existing route tests.

- [ ] **Step 5: Gate and commit**

Run: `nix build .#plab` (repo root).

```bash
git add packages/plab/src/web.rs packages/plab/src/web_tests.rs packages/plab/src/commands.rs
git commit -m "feat(galactica): plab stream routes and a read-only tailnet listener"
```

---

### Task 5: daemon wiring — config, tailnet listener, reaper

**Files:**
- Modify: `packages/plab/src/config.rs`, `packages/plab/src/app.rs`, `packages/plab/src/main.rs`, `packages/plab/src/commands.rs`

**Interfaces:**
- Consumes: `Rqbit::new`, `Rqbit::delete`, `Streams::reap`, `web::stream_router`.
- Produces: env `PLAB_RQBIT_URL`, `PLAB_STREAM_PUBLIC_URL`; CLI `plab serve --stream-port <u16>`; `App { rqbit: Option<Rqbit>, streams: Arc<Streams>, … }`.

- [ ] **Step 1: Write the failing test** — in `config.rs`' tests (create a `#[cfg(test)] mod tests` if the file has none, with `use super::*;`):

```rust
    #[test]
    fn stream_settings_come_from_the_environment() {
        let c = Config::from_env(|k| match k {
            "PLAB_RQBIT_URL" => Some("http://10.0.0.2:3031".into()),
            "PLAB_STREAM_PUBLIC_URL" => Some("https://plab-stream.bat-boa.ts.net".into()),
            _ => None,
        });
        assert_eq!(c.rqbit_url.as_deref(), Some("http://10.0.0.2:3031"));
        assert_eq!(c.stream_public_url.as_deref(), Some("https://plab-stream.bat-boa.ts.net"));
        let none = Config::from_env(|_| None);
        assert!(none.rqbit_url.is_none() && none.stream_public_url.is_none());
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `cargo test config::`
Expected: compile error, no field `rqbit_url`.

- [ ] **Step 3: Implement**

`config.rs`: fields `pub rqbit_url: Option<String>, pub stream_public_url: Option<String>,` filled with `rqbit_url: var("PLAB_RQBIT_URL"), stream_public_url: var("PLAB_STREAM_PUBLIC_URL"),`.

`app.rs`: fields on `App`:

```rust
    /// The stream engine, when PLAB_RQBIT_URL is set.
    pub rqbit: Option<crate::rqbit::Rqbit>,
    pub streams: Arc<crate::stream::Streams>,
```

built in `App::build` as `rqbit: cfg.rqbit_url.as_deref().map(crate::rqbit::Rqbit::new), streams: Arc::new(Default::default()),` (before `cfg: Arc::new(cfg)` moves `cfg`).

`main.rs`: on `Cmd::Serve` add

```rust
        /// Also serve GET /stream/<topic>/<file> alone on this port (the tailnet node).
        #[arg(long)]
        stream_port: Option<u16>,
```

and pass it: `Cmd::Serve { bind, port, stream_port, tasks } => { commands::serve(cfg, bind, port, stream_port, tasks).await?; … }`.

`commands.rs`: `pub async fn serve(cfg: Config, bind: String, port: u16, stream_port: Option<u16>, names: Vec<String>)`. In the `Task::Web` arm, set the WebState fields from the app: `engine: a.rqbit.clone(), streams: a.streams.clone(), stream_public_url: a.cfg.stream_public_url.clone(),`. After the existing `tokio::spawn(supervise("web", …))`, add:

```rust
                if let Some(sp) = stream_port {
                    let state = state.clone();
                    let bind = bind.clone();
                    tokio::spawn(supervise("stream-web", move || {
                        let router = web::stream_router(state.clone());
                        let bind = bind.clone();
                        async move { web::serve(router, &bind, sp).await }
                    }));
                }
                let reaper = a.clone();
                tokio::spawn(supervise("stream-reaper", move || {
                    let a = reaper.clone();
                    async move { reap_streams(&a).await }
                }));
```

(If `state` is moved into the `"web"` closure, clone it into a `web_state` binding first and use `state` here.) Add the function:

```rust
/// Every minute, delete the streams nobody has read for `stream::IDLE_SECS`.
async fn reap_streams(a: &App) -> anyhow::Result<()> {
    let Some(engine) = a.rqbit.as_ref() else {
        return std::future::pending().await;
    };
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(60)).await;
        for id in a.streams.reap(chrono::Utc::now().timestamp()) {
            match engine.delete(id).await {
                Ok(()) => tracing::info!(job = "stream", "reaped idle rqbit torrent {id}"),
                Err(e) => tracing::warn!(job = "stream", "reaping rqbit torrent {id}: {e:#}"),
            }
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cargo test`
Expected: the whole suite PASSES.

- [ ] **Step 5: Gate and commit**

Run: `nix build .#plab`.

```bash
git add packages/plab/src/config.rs packages/plab/src/app.rs packages/plab/src/main.rs packages/plab/src/commands.rs
git commit -m "feat(galactica): plab serves the tailnet stream listener and reaps idle streams"
```

---

### Task 6: Stream button and player modal

**Files:**
- Modify: `packages/plab/src/page.rs` (`card` near line 111, its caller in `render` near line 520, the page shell near line 556), `packages/plab/assets/page.js` (`plabApp`), `packages/plab/src/page_tests.rs`

**Interfaces:**
- Consumes: the JSON from Task 4 (`files`, `selected`, `external`, `stats.{progress,total,mbps,peers}`).
- Produces: `card(…, stream: bool)`; the `#sv` dialog; `plabApp` methods `openStream(id)`, `selectStreamFile(index)`, `pollStream()`, `closeStream()`, `stopStream()`, `copyStreamUrl()`.

- [ ] **Step 1: Write the failing tests** in `page_tests.rs` (next to the other `render` tests; `r(topics)` renders the video list, `tp(i, title)` builds a topic):

```rust
#[test]
fn video_cards_have_a_stream_button() {
    let out = r(vec![tp(5, "[Studio] Name [2026, alpha, 1080p]")]);
    assert!(out.contains(r#"@click="openStream(5)""#));
    assert!(out.contains(r#"<dialog id="sv""#));
    assert!(script(&out).contains("openStream(id)"));
}

#[test]
fn games_cards_have_no_stream_button() {
    let l = listing(1, vec![tp(5, "Some Game")]);
    let out = render(&l, &set(&[]), &set(&[]), 1, None, Section::Games);
    assert!(!out.contains("openStream(5)"));
}
```

If `page_tests.rs` has no free-standing `render`/`set`/`listing` in scope at that point, call `crate::page::render` with the helpers the file already defines (`listing(updated, topics)` near line 54, `set(ids)` near line 50).

- [ ] **Step 2: Run to verify failure**

Run: `cargo test page::tests::video_cards_have_a_stream page::tests::games_cards_have_no`
Expected: the first FAILS (no `openStream`), the second passes.

- [ ] **Step 3: Implement**

`page.rs`: add a `stream: bool` parameter to `card` and, after the existing `let button = format!(…);`:

```rust
    let button = if stream {
        format!(
            r#"{button}<button class="stream btn btn-sm btn-ghost" data-id="{id}" @click="openStream({id})">Stream ▶</button>"#
        )
    } else {
        button
    };
```

In `render`, call `card(t, lab, added, queued, now, add_label, !games)`.

In the page shell, after the `#ov` gallery dialog line and before `"<script>{js}</script></body></html>"`, add:

```rust
            r#"<dialog id="sv" x-ref="streamModal" class="modal" @close="closeStream()">"#,
            r#"<div class="modal-box w-11/12 max-w-5xl p-3">"#,
            r#"<p class="text-error text-sm" x-show="stream.error" x-text="stream.error"></p>"#,
            r#"<video x-ref="player" class="w-full max-h-[70vh] bg-black" controls autoplay :src="stream.src" x-show="stream.src"></video>"#,
            r#"<div class="flex flex-wrap items-center gap-2 mt-2">"#,
            r#"<select class="select select-sm max-w-xs" x-show="stream.files.length > 1" @change="selectStreamFile(+$event.target.value)">"#,
            r#"<template x-for="f in stream.files" :key="f.index"><option :value="f.index" :selected="f.index === stream.selected" x-text="f.name"></option></template></select>"#,
            r#"<span class="text-sm text-base-content/70" x-text="stream.progress"></span>"#,
            r#"<span class="grow"></span>"#,
            r#"<button type="button" class="btn btn-sm" x-show="stream.external" @click="copyStreamUrl()" x-text="stream.copied ? 'Copied ✓' : 'Copy URL for VLC'"></button>"#,
            r#"<button type="button" class="btn btn-sm btn-error" @click="stopStream()">Stop</button>"#,
            r#"</div></div><form method="dialog" class="modal-backdrop"><button>close</button></form></dialog>"#,
```

`assets/page.js`, inside `Alpine.data('plabApp', () => ({ … }))` next to `closeGallery()`:

```js
      stream: {id: null, files: [], selected: null, src: '', external: '', progress: '', error: '', copied: false, started: 0},
      streamTimer: null,

      applyStream(id, j) {
        this.stream.id = id;
        this.stream.files = j.files || [];
        this.stream.selected = j.selected;
        this.stream.src = 'stream/' + id + '/' + j.selected;
        this.stream.external = j.external || '';
      },

      async streamCall(url, opts) {
        const r = await fetch(url, opts);
        let j;
        try {
          j = await r.json();
        } catch (_) {
          throw new Error('HTTP ' + r.status);
        }
        if (!j.ok) throw Object.assign(new Error(j.error), {status: r.status});
        return j;
      },

      async openStream(id) {
        const dlg = this.$refs.streamModal || document.getElementById('sv');
        this.stream = {id, files: [], selected: null, src: '', external: '', progress: 'Starting…', error: '', copied: false, started: Date.now()};
        if (dlg && dlg.showModal) dlg.showModal();
        try {
          this.applyStream(id, await this.streamCall('stream/' + id, {method: 'POST'}));
          clearInterval(this.streamTimer);
          this.streamTimer = setInterval(() => this.pollStream(), 2000);
          this.pollStream();
        } catch (e) {
          this.stream.progress = '';
          this.stream.error = e.message || String(e);
        }
      },

      async selectStreamFile(index) {
        try {
          this.applyStream(this.stream.id, await this.streamCall('stream/' + this.stream.id + '/select/' + index, {method: 'POST'}));
        } catch (e) {
          this.stream.error = e.message || String(e);
        }
      },

      async pollStream() {
        const id = this.stream.id;
        if (id === null) return;
        try {
          const s = (await this.streamCall('stream/' + id)).stats;
          const gib = (b) => (b / 1073741824).toFixed(2) + ' GiB';
          if (s.peers === 0 && Date.now() - this.stream.started > 60000) {
            this.stream.progress = 'no peers yet';
          } else {
            this.stream.progress = gib(s.progress) + ' / ' + gib(s.total) + ' · ' + s.mbps.toFixed(1) + ' MiB/s · ' + s.peers + ' peers';
          }
        } catch (e) {
          if (e.status === 410 || e.status === 404) {
            clearInterval(this.streamTimer);
            this.stream.src = '';
            this.stream.error = e.message + ' — press Stream again';
          }
        }
      },

      closeStream() {
        // Closing the player does not stop the stream: a VLC playback keeps it alive
        // until the idle reaper takes it.
        clearInterval(this.streamTimer);
        if (this.$refs.player) this.$refs.player.pause();
        this.stream.src = '';
        this.stream.id = null;
      },

      async stopStream() {
        const id = this.stream.id;
        const dlg = this.$refs.streamModal || document.getElementById('sv');
        if (dlg && dlg.close) dlg.close();
        if (id !== null) {
          try {
            await fetch('stream/' + id, {method: 'DELETE'});
          } catch (_) {}
        }
      },

      async copyStreamUrl() {
        try {
          await navigator.clipboard.writeText(this.stream.external);
          this.stream.copied = true;
          setTimeout(() => (this.stream.copied = false), 2000);
        } catch (_) {
          window.prompt('Stream URL', this.stream.external);
        }
      },
```

Note: `stopStream` reads `this.stream.id` before closing, because `@close` runs `closeStream()`, which clears it.

- [ ] **Step 4: Run tests**

Run: `cargo test page::`
Expected: all PASS. If an existing test compares the whole rendered shell against a fixed string, update that expectation to include the new dialog markup.

- [ ] **Step 5: Gate and commit**

Run: `nix build .#plab`.

```bash
git add packages/plab/src/page.rs packages/plab/src/page_tests.rs packages/plab/assets/page.js
git commit -m "feat(galactica): plab stream button and player"
```

---

### Task 7: NixOS — `plab-stream` unit, port mapping, tailnet node

**Files:**
- Modify: `modules/hosts/galactica/services/plab/default.nix`

**Interfaces:**
- Consumes: `plab serve --stream-port`, env `PLAB_RQBIT_URL`, `PLAB_STREAM_PUBLIC_URL` (Task 5).
- Produces: `plab-stream.service`, `https://plab-stream.bat-boa.ts.net/stream/<topic>/<file>`.

- [ ] **Step 1: Edit the module.** In the `let` block add:

```nix
    pia = config.constellation.pia;
    # rqbit's API, inside the PIA namespace (3030 is loki's).
    streamApiPort = 3031;
    # plab's GET-only stream listener, behind the plab-stream tailnet node.
    streamPort = 8578;
    # Scratch for streamed media: emptied on every plab-stream start.
    streamDir = "${vars.storageDir}/media/Downloads/.plab-stream";
```

In the `plab` wrapper script, after `PLAB_PROWLARR_CONFIG`:

```nix
        # The stream engine, straight into the PIA namespace like Transmission.
        export PLAB_RQBIT_URL="http://${pia.namespaceAddress}:${toString streamApiPort}"
        export PLAB_STREAM_PUBLIC_URL="https://plab-stream.${vars.tsDomain}"
```

Change `ExecStart` to `"${plab}/bin/plab serve --bind 127.0.0.1 --port ${toString port} --stream-port ${toString streamPort}"`, and add `"plab-stream.service"` to both `after` and `wants` of `systemd.services.plab`.

Add, beside `systemd.services.plab`:

```nix
    # The stream engine's API, reachable from the host at the namespace address.
    vpnNamespaces.${pia.namespace}.portMappings = [
      {
        from = streamApiPort;
        to = streamApiPort;
        protocol = "tcp";
      }
    ];

    # rqbit for plab's Stream button: peer traffic inside the PIA namespace, outbound only
    # (Transmission keeps PIA's one forwarded port), nothing kept. PartOf plab, so a plab
    # restart empties it and the two never disagree about which streams exist.
    systemd.services.plab-stream = {
      description = "plab-stream: rqbit streaming engine for plab (PIA namespace, no persistence)";
      wantedBy = ["multi-user.target"];
      partOf = ["plab.service"];
      before = ["plab.service"];
      after = ["mnt-storage.mount"];
      requires = ["mnt-storage.mount"];
      vpnConfinement = {
        enable = true;
        vpnNamespace = pia.namespace;
      };
      environment.XDG_CACHE_HOME = "/var/cache/plab-stream"; # rqbit's DHT state
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "plab-stream-scratch" ''
          rm -rf -- '${streamDir}'
          mkdir -p -- '${streamDir}'
        '';
        ExecStart = lib.concatStringsSep " " [
          "${pkgs.rqbit}/bin/rqbit"
          "--http-api-listen-addr ${pia.namespaceAddress}:${toString streamApiPort}"
          "--disable-tcp-listen"
          "--disable-upnp-port-forward"
          "server start --disable-persistence ${streamDir}"
        ];
        User = vars.user;
        Group = vars.group;
        CacheDirectory = "plab-stream";
        Restart = "always";
        RestartSec = "10s";
      };
    };

    # VLC's way in: tailnet only, plab's GET-only stream listener, no Authelia.
    services.tsnsrv.services.plab-stream = {
      toURL = "http://127.0.0.1:${toString streamPort}";
      prefixes = ["/stream/"];
      stripPrefix = false;
      funnel = false;
    };
```

Add `lib` to the module's argument set (`{config, pkgs, lib, ...}`). Extend the header comment with one paragraph: streaming via `plab-stream` (rqbit in the PIA namespace), the tailnet node, the scratch dir, `torrent_file` keeping every grabbed `.torrent`, and the design doc path `docs/superpowers/specs/2026-11-02-plab-streaming-design.md`.

- [ ] **Step 2: Check the option paths evaluate**

Run (repo root):
`nix eval --json .#nixosConfigurations.galactica.config.systemd.services.plab-stream.serviceConfig.ExecStart`
Expected: the rqbit command line with `10.x.x.x:3031` (PIA namespace address) and the scratch path.

Run: `nix eval --json .#nixosConfigurations.galactica.config.vpnNamespaces --apply 'v: map (m: m.from) v.${"<ns>"}.portMappings'` with `<ns>` replaced by the value of `nix eval --raw .#nixosConfigurations.galactica.config.constellation.pia.namespace`.
Expected: a list containing both `9091` and `3031`.

- [ ] **Step 3: Build galactica**

Run: `just fmt && nix build .#nixosConfigurations.galactica.config.system.build.toplevel`
Expected: builds. (One host only; never evaluate hosts in parallel.)

- [ ] **Step 4: Commit**

```bash
git add modules/hosts/galactica/services/plab/default.nix
git commit -m "feat(galactica): plab-stream rqbit engine in the PIA namespace and its tailnet node"
```

---

### Task 8: Deploy and verify on galactica

Deploying is outward-facing: ask the user before running it.

- [ ] **Step 1: Push and deploy** (after the user agrees): `git push -u origin master && just deploy galactica`.

- [ ] **Step 2: Units up, scratch empty**

Run: `ssh galactica.bat-boa.ts.net 'systemctl is-active plab plab-stream; sudo ls -A /mnt/storage/media/Downloads/.plab-stream | wc -l; sudo -u media sqlite3 /var/lib/plab/state.db "PRAGMA user_version"'`
Expected: `active`, `active`, `0`, `3`.

- [ ] **Step 3: Peer traffic is in the namespace.** Run: `ssh galactica.bat-boa.ts.net 'sudo ss -tnp | grep rqbit | head'` from the host namespace.
Expected: no rqbit sockets in the host namespace (they live in the PIA netns: `sudo ip netns exec <ns> ss -tnp | grep rqbit` shows them).

- [ ] **Step 4: Manual playback** — ask the user to: press Stream on a well-seeded mp4 at `https://plab.arsfeld.one`, seek to the middle within seconds, copy the URL and play it in VLC on raider, press Stop. Then confirm `.plab-stream` is empty again (Step 2's command) and `SELECT topic_id FROM torrent_file` lists the topic.

- [ ] **Step 5: Restart wipes.** Start a stream, then `ssh galactica.bat-boa.ts.net 'sudo systemctl restart plab'`; confirm `plab-stream` restarted (`systemctl show -p ActiveEnterTimestamp plab-stream`) and the scratch dir is empty.
