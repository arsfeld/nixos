//! Settings for the curated job's other indexers, from the `plab-sources` sops secret
//! (`PLAB_SOURCES_FILE`). Indexer names, categories, the scene-database URL and title
//! vocabulary are kept out of this repository on purpose: they live only in that file.
//!
//! Format: `key = value` lines; blank lines and `#` comments ignored; unknown keys logged.
//! `categories` and `noise` are comma-separated.

use std::path::Path;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Sources {
    /// Prowlarr's name for the tracker's own indexer, left out of external searches.
    pub primary_indexer: Option<String>,
    /// Prowlarr category ids to search.
    pub categories: Vec<u32>,
    /// The scene database's scene search endpoint.
    pub scene_url: Option<String>,
    /// Lower-cased title words dropped when titles are compared.
    pub noise: Vec<String>,
}

pub fn parse(text: &str) -> Sources {
    let mut s = Sources::default();
    let list = |v: &str| -> Vec<String> {
        v.split(',')
            .map(str::trim)
            .filter(|x| !x.is_empty())
            .map(String::from)
            .collect()
    };
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            tracing::warn!("plab-sources: ignoring a line without '='");
            continue;
        };
        let (key, value) = (key.trim(), value.trim());
        let value_opt = (!value.is_empty()).then(|| value.to_string());
        match key {
            "primary_indexer" => s.primary_indexer = value_opt,
            "categories" => {
                s.categories = list(value).iter().filter_map(|c| c.parse().ok()).collect()
            }
            "scene_url" => s.scene_url = value_opt,
            "noise" => {
                s.noise = list(value)
                    .iter()
                    .flat_map(|n| n.split_whitespace())
                    .map(str::to_lowercase)
                    .collect()
            }
            other => tracing::warn!("plab-sources: unknown key {other:?}"),
        }
    }
    s
}

/// The settings, or None (logged) when there is no file or it names no category: the
/// curated job then searches the tracker only.
pub fn load(path: Option<&Path>) -> Option<Sources> {
    let Some(path) = path else {
        tracing::info!("no plab-sources file: curated searches the tracker only");
        return None;
    };
    if !path.is_file() {
        tracing::warn!(
            "plab-sources file {} is missing: external sources are off",
            path.display()
        );
        return None;
    }
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) => {
            tracing::error!("cannot read {}: {e}", path.display());
            return None;
        }
    };
    let s = parse(&text);
    if s.categories.is_empty() {
        tracing::warn!("plab-sources names no categories: curated searches the tracker only");
        return None;
    }
    Some(s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_key_parses() {
        let s = parse(
            "# comment\nprimary_indexer = Primary\ncategories = 100, 200,x\n\
             scene_url = http://scenes.example/scenes\nnoise = NoiseA, two Words\nbogus = 1\n",
        );
        assert_eq!(
            s,
            Sources {
                primary_indexer: Some("Primary".into()),
                categories: vec![100, 200],
                scene_url: Some("http://scenes.example/scenes".into()),
                noise: vec!["noisea".into(), "two".into(), "words".into()],
            }
        );
    }

    #[test]
    fn no_file_or_no_categories_disables_the_external_pass() {
        assert_eq!(load(None), None);
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("s.txt");
        std::fs::write(&p, "primary_indexer = Primary\n").unwrap();
        assert_eq!(load(Some(&p)), None);
        std::fs::write(&p, "categories = 100\n").unwrap();
        assert_eq!(load(Some(&p)).unwrap().categories, vec![100]);
    }
}
