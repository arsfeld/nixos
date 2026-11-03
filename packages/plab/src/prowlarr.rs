//! Prowlarr: the API key from its config.xml, search, and fetching a result's torrent.

use std::path::Path;
use std::time::Duration;

use anyhow::{Context, Result, bail};

use crate::transmission::TorrentSource;

/// Prowlarr's API key, from its own config.xml: no second copy to drift.
pub fn api_key(config_xml: &Path) -> Result<String> {
    let text = std::fs::read_to_string(config_xml)
        .with_context(|| format!("reading {}", config_xml.display()))?;
    let re = regex::Regex::new(r"<ApiKey>([^<]+)</ApiKey>").unwrap();
    match re.captures(&text) {
        Some(c) => Ok(c[1].to_string()),
        None => bail!("no <ApiKey> in {}", config_xml.display()),
    }
}

/// One Prowlarr search result. Fields grab cannot do without are optional here, so one
/// malformed result is skipped (see `grab::skip_reason`) rather than failing the search.
#[derive(Debug, Clone, Default, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProwlarrResult {
    #[serde(default, deserialize_with = "crate::stash::de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::nonempty")]
    pub protocol: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::nonempty")]
    pub publish_date: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::nonempty")]
    pub download_url: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::nonempty")]
    pub indexer: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::lenient_f64")]
    pub seeders: Option<f64>,
    #[serde(default, deserialize_with = "crate::stash::de::nonempty")]
    pub guid: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::nonempty")]
    pub info_url: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::lenient_f64")]
    pub leechers: Option<f64>,
    #[serde(default, deserialize_with = "crate::stash::de::lenient_f64")]
    pub size: Option<f64>,
}

impl ProwlarrResult {
    pub fn title(&self) -> &str {
        self.title.as_deref().unwrap_or("?")
    }
}

/// One of Prowlarr's configured indexers, as the curated job chooses among them.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
pub struct Indexer {
    pub id: u32,
    pub name: String,
    #[serde(default)]
    pub enable: bool,
    #[serde(default)]
    pub protocol: String,
}

pub struct Prowlarr {
    http: reqwest::Client,
    base: String,
    key: String,
}

impl Prowlarr {
    pub fn new(base: &str, key: String) -> Prowlarr {
        Prowlarr {
            http: crate::http::client(300),
            base: base.trim_end_matches('/').to_string(),
            key,
        }
    }

    async fn get<R: serde::de::DeserializeOwned>(&self, path_and_query: &str) -> Result<R> {
        let resp = self
            .http
            .get(format!("{}{path_and_query}", self.base))
            .header("X-Api-Key", &self.key)
            .send()
            .await
            .map_err(reqwest::Error::without_url)?
            .error_for_status()
            .map_err(reqwest::Error::without_url)?;
        Ok(resp.json().await.map_err(reqwest::Error::without_url)?)
    }

    /// Prowlarr's results for `query` across every enabled indexer.
    pub async fn search(&self, query: &str) -> Result<Vec<ProwlarrResult>> {
        self.search_in(query, &[], &[]).await
    }

    /// Results for `query` limited to `categories` and `indexer_ids` (each empty: no limit).
    pub async fn search_in(
        &self,
        query: &str,
        categories: &[u32],
        indexer_ids: &[u32],
    ) -> Result<Vec<ProwlarrResult>> {
        // Built in its own block: the serializer holds a non-Send encoder closure, so it
        // must be dropped before the await.
        let qs = {
            let mut qs = form_urlencoded::Serializer::new(String::new());
            qs.append_pair("query", query)
                .append_pair("type", "search")
                .append_pair("limit", "100");
            for c in categories {
                qs.append_pair("categories", &c.to_string());
            }
            for i in indexer_ids {
                qs.append_pair("indexerIds", &i.to_string());
            }
            qs.finish()
        };
        self.get(&format!("/api/v1/search?{qs}")).await
    }

    pub async fn indexers(&self) -> Result<Vec<Indexer>> {
        self.get("/api/v1/indexer").await
    }

