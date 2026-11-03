//! Thin Stash GraphQL client for identify.

pub mod de;
pub mod library;
pub mod types;

use std::collections::HashSet;
use std::future::Future;
use std::time::Duration;

use anyhow::Context;
use serde_json::{Value, json};

use crate::http;
pub use types::*;

const SCENE_FIELDS: &str =
    "id title code details director date urls studio { id name } performers { id }
  tags { id } stash_ids { endpoint stash_id } files { path duration }";

const SCRAPED_FIELDS: &str = "title code details director urls date image duration remote_site_id
  studio { name urls image details aliases remote_site_id parent { name remote_site_id } }
  performers { name disambiguation gender urls birthdate death_date ethnicity country
    eye_color hair_color height weight measurements
    career_start career_end tattoos piercings aliases details images remote_site_id }
  tags { name stored_id }";

// Saved task defaults from the Stash UI. The output shapes match the job input types
// field for field, so they pass straight through once nulls are stripped.
const DEFAULTS_QUERY: &str = "{ configuration { defaults {
  scan { rescan scanGenerateCovers scanGeneratePreviews scanGenerateImagePreviews
    scanGenerateSprites scanGeneratePhashes scanGenerateImagePhashes scanGenerateThumbnails
    scanGenerateClipPreviews }
  generate { covers sprites previews imagePreviews markers markerImagePreviews
    markerScreenshots transcodes phashes interactiveHeatmapsSpeeds imageThumbnails clipPreviews
    previewOptions { previewSegments previewSegmentDuration previewExcludeStart
      previewExcludeEnd previewPreset } }
  identify { sources { source { scraper_id stash_box_index stash_box_endpoint }
      options { fieldOptions { field strategy createMissing } setCoverImage setOrganized
  includeMalePerformers performerGenders skipMultipleMatches skipMultipleMatchTag
  skipSingleNamePerformers skipSingleNamePerformerTag } }
    options { fieldOptions { field strategy createMissing } setCoverImage setOrganized
  includeMalePerformers performerGenders skipMultipleMatches skipMultipleMatchTag
  skipSingleNamePerformers skipSingleNamePerformerTag } } } } }";

pub const JOB_TIMEOUT: u64 = 6 * 3600;
pub const JOB_POLL: u64 = 5;

fn job_input_type(mutation: &str) -> &'static str {
    match mutation {
        "metadataScan" => "ScanMetadataInput",
        "metadataGenerate" => "GenerateMetadataInput",
        "metadataIdentify" => "IdentifyMetadataInput",
        other => unreachable!("no job mutation {other}"),
    }
}

/// A GraphQL `errors` reply: its messages, joined with "; ".
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct GqlError(pub String);

#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct JobFailed(pub String);

#[derive(serde::Deserialize)]
struct Job {
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    error: Option<String>,
}

