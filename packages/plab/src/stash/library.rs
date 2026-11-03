//! Library reads for the assistant: what was played, what is unwatched, scene search.
//! Inherent methods on `Stash` (not `StashApi`): only the assistant uses them.
#![allow(dead_code)] // Used by assistant (task 6); remove then.

use std::collections::HashSet;

use serde::Deserialize;
use serde_json::json;

use super::Stash;
use super::types::VideoFile;

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Named {
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Default, Deserialize)]
pub struct ScenePaths {
    #[serde(default)]
    pub screenshot: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LibScene {
    pub id: String,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub date: Option<String>,
    #[serde(default)]
    pub studio: Option<Named>,
    #[serde(default)]
    pub performers: Vec<Named>,
    #[serde(default)]
    pub tags: Vec<Named>,
    #[serde(default)]
    pub play_count: Option<u32>,
    #[serde(default)]
    pub o_counter: Option<u32>,
    #[serde(default)]
    pub rating100: Option<u32>,
    /// RFC 3339.
    #[serde(default)]
    pub last_played_at: Option<String>,
    #[serde(default)]
    pub paths: ScenePaths,
    #[serde(default)]
    pub files: Vec<VideoFile>,
}

impl LibScene {
    pub fn label(&self) -> String {
        if let Some(t) = self.title.as_deref().filter(|t| !t.trim().is_empty()) {
            return t.to_string();
        }
        match self.files.first() {
            Some(f) => f.path.rsplit('/').next().unwrap_or(&f.path).to_string(),
            None => format!("scene {}", self.id),
        }
    }
}

const FIELDS: &str = "id title date studio { id name } performers { id name } tags { id name } \
    play_count o_counter rating100 last_played_at paths { screenshot } files { path duration }";

const SCENES: &[&str] = &["findScenes", "scenes"];

impl Stash {
    pub async fn recent_plays(&self, limit: usize) -> anyhow::Result<Vec<LibScene>> {
        let q = format!(
            "query($n: Int!) {{ findScenes(
               scene_filter: {{play_count: {{value: 0, modifier: GREATER_THAN}}}},
               filter: {{sort: \"last_played_at\", direction: DESC, per_page: $n}})
               {{ scenes {{ {FIELDS} }} }} }}"
        );
        self.query(&q, json!({"n": limit}), SCENES).await
    }

    /// `limit` applies per criterion, so the result can hold up to 2x `limit`.
    pub async fn unwatched(
        &self,
        performer_ids: &[String],
        studio_ids: &[String],
        limit: usize,
    ) -> anyhow::Result<Vec<LibScene>> {
        let mut seen = HashSet::new();
        let mut out = vec![];
        for (field, ids) in [("performers", performer_ids), ("studios", studio_ids)] {
            if ids.is_empty() {
                continue;
            }
            let q = format!(
                "query($ids: [ID!], $n: Int!) {{ findScenes(
                   scene_filter: {{play_count: {{value: 0, modifier: EQUALS}},
                                   {field}: {{value: $ids, modifier: INCLUDES}}}},
                   filter: {{sort: \"date\", direction: DESC, per_page: $n}})
                   {{ scenes {{ {FIELDS} }} }} }}"
            );
            let got: Vec<LibScene> = self
                .query(&q, json!({"ids": ids, "n": limit}), SCENES)
                .await?;
            out.extend(got.into_iter().filter(|s| seen.insert(s.id.clone())));
        }
        Ok(out)
    }

