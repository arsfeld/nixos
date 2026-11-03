//! The identify pass: scan, generate and identify new Stash files, then fill bare scenes
//! from an LLM filename parse, confirmed against stash-box where possible. Files named by a
//! product code are looked up by it first (FC2-PPV ones on FC2 itself, title translated), and
//! replace earlier LLM guesses. Port of stash-identify `main.py` (the watcher is Task 15).

pub mod matching;
pub mod watch;

use crate::backends::IdentifyBackends;
use std::collections::{BTreeSet, HashSet};
use std::path::Path;

use anyhow::Context;

use crate::codedb::{CodeDbError, CodeSearch};
use crate::db::{Db, IDENTIFY_FAILURE_LIMIT};
use crate::llm::{Llm, Parse};
use crate::provenance::{self, Provenance};
use crate::stash::{
    Candidate, Defaults, GqlError, PerformerCreate, Resolved, Scene, SceneUpdate, StashApi,
    StashId, StudioCreate,
};
use matching::Hit;

pub const STASHDB: &str = "https://stashdb.org/graphql";
pub const PER_BOX: usize = 6;
pub const LLM_TAG: &str = "llm-identified";
pub const LIBRARY_HOST: &str = "/mnt/storage/media/Vault";
pub const LIBRARY_CONTAINER: &str = "/media/Vault";

/// A stash-box search, the Jev call, a code-database lookup or an FC2 scrape/translation
/// failed. These are typically an external-service blip rather than anything wrong with
/// the scene, so run_pass retries the scene next pass without counting it toward the
/// failure cap (see is_transient, which also covers raw transport errors from any
/// OpenRouter or Stash call, however they surface).
#[derive(Debug, thiserror::Error)]
#[error("{0}")]
pub struct Transient(pub String);

/// A title for a log line: quoted, or an unquoted `-` when there is none.
fn quoted_or_dash(s: Option<&str>) -> String {
    s.map_or_else(|| "-".to_string(), |s| format!("{s:?}"))
}

fn transient(msg: String) -> anyhow::Error {
    Transient(msg).into()
}

/// A `Transient`, or any `reqwest::Error` anywhere in the chain (connect, timeout, HTTP
/// status). GraphQL errors and
/// malformed LLM replies are not.
pub fn is_transient(e: &anyhow::Error) -> bool {
    e.chain()
        .any(|c| c.is::<Transient>() || c.is::<reqwest::Error>())
}

/// The library as the host sees it and as the Stash container does.
pub struct Paths {
    pub host: String,
    pub container: String,
}

impl Default for Paths {
    fn default() -> Paths {
        Paths {
            host: LIBRARY_HOST.into(),
            container: LIBRARY_CONTAINER.into(),
        }
    }
}

impl Paths {
    pub fn rel_path<'a>(&self, container_path: &'a str) -> &'a str {
        container_path
            .strip_prefix(&format!("{}/", self.container))
            .unwrap_or(container_path)
    }

    pub fn to_container(&self, host_path: &str) -> String {
        format!(
            "{}{}",
            self.container,
            host_path.strip_prefix(&self.host).unwrap_or(host_path)
        )
    }
}

/// Which rule confirmed a scrape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rule {
    /// The file's product / FC2 code.
    Code,
    /// Studio and date agree with the filename parse.
    Date,
    /// The Jev call picked it.
    Jev,
}

impl std::fmt::Display for Rule {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str(match self {
            Rule::Code => "code",
            Rule::Date => "date",
            Rule::Jev => "jev",
        })
    }
}

/// A confirmed match against a stash-box, the code database or FC2.
#[derive(Debug, Clone, PartialEq)]
pub struct ScrapeMatch {
    pub rule: Rule,
    /// The lookup that found it ("stashdb", "codedb", "fc2"); empty for a stash-box
    /// search, whose source is named by its stash ids.
    pub source: &'static str,
    pub candidate: Candidate,
    pub endpoint: Option<String>,
    pub stash_ids: Vec<StashId>,
    pub confidence: Option<f64>,
    /// Candidate duration minus the file's, in whole seconds.
    pub delta: Option<i64>,
}

impl ScrapeMatch {
    fn code(source: &'static str, candidate: Candidate, endpoint: Option<&str>) -> ScrapeMatch {
        ScrapeMatch {
            rule: Rule::Code,
            source,
            candidate,
            endpoint: endpoint.map(str::to_string),
            stash_ids: vec![],
            confidence: None,
            delta: None,
        }
    }

