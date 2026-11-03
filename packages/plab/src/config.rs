//! The daemon's and the one-shot commands' configuration, from `PLAB_*` environment
//! variables. Nothing is required up front: each command asks for what it uses.

use std::path::PathBuf;

use anyhow::Context;

use crate::db::import::LegacyPaths;

pub struct Config {
    pub state_dir: PathBuf,
    pub username_file: Option<PathBuf>,
    pub password_file: Option<PathBuf>,
    pub transmission_url: Option<String>,
    pub download_dir: Option<String>,
    pub games_dir: Option<String>,
    pub static_dir: Option<PathBuf>,
    pub exclude_file: Option<PathBuf>,
    pub filter_file: Option<PathBuf>,
    /// The `plab-sources` file: other indexers' settings for the curated job.
    pub sources_file: Option<PathBuf>,
    /// The `plab-site` file: the tracker and everything naming its content (`site.rs`).
    pub site_file: Option<PathBuf>,
    pub openrouter_key_file: Option<PathBuf>,
    pub jev_model: String,
    pub parse_model: String,
    /// The assistant's chat model; defaults to `parse_model`.
    pub assistant_model: String,
    pub stash_url: String,
    /// Where the browser reaches Stash; None renders no links to it.
    pub stash_web_url: Option<String>,
    pub stash_api_key: Option<String>,
    pub library_host: String,
    pub library_container: String,
    pub grab_rules_file: Option<PathBuf>,
    pub prowlarr_url: String,
    pub prowlarr_config: Option<PathBuf>,
    pub legacy: LegacyPaths,
    /// The rqbit engine's API; None turns streaming off.
    pub rqbit_url: Option<String>,
    /// Where the browser reaches the tailnet stream listener.
    pub stream_public_url: Option<String>,
}

impl Config {
    /// `get` is `std::env::var(..).ok()` outside tests. An empty variable counts as unset.
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> Config {
        let var = |k: &str| get(k).filter(|v| !v.is_empty());
        let or = |k: &str, default: &str| var(k).unwrap_or_else(|| default.to_string());
        let path = |k: &str| var(k).map(PathBuf::from);
        let state_dir = PathBuf::from(or("PLAB_STATE_DIR", "/var/lib/plab"));
        let parse_model = or("PLAB_PARSE_MODEL", "~deepseek/deepseek-flash-latest");
        let assistant_model = or("PLAB_ASSISTANT_MODEL", &parse_model);
        Config {
            username_file: path("PLAB_USERNAME_FILE"),
            password_file: path("PLAB_PASSWORD_FILE"),
            transmission_url: var("PLAB_TRANSMISSION_URL"),
            download_dir: var("PLAB_DOWNLOAD_DIR"),
            games_dir: var("PLAB_GAMES_DIR"),
            static_dir: path("PLAB_STATIC_DIR"),
            exclude_file: path("PLAB_EXCLUDE_FILE"),
            filter_file: path("PLAB_FILTER_FILE"),
            sources_file: path("PLAB_SOURCES_FILE"),
            site_file: path("PLAB_SITE_FILE"),
            openrouter_key_file: path("PLAB_OPENROUTER_KEY_FILE"),
            jev_model: or("PLAB_JEV_MODEL", "typesafe/jev-1.13"),
            parse_model,
            assistant_model,
            stash_url: or("PLAB_STASH_URL", "http://localhost:9999/graphql"),
            stash_web_url: var("PLAB_STASH_WEB_URL"),
            stash_api_key: var("PLAB_STASH_API_KEY"),
            library_host: or("PLAB_LIBRARY_HOST", "/mnt/storage/media/Vault"),
            library_container: or("PLAB_LIBRARY_CONTAINER", "/media/Vault"),
            grab_rules_file: path("PLAB_GRAB_RULES_FILE"),
            prowlarr_url: or("PLAB_PROWLARR_URL", "http://127.0.0.1:9696"),
            prowlarr_config: path("PLAB_PROWLARR_CONFIG"),
            rqbit_url: var("PLAB_RQBIT_URL"),
            stream_public_url: var("PLAB_STREAM_PUBLIC_URL"),
            legacy: LegacyPaths {
                plab: path("PLAB_LEGACY_PLAB_DIR").unwrap_or_else(|| state_dir.clone()),
                stash_identify: PathBuf::from(or(
                    "PLAB_LEGACY_STASH_IDENTIFY_DIR",
                    "/var/lib/stash-identify",
                )),
                vault_grab: PathBuf::from(or("PLAB_LEGACY_VAULT_GRAB_DIR", "/var/lib/vault-grab")),
            },
            state_dir,
        }
    }