    pub async fn search_scenes(&self, q: &str, limit: usize) -> anyhow::Result<Vec<LibScene>> {
        let query = format!(
            "query($q: String!, $n: Int!) {{ findScenes(filter: {{q: $q, per_page: $n}})
               {{ scenes {{ {FIELDS} }} }} }}"
        );
        self.query(&query, json!({"q": q, "n": limit}), SCENES)
            .await
    }

    pub async fn lib_scenes(&self, ids: &[String]) -> anyhow::Result<Vec<LibScene>> {
        if ids.is_empty() {
            return Ok(vec![]);
        }
        let q = format!(
            "query($ids: [ID!]) {{ findScenes(ids: $ids, filter: {{per_page: -1}})
               {{ scenes {{ {FIELDS} }} }} }}"
        );
        self.query(&q, json!({"ids": ids}), SCENES).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{Value, json};
    use wiremock::matchers::{body_partial_json, body_string_contains, method};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    fn scenes(v: Value) -> ResponseTemplate {
        ResponseTemplate::new(200).set_body_json(json!({"data": {"findScenes": {"scenes": v}}}))
    }

    async fn stash(server: &MockServer) -> Stash {
        Stash::new(&format!("{}/graphql", server.uri()), None)
    }

    #[tokio::test]
    async fn recent_plays_reads_play_fields() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(body_string_contains("last_played_at"))
            .and(body_string_contains("GREATER_THAN"))
            .and(body_partial_json(json!({"variables": {"n": 100}})))
            .respond_with(scenes(json!([{
                "id": "4", "title": "Alpha", "studio": {"id": "s1", "name": "Studio A"},
                "performers": [{"id": "p1", "name": "Performer B"}], "tags": [],
                "play_count": 2, "o_counter": 1, "rating100": 80,
                "last_played_at": "2026-11-01T20:00:00Z",
                "paths": {"screenshot": "http://localhost:9999/scene/4/screenshot"},
                "files": [{"path": "/media/Vault/a.mp4", "duration": 60.0}]
            }])))
            .expect(1)
            .mount(&server)
            .await;
        let got = stash(&server).await.recent_plays(100).await.unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].studio.as_ref().unwrap().name, "Studio A");
        assert_eq!(got[0].o_counter, Some(1));
        assert_eq!(
            got[0].paths.screenshot.as_deref(),
            Some("http://localhost:9999/scene/4/screenshot")
        );
    }

    #[tokio::test]
    async fn unwatched_merges_performer_and_studio_hits() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(body_string_contains("performers: {value: $ids"))
            .and(body_string_contains("EQUALS"))
            .and(body_partial_json(
                json!({"variables": {"ids": ["p1"], "n": 60}}),
            ))
            .respond_with(scenes(json!([{"id": "1"}, {"id": "2"}])))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(body_string_contains("studios: {value: $ids"))
            .and(body_string_contains("EQUALS"))
            .and(body_partial_json(
                json!({"variables": {"ids": ["s1"], "n": 60}}),
            ))
            .respond_with(scenes(json!([{"id": "2"}, {"id": "3"}])))
            .mount(&server)
            .await;
        let got = stash(&server)
            .await
            .unwatched(&["p1".into()], &["s1".into()], 60)
            .await
            .unwrap();
        assert_eq!(
            got.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            vec!["1", "2", "3"]
        );
    }

    #[tokio::test]
    async fn search_scenes_sends_query_and_limit() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(body_partial_json(
                json!({"variables": {"q": "alpha", "n": 20}}),
            ))
            .respond_with(scenes(json!([{"id": "7", "title": "Alpha"}])))
            .expect(1)
            .mount(&server)
            .await;
        let got = stash(&server)
            .await
            .search_scenes("alpha", 20)
            .await
            .unwrap();
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].label(), "Alpha");
    }

    #[tokio::test]
    async fn lib_scenes_sends_ids() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(body_partial_json(json!({"variables": {"ids": ["4", "5"]}})))
            .respond_with(scenes(json!([{"id": "4"}, {"id": "5"}])))
            .expect(1)
            .mount(&server)
            .await;
        let ids = vec!["4".to_string(), "5".to_string()];
        let got = stash(&server).await.lib_scenes(&ids).await.unwrap();
        assert_eq!(
            got.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            vec!["4", "5"]
        );
    }

    #[tokio::test]
    async fn unwatched_without_ids_asks_nothing() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(scenes(json!([])))
            .expect(0)
            .mount(&server)
            .await;
        assert!(
            stash(&server)
                .await
                .unwatched(&[], &[], 60)
                .await
                .unwrap()
                .is_empty()
        );
        assert!(
            stash(&server)
                .await
                .lib_scenes(&[])
                .await
                .unwrap()
                .is_empty()
        );
    }

    #[test]
    fn label_falls_back_to_the_file_name() {
        let s: LibScene = serde_json::from_value(json!({
            "id": "5", "files": [{"path": "/media/Vault/dir/clip one.mp4"}]
        }))
        .unwrap();
        assert_eq!(s.label(), "clip one.mp4");
        let s: LibScene = serde_json::from_value(json!({"id": "6"})).unwrap();
        assert_eq!(s.label(), "scene 6");
    }
}
