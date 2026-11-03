//! Pure matching and payload-building logic for identify. No I/O here.

use std::collections::HashSet;
use std::sync::LazyLock;

use anyhow::{Result, bail};
use regex::Regex;
use serde::Serialize;

use crate::llm::{JevRequest, Parse};
use crate::stash::NamedRecord;
use crate::stash::de::csv;
use crate::stash::{
    Candidate, PerformerCreate, Resolved, Scene, SceneUpdate, ScrapedPerformer, ScrapedStudio,
    StashId, StudioCreate,
};

/// A candidate must be within this many seconds of the file. It is the gate that makes
/// the looser checks (Jev, studio+date) safe: in testing every real match was within ~1 s.
pub const DURATION_TOLERANCE: f64 = 10.0;

const JEV_INSTRUCTIONS: &str = "All candidates already have a duration matching the file. Which one is the exact same \
scene as this file? The title or studio in the file path should correspond to the candidate. \
Performer names in file paths are often aliases, first names only, or folder names, so a \
performer mismatch alone does not rule a candidate out. Pick none if the title and studio \
don't correspond.";

/// A candidate and the stash-box endpoint it came from.
#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub endpoint: String,
    pub scene: Candidate,
}

/// Lowercase alphanumerics only, so "StudioName" == "Studio Name".
pub fn norm(s: Option<&str>) -> String {
    s.unwrap_or("")
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        .collect()
}

fn squash(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// Whether a stash-box candidate is `name`'s scene: its studio, an alias of it, or its
/// parent network, compared without case, spaces or punctuation ("Studio A" = "StudioA").
pub fn studio_matches(c: &Candidate, name: &str) -> bool {
    let want = squash(name);
    let Some(s) = c.studio.as_ref().filter(|_| !want.is_empty()) else {
        return false;
    };
    let parent = s.parent.as_ref().and_then(|p| p.name.clone());
    // A scraped studio's aliases are one comma-separated string.
    s.name
        .iter()
        .cloned()
        .chain(parent)
        .chain(csv(s.aliases.as_deref()))
        .any(|n| squash(&n) == want)
}

pub fn scene_key(c: &Candidate) -> (String, String) {
    (norm(c.title.as_deref()), norm(c.studio_name()))
}

pub fn duration_ok(c: &Candidate, file_duration: f64) -> bool {
    c.known_duration()
        .is_some_and(|d| (d - file_duration).abs() <= DURATION_TOLERANCE)
}

/// cands in endpoint preference order; first per scene wins.
pub fn dedupe(cands: Vec<Hit>) -> Vec<Hit> {
    let mut seen = HashSet::new();
    cands
        .into_iter()
        .filter(|h| seen.insert(scene_key(&h.scene)))
        .collect()
}

/// Studio and date agree with the filename parse. cands must be duration-filtered.
///
/// Release-style names (StudioName.24.12.24.Performer.Alice) carry a date but no title,
/// which Jev reads as a mismatch; this rule catches them. Several hits must all be the
/// same scene, else nothing fires.
pub fn deterministic_match(cands: &[Hit], parse: &Parse) -> Option<Hit> {
    let studio = norm(parse.studio.as_deref());
    let date = parse.date.as_deref()?;
    if studio.is_empty() {
        return None;
    }
    let hits: Vec<&Hit> = cands
        .iter()
        .filter(|h| norm(h.scene.studio_name()) == studio && h.scene.date.as_deref() == Some(date))
        .collect();
    let titles: HashSet<String> = hits
        .iter()
        .map(|h| norm(h.scene.title.as_deref()))
        .collect();
    (titles.len() == 1).then(|| hits[0].clone())
}

/// All candidates, from any endpoint and including chosen, that are the same scene.
pub fn twins(chosen: &Hit, all: &[Hit], file_duration: f64) -> Vec<Hit> {
    let key = scene_key(&chosen.scene);
    all.iter()
        .filter(|h| scene_key(&h.scene) == key && duration_ok(&h.scene, file_duration))
        .cloned()
        .collect()
}

// A product code leading a filename: 2-6 letters, a hyphen, 3-5 digits, then nothing
// or a separator and anything (WXYZ-796.H265, IJKL-601-C). The hyphen is required so
// abcd958_sd, wxyz0720 and tokens inside Western names don't match; a false positive
// only costs a lookup before the LLM flow takes over.
static PRODUCT_CODE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(?:([A-Za-z]{2,6})-(\d{3,5})(?:[-_. ].*)?)$").unwrap());
// FC2 Content Market (sold per article): FC2-PPV-1000001, FC2PPV 200004 and
// FC2-1000005 all name article 1000001 etc. Normalised to FC2-PPV-<n>.
static FC2_CODE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?i)^(?:FC2[-_ ]?(?:PPV[-_ ]?)?(\d{5,8})(?:[-_. ].*)?)$").unwrap()
});
static CODE_KEY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*([A-Za-z]{2,6})[-_ ]?([0-9]{2,6})\s*$").unwrap());

