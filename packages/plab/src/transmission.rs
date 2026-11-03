//! Transmission RPC: `torrent-add` (bytes or magnet), `torrent-get` and `torrent-remove`,
//! including its CSRF session-id handshake.

use std::future::Future;
use std::sync::Mutex;

use anyhow::{Result, anyhow, bail};
use base64::Engine;
use serde_json::{Value, json};

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

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TrackerAnnounce {
    #[serde(default)]
    pub announce: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Torrent {
    pub id: i64,
    pub name: String,
    #[serde(default)]
    pub hash_string: String,
    pub download_dir: String,
    pub percent_done: f64,
    pub upload_ratio: f64,
    pub done_date: i64,
    pub activity_date: i64,
    #[serde(default)]
    pub trackers: Vec<TrackerAnnounce>,
}

#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TorrentFile {
    /// Relative to the torrent's downloadDir. The logical name: the RPC never shows the
    /// `.part` suffix an unfinished file has on disk, so `bytes_completed` says whether it
    /// is complete.
    pub name: String,
    #[serde(default)]
    pub length: i64,
    #[serde(default)]
    pub bytes_completed: i64,
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

pub enum TorrentSource {
    Bytes(Vec<u8>),
    Magnet(String),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Added {
    pub name: String,
    pub hash: Option<String>,
}

pub trait TorrentClient: Send + Sync {
    /// Add a torrent; a duplicate is not an error.
    fn add(
        &self,
        src: &TorrentSource,
        download_dir: &str,
    ) -> impl Future<Output = Result<Added>> + Send;
    /// Every torrent in the client, with FIELDS.
    fn torrents(&self) -> impl Future<Output = Result<Vec<Torrent>>> + Send;
    /// The torrents with these hashes that are still in the client. Unknown hashes are
    /// simply absent from the reply.
    fn details(&self, _hashes: &[String]) -> impl Future<Output = Result<Vec<Detail>>> + Send {
        async { Ok(Vec::new()) }
    }
    /// Take torrents out of the client. Their data stays on disk.
    fn remove(&self, ids: &[i64]) -> impl Future<Output = Result<()>> + Send;
}

pub struct Transmission {
    http: reqwest::Client,
    url: String,
    session: Mutex<String>,
}

impl Transmission {
    pub fn new(url: &str) -> Transmission {
        Transmission {
            http: crate::http::client(30),
            url: url.to_string(),
            session: Mutex::new(String::new()),
        }
    }

    /// One RPC call; return its reply's `arguments`.
    async fn call(&self, method: &str, arguments: Value) -> Result<Value> {
        let body = json!({"method": method, "arguments": arguments});
        // The first request is answered 409 with the session id to send on the second.
        for _ in 0..2 {
            let session = self.session.lock().unwrap().clone();
            let resp = self
                .http
                .post(&self.url)
                .header("X-Transmission-Session-Id", session)
                .json(&body)
                .send()
                .await?;
            let status = resp.status();
            if status.as_u16() == 409 {
                let id = resp
                    .headers()
                    .get("X-Transmission-Session-Id")
                    .and_then(|v| v.to_str().ok())
                    .unwrap_or("")
                    .to_string();
                *self.session.lock().unwrap() = id;
                continue;
            }
            if !status.is_success() {
                bail!("HTTP {}", status.as_u16());
            }
            let mut reply: Value = resp.json().await?;
            match reply.get("result").and_then(Value::as_str) {
                Some("success") => {}
                Some(other) => bail!("{other}"),
                None => bail!("no result"),
            }
            return Ok(reply
                .get_mut("arguments")
                .map(Value::take)
                .unwrap_or_else(|| json!({})));
        }
        Err(anyhow!("no session id after 409"))
    }
}

impl TorrentClient for Transmission {
    async fn add(&self, src: &TorrentSource, download_dir: &str) -> Result<Added> {
        let mut args = match src {
            TorrentSource::Magnet(m) => json!({"filename": m}),
            TorrentSource::Bytes(b) => {
                json!({"metainfo": base64::engine::general_purpose::STANDARD.encode(b)})
            }
        };
        args["download-dir"] = json!(download_dir);
        let reply = self.call("torrent-add", args).await?;
        /// The torrent a `torrent-add` reply names, whether new or already present.
        #[derive(serde::Deserialize, Default)]
        #[serde(rename_all = "camelCase")]
        struct Reply {
            #[serde(default)]
            name: Option<String>,
            #[serde(default)]
            hash_string: Option<String>,
        }
        let t = ["torrent-added", "torrent-duplicate"]
            .iter()
            .filter_map(|k| reply.get(k).filter(|v| !v.is_null()))
            .next();
        let t: Reply = t
            .and_then(|t| serde_json::from_value(t.clone()).ok())
            .unwrap_or_default();
        Ok(Added {
            name: t.name.unwrap_or_default(),
            hash: t.hash_string,
        })
    }

    async fn torrents(&self) -> Result<Vec<Torrent>> {
        let mut reply = self.call("torrent-get", json!({"fields": FIELDS})).await?;
        let list = reply
            .get_mut("torrents")
            .map(Value::take)
            .ok_or_else(|| anyhow!("no torrents in reply"))?;
        Ok(serde_json::from_value(list)?)
    }

    async fn details(&self, hashes: &[String]) -> Result<Vec<Detail>> {
        if hashes.is_empty() {
            return Ok(vec![]); // an empty ids list means every torrent
        }
        let mut reply = self
            .call(
                "torrent-get",
                json!({"ids": hashes, "fields": DETAIL_FIELDS}),
            )
            .await?;
        let list = reply
            .get_mut("torrents")
            .map(Value::take)
            .ok_or_else(|| anyhow!("no torrents in reply"))?;
        Ok(serde_json::from_value(list)?)
    }

    async fn remove(&self, ids: &[i64]) -> Result<()> {
        self.call(
            "torrent-remove",
            json!({"ids": ids, "delete-local-data": false}),
        )
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::method;
    use wiremock::{Mock, MockServer, Request, ResponseTemplate};

    /// Transmission's RPC: 409 plus a session id until the client echoes it back.
    async fn stub(reply: Value) -> MockServer {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(move |req: &Request| {
                let ok = req
                    .headers
                    .get("X-Transmission-Session-Id")
                    .is_some_and(|v| v == "abc");
                if ok {
                    ResponseTemplate::new(200).set_body_json(reply.clone())
                } else {
                    ResponseTemplate::new(409).insert_header("X-Transmission-Session-Id", "abc")
                }
            })
            .mount(&server)
            .await;
        server
    }

    fn sent(server: &MockServer, i: usize) -> (String, Value) {
        let reqs = futures::executor::block_on(server.received_requests()).unwrap();
        let r = &reqs[i];
        let sid = r
            .headers
            .get("X-Transmission-Session-Id")
            .map(|v| v.to_str().unwrap().to_string())
            .unwrap_or_default();
        (sid, serde_json::from_slice(&r.body).unwrap())
    }

    #[tokio::test]
    async fn handshake_then_add() {
        let s = stub(json!({"result": "success", "arguments": {"torrent-added":
            {"name": "Some Release", "id": 7, "hashString": "abcd"}}}))
        .await;
        let t = Transmission::new(&s.uri());
        let added = t
            .add(
                &TorrentSource::Bytes(b"d4:infoe".to_vec()),
                "/mnt/storage/media/Downloads/Vault",
            )
            .await
            .unwrap();
        assert_eq!(
            added,
            Added {
                name: "Some Release".into(),
                hash: Some("abcd".into())
            }
        );
        assert_eq!(s.received_requests().await.unwrap().len(), 2);
        let (sid, body) = sent(&s, 1);
        assert_eq!(sid, "abc");
        assert_eq!(body["method"], "torrent-add");
        let meta = base64::engine::general_purpose::STANDARD
            .decode(body["arguments"]["metainfo"].as_str().unwrap())
            .unwrap();
        assert_eq!(meta, b"d4:infoe");
        assert_eq!(
            body["arguments"]["download-dir"],
            "/mnt/storage/media/Downloads/Vault"
        );
    }

    #[tokio::test]
    async fn session_id_is_remembered_for_later_calls() {
        let s = stub(json!({"result": "success", "arguments": {}})).await;
        let t = Transmission::new(&s.uri());
        t.remove(&[1]).await.unwrap();
        t.remove(&[2]).await.unwrap();
        // 409 + retry, then a single request.
        assert_eq!(s.received_requests().await.unwrap().len(), 3);
    }

    #[tokio::test]
    async fn duplicate_is_success() {
        let s = stub(
            json!({"result": "success", "arguments": {"torrent-duplicate": {"name": "Old Release"}}}),
        )
        .await;
        let added = Transmission::new(&s.uri())
            .add(&TorrentSource::Bytes(b"d4:infoe".to_vec()), "/x")
            .await
            .unwrap();
        assert_eq!(added.name, "Old Release");
        assert_eq!(added.hash, None);
    }

    #[tokio::test]
    async fn magnet_is_sent_as_filename() {
        let s = stub(
            json!({"result": "success", "arguments": {"torrent-added": {"name": "Magnet Release"}}}),
        )
        .await;
        let magnet = "magnet:?xt=urn:btih:836EDDB16DC9A43927DAA5A83F2726513069B41A&dn=x";
        let added = Transmission::new(&s.uri())
            .add(&TorrentSource::Magnet(magnet.into()), "/x")
            .await
            .unwrap();
        assert_eq!(added.name, "Magnet Release");
        let (_, body) = sent(&s, 1);
        assert_eq!(body["arguments"]["filename"], magnet);
        assert!(body["arguments"].get("metainfo").is_none());
        assert_eq!(body["arguments"]["download-dir"], "/x");
    }

    #[tokio::test]
    async fn failure_result_raises() {
        let s = stub(json!({"result": "invalid or corrupt torrent file", "arguments": {}})).await;
        let e = Transmission::new(&s.uri())
            .add(&TorrentSource::Bytes(b"junk".to_vec()), "/x")
            .await
            .unwrap_err();
        assert!(e.to_string().contains("invalid or corrupt"), "{e}");
    }

    #[tokio::test]
    async fn torrents_lists_with_fields() {
        let s = stub(json!({"result": "success", "arguments": {"torrents": [{
            "id": 1, "name": "A", "hashString": "h1", "downloadDir": "/d", "percentDone": 1.0, "uploadRatio": 0.5,
            "doneDate": 3, "activityDate": 4,
            "trackers": [{"announce": "http://x/a", "id": 0}]}]}}))
        .await;
        let list = Transmission::new(&s.uri()).torrents().await.unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].id, 1);
        assert_eq!(list[0].name, "A");
        assert_eq!(list[0].hash_string, "h1");
        assert_eq!(list[0].trackers[0].announce, "http://x/a");
        let (_, body) = sent(&s, 1);
        assert_eq!(body["method"], "torrent-get");
        assert!(
            body["arguments"]["fields"]
                .as_array()
                .unwrap()
                .contains(&json!("trackers"))
        );
    }

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
        assert_eq!(
            (got[0].files[0].length, got[0].files[0].bytes_completed),
            (5, 5)
        );
        let (_, body) = sent(&s, 1);
        assert_eq!(body["method"], "torrent-get");
        assert_eq!(body["arguments"]["ids"], json!(["abcd"]));
        assert!(
            body["arguments"]["fields"]
                .as_array()
                .unwrap()
                .contains(&json!("files"))
        );
    }

    #[tokio::test]
    async fn details_of_no_hashes_makes_no_call() {
        // torrent-get with an empty ids list would answer every torrent.
        let s = stub(json!({"result": "success", "arguments": {"torrents": []}})).await;
        assert!(
            Transmission::new(&s.uri())
                .details(&[])
                .await
                .unwrap()
                .is_empty()
        );
        assert!(s.received_requests().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn remove_keeps_data() {
        let s = stub(json!({"result": "success", "arguments": {}})).await;
        Transmission::new(&s.uri()).remove(&[3, 4]).await.unwrap();
        let (_, body) = sent(&s, 1);
        assert_eq!(body["method"], "torrent-remove");
        assert_eq!(
            body["arguments"],
            json!({"ids": [3, 4], "delete-local-data": false})
        );
    }

    #[tokio::test]
    async fn http_error_and_missing_session_id() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(500))
            .mount(&server)
            .await;
        let e = Transmission::new(&server.uri())
            .remove(&[1])
            .await
            .unwrap_err();
        assert_eq!(e.to_string(), "HTTP 500");

        let always409 = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(
                ResponseTemplate::new(409).insert_header("X-Transmission-Session-Id", "z"),
            )
            .mount(&always409)
            .await;
        let e = Transmission::new(&always409.uri())
            .remove(&[1])
            .await
            .unwrap_err();
        assert_eq!(e.to_string(), "no session id after 409");
    }
}
