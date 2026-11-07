//! The shared state of the daemon, and the constructors the one-shot commands use to build
//! only what they need.

use std::sync::Arc;

use anyhow::Context;
use tokio::sync::Semaphore;

use crate::codedb::CodeDb;
use crate::config::Config;
use crate::db::Db;
use crate::identify::Paths;
use crate::images::ImageCache;
use crate::llm::{self, OpenRouter};
use crate::stash::{Stash, StashApi};
use crate::tracker::Tracker;
use crate::transmission::Transmission;

/// Topic pages fetched at once for search thumbnails.
pub const FETCH_SLOTS: usize = 2;

pub struct App {
    pub cfg: Arc<Config>,
    pub db: Db,
    pub images: ImageCache,
    pub tracker: Arc<Tracker>,
    pub transmission: Arc<Transmission>,
    pub stash: Stash,
    pub openrouter: Option<OpenRouter>,
    pub fetch_slots: Arc<Semaphore>,
    /// Held by each identify pass: the sweep and the watcher never run one at once.
    pub pass_lock: tokio::sync::Mutex<()>,
    /// The stream engine, when PLAB_RQBIT_URL is set.
    pub rqbit: Option<crate::rqbit::Rqbit>,
    pub streams: Arc<crate::stream::Streams>,
    /// Shared by the curated job and, later, the web handlers.
    pub prowlarr: Option<Arc<crate::prowlarr::Prowlarr>>,
}

impl App {
    pub fn build(cfg: Config) -> anyhow::Result<App> {
        let db = open_db(&cfg)?;
        let stash = stash(&cfg);
        Ok(App {
            images: images(&cfg)?,
            tracker: Arc::new(tracker(&cfg, &db)?),
            transmission: Arc::new(transmission(&cfg)?),
            openrouter: openrouter(&cfg, llm::OPENROUTER)?,
            stash,
            db,
            fetch_slots: Arc::new(Semaphore::new(FETCH_SLOTS)),
            pass_lock: tokio::sync::Mutex::new(()),
            rqbit: cfg.rqbit_url.as_deref().map(crate::rqbit::Rqbit::new),
            streams: Arc::default(),
            prowlarr: prowlarr(&cfg).map(Arc::new),
            cfg: Arc::new(cfg),
        })
    }
}

/// `state.db` under the state dir, importing the Python tools' JSON state on first open.
pub fn open_db(cfg: &Config) -> anyhow::Result<Db> {
    Db::open_with(&cfg.state_dir.join("state.db"), Some(&cfg.legacy))
}

pub fn images(cfg: &Config) -> anyhow::Result<ImageCache> {
    let dir = cfg.state_dir.join("img");
    ImageCache::new(dir.clone()).with_context(|| format!("creating {}", dir.display()))
}

pub fn tracker(cfg: &Config, db: &Db) -> anyhow::Result<Tracker> {
    Ok(Tracker::new(
        &crate::site::get().tracker_url,
        Config::secret(&cfg.username_file, "PLAB_USERNAME_FILE")?,
        Config::secret(&cfg.password_file, "PLAB_PASSWORD_FILE")?,
        db.clone(),
    ))
}

pub fn transmission(cfg: &Config) -> anyhow::Result<Transmission> {
    Ok(Transmission::new(Config::require(
        &cfg.transmission_url,
        "PLAB_TRANSMISSION_URL",
    )?))
}

/// Prowlarr with the key from its own config.xml, or None (logged) when
/// PLAB_PROWLARR_CONFIG is unset or unreadable: curated then skips other indexers, and
/// their releases cannot be streamed or added.
pub fn prowlarr(cfg: &Config) -> Option<crate::prowlarr::Prowlarr> {
    let path = cfg.prowlarr_config.as_ref()?;
    match crate::prowlarr::api_key(path) {
        Ok(key) => Some(crate::prowlarr::Prowlarr::new(&cfg.prowlarr_url, key)),
        Err(e) => {
            tracing::warn!("Prowlarr: {e:#}");
            None
        }
    }
}

pub fn stash(cfg: &Config) -> Stash {
    Stash::new(&cfg.stash_url, cfg.stash_api_key.clone())
}

pub fn paths(cfg: &Config) -> Paths {
    Paths {
        host: cfg.library_host.clone(),
        container: cfg.library_container.clone(),
    }
}

/// The OpenRouter client (refresh's classifier, identify's LLM), or None without a key
/// file, as plab's `make_classifier`. `base` is `llm::OPENROUTER` outside tests.
pub fn openrouter(cfg: &Config, base: &str) -> anyhow::Result<Option<OpenRouter>> {
    let Some(path) = cfg.openrouter_key_file.as_ref().filter(|p| p.is_file()) else {
        return Ok(None);
    };
    let key = std::fs::read_to_string(path)
        .with_context(|| format!("reading {}", path.display()))?
        .trim()
        .to_string();
    Ok(Some(OpenRouter::new(
        base,
        key,
        cfg.parse_model.clone(),
        cfg.jev_model.clone(),
    )))
}