    /// The value of a variable a command needs.
    pub fn require<'a, T>(v: &'a Option<T>, var: &str) -> anyhow::Result<&'a T> {
        v.as_ref().with_context(|| format!("{var} is not set"))
    }

    /// The trimmed contents of the file a `*_FILE` variable names.
    pub fn secret(path: &Option<PathBuf>, var: &str) -> anyhow::Result<String> {
        let path = Self::require(path, var)?;
        let text = std::fs::read_to_string(path)
            .with_context(|| format!("reading {var} {}", path.display()))?;
        Ok(text.trim().to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<String> {
        let m: HashMap<String, String> = pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        move |k| m.get(k).cloned()
    }

    #[test]
    fn config_defaults() {
        let c = Config::from_env(|_| None);
        assert_eq!(c.state_dir, std::path::PathBuf::from("/var/lib/plab"));
        assert_eq!(c.legacy.plab, c.state_dir);
        assert_eq!(c.stash_url, "http://localhost:9999/graphql");
        assert_eq!(c.stash_web_url, None);
        assert!(
            Config::require(&c.transmission_url, "PLAB_TRANSMISSION_URL")
                .unwrap_err()
                .to_string()
                .contains("PLAB_TRANSMISSION_URL")
        );
        assert_eq!(c.jev_model, "typesafe/jev-1.13");
        assert_eq!(c.parse_model, "~deepseek/deepseek-flash-latest");
        assert_eq!(c.assistant_model, "~deepseek/deepseek-flash-latest");
        assert_eq!(c.library_host, "/mnt/storage/media/Vault");
        assert_eq!(c.library_container, "/media/Vault");
        assert_eq!(c.prowlarr_url, "http://127.0.0.1:9696");
        assert_eq!(c.sources_file, None);
        assert_eq!(
            c.legacy.stash_identify,
            PathBuf::from("/var/lib/stash-identify")
        );
        assert_eq!(c.legacy.vault_grab, PathBuf::from("/var/lib/vault-grab"));
        assert!(c.username_file.is_none() && c.games_dir.is_none() && c.stash_api_key.is_none());
    }

    #[test]
    fn config_reads_every_variable() {
        let c = Config::from_env(env(&[
            ("PLAB_STATE_DIR", "/s"),
            ("PLAB_USERNAME_FILE", "/u"),
            ("PLAB_PASSWORD_FILE", "/p"),
            ("PLAB_TRANSMISSION_URL", "http://t/rpc"),
            ("PLAB_DOWNLOAD_DIR", "/dl"),
            ("PLAB_GAMES_DIR", "/games"),
            ("PLAB_STATIC_DIR", "/static"),
            ("PLAB_EXCLUDE_FILE", "/ex"),
            ("PLAB_FILTER_FILE", "/fi"),
            ("PLAB_SOURCES_FILE", "/sources"),
            ("PLAB_SITE_FILE", "/site"),
            ("PLAB_OPENROUTER_KEY_FILE", "/key"),
            ("PLAB_JEV_MODEL", "j/m"),
            ("PLAB_PARSE_MODEL", "p/m"),
            ("PLAB_ASSISTANT_MODEL", "a/m"),
            ("PLAB_STASH_URL", "http://stash/graphql"),
            ("PLAB_STASH_WEB_URL", "https://stash.example"),
            ("PLAB_STASH_API_KEY", "sk"),
            ("PLAB_LIBRARY_HOST", "/lib"),
            ("PLAB_LIBRARY_CONTAINER", "/c"),
            ("PLAB_GRAB_RULES_FILE", "/rules"),
            ("PLAB_PROWLARR_URL", "http://prowlarr"),
            ("PLAB_PROWLARR_CONFIG", "/config.xml"),
            ("PLAB_LEGACY_PLAB_DIR", "/old/plab"),
            ("PLAB_LEGACY_STASH_IDENTIFY_DIR", "/old/si"),
            ("PLAB_LEGACY_VAULT_GRAB_DIR", "/old/vg"),
        ]));
        let p = PathBuf::from;
        assert_eq!(c.state_dir, p("/s"));
        assert_eq!(c.username_file, Some(p("/u")));
        assert_eq!(c.password_file, Some(p("/p")));
        assert_eq!(c.transmission_url.as_deref(), Some("http://t/rpc"));
        assert_eq!(c.download_dir.as_deref(), Some("/dl"));
        assert_eq!(c.games_dir.as_deref(), Some("/games"));
        assert_eq!(c.static_dir, Some(p("/static")));
        assert_eq!(c.exclude_file, Some(p("/ex")));
        assert_eq!(c.filter_file, Some(p("/fi")));
        assert_eq!(c.sources_file, Some(p("/sources")));
        assert_eq!(c.site_file, Some(p("/site")));
        assert_eq!(c.openrouter_key_file, Some(p("/key")));
        assert_eq!(c.jev_model, "j/m");
        assert_eq!(c.parse_model, "p/m");
        assert_eq!(c.assistant_model, "a/m");
        assert_eq!(c.stash_url, "http://stash/graphql");
        assert_eq!(c.stash_web_url.as_deref(), Some("https://stash.example"));
        assert_eq!(c.stash_api_key.as_deref(), Some("sk"));
        assert_eq!(c.library_host, "/lib");
        assert_eq!(c.library_container, "/c");
        assert_eq!(c.grab_rules_file, Some(p("/rules")));
        assert_eq!(c.prowlarr_url, "http://prowlarr");
        assert_eq!(c.prowlarr_config, Some(p("/config.xml")));
        assert_eq!(c.legacy.plab, p("/old/plab"));
        assert_eq!(c.legacy.stash_identify, p("/old/si"));
        assert_eq!(c.legacy.vault_grab, p("/old/vg"));
    }

    #[test]
    fn assistant_model_follows_parse_model() {
        let c = Config::from_env(env(&[("PLAB_PARSE_MODEL", "p/m")]));
        assert_eq!(c.assistant_model, "p/m");
    }

    #[test]
    fn legacy_plab_dir_follows_state_dir() {
        let c = Config::from_env(env(&[("PLAB_STATE_DIR", "/s")]));
        assert_eq!(c.legacy.plab, PathBuf::from("/s"));
    }

    #[test]
    fn empty_variables_count_as_unset() {
        let c = Config::from_env(env(&[("PLAB_GAMES_DIR", ""), ("PLAB_JEV_MODEL", "")]));
        assert_eq!(c.games_dir, None);
        assert_eq!(c.jev_model, "typesafe/jev-1.13");
    }

    #[test]
    fn secret_reads_and_trims() {
        let dir = tempfile::tempdir().unwrap();
        let f = dir.path().join("user");
        std::fs::write(&f, "  alice\n").unwrap();
        assert_eq!(
            Config::secret(&Some(f), "PLAB_USERNAME_FILE").unwrap(),
            "alice"
        );
        let e = Config::secret(&None, "PLAB_USERNAME_FILE").unwrap_err();
        assert_eq!(e.to_string(), "PLAB_USERNAME_FILE is not set");
        let missing = dir.path().join("missing");
        let e = Config::secret(&Some(missing.clone()), "PLAB_USERNAME_FILE").unwrap_err();
        assert!(format!("{e:#}").contains(&missing.display().to_string()));
    }

    #[test]
    fn stream_settings_come_from_the_environment() {
        let c = Config::from_env(env(&[
            ("PLAB_RQBIT_URL", "http://10.0.0.2:3031"),
            (
                "PLAB_STREAM_PUBLIC_URL",
                "https://plab-stream.bat-boa.ts.net",
            ),
        ]));
        assert_eq!(c.rqbit_url.as_deref(), Some("http://10.0.0.2:3031"));
        assert_eq!(
            c.stream_public_url.as_deref(),
            Some("https://plab-stream.bat-boa.ts.net")
        );
        let none = Config::from_env(|_| None);
        assert!(none.rqbit_url.is_none() && none.stream_public_url.is_none());
    }
}