    /// The source, or the stash-boxes its ids come from ("stashdb+codedb").
    fn source_label(&self) -> String {
        if !self.source.is_empty() {
            return self.source.to_string();
        }
        let labels: BTreeSet<&str> = self
            .stash_ids
            .iter()
            .map(|s| {
                let host = s.endpoint.split('/').nth(2).unwrap_or("");
                let parts: Vec<&str> = host.split('.').collect();
                parts[parts.len().saturating_sub(2)]
            })
            .collect();
        labels.into_iter().collect::<Vec<_>>().join("+")
    }
}

/// What identify proposes for a scene.
// One value per scene per pass, so boxing the scrape would buy nothing.
#[allow(clippy::large_enum_variant)]
#[derive(Debug, Clone, PartialEq)]
pub enum Proposal {
    Nothing,
    /// An unconfirmed filename guess.
    Llm(Parse),
    Scrape(ScrapeMatch),
}

impl std::fmt::Display for Proposal {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        fn or_dash(s: &str) -> &str {
            if s.is_empty() { "-" } else { s }
        }
        match self {
            Proposal::Scrape(m) => {
                let c = &m.candidate;
                let conf = m
                    .confidence
                    .map_or(String::new(), |c| format!(" conf={c:.2}"));
                let perf: Vec<&str> = c
                    .performers
                    .iter()
                    .filter_map(|p| p.name.as_deref())
                    .collect();
                let delta = m.delta.map_or("Δ?".to_string(), |d| format!("Δ{d:+}s"));
                write!(
                    f,
                    "{} ({}{conf}) | {} | {} | {} | {delta}",
                    m.source_label(),
                    m.rule,
                    quoted_or_dash(c.title.as_deref()),
                    c.studio_name().unwrap_or("-"),
                    or_dash(&perf.join(", ")),
                )
            }
            Proposal::Llm(q) => write!(
                f,
                "llm-only | {} | {} | {}",
                quoted_or_dash(q.display_title().as_deref()),
                q.studio.as_deref().unwrap_or("-"),
                or_dash(&q.performers.join(", ")),
            ),
            Proposal::Nothing => f.write_str("nothing found"),
        }
    }
}

/// What identify made of a scene, as the page's status records it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Scrape,
    Llm,
    Nothing,
    /// Stash's own identify filled it.
    Stash,
    GaveUp,
}

impl Outcome {
    /// The value stored in the database.
    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Scrape => "scrape",
            Outcome::Llm => "llm",
            Outcome::Nothing => "none",
            Outcome::Stash => "stash",
            Outcome::GaveUp => "gave-up",
        }
    }
}

pub struct Clients<'a, B: IdentifyBackends> {
    pub stash: &'a B::Stash,
    pub llm: &'a B::Llm,
    pub codedb: Option<&'a B::CodeSearch>,
    pub paths: &'a Paths,
    /// Transmission, for recording download files at the start of a pass; None in a
    /// dry run's tests.
    pub torrents: Option<&'a B::Torrents>,
}

/// A "scrape" proposal from the FC2 article itself, via Stash's fc2 scraper, or None.
/// Neither stash-box carries FC2-PPV, so this is the only source. FC2 pulls
/// articles after a while, and the scraper answers a pulled one with a GraphQL error (a
/// nil dereference), so any Stash-side error counts as a miss. That costs nothing: a
/// miss leaves an llm-identified guess, which every pass looks up again. Only Stash
/// being unreachable, or the translation failing, is Transient.
pub async fn fc2_prop<B: IdentifyBackends>(
    c: &Clients<'_, B>,
    scene: &Scene,
    number: &str,
) -> anyhow::Result<Option<Proposal>> {
    let id = scene.id.clone();
    let hit = match c
        .stash
        .scrape_url(&crate::site::get().fc2_article.replace("{}", number))
        .await
    {
        Ok(hit) => hit,
        Err(e) if is_transient(&e) => {
            return Err(transient(format!("scene {id}: fc2 scrape failed: {e:#}")));
        }
        Err(e) if e.is::<GqlError>() => {
            tracing::info!(
                "scene {id}: fc2 article {number} not scraped, treating as a miss: {e:#}"
            );
            return Ok(None);
        }
        Err(e) => return Err(e),
    };
    let Some(hit) = hit else { return Ok(None) };
    let Some(original) = hit.title.as_deref() else {
        return Ok(None);
    };
    let title = c
        .llm
        .translate_title(original)
        .await
        .map_err(|e| transient(format!("scene {id}: title translation failed: {e:#}")))?;
    Ok(Some(Proposal::Scrape(ScrapeMatch::code(
        "fc2",
        matching::fc2_scene(&hit, &title),
        None,
    ))))
}

