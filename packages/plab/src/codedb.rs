//! The code database: the second stash-box's product-code search (`site::CodeDb`). Its
//! stash-box endpoint doesn't expose these records, and Stash's community scraper for them
//! would need a key hand-edited into a file the scraper manager overwrites, so identify
//! calls the REST API itself.

use std::fmt::Write;

use anyhow::Context;
use serde::Deserialize;
use serde_json::Value;

use crate::http;
use crate::stash::de;
use crate::stash::types::{Candidate, ScrapedPerformer, ScrapedStudio};

#[derive(Debug, thiserror::Error)]
pub enum CodeDbError {
    /// The API answered with a non-2xx status (Python: `urllib.error.HTTPError`).
    #[error("HTTP {0}")]
    Status(u16),
    #[error(transparent)]
    Other(#[from] anyhow::Error),
}

/// A code-database record, as far as identify reads it.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct CodeHit {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub external_id: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub date: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub description: Option<String>,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub duration: Option<f64>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub slug: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub url: Option<String>,
    #[serde(default)]
    pub site: Option<CodeSite>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub performers: Vec<CodePerformer>,
    #[serde(default)]
    pub background: Option<CodeBackground>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub poster: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CodeSite {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CodePerformer {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub image: Option<String>,
    #[serde(default)]
    pub parent: Option<CodeSite>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CodeBackground {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub full: Option<String>,
}

/// The ScrapedScene shape apply() consumes. There is no remote_site_id: the code search isn't
/// a stash-box, so studio and performers resolve by name. Its tags carry no Stash id,
/// so none are passed on.
impl From<CodeHit> for Candidate {
    fn from(h: CodeHit) -> Candidate {
        let performers = h
            .performers
            .into_iter()
            .filter_map(|p| {
                let name = p.parent.and_then(|x| x.name).or(p.name)?;
                Some(ScrapedPerformer {
                    name: Some(name),
                    images: p.image.into_iter().collect(),
                    ..Default::default()
                })
            })
            .collect();
        let page = &crate::site::get().code_db.page_url;
        let slug_url = h.slug.map(|s| page.replace("{}", &s));
        Candidate {
            title: h.title,
            code: h.external_id.map(|c| c.to_uppercase()),
            date: h.date,
            details: h.description,
            duration: h.duration,
            image: h.background.and_then(|b| b.full).or(h.poster),
            urls: slug_url.into_iter().chain(h.url).collect(),
            studio: h.site.and_then(|s| s.name).map(|name| ScrapedStudio {
                name: Some(name),
                ..Default::default()
            }),
            performers,
            ..Candidate::default()
        }
    }
}

pub trait CodeSearch: Send + Sync {
    fn code_search(
        &self,
        code: &str,
    ) -> impl std::future::Future<Output = Result<Vec<CodeHit>, CodeDbError>> + Send;
}

pub struct CodeDb {
    http: reqwest::Client,
    base: String,
    key: String,
}

impl CodeDb {
    pub fn new(key: &str) -> CodeDb {
        CodeDb::with_base(&crate::site::get().code_db.search_url, key)
    }

    /// `base` stands in for the site's `search_url`.
    pub fn with_base(base: &str, key: &str) -> CodeDb {
        CodeDb {
            http: http::client(120),
            base: base.to_string(),
            key: key.to_string(),
        }
    }
}

/// `urllib.parse.quote(s)`: everything but ASCII alphanumerics and `_.-~/` is %-encoded.
fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"_.-~/".contains(&b) {
            out.push(b as char);
        } else {
            write!(out, "%{b:02X}").unwrap();
        }
    }
    out
}

fn search_url(base: &str, code: &str) -> String {
    format!("{base}?q={}&per_page=10", quote(code))
}

impl CodeSearch for CodeDb {
    async fn code_search(&self, code: &str) -> Result<Vec<CodeHit>, CodeDbError> {
        let resp = self
            .http
            .get(search_url(&self.base, code))
            // Without a User-Agent the request is refused at the edge.
            .header("Authorization", format!("Bearer {}", self.key))
            .header("Accept", "application/json")
            .header("User-Agent", "stash-identify")
            .send()
            .await
            .map_err(anyhow::Error::from)?;
        if !resp.status().is_success() {
            return Err(CodeDbError::Status(resp.status().as_u16()));
        }
        let mut d: Value = resp.json().await.map_err(anyhow::Error::from)?;
        let data = d
            .get_mut("data")
            .context("no data in the code search reply")?;
        Ok(serde_json::from_value(data.take()).context("code search data")?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use wiremock::matchers::{header, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn codedb_search_sends_key_and_returns_data() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/code"))
            .and(query_param("q", "ABCD-910"))
            .and(query_param("per_page", "10"))
            .and(header("Authorization", "Bearer k"))
            .and(header("Accept", "application/json"))
            .and(header("User-Agent", "stash-identify"))
            .respond_with(
                ResponseTemplate::new(200)
                    .set_body_json(json!({"data": [{"external_id": "abcd-910"}]})),
            )
            .expect(1)
            .mount(&server)
            .await;
        let hits = CodeDb::with_base(&format!("{}/code", server.uri()), "k")
            .code_search("ABCD-910")
            .await
            .unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].external_id.as_deref(), Some("abcd-910"));
        assert_eq!(
            search_url("https://api.codes.example/code", "ABCD-910"),
            "https://api.codes.example/code?q=ABCD-910&per_page=10"
        );
    }

    fn hit(v: Value) -> CodeHit {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn code_hit_becomes_a_candidate() {
        let hit: CodeHit = serde_json::from_value(json!({
            "title": "T", "external_id": "wxyz-796", "date": "2024-01-02", "description": "D",
            "duration": 7200, "slug": "wxyz-796", "url": "https://x/1",
            "site": {"name": "StudioM"},
            "performers": [{"name": "Alias", "parent": {"name": "Real"}, "image": "https://i/1"},
                           {"name": "", "parent": null}],
            "background": {"full": "https://bg"}, "poster": "https://p",
        }))
        .unwrap();
        let c = Candidate::from(hit);
        assert_eq!(c.code.as_deref(), Some("WXYZ-796"));
        assert_eq!(
            c.urls,
            ["https://codes.example/code/wxyz-796", "https://x/1"]
        );
        assert_eq!(c.image.as_deref(), Some("https://bg"));
        assert_eq!(c.studio_name(), Some("StudioM"));
        assert_eq!(c.performers.len(), 1);
        assert_eq!(c.performers[0].name.as_deref(), Some("Real"));
        assert_eq!(c.performers[0].images, ["https://i/1"]);
        assert!(c.tags.is_empty());
    }

    #[test]
    fn poster_fallback_and_missing_site() {
        let c = Candidate::from(hit(json!({
            "background": {"full": null}, "site": null, "poster": "https://thumb/poster",
        })));
        assert_eq!(c.image.as_deref(), Some("https://thumb/poster"));
        assert_eq!(c.studio, None);
        assert_eq!(c.code, None);
    }

    #[test]
    fn code_is_quoted_like_urllib() {
        assert_eq!(
            search_url("https://api.codes.example/code", "a b&c/d~é"),
            "https://api.codes.example/code?q=a%20b%26c/d~%C3%A9&per_page=10"
        );
    }

    #[tokio::test]
    async fn http_status_is_its_own_error() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(401))
            .mount(&server)
            .await;
        let e = CodeDb::with_base(&server.uri(), "k")
            .code_search("X")
            .await
            .unwrap_err();
        assert!(matches!(e, CodeDbError::Status(401)));
        assert_eq!(e.to_string(), "HTTP 401");
    }
}