/// The assistant, or None without an OpenRouter key. Its own OpenRouter client, so the
/// web task and the jobs never share one; `base` is `llm::OPENROUTER` outside tests.
pub fn assistant(cfg: &Config, base: &str) -> anyhow::Result<Option<crate::assistant::Assistant>> {
    Ok(openrouter(cfg, base)?.map(|llm| {
        crate::assistant::Assistant::new(
            llm,
            stash(cfg),
            cfg.assistant_model.clone(),
            crate::site::get().prompts.assistant.clone(),
        )
        .with_hide(
            crate::filters::load_excludes(cfg.exclude_file.as_deref(), Some(&cfg.state_dir)).rule,
        )
        .with_sources(cfg.sources_file.clone())
    }))
}

/// identify cannot run without the LLM: stash-identify always needed its key.
pub fn require_openrouter(o: &Option<OpenRouter>) -> anyhow::Result<&OpenRouter> {
    o.as_ref().context(
        "identify needs an OpenRouter key: PLAB_OPENROUTER_KEY_FILE is not set or not a file",
    )
}

/// The code database's search API, with the key Stash holds for its stash-box; None (logged) when
/// there is none or Stash cannot be asked. Resolved per pass, so a Stash that was down
/// when the daemon started is asked again.
pub async fn codedb<S: StashApi>(stash: &S) -> Option<CodeDb> {
    let key = match stash.codedb_api_key().await {
        Ok(key) => key,
        Err(e) => {
            tracing::warn!("reading the code database key from Stash failed: {e:#}");
            None
        }
    };
    if key.is_none() {
        tracing::info!(
            "no code database key in Stash's stash-box config; code lookup uses StashDB only"
        );
    }
    key.map(|k| CodeDb::new(&k))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::Classify;
    use wiremock::matchers::{body_partial_json, header, method, path};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn cfg(vars: Vec<(&'static str, String)>) -> Config {
        Config::from_env(move |k| vars.iter().find(|(n, _)| *n == k).map(|(_, v)| v.clone()))
    }

    // plab test_main.py MakeClassifier

    #[test]
    fn no_key_file_means_none() {
        let dir = tempfile::tempdir().unwrap();
        let missing = dir.path().join("missing").display().to_string();
        let c = cfg(vec![("PLAB_OPENROUTER_KEY_FILE", missing)]);
        assert!(openrouter(&c, llm::OPENROUTER).unwrap().is_none());
        assert!(openrouter(&cfg(vec![]), llm::OPENROUTER).unwrap().is_none());
    }

    #[tokio::test]
    async fn key_file_builds_classifier() {
        let dir = tempfile::tempdir().unwrap();
        let key = dir.path().join("key");
        std::fs::write(&key, "sk-key\n").unwrap();
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(path(llm::DECISIONS_PATH))
            .and(header("Authorization", "Bearer sk-key"))
            .and(body_partial_json(
                serde_json::json!({"model": "other/model"}),
            ))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!(
                {"answers": {"production": {"choice": "amateur", "confidence": 0.9}}}
            )))
            .expect(1)
            .mount(&server)
            .await;
        let c = cfg(vec![
            ("PLAB_OPENROUTER_KEY_FILE", key.display().to_string()),
            ("PLAB_JEV_MODEL", "other/model".into()),
        ]);
        let classifier = openrouter(&c, &server.uri()).unwrap().unwrap();
        let p = classifier.classify("t", "c").await.unwrap();
        assert_eq!(p.class, "amateur");
    }

    #[tokio::test]
    async fn codedb_is_resolved_on_each_call_and_survives_a_stash_outage() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(500))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!(
                {"data": {"configuration": {"general": {"stashBoxes": [
                    {"endpoint": "https://codes.example/graphql", "api_key": "tp"}]}}}}
            )))
            .mount(&server)
            .await;
        let stash = Stash::new(&server.uri(), None);
        assert!(codedb(&stash).await.is_none()); // Stash down: no key this pass, no panic
        assert!(codedb(&stash).await.is_some()); // next pass picks it up
    }

    #[test]
    fn identify_needs_the_key() {
        let e = require_openrouter(&None).err().unwrap();
        assert!(e.to_string().contains("PLAB_OPENROUTER_KEY_FILE"));
    }

    #[test]
    fn tracker_needs_credentials() {
        let db = Db::open_in_memory().unwrap();
        let e = tracker(&cfg(vec![]), &db).err().unwrap();
        assert_eq!(e.to_string(), "PLAB_USERNAME_FILE is not set");
    }
}