/// A "scrape" proposal for a file named by a product code, or None (no code, or no exact
/// hit). FC2-PPV codes go to fc2_prop. Others try StashDB first, for its stash_ids and
/// tags; then the code database. The code is the identity check, so there's no
/// duration gate: the code database lists durations in whole minutes, and multi-part files share
/// one code. A failed lookup is Transient rather than letting the scene fall through to
/// a guess.
pub async fn code_prop<B: IdentifyBackends>(
    c: &Clients<'_, B>,
    scene: &Scene,
) -> anyhow::Result<Option<Proposal>> {
    let id = scene.id.clone();
    let (path, duration) = scene.first_file()?;
    let Some(code) = matching::product_code(c.paths.rel_path(path)) else {
        return Ok(None);
    };
    if let Some(number) = matching::fc2_number(&code) {
        return fc2_prop(c, scene, &number).await;
    }
    let key = matching::code_key(Some(&code));
    let hits = c
        .stash
        .search(STASHDB, &code)
        .await
        .map_err(|e| transient(format!("scene {id}: search {STASHDB} failed: {e:#}")))?;
    let mut chosen = matching::single_scene(
        hits.iter()
            .filter(|h| matching::code_key(h.code.as_deref()) == key)
            .cloned()
            .collect(),
    );
    let (mut ep, mut source) = (STASHDB, "stashdb");
    if let (None, Some(codedb)) = (&chosen, c.codedb) {
        let hits = match codedb.code_search(&code).await {
            Ok(hits) => hits,
            Err(CodeDbError::Status(code @ (401 | 403))) => {
                tracing::info!(
                    "scene {id}: the code database refused the key ({code}); treating as a miss"
                );
                vec![]
            }
            Err(e) => {
                return Err(transient(format!(
                    "scene {id}: code database search failed: {e:#}"
                )));
            }
        };
        chosen = matching::single_scene(
            hits.into_iter()
                .filter(|h| matching::code_key(h.external_id.as_deref()) == key)
                .map(Candidate::from)
                .collect(),
        );
        (ep, source) = (&crate::site::get().code_db.search_url, "codedb");
    }
    let Some(chosen) = chosen else {
        return Ok(None);
    };
    let delta = chosen
        .known_duration()
        .map(|d| (d - duration).round_ties_even() as i64);
    let stash_ids = matching::stash_ids_for(ep, chosen.remote_site_id.as_deref());
    Ok(Some(Proposal::Scrape(ScrapeMatch {
        stash_ids,
        delta,
        ..ScrapeMatch::code(source, chosen, Some(ep))
    })))
}

fn box_index(ep: &str) -> usize {
    crate::site::get()
        .boxes()
        .iter()
        .position(|b| *b == ep)
        .unwrap_or(usize::MAX)
}

