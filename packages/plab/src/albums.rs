//! The album index: a site that lists albums kept on a direct-HTTP file host. The curated
//! job scrapes its search page for terms marked `%`; plab never streams, downloads or
//! resolves anything on the file host, whose album page the card links to. The index's
//! address and label come from `plab-sources`, never from this repository.

use std::sync::LazyLock;

use regex::Regex;

/// One result card.
#[derive(Debug, Clone, PartialEq)]
pub struct Album {
    /// The file host's album id: the last segment of `href`.
    pub id: String,
    pub href: String,
    pub name: String,
    pub files: u32,
    /// The card's thumbnail on the file host's CDN, if it has one.
    pub thumb: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct AlbumPage {
    pub albums: Vec<Album>,
    /// The page count from the `page 1 of N` header; None when there is no header.
    pub pages: Option<u32>,
}

impl AlbumPage {
    /// No cards read, although the page does not say it is empty: its layout changed.
    pub fn looks_broken(&self) -> bool {
        self.albums.is_empty() && self.pages != Some(0)
    }
}

fn re(p: &str) -> Regex {
    Regex::new(p).unwrap()
}

static CARD: LazyLock<Regex> =
    LazyLock::new(|| re(r#"(?s)<a href="(https?://[^"/]+/a/([A-Za-z0-9_-]+))"[^>]*>(.*?)</a>"#));
static THUMB: LazyLock<Regex> = LazyLock::new(|| re(r#"<img src="(https?://[^"]+)""#));
static NAME: LazyLock<Regex> = LazyLock::new(|| re(r"(?s)<h3[^>]*>(.*?)</h3>"));
static FILES: LazyLock<Regex> = LazyLock::new(|| re(r"\b(\d+) files?\b"));
static PAGES: LazyLock<Regex> =
    LazyLock::new(|| re(r"page <span[^>]*>\d+</span> of <span[^>]*>(\d+)</span>"));

pub fn parse(html: &str) -> AlbumPage {
    let albums = CARD
        .captures_iter(html)
        .filter_map(|c| {
            let body = c.get(3)?.as_str();
            let name =
                html_escape::decode_html_entities(NAME.captures(body)?[1].trim()).into_owned();
            if name.is_empty() {
                return None;
            }
            Some(Album {
                id: c[2].to_string(),
                href: c[1].to_string(),
                name,
                files: FILES
                    .captures(body)
                    .and_then(|f| f[1].parse().ok())
                    .unwrap_or(0),
                thumb: THUMB.captures(body).map(|t| t[1].to_string()),
            })
        })
        .collect();
    AlbumPage {
        albums,
        pages: PAGES.captures(html).and_then(|c| c[1].parse().ok()),
    }
}

/// Results asked for per search.
pub const PER_PAGE: u32 = 40;

/// The index's search page, fetched directly from galactica: a few dozen HTML pages a
/// day and no media, so not through PIA.
pub struct AlbumIndex {
    http: reqwest::Client,
    url: String,
    label: String,
    mode: String,
}

impl AlbumIndex {
    pub fn new(url: &str, label: &str, mode: &str) -> AlbumIndex {
        AlbumIndex {
            http: reqwest::Client::builder()
                .user_agent("Mozilla/5.0")
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .expect("reqwest client"),
            url: url.to_string(),
            label: label.to_string(),
            mode: mode.to_string(),
        }
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    /// The newest `PER_PAGE` albums matching `term`.
    pub async fn search(&self, term: &str) -> anyhow::Result<AlbumPage> {
        let per = PER_PAGE.to_string();
        let url = url::Url::parse_with_params(
            &self.url,
            [
                ("search", term),
                ("mode", &self.mode),
                ("per", &per),
                ("sort", "latest"),
            ],
        )?;
        let html = self
            .http
            .get(url)
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;
        Ok(parse(&html))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> String {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/albums_search.html");
        std::fs::read_to_string(p).unwrap()
    }

    #[test]
    fn every_card_is_read() {
        let page = parse(&fixture());
        assert_eq!(page.pages, Some(3));
        assert_eq!(
            page.albums,
            vec![
                Album {
                    id: "AbC123".into(),
                    href: "https://files.example/a/AbC123".into(),
                    name: "Alpha One & Two".into(),
                    files: 3,
                    thumb: Some("https://cdn.example/thumbs/one.png".into()),
                },
                Album {
                    id: "Def_456".into(),
                    href: "https://files.example/a/Def_456".into(),
                    name: "Alpha Solo".into(),
                    files: 1,
                    thumb: None,
                },
            ]
        );
        assert!(!page.looks_broken());
    }

    #[test]
    fn an_empty_result_is_not_a_broken_page() {
        let html = fixture().replace(">3</span>", ">0</span>").replace(
            "<a href=\"https://files.example/a/",
            "<a data-x href=\"https://files.example/a/",
        );
        let page = parse(&html);
        assert!(page.albums.is_empty());
        assert!(!page.looks_broken());
    }

    #[test]
    fn results_reported_but_none_read_is_a_broken_page() {
        // The card markup changed: the header still says 3 pages.
        let html = fixture().replace(
            "<a href=\"https://files.example/a/",
            "<a data-x href=\"https://files.example/a/",
        );
        assert!(parse(&html).looks_broken());
        // No header at all is broken too.
        assert!(parse("<html><body>nothing</body></html>").looks_broken());
    }

    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn search_asks_for_the_latest_page_in_the_configured_mode() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/"))
            .and(query_param("search", "alpha beta"))
            .and(query_param("mode", "strict"))
            .and(query_param("per", "40"))
            .and(query_param("sort", "latest"))
            .respond_with(ResponseTemplate::new(200).set_body_string(fixture()))
            .expect(1)
            .mount(&server)
            .await;
        let index = AlbumIndex::new(&format!("{}/", server.uri()), "Album index A", "strict");
        assert_eq!(index.label(), "Album index A");
        let page = index.search("alpha beta").await.unwrap();
        assert_eq!(page.albums.len(), 2);
    }

    #[tokio::test]
    async fn a_server_error_is_an_error() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(503))
            .mount(&server)
            .await;
        let index = AlbumIndex::new(&format!("{}/", server.uri()), "Album index A", "strict");
        assert!(index.search("alpha").await.is_err());
    }
}
