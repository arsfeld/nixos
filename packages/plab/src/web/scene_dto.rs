//! A Stash scene as the page's scene cards show it: For you and assistant picks, and the
//! watchlist.

use serde::Serialize;

use crate::stash::library::LibScene;

#[derive(Serialize)]
pub(super) struct SceneDto {
    #[serde(rename = "ref")]
    pub(super) ref_: String,
    id: String,
    title: String,
    studio: Option<String>,
    performers: Vec<String>,
    screenshot: Option<String>,
    /// The preview clip, for playing on hover.
    preview: Option<String>,
    date: Option<String>,
    /// Seconds, of the first file.
    duration: Option<f64>,
    link: Option<String>,
}

/// Stash's own screenshot URL names the address plab reached it at; the browser needs
/// Stash's public address with the same path. Only `<scheme>://<authority>/<path>` or a
/// rooted `/<path>` carry a path worth keeping; anything else yields None.
fn rebase(url: &str, web: &str) -> Option<String> {
    let path = if let Some((_, rest)) = url.split_once("://") {
        &rest[rest.find('/')?..]
    } else if url.starts_with('/') && !url.starts_with("//") {
        url
    } else {
        return None;
    };
    Some(format!("{}{path}", web.trim_end_matches('/')))
}

pub(super) fn scene_dto(s: &LibScene, web: Option<&str>) -> SceneDto {
    SceneDto {
        ref_: format!("s:{}", s.id),
        id: s.id.clone(),
        title: s.label(),
        studio: s.studio.as_ref().map(|x| x.name.clone()),
        performers: s.performers.iter().map(|p| p.name.clone()).collect(),
        screenshot: web.and_then(|w| s.paths.screenshot.as_deref().and_then(|u| rebase(u, w))),
        preview: web.and_then(|w| s.paths.preview.as_deref().and_then(|u| rebase(u, w))),
        date: s.date.clone(),
        duration: s.files.first().and_then(|f| f.duration),
        link: web.map(|w| format!("{}/scenes/{}", w.trim_end_matches('/'), s.id)),
    }
}

#[cfg(test)]
mod tests {
    use super::rebase;

    #[test]
    fn rebase_keeps_only_a_rooted_path() {
        let w = "https://stash.example/";
        assert_eq!(
            rebase("http://localhost:9999/scene/4/screenshot?t=1", w).as_deref(),
            Some("https://stash.example/scene/4/screenshot?t=1")
        );
        assert_eq!(
            rebase("/scene/4/screenshot", w).as_deref(),
            Some("https://stash.example/scene/4/screenshot")
        );
        assert_eq!(rebase("scene/4/screenshot", w), None);
        assert_eq!(rebase("http://host?x", w), None);
        assert_eq!(rebase("javascript:alert(1)", w), None);
        assert_eq!(rebase("//evil.example/x", w), None);
    }
}