/// Propose metadata for one bare scene. A file named by a product code is looked up by its code first
/// (code_prop), and only reaches the LLM if that finds nothing. Fails if the parse, a
/// stash-box search, or the Jev call fails: run_pass must retry the scene next pass
/// rather than record a downgraded llm-only guess that would lose a possible scrape for
/// good. Only downgrades to llm-only when every search succeeded and turned up nothing
/// usable (or Jev affirmatively picked none). A search or Jev failure is Transient; a
/// malformed LLM parse reply is scene-specific and propagates as-is.
pub async fn identify_scene<B: IdentifyBackends>(
    c: &Clients<'_, B>,
    scene: &Scene,
    prov: Option<&Provenance>,
) -> anyhow::Result<Proposal> {
    if let Some(prop) = code_prop(c, scene).await? {
        return Ok(prop);
    }
    let id = scene.id.clone();
    let (path, duration) = scene.first_file()?;
    let path = c.paths.rel_path(path);
    let mut parse = match prov {
        Some(p) => {
            c.llm
                .parse_with_title(path, &p.title, p.studio.as_deref())
                .await?
        }
        None => c.llm.parse(path).await?,
    };
    // A grab's studio is certain: it overrides the parse, and only its scenes are candidates.
    let forced = prov.filter(|p| p.forced).and_then(|p| p.studio.as_deref());
    if let Some(s) = forced {
        parse.studio = Some(s.to_string());
    }
    let fallback = if parse.has_content() {
        Proposal::Llm(parse.clone())
    } else {
        Proposal::Nothing
    };

    let mut everything: Vec<Hit> = Vec::new();
    if let Some(query) = parse.query.as_deref() {
        for ep in crate::site::get().boxes() {
            let hits = c
                .stash
                .search(ep, query)
                .await
                .map_err(|e| transient(format!("scene {id}: search {ep} failed: {e:#}")))?;
            everything.extend(hits.into_iter().take(PER_BOX).map(|scene| Hit {
                endpoint: ep.to_string(),
                scene,
            }));
        }
    }
    if let Some(s) = forced {
        everything.retain(|h| matching::studio_matches(&h.scene, s));
    }
    let cands = matching::dedupe(
        everything
            .iter()
            .filter(|h| matching::duration_ok(&h.scene, duration))
            .cloned()
            .collect(),
    );
    if cands.is_empty() {
        return Ok(fallback);
    }

    let mut confidence = None;
    let (chosen, rule) = match matching::deterministic_match(&cands, &parse) {
        Some(chosen) => (Some(chosen), Rule::Date),
        None => {
            let req = matching::jev_request(path, duration, &parse, &cands);
            let answer = c
                .llm
                .choose(&req)
                .await
                .map_err(|e| transient(format!("scene {id}: jev failed: {e:#}")))?;
            confidence = answer.confidence;
            (
                matching::jev_pick(answer.choice.as_deref(), &cands)?,
                Rule::Jev,
            )
        }
    };
    let Some(chosen) = chosen else {
        return Ok(fallback);
    };

    let mut group = matching::twins(&chosen, &everything, duration);
    group.sort_by_key(|h| box_index(&h.endpoint)); // stable: the first minimum leads
    let Hit {
        endpoint: primary_ep,
        scene: primary,
    } = group
        .first()
        .cloned()
        .context("the chosen scene has no twin")?;
    let mut ids = Vec::new();
    let mut seen = HashSet::new();
    for h in &group {
        if let Some(rid) = h.scene.remote_site_id.as_deref()
            && seen.insert(h.endpoint.clone())
        {
            ids.extend(matching::stash_ids_for(&h.endpoint, Some(rid)));
        }
    }
    let primary_duration = primary.duration.context("matched scene has no duration")?;
    Ok(Proposal::Scrape(ScrapeMatch {
        rule,
        source: "",
        delta: Some((primary_duration - duration).round_ties_even() as i64),
        candidate: primary,
        endpoint: Some(primary_ep),
        stash_ids: ids,
        confidence,
    }))
}

async fn resolve_studio<S: StashApi>(
    stash: &S,
    name: &str,
    create_input: Option<StudioCreate>,
    endpoint: Option<&str>,
    remote_id: Option<&str>,
    create: bool,
) -> anyhow::Result<Option<String>> {
    if let (Some(ep), Some(rid)) = (
        endpoint.filter(|e| !e.is_empty()),
        remote_id.filter(|r| !r.is_empty()),
    ) && let Some(hit) = stash.studio_by_stash_id(ep, rid).await?
    {
        return Ok(Some(hit));
    }
    let hit = matching::pick_by_name(&stash.studios_like(name).await?, name, true);
    if hit.is_some() || !create {
        return Ok(hit);
    }
    let inp = create_input.unwrap_or_else(|| StudioCreate::named(name));
    Ok(Some(stash.create_studio(&inp).await?))
}

async fn resolve_performer<S: StashApi>(
    stash: &S,
    name: &str,
    create_input: Option<PerformerCreate>,
    endpoint: Option<&str>,
    remote_id: Option<&str>,
) -> anyhow::Result<String> {
    if let (Some(ep), Some(rid)) = (
        endpoint.filter(|e| !e.is_empty()),
        remote_id.filter(|r| !r.is_empty()),
    ) && let Some(hit) = stash.performer_by_stash_id(ep, rid).await?
    {
        return Ok(hit);
    }
    let records = stash.performers_like(name).await?;
    if let Some(hit) = matching::pick_by_name(&records, name, matching::alias_ok(name)) {
        return Ok(hit);
    }
    let inp = create_input.unwrap_or_else(|| PerformerCreate::named(name));
    stash.create_performer(&inp).await
}