pub trait StashApi: Send + Sync {
    fn defaults(&self) -> impl Future<Output = anyhow::Result<Defaults>> + Send;
    fn video_extensions(&self) -> impl Future<Output = anyhow::Result<Vec<String>>> + Send;
    fn codedb_api_key(&self) -> impl Future<Output = anyhow::Result<Option<String>>> + Send;
    fn scan(
        &self,
        paths: Option<Vec<String>>,
        options: &JobOptions,
    ) -> impl Future<Output = anyhow::Result<()>> + Send;
    fn generate(
        &self,
        scene_ids: Option<Vec<String>>,
        options: &JobOptions,
    ) -> impl Future<Output = anyhow::Result<()>> + Send;
    fn identify(
        &self,
        scene_ids: Vec<String>,
        options: &JobOptions,
    ) -> impl Future<Output = anyhow::Result<()>> + Send;
    fn max_scene_id(&self) -> impl Future<Output = anyhow::Result<i64>> + Send;
    fn scene_ids_after(&self, id: i64) -> impl Future<Output = anyhow::Result<Vec<String>>> + Send;
    fn scenes(&self, ids: &[String]) -> impl Future<Output = anyhow::Result<Vec<Scene>>> + Send;
    fn bare_scenes(&self) -> impl Future<Output = anyhow::Result<Vec<Scene>>> + Send;
    fn scenes_with_tag(
        &self,
        tag_id: &str,
    ) -> impl Future<Output = anyhow::Result<Vec<Scene>>> + Send;
    fn search(
        &self,
        endpoint: &str,
        query: &str,
    ) -> impl Future<Output = anyhow::Result<Vec<Candidate>>> + Send;
    /// What `endpoint` matches each scene to by fingerprint (as Stash's identify would),
    /// one list per id, in order.
    fn fingerprint_matches(
        &self,
        endpoint: &str,
        scene_ids: &[String],
    ) -> impl Future<Output = anyhow::Result<Vec<Vec<FingerprintMatch>>>> + Send;
    fn scrape_url(
        &self,
        url: &str,
    ) -> impl Future<Output = anyhow::Result<Option<Candidate>>> + Send;
    fn performer_by_stash_id(
        &self,
        endpoint: &str,
        id: &str,
    ) -> impl Future<Output = anyhow::Result<Option<String>>> + Send;
    fn studio_by_stash_id(
        &self,
        endpoint: &str,
        id: &str,
    ) -> impl Future<Output = anyhow::Result<Option<String>>> + Send;
    fn performers_like(
        &self,
        name: &str,
    ) -> impl Future<Output = anyhow::Result<Vec<NamedRecord>>> + Send;
    fn studios_like(
        &self,
        name: &str,
    ) -> impl Future<Output = anyhow::Result<Vec<NamedRecord>>> + Send;
    fn tag_id(
        &self,
        name: &str,
        create: bool,
    ) -> impl Future<Output = anyhow::Result<Option<String>>> + Send;
    fn create_performer(
        &self,
        inp: &PerformerCreate,
    ) -> impl Future<Output = anyhow::Result<String>> + Send;
    fn create_studio(
        &self,
        inp: &StudioCreate,
    ) -> impl Future<Output = anyhow::Result<String>> + Send;
    fn update_scene(&self, inp: &SceneUpdate) -> impl Future<Output = anyhow::Result<()>> + Send;
}

/// Concatenate record lists, keeping the first occurrence of each id.
fn dedupe_by_id(groups: [Vec<NamedRecord>; 2]) -> Vec<NamedRecord> {
    let mut seen = HashSet::new();
    groups
        .into_iter()
        .flatten()
        .filter(|r| seen.insert(r.id.clone()))
        .collect()
}

pub struct Stash {
    http: reqwest::Client,
    url: String,
    api_key: Option<String>,
    /// JOB_POLL; shortened by tests.
    pub(crate) job_poll: Duration,
}

impl Stash {
    pub fn new(url: &str, api_key: Option<String>) -> Stash {
        Stash {
            http: http::client(120),
            url: url.to_string(),
            api_key: api_key.filter(|k| !k.is_empty()),
            job_poll: Duration::from_secs(JOB_POLL),
        }
    }

    async fn gql(&self, query: &str, variables: Value) -> anyhow::Result<Value> {
        let headers: Vec<(&str, String)> = match &self.api_key {
            Some(k) => vec![("ApiKey", k.clone())],
            None => vec![],
        };
        let mut d = http::post_json(
            &self.http,
            &self.url,
            &json!({"query": query, "variables": variables}),
            &headers,
        )
        .await?;
        if let Some(errors) = d
            .get("errors")
            .and_then(Value::as_array)
            .filter(|e| !e.is_empty())
        {
            let messages: Vec<&str> = errors
                .iter()
                .map(|e| e.get("message").and_then(Value::as_str).unwrap_or("?"))
                .collect();
            return Err(GqlError(messages.join("; ")).into());
        }
        d.get_mut("data")
            .map(Value::take)
            .context("no data in the Stash reply")
    }

    /// `query`'s reply at `path`, deserialized; an error naming the path when it is missing
    /// or not a `T`.
    async fn query<T: serde::de::DeserializeOwned>(
        &self,
        query: &str,
        variables: Value,
        path: &[&str],
    ) -> anyhow::Result<T> {
        let mut v = self.gql(query, variables).await?;
        for k in path {
            v = v
                .get_mut(*k)
                .map(Value::take)
                .with_context(|| format!("no {} in the Stash reply", path.join(".")))?;
        }
        serde_json::from_value(v).with_context(|| format!("{} in the Stash reply", path.join(".")))
    }