/// The file name without its directory or last extension (a leading dot is not one).
fn stem(path: &str) -> &str {
    let base = path.rsplit('/').next().unwrap_or(path);
    let lead = base.len() - base.trim_start_matches('.').len();
    match base[lead..].rfind('.') {
        Some(i) => &base[..lead + i],
        None => base,
    }
}

pub fn product_code(path: &str) -> Option<String> {
    // Download sites prefix their name: dl.example@FC2-PPV-1000003.mp4.
    let stem = stem(path);
    let stem = stem.rsplit('@').next().unwrap_or(stem);
    if let Some(m) = FC2_CODE.captures(stem) {
        return Some(format!("FC2-PPV-{}", &m[1]));
    }
    PRODUCT_CODE
        .captures(stem)
        .map(|m| format!("{}-{}", m[1].to_uppercase(), &m[2]))
}

/// The FC2 article number in a product_code() result, or None for any other code.
pub fn fc2_number(code: &str) -> Option<String> {
    code.strip_prefix("FC2-PPV-").map(str::to_string)
}

/// ("PQRS", 402) for pqrs00402, PQRS-402 and pqrs-402 alike; None for non-codes.
pub fn code_key(s: Option<&str>) -> Option<(String, u64)> {
    let m = CODE_KEY.captures(s.unwrap_or(""))?;
    Some((m[1].to_uppercase(), m[2].parse().ok()?))
}

/// cands already share the file's code. The one scene they all are, or None when
/// there are none or they disagree on the title.
pub fn single_scene(cands: Vec<Candidate>) -> Option<Candidate> {
    let titles: HashSet<String> = cands.iter().map(|c| norm(c.title.as_deref())).collect();
    (titles.len() == 1)
        .then(|| cands.into_iter().next())
        .flatten()
}

const FC2_STUDIO: &str = "FC2-PPV";

/// Stash's fc2 scraper result -> the ScrapedScene shape apply() consumes, with title
/// the English translation. The Japanese original goes to details, as FC2 gives none.
/// The scraper's lone "performer" is the seller, so it becomes a studio under FC2-PPV;
/// FC2 names no actual performers.
pub fn fc2_scene(hit: &Candidate, title: &str) -> Candidate {
    let studio = match hit.performers.iter().find_map(|p| p.name.clone()) {
        Some(seller) => ScrapedStudio {
            name: Some(seller),
            parent: Some(Box::new(ScrapedStudio {
                name: Some(FC2_STUDIO.into()),
                ..Default::default()
            })),
            ..Default::default()
        },
        None => ScrapedStudio {
            name: Some(FC2_STUDIO.into()),
            ..Default::default()
        },
    };
    let details: Vec<&str> = [&hit.title, &hit.details]
        .into_iter()
        .flatten()
        .map(String::as_str)
        .collect();
    Candidate {
        title: Some(title.to_string()),
        details: (!details.is_empty()).then(|| details.join("\n\n")),
        studio: Some(studio),
        performers: vec![],
        ..hit.clone()
    }
}