pub async fn apply<B: IdentifyBackends>(
    c: &Clients<'_, B>,
    scene: &Scene,
    prop: &Proposal,
    skip_tag_ids: &HashSet<String>,
    overwrite: bool,
    cover: Option<&Path>,
) -> anyhow::Result<()> {
    let stash = c.stash;
    match prop {
        Proposal::Scrape(m) => {
            let p = &m.candidate;
            let ep = m.endpoint.as_deref();
            let mut resolved = Resolved {
                stash_ids: m.stash_ids.clone(),
                ..Resolved::default()
            };
            if let Some(s) = &p.studio {
                let mut parent_id = None;
                if let Some(parent) = &s.parent {
                    parent_id = resolve_studio(
                        stash,
                        parent.name.as_deref().unwrap_or(""),
                        None,
                        ep,
                        parent.remote_site_id.as_deref(),
                        false,
                    )
                    .await?;
                }
                let inp = matching::studio_create_input(s, ep.unwrap_or(""), parent_id.as_deref());
                resolved.studio_id = resolve_studio(
                    stash,
                    s.name.as_deref().unwrap_or(""),
                    Some(inp),
                    ep,
                    s.remote_site_id.as_deref(),
                    true,
                )
                .await?;
            }
            for x in &p.performers {
                let Some(name) = x.name.as_deref() else {
                    continue;
                };
                let inp = matching::performer_create_input(x, ep.unwrap_or(""));
                resolved.performer_ids.push(
                    resolve_performer(stash, name, Some(inp), ep, x.remote_site_id.as_deref())
                        .await?,
                );
            }
            resolved.tag_ids = p.tags.iter().filter_map(|t| t.stored_id.clone()).collect();
            let up = matching::scrape_update(scene, p, &resolved, skip_tag_ids, overwrite);
            stash
                .update_scene(&with_cover(english_title(c, scene, up).await?, cover))
                .await
        }
        Proposal::Llm(parse) => {
            let studio_id = match parse.studio.as_deref() {
                Some(studio) => resolve_studio(stash, studio, None, None, None, true).await?,
                None => None,
            };
            let mut performer_ids = Vec::new();
            for n in &parse.performers {
                performer_ids.push(resolve_performer(stash, n, None, None, None).await?);
            }
            let tag = stash
                .tag_id(LLM_TAG, true)
                .await?
                .context("the llm-identified tag was not created")?;
            let up = matching::llm_update(scene, parse, studio_id.as_deref(), &performer_ids, &tag);
            stash
                .update_scene(&with_cover(english_title(c, scene, up).await?, cover))
                .await
        }
        Proposal::Nothing => {
            let up = with_cover(SceneUpdate::new(&scene.id), cover);
            if up.has_changes() {
                stash.update_scene(&up).await?;
            }
            Ok(())
        }
    }
}

/// Whether a title is written in a script other than Latin (Cyrillic, kana, Han, ...), and
/// so wants translating before it lands in Stash.
fn is_non_latin(title: &str) -> bool {
    static RE: std::sync::LazyLock<regex::Regex> =
        std::sync::LazyLock::new(|| regex::Regex::new(r"[\p{L}--\p{Latin}]").unwrap());
    RE.is_match(title)
}

/// The update with a non-Latin title replaced by its English translation, whichever source
/// it came from: a stash-box or code-database scrape, an LLM guess off the filename. FC2 titles are
/// already translated in fc2_prop and pass through untouched. A failed translation is
/// Transient, so the scene is retried rather than written in a language nobody reads.
async fn english_title<B: IdentifyBackends>(
    c: &Clients<'_, B>,
    scene: &Scene,
    mut up: SceneUpdate,
) -> anyhow::Result<SceneUpdate> {
    if let Some(original) = up.title.as_deref().filter(|t| is_non_latin(t)) {
        let title = c.llm.translate_title(original).await.map_err(|e| {
            transient(format!(
                "scene {}: title translation failed: {e:#}",
                scene.id
            ))
        })?;
        up.title = Some(title);
    }
    Ok(up)
}

/// The file as a `data:` URI for Stash's cover_image, or None (logged) if unreadable or not
/// an image.
fn cover_uri(path: &Path) -> Option<String> {
    use base64::Engine;
    let data = match std::fs::read(path) {
        Ok(d) => d,
        Err(e) => {
            tracing::info!("cover {}: {e}", path.display());
            return None;
        }
    };
    let ctype = crate::images::sniff(&data)?;
    Some(format!(
        "data:{ctype};base64,{}",
        base64::engine::general_purpose::STANDARD.encode(&data)
    ))
}