    async fn run_job(&self, mutation: &str, inp: Value) -> anyhow::Result<()> {
        let q = format!(
            "mutation($i: {}!) {{ {mutation}(input: $i) }}",
            job_input_type(mutation)
        );
        let job: String = match self
            .query::<Value>(&q, json!({"i": inp}), &[mutation])
            .await?
        {
            Value::String(s) => s,
            other => other.to_string(),
        };
        let deadline = tokio::time::Instant::now() + Duration::from_secs(JOB_TIMEOUT);
        while tokio::time::Instant::now() < deadline {
            let j: Option<Job> = self
                .query(
                    "query($id: ID!) { findJob(input: {id: $id}) { status error } }",
                    json!({"id": job}),
                    &["findJob"],
                )
                .await?;
            // Finished jobs are pruned from the queue after a grace period.
            let Some(j) = j else { return Ok(()) };
            let status = j.status.as_deref();
            if status == Some("FINISHED") {
                return Ok(());
            }
            if let Some(s @ ("FAILED" | "CANCELLED")) = status {
                let error = j.error.as_deref().unwrap_or("");
                return Err(JobFailed(format!("{mutation} job {job}: {s} {error}")).into());
            }
            tokio::time::sleep(self.job_poll).await;
        }
        Err(JobFailed(format!(
            "{mutation} job {job}: timed out after {JOB_TIMEOUT}s"
        ))
        .into())
    }

    async fn by_stash_id(
        &self,
        kind: &str,
        endpoint: &str,
        stash_id: &str,
    ) -> anyhow::Result<Option<String>> {
        let lower = kind.to_lowercase();
        let q = format!(
            "query($e: String!, $s: String!) {{ find{kind}s(
              {lower}_filter: {{stash_id_endpoint: {{endpoint: $e, stash_id: $s, modifier: EQUALS}}}})
              {{ {lower}s {{ id }} }} }}"
        );
        let hits: Vec<Ref> = self
            .query(
                &q,
                json!({"e": endpoint, "s": stash_id}),
                &[&format!("find{kind}s"), &format!("{lower}s")],
            )
            .await?;
        Ok(hits.into_iter().next().map(|h| h.id))
    }
}

impl StashApi for Stash {
    // --- configuration -------------------------------------------------------

    async fn defaults(&self) -> anyhow::Result<Defaults> {
        self.query(DEFAULTS_QUERY, json!({}), &["configuration", "defaults"])
            .await
    }

    async fn video_extensions(&self) -> anyhow::Result<Vec<String>> {
        let q = "{ configuration { general { videoExtensions } } }";
        self.query(
            q,
            json!({}),
            &["configuration", "general", "videoExtensions"],
        )
        .await
    }

    /// The key Stash holds for the code database's stash-box, reused for its code search.
    async fn codedb_api_key(&self) -> anyhow::Result<Option<String>> {
        #[derive(serde::Deserialize)]
        struct StashBox {
            #[serde(default)]
            endpoint: String,
            #[serde(default, deserialize_with = "de::nonempty")]
            api_key: Option<String>,
        }
        let q = "{ configuration { general { stashBoxes { endpoint api_key } } } }";
        let boxes: Vec<StashBox> = self
            .query(q, json!({}), &["configuration", "general", "stashBoxes"])
            .await?;
        Ok(boxes
            .into_iter()
            .find(|b| b.endpoint == crate::site::get().code_db.box_endpoint && b.api_key.is_some())
            .and_then(|b| b.api_key))
    }

    // --- jobs ----------------------------------------------------------------

    async fn scan(&self, paths: Option<Vec<String>>, options: &JobOptions) -> anyhow::Result<()> {
        let extra = paths.filter(|p| !p.is_empty()).map(|p| ("paths", json!(p)));
        self.run_job("metadataScan", options.with(extra)).await
    }

    async fn generate(
        &self,
        scene_ids: Option<Vec<String>>,
        options: &JobOptions,
    ) -> anyhow::Result<()> {
        let ids = scene_ids.map(|ids| ("sceneIDs", json!(ids)));
        self.run_job(
            "metadataGenerate",
            options.with([("overwrite", json!(false))].into_iter().chain(ids)),
        )
        .await
    }

    async fn identify(&self, scene_ids: Vec<String>, options: &JobOptions) -> anyhow::Result<()> {
        self.run_job(
            "metadataIdentify",
            options.with([("sceneIDs", json!(scene_ids))]),
        )
        .await
    }

    // --- scenes --------------------------------------------------------------

