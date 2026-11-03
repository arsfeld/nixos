//! Port of stash-identify `test_main.py` (all but the watcher tests, which are Task 15),
//! with fake Stash, LLM and code-database clients.

use std::collections::{HashMap, HashSet};
use std::io::Write;
use std::path::PathBuf;
use std::sync::{Arc, LazyLock, Mutex};

use anyhow::anyhow;
use serde_json::{Value, json};

use super::*;
use crate::codedb::{CodeDbError, CodeHit, CodeSearch};
use crate::db::{Db, IDENTIFY_FAILURE_LIMIT};
use crate::llm::{ChoiceAnswer, JevRequest, Llm};
use crate::stash::{
    Candidate, Defaults, FingerprintMatch, GqlError, JobFailed, JobOptions, NamedRecord, Scene,
    StashApi,
};

const CODEDB: &str = "https://codes.example/graphql";
const CODE_URL: &str = "https://api.codes.example/code";
const FC2_URL: &str = "https://fc2.example/article/1000006/";

static PATHS: LazyLock<Paths> = LazyLock::new(Paths::default);

fn scene(v: Value) -> Scene {
    serde_json::from_value(v).expect("test scene")
}

fn cand(v: Value) -> Candidate {
    serde_json::from_value(v).expect("test candidate")
}

fn parse_of(v: Value) -> Parse {
    serde_json::from_value(v).expect("test parse")
}

fn named(v: Value) -> NamedRecord {
    serde_json::from_value(v).expect("test record")
}

// --- fakes -------------------------------------------------------------------------

/// A fake endpoint's fingerprint matches by scene id, or how its lookup fails.
type Fingerprints = Result<HashMap<&'static str, Vec<FingerprintMatch>>, Fail>;