/// Add the tracker cover to an update that sets none.
fn with_cover(mut up: SceneUpdate, cover: Option<&Path>) -> SceneUpdate {
    if up.cover_image.is_none()
        && let Some(uri) = cover.and_then(cover_uri)
    {
        up.cover_image = Some(uri);
    }
    up
}

/// The two lines a pass prints for a scene's proposal.
pub fn format_line(paths: &Paths, scene: &Scene, prop: &Proposal) -> String {
    let file = scene.first_path().unwrap_or("");
    format!("[{}] {}\n    {prop}", scene.id, paths.rel_path(file))
}

/// An earlier LLM guess on a file named by a product code: re-checked every pass (lookup
/// only, never the LLM) and overwritten once the code is found. Removing the tag in the
/// UI opts a scene out. A scene with no files (shouldn't happen, but tags aren't proof
/// of a file) is never an upgrade.
pub fn is_upgrade(paths: &Paths, scene: &Scene, llm_tag_id: Option<&str>) -> bool {
    let Some(tag) = llm_tag_id.filter(|t| !t.is_empty()) else {
        return false;
    };
    scene.has_tag(tag)
        && scene
            .first_path()
            .is_some_and(|p| matching::product_code(paths.rel_path(p)).is_some())
}

pub struct PassOpts {
    /// Run Stash's scan/generate/identify first.
    pub jobs: bool,
    /// Print proposals; write nothing.
    pub dry_run: bool,
    pub limit: Option<usize>,
    /// Exactly these scenes, ignoring the done set.
    pub scene_ids: Option<Vec<String>>,
}

async fn stash_jobs<S: StashApi>(
    stash: &S,
    paths: &Paths,
    defaults: &Defaults,
    dirs: Option<&Vec<String>>,
) -> anyhow::Result<Vec<String>> {
    let watched = dirs.filter(|d| !d.is_empty());
    let before = stash.max_scene_id().await?;
    tracing::info!(
        "scan {}",
        watched.map_or("library".to_string(), |d| format!("{d:?}"))
    );
    let scan_paths = watched.map(|d| d.iter().map(|p| paths.to_container(p)).collect());
    stash.scan(scan_paths, &defaults.scan).await?;
    let new = stash.scene_ids_after(before).await?;
    tracing::info!("{} new scene(s)", new.len());
    if !new.is_empty() || dirs.is_none() {
        // The sweep generates library-wide (overwrite is always off, so only missing
        // files are made); a watched pass only touches its new scenes.
        let ids = watched.map(|_| new.clone());
        stash.generate(ids, &defaults.generate).await?;
    }
    let trusted: Vec<String> = match fingerprint_suspects(stash, defaults, &new).await {
        Ok(suspects) => new
            .iter()
            .filter(|id| !suspects.contains(*id))
            .cloned()
            .collect(),
        Err(e) => {
            tracing::warn!("checking fingerprint matches failed, identifying all: {e:#}");
            new.clone()
        }
    };
    if !trusted.is_empty() {
        stash.identify(trusted, &defaults.identify).await?;
    }
    Ok(new)
}

/// Scenes Stash's identify would fill from a fingerprint match whose duration is more
/// than DURATION_TOLERANCE off the file's. Stash trusts a fingerprint outright, and a
/// stash-box scene can carry another video's fingerprints: one 943s scene
/// listed the oshash of an unrelated 1249s file, and Stash gave that file its title.
/// Like Stash, the first endpoint with any match decides; a match of unknown duration
/// cannot be judged and passes. These scenes stay bare, so the LLM step takes them, and
/// its stash-box candidates must match the duration.
async fn fingerprint_suspects<S: StashApi>(
    stash: &S,
    defaults: &Defaults,
    ids: &[String],
) -> anyhow::Result<HashSet<String>> {
    let mut suspects = HashSet::new();
    let boxes = defaults.identify_boxes();
    if boxes.is_empty() || ids.is_empty() {
        return Ok(suspects);
    }
    let mut undecided: Vec<(String, f64)> = stash
        .scenes(ids)
        .await?
        .iter()
        .filter_map(|s| Some((s.id.clone(), s.first_file().ok()?.1)))
        .collect();
    for ep in &boxes {
        if undecided.is_empty() {
            break;
        }
        let ids: Vec<String> = undecided.iter().map(|(id, _)| id.clone()).collect();
        let matches = stash.fingerprint_matches(ep, &ids).await?;
        let mut rest = Vec::new();
        for ((id, file), found) in undecided.into_iter().zip(matches) {
            if found.is_empty() {
                rest.push((id, file));
                continue;
            }
            let off = found.iter().find_map(|m| {
                let d = m.duration?;
                ((d - file).abs() > matching::DURATION_TOLERANCE).then_some((m, d))
            });
            if let Some((m, d)) = off {
                tracing::warn!(
                    "[{id}] {ep} fingerprint match {} is {d}s, the file {file}s: \
                     left to the LLM step",
                    quoted_or_dash(m.title.as_deref())
                );
                suspects.insert(id);
            }
        }
        undecided = rest;
    }
    Ok(suspects)
}