    /// A result's torrent: .torrent bytes, or the magnet link Prowlarr redirects to.
    pub async fn fetch(&self, url: &str) -> Result<TorrentSource> {
        let resp = self
            .http
            .get(url)
            .timeout(Duration::from_secs(120))
            .send()
            .await
            .map_err(reqwest::Error::without_url)?;
        let status = resp.status();
        if status.is_redirection() {
            let location = resp
                .headers()
                .get("Location")
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            if location.starts_with("magnet:") {
                return Ok(TorrentSource::Magnet(location.to_string()));
            }
        }
        if !status.is_success() {
            bail!("HTTP {}", status.as_u16());
        }
        let data = resp.bytes().await.map_err(reqwest::Error::without_url)?;
        if !data.starts_with(b"d") {
            bail!("not a .torrent ({:?})", &data[..data.len().min(40)]);
        }
        Ok(TorrentSource::Bytes(data.to_vec()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn config(body: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("config.xml");
        std::fs::write(&p, body).unwrap();
        (d, p)
    }

    #[test]
    fn wrong_typed_fields_do_not_fail_the_whole_search() {
        let results: Vec<ProwlarrResult> = serde_json::from_str(
            r#"[{"title":"ok","protocol":"torrent"},
                {"title":123,"protocol":{"x":1}},
                {"title":"also ok","protocol":"torrent","indexer":"i"}]"#,
        )
        .unwrap();
        assert_eq!(results[0].title.as_deref(), Some("ok"));
        assert_eq!(results[1].protocol, None);
        assert_eq!(results[2].indexer.as_deref(), Some("i"));
    }

    #[test]
    fn reads_config_xml() {
        let (_d, p) =
            config("<Config>\n  <Port>9696</Port>\n  <ApiKey>abc123</ApiKey>\n</Config>\n");
        assert_eq!(api_key(&p).unwrap(), "abc123");
    }

    #[test]
    fn missing() {
        let (_d, p) = config("<Config></Config>");
        assert!(api_key(&p).unwrap_err().to_string().contains("no <ApiKey>"));
    }

    async fn server() -> MockServer {
        let s = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/magnet"))
            .respond_with(
                ResponseTemplate::new(301)
                    .insert_header("Location", "magnet:?xt=urn:btih:ABC&dn=x"),
            )
            .mount(&s)
            .await;
        Mock::given(method("GET"))
            .and(path("/torrent"))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(b"d4:infoe".to_vec()))
            .mount(&s)
            .await;
        Mock::given(method("GET"))
            .and(path("/html"))
            .respond_with(ResponseTemplate::new(200).set_body_bytes(b"<html>".to_vec()))
            .mount(&s)
            .await;
        s
    }

    fn p(s: &MockServer) -> Prowlarr {
        Prowlarr::new(&s.uri(), "k3y".into())
    }

    #[tokio::test]
    async fn magnet_redirect_is_not_followed() {
        let s = server().await;
        match p(&s).fetch(&format!("{}/magnet", s.uri())).await.unwrap() {
            TorrentSource::Magnet(m) => assert_eq!(m, "magnet:?xt=urn:btih:ABC&dn=x"),
            _ => panic!("expected magnet"),
        }
    }

    #[tokio::test]
    async fn torrent_bytes() {
        let s = server().await;
        match p(&s).fetch(&format!("{}/torrent", s.uri())).await.unwrap() {
            TorrentSource::Bytes(b) => assert_eq!(b, b"d4:infoe"),
            _ => panic!("expected bytes"),
        }
    }

    #[tokio::test]
    async fn not_a_torrent() {
        let s = server().await;
        let e = p(&s)
            .fetch(&format!("{}/html", s.uri()))
            .await
            .err()
            .unwrap();
        assert!(e.to_string().contains("not a .torrent"), "{e}");
    }

    #[tokio::test]
    async fn server_error() {
        let s = server().await;
        assert!(p(&s).fetch(&format!("{}/boom", s.uri())).await.is_err());
    }

    #[tokio::test]
    async fn search_sends_key_and_query() {
        let s = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v1/search"))
            .and(header("X-Api-Key", "k3y"))
            .and(query_param("query", "studio a"))
            .and(query_param("type", "search"))
            .and(query_param("limit", "100"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!([{"title": "x"}])),
            )
            .expect(1)
            .mount(&s)
            .await;
        let r = p(&s).search("studio a").await.unwrap();
        assert_eq!(r[0].title(), "x");
        let reqs = s.received_requests().await.unwrap();
        assert!(reqs[0].url.query().unwrap().contains("query=studio+a"));
    }

    #[tokio::test]
    async fn indexers_and_a_targeted_search() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v1/indexer"))
            .and(header("X-Api-Key", "k"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {"id": 1, "name": "Primary", "enable": true, "protocol": "torrent", "extra": 1},
                {"id": 2, "name": "Indexer A", "enable": false, "protocol": "torrent"}
            ])))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/api/v1/search"))
            .and(query_param("query", "alpha"))
            .and(query_param("categories", "100"))
            .and(query_param("indexerIds", "2"))
            .and(query_param("indexerIds", "3"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {"title": "Alpha one", "guid": "g1", "infoUrl": "http://a/1", "size": 42,
                 "seeders": 3, "leechers": 1, "protocol": "torrent", "indexer": "Indexer A",
                 "downloadUrl": "http://p/1", "publishDate": "2026-10-30T04:00:00Z"}
            ])))
            .mount(&server)
            .await;
        let p = Prowlarr::new(&server.uri(), "k".into());
        let ix = p.indexers().await.unwrap();
        assert_eq!(
            ix,
            vec![
                Indexer {
                    id: 1,
                    name: "Primary".into(),
                    enable: true,
                    protocol: "torrent".into()
                },
                Indexer {
                    id: 2,
                    name: "Indexer A".into(),
                    enable: false,
                    protocol: "torrent".into()
                },
            ]
        );
        let r = p.search_in("alpha", &[100], &[2, 3]).await.unwrap();
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].guid.as_deref(), Some("g1"));
        assert_eq!(r[0].info_url.as_deref(), Some("http://a/1"));
        assert_eq!((r[0].size, r[0].leechers), (Some(42.0), Some(1.0)));
    }

    #[tokio::test]
    async fn errors_do_not_carry_the_api_key() {
        let s = server().await;
        let url = format!("{}/boom?apikey=SECRET", s.uri());
        let e = p(&s).fetch(&url).await.err().unwrap();
        assert!(!format!("{e:#}").contains("SECRET"), "{e:#}");
        // A refused connection is a reqwest::Error whose Display names the URL.
        let dead = {
            let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            l.local_addr().unwrap()
        };
        let e = p(&s)
            .fetch(&format!("http://{dead}/dl?apikey=SECRET"))
            .await
            .err()
            .unwrap();
        assert!(!format!("{e:#}").contains("SECRET"), "{e:#}");
        let dead_search = Prowlarr::new(&format!("http://{dead}/?apikey=SECRET"), "k".into());
        let e = dead_search.search("q").await.err().unwrap();
        assert!(!format!("{e:#}").contains("SECRET"), "{e:#}");
    }
}