    async fn max_scene_id(&self) -> anyhow::Result<i64> {
        let scenes: Vec<Ref> = self
            .query(
                "{ findScenes(filter: {sort: \"id\", direction: DESC, per_page: 1}) { scenes { id } } }",
                json!({}),
                &["findScenes", "scenes"],
            )
            .await?;
        match scenes.first() {
            Some(s) => Ok(s.id.parse()?),
            None => Ok(0),
        }
    }

    async fn scene_ids_after(&self, scene_id: i64) -> anyhow::Result<Vec<String>> {
        let scenes: Vec<Ref> = self
            .query(
                "query($v: Int!) { findScenes(
              scene_filter: {id: {value: $v, modifier: GREATER_THAN}}, filter: {per_page: -1})
              { scenes { id } } }",
                json!({"v": scene_id}),
                &["findScenes", "scenes"],
            )
            .await?;
        Ok(scenes.into_iter().map(|s| s.id).collect())
    }

    async fn scenes(&self, ids: &[String]) -> anyhow::Result<Vec<Scene>> {
        let q = format!(
            "query($ids: [ID!]) {{ findScenes(ids: $ids, filter: {{per_page: -1}}) \
             {{ scenes {{ {SCENE_FIELDS} }} }} }}"
        );
        self.query(&q, json!({"ids": ids}), &["findScenes", "scenes"])
            .await
    }

    async fn bare_scenes(&self) -> anyhow::Result<Vec<Scene>> {
        let q = format!(
            "{{ findScenes(scene_filter: {{is_missing: \"title\"}}, filter: {{per_page: -1}}) \
             {{ scenes {{ {SCENE_FIELDS} }} }} }}"
        );
        let scenes: Vec<Scene> = self.query(&q, json!({}), &["findScenes", "scenes"]).await?;
        Ok(scenes
            .into_iter()
            .filter(|s| s.studio.is_none() && s.performers.is_empty())
            .collect())
    }

    async fn scenes_with_tag(&self, tag_id: &str) -> anyhow::Result<Vec<Scene>> {
        let q = format!(
            "query($t: [ID!]) {{ findScenes(
              scene_filter: {{tags: {{value: $t, modifier: INCLUDES}}}}, filter: {{per_page: -1}})
              {{ scenes {{ {SCENE_FIELDS} }} }} }}"
        );
        self.query(&q, json!({"t": [tag_id]}), &["findScenes", "scenes"])
            .await
    }

    async fn search(&self, endpoint: &str, query: &str) -> anyhow::Result<Vec<Candidate>> {
        let q = format!(
            "query($s: ScraperSourceInput!, $i: ScrapeSingleSceneInput!) {{
              scrapeSingleScene(source: $s, input: $i) {{ {SCRAPED_FIELDS} }} }}"
        );
        self.query(
            &q,
            json!({"s": {"stash_box_endpoint": endpoint}, "i": {"query": query}}),
            &["scrapeSingleScene"],
        )
        .await
    }

    async fn fingerprint_matches(
        &self,
        endpoint: &str,
        scene_ids: &[String],
    ) -> anyhow::Result<Vec<Vec<FingerprintMatch>>> {
        let per_scene: Vec<Vec<FingerprintMatch>> = self
            .query(
                "query($s: ScraperSourceInput!, $i: ScrapeMultiScenesInput!) {
                  scrapeMultiScenes(source: $s, input: $i) { title duration } }",
                json!({"s": {"stash_box_endpoint": endpoint}, "i": {"scene_ids": scene_ids}}),
                &["scrapeMultiScenes"],
            )
            .await?;
        anyhow::ensure!(
            per_scene.len() == scene_ids.len(),
            "scrapeMultiScenes answered {} of {} scenes",
            per_scene.len(),
            scene_ids.len()
        );
        Ok(per_scene)
    }

    /// Scrape one scene page with whichever installed scraper claims its URL.
    async fn scrape_url(&self, url: &str) -> anyhow::Result<Option<Candidate>> {
        let q = format!("query($u: String!) {{ scrapeSceneURL(url: $u) {{ {SCRAPED_FIELDS} }} }}");
        self.query(&q, json!({"u": url}), &["scrapeSceneURL"]).await
    }

    // --- lookups and creates ---------------------------------------------------

    async fn performer_by_stash_id(
        &self,
        endpoint: &str,
        id: &str,
    ) -> anyhow::Result<Option<String>> {
        self.by_stash_id("Performer", endpoint, id).await
    }

    async fn studio_by_stash_id(&self, endpoint: &str, id: &str) -> anyhow::Result<Option<String>> {
        self.by_stash_id("Studio", endpoint, id).await
    }

    async fn performers_like(&self, name: &str) -> anyhow::Result<Vec<NamedRecord>> {
        // The q= search is a fuzzy full-text search capped at 50 hits and not ordered by
        // relevance, so it can miss a performer by their own exact name entirely (seen for
        // "Be", "Ro", ...), which then makes resolve_performer create a duplicate every
        // pass. An exact-name lookup alongside it closes that gap; q= is kept for alias
        // matching, which an exact-name filter can't do.
        let path = ["findPerformers", "performers"];
        let exact = self
            .query(
                "query($n: String!) { findPerformers(
              performer_filter: {name: {value: $n, modifier: EQUALS}}, filter: {per_page: -1})
              { performers { id name alias_list } } }",
                json!({"n": name}),
                &path,
            )
            .await?;
        let fuzzy = self
            .query(
                "query($q: String!) { findPerformers(filter: {q: $q, per_page: 50})
              { performers { id name alias_list } } }",
                json!({"q": name}),
                &path,
            )
            .await?;
        Ok(dedupe_by_id([exact, fuzzy]))
    }

    async fn studios_like(&self, name: &str) -> anyhow::Result<Vec<NamedRecord>> {
        let path = ["findStudios", "studios"];
        let exact = self
            .query(
                "query($n: String!) { findStudios(
              studio_filter: {name: {value: $n, modifier: EQUALS}}, filter: {per_page: -1})
              { studios { id name aliases } } }",
                json!({"n": name}),
                &path,
            )
            .await?;
        let fuzzy = self
            .query(
                "query($q: String!) { findStudios(filter: {q: $q, per_page: 50})
              { studios { id name aliases } } }",
                json!({"q": name}),
                &path,
            )
            .await?;
        Ok(dedupe_by_id([exact, fuzzy]))
    }

    async fn tag_id(&self, name: &str, create: bool) -> anyhow::Result<Option<String>> {
        let tags: Vec<NamedRecord> = self
            .query(
                "query($q: String!) { findTags(filter: {q: $q, per_page: 50})
              { tags { id name } } }",
                json!({"q": name}),
                &["findTags", "tags"],
            )
            .await?;
        if let Some(t) = tags.into_iter().find(|t| t.name.as_deref() == Some(name)) {
            return Ok(Some(t.id));
        }
        if !create {
            return Ok(None);
        }
        let created: Ref = self
            .query(
                "mutation($i: TagCreateInput!) { tagCreate(input: $i) { id } }",
                json!({"i": {"name": name}}),
                &["tagCreate"],
            )
            .await?;
        Ok(Some(created.id))
    }

    async fn create_performer(&self, inp: &PerformerCreate) -> anyhow::Result<String> {
        let r: Ref = self
            .query(
                "mutation($i: PerformerCreateInput!) { performerCreate(input: $i) { id } }",
                json!({"i": inp}),
                &["performerCreate"],
            )
            .await?;
        Ok(r.id)
    }

    async fn create_studio(&self, inp: &StudioCreate) -> anyhow::Result<String> {
        let r: Ref = self
            .query(
                "mutation($i: StudioCreateInput!) { studioCreate(input: $i) { id } }",
                json!({"i": inp}),
                &["studioCreate"],
            )
            .await?;
        Ok(r.id)
    }

    async fn update_scene(&self, inp: &SceneUpdate) -> anyhow::Result<()> {
        self.gql(
            "mutation($i: SceneUpdateInput!) { sceneUpdate(input: $i) { id } }",
            json!({"i": inp}),
        )
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use wiremock::matchers::{body_string_contains, method};
    use wiremock::{Mock, MockServer, Request, ResponseTemplate};

    fn data(v: Value) -> ResponseTemplate {
        ResponseTemplate::new(200).set_body_json(json!({ "data": v }))
    }

    fn queries(reqs: &[Request]) -> Vec<(String, Value)> {
        reqs.iter()
            .map(|r| {
                let b: Value = serde_json::from_slice(&r.body).unwrap();
                (
                    b["query"].as_str().unwrap().to_string(),
                    b["variables"].clone(),
                )
            })
            .collect()
    }

    // --- StashLookupTest. Real Stash: the q= fuzzy search is capped at 50 hits and not
    // relevance-ordered, so it can miss a performer/studio's own exact name (seen live
    // for "Be", "Ro", ...). performers_like/studios_like must also run an exact-name
    // lookup and union the results.

    #[tokio::test]
    async fn performers_like_unions_exact_and_fuzzy_by_id() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(body_string_contains("performer_filter"))
            .respond_with(data(json!({"findPerformers": {"performers": [
                {"id": "1", "name": "Be", "alias_list": []}]}})))
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .respond_with(data(json!({"findPerformers": {"performers": [
                {"id": "1", "name": "Be", "alias_list": []},
                {"id": "2", "name": "Bee", "alias_list": []}]}})))
            .with_priority(2)
            .mount(&server)
            .await;
        let s = Stash::new(&server.uri(), None);
        let result = s.performers_like("Be").await.unwrap();
        let ids = result.iter().map(|r| r.id.as_str()).collect::<Vec<_>>();
        assert_eq!(ids, ["1", "2"]);
        let calls = queries(&server.received_requests().await.unwrap());
        assert_eq!(calls.len(), 2);
        let exact = calls
            .iter()
            .find(|(q, _)| q.contains("performer_filter"))
            .unwrap();
        assert!(exact.0.contains("modifier: EQUALS"));
        assert!(exact.0.contains("per_page: -1"));
        assert_eq!(exact.1, json!({"n": "Be"}));
    }

    #[tokio::test]
    async fn studios_like_unions_exact_and_fuzzy_by_id() {
        let server = MockServer::start().await;
        // The exact-name query finds "Ro", which the capped/unordered q= search below
        // misses entirely.
        Mock::given(method("POST"))
            .and(body_string_contains("studio_filter"))
            .respond_with(data(json!({"findStudios": {"studios": [
                {"id": "9", "name": "Ro", "aliases": []}]}})))
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .respond_with(data(json!({"findStudios": {"studios": [
                {"id": "10", "name": "Robot", "aliases": []}]}})))
            .with_priority(2)
            .mount(&server)
            .await;
        let s = Stash::new(&server.uri(), None);
        let result = s.studios_like("Ro").await.unwrap();
        let ids = result.iter().map(|r| r.id.as_str()).collect::<Vec<_>>();
        assert_eq!(ids, ["9", "10"]);
        let calls = queries(&server.received_requests().await.unwrap());
        assert_eq!(calls.len(), 2);
        let exact = calls
            .iter()
            .find(|(q, _)| q.contains("studio_filter"))
            .unwrap();
        assert!(exact.0.contains("modifier: EQUALS"));
        assert!(exact.0.contains("per_page: -1"));
    }

    // --- ClientTest (the Stash halves) -------------------------------------------------

    #[tokio::test]
    async fn codedb_api_key_from_stash_box_config() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(data(json!({"configuration": {"general": {"stashBoxes": [
                {"endpoint": "https://stashdb.org/graphql", "api_key": "sdb"},
                {"endpoint": "https://codes.example/graphql", "api_key": "tp"}]}}})))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .respond_with(data(
                json!({"configuration": {"general": {"stashBoxes": []}}}),
            ))
            .mount(&server)
            .await;
        let s = Stash::new(&server.uri(), None);
        assert_eq!(s.codedb_api_key().await.unwrap().as_deref(), Some("tp"));
        assert_eq!(s.codedb_api_key().await.unwrap(), None);
    }

    #[tokio::test]
    async fn scenes_with_tag_filters_by_tag() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(data(json!({"findScenes": {"scenes": [{"id": "20"}]}})))
            .mount(&server)
            .await;
        let s = Stash::new(&server.uri(), None);
        let scenes = s.scenes_with_tag("77").await.unwrap();
        assert_eq!(
            scenes.iter().map(|s| s.id.as_str()).collect::<Vec<_>>(),
            ["20"]
        );
        let (query, variables) = queries(&server.received_requests().await.unwrap())
            .into_iter()
            .next()
            .unwrap();
        assert!(query.contains("tags:"));
        assert!(query.contains("INCLUDES"));
        assert_eq!(variables, json!({"t": ["77"]}));
    }

    // --- transport and query shape --------------------------------------------------------

    #[tokio::test]
    async fn api_key_header_and_graphql_errors() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(wiremock::matchers::header("ApiKey", "k"))
            .respond_with(ResponseTemplate::new(200).set_body_json(
                json!({"errors": [{"message": "nil pointer dereference"}], "data": null}),
            ))
            .mount(&server)
            .await;
        let s = Stash::new(&server.uri(), Some("k".into()));
        let e = s.scrape_url("https://x/").await.unwrap_err();
        let g = e.downcast_ref::<GqlError>().unwrap();
        assert_eq!(g.0, "nil pointer dereference");
    }

    #[test]
    fn defaults_query_keeps_its_shape() {
        assert!(DEFAULTS_QUERY.starts_with("{ configuration { defaults {\n  scan { rescan"));
        assert_eq!(
            DEFAULTS_QUERY.matches("skipSingleNamePerformerTag").count(),
            2
        );
        assert!(DEFAULTS_QUERY.ends_with("skipSingleNamePerformerTag } } } } }"));
    }

    #[tokio::test]
    async fn defaults_strips_nulls() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(data(json!({"configuration": {"defaults": {
                "scan": {"rescan": null, "scanGenerateCovers": true},
                "identify": {"sources": [{"source": {"scraper_id": null,
                                                     "stash_box_endpoint": "e"}}]}}}})))
            .mount(&server)
            .await;
        let s = Stash::new(&server.uri(), None);
        let d = s.defaults().await.unwrap();
        assert_eq!(
            json!(d),
            json!({"scan": {"scanGenerateCovers": true}, "generate": {},
                   "identify": {"sources": [{"source": {"stash_box_endpoint": "e"}}]}})
        );
    }

    #[tokio::test]
    async fn bare_scenes_drop_scenes_with_studio_or_performers() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .respond_with(data(json!({"findScenes": {"scenes": [
                {"id": "1", "studio": null, "performers": []},
                {"id": "2", "studio": {"id": "9"}, "performers": []},
                {"id": "3", "studio": null, "performers": [{"id": "4"}]}]}})))
            .mount(&server)
            .await;
        let s = Stash::new(&server.uri(), None);
        let scenes = s.bare_scenes().await.unwrap();
        let ids = scenes.iter().map(|x| x.id.as_str()).collect::<Vec<_>>();
        assert_eq!(ids, ["1"]);
    }

    #[tokio::test]
    async fn job_polls_until_finished() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(body_string_contains("metadataScan"))
            .respond_with(data(json!({"metadataScan": "7"})))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(body_string_contains("findJob"))
            .respond_with(data(
                json!({"findJob": {"status": "RUNNING", "error": null}}),
            ))
            .up_to_n_times(2)
            .with_priority(1)
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(body_string_contains("findJob"))
            .respond_with(data(json!({"findJob": null})))
            .with_priority(2)
            .mount(&server)
            .await;
        let mut s = Stash::new(&server.uri(), None);
        s.job_poll = std::time::Duration::from_millis(1);
        s.scan(
            Some(vec!["/media/Vault/a".into()]),
            &serde_json::from_value(json!({"rescan": true})).unwrap(),
        )
        .await
        .unwrap();
        let calls = queries(&server.received_requests().await.unwrap());
        assert_eq!(calls.len(), 4);
        assert_eq!(
            calls[0].0,
            "mutation($i: ScanMetadataInput!) { metadataScan(input: $i) }"
        );
        assert_eq!(
            calls[0].1,
            json!({"i": {"rescan": true, "paths": ["/media/Vault/a"]}})
        );
        assert_eq!(calls[1].1, json!({"id": "7"}));
    }

    #[tokio::test]
    async fn failed_job_is_job_failed() {
        let server = MockServer::start().await;
        Mock::given(method("POST"))
            .and(body_string_contains("metadataIdentify"))
            .respond_with(data(json!({"metadataIdentify": "8"})))
            .mount(&server)
            .await;
        Mock::given(method("POST"))
            .and(body_string_contains("findJob"))
            .respond_with(data(
                json!({"findJob": {"status": "FAILED", "error": "boom"}}),
            ))
            .mount(&server)
            .await;
        let s = Stash::new(&server.uri(), None);
        let e = s
            .identify(vec!["1".into()], &JobOptions::default())
            .await
            .unwrap_err();
        assert_eq!(
            e.downcast_ref::<JobFailed>().unwrap().0,
            "metadataIdentify job 8: FAILED boom"
        );
        let calls = queries(&server.received_requests().await.unwrap());
        assert_eq!(calls[0].1, json!({"i": {"sceneIDs": ["1"]}}));
    }
}