/// A pass with Stash's jobs, as the daemon runs it: the sweep (`paths` None) or a watcher
/// pass over changed folders. `lock` is held throughout, so the two never overlap, as they
/// could not in stash-identify's single watch loop: overlapping passes would pick the same
/// bare scenes (double LLM spend, double failure counts, duplicate studios or performers
/// created in Stash) and queue a library-wide scan beside a per-folder one.
pub async fn locked_pass<B: IdentifyBackends>(
    c: &Clients<'_, B>,
    db: &Db,
    lock: &tokio::sync::Mutex<()>,
    paths: Option<Vec<String>>,
) -> anyhow::Result<()> {
    let _pass = lock.lock().await;
    let defaults = c.stash.defaults().await?;
    let opts = PassOpts {
        jobs: true,
        dry_run: false,
        limit: None,
        scene_ids: None,
    };
    run_pass(c, db, &defaults, paths, &opts).await
}

/// One pass. paths=None means the whole library (the sweep). jobs=false skips Stash's
/// scan/generate/identify; scene_ids processes exactly those scenes, ignoring the done set.
pub async fn run_pass<B: IdentifyBackends>(
    c: &Clients<'_, B>,
    db: &Db,
    defaults: &Defaults,
    paths: Option<Vec<String>>,
    opts: &PassOpts,
) -> anyhow::Result<()> {
    let stash = c.stash;
    if !opts.dry_run
        && let Some(t) = c.torrents
        && let Err(e) = provenance::sync(db, t, c.paths, None).await
    {
        tracing::warn!("recording download files failed, continuing: {e:#}");
    }
    let mut new = Vec::new();
    if opts.jobs && !opts.dry_run {
        match stash_jobs(stash, c.paths, defaults, paths.as_ref()).await {
            Ok(ids) => new = ids,
            Err(e) => tracing::warn!("stash jobs failed, continuing to the LLM step: {e:#}"),
        }
    }
    if !new.is_empty() {
        record_new(c, db, &new).await;
    }

    let llm_tag = stash.tag_id(LLM_TAG, false).await?;
    let mut todo = match opts.scene_ids.as_ref().filter(|ids| !ids.is_empty()) {
        Some(ids) => stash.scenes(ids).await?,
        None => {
            let mut todo = Vec::new();
            for s in stash.bare_scenes().await? {
                if !db.identify_done(&s.id)? {
                    todo.push(s);
                }
            }
            if let Some(tag) = &llm_tag {
                todo.extend(
                    stash
                        .scenes_with_tag(tag)
                        .await?
                        .into_iter()
                        .filter(|s| is_upgrade(c.paths, s, Some(tag))),
                );
            }
            todo
        }
    };
    if let Some(limit) = opts.limit.filter(|l| *l > 0) {
        todo.truncate(limit);
    }
    tracing::info!("llm step: {} scene(s)", todo.len());
    let drop = defaults.skip_tags();
    for (i, scene) in todo.iter().enumerate() {
        tracing::info!(
            done = i + 1,
            total = todo.len(),
            "[{}] scene {}/{}",
            scene.id,
            i + 1,
            todo.len()
        );
        let id = scene.id.clone();
        if let Err(e) = pass_scene(c, db, scene, &id, llm_tag.as_deref(), &drop, opts).await {
            if !opts.dry_run && !is_transient(&e) && db.identify_fail(&id)? {
                tracing::warn!(
                    "giving up on [{id}] after {IDENTIFY_FAILURE_LIMIT} failures: {e:#}"
                );
                record_outcome(db, &id, Outcome::GaveUp, None);
                continue;
            }
            tracing::warn!("  [{id}] failed, will retry next pass: {e:#}");
        }
    }
    Ok(())
}

