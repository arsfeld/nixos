//! rqbit's HTTP API: the stream-only engine plab-stream.service runs in the PIA namespace.
//! plab adds one file of a torrent, proxies rqbit's range-aware stream endpoint, and
//! deletes the torrent with its files when the stream ends.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use axum::body::Body;
use serde::Deserialize;

use crate::transmission::TorrentSource;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);

/// rqbit fetches a magnet's metadata from peers before it can list the files; past this,
/// the swarm is taken to have no peers.
const MAGNET_LIST_TIMEOUT: Duration = Duration::from_secs(120);

/// A magnet whose metadata no peer sent within `MAGNET_LIST_TIMEOUT`.
#[derive(Debug, thiserror::Error)]
#[error("no peers for metadata")]
pub struct NoMetadata;

fn body(torrent: &TorrentSource) -> Vec<u8> {
    match torrent {
        TorrentSource::Bytes(b) => b.clone(),
        TorrentSource::Magnet(m) => m.as_bytes().to_vec(),
    }
}

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
    /// rqbit's torrent state: "initializing", "live", "paused" or "error".
    pub state: String,
    pub error: Option<String>,
}

/// A stream response to pass through: status, the range headers, and the body.
pub struct Upstream {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Body,
}

/// rqbit answered 404 for this info hash: it restarted on its own, or it was deleted.
#[derive(Debug, thiserror::Error)]
#[error("torrent {0} is gone from the stream engine")]
pub struct Gone(pub String);

/// rqbit answered 409 to an add: it already manages this info hash (a torrent whose
/// delete failed and is still queued, say).
#[derive(Debug, thiserror::Error)]
#[error("the stream engine already has this torrent: {0}")]
pub struct AlreadyManaged(pub String);

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
    details: Details,
}