/// What a fake raises in place of answering.
#[derive(Clone)]
enum Fail {
    /// A GraphQL error reply.
    Gql(&'static str),
    /// A transport failure.
    Net,
    /// Any other failure.
    Msg(&'static str),
    /// Must never be reached.
    Panic(&'static str),
}

fn net_error() -> anyhow::Error {
    reqwest::Client::new()
        .get("not a url")
        .build()
        .unwrap_err()
        .into()
}

impl Fail {
    fn err(&self) -> anyhow::Error {
        match self {
            Fail::Gql(m) => GqlError(m.to_string()).into(),
            Fail::Net => net_error(),
            Fail::Msg(m) => anyhow!("{m}"),
            Fail::Panic(m) => panic!("{m}"),
        }
    }
}

/// A Stash job the fake ran: its name and the paths or scene ids it was given.
type Job = (&'static str, Option<Vec<String>>);

#[derive(Default)]
struct FakeStash {
    results: HashMap<String, Result<Vec<Candidate>, Fail>>,
    performers: Vec<NamedRecord>,
    studios: Vec<NamedRecord>,
    tags: Mutex<HashMap<String, String>>,
    updates: Mutex<Vec<Value>>,
    created: Mutex<Vec<(String, Value)>>,
    tagged: Vec<Scene>,
    fc2: HashMap<String, Result<Option<Candidate>, Fail>>,
    scraped_urls: Mutex<Vec<String>>,
    // PassStash
    bare: Vec<Scene>,
    bare_forbidden: bool,
    scenes_dict: HashMap<String, Scene>,
    missing: HashSet<String>,
    jobs: Mutex<Vec<Job>>,
    scan_fails: bool,
    /// endpoint -> scene id -> its fingerprint matches; Err fails the endpoint's lookup.
    fingerprints: HashMap<&'static str, Fingerprints>,
    update_fails: Option<Fail>,
    /// bare_scenes calls in progress, and the most there ever were at once.
    in_flight: std::sync::atomic::AtomicUsize,
    max_in_flight: std::sync::atomic::AtomicUsize,
}

impl FakeStash {
    fn with_results(results: Vec<(&str, Result<Vec<Value>, Fail>)>) -> FakeStash {
        FakeStash {
            results: results
                .into_iter()
                .map(|(k, v)| {
                    (
                        k.to_string(),
                        v.map(|hits| hits.into_iter().map(cand).collect()),
                    )
                })
                .collect(),
            ..Default::default()
        }
    }

    fn pass(bare: Vec<Scene>) -> FakeStash {
        FakeStash {
            bare,
            ..Default::default()
        }
    }

    fn updates(&self) -> Vec<Value> {
        self.updates.lock().unwrap().clone()
    }

    fn created(&self) -> Vec<(String, Value)> {
        self.created.lock().unwrap().clone()
    }

    fn jobs(&self) -> Vec<Job> {
        self.jobs.lock().unwrap().clone()
    }

    fn update_ids(&self) -> Vec<String> {
        self.updates()
            .iter()
            .map(|u| u["id"].as_str().unwrap().to_string())
            .collect()
    }
}

impl StashApi for FakeStash {
    async fn defaults(&self) -> anyhow::Result<Defaults> {
        Ok(Defaults::default())
    }
    async fn video_extensions(&self) -> anyhow::Result<Vec<String>> {
        unimplemented!()
    }
    async fn codedb_api_key(&self) -> anyhow::Result<Option<String>> {
        unimplemented!()
    }
    async fn scan(&self, paths: Option<Vec<String>>, _options: &JobOptions) -> anyhow::Result<()> {
        if self.scan_fails {
            return Err(JobFailed("scan failed".into()).into());
        }
        self.jobs.lock().unwrap().push(("scan", paths));
        Ok(())
    }
    async fn generate(
        &self,
        ids: Option<Vec<String>>,
        _options: &JobOptions,
    ) -> anyhow::Result<()> {
        self.jobs.lock().unwrap().push(("generate", ids));
        Ok(())
    }
    async fn identify(&self, ids: Vec<String>, _options: &JobOptions) -> anyhow::Result<()> {
        self.jobs.lock().unwrap().push(("identify", Some(ids)));
        Ok(())
    }
    async fn max_scene_id(&self) -> anyhow::Result<i64> {
        Ok(10)
    }
    async fn scene_ids_after(&self, _id: i64) -> anyhow::Result<Vec<String>> {
        Ok(vec!["11".into()])
    }
    async fn scenes(&self, ids: &[String]) -> anyhow::Result<Vec<Scene>> {
        // Real Stash still returns a scene's current data on a plain re-fetch; only an
        // id in `missing` simulates one deleted mid-run. `scenes_dict` overrides a bare
        // entry to stage a "fresh copy differs from the stale one" case.
        let mut by_id: HashMap<String, Scene> = self
            .bare
            .iter()
            .map(|s| (s.id.clone(), s.clone()))
            .collect();
        by_id.extend(self.scenes_dict.clone());
        Ok(ids
            .iter()
            .filter(|id| !self.missing.contains(*id))
            .filter_map(|id| by_id.get(id).cloned())
            .collect())
    }
    async fn bare_scenes(&self) -> anyhow::Result<Vec<Scene>> {
        use std::sync::atomic::Ordering::SeqCst;
        assert!(!self.bare_forbidden, "bare_scenes should not be called");
        let n = self.in_flight.fetch_add(1, SeqCst) + 1;
        self.max_in_flight.fetch_max(n, SeqCst);
        // Long enough for a concurrent pass to arrive here too, were it not locked out.
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        self.in_flight.fetch_sub(1, SeqCst);
        Ok(self.bare.clone())
    }
    async fn scenes_with_tag(&self, _tag_id: &str) -> anyhow::Result<Vec<Scene>> {
        Ok(self.tagged.clone())
    }
    async fn search(&self, endpoint: &str, _query: &str) -> anyhow::Result<Vec<Candidate>> {
        match self.results.get(endpoint) {
            None => Ok(vec![]),
            Some(Ok(v)) => Ok(v.clone()),
            Some(Err(f)) => Err(f.err()),
        }
    }
    async fn fingerprint_matches(
        &self,
        endpoint: &str,
        scene_ids: &[String],
    ) -> anyhow::Result<Vec<Vec<FingerprintMatch>>> {
        let by_id = match self.fingerprints.get(endpoint) {
            None => return Ok(vec![vec![]; scene_ids.len()]),
            Some(Err(f)) => return Err(f.err()),
            Some(Ok(m)) => m,
        };
        Ok(scene_ids
            .iter()
            .map(|id| by_id.get(id.as_str()).cloned().unwrap_or_default())
            .collect())
    }
    async fn scrape_url(&self, url: &str) -> anyhow::Result<Option<Candidate>> {
        self.scraped_urls.lock().unwrap().push(url.to_string());
        match self.fc2.get(url) {
            None => Ok(None),
            Some(Ok(v)) => Ok(v.clone()),
            Some(Err(f)) => Err(f.err()),
        }
    }
    async fn performer_by_stash_id(
        &self,
        _endpoint: &str,
        _sid: &str,
    ) -> anyhow::Result<Option<String>> {
        // The fake's records carry no stash ids; no test finds one by them.
        Ok(None)
    }
    async fn studio_by_stash_id(
        &self,
        _endpoint: &str,
        _sid: &str,
    ) -> anyhow::Result<Option<String>> {
        Ok(None)
    }
    async fn performers_like(&self, _name: &str) -> anyhow::Result<Vec<NamedRecord>> {
        Ok(self.performers.clone())
    }
    async fn studios_like(&self, _name: &str) -> anyhow::Result<Vec<NamedRecord>> {
        Ok(self.studios.clone())
    }
    async fn tag_id(&self, name: &str, create: bool) -> anyhow::Result<Option<String>> {
        let mut tags = self.tags.lock().unwrap();
        if !tags.contains_key(name) && create {
            tags.insert(name.to_string(), format!("t-{name}"));
        }
        Ok(tags.get(name).cloned())
    }
    async fn create_performer(&self, inp: &PerformerCreate) -> anyhow::Result<String> {
        self.created
            .lock()
            .unwrap()
            .push(("performer".into(), serde_json::to_value(inp).unwrap()));
        Ok(format!("p-{}", inp.name))
    }
    async fn create_studio(&self, inp: &StudioCreate) -> anyhow::Result<String> {
        self.created
            .lock()
            .unwrap()
            .push(("studio".into(), serde_json::to_value(inp).unwrap()));
        Ok(format!("s-{}", inp.name))
    }
    async fn update_scene(&self, inp: &SceneUpdate) -> anyhow::Result<()> {
        if let Some(f) = &self.update_fails {
            return Err(f.err());
        }
        self.updates
            .lock()
            .unwrap()
            .push(serde_json::to_value(inp).unwrap());
        Ok(())
    }
}

struct FakeLlm {
    parse: Result<Parse, Fail>,
    choice: Result<&'static str, Fail>,
    translation: Result<&'static str, Fail>,
    translated: Mutex<Vec<String>>,
    /// (path, title, studio) of each `parse_with_title` call.
    titled: Mutex<Vec<(String, String, Option<String>)>>,
}

fn llm(parse: Value) -> FakeLlm {
    llm_parse(if parse.is_null() {
        Parse::default()
    } else {
        parse_of(parse)
    })
}

fn llm_parse(parse: Parse) -> FakeLlm {
    FakeLlm {
        parse: Ok(parse),
        choice: Ok("none"),
        translation: Ok("English Title"),
        translated: Mutex::new(vec![]),
        titled: Mutex::new(vec![]),
    }
}

fn llm_failing(f: Fail) -> FakeLlm {
    FakeLlm {
        parse: Err(f),
        ..llm_parse(Parse::default())
    }
}

fn no_llm() -> FakeLlm {
    llm_failing(Fail::Panic("LLM must not be called for a product-code hit"))
}

impl FakeLlm {
    fn choice(mut self, c: Result<&'static str, Fail>) -> FakeLlm {
        self.choice = c;
        self
    }
    fn translation(mut self, t: Result<&'static str, Fail>) -> FakeLlm {
        self.translation = t;
        self
    }
}

impl Llm for FakeLlm {
    async fn parse(&self, _path: &str) -> anyhow::Result<Parse> {
        self.parse.clone().map_err(|f| f.err())
    }
    async fn parse_with_title(
        &self,
        path: &str,
        title: &str,
        studio: Option<&str>,
    ) -> anyhow::Result<Parse> {
        self.titled
            .lock()
            .unwrap()
            .push((path.into(), title.into(), studio.map(str::to_string)));
        self.parse.clone().map_err(|f| f.err())
    }
    async fn translate_title(&self, title: &str) -> anyhow::Result<String> {
        self.translated.lock().unwrap().push(title.to_string());
        self.translation
            .clone()
            .map(str::to_string)
            .map_err(|f| f.err())
    }
    async fn choose(&self, _req: &JevRequest) -> anyhow::Result<ChoiceAnswer> {
        let c = self.choice.clone().map_err(|f| f.err())?;
        Ok(serde_json::from_value(json!({"choice": c, "confidence": 0.4})).unwrap())
    }
}

enum CodeDbFail {
    Status(u16),
    Net,
}

struct FakeCodeDb {
    hits: Result<Vec<CodeHit>, CodeDbFail>,
    calls: Mutex<Vec<String>>,
}

fn codedb(hits: Vec<Value>) -> FakeCodeDb {
    FakeCodeDb {
        hits: Ok(hits
            .into_iter()
            .map(|h| serde_json::from_value(h).unwrap())
            .collect()),
        calls: Mutex::new(vec![]),
    }
}

fn codedb_failing(f: CodeDbFail) -> FakeCodeDb {
    FakeCodeDb {
        hits: Err(f),
        calls: Mutex::new(vec![]),
    }
}

impl FakeCodeDb {
    fn calls(&self) -> Vec<String> {
        self.calls.lock().unwrap().clone()
    }
}

impl CodeSearch for FakeCodeDb {
    async fn code_search(&self, code: &str) -> Result<Vec<CodeHit>, CodeDbError> {
        self.calls.lock().unwrap().push(code.to_string());
        match &self.hits {
            Ok(h) => Ok(h.clone()),
            Err(CodeDbFail::Status(s)) => Err(CodeDbError::Status(*s)),
            Err(CodeDbFail::Net) => Err(CodeDbError::Other(net_error())),
        }
    }
}

fn clients<'a>(
    st: &'a FakeStash,
    llm: &'a FakeLlm,
    tp: Option<&'a FakeCodeDb>,
) -> Clients<'a, FakeStash, FakeLlm, FakeCodeDb, crate::provenance::tests::FakeTorrents> {
    Clients {
        stash: st,
        llm,
        codedb: tp,
        paths: &PATHS,
        torrents: None,
    }
}

async fn identify(st: &FakeStash, llm: &FakeLlm, scene: &Scene) -> anyhow::Result<Proposal> {
    identify_scene(&clients(st, llm, None), scene, None).await
}

async fn identify_with(
    st: &FakeStash,
    llm: &FakeLlm,
    scene: &Scene,
    tp: Option<&FakeCodeDb>,
) -> anyhow::Result<Proposal> {
    identify_scene(&clients(st, llm, tp), scene, None).await
}

// --- fixtures ----------------------------------------------------------------------

fn merge(mut base: Value, extra: Value) -> Value {
    let o = base.as_object_mut().unwrap();
    for (k, v) in extra.as_object().unwrap() {
        o.insert(k.clone(), v.clone());
    }
    base
}

fn scene_at(id: &str, path: &str, duration: f64) -> Scene {
    scene(
        json!({"id": id, "title": "", "code": "", "details": "", "director": "", "date": null,
           "urls": [], "studio": null, "performers": [], "tags": [], "stash_ids": [],
           "files": [{"path": path, "duration": duration}]}),
    )
}

/// `base` with `extra`'s keys set.
fn merge_scene(base: Scene, extra: Value) -> Scene {
    scene(merge(json!(base), extra))
}

fn scene5() -> Scene {
    scene_at("5", "/media/Vault/dir/file.mp4", 600.0)
}

fn scene_id(id: &str) -> Scene {
    scene_at(id, "/media/Vault/dir/file.mp4", 600.0)
}

fn scene_path(path: &str) -> Scene {
    scene_at("5", path, 600.0)
}

fn scraped(title: &str, studio: &str, date: Value, duration: Value, rid: &str) -> Value {
    json!({"title": title, "date": date, "duration": duration, "remote_site_id": rid,
           "studio": {"name": studio, "remote_site_id": format!("st-{studio}")},
           "performers": [], "tags": [], "image": "data:img"})
}

fn code_hit(code: &str, title: Option<&str>) -> Value {
    let lower = code.to_lowercase();
    json!({"external_id": lower, "slug": format!("x-{lower}"),
           "title": title.map_or_else(|| format!("{code} - Some Title"), str::to_string),
           "date": "2026-03-03", "description": "d", "duration": 7800,
           "url": "https://codes.example/x", "background": {"full": "https://img"},
           "site": {"name": "StudioK"},
           "performers": [{"name": "Performer K", "image": null,
                           "parent": {"name": "Performer K"}}]})
}

fn fc2_hit() -> Value {
    json!({"title": "サンプル題名", "code": "FC2-PPV-1000006", "date": "2026-10-04",
           "details": null, "image": "data:img", "duration": null, "remote_site_id": null,
           "studio": {"name": "FC2"}, "performers": [{"name": "サンプル販売者"}],
           "tags": [], "urls": [FC2_URL]})
}

/// Log lines emitted on this thread while the guard lives.
#[derive(Clone, Default)]
struct Logs(Arc<Mutex<Vec<u8>>>);

impl Write for Logs {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for Logs {
    type Writer = Logs;
    fn make_writer(&'a self) -> Logs {
        self.clone()
    }
}

impl Logs {
    fn capture() -> (Logs, tracing::subscriber::DefaultGuard) {
        let logs = Logs::default();
        let sub = tracing_subscriber::fmt()
            .with_writer(logs.clone())
            .with_ansi(false)
            .without_time()
            .with_target(false)
            .with_level(false)
            .finish();
        (logs, tracing::subscriber::set_default(sub))
    }

    fn lines(&self) -> Vec<String> {
        String::from_utf8(self.0.lock().unwrap().clone())
            .unwrap()
            .lines()
            .map(str::to_string)
            .collect()
    }
}

fn sid(endpoint: &str, id: &str) -> StashId {
    StashId {
        endpoint: endpoint.into(),
        stash_id: id.into(),
    }
}

// --- RelPathTest -------------------------------------------------------------------

#[test]
fn strips_library_root() {
    assert_eq!(PATHS.rel_path("/media/Vault/a/b.mp4"), "a/b.mp4");
}

// --- IdentifyTest ------------------------------------------------------------------

fn scrape(p: &Proposal) -> &ScrapeMatch {
    let Proposal::Scrape(m) = p else {
        panic!("expected a scrape, got {p:?}")
    };
    m
}

#[tokio::test]
async fn date_rule_beats_jev() {
    let st = FakeStash::with_results(vec![
        (
            CODEDB,
            Ok(vec![scraped(
                "Cow",
                "Studio Name",
                json!("2024-12-24"),
                json!(600),
                "t1",
            )]),
        ),
        (
            STASHDB,
            Ok(vec![scraped(
                "cow",
                "StudioName",
                json!("2024-12-24"),
                json!(601),
                "s1",
            )]),
        ),
    ]);
    let l = llm(json!({"studio": "StudioName", "date": "2024-12-24", "query": "q"}));
    let p = identify(&st, &l, &scene5()).await.unwrap();
    let m = scrape(&p);
    assert_eq!((m.rule, m.endpoint.as_deref()), (Rule::Date, Some(CODEDB)));
    assert_eq!(m.stash_ids, vec![sid(CODEDB, "t1"), sid(STASHDB, "s1")]);
}

fn snowed_in() -> FakeStash {
    FakeStash::with_results(vec![
        (
            CODEDB,
            Ok(vec![scraped(
                "Snowed In",
                "Other Studio",
                Value::Null,
                json!(600),
                "t1",
            )]),
        ),
        (
            STASHDB,
            Ok(vec![scraped(
                "SNOWED IN",
                "Other Studio",
                Value::Null,
                json!(600),
                "s1",
            )]),
        ),
    ])
}

#[tokio::test]
async fn jev_pick_and_codedb_twin_becomes_primary() {
    let st = snowed_in();
    // After dedupe only the CODEDB copy is offered to Jev, as c0.
    let l = llm(json!({"query": "q"})).choice(Ok("c0"));
    let p = identify(&st, &l, &scene5()).await.unwrap();
    let m = scrape(&p);
    assert_eq!((m.rule, m.endpoint.as_deref()), (Rule::Jev, Some(CODEDB)));
    assert_eq!(m.stash_ids.len(), 2);
}

#[tokio::test]
async fn duration_filter_blocks_lookalikes() {
    let st = FakeStash::with_results(vec![(
        STASHDB,
        Ok(vec![scraped(
            "Similar",
            "Other",
            Value::Null,
            json!(900),
            "r",
        )]),
    )]);
    let l = llm(json!({"title": "T", "query": "q"})).choice(Ok("c0"));
    let p = identify(&st, &l, &scene5()).await.unwrap();
    assert!(matches!(p, Proposal::Llm(_)), "{p:?}");
}

#[tokio::test]
async fn empty_parse_is_none() {
    let p = identify(&FakeStash::default(), &llm(json!({"query": ""})), &scene5())
        .await
        .unwrap();
    assert_eq!(p, Proposal::Nothing);
}

#[tokio::test]
async fn series_and_date_without_studio_or_title_is_llm() {
    // No title, studio or performers, but display_title can still build a fallback
    // name from series + date -- that must count as a proposal, not "none".
    let parse = json!({"series": "Series Name 2004", "date": "2025-01-01", "query": ""});
    let p = identify(&FakeStash::default(), &llm(parse), &scene5())
        .await
        .unwrap();
    assert!(matches!(p, Proposal::Llm(_)), "{p:?}");
}

#[tokio::test]
async fn parse_failure_propagates() {
    let e = identify(
        &FakeStash::default(),
        &llm_failing(Fail::Msg("bad")),
        &scene5(),
    )
    .await
    .unwrap_err();
    assert_eq!(e.to_string(), "bad");
    assert!(!is_transient(&e));
}

#[tokio::test]
async fn search_failure_raises_instead_of_downgrading() {
    let st = FakeStash::with_results(vec![(CODEDB, Err(Fail::Msg("timeout")))]);
    let e = identify(&st, &llm(json!({"title": "T", "query": "q"})), &scene5())
        .await
        .unwrap_err();
    assert!(e.to_string().contains("timeout"));
}

#[tokio::test]
async fn jev_failure_raises_instead_of_downgrading() {
    let st = snowed_in();
    let l = llm(json!({"title": "T", "query": "q"})).choice(Err(Fail::Msg("jev down")));
    let e = identify(&st, &l, &scene5()).await.unwrap_err();
    assert!(e.to_string().contains("jev down"));
}

#[tokio::test]
async fn duration_filter_runs_before_dedupe() {
    // The CODEDB copy sorts first into dedupe but has no usable duration; without
    // filtering first it would win dedupe and the whole match would be lost.
    let st = FakeStash::with_results(vec![
        (
            CODEDB,
            Ok(vec![scraped("Cow", "Trip", Value::Null, Value::Null, "t1")]),
        ),
        (
            STASHDB,
            Ok(vec![scraped("Cow", "Trip", Value::Null, json!(600), "s1")]),
        ),
    ]);
    let l = llm(json!({"query": "q"})).choice(Ok("c0"));
    let p = identify(&st, &l, &scene5()).await.unwrap();
    assert_eq!(scrape(&p).endpoint.as_deref(), Some(STASHDB));
}

// --- CodeIdentifyTest --------------------------------------------------------------

const CODE_PATH: &str = "/media/Vault/ABCD-910.mp4";

#[tokio::test]
async fn stashdb_exact_code_wins_without_llm() {
    let st = FakeStash::with_results(vec![(
        STASHDB,
        Ok(vec![
            merge(
                scraped("EFGH-795", "Studio I", Value::Null, json!(9499), "s1"),
                json!({"code": "EFGH-795"}),
            ),
            merge(
                scraped("TUVWX-795", "Studio D", Value::Null, json!(600), "s2"),
                json!({"code": "TUVWX-795"}),
            ),
        ]),
    )]);
    let tp = codedb(vec![]);
    let p = identify_with(
        &st,
        &no_llm(),
        &scene_at("5", "/media/Vault/EFGH-795.mp4", 9500.0),
        Some(&tp),
    )
    .await
    .unwrap();
    let m = scrape(&p);
    assert_eq!((m.rule, m.source), (Rule::Code, "stashdb"));
    assert_eq!(m.endpoint.as_deref(), Some(STASHDB));
    assert_eq!(m.stash_ids, vec![sid(STASHDB, "s1")]);
    assert_eq!(m.delta, Some(-1));
    assert_eq!(tp.calls(), Vec::<String>::new()); // StashDB hit: CODEDB never asked
}

#[tokio::test]
async fn codedb_hit_ignores_duration() {
    // StashDB only has same-number neighbours; CODEDB's nominal 7800 s is 281 s off.
    let st = FakeStash::with_results(vec![(
        STASHDB,
        Ok(vec![merge(
            scraped("YZAB-910", "Studio O", Value::Null, json!(600), "r"),
            json!({"code": "YZAB-910"}),
        )]),
    )]);
    let tp = codedb(vec![code_hit("ABCD-910", None)]);
    let p = identify_with(&st, &no_llm(), &scene_at("5", CODE_PATH, 7519.0), Some(&tp))
        .await
        .unwrap();
    let m = scrape(&p);
    assert_eq!((m.rule, m.source), (Rule::Code, "codedb"));
    assert_eq!(m.endpoint.as_deref(), Some(CODE_URL));
    assert_eq!(m.candidate.code.as_deref(), Some("ABCD-910"));
    assert_eq!((&m.stash_ids, m.delta), (&vec![], Some(281)));
}

#[tokio::test]
async fn both_miss_falls_back_to_llm() {
    let tp = codedb(vec![code_hit("ABCD-190", None)]);
    let p = identify_with(
        &FakeStash::default(),
        &llm(json!({"title": "T", "query": ""})),
        &scene_path(CODE_PATH),
        Some(&tp),
    )
    .await
    .unwrap();
    assert!(matches!(p, Proposal::Llm(_)), "{p:?}");
}

#[tokio::test]
async fn no_codedb_client_uses_stashdb_only() {
    let p = identify_with(
        &FakeStash::default(),
        &llm(json!({"title": "T", "query": ""})),
        &scene_path(CODE_PATH),
        None,
    )
    .await
    .unwrap();
    assert!(matches!(p, Proposal::Llm(_)), "{p:?}");
}

#[tokio::test]
async fn ambiguous_exact_hits_fall_back() {
    let tp = codedb(vec![
        code_hit("ABCD-910", Some("One")),
        code_hit("ABCD-910", Some("Two")),
    ]);
    let p = identify_with(
        &FakeStash::default(),
        &llm(json!({"title": "T", "query": ""})),
        &scene_path(CODE_PATH),
        Some(&tp),
    )
    .await
    .unwrap();
    assert!(matches!(p, Proposal::Llm(_)), "{p:?}");
}

#[tokio::test]
async fn codedb_failure_is_transient() {
    let tp = codedb_failing(CodeDbFail::Net);
    let e = identify_with(
        &FakeStash::default(),
        &no_llm(),
        &scene_path(CODE_PATH),
        Some(&tp),
    )
    .await
    .unwrap_err();
    assert!(e.is::<Transient>());
}

#[tokio::test]
async fn stashdb_failure_is_transient() {
    let st = FakeStash::with_results(vec![(STASHDB, Err(Fail::Msg("down")))]);
    let tp = codedb(vec![]);
    let e = identify_with(&st, &no_llm(), &scene_path(CODE_PATH), Some(&tp))
        .await
        .unwrap_err();
    assert!(e.is::<Transient>());
}

#[tokio::test]
async fn codedb_auth_failure_is_a_miss_not_transient() {
    let (logs, _guard) = Logs::capture();
    let tp = codedb_failing(CodeDbFail::Status(401));
    let p = identify_with(
        &FakeStash::default(),
        &llm(json!({"title": "T", "query": ""})),
        &scene_path(CODE_PATH),
        Some(&tp),
    )
    .await
    .unwrap();
    assert!(matches!(p, Proposal::Llm(_)), "{p:?}");
    let lines = logs.lines();
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert!(lines[0].contains("the code database"));
    assert!(
        lines[0].contains("scene 5: the code database refused the key (401); treating as a miss"),
        "{lines:?}"
    );
}

#[tokio::test]
async fn codedb_server_error_is_still_transient() {
    let tp = codedb_failing(CodeDbFail::Status(500));
    let e = identify_with(
        &FakeStash::default(),
        &no_llm(),
        &scene_path(CODE_PATH),
        Some(&tp),
    )
    .await
    .unwrap_err();
    assert!(e.is::<Transient>());
}

#[tokio::test]
async fn codedb_apply_resolves_by_name() {
    let st = FakeStash::default();
    let tp = codedb(vec![code_hit("ABCD-910", None)]);
    let l = no_llm();
    let c = clients(&st, &l, Some(&tp));
    let p = identify_scene(&c, &scene_at("5", CODE_PATH, 7519.0), None)
        .await
        .unwrap();
    apply(&c, &scene_path(CODE_PATH), &p, &HashSet::new(), false, None)
        .await
        .unwrap();
    assert_eq!(
        st.created(),
        vec![
            ("studio".to_string(), json!({"name": "StudioK"})),
            ("performer".to_string(), json!({"name": "Performer K"})),
        ]
    );
    let up = &st.updates()[0];
    assert_eq!(
        (&up["title"], &up["code"]),
        (&json!("ABCD-910 - Some Title"), &json!("ABCD-910"))
    );
    assert_eq!(
        (&up["studio_id"], &up["performer_ids"]),
        (&json!("s-StudioK"), &json!(["p-Performer K"]))
    );
    assert_eq!(up["stash_ids"], json!([]));
}

// --- Fc2IdentifyTest ---------------------------------------------------------------

const FC2_PATH: &str = "/media/Vault/FC2-PPV-1000006.mp4";

fn fc2_stash(result: Result<Option<Value>, Fail>) -> FakeStash {
    let result = result.map(|hit| hit.map(cand));
    let mut st = FakeStash {
        studios: vec![named(
            json!({"id": "632", "name": "FC2-PPV", "aliases": []}),
        )],
        ..Default::default()
    };
    st.fc2.insert(FC2_URL.to_string(), result);
    st
}

fn parse_only() -> FakeLlm {
    llm(json!({"title": "T", "query": ""})).translation(Err(Fail::Panic("no hit")))
}

#[tokio::test]
async fn hit_is_translated_and_skips_stash_box_and_codedb() {
    let st = fc2_stash(Ok(Some(fc2_hit())));
    let tp = codedb(vec![]);
    let l = llm_failing(Fail::Panic("no parse")).translation(Ok("Sample Title"));
    let p = identify_with(&st, &l, &scene_path(FC2_PATH), Some(&tp))
        .await
        .unwrap();
    let m = scrape(&p);
    assert_eq!((m.rule, m.source), (Rule::Code, "fc2"));
    let primary = &m.candidate;
    assert_eq!(
        (primary.title.as_deref(), primary.details.as_deref()),
        (Some("Sample Title"), Some("サンプル題名"))
    );
    assert_eq!((&m.stash_ids, m.delta), (&vec![], None));
    assert_eq!(*l.translated.lock().unwrap(), vec!["サンプル題名"]);
    assert_eq!(
        (st.scraped_urls.lock().unwrap().clone(), tp.calls()),
        (vec![FC2_URL.to_string()], vec![])
    );
}

#[tokio::test]
async fn removed_listing_falls_back_to_llm() {
    // Stash's fc2 scraper nil-derefs on FC2's "product not found" page.
    let st = fc2_stash(Err(Fail::Gql("[{'message': 'nil pointer dereference'}]")));
    let p = identify(&st, &parse_only(), &scene_path(FC2_PATH))
        .await
        .unwrap();
    assert!(matches!(p, Proposal::Llm(_)), "{p:?}");
}

#[tokio::test]
async fn empty_scrape_falls_back_to_llm() {
    let p = identify(&fc2_stash(Ok(None)), &parse_only(), &scene_path(FC2_PATH))
        .await
        .unwrap();
    assert!(matches!(p, Proposal::Llm(_)), "{p:?}");
}

#[tokio::test]
async fn stash_unreachable_is_transient() {
    let e = identify(&fc2_stash(Err(Fail::Net)), &no_llm(), &scene_path(FC2_PATH))
        .await
        .unwrap_err();
    assert!(e.is::<Transient>());
}

#[tokio::test]
async fn translation_failure_is_transient() {
    let l = llm_failing(Fail::Panic("no parse")).translation(Err(Fail::Msg("malformed")));
    let e = identify(&fc2_stash(Ok(Some(fc2_hit()))), &l, &scene_path(FC2_PATH))
        .await
        .unwrap_err();
    assert!(e.is::<Transient>());
}

#[tokio::test]
async fn apply_puts_seller_under_existing_fc2_ppv() {
    let st = fc2_stash(Ok(Some(fc2_hit())));
    let l = llm(Value::Null).translation(Ok("Sample Title"));
    let c = clients(&st, &l, None);
    let p = identify_scene(&c, &scene_path(FC2_PATH), None)
        .await
        .unwrap();
    apply(&c, &scene_path(FC2_PATH), &p, &HashSet::new(), false, None)
        .await
        .unwrap();
    assert_eq!(
        st.created(),
        vec![(
            "studio".to_string(),
            json!({"name": "サンプル販売者", "parent_id": "632"})
        )]
    );
    let up = &st.updates()[0];
    assert_eq!(
        (
            &up["title"],
            &up["code"],
            &up["studio_id"],
            &up["performer_ids"]
        ),
        (
            &json!("Sample Title"),
            &json!("FC2-PPV-1000006"),
            &json!("s-サンプル販売者"),
            &json!([])
        )
    );
    assert_eq!(up["urls"], json!([FC2_URL]));
}

// --- ApplyTest ---------------------------------------------------------------------

/// A scrape of `candidate` from CODEDB with no stash ids.
fn scrape_of(candidate: Candidate) -> ScrapeMatch {
    ScrapeMatch {
        endpoint: Some(CODEDB.into()),
        ..ScrapeMatch::code("", candidate, None)
    }
}

#[tokio::test]
async fn scrape_resolves_by_stash_id_then_creates() {
    let known = json!({"id": "1019", "name": "Jane Example", "alias_list": ["Vivian"]});
    let st = FakeStash {
        performers: vec![named(known)],
        studios: vec![named(
            json!({"id": "161", "name": "Studio L", "aliases": []}),
        )],
        ..Default::default()
    };
    let primary = merge(
        scraped("Some Title", "Studio L", Value::Null, json!(600), "r"),
        json!({"performers": [{"name": "Vivian", "remote_site_id": "v1", "images": ["https://i"]}],
               "tags": [{"name": "Tag A", "stored_id": "20"},
                        {"name": "Unknown", "stored_id": null}]}),
    );
    let p = Proposal::Scrape(ScrapeMatch {
        stash_ids: vec![sid(CODEDB, "r")],
        ..scrape_of(cand(primary))
    });
    let l = no_llm();
    let skip: HashSet<String> = ["1398".to_string()].into();
    apply(
        &clients(&st, &l, None),
        &merge_scene(scene5(), json!({"tags": [{"id": "1398"}]})),
        &p,
        &skip,
        false,
        None,
    )
    .await
    .unwrap();
    // "Vivian" must NOT resolve to Jane Example through her alias.
    assert_eq!(
        st.created(),
        vec![(
            "performer".to_string(),
            json!({"name": "Vivian", "image": "https://i",
                   "stash_ids": [{"endpoint": CODEDB, "stash_id": "v1"}]})
        )]
    );
    let up = &st.updates()[0];
    assert_eq!(up["studio_id"], "161");
    assert_eq!(up["performer_ids"], json!(["p-Vivian"]));
    assert_eq!(up["tag_ids"], json!(["20"]));
    assert_eq!(up["cover_image"], "data:img");
}

#[tokio::test]
async fn llm_guess_creates_by_name_and_tags() {
    let st = FakeStash::default();
    let p = Proposal::Llm(parse_of(json!({"title": "Guess", "studio": "studiosample",
                           "performers": ["Performer S"]})));
    let l = no_llm();
    apply(
        &clients(&st, &l, None),
        &scene5(),
        &p,
        &HashSet::new(),
        false,
        None,
    )
    .await
    .unwrap();
    assert_eq!(
        st.created(),
        vec![
            ("studio".to_string(), json!({"name": "studiosample"})),
            ("performer".to_string(), json!({"name": "Performer S"})),
        ]
    );
    assert_eq!(
        st.updates()[0],
        json!({"id": "5", "title": "Guess", "studio_id": "s-studiosample",
               "performer_ids": ["p-Performer S"], "tag_ids": ["t-llm-identified"]})
    );
}

#[tokio::test]
async fn a_non_latin_title_is_written_in_english() {
    let st = FakeStash::default();
    let p = Proposal::Llm(parse_of(json!({"title": "Утро в городе"})));
    let l = llm(Value::Null);
    apply(
        &clients(&st, &l, None),
        &scene5(),
        &p,
        &HashSet::new(),
        false,
        None,
    )
    .await
    .unwrap();
    assert_eq!(*l.translated.lock().unwrap(), vec!["Утро в городе"]);
    assert_eq!(st.updates()[0]["title"], "English Title");
}

#[tokio::test]
async fn a_failed_translation_is_transient_and_writes_nothing() {
    let st = FakeStash::default();
    let p = Proposal::Scrape(scrape_of(cand(scraped(
        "金欠",
        "S1",
        Value::Null,
        json!(600),
        "r",
    ))));
    let l = llm(Value::Null).translation(Err(Fail::Net));
    let e = apply(
        &clients(&st, &l, None),
        &scene5(),
        &p,
        &HashSet::new(),
        false,
        None,
    )
    .await
    .unwrap_err();
    assert!(is_transient(&e), "{e:#}");
    assert!(st.updates().is_empty());
}

#[test]
fn only_non_latin_scripts_count_as_foreign() {
    for t in ["Some Title", "Café Crème", "Łódź", "2025-10-11 #3"] {
        assert!(!is_non_latin(t), "{t}");
    }
    for t in ["Привет-2", "金欠", "テスト", "Ελένη", "Mix Привет"] {
        assert!(is_non_latin(t), "{t}");
    }
}

#[tokio::test]
async fn none_writes_nothing() {
    let st = FakeStash::default();
    let l = no_llm();
    apply(
        &clients(&st, &l, None),
        &scene5(),
        &Proposal::Nothing,
        &HashSet::new(),
        false,
        None,
    )
    .await
    .unwrap();
    assert_eq!((st.updates(), st.created()), (vec![], vec![]));
}

// --- FormatLineTest ----------------------------------------------------------------

#[test]
fn outcome_strings_are_the_stored_ones() {
    let all = [
        Outcome::Scrape,
        Outcome::Llm,
        Outcome::Nothing,
        Outcome::Stash,
        Outcome::GaveUp,
    ];
    assert_eq!(
        all.map(Outcome::as_str),
        ["scrape", "llm", "none", "stash", "gave-up"]
    );
}

#[test]
fn format_line_scrape() {
    let s = scene(
        json!({"id": "5", "files": [{"path": "/media/Vault/Studio/a.mp4", "duration": 300}]}),
    );
    let prop = Proposal::Scrape(ScrapeMatch {
        rule: Rule::Jev,
        source: "",
        candidate: cand(
            json!({"title": "It's On", "studio": {"name": "S"}, "performers": [{"name": "A"}, {"name": "B"}]}),
        ),
        endpoint: Some(CODEDB.into()),
        stash_ids: vec![StashId {
            endpoint: CODEDB.into(),
            stash_id: "x".into(),
        }],
        confidence: Some(0.91),
        delta: Some(-2),
    });
    assert_eq!(
        format_line(&PATHS, &s, &prop),
        "[5] Studio/a.mp4\n    codes (jev conf=0.91) | \"It's On\" | S | A, B | Δ-2s"
    );
}

#[test]
fn format_line_llm_and_nothing() {
    let s = scene(json!({"id": "5", "files": [{"path": "/media/Vault/a.mp4", "duration": 300}]}));
    let parse: Parse = serde_json::from_value(json!({"title": "T", "performers": []})).unwrap();
    assert_eq!(
        format_line(&PATHS, &s, &Proposal::Llm(parse)),
        "[5] a.mp4\n    llm-only | \"T\" | - | -"
    );
    assert_eq!(
        format_line(&PATHS, &s, &Proposal::Nothing),
        "[5] a.mp4\n    nothing found"
    );
}

#[test]
fn llm_only_shows_display_title_fallback() {
    let p = Proposal::Llm(parse_of(
        json!({"title": null, "studio": "StudioSample", "date": "2025-10-11"}),
    ));
    let line = format_line(&PATHS, &scene5(), &p);
    assert!(line.contains("StudioSample – 2025-10-11"), "{line}");
}

#[test]
fn llm_only_shows_real_title_unchanged() {
    let p = Proposal::Llm(parse_of(json!({"title": "Guess", "studio": "S"})));
    let line = format_line(&PATHS, &scene5(), &p);
    assert!(line.contains("\"Guess\""), "{line}");
    assert_eq!(line, "[5] dir/file.mp4\n    llm-only | \"Guess\" | S | -");
}

#[tokio::test]
async fn codedb_line_shows_source_and_delta() {
    let tp = codedb(vec![code_hit("ABCD-910", None)]);
    let p = identify_with(
        &FakeStash::default(),
        &no_llm(),
        &scene_at("5", CODE_PATH, 7519.0),
        Some(&tp),
    )
    .await
    .unwrap();
    let line = format_line(&PATHS, &scene_path(CODE_PATH), &p);
    assert!(line.contains("codedb (code)"), "{line}");
    assert!(line.contains("Δ+281s"), "{line}");
    assert_eq!(
        line,
        "[5] ABCD-910.mp4\n    codedb (code) | \"ABCD-910 - Some Title\" | StudioK | \
         Performer K | Δ+281s"
    );
}

#[tokio::test]
async fn unknown_delta_does_not_crash() {
    let st = FakeStash::with_results(vec![(
        STASHDB,
        Ok(vec![merge(
            scraped("EFGH-795", "Studio I", Value::Null, Value::Null, "r"),
            json!({"code": "EFGH-795"}),
        )]),
    )]);
    let p = identify_with(
        &st,
        &no_llm(),
        &scene_path("/media/Vault/EFGH-795.mp4"),
        None,
    )
    .await
    .unwrap();
    assert!(format_line(&PATHS, &scene5(), &p).contains("Δ?"));
}

#[test]
fn stash_ids_name_the_source_and_confidence_shows() {
    // Pins the `src` and `conf=` formatting.
    let p = Proposal::Scrape(ScrapeMatch {
        rule: Rule::Jev,
        endpoint: None,
        stash_ids: vec![sid(STASHDB, "s"), sid(CODEDB, "t")],
        confidence: Some(0.4),
        delta: Some(0),
        ..scrape_of(cand(
            json!({"title": "It's", "performers": [{"name": "A"}, {"name": "B"}]}),
        ))
    });
    assert_eq!(
        format_line(&PATHS, &scene5(), &p),
        "[5] dir/file.mp4\n    codes+stashdb (jev conf=0.40) | \"It's\" | - | A, B | Δ+0s"
    );
    assert_eq!(
        format_line(&PATHS, &scene5(), &Proposal::Nothing),
        "[5] dir/file.mp4\n    nothing found"
    );
}

// --- PathTest ----------------------------------------------------------------------

#[test]
fn host_to_container() {
    assert_eq!(
        PATHS.to_container("/mnt/storage/media/Vault/a b/c"),
        "/media/Vault/a b/c"
    );
}

// --- StateTest ---------------------------------------------------------------------

#[test]
fn persists_ids() {
    let d = tempfile::tempdir().unwrap();
    let path = d.path().join("sub").join("plab.db");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = Db::open(&path).unwrap();
    assert!(!db.identify_done("5").unwrap());
    db.identify_mark_done("5").unwrap();
    drop(db);
    assert!(Db::open(&path).unwrap().identify_done("5").unwrap());
}

// --- SkipTagsTest ------------------------------------------------------------------

#[test]
fn collects_identify_skip_tags() {
    let d: Defaults = serde_json::from_value(json!({"identify": {"options": {
        "skipMultipleMatchTag": "1398", "skipSingleNamePerformerTag": "1398"}}}))
    .unwrap();
    assert_eq!(d.skip_tags(), HashSet::from(["1398".to_string()]));
    let none: Defaults = serde_json::from_value(json!({"identify": {}})).unwrap();
    assert_eq!(none.skip_tags(), HashSet::new());
}

// --- IsUpgradeTest -----------------------------------------------------------------

#[test]
fn tagged_scene_with_no_files_is_not_an_upgrade() {
    let s = merge_scene(
        scene5(),
        json!({"tags": [{"id": "t-llm-identified"}], "files": []}),
    );
    assert!(!is_upgrade(&PATHS, &s, Some("t-llm-identified")));
}

// --- PassTest ----------------------------------------------------------------------

fn defaults() -> Defaults {
    serde_json::from_value(json!({"scan": {}, "generate": {}, "identify": {}})).unwrap()
}

fn opts() -> PassOpts {
    PassOpts {
        jobs: true,
        dry_run: false,
        limit: None,
        scene_ids: None,
    }
}

fn manual() -> PassOpts {
    PassOpts {
        jobs: false,
        ..opts()
    }
}

async fn pass(
    st: &FakeStash,
    l: &FakeLlm,
    tp: Option<&FakeCodeDb>,
    db: &Db,
    paths: Option<Vec<String>>,
    o: PassOpts,
) {
    run_pass(&clients(st, l, tp), db, &defaults(), paths, &o)
        .await
        .unwrap();
}

fn guessed(id: &str, path: &str, tags: &[&str]) -> Scene {
    merge_scene(
        scene_at(id, path, 7519.0),
        json!({"title": "StudioK* – ABCD-910", "studio": {"id": "s9"},
               "performers": [{"id": "p9"}],
               "tags": tags.iter().map(|t| json!({"id": t})).collect::<Vec<_>>()}),
    )
}

fn guessed_default() -> Scene {
    guessed("20", CODE_PATH, &["t-llm-identified"])
}

fn upgrade_stash(stale: Scene, fresh: Option<Scene>) -> FakeStash {
    let id = stale.id.clone();
    let st = FakeStash {
        scenes_dict: HashMap::from([(id, fresh.unwrap_or_else(|| stale.clone()))]),
        tagged: vec![stale],
        ..Default::default()
    };
    st.tags
        .lock()
        .unwrap()
        .insert("llm-identified".into(), "t-llm-identified".into());
    st
}

fn titled() -> FakeLlm {
    llm(json!({"title": "T", "query": ""}))
}

#[tokio::test]
async fn steps_in_order_and_state_recorded() {
    let st = FakeStash::pass(vec![scene_id("11"), scene_id("12")]);
    let db = Db::open_in_memory().unwrap();
    db.identify_mark_done("12").unwrap();
    pass(
        &st,
        &titled(),
        None,
        &db,
        Some(vec!["/mnt/storage/media/Vault/new".into()]),
        opts(),
    )
    .await;
    assert_eq!(
        st.jobs(),
        vec![
            ("scan", Some(vec!["/media/Vault/new".to_string()])),
            ("generate", Some(vec!["11".to_string()])),
            ("identify", Some(vec!["11".to_string()])),
        ]
    );
    assert_eq!(st.update_ids(), vec!["11"]); // 12 was already attempted
    assert!(db.identify_done("11").unwrap());
}

// --- fingerprint durations -------------------------------------------------------

/// Scene 11, a 1249s file, behind Stash's saved identify sources: StashDB, then CODEDB.
fn fingerprinted(fingerprints: Vec<(&'static str, Fingerprints)>) -> FakeStash {
    FakeStash {
        bare: vec![scene_at("11", "/media/Vault/dir/file.mp4", 1249.0)],
        fingerprints: fingerprints.into_iter().collect(),
        ..Default::default()
    }
}

fn fp(duration: f64) -> Fingerprints {
    Ok(HashMap::from([(
        "11",
        vec![serde_json::from_value(json!({"title": "Some Title", "duration": duration})).unwrap()],
    )]))
}

/// The scenes stash_jobs handed Stash's identify, if it ran it.
async fn identified(st: &FakeStash) -> Option<Vec<String>> {
    let d: Defaults = serde_json::from_value(json!({"scan": {}, "generate": {}, "identify": {
        "sources": [{"source": {"stash_box_endpoint": STASHDB}},
                    {"source": {"stash_box_endpoint": CODEDB}}]}}))
    .unwrap();
    assert_eq!(stash_jobs(st, &PATHS, &d, None).await.unwrap(), vec!["11"]);
    st.jobs()
        .into_iter()
        .find(|(job, _)| *job == "identify")
        .and_then(|(_, ids)| ids)
}

#[tokio::test]
async fn a_fingerprint_match_of_another_length_is_left_to_the_llm() {
    let st = fingerprinted(vec![(CODEDB, fp(943.0))]);
    assert_eq!(identified(&st).await, None);
}

#[tokio::test]
async fn a_fingerprint_match_within_tolerance_is_identified() {
    let st = fingerprinted(vec![(CODEDB, fp(1258.0))]);
    assert_eq!(identified(&st).await, Some(vec!["11".to_string()]));
}

#[tokio::test]
async fn the_first_endpoint_with_a_match_decides_as_in_stash() {
    let st = fingerprinted(vec![(STASHDB, fp(1249.0)), (CODEDB, fp(943.0))]);
    assert_eq!(identified(&st).await, Some(vec!["11".to_string()]));
}

#[tokio::test]
async fn a_match_of_unknown_duration_is_identified() {
    let unknown = Ok(HashMap::from([(
        "11",
        vec![serde_json::from_value(json!({"title": "T", "duration": null})).unwrap()],
    )]));
    let st = fingerprinted(vec![(CODEDB, unknown)]);
    assert_eq!(identified(&st).await, Some(vec!["11".to_string()]));
}

#[tokio::test]
async fn a_failed_fingerprint_check_identifies_everything() {
    let st = fingerprinted(vec![(STASHDB, Err(Fail::Net))]);
    assert_eq!(identified(&st).await, Some(vec!["11".to_string()]));
}

#[tokio::test]
async fn dry_run_skips_jobs_writes_and_state() {
    let st = FakeStash::pass(vec![scene_id("11")]);
    let db = Db::open_in_memory().unwrap();
    pass(
        &st,
        &titled(),
        None,
        &db,
        None,
        PassOpts {
            dry_run: true,
            ..opts()
        },
    )
    .await;
    assert_eq!((st.jobs(), st.updates()), (vec![], vec![]));
    assert!(!db.identify_done("11").unwrap());
}

#[tokio::test]
async fn manual_run_skips_jobs_but_applies() {
    let st = FakeStash::pass(vec![scene_id("11")]);
    let db = Db::open_in_memory().unwrap();
    pass(&st, &titled(), None, &db, None, manual()).await;
    assert_eq!(st.jobs(), vec![]);
    assert_eq!(st.update_ids(), vec!["11"]);
}

#[tokio::test]
async fn parse_failure_is_not_recorded() {
    let st = FakeStash::pass(vec![scene_id("11")]);
    let db = Db::open_in_memory().unwrap();
    pass(&st, &llm_failing(Fail::Msg("bad")), None, &db, None, opts()).await;
    assert!(!db.identify_done("11").unwrap());
}

#[tokio::test]
async fn job_failure_still_reaches_llm_step() {
    let st = FakeStash {
        scan_fails: true,
        ..FakeStash::pass(vec![scene_id("11")])
    };
    let db = Db::open_in_memory().unwrap();
    pass(&st, &titled(), None, &db, None, opts()).await;
    assert_eq!(st.update_ids(), vec!["11"]);
}

#[tokio::test]
async fn failure_cap_gives_up_after_three_failures() {
    let st = FakeStash::pass(vec![scene_id("11")]);
    let db = Db::open_in_memory().unwrap();
    let bad = llm_failing(Fail::Msg("bad"));
    for _ in 0..IDENTIFY_FAILURE_LIMIT - 1 {
        pass(&st, &bad, None, &db, None, manual()).await;
        assert!(!db.identify_done("11").unwrap());
    }
    pass(&st, &bad, None, &db, None, manual()).await;
    assert!(db.identify_done("11").unwrap());
}

#[tokio::test]
async fn failure_cap_not_counted_in_dry_run() {
    let st = FakeStash::pass(vec![scene_id("11")]);
    let db = Db::open_in_memory().unwrap();
    let bad = llm_failing(Fail::Msg("bad"));
    for _ in 0..IDENTIFY_FAILURE_LIMIT + 2 {
        let o = PassOpts {
            dry_run: true,
            ..manual()
        };
        pass(&st, &bad, None, &db, None, o).await;
    }
    assert_eq!(db.identify_failures("11").unwrap(), 0);
    assert!(!db.identify_done("11").unwrap());
}

#[tokio::test]
async fn success_clears_failure_count() {
    let st = FakeStash::pass(vec![scene_id("11")]);
    let db = Db::open_in_memory().unwrap();
    let bad = llm_failing(Fail::Msg("bad"));
    pass(&st, &bad, None, &db, None, manual()).await;
    pass(&st, &bad, None, &db, None, manual()).await;
    assert_eq!(db.identify_failures("11").unwrap(), 2);
    pass(&st, &titled(), None, &db, None, manual()).await;
    assert_eq!(db.identify_failures("11").unwrap(), 0);
    assert!(db.identify_done("11").unwrap());
}

#[tokio::test]
async fn transient_search_failure_never_counted() {
    // A stash-box outage: search raises on every pass. The scene must never be
    // recorded and the failure count must never move, however many passes run.
    let st = FakeStash {
        results: HashMap::from([(CODEDB.to_string(), Err(Fail::Msg("stash-box down")))]),
        ..FakeStash::pass(vec![scene_id("11")])
    };
    let db = Db::open_in_memory().unwrap();
    let l = llm(json!({"title": "T", "query": "q"}));
    for _ in 0..IDENTIFY_FAILURE_LIMIT + 2 {
        pass(&st, &l, None, &db, None, manual()).await;
    }
    assert!(!db.identify_done("11").unwrap());
    assert_eq!(db.identify_failures("11").unwrap(), 0);
}

#[tokio::test]
async fn transient_network_error_never_counted() {
    // An OpenRouter outage surfacing as a raw transport error, not a Transient:
    // still must not count, however many passes run.
    let st = FakeStash::pass(vec![scene_id("11")]);
    let l = llm_failing(Fail::Net);
    let db = Db::open_in_memory().unwrap();
    for _ in 0..IDENTIFY_FAILURE_LIMIT + 2 {
        pass(&st, &l, None, &db, None, manual()).await;
    }
    assert!(!db.identify_done("11").unwrap());
    assert_eq!(db.identify_failures("11").unwrap(), 0);
}

#[tokio::test]
async fn scene_specific_failure_gives_up_with_error_in_log() {
    // A Stash-side mutation error (not transient) must still count, and the give-up
    // line must carry the error that caused the final failure.
    let st = FakeStash {
        update_fails: Some(Fail::Gql("sceneUpdate: bad studio_id")),
        ..FakeStash::pass(vec![scene_id("11")])
    };
    let (logs, _guard) = Logs::capture();
    let db = Db::open_in_memory().unwrap();
    for _ in 0..IDENTIFY_FAILURE_LIMIT {
        pass(&st, &titled(), None, &db, None, manual()).await;
    }
    assert!(db.identify_done("11").unwrap());
    let giveup: Vec<_> = logs
        .lines()
        .into_iter()
        .filter(|l| l.contains("giving up on [11]"))
        .collect();
    assert_eq!(giveup.len(), 1, "{:?}", logs.lines());
    assert!(giveup[0].contains("bad studio_id"));
    assert!(giveup[0].contains("giving up on [11] after 3 failures: "));
}

#[tokio::test]
async fn scene_ids_ignore_state_and_bare_filter() {
    let st = FakeStash {
        scenes_dict: HashMap::from([
            ("11".to_string(), scene_id("11")),
            ("12".to_string(), scene_id("12")),
        ]),
        bare_forbidden: true,
        ..Default::default()
    };
    let db = Db::open_in_memory().unwrap();
    db.identify_mark_done("12").unwrap();
    let o = PassOpts {
        scene_ids: Some(vec!["12".into()]),
        ..manual()
    };
    pass(&st, &titled(), None, &db, None, o).await;
    assert_eq!(st.jobs(), vec![]);
    assert_eq!(st.update_ids(), vec!["12"]);
    assert!(db.identify_done("12").unwrap()); // updated even though already in state
}

#[tokio::test]
async fn edited_meanwhile_not_applied() {
    // Listed bare, but a fresh re-fetch shows the scene picked up a title by other
    // means (UI edit, a concurrent identify) while the LLM step was running.
    let st = FakeStash {
        scenes_dict: HashMap::from([(
            "11".to_string(),
            merge_scene(scene_id("11"), json!({"title": "Already Titled"})),
        )]),
        ..FakeStash::pass(vec![scene_id("11")])
    };
    let db = Db::open_in_memory().unwrap();
    pass(&st, &titled(), None, &db, None, manual()).await;
    assert_eq!(st.updates(), Vec::<Value>::new());
    assert!(db.identify_done("11").unwrap());
}

#[tokio::test]
async fn gone_mid_run_is_skipped() {
    // The re-fetch finds nothing: the scene was deleted while the LLM step ran.
    // Nothing should be created or updated, and it must not be recorded as done.
    let st = FakeStash {
        missing: HashSet::from(["11".to_string()]),
        ..FakeStash::pass(vec![scene_id("11")])
    };
    let (logs, _guard) = Logs::capture();
    let db = Db::open_in_memory().unwrap();
    pass(&st, &titled(), None, &db, None, manual()).await;
    assert_eq!((st.updates(), st.created()), (vec![], vec![]));
    assert!(!db.identify_done("11").unwrap());
    assert!(
        logs.lines()
            .iter()
            .any(|l| l.contains("[11] gone, skipped")),
        "{:?}",
        logs.lines()
    );
}

#[tokio::test]
async fn apply_uses_freshly_refetched_scene() {
    let stale = merge_scene(scene_id("11"), json!({"tags": [{"id": "stale-tag"}]}));
    let fresh = merge_scene(scene_id("11"), json!({"tags": [{"id": "fresh-tag"}]}));
    let st = FakeStash {
        scenes_dict: HashMap::from([("11".to_string(), fresh)]),
        ..FakeStash::pass(vec![stale])
    };
    let db = Db::open_in_memory().unwrap();
    pass(&st, &titled(), None, &db, None, manual()).await;
    assert_eq!(st.updates().len(), 1);
    assert_eq!(
        st.updates()[0]["tag_ids"],
        json!(["fresh-tag", "t-llm-identified"])
    );
    assert!(db.identify_done("11").unwrap());
}

#[tokio::test]
async fn explicit_scene_run_applies_even_if_edited_meanwhile() {
    // --scene ID is an explicit ask; it should not be silently skipped.
    let edited = merge_scene(scene_id("11"), json!({"title": "Existing Title"}));
    let st = FakeStash {
        scenes_dict: HashMap::from([("11".to_string(), edited)]),
        ..Default::default()
    };
    let db = Db::open_in_memory().unwrap();
    let o = PassOpts {
        scene_ids: Some(vec!["11".into()]),
        ..manual()
    };
    pass(&st, &titled(), None, &db, None, o).await;
    assert_eq!(st.updates().len(), 1);
    assert!(db.identify_done("11").unwrap());
}

#[tokio::test]
async fn llm_guess_with_code_code_is_upgraded() {
    let st = upgrade_stash(guessed_default(), None);
    let db = Db::open_in_memory().unwrap();
    db.identify_mark_done("20").unwrap(); // done long ago; upgrades ignore the state
    let tp = codedb(vec![code_hit("ABCD-910", None)]);
    pass(&st, &no_llm(), Some(&tp), &db, None, manual()).await;
    let up = &st.updates()[0];
    assert_eq!(up["title"], "ABCD-910 - Some Title");
    assert_eq!(up["studio_id"], "s-StudioK");
    assert_eq!(up["performer_ids"], json!(["p-Performer K"]));
    assert_eq!(up["tag_ids"], json!([])); // llm-identified dropped
}

#[tokio::test]
async fn upgrade_miss_writes_nothing_and_leaves_state() {
    let st = upgrade_stash(guessed_default(), None);
    let db = Db::open_in_memory().unwrap();
    let tp = codedb(vec![]);
    pass(&st, &no_llm(), Some(&tp), &db, None, manual()).await;
    assert_eq!((st.updates(), st.created()), (vec![], vec![]));
    assert!(!db.identify_done("20").unwrap());
    assert_eq!(db.identify_failures("20").unwrap(), 0);
}

#[tokio::test]
async fn llm_guess_without_code_is_not_revisited() {
    let tp = codedb(vec![code_hit("ABCD-910", None)]);
    let st = upgrade_stash(
        guessed("20", "/media/Vault/Some Title.mp4", &["t-llm-identified"]),
        None,
    );
    let db = Db::open_in_memory().unwrap();
    pass(&st, &no_llm(), Some(&tp), &db, None, manual()).await;
    assert_eq!((st.updates(), tp.calls()), (vec![], vec![]));
}

#[tokio::test]
async fn upgrade_skipped_once_tag_removed_meanwhile() {
    let st = upgrade_stash(guessed_default(), Some(guessed("20", CODE_PATH, &[])));
    let db = Db::open_in_memory().unwrap();
    let tp = codedb(vec![code_hit("ABCD-910", None)]);
    pass(&st, &no_llm(), Some(&tp), &db, None, manual()).await;
    assert_eq!(st.updates(), Vec::<Value>::new());
}

#[tokio::test]
async fn explicit_scene_run_upgrades_too() {
    let st = upgrade_stash(guessed_default(), None);
    let db = Db::open_in_memory().unwrap();
    let tp = codedb(vec![code_hit("ABCD-910", None)]);
    let o = PassOpts {
        scene_ids: Some(vec!["20".into()]),
        ..manual()
    };
    pass(&st, &no_llm(), Some(&tp), &db, None, o).await;
    assert_eq!(st.updates()[0]["title"], "ABCD-910 - Some Title");
}

#[tokio::test]
async fn fc2_llm_guess_is_upgraded_with_translation() {
    let mut st = upgrade_stash(guessed("20", FC2_PATH, &["t-llm-identified"]), None);
    st.fc2
        .insert(FC2_URL.to_string(), Ok(Some(cand(fc2_hit()))));
    let db = Db::open_in_memory().unwrap();
    let l = llm_failing(Fail::Panic("no parse")).translation(Ok("Sample Title"));
    pass(&st, &l, None, &db, None, manual()).await;
    let up = &st.updates()[0];
    assert_eq!(
        (&up["title"], &up["details"]),
        (&json!("Sample Title"), &json!("サンプル題名"))
    );
    assert_eq!(
        (&up["performer_ids"], &up["tag_ids"]),
        (&json!([]), &json!([]))
    );
}

// --- error classification ----------------------------------------------------------

#[test]
fn transient_classification() {
    // Pins which errors count as transient.
    assert!(is_transient(&anyhow!(Transient("x".into()))));
    assert!(is_transient(&net_error()));
    assert!(is_transient(&net_error().context("wrapped")));
    assert!(!is_transient(&GqlError("x".into()).into()));
    assert!(!is_transient(&anyhow!("malformed reply")));
}

// --- the daemon's sweep and watcher passes ---------------------------------------------

/// The most passes that were ever inside Stash's bare-scene query at once, with a sweep
/// and a watcher pass started together under `sweep_lock` and `watch_lock`.
async fn max_concurrent_passes(same_lock: bool) -> usize {
    let st = FakeStash::pass(vec![]);
    let llm = no_llm();
    let db = Db::open_in_memory().unwrap();
    let (a, b) = (tokio::sync::Mutex::new(()), tokio::sync::Mutex::new(()));
    let c = clients(&st, &llm, None);
    let watched = vec![format!("{}/new", PATHS.host)];
    let (r1, r2) = tokio::join!(
        locked_pass(&c, &db, &a, None),
        locked_pass(&c, &db, if same_lock { &a } else { &b }, Some(watched)),
    );
    r1.unwrap();
    r2.unwrap();
    st.max_in_flight.load(std::sync::atomic::Ordering::SeqCst)
}

#[tokio::test]
async fn sweep_and_watcher_passes_never_overlap() {
    assert_eq!(max_concurrent_passes(true).await, 1);
    // The control: without the shared lock the fake does see them overlap.
    assert_eq!(max_concurrent_passes(false).await, 2);
}

// --- provenance --------------------------------------------------------------------

use crate::provenance::tests::{FakeTorrents, add, detail};

/// A grab of "Studio A" whose file is the scene's, recorded and ready to link.
fn grabbed(db: &Db, path_in_library: &str) -> i64 {
    let id = add(
        db,
        "grab",
        None,
        "[StudioA.com] Jane - Real Title [2026, 1080p]",
        "h1",
    );
    db.record_grab(
        "Studio A",
        &std::collections::BTreeSet::from(["ep:1".to_string()]),
        "t",
        "x",
        Some(id),
    )
    .unwrap();
    db.save_files(id, &[path_in_library.to_string()]).unwrap();
    id
}

fn studio_hit(title: &str, studio: &str, rid: &str) -> Value {
    scraped(title, studio, json!("2026-01-02"), json!(600), rid)
}

#[tokio::test]
async fn linked_scene_parses_with_the_release_title_and_forced_studio() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm(json!({"studio": "Wrong", "title": "Real Title", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let titled = l.titled.lock().unwrap().clone();
    assert_eq!(
        titled,
        vec![(
            "dir/file.mp4".to_string(),
            "[StudioA.com] Jane - Real Title [2026, 1080p]".to_string(),
            Some("Studio A".to_string())
        )]
    );
    // nothing on the boxes: an llm guess, under the rule's studio, not the parse's
    let created = st.created();
    assert!(
        created
            .iter()
            .any(|(k, v)| k == "studio" && v["name"] == "Studio A"),
        "{created:?}"
    );
}

#[tokio::test]
async fn forced_studio_drops_another_studios_candidate() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash {
        results: [(
            CODEDB.to_string(),
            Ok(vec![cand(studio_hit("Real Title", "Other Studio", "r1"))]),
        )]
        .into_iter()
        .collect(),
        ..FakeStash::pass(vec![scene5()])
    };
    // Jev would pick the candidate: only the forced studio's filter keeps it out.
    let l =
        llm(json!({"title": "Real Title", "date": "2026-01-02", "performers": [], "query": "q"}))
            .choice(Ok("c0"));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let up = &st.updates()[0];
    assert!(
        up.get("stash_ids")
            .is_none_or(|s| s.as_array().unwrap().is_empty()),
        "{up}"
    );
}

#[tokio::test]
async fn forced_studio_keeps_its_own_candidate() {
    // The forced studio also lets deterministic_match (same studio and date) pick it.
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash {
        results: [(
            CODEDB.to_string(),
            Ok(vec![cand(studio_hit("Real Title", "Studio A", "r1"))]),
        )]
        .into_iter()
        .collect(),
        ..FakeStash::pass(vec![scene5()])
    };
    let l =
        llm(json!({"title": "Real Title", "date": "2026-01-02", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert_eq!(st.updates()[0]["title"], "Real Title");
    assert!(!st.updates()[0]["stash_ids"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn hinted_studio_filters_nothing() {
    let db = Db::open_in_memory().unwrap();
    let id = add(
        &db,
        "plab",
        Some(9),
        "[StudioB.com] Jane - Real Title [2026, 1080p]",
        "h1",
    );
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    let st = FakeStash {
        results: [(
            CODEDB.to_string(),
            Ok(vec![cand(studio_hit("Real Title", "Other Studio", "r1"))]),
        )]
        .into_iter()
        .collect(),
        ..FakeStash::pass(vec![scene5()])
    };
    // The parse names the other studio, so deterministic_match picks its scene: only a
    // forced studio would have dropped it.
    let l = llm(
        json!({"studio": "Other Studio", "title": "Real Title", "date": "2026-01-02",
                       "performers": [], "query": "q"}),
    );
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert!(l.titled.lock().unwrap()[0].2.is_some()); // the title's studio label, as a hint
    assert!(!st.updates()[0]["stash_ids"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn unlinked_scene_parses_the_path_as_before() {
    let db = Db::open_in_memory().unwrap();
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm(json!({"title": "T", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert!(l.titled.lock().unwrap().is_empty());
}

#[tokio::test]
async fn outcomes_are_recorded_for_linked_scenes() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm(json!({"title": "Real Title", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let row = db.link_scene("dir/file.mp4", None).unwrap().unwrap();
    assert_eq!(row.download_id, 1);
    let (outcome, label): (Option<String>, Option<String>) = outcome_of(&db, "5");
    assert_eq!(outcome.as_deref(), Some("llm"));
    assert_eq!(label.as_deref(), Some("Real Title · Studio A"));
}

#[tokio::test]
async fn nothing_found_is_recorded_none() {
    // A grab always has its studio (so at least an llm guess); a plab add whose title has
    // no studio label can find nothing.
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(3), "x", "h2");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm(json!({"performers": [], "query": ""}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert_eq!(outcome_of(&db, "5").0.as_deref(), Some("none"));
}

#[tokio::test]
async fn giving_up_is_recorded() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm_failing(Fail::Msg("malformed"));
    for _ in 0..IDENTIFY_FAILURE_LIMIT {
        pass(&st, &l, None, &db, None, opts()).await;
    }
    assert_eq!(outcome_of(&db, "5").0.as_deref(), Some("gave-up"));
}

#[tokio::test]
async fn a_failed_outcome_write_after_applying_is_not_an_identify_failure() {
    // The scene is written to Stash; only the page's record of it fails.
    let db = Db::open_in_memory().unwrap();
    db.exec("DROP TABLE download_file").unwrap();
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm(json!({"title": "Real Title", "studio": "S", "performers": [], "query": "q"}));
    pass(&st, &l, None, &db, None, opts()).await;
    assert_eq!(st.updates().len(), 1);
    assert!(db.identify_done("5").unwrap());
    assert_eq!(db.identify_failures("5").unwrap(), 0);
}

#[tokio::test]
async fn a_failed_gave_up_write_does_not_stop_the_pass() {
    let db = Db::open_in_memory().unwrap();
    db.exec("DROP TABLE download_file").unwrap();
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm_failing(Fail::Msg("malformed"));
    for _ in 0..IDENTIFY_FAILURE_LIMIT {
        pass(&st, &l, None, &db, None, opts()).await; // unwraps run_pass's result
    }
    assert!(db.identify_done("5").unwrap());
}

#[tokio::test]
async fn a_new_scene_stash_filled_is_recorded_stash() {
    let db = Db::open_in_memory().unwrap();
    grabbed(&db, "dir/file.mp4");
    let filled = merge_scene(
        scene_id("11"),
        json!({"title": "From Fingerprint", "studio": {"id": "s1", "name": "Studio A"}}),
    );
    let st = FakeStash {
        scenes_dict: [("11".to_string(), filled)].into_iter().collect(),
        ..FakeStash::pass(vec![])
    };
    let l = llm(json!({}));
    pass(
        &st,
        &l,
        None,
        &db,
        Some(vec!["/mnt/storage/media/Vault/dir".into()]),
        opts(),
    )
    .await;
    let (outcome, label) = outcome_of(&db, "11");
    assert_eq!(outcome.as_deref(), Some("stash"));
    assert_eq!(label.as_deref(), Some("From Fingerprint · Studio A"));
}

#[tokio::test]
async fn a_pass_records_download_files_first() {
    let db = Db::open_in_memory().unwrap();
    add(&db, "grab", None, "R", "h1");
    let torrents = FakeTorrents::new(vec![detail(
        "h1",
        "/mnt/storage/media/Vault",
        1.0,
        &["dir/file.mp4"],
    )]);
    let st = FakeStash::pass(vec![]);
    let l = llm(json!({}));
    let c = Clients {
        torrents: Some(&torrents),
        ..clients(&st, &l, None)
    };
    run_pass(&c, &db, &defaults(), None, &opts()).await.unwrap();
    assert_eq!(torrents.asked.lock().unwrap().len(), 1);
    assert!(db.link_scene("dir/file.mp4", None).unwrap().is_some());
}

fn manual_for(id: &str) -> PassOpts {
    PassOpts {
        scene_ids: Some(vec![id.to_string()]),
        ..manual()
    }
}

fn outcome_of(db: &Db, scene_id: &str) -> (Option<String>, Option<String>) {
    db.outcome_of(scene_id).unwrap()
}

fn cover_file() -> (tempfile::TempDir, PathBuf) {
    let d = tempfile::tempdir().unwrap();
    let p = d.path().join("1");
    std::fs::write(&p, b"\xff\xd8\xffJPEG").unwrap();
    (d, p)
}

#[tokio::test]
async fn tracker_cover_fills_an_llm_guess() {
    let (_d, cover) = cover_file();
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(1), "[StudioB.com] Jane - T [2026]", "h1");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    db.set_cover(id, cover.to_str().unwrap()).unwrap();
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm(json!({"title": "T", "performers": [], "query": ""}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let up = &st.updates()[0];
    assert!(
        up["cover_image"]
            .as_str()
            .unwrap()
            .starts_with("data:image/jpeg;base64,")
    );
}

#[tokio::test]
async fn tracker_cover_alone_for_nothing_found() {
    let (_d, cover) = cover_file();
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(1), "x", "h1");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    db.set_cover(id, cover.to_str().unwrap()).unwrap();
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm(json!({"performers": [], "query": ""}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    let up = &st.updates()[0];
    assert_eq!(up.as_object().unwrap().len(), 2, "{up}"); // id and cover_image only
}

#[tokio::test]
async fn a_scrape_image_wins_over_the_tracker_cover() {
    let (_d, cover) = cover_file();
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(1), "x", "h1");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    db.set_cover(id, cover.to_str().unwrap()).unwrap();
    let st = FakeStash {
        results: [(
            CODEDB.to_string(),
            Ok(vec![cand(studio_hit("Real Title", "S", "r1"))]),
        )]
        .into_iter()
        .collect(),
        ..FakeStash::pass(vec![scene5()])
    };
    let l =
        llm(json!({"title": "Real Title", "date": "2026-01-02", "performers": [], "query": "q"}))
            .choice(Ok("c0"));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert_eq!(st.updates()[0]["cover_image"], "data:img"); // scraped()'s image
}

#[tokio::test]
async fn a_missing_cover_file_is_skipped() {
    let db = Db::open_in_memory().unwrap();
    let id = add(&db, "plab", Some(1), "x", "h1");
    db.save_files(id, &["dir/file.mp4".into()]).unwrap();
    db.set_cover(id, "/nonexistent/cover").unwrap();
    let st = FakeStash::pass(vec![scene5()]);
    let l = llm(json!({"title": "T", "performers": [], "query": ""}));
    pass(&st, &l, None, &db, None, manual_for("5")).await;
    assert!(st.updates()[0].get("cover_image").is_none());
}