/// How the Jev call sees a candidate: its identifying fields, as JSON.
pub fn summary(c: &Candidate) -> String {
    #[derive(Serialize)]
    struct Summary<'a> {
        title: Option<&'a str>,
        studio: Option<&'a str>,
        performers: Vec<&'a str>,
        date: Option<&'a str>,
        code: Option<&'a str>,
        duration_seconds: Option<i64>,
    }
    serde_json::to_string(&Summary {
        title: c.title.as_deref(),
        studio: c.studio_name(),
        performers: c
            .performers
            .iter()
            .filter_map(|p| p.name.as_deref())
            .collect(),
        date: c.date.as_deref(),
        code: c.code.as_deref(),
        duration_seconds: c.known_duration().map(|d| d.round() as i64),
    })
    .expect("summary serializes")
}

pub fn stash_ids_for(endpoint: &str, remote_id: Option<&str>) -> Vec<StashId> {
    remote_id
        .filter(|id| !id.is_empty())
        .map(|id| StashId {
            endpoint: endpoint.to_string(),
            stash_id: id.to_string(),
        })
        .into_iter()
        .collect()
}

/// `int(float(s))`: the whole part of a numeric text, or None.
fn whole(s: Option<&str>) -> Option<i64> {
    let f: f64 = s?.trim().parse().ok()?;
    f.is_finite().then(|| f.trunc() as i64)
}

/// ScrapedPerformer -> PerformerCreateInput, keeping every field stash-box returned.
pub fn performer_create_input(p: &ScrapedPerformer, endpoint: &str) -> PerformerCreate {
    PerformerCreate {
        name: p.name.clone().unwrap_or_default(),
        disambiguation: p.disambiguation.clone(),
        gender: p.gender.as_deref().and_then(|g| g.parse().ok()),
        urls: p.urls.clone(),
        birthdate: p.birthdate.clone(),
        death_date: p.death_date.clone(),
        ethnicity: p.ethnicity.clone(),
        country: p.country.clone(),
        eye_color: p.eye_color.clone(),
        hair_color: p.hair_color.clone(),
        height_cm: whole(p.height.as_deref()),
        weight: whole(p.weight.as_deref()),
        measurements: p.measurements.clone(),
        career_start: p.career_start.clone(),
        career_end: p.career_end.clone(),
        tattoos: p.tattoos.clone(),
        piercings: p.piercings.clone(),
        alias_list: csv(p.aliases.as_deref()),
        details: p.details.clone(),
        image: p.images.first().cloned(),
        stash_ids: stash_ids_for(endpoint, p.remote_site_id.as_deref()),
    }
}

/// ScrapedStudio -> StudioCreateInput.
pub fn studio_create_input(
    s: &ScrapedStudio,
    endpoint: &str,
    parent_id: Option<&str>,
) -> StudioCreate {
    StudioCreate {
        name: s.name.clone().unwrap_or_default(),
        urls: s.urls.clone(),
        image: s.image.clone(),
        details: s.details.clone(),
        aliases: csv(s.aliases.as_deref()),
        parent_id: parent_id.map(str::to_string),
        stash_ids: stash_ids_for(endpoint, s.remote_site_id.as_deref()),
    }
}

/// Single-word aliases are too ambiguous: a performer can carry dozens, "Vivian" among them.
pub fn alias_ok(name: &str) -> bool {
    name.split_whitespace().count() >= 2
}

/// records come from a q= search. Exact normalized name first; alias only if allowed.
pub fn pick_by_name(records: &[NamedRecord], name: &str, allow_alias: bool) -> Option<String> {
    let n = norm(Some(name));
    records
        .iter()
        .find(|r| norm(r.name.as_deref()) == n)
        .or_else(|| {
            allow_alias
                .then(|| {
                    records
                        .iter()
                        .find(|r| r.aliases.iter().any(|a| norm(Some(a)) == n))
                })
                .flatten()
        })
        .map(|r| r.id.clone())
}

fn merge(existing: impl IntoIterator<Item = String>, new: &[String]) -> Vec<String> {
    let mut out: Vec<String> = existing.into_iter().collect();
    for i in new {
        if !out.contains(i) {
            out.push(i.clone());
        }
    }
    out
}

fn ids(refs: &[crate::stash::Ref]) -> impl Iterator<Item = String> + '_ {
    refs.iter().map(|r| r.id.clone())
}