#[derive(Deserialize)]
struct Details {
    #[serde(default)]
    info_hash: Option<String>,
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
    state: String,
    error: Option<String>,
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
        Rqbit {
            base: base.trim_end_matches('/').to_string(),
            // The same settings as `crate::http::client(60)`, plus a connect timeout: an
            // engine that does not answer fails the start in seconds, not minutes.
            http: reqwest::Client::builder()
                .use_rustls_tls()
                .redirect(reqwest::redirect::Policy::none())
                .timeout(Duration::from_secs(60))
                .connect_timeout(CONNECT_TIMEOUT)
                .build()
                .expect("the HTTP client's static configuration is valid"),
            stream_http: reqwest::Client::builder()
                .connect_timeout(CONNECT_TIMEOUT)
                .build()
                .expect("the stream client's static configuration is valid"),
        }
    }

    fn url(&self, path: &str) -> String {
        format!("{}/{path}", self.base)
    }

    async fn post_torrent(
        &self,
        torrent: &TorrentSource,
        query: &[(&str, String)],
    ) -> Result<AddReply> {
        let magnet = matches!(torrent, TorrentSource::Magnet(_));
        let mut req = self
            .http
            .post(self.url("torrents"))
            .query(query)
            .body(body(torrent));
        if magnet {
            req = req.timeout(MAGNET_LIST_TIMEOUT);
        }
        let resp = match req.send().await {
            Ok(r) => r,
            // A connect timeout is a timeout too, and means the engine is down.
            Err(e) if e.is_timeout() && !e.is_connect() && magnet => {
                return Err(NoMetadata.into());
            }
            Err(e) => return Err(anyhow::Error::new(e).context("rqbit unreachable")),
        };
        Ok(checked(resp, None).await?.json().await?)
    }

    pub async fn list(&self, torrent: &TorrentSource) -> Result<Vec<EngineFile>> {
        let reply = self
            .post_torrent(torrent, &[("list_only", "true".into())])
            .await?;
        Ok(reply
            .details
            .files
            .unwrap_or_default()
            .into_iter()
            .enumerate()
            .map(|(index, f)| EngineFile {
                index,
                name: f.name,
                length: f.length,
            })
            .collect())
    }

    /// Add the torrent fetching only `file`; its info hash, which names it from then on.
    /// Never rqbit's numeric id: without persistence a restarted rqbit counts from 1 again,
    /// so an old id can name someone else's torrent. A hash names only this one.
    pub async fn add(&self, torrent: &TorrentSource, file: usize) -> Result<String> {
        let reply = self
            .post_torrent(
                torrent,
                &[
                    ("only_files", file.to_string()),
                    ("overwrite", "true".into()),
                ],
            )
            .await?;
        reply
            .details
            .info_hash
            .context("rqbit added the torrent without an info hash")
    }

    pub async fn select(&self, id: &str, file: usize) -> Result<()> {
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

    pub async fn stats(&self, id: &str) -> Result<EngineStats> {
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
            state: raw.state,
            error: raw.error,
        })
    }

    pub async fn delete(&self, id: &str) -> Result<()> {
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

    pub async fn open(&self, id: &str, file: usize, range: Option<&str>) -> Result<Upstream> {
        let mut req = self
            .stream_http
            .get(self.url(&format!("torrents/{id}/stream/{file}")));
        if let Some(r) = range {
            req = req.header(reqwest::header::RANGE, r);
        }
        let resp = req.send().await.context("rqbit unreachable")?;
        if resp.status() == reqwest::StatusCode::NOT_FOUND {
            return Err(Gone(id.to_string()).into());
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
}

/// A 2xx response, `Gone` for a 404 on a torrent, `AlreadyManaged` for a 409, an error
/// carrying rqbit's body otherwise.
async fn checked(resp: reqwest::Response, id: Option<&str>) -> Result<reqwest::Response> {
    let status = resp.status();
    if status.is_success() {
        return Ok(resp);
    }
    if let (reqwest::StatusCode::NOT_FOUND, Some(id)) = (status, id) {
        return Err(Gone(id.to_string()).into());
    }
    let body = resp.text().await.unwrap_or_default();
    if status == reqwest::StatusCode::CONFLICT {
        return Err(AlreadyManaged(body.trim().to_string()).into());
    }
    bail!("rqbit {status}: {}", body.trim())
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
        "info_hash": "aa4", "name": "Rel", "output_folder": "/s",
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
        let files = Rqbit::new(&s.uri())
            .list(&TorrentSource::Bytes(b"d4:infoe".to_vec()))
            .await
            .unwrap();
        assert_eq!(
            files,
            vec![
                EngineFile {
                    index: 0,
                    name: "Rel/sample.mp4".into(),
                    length: 10
                },
                EngineFile {
                    index: 1,
                    name: "Rel/movie.mkv".into(),
                    length: 900
                },
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
        assert_eq!(
            Rqbit::new(&s.uri())
                .add(&TorrentSource::Bytes(b"t".to_vec()), 1)
                .await
                .unwrap(),
            "aa4"
        );
    }

    #[tokio::test]
    async fn a_magnet_is_sent_as_the_body() {
        let server = MockServer::start().await;
        let magnet = "magnet:?xt=urn:btih:0000000000000000000000000000000000000000&dn=x";
        Mock::given(method("POST"))
            .and(path("/torrents"))
            .and(wiremock::matchers::body_string(magnet))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "details": {"info_hash": "h", "files": [{"name": "a.mp4", "length": 5}]}})))
            .mount(&server)
            .await;
        let r = Rqbit::new(&server.uri());
        let src = TorrentSource::Magnet(magnet.into());
        assert_eq!(r.list(&src).await.unwrap()[0].name, "a.mp4");
        assert_eq!(r.add(&src, 0).await.unwrap(), "h");
    }

    #[tokio::test]
    async fn a_409_on_add_is_already_managed() {
        let s = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/torrents"))
            .respond_with(
                ResponseTemplate::new(409).set_body_string("aa4 is already managed, id=1"),
            )
            .mount(&s)
            .await;
        let e = Rqbit::new(&s.uri())
            .add(&TorrentSource::Bytes(b"t".to_vec()), 1)
            .await
            .unwrap_err();
        assert!(e.downcast_ref::<AlreadyManaged>().is_some(), "{e:#}");
        assert!(e.downcast_ref::<Gone>().is_none());
    }

    #[tokio::test]
    async fn select_replaces_only_files() {
        let s = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path("/torrents/aa4/update_only_files"))
            .and(body_json(json!({"only_files": [0]})))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({})))
            .expect(1)
            .mount(&s)
            .await;
        Rqbit::new(&s.uri()).select("aa4", 0).await.unwrap();
    }

    #[tokio::test]
    async fn stats_decode_with_and_without_live() {
        let s = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/torrents/aa4/stats/v1"))
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
            .and(path("/torrents/aa5/stats/v1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "state": "initializing", "file_progress": [], "error": null,
                "progress_bytes": 0, "uploaded_bytes": 0, "total_bytes": 900,
                "finished": false, "live": null
            })))
            .mount(&s)
            .await;
        let r = Rqbit::new(&s.uri());
        assert_eq!(
            r.stats("aa4").await.unwrap(),
            EngineStats {
                progress: 300,
                total: 900,
                finished: false,
                mbps: 2.5,
                peers: 7,
                state: "live".into(),
                error: None,
            }
        );
        let init = r.stats("aa5").await.unwrap();
        assert_eq!(init.peers, 0);
        assert_eq!(init.state, "initializing");
        assert_eq!(init.error, None);
    }

    #[tokio::test]
    async fn stats_carry_rqbits_error() {
        let s = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/torrents/aa6/stats/v1"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "state": "error", "error": "disk full",
                "progress_bytes": 0, "total_bytes": 9, "finished": false, "live": null
            })))
            .mount(&s)
            .await;
        let st = Rqbit::new(&s.uri()).stats("aa6").await.unwrap();
        assert_eq!(st.state, "error");
        assert_eq!(st.error.as_deref(), Some("disk full"));
    }

    #[tokio::test]
    async fn an_unreachable_engine_fails_fast() {
        let r = Rqbit::new("http://10.255.255.1:9");
        let e = tokio::time::timeout(
            Duration::from_secs(10),
            r.list(&TorrentSource::Bytes(b"t".to_vec())),
        )
        .await
        .expect("the connect timeout bounds the wait")
        .unwrap_err();
        assert!(format!("{e:#}").contains("rqbit unreachable"), "{e:#}");
    }

    /// An engine that never answers a magnet start is "rqbit unreachable", never "no peers
    /// for metadata": reqwest calls a connect timeout a timeout too.
    #[tokio::test]
    async fn an_unreachable_engine_on_a_magnet_is_not_no_metadata() {
        let magnet = TorrentSource::Magnet("magnet:?xt=urn:btih:00".into());
        for base in ["http://127.0.0.1:1", "http://10.255.255.1:9"] {
            let e = tokio::time::timeout(Duration::from_secs(10), Rqbit::new(base).list(&magnet))
                .await
                .expect("the connect timeout bounds the wait")
                .unwrap_err();
            assert!(e.downcast_ref::<NoMetadata>().is_none(), "{base}: {e:#}");
            assert!(
                format!("{e:#}").contains("rqbit unreachable"),
                "{base}: {e:#}"
            );
        }
    }

    #[tokio::test]
    async fn a_404_is_gone_and_delete_tolerates_it() {
        let s = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/torrents/aa9/stats/v1"))
            .respond_with(ResponseTemplate::new(404).set_body_string("torrent aa9 not found"))
            .mount(&s)
            .await;
        Mock::given(method("POST"))
            .and(path("/torrents/aa9/delete"))
            .respond_with(ResponseTemplate::new(404))
            .expect(1)
            .mount(&s)
            .await;
        let r = Rqbit::new(&s.uri());
        let e = r.stats("aa9").await.unwrap_err();
        assert!(e.downcast_ref::<Gone>().is_some(), "{e:#}");
        r.delete("aa9").await.unwrap();
    }

    #[tokio::test]
    async fn open_forwards_range_and_passes_range_headers_back() {
        let s = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/torrents/aa4/stream/1"))
            .and(header("range", "bytes=2-5"))
            .respond_with(
                ResponseTemplate::new(206)
                    .insert_header("content-range", "bytes 2-5/900")
                    .insert_header("accept-ranges", "bytes")
                    .set_body_bytes(b"abcd".to_vec()),
            )
            .mount(&s)
            .await;
        let up = Rqbit::new(&s.uri())
            .open("aa4", 1, Some("bytes=2-5"))
            .await
            .unwrap();
        assert_eq!(up.status, 206);
        assert!(
            up.headers
                .contains(&("content-range".into(), "bytes 2-5/900".into()))
        );
        assert!(
            up.headers
                .contains(&("accept-ranges".into(), "bytes".into()))
        );
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
        let e = Rqbit::new(&s.uri())
            .list(&TorrentSource::Bytes(b"t".to_vec()))
            .await
            .unwrap_err();
        assert!(e.downcast_ref::<Gone>().is_none());
        assert!(format!("{e:#}").contains("disk full"));
    }
}