/// Link the scenes a scan just made to their downloads; one Stash already filled (by
/// fingerprint) is done, and recorded as such. Failures are logged: the page's status is
/// all that depends on this.
async fn record_new<B: IdentifyBackends>(
    c: &Clients<'_, B>,
    db: &Db,
    ids: &[String],
) {
    let scenes = match c.stash.scenes(ids).await {
        Ok(s) => s,
        Err(e) => {
            tracing::warn!("reading new scenes failed: {e:#}");
            return;
        }
    };
    for s in &scenes {
        if provenance::link(db, c.paths, s, true).is_none() || !s.is_filled() {
            continue;
        }
        let label = provenance::outcome_label(s.title.as_deref(), s.studio_name());
        record_outcome(db, &s.id, Outcome::Stash, label.as_deref());
    }
}

/// Record what identify made of a scene for the page's status. A failure is logged: the
/// scene itself is already written (or given up on), so it is no identify failure.
fn record_outcome(db: &Db, id: &str, outcome: Outcome, label: Option<&str>) {
    if let Err(e) = db.record_outcome(id, outcome.as_str(), label) {
        tracing::warn!("recording [{id}] failed: {e:#}");
    }
}

/// The outcome and label `pass_scene` records for a proposal.
fn outcome_of(prop: &Proposal) -> (Outcome, Option<String>) {
    match prop {
        Proposal::Scrape(m) => (
            Outcome::Scrape,
            provenance::outcome_label(m.candidate.title.as_deref(), m.candidate.studio_name()),
        ),
        Proposal::Llm(q) => (
            Outcome::Llm,
            provenance::outcome_label(q.display_title().as_deref(), q.studio.as_deref()),
        ),
        Proposal::Nothing => (Outcome::Nothing, None),
    }
}

async fn pass_scene<B: IdentifyBackends>(
    c: &Clients<'_, B>,
    db: &Db,
    scene: &Scene,
    id: &str,
    llm_tag: Option<&str>,
    drop: &HashSet<String>,
    opts: &PassOpts,
) -> anyhow::Result<()> {
    let upgrade = is_upgrade(c.paths, scene, llm_tag);
    let prov = provenance::link(db, c.paths, scene, !opts.dry_run);
    let prop = if upgrade {
        match code_prop(c, scene).await? {
            Some(prop) => prop,
            None => {
                tracing::info!("[{id}] llm guess, no code match yet");
                return Ok(());
            }
        }
    } else {
        identify_scene(c, scene, prov.as_ref()).await?
    };
    println!("{}", format_line(c.paths, scene, &prop));
    if opts.dry_run {
        return Ok(());
    }
    // Re-fetch: the LLM step can take minutes, so re-check against a fresh copy right
    // before writing, in case the scene was edited (or identified) by hand -- or deleted
    // outright -- in the meantime. An explicit --scene run means it should apply
    // regardless of an edit, but a deletion is never applicable. An upgrade counts as
    // untouched for as long as it keeps the llm-identified tag.
    let fresh = c.stash.scenes(&[id.to_string()]).await?;
    let Some(fresh) = fresh.into_iter().next() else {
        tracing::info!("[{id}] gone, skipped");
        db.identify_clear_failures(id)?;
        return Ok(());
    };
    let edited = if upgrade {
        !is_upgrade(c.paths, &fresh, llm_tag)
    } else {
        fresh.is_filled()
    };
    if opts.scene_ids.is_none() && edited {
        tracing::info!("[{id}] edited meanwhile, skipped");
        db.identify_mark_done(id)?;
        db.identify_clear_failures(id)?;
        return Ok(());
    }
    let mut skip = drop.clone();
    if upgrade {
        skip.extend(llm_tag.map(str::to_string));
    }
    apply(
        c,
        &fresh,
        &prop,
        &skip,
        upgrade,
        prov.as_ref().and_then(|p| p.cover.as_deref()),
    )
    .await?;
    let (outcome, label) = outcome_of(&prop);
    record_outcome(db, id, outcome, label.as_deref());
    db.identify_mark_done(id)?;
    db.identify_clear_failures(id)?;
    Ok(())
}

#[cfg(test)]
mod tests;