/// Take `new` when `scene` lacks the field (or always, when overwriting).
fn fill(new: &Option<String>, have: &Option<String>, overwrite: bool) -> Option<String> {
    new.clone().filter(|_| overwrite || have.is_none())
}

/// SceneUpdateInput for a confirmed stash-box match. Fills empty fields only,
/// except the cover, which replaces the generated screenshot. overwrite (upgrading an
/// llm-identified guess) replaces the guessed fields and performers outright.
pub fn scrape_update(
    scene: &Scene,
    primary: &Candidate,
    resolved: &Resolved,
    drop_tag_ids: &HashSet<String>,
    overwrite: bool,
) -> SceneUpdate {
    let mut stash_ids = scene.stash_ids.clone();
    for s in &resolved.stash_ids {
        if !stash_ids.contains(s) {
            stash_ids.push(s.clone());
        }
    }
    SceneUpdate {
        title: fill(&primary.title, &scene.title, overwrite),
        code: fill(&primary.code, &scene.code, overwrite),
        details: fill(&primary.details, &scene.details, overwrite),
        director: fill(&primary.director, &scene.director, overwrite),
        date: fill(&primary.date, &scene.date, overwrite),
        urls: (!primary.urls.is_empty() && (overwrite || scene.urls.is_empty()))
            .then(|| primary.urls.clone()),
        cover_image: primary.image.clone(),
        studio_id: resolved
            .studio_id
            .clone()
            .filter(|_| overwrite || scene.studio.is_none()),
        performer_ids: Some(if overwrite {
            resolved.performer_ids.clone()
        } else {
            merge(ids(&scene.performers), &resolved.performer_ids)
        }),
        tag_ids: Some(
            merge(ids(&scene.tags), &resolved.tag_ids)
                .into_iter()
                .filter(|t| !drop_tag_ids.contains(t))
                .collect(),
        ),
        stash_ids: Some(stash_ids),
        ..SceneUpdate::new(&scene.id)
    }
}

/// SceneUpdateInput for an unconfirmed filename guess, tagged for later review.
pub fn llm_update(
    scene: &Scene,
    parse: &Parse,
    studio_id: Option<&str>,
    performer_ids: &[String],
    llm_tag_id: &str,
) -> SceneUpdate {
    SceneUpdate {
        title: parse.display_title().filter(|_| scene.title.is_none()),
        date: fill(&parse.date, &scene.date, false),
        studio_id: studio_id
            .filter(|s| !s.is_empty() && scene.studio.is_none())
            .map(str::to_string),
        performer_ids: Some(merge(ids(&scene.performers), performer_ids)),
        tag_ids: Some(merge(ids(&scene.tags), &[llm_tag_id.to_string()])),
        ..SceneUpdate::new(&scene.id)
    }
}

/// The Jev choice over duration-filtered candidates.
pub fn jev_request(path: &str, duration: f64, parse: &Parse, cands: &[Hit]) -> JevRequest {
    let mut criteria: Vec<(String, String)> = cands
        .iter()
        .enumerate()
        .map(|(i, h)| (format!("c{i}"), summary(&h.scene)))
        .collect();
    criteria.push((
        "none".into(),
        "None of the candidates is this exact scene.".into(),
    ));
    JevRequest {
        file_path: path.to_string(),
        file_duration_seconds: duration.round_ties_even() as i64,
        filename_parse: parse.clone(),
        instructions: JEV_INSTRUCTIONS,
        criteria,
    }
}

pub fn jev_pick(choice: Option<&str>, cands: &[Hit]) -> Result<Option<Hit>> {
    let choice = choice.unwrap_or("");
    if choice == "none" {
        return Ok(None);
    }
    match choice
        .strip_prefix('c')
        .and_then(|n| n.parse::<usize>().ok())
        .and_then(|i| cands.get(i))
    {
        Some(h) => Ok(Some(h.clone())),
        None => bail!("jev choice {choice:?} is neither \"none\" nor a candidate"),
    }
}

#[cfg(test)]
#[path = "matching_tests.rs"]
mod tests;
