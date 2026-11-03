//! The scene database's scene search, for a poster and a background of a release from
//! another indexer. Same service and key as `codedb.rs`; the endpoint comes from the
//! plab-sources secret (`scene_url`), not from this repository.

use serde::Deserialize;

use crate::labels::match_term;

pub struct SceneDb {
    http: reqwest::Client,
    base: String,
    key: String,
}

/// The first scene a search returned: its id, site name and images (poster, background).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SceneHit {
    pub id: String,
    pub site: Option<String>,
    pub images: Vec<String>,
}

#[derive(Deserialize)]
struct Reply {
    #[serde(default)]
    data: Vec<RawScene>,
}

#[derive(Deserialize)]
struct RawScene {
    #[serde(default)]
    id: serde_json::Value,
    #[serde(default)]
    site: Option<RawSite>,
    #[serde(default)]
    poster: Option<String>,
    #[serde(default)]
    background: Option<RawBackground>,
}

#[derive(Deserialize)]
struct RawSite {
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
struct RawBackground {
    #[serde(default)]
    large: Option<String>,
}

impl SceneDb {
    pub fn new(base: &str, key: &str) -> SceneDb {
        SceneDb {
            http: crate::http::client(60),
            base: base.trim_end_matches('/').to_string(),
            key: key.to_string(),
        }
    }

    /// The best match for `query`, or None when the search found nothing.
    pub async fn search(&self, query: &str) -> anyhow::Result<Option<SceneHit>> {
        let reply: Reply = self
            .http
            .get(&self.base)
            .query(&[("parse", query), ("per_page", "1")])
            .header("Authorization", format!("Bearer {}", self.key))
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(reqwest::Error::without_url)?
            .error_for_status()
            .map_err(reqwest::Error::without_url)?
            .json()
            .await
            .map_err(reqwest::Error::without_url)?;
        Ok(reply.data.into_iter().next().and_then(|s| {
            let id = match s.id {
                serde_json::Value::String(v) if !v.is_empty() => v,
                serde_json::Value::Number(n) => n.to_string(),
                _ => return None,
            };
            let images = [s.poster, s.background.and_then(|b| b.large)]
                .into_iter()
                .flatten()
                .filter(|u| !u.is_empty())
                .collect();
            Some(SceneHit {
                id,
                site: s.site.and_then(|x| x.name),
                images,
            })
        }))
    }
}

/// Whether a hit is this release's scene: its site matches the term that found the
/// release, or the release title names the site. Anything else is a miss, so a release
/// found by a generic term never borrows another release's images.
pub fn accept(hit: &SceneHit, term: &str, title: &str) -> bool {
    let Some(site) = hit.site.as_deref() else {
        return false;
    };
    match_term(term, site) || match_term(site, title)
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn search_decodes_the_first_scene() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/scenes"))
            .and(query_param("parse", "alpha lazy 2026-10-24"))
            .and(header("Authorization", "Bearer k"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": [
                    {"id": "abc", "site": {"name": "Alpha"}, "poster": "http://i/p.jpg",
                     "background": {"large": "http://i/b.jpg"}},
                    {"id": "other"}
                ]})),
            )
            .mount(&server)
            .await;
        let db = SceneDb::new(&format!("{}/scenes", server.uri()), "k");
        let hit = db.search("alpha lazy 2026-10-24").await.unwrap().unwrap();
        assert_eq!(
            hit,
            SceneHit {
                id: "abc".into(),
                site: Some("Alpha".into()),
                images: vec!["http://i/p.jpg".into(), "http://i/b.jpg".into()],
            }
        );
    }

    #[tokio::test]
    async fn no_scene_is_none_and_a_numeric_id_is_kept() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(query_param("parse", "none"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": []})))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(query_param("parse", "num"))
            .respond_with(
                ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": [{"id": 7}]})),
            )
            .mount(&server)
            .await;
        let db = SceneDb::new(&server.uri(), "k");
        assert_eq!(db.search("none").await.unwrap(), None);
        assert_eq!(db.search("num").await.unwrap().unwrap().id, "7");
    }

    #[test]
    fn a_site_mismatch_is_a_miss() {
        let hit = SceneHit {
            id: "1".into(),
            site: Some("Alpha Studio".into()),
            images: vec![],
        };
        assert!(accept(&hit, "alpha studio", "anything"));
        assert!(accept(&hit, "generic", "AlphaStudio Ann Lazy"));
        assert!(!accept(&hit, "generic", "Beta Ann Lazy"));
        assert!(!accept(&SceneHit::default(), "alpha", "Alpha"));
    }
}
