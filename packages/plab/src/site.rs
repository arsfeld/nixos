//! Everything that identifies the tracker and what it carries, from the `plab-site` sops
//! secret (`PLAB_SITE_FILE`, JSON): its address and Prowlarr name, its forum groups, the
//! code database, the LLM prompts and the production criteria. None of it is in this
//! repository on purpose; tests run against `Site::example()`, which is made up.

use std::path::Path;
use std::sync::OnceLock;

use anyhow::Context;
use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Site {
    /// The tracker's forum root, ending in `/`.
    pub tracker_url: String,
    /// Prowlarr's name for the tracker's indexer.
    pub tracker_indexer: String,
    /// Substrings of the announce hosts that mark a torrent as the tracker's.
    pub announce_hosts: Vec<String>,
    /// The scene tag release names carry before their tail; titles are cut there.
    pub release_tag: String,
    /// The video forums, grouped under the names the page shows as categories.
    pub groups: Vec<Group>,
    /// The game forums, which make the separate games list.
    pub games: Vec<u32>,
    pub code_db: CodeDb,
    /// The FC2 article page; `{}` is the article number.
    pub fc2_article: String,
    pub prompts: Prompts,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Group {
    pub name: String,
    pub forums: Vec<u32>,
}

/// The second stash-box, and its product-code search API.
#[derive(Debug, Clone, Deserialize)]
pub struct CodeDb {
    /// The product-code search endpoint.
    pub search_url: String,
    /// Its stash-box GraphQL endpoint, as Stash's config names it.
    pub box_endpoint: String,
    /// A record's page; `{}` is its slug.
    pub page_url: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Prompts {
    /// The filename parse's system prompt.
    pub parse: String,
    /// The title translation's system prompt.
    pub translate: String,
    /// The production classifier's question.
    pub classify: String,
    /// Its answers, in the order the question lists them.
    pub criteria: Vec<Criterion>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Criterion {
    pub key: String,
    pub description: String,
}

impl Site {
    pub fn load(path: &Path) -> anyhow::Result<Site> {
        let text =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))
    }

    /// The tracker's domain, without a leading `www.`: cookies for it and its subdomains
    /// are the session's.
    pub fn tracker_domain(&self) -> String {
        url::Url::parse(&self.tracker_url)
            .ok()
            .and_then(|u| {
                u.host_str()
                    .map(|h| h.trim_start_matches("www.").to_string())
            })
            .unwrap_or_default()
    }

    /// A topic's page, minus its id.
    pub fn topic_url(&self) -> String {
        format!("{}viewtopic.php?t=", self.tracker_url)
    }

    /// The stash-boxes identify searches, best first.
    pub fn boxes(&self) -> [&str; 2] {
        [&self.code_db.box_endpoint, crate::identify::STASHDB]
    }

    /// A stand-in with made-up values, for tests.
    #[cfg(test)]
    pub fn example() -> Site {
        let g = |name: &str, forums: &[u32]| Group {
            name: name.into(),
            forums: forums.to_vec(),
        };
        let c = |key: &str| Criterion {
            key: key.into(),
            description: format!("{key} criterion"),
        };
        Site {
            tracker_url: "https://tracker.example/forum/".into(),
            tracker_indexer: "TrackerA".into(),
            announce_hosts: vec!["tracker.example".into()],
            release_tag: "TAG".into(),
            groups: vec![
                g("Group A", &[10, 11]),
                g("Clips", &[1875, 1878, 1877]),
                g("Group B", &[1800]),
                g("VR", &[1823]),
            ],
            games: vec![1838, 1750],
            code_db: CodeDb {
                search_url: "https://api.codes.example/code".into(),
                box_endpoint: "https://codes.example/graphql".into(),
                page_url: "https://codes.example/code/{}".into(),
            },
            fc2_article: "https://fc2.example/article/{}/".into(),
            prompts: Prompts {
                parse: "parse prompt".into(),
                translate: "translate prompt".into(),
                classify: "classify question".into(),
                criteria: vec![c("industrial"), c("pro_artistic"), c("amateur")],
            },
        }
    }
}

static SITE: OnceLock<Site> = OnceLock::new();

/// Loads the site once, at startup, before anything reads it.
pub fn init(path: Option<&Path>) -> anyhow::Result<()> {
    let path = path.context("PLAB_SITE_FILE is not set")?;
    let site = Site::load(path)?;
    let _ = SITE.set(site);
    Ok(())
}

/// The site. Outside tests, `init` must have run.
pub fn get() -> &'static Site {
    #[cfg(test)]
    {
        SITE.get_or_init(Site::example)
    }
    #[cfg(not(test))]
    {
        SITE.get().expect("site::init runs at startup")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_the_json_shape() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("site.json");
        std::fs::write(
            &p,
            r#"{"tracker_url": "https://www.t.example/forum/", "tracker_indexer": "T",
                "announce_hosts": ["t.example"], "release_tag": "TAG",
                "groups": [{"name": "A", "forums": [1, 2]}], "games": [3],
                "code_db": {"search_url": "s", "box_endpoint": "b", "page_url": "p/{}"},
                "fc2_article": "f/{}/",
                "prompts": {"parse": "p", "translate": "t", "classify": "c",
                            "criteria": [{"key": "k", "description": "d"}]}}"#,
        )
        .unwrap();
        let s = Site::load(&p).unwrap();
        assert_eq!(s.groups[0].forums, [1, 2]);
        assert_eq!(s.tracker_domain(), "t.example");
        assert_eq!(
            s.topic_url(),
            "https://www.t.example/forum/viewtopic.php?t="
        );
        assert_eq!(s.prompts.criteria[0].key, "k");
        assert!(Site::load(&dir.path().join("missing")).is_err());
    }
}
