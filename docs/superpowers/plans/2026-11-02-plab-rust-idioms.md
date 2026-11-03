# plab Rust Idioms Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace plab's Python-shaped code (untyped `serde_json::Value` records, Python truthiness helpers, `py.rs` byte-parity shims, Python `repr` in logs and prompts) with typed serde structs and plain Rust formatting, without changing what plab writes to Stash.

**Architecture:** Edge-inward, one layer per commit. Typed records first (Stash reads), then the pure matching layer and Stash writes, then the identify pass and the LLM client, then the smaller `Value` users, then `py.rs` is deleted. Test fixtures stay as `json!` literals and are deserialized into the new types; the fake Stash re-serializes what it is asked to write, so the existing assertions on Stash writes stay byte-for-byte the same and keep proving behaviour.

**Tech Stack:** Rust 2024, serde / serde_json (`preserve_order`), rusqlite, tokio, wiremock, html-escape. Crate root: `packages/plab/`.

**Spec:** `docs/superpowers/specs/2026-11-02-plab-rust-idioms-design.md`

## Global Constraints

- Work in `packages/plab/`. Every command below runs from there unless it says otherwise.
- Commit straight to `master`; no branches, no worktrees.
- Commit messages: `refactor(galactica): plab <subject>`; never mention Claude.
- After every task: `cargo test` passes, `cargo clippy --all-targets -- -D warnings` is clean, `cargo fmt --check` is clean.
- What plab writes to Stash (scene updates, performer/studio creates, job inputs) must not change. The assertions in `src/identify/tests.rs` and `src/identify/matching_tests.rs` on written payloads are the proof; change how a fixture is *built*, never what a write assertion *expects*, except where a task names the change.
- The database's stored outcome strings stay `scrape`, `llm`, `none`, `stash`, `gave-up`.
- LLM instruction text (`PARSE_PROMPT`, `TITLE_NOTE`, `TRANSLATE_PROMPT`, `INSTRUCTIONS`, `CRITERIA`, the Jev instructions) stays word for word.
- Out of scope: `page.rs`'s string-built HTML and its `too_many_arguments`, `grab.rs`'s `grab()` `too_many_arguments`, the db, tracker and provenance logic.
- A new file is invisible to `nix build` until `git add`ed; `cargo` does not care, but commit new files in the task that adds them.

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `src/stash.rs` → `src/stash/mod.rs` | move + modify | GraphQL client, `StashApi` trait |
| `src/stash/types.rs` | create | Records read from and written to Stash |
| `src/stash/de.rs` | create | Lenient serde deserializers (ids, non-empty strings, numbers-or-strings) |
| `src/identify/matching.rs` | modify | Pure matching over typed records; builds `SceneUpdate`, `PerformerCreate`, `StudioCreate`, `JevRequest` |
| `src/identify/mod.rs` | modify | `Proposal` enum, `Outcome` enum, typed pass |
| `src/llm.rs` | modify | `Parse`, `JevRequest`, `JevAnswer`; typed `Llm` trait |
| `src/codedb.rs` | modify | `CodeHit` typed code-database record |
| `src/provenance.rs` | modify | `link` takes `&Scene` |
| `src/prowlarr.rs`, `src/grab.rs` | modify | `ProwlarrResult` |
| `src/web.rs` | modify | Serialize reply structs; Rust log formatting |
| `src/plab.rs` | modify | Rust log formatting |
| `src/page.rs` | modify | `html_escape` + `serde_json` in place of `py::` |
| `src/py.rs` | delete | |
| `src/main.rs` | modify | drop `mod py;` |
| tests beside each file | modify | typed fixtures |

---

### Task 0: Preconditions

**Files:** none.

- [ ] **Step 1: Confirm the tree is clean for plab**

Run: `git status --short packages/plab` from the repo root.
Expected: no output. If page work (`assets/page.js`, `src/page.rs`, `src/page_tests.rs`, `tests/fixtures/golden_page*.html`) is still uncommitted, stop and ask the user to land it first. Task 5 regenerates those golden files.

- [ ] **Step 2: Baseline**

Run: `cargo test 2>&1 | grep -E "^test result|FAILED|panicked"` and `cargo clippy --all-targets -- -D warnings`.
Expected: every `test result: ok`; clippy clean. Record the total test count (sum of `passed`), so later tasks can confirm no test was lost.

---

### Task 1: Typed Stash records and a typed GraphQL client (read side)

Introduces `stash::types` and `stash::de`, makes every `StashApi` *read* method return typed records, and gives `matching` a temporary `Value` shim, deleted in Task 2. Write methods (`create_*`, `update_scene`) keep `&Value` until Task 2.

**Files:**
- Move: `src/stash.rs` → `src/stash/mod.rs` (`git mv`)
- Create: `src/stash/types.rs`, `src/stash/de.rs`
- Modify: `src/stash/mod.rs`, `src/identify/mod.rs`, `src/provenance.rs`, `src/identify/tests.rs`

**Interfaces:**
- Produces (used by every later task):
  - `stash::de::{id, opt_id, nonempty, lenient_f64, null_default, csv}`
  - `stash::types::{Scene, StudioRef, Ref, VideoFile, StashId, Candidate, ScrapedStudio, ScrapedPerformer, ScrapedTag, NamedRecord, JobOptions, Defaults, FingerprintMatch}`
  - `Scene::first_file(&self) -> anyhow::Result<(&str, f64)>`, `Scene::first_path(&self) -> Option<&str>`, `Scene::is_filled(&self) -> bool`, `Scene::has_tag(&self, id: &str) -> bool`
  - `Candidate::known_duration(&self) -> Option<f64>`, `Candidate::studio_name(&self) -> Option<&str>`
  - `Defaults::skip_tags(&self) -> HashSet<String>`, `Defaults::identify_boxes(&self) -> Vec<String>`
  - `JobOptions::with<'a>(&self, extra: impl IntoIterator<Item = (&'a str, Value)>) -> Value`
  - `StashApi` read methods with the signatures in Step 6.

- [ ] **Step 1: Move the module**

```bash
mkdir -p src/stash && git mv src/stash.rs src/stash/mod.rs
cargo build
```
Expected: builds (Rust resolves `mod stash;` to `stash/mod.rs`).

- [ ] **Step 2: Write `src/stash/de.rs` with failing tests**

```rust
//! Lenient deserializers for the shapes Stash, stash-boxes, the code database and the LLM send.
//! Each one maps "absent" spellings (missing, `null`, `""`) to `None` once, here, so the
//! code reading a record never has to re-check them.

use serde::{Deserialize, Deserializer};

/// A JSON scalar as it may arrive where a string is meant.
#[derive(Deserialize)]
#[serde(untagged)]
enum Scalar {
    S(String),
    I(i64),
    U(u64),
    F(f64),
    B(bool),
}

impl Scalar {
    fn into_string(self) -> Option<String> {
        match self {
            Scalar::S(s) if s.is_empty() => None,
            Scalar::S(s) => Some(s),
            Scalar::I(i) => Some(i.to_string()),
            Scalar::U(u) => Some(u.to_string()),
            Scalar::F(f) => Some(f.to_string()),
            // A boolean where a string belongs carries no usable value.
            Scalar::B(_) => None,
        }
    }
}

/// An id, sent as a string or a number.
pub fn id<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    Scalar::deserialize(d)?
        .into_string()
        .ok_or_else(|| serde::de::Error::custom("empty id"))
}

/// An optional id: missing, `null` or `""` is `None`.
pub fn opt_id<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    nonempty(d)
}

/// A string field: missing, `null` or `""` is `None`; a number becomes its decimal text.
pub fn nonempty<'de, D: Deserializer<'de>>(d: D) -> Result<Option<String>, D::Error> {
    Ok(Option::<Scalar>::deserialize(d)?.and_then(Scalar::into_string))
}

/// A number sent as a number or a numeric string; anything else is `None`.
pub fn lenient_f64<'de, D: Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
    Ok(match Option::<Scalar>::deserialize(d)? {
        Some(Scalar::I(i)) => Some(i as f64),
        Some(Scalar::U(u)) => Some(u as f64),
        Some(Scalar::F(f)) => Some(f),
        Some(Scalar::S(s)) => s.trim().parse().ok().filter(|f: &f64| f.is_finite()),
        Some(Scalar::B(_)) | None => None,
    })
}

/// A list or object field where `null` means empty.
pub fn null_default<'de, D, T>(d: D) -> Result<T, D::Error>
where
    D: Deserializer<'de>,
    T: Deserialize<'de> + Default,
{
    Ok(Option::<T>::deserialize(d)?.unwrap_or_default())
}

/// A list of strings, dropping `null`s, empties and non-strings (an LLM's `performers`).
pub fn names<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<String>, D::Error> {
    let raw: Option<Vec<serde_json::Value>> = Option::deserialize(d)?;
    Ok(raw
        .unwrap_or_default()
        .into_iter()
        .filter_map(|v| match v {
            serde_json::Value::String(s) if !s.is_empty() => Some(s),
            _ => None,
        })
        .collect())
}

/// Split a comma-separated alias string (a scraped performer's or studio's `aliases`).
pub fn csv(s: Option<&str>) -> Vec<String> {
    s.unwrap_or("")
        .split(',')
        .map(str::trim)
        .filter(|a| !a.is_empty())
        .map(str::to_string)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[derive(Deserialize, Debug, PartialEq)]
    struct R {
        #[serde(deserialize_with = "id")]
        id: String,
        #[serde(default, deserialize_with = "nonempty")]
        s: Option<String>,
        #[serde(default, deserialize_with = "lenient_f64")]
        f: Option<f64>,
        #[serde(default, deserialize_with = "null_default")]
        v: Vec<String>,
        #[serde(default, deserialize_with = "names")]
        n: Vec<String>,
    }

    fn r(v: serde_json::Value) -> R {
        serde_json::from_value(v).unwrap()
    }

    #[test]
    fn ids_arrive_as_strings_or_numbers() {
        assert_eq!(r(json!({"id": "7"})).id, "7");
        assert_eq!(r(json!({"id": 7})).id, "7");
        assert!(serde_json::from_value::<R>(json!({"id": ""})).is_err());
    }

    #[test]
    fn absent_strings_are_none() {
        assert_eq!(r(json!({"id": 1})).s, None);
        assert_eq!(r(json!({"id": 1, "s": null})).s, None);
        assert_eq!(r(json!({"id": 1, "s": ""})).s, None);
        assert_eq!(r(json!({"id": 1, "s": "x"})).s.as_deref(), Some("x"));
        assert_eq!(r(json!({"id": 1, "s": 170})).s.as_deref(), Some("170"));
        assert_eq!(r(json!({"id": 1, "s": true})).s, None);
    }

    #[test]
    fn numbers_may_be_numeric_strings() {
        assert_eq!(r(json!({"id": 1, "f": 358})).f, Some(358.0));
        assert_eq!(r(json!({"id": 1, "f": 358.5})).f, Some(358.5));
        assert_eq!(r(json!({"id": 1, "f": " 358 "})).f, Some(358.0));
        assert_eq!(r(json!({"id": 1, "f": "abc"})).f, None);
        assert_eq!(r(json!({"id": 1, "f": ""})).f, None);
        assert_eq!(r(json!({"id": 1, "f": null})).f, None);
    }

    #[test]
    fn null_lists_are_empty() {
        assert!(r(json!({"id": 1, "v": null})).v.is_empty());
        assert_eq!(r(json!({"id": 1, "v": ["a"]})).v, ["a"]);
    }

    #[test]
    fn names_keep_nonempty_strings_only() {
        assert_eq!(r(json!({"id": 1, "n": ["A", "", null, 3, "B"]})).n, ["A", "B"]);
        assert!(r(json!({"id": 1, "n": null})).n.is_empty());
    }

    #[test]
    fn csv_splits_and_trims() {
        assert_eq!(csv(Some(" a, b ,,c ")), ["a", "b", "c"]);
        assert!(csv(None).is_empty());
    }
}
```

Add `pub mod de;` at the top of `src/stash/mod.rs`.

- [ ] **Step 3: Run the new tests**

Run: `cargo test stash::de`
Expected: 6 tests pass. (They are self-contained; there is no separate red step, because the module is new and its tests define it.)

- [ ] **Step 4: Write `src/stash/types.rs`**

```rust
//! The records plab reads from and writes to Stash and the stash-boxes behind it.
//! Field names are the GraphQL ones. Absent values are normalized by `super::de` on the way
//! in, so `Option<String>` here always means "present and non-empty".

use std::collections::HashSet;

use anyhow::Context;
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};

use super::de;

/// A link to another record by id (a scene's performers and tags).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Ref {
    #[serde(deserialize_with = "de::id")]
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct StudioRef {
    #[serde(deserialize_with = "de::id")]
    pub id: String,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Deserialize, Serialize)]
pub struct StashId {
    pub endpoint: String,
    pub stash_id: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct VideoFile {
    pub path: String,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub duration: Option<f64>,
}

/// A library scene (`SCENE_FIELDS`).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct Scene {
    #[serde(deserialize_with = "de::id")]
    pub id: String,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub code: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub details: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub director: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub date: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub urls: Vec<String>,
    #[serde(default)]
    pub studio: Option<StudioRef>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub performers: Vec<Ref>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub tags: Vec<Ref>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub stash_ids: Vec<StashId>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub files: Vec<VideoFile>,
}

impl Scene {
    pub fn first_path(&self) -> Option<&str> {
        self.files.first().map(|f| f.path.as_str())
    }

    /// The first file's path and duration; an error when the scene has none.
    pub fn first_file(&self) -> anyhow::Result<(&str, f64)> {
        let f = self
            .files
            .first()
            .with_context(|| format!("scene {} has no file", self.id))?;
        let duration = f.duration.context("file has no duration")?;
        Ok((&f.path, duration))
    }

    /// Has a title, studio or performers: what `bare_scenes` leaves out.
    pub fn is_filled(&self) -> bool {
        self.title.is_some() || self.studio.is_some() || !self.performers.is_empty()
    }

    pub fn has_tag(&self, id: &str) -> bool {
        self.tags.iter().any(|t| t.id == id)
    }

    pub fn studio_name(&self) -> Option<&str> {
        self.studio.as_ref()?.name.as_deref()
    }
}

/// A scraped studio (`SCRAPED_FIELDS`' `studio { ... }`).
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct ScrapedStudio {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub urls: Vec<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub image: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub details: Option<String>,
    /// One comma-separated string, as stash-box sends it; see `de::csv`.
    #[serde(default, deserialize_with = "de::nonempty")]
    pub aliases: Option<String>,
    #[serde(default, deserialize_with = "de::opt_id")]
    pub remote_site_id: Option<String>,
    #[serde(default)]
    pub parent: Option<Box<ScrapedStudio>>,
}

/// A scraped performer. Every attribute is text on the wire, numbers included.
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct ScrapedPerformer {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub disambiguation: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub gender: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub urls: Vec<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub birthdate: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub death_date: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub ethnicity: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub country: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub eye_color: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub hair_color: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub height: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub weight: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub measurements: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub career_start: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub career_end: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub tattoos: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub piercings: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub aliases: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub details: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub images: Vec<String>,
    #[serde(default, deserialize_with = "de::opt_id")]
    pub remote_site_id: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct ScrapedTag {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "de::opt_id")]
    pub stored_id: Option<String>,
}

/// A scraped scene: a stash-box search hit, a URL scrape, or a code-database / FC2 record
/// put in the same shape.
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct Candidate {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub code: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub details: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub director: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub date: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub image: Option<String>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub urls: Vec<String>,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub duration: Option<f64>,
    #[serde(default, deserialize_with = "de::opt_id")]
    pub remote_site_id: Option<String>,
    #[serde(default)]
    pub studio: Option<ScrapedStudio>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub performers: Vec<ScrapedPerformer>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub tags: Vec<ScrapedTag>,
}

impl Candidate {
    /// The duration, when known. Stash-boxes send 0 for "unknown".
    pub fn known_duration(&self) -> Option<f64> {
        self.duration.filter(|d| *d != 0.0)
    }

    pub fn studio_name(&self) -> Option<&str> {
        self.studio.as_ref()?.name.as_deref()
    }
}

/// A performer or studio found by name (`performers_like`, `studios_like`). Performers
/// carry `alias_list`, studios `aliases`; both are lists here.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct NamedRecord {
    #[serde(deserialize_with = "de::id")]
    pub id: String,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, alias = "alias_list", deserialize_with = "de::null_default")]
    pub aliases: Vec<String>,
}

/// One scene's fingerprint match (`scrapeMultiScenes { title duration }`).
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
pub struct FingerprintMatch {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub duration: Option<f64>,
}

/// One of Stash's saved task-option blobs (scan, generate, identify). plab never reads
/// inside one beyond `Defaults`' two accessors: it adds a few keys and sends it back to the
/// same server, so it stays JSON. Nulls are dropped on the way in, since the blob is
/// replayed as a job input.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct JobOptions(pub Map<String, Value>);

impl<'de> Deserialize<'de> for JobOptions {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(match strip_nulls(Option::<Value>::deserialize(d)?.unwrap_or(Value::Null)) {
            Value::Object(m) => JobOptions(m),
            _ => JobOptions::default(),
        })
    }
}

fn strip_nulls(v: Value) -> Value {
    match v {
        Value::Object(o) => Value::Object(
            o.into_iter()
                .filter(|(_, x)| !x.is_null())
                .map(|(k, x)| (k, strip_nulls(x)))
                .collect(),
        ),
        Value::Array(a) => Value::Array(a.into_iter().map(strip_nulls).collect()),
        other => other,
    }
}

impl JobOptions {
    /// This blob with `extra` keys set, as a job input.
    pub fn with<'a>(&self, extra: impl IntoIterator<Item = (&'a str, Value)>) -> Value {
        let mut m = self.0.clone();
        for (k, v) in extra {
            m.insert(k.to_string(), v);
        }
        Value::Object(m)
    }
}

/// `configuration.defaults`.
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
#[serde(default)]
pub struct Defaults {
    pub scan: JobOptions,
    pub generate: JobOptions,
    pub identify: JobOptions,
}

impl Defaults {
    /// The tags Stash's identify adds to scenes it skipped, which a fill must not copy.
    pub fn skip_tags(&self) -> HashSet<String> {
        let opts = self.identify.0.get("options");
        ["skipMultipleMatchTag", "skipSingleNamePerformerTag"]
            .into_iter()
            .filter_map(|k| opts?.get(k)?.as_str())
            .filter(|t| !t.is_empty())
            .map(str::to_string)
            .collect()
    }

    /// The stash-box endpoints Stash's identify consults, in its order.
    pub fn identify_boxes(&self) -> Vec<String> {
        self.identify
            .0
            .get("sources")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|s| s.pointer("/source/stash_box_endpoint")?.as_str())
            .map(str::to_string)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn scene_reads_stash_shape() {
        let s: Scene = serde_json::from_value(json!({
            "id": "5", "title": "", "studio": null, "performers": [{"id": "1"}],
            "tags": [{"id": 9}], "stash_ids": null,
            "files": [{"path": "/media/Vault/a.mp4", "duration": 348.2}],
        }))
        .unwrap();
        assert_eq!(s.title, None);
        assert!(s.is_filled());
        assert!(s.has_tag("9"));
        assert_eq!(s.first_file().unwrap(), ("/media/Vault/a.mp4", 348.2));
    }

    #[test]
    fn scene_without_files_has_no_first_file() {
        let s: Scene = serde_json::from_value(json!({"id": "5"})).unwrap();
        assert!(!s.is_filled());
        assert!(s.first_file().unwrap_err().to_string().contains("scene 5 has no file"));
    }

    #[test]
    fn candidate_zero_duration_is_unknown() {
        let c: Candidate = serde_json::from_value(json!({"duration": 0})).unwrap();
        assert_eq!(c.known_duration(), None);
        let c: Candidate = serde_json::from_value(json!({"duration": "1249"})).unwrap();
        assert_eq!(c.known_duration(), Some(1249.0));
    }

    #[test]
    fn named_record_reads_either_alias_field() {
        let p: NamedRecord =
            serde_json::from_value(json!({"id": "1", "name": "A", "alias_list": ["B"]})).unwrap();
        let s: NamedRecord =
            serde_json::from_value(json!({"id": "2", "name": "S", "aliases": ["T"]})).unwrap();
        assert_eq!((p.aliases, s.aliases), (vec!["B".to_string()], vec!["T".to_string()]));
    }

    #[test]
    fn defaults_strip_nulls_and_expose_identify_settings() {
        let d: Defaults = serde_json::from_value(json!({
            "scan": {"rescan": null, "scanGenerateCovers": true},
            "identify": {
                "sources": [{"source": {"stash_box_endpoint": "https://stashdb.org/graphql"}},
                            {"source": {"scraper_id": "x"}}],
                "options": {"skipMultipleMatchTag": "7", "skipSingleNamePerformerTag": ""},
            },
        }))
        .unwrap();
        assert_eq!(d.scan.0, json!({"scanGenerateCovers": true}).as_object().unwrap().clone());
        assert_eq!(d.identify_boxes(), ["https://stashdb.org/graphql"]);
        assert_eq!(d.skip_tags(), HashSet::from(["7".to_string()]));
        assert_eq!(
            d.scan.with([("paths", json!(["/a"]))]),
            json!({"scanGenerateCovers": true, "paths": ["/a"]})
        );
    }
}
```

Add `pub mod types;` and `pub use types::*;` to `src/stash/mod.rs`.

- [ ] **Step 5: Run the type tests**

Run: `cargo test stash::types`
Expected: 5 tests pass.

- [ ] **Step 6: Make the client typed**

In `src/stash/mod.rs`:

1. Replace `gql` and `at` with a typed query helper. `gql` keeps returning the raw `data` `Value`; `query` walks a path and deserializes, naming the path on failure:

```rust
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
        if let Some(errors) = d.get("errors").and_then(Value::as_array).filter(|e| !e.is_empty()) {
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
```

Update the `GqlError` doc comment to: `/// A GraphQL \`errors\` reply: its messages, joined with "; ".` and the test in this file asserting `"[{'message': 'nil pointer dereference'}]"` (around line 718) to expect `"nil pointer dereference"`.

2. Delete `strip_nulls`, `at`, `list`, `with`, `has`, and the `use crate::identify::matching::{...}` import.

3. Change the `StashApi` read methods to these signatures (writes unchanged in this task):

```rust
    fn defaults(&self) -> impl Future<Output = anyhow::Result<Defaults>> + Send;
    fn scan(&self, paths: Option<Vec<String>>, options: &JobOptions) -> impl Future<Output = anyhow::Result<()>> + Send;
    fn generate(&self, scene_ids: Option<Vec<String>>, options: &JobOptions) -> impl Future<Output = anyhow::Result<()>> + Send;
    fn identify(&self, scene_ids: Vec<String>, options: &JobOptions) -> impl Future<Output = anyhow::Result<()>> + Send;
    fn scenes(&self, ids: &[String]) -> impl Future<Output = anyhow::Result<Vec<Scene>>> + Send;
    fn bare_scenes(&self) -> impl Future<Output = anyhow::Result<Vec<Scene>>> + Send;
    fn scenes_with_tag(&self, tag_id: &str) -> impl Future<Output = anyhow::Result<Vec<Scene>>> + Send;
    fn search(&self, endpoint: &str, query: &str) -> impl Future<Output = anyhow::Result<Vec<Candidate>>> + Send;
    fn fingerprint_matches(&self, endpoint: &str, scene_ids: &[String]) -> impl Future<Output = anyhow::Result<Vec<Vec<FingerprintMatch>>>> + Send;
    fn scrape_url(&self, url: &str) -> impl Future<Output = anyhow::Result<Option<Candidate>>> + Send;
    fn performers_like(&self, name: &str) -> impl Future<Output = anyhow::Result<Vec<NamedRecord>>> + Send;
    fn studios_like(&self, name: &str) -> impl Future<Output = anyhow::Result<Vec<NamedRecord>>> + Send;
```

4. Rewrite each implementation with `query`. The pattern, shown for every shape that occurs:

```rust
    async fn defaults(&self) -> anyhow::Result<Defaults> {
        self.query(DEFAULTS_QUERY, json!({}), &["configuration", "defaults"]).await
    }

    async fn video_extensions(&self) -> anyhow::Result<Vec<String>> {
        let q = "{ configuration { general { videoExtensions } } }";
        self.query(q, json!({}), &["configuration", "general", "videoExtensions"]).await
    }

    async fn codedb_api_key(&self) -> anyhow::Result<Option<String>> {
        #[derive(serde::Deserialize)]
        struct StashBox {
            #[serde(default)]
            endpoint: String,
            #[serde(default, deserialize_with = "de::nonempty")]
            api_key: Option<String>,
        }
        let q = "{ configuration { general { stashBoxes { endpoint api_key } } } }";
        let boxes: Vec<StashBox> =
            self.query(q, json!({}), &["configuration", "general", "stashBoxes"]).await?;
        Ok(boxes
            .into_iter()
            .find(|b| b.endpoint.contains("codedb") && b.api_key.is_some())
            .and_then(|b| b.api_key))
    }

    async fn scan(&self, paths: Option<Vec<String>>, options: &JobOptions) -> anyhow::Result<()> {
        let extra = paths.filter(|p| !p.is_empty()).map(|p| ("paths", json!(p)));
        self.run_job("metadataScan", options.with(extra)).await
    }

    async fn generate(&self, scene_ids: Option<Vec<String>>, options: &JobOptions) -> anyhow::Result<()> {
        let ids = scene_ids.map(|ids| ("sceneIDs", json!(ids)));
        self.run_job("metadataGenerate", options.with([("overwrite", json!(false))].into_iter().chain(ids)))
            .await
    }

    async fn identify(&self, scene_ids: Vec<String>, options: &JobOptions) -> anyhow::Result<()> {
        self.run_job("metadataIdentify", options.with([("sceneIDs", json!(scene_ids))])).await
    }

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

    async fn scrape_url(&self, url: &str) -> anyhow::Result<Option<Candidate>> {
        let q = format!("query($u: String!) {{ scrapeSceneURL(url: $u) {{ {SCRAPED_FIELDS} }} }}");
        self.query(&q, json!({"u": url}), &["scrapeSceneURL"]).await
    }

    async fn performers_like(&self, name: &str) -> anyhow::Result<Vec<NamedRecord>> {
        // (keep the existing comment)
        let path = ["findPerformers", "performers"];
        let exact = self.query(/* exact query */, json!({"n": name}), &path).await?;
        let fuzzy = self.query(/* fuzzy query */, json!({"q": name}), &path).await?;
        Ok(dedupe_by_id([exact, fuzzy]))
    }
```

`scenes` and `scenes_with_tag` follow `bare_scenes` without the filter. `search` uses `&["scrapeSingleScene"]` and returns `Vec<Candidate>`. `fingerprint_matches` deserializes `Vec<Vec<FingerprintMatch>>` from `&["scrapeMultiScenes"]` and keeps the length `ensure!`. `studios_like` mirrors `performers_like`. In the `performers_like` and `studios_like` bodies, keep the two existing GraphQL query strings verbatim where the sketch above shows `/* exact query */` and `/* fuzzy query */`. `run_job`, `by_stash_id`, `tag_id` and the three creates read ids through small typed replies:

```rust
#[derive(serde::Deserialize)]
struct Job {
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    error: Option<String>,
}
```
In `run_job`: the mutation returns a bare id, so read it as `let job: String = match self.query::<Value>(&q, json!({"i": inp}), &[mutation]).await? { Value::String(s) => s, other => other.to_string() };`, then poll with `let j: Option<Job> = self.query(…, &["findJob"]).await?;` and treat `None` or `status == Some("FINISHED")` as done, exactly as now. `by_stash_id` deserializes `Vec<Ref>` from `[find{kind}s, {lower}s]`. `tag_id` deserializes `Vec<NamedRecord>` from `["findTags", "tags"]` and compares `t.name.as_deref() == Some(name)`; creating reads `Ref` from `["tagCreate"]`. `create_performer` / `create_studio` read `Ref` from `["performerCreate"]` / `["studioCreate"]` and return `.id`.

`dedupe_by_id` becomes:

```rust
fn dedupe_by_id(groups: [Vec<NamedRecord>; 2]) -> Vec<NamedRecord> {
    let mut seen = HashSet::new();
    groups.into_iter().flatten().filter(|r| seen.insert(r.id.clone())).collect()
}
```

5. Update this file's wiremock tests that read results as `Value`, e.g. `result.iter().map(|r| r["id"].clone())` becomes `result.iter().map(|r| r.id.as_str()).collect::<Vec<_>>()` compared against `["1", "2"]`.

- [ ] **Step 7: Bridge identify to the typed reads**

`matching` still takes `&Value` in this task. In `src/identify/mod.rs` add, just below the imports:

```rust
/// Temporary: matching still reads JSON. Deleted in the matching rewrite.
fn json<T: serde::Serialize>(v: &T) -> Value {
    serde_json::to_value(v).expect("records serialize")
}
```

Then, mechanically:
- `scene: &Value` parameters become `scene: &Scene` throughout `identify/mod.rs` (`fc2_prop`, `code_prop`, `identify_scene`, `apply`, `english_title`, `format_line`, `is_upgrade`, `pass_scene`, `record_new`); `id_str(&scene["id"])` becomes `scene.id.clone()` (or `&scene.id`); `first_file(scene)` becomes `scene.first_file()`; delete the free `first_file` and `filled` and use `Scene::first_file` / `Scene::is_filled`.
- `is_upgrade` becomes `tag.is_some_and(|t| scene.has_tag(t)) && scene.first_path().is_some_and(|p| matching::product_code(paths.rel_path(p)).is_some())` with the existing empty-tag guard.
- Every call into `matching` that took a scene or candidate now passes `&json(&x)`; `stash.search(...)` results become `hits.iter().map(json).collect::<Vec<Value>>()` before entering the existing Value code; `scrape_url`'s `Option<Candidate>` likewise. `matching::scrape_update(&json(scene), …)` and `llm_update(&json(scene), …)`.
- `defaults: &Value` becomes `&Defaults`: `&defaults["scan"]` → `&defaults.scan` (and generate, identify); `skip_tags(defaults)` → `defaults.skip_tags()`; `identify_boxes(defaults)` → `defaults.identify_boxes()`; delete the free `skip_tags` and `identify_boxes`.
- `fingerprint_suspects`: `m.duration` and `m.title.as_deref()` replace the `Value` reads; keep the log line as is in this task.
- `resolve_studio` / `resolve_performer` take `&[NamedRecord]` through `pick_by_name`; in `matching.rs` change only `pick_by_name` now, since it reads search records, not candidates:

```rust
pub fn pick_by_name(records: &[NamedRecord], name: &str, allow_alias: bool) -> Option<String> {
    let n = norm(Some(name));
    records
        .iter()
        .find(|r| norm(r.name.as_deref()) == n)
        .or_else(|| {
            allow_alias
                .then(|| records.iter().find(|r| r.aliases.iter().any(|a| norm(Some(a)) == n)))
                .flatten()
        })
        .map(|r| r.id.clone())
}
```
Callers drop the `"aliases"` / `"alias_list"` argument.

In `src/provenance.rs`, `link` takes `scene: &Scene`: `let path = scene.first_path()?;` and `let id = &scene.id;`; drop the `id_str` and `Value` imports. Update `provenance_tests.rs` call sites by deserializing their `json!` scenes (see Step 8's `scene()` helper; copy it into that test module).

- [ ] **Step 8: Migrate the identify test fakes**

At the top of `src/identify/tests.rs` add:

```rust
fn scene(v: Value) -> Scene {
    serde_json::from_value(v).expect("test scene")
}

fn cand(v: Value) -> Candidate {
    serde_json::from_value(v).expect("test candidate")
}

fn named(v: Value) -> NamedRecord {
    serde_json::from_value(v).expect("test record")
}
```

Migration rules for the rest of the file:
1. `FakeStash` fields that hold Stash reads change type: `results: HashMap<String, Result<Vec<Candidate>, Fail>>`, `performers: Vec<NamedRecord>`, `studios: Vec<NamedRecord>`, `tagged: Vec<Scene>`, `fc2: HashMap<String, Result<Option<Candidate>, Fail>>`, `bare: Vec<Scene>`, `scenes_dict: HashMap<String, Scene>`, and `Fingerprints = Result<HashMap<&'static str, Vec<FingerprintMatch>>, Fail>`.
2. Where a test builds one of those with `json!(…)`, wrap it in `scene(…)`, `cand(…)`, `named(…)` or `serde_json::from_value(…).unwrap()`. The literal inside stays identical.
3. Write-side fields (`updates`, `created`) stay `Value` in this task.
4. `FakeStash::defaults` returns `Ok(Defaults::default())`; tests that pass a `defaults` `json!` to `run_pass` deserialize it: `let defaults: Defaults = serde_json::from_value(json!({…})).unwrap();`.
5. Any assertion on a *read* record (`s["id"]`) becomes a field access (`s.id`).

- [ ] **Step 9: Run everything**

Run: `cargo test 2>&1 | grep -E "^test result|FAILED|panicked"` and `cargo clippy --all-targets -- -D warnings`.
Expected: all pass. The test count is the Task 0 baseline plus 11 (the new `de` and `types` tests).

- [ ] **Step 10: Commit**

```bash
git add src/stash src/identify src/provenance.rs src/provenance_tests.rs
git commit -m "refactor(galactica): plab reads Stash into typed records"
```

---

### Task 2: Typed matching and typed Stash writes

Rewrites `matching.rs` over `Scene`, `Candidate` and `Parse`, adds the write-side input structs, switches the `StashApi` write methods to them, and deletes the Task 1 shim and every Python helper in `matching.rs`. Introduces `llm::Parse` here, because matching consumes it; the `Llm` trait still returns `Value` until Task 3, deserialized at the call site.

**Files:**
- Modify: `src/stash/types.rs` (write inputs), `src/stash/mod.rs` (write signatures), `src/llm.rs` (add `Parse`), `src/identify/matching.rs`, `src/identify/matching_tests.rs`, `src/identify/mod.rs`, `src/identify/tests.rs`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  - `stash::types::{SceneUpdate, PerformerCreate, StudioCreate, Gender, Resolved}`
  - `SceneUpdate::new(id: &str) -> SceneUpdate`, `SceneUpdate::has_changes(&self) -> bool`
  - `llm::Parse { studio, title, date, time, series, clip_id, query: Option<String>, performers: Vec<String> }`, `Parse::display_title(&self) -> Option<String>`, `Parse::has_content(&self) -> bool`
  - `matching::{Hit, scrape_update, llm_update, performer_create_input, studio_create_input, fc2_scene, summary, jev_request, jev_pick, deterministic_match, twins, dedupe, duration_ok, studio_matches, scene_key, single_scene, stash_ids_for}` with the signatures below; `codedb_scene(&Value) -> Candidate` survives temporarily until Task 4.
  - `StashApi::{create_performer(&PerformerCreate), create_studio(&StudioCreate), update_scene(&SceneUpdate)}`

- [ ] **Step 1: Add the write-side types to `src/stash/types.rs`**

```rust
fn is_empty<T>(v: &[T]) -> bool {
    v.is_empty()
}

/// SceneUpdateInput. Only the fields set are sent; Stash leaves the rest alone.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct SceneUpdate {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub director: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub urls: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cover_image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub studio_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub performer_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tag_ids: Option<Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stash_ids: Option<Vec<StashId>>,
}

impl SceneUpdate {
    pub fn new(id: &str) -> SceneUpdate {
        SceneUpdate { id: id.to_string(), ..SceneUpdate::default() }
    }

    /// Sets anything besides the id.
    pub fn has_changes(&self) -> bool {
        *self != SceneUpdate::new(&self.id)
    }
}

/// GenderEnum. Parsed from a scraped performer's free text; anything else is not sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum Gender {
    Male,
    Female,
    TransgenderMale,
    TransgenderFemale,
    Intersex,
    NonBinary,
}

/// "transgender female", "Non-Binary", "MALE" -> the enum spelling.
fn enum_key(s: &str) -> String {
    s.to_uppercase().replace([' ', '-'], "_")
}

impl std::str::FromStr for Gender {
    type Err = ();
    fn from_str(s: &str) -> Result<Gender, ()> {
        Ok(match enum_key(s).as_str() {
            "MALE" => Gender::Male,
            "FEMALE" => Gender::Female,
            "TRANSGENDER_MALE" => Gender::TransgenderMale,
            "TRANSGENDER_FEMALE" => Gender::TransgenderFemale,
            "INTERSEX" => Gender::Intersex,
            "NON_BINARY" => Gender::NonBinary,
            _ => return Err(()),
        })
    }
}

/// PerformerCreateInput; unset fields are not sent.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct PerformerCreate {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub disambiguation: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub gender: Option<Gender>,
    #[serde(skip_serializing_if = "is_empty")]
    pub urls: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub birthdate: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub death_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ethnicity: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub country: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub eye_color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub hair_color: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub height_cm: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub weight: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub measurements: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub career_start: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub career_end: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tattoos: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub piercings: Option<String>,
    #[serde(skip_serializing_if = "is_empty")]
    pub alias_list: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(skip_serializing_if = "is_empty")]
    pub stash_ids: Vec<StashId>,
}

impl PerformerCreate {
    /// Just a name: a performer known only from a filename.
    pub fn named(name: &str) -> PerformerCreate {
        PerformerCreate { name: name.to_string(), ..PerformerCreate::default() }
    }
}

/// StudioCreateInput; unset fields are not sent.
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct StudioCreate {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    #[serde(skip_serializing_if = "is_empty")]
    pub urls: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
    #[serde(skip_serializing_if = "is_empty")]
    pub aliases: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    #[serde(skip_serializing_if = "is_empty")]
    pub stash_ids: Vec<StashId>,
}

impl StudioCreate {
    pub fn named(name: &str) -> StudioCreate {
        StudioCreate { name: name.to_string(), ..StudioCreate::default() }
    }
}

/// What `apply` resolved a scrape's studio, performers and tags to in this Stash.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Resolved {
    pub studio_id: Option<String>,
    pub performer_ids: Vec<String>,
    pub tag_ids: Vec<String>,
    pub stash_ids: Vec<StashId>,
}
```

Add tests to the `types` test module:

```rust
    #[test]
    fn scene_update_sends_only_what_is_set() {
        let mut up = SceneUpdate::new("5");
        assert!(!up.has_changes());
        assert_eq!(serde_json::to_value(&up).unwrap(), json!({"id": "5"}));
        up.cover_image = Some("data:x".into());
        assert!(up.has_changes());
        assert_eq!(serde_json::to_value(&up).unwrap(), json!({"id": "5", "cover_image": "data:x"}));
    }

    #[test]
    fn enums_parse_free_text() {
        assert_eq!("transgender female".parse(), Ok(Gender::TransgenderFemale));
        assert_eq!("Non-Binary".parse(), Ok(Gender::NonBinary));
        assert_eq!("robot".parse::<Gender>(), Err(()));
        assert_eq!(serde_json::to_value(Gender::NonBinary).unwrap(), json!("NON_BINARY"));
    }

    #[test]
    fn creates_drop_empty_fields() {
        assert_eq!(serde_json::to_value(PerformerCreate::named("A")).unwrap(), json!({"name": "A"}));
        assert_eq!(serde_json::to_value(StudioCreate::named("S")).unwrap(), json!({"name": "S"}));
    }
```

Run: `cargo test stash::types` → 8 pass.

- [ ] **Step 2: Add `Parse` to `src/llm.rs`**

```rust
/// The LLM's reading of a file path (`PARSE_PROMPT`'s JSON).
#[derive(Debug, Clone, Default, PartialEq, Deserialize, Serialize)]
pub struct Parse {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub studio: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::names")]
    pub performers: Vec<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub date: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub time: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub series: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub clip_id: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub query: Option<String>,
}

impl Parse {
    /// A scene title, or None if there's nothing usable.
    ///
    /// The parsed title unchanged when there is one. Otherwise, for a filename with no real
    /// title, a "Creator – date" style fallback: base is the series, studio, or first
    /// performer (in that order); suffix is date+time, date, a clip_id, or -- only when
    /// base came from a series -- the first performer's name. No suffix means no title: a
    /// bare creator name on its own isn't worth writing.
    pub fn display_title(&self) -> Option<String> {
        if let Some(t) = &self.title {
            return Some(t.clone());
        }
        let first = self.performers.first();
        let base = self.series.as_ref().or(self.studio.as_ref()).or(first)?;
        let suffix = match (&self.date, &self.time) {
            (Some(d), Some(t)) => format!("{d} {t}"),
            (Some(d), None) => d.clone(),
            _ => match (&self.clip_id, &self.series, first) {
                (Some(c), _, _) => c.clone(),
                (None, Some(_), Some(p)) => p.clone(),
                _ => return None,
            },
        };
        Some(format!("{base} \u{2013} {suffix}"))
    }

    /// Worth writing as a guess: a title, a studio or performers.
    pub fn has_content(&self) -> bool {
        self.display_title().is_some() || self.studio.is_some() || !self.performers.is_empty()
    }
}
```

Add `use crate::stash::de;` and `use serde::{Deserialize, Serialize};` to `llm.rs`. Move the existing `display_title` tests from `matching_tests.rs` to `llm.rs`'s test module, building `Parse` with `serde_json::from_value(json!({…})).unwrap()` from the same literals and calling `.display_title()`.

- [ ] **Step 3: Rewrite `matching.rs` over the types**

Replace the file's Python helpers and `Value` functions. A candidate tagged with its endpoint is a named type now:

```rust
//! Pure matching and payload-building logic for identify. No I/O here.

use std::collections::HashSet;
use std::sync::LazyLock;

use anyhow::{Result, bail};
use regex::Regex;
use serde::Serialize;

use crate::llm::{JevRequest, Parse};
use crate::stash::de::csv;
use crate::stash::{
    Candidate, Gender, PerformerCreate, Resolved, Scene, SceneUpdate, ScrapedPerformer,
    ScrapedStudio, StashId, StudioCreate,
};

/// A candidate and the stash-box endpoint it came from.
#[derive(Debug, Clone, PartialEq)]
pub struct Hit {
    pub endpoint: String,
    pub scene: Candidate,
}
```

The functions, in file order (keep each existing doc comment; the bodies change):

```rust
pub fn norm(s: Option<&str>) -> String { /* unchanged */ }
fn squash(s: &str) -> String { /* unchanged */ }

pub fn studio_matches(c: &Candidate, name: &str) -> bool {
    let want = squash(name);
    let Some(s) = c.studio.as_ref().filter(|_| !want.is_empty()) else {
        return false;
    };
    let parent = s.parent.as_ref().and_then(|p| p.name.clone());
    s.name.iter().cloned().chain(parent).chain(csv(s.aliases.as_deref())).any(|n| squash(&n) == want)
}

pub fn scene_key(c: &Candidate) -> (String, String) {
    (norm(c.title.as_deref()), norm(c.studio_name()))
}

pub fn duration_ok(c: &Candidate, file_duration: f64) -> bool {
    c.known_duration().is_some_and(|d| (d - file_duration).abs() <= DURATION_TOLERANCE)
}

pub fn dedupe(cands: Vec<Hit>) -> Vec<Hit> {
    let mut seen = HashSet::new();
    cands.into_iter().filter(|h| seen.insert(scene_key(&h.scene))).collect()
}

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
    let titles: HashSet<String> = hits.iter().map(|h| norm(h.scene.title.as_deref())).collect();
    (titles.len() == 1).then(|| hits[0].clone())
}

pub fn twins(chosen: &Hit, all: &[Hit], file_duration: f64) -> Vec<Hit> {
    let key = scene_key(&chosen.scene);
    all.iter()
        .filter(|h| scene_key(&h.scene) == key && duration_ok(&h.scene, file_duration))
        .cloned()
        .collect()
}

// PRODUCT_CODE, FC2_CODE, CODE_KEY, stem, product_code, fc2_number, code_key: unchanged.
// Rename stem's doc comment from the Python expression to:
/// The file name without its directory or last extension (a leading dot is not one).

pub fn single_scene(cands: Vec<Candidate>) -> Option<Candidate> {
    let titles: HashSet<String> = cands.iter().map(|c| norm(c.title.as_deref())).collect();
    (titles.len() == 1).then(|| cands.into_iter().next()).flatten()
}

const FC2_STUDIO: &str = "FC2-PPV";

/// (keep the existing fc2_scene doc comment)
pub fn fc2_scene(hit: &Candidate, title: &str) -> Candidate {
    let studio = match hit.performers.iter().find_map(|p| p.name.clone()) {
        Some(seller) => ScrapedStudio {
            name: Some(seller),
            parent: Some(Box::new(ScrapedStudio { name: Some(FC2_STUDIO.into()), ..Default::default() })),
            ..Default::default()
        },
        None => ScrapedStudio { name: Some(FC2_STUDIO.into()), ..Default::default() },
    };
    let details: Vec<&str> = [&hit.title, &hit.details].into_iter().flatten().map(String::as_str).collect();
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
        duration_seconds: Option<f64>,
    }
    serde_json::to_string(&Summary {
        title: c.title.as_deref(),
        studio: c.studio_name(),
        performers: c.performers.iter().filter_map(|p| p.name.as_deref()).collect(),
        date: c.date.as_deref(),
        code: c.code.as_deref(),
        duration_seconds: c.known_duration(),
    })
    .expect("summary serializes")
}

pub fn stash_ids_for(endpoint: &str, remote_id: Option<&str>) -> Vec<StashId> {
    remote_id
        .filter(|id| !id.is_empty())
        .map(|id| StashId { endpoint: endpoint.to_string(), stash_id: id.to_string() })
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
pub fn studio_create_input(s: &ScrapedStudio, endpoint: &str, parent_id: Option<&str>) -> StudioCreate {
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

pub fn alias_ok(name: &str) -> bool { /* unchanged */ }
// pick_by_name: as written in Task 1.

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

/// (keep scrape_update's doc comment)
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
        urls: (!primary.urls.is_empty() && (overwrite || scene.urls.is_empty())).then(|| primary.urls.clone()),
        cover_image: primary.image.clone(),
        studio_id: resolved.studio_id.clone().filter(|_| overwrite || scene.studio.is_none()),
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
        studio_id: studio_id.filter(|_| scene.studio.is_none()).map(str::to_string),
        performer_ids: Some(merge(ids(&scene.performers), performer_ids)),
        tag_ids: Some(merge(ids(&scene.tags), &[llm_tag_id.to_string()])),
        ..SceneUpdate::new(&scene.id)
    }
}

/// The Jev choice over duration-filtered candidates.
pub fn jev_request(path: &str, duration: f64, parse: &Parse, cands: &[Hit]) -> JevRequest {
    let mut criteria: Vec<(String, String)> =
        cands.iter().enumerate().map(|(i, h)| (format!("c{i}"), summary(&h.scene))).collect();
    criteria.push(("none".into(), "None of the candidates is this exact scene.".into()));
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
    match choice.strip_prefix('c').and_then(|n| n.parse::<usize>().ok()).and_then(|i| cands.get(i)) {
        Some(h) => Ok(Some(h.clone())),
        None => bail!("jev choice {choice:?} is neither \"none\" nor a candidate"),
    }
}
```

Notes on exactness:
- `studio_id: resolved.studio_id.clone().filter(…)`: callers already pass `None` for an empty id; `Resolved` is built from `Option<String>` ids, never `Some("")`.
- `merge` keeps the old order: existing ids first, then new ones not already present.
- Delete `GENDERS`, `truthy`, `or`, `get`, `cget`, `as_str`, `py_str`, `py_repr`, `id_str`, `norm_v`, `studio_name` (use `Candidate::studio_name`), `describe`, `compact`, `to_float`, `to_int`, `to_float_value`, `to_enum`, `aliases`, `remote_stash_ids`, `strings`, `display_title` (now `Parse::display_title`), and `codedb_scene` (moves to `codedb.rs` in Task 4; in this task keep it as a function `pub fn codedb_scene(hit: &serde_json::Value) -> Candidate` by wrapping the old body's output: `serde_json::from_value(old_body(hit)).expect("codedb scene")`, rename the old body `codedb_json` as a private fn, and keep only the helpers it needs as private fns at the bottom, marked `// Task 4 replaces this with codedb::CodeHit.`).
- `JevRequest` is defined in `llm.rs` in Task 3. For this task, define it in `llm.rs` now:

```rust
/// One Jev decision: which candidate (if any) a file is.
#[derive(Debug, Clone, PartialEq)]
pub struct JevRequest {
    pub file_path: String,
    pub file_duration_seconds: i64,
    pub filename_parse: Parse,
    pub instructions: &'static str,
    /// `c0`, `c1`, … then `none`, each with its description, in order.
    pub criteria: Vec<(String, String)>,
}

impl JevRequest {
    /// The decisions API's `state` and `questions`.
    pub fn body(&self) -> (serde_json::Value, serde_json::Value) {
        let criteria: serde_json::Map<String, serde_json::Value> =
            self.criteria.iter().map(|(k, v)| (k.clone(), v.clone().into())).collect();
        (
            json!({
                "file_path": self.file_path,
                "file_duration_seconds": self.file_duration_seconds,
                "filename_parse": self.filename_parse,
            }),
            json!({"match": {"type": "choice", "instructions": self.instructions, "criteria": criteria}}),
        )
    }
}
```

In this task `Llm::choose` keeps its `(Value, Value)` signature; `identify_scene` calls `let (state, questions) = req.body();`.

- [ ] **Step 4: Switch the Stash write methods**

In `src/stash/mod.rs`, the trait and impl:

```rust
    fn create_performer(&self, inp: &PerformerCreate) -> impl Future<Output = anyhow::Result<String>> + Send;
    fn create_studio(&self, inp: &StudioCreate) -> impl Future<Output = anyhow::Result<String>> + Send;
    fn update_scene(&self, inp: &SceneUpdate) -> impl Future<Output = anyhow::Result<()>> + Send;
```
Bodies unchanged apart from the parameter type: `json!({"i": inp})` serializes the struct.

- [ ] **Step 5: Update `identify/mod.rs`**

- Delete the `json` shim and the `Value` import if unused.
- `everything: Vec<Hit>`; `hits.into_iter().take(PER_BOX).map(|scene| Hit { endpoint: ep.to_string(), scene })`.
- The LLM parse: `let mut parse: Parse = serde_json::from_value(c.llm.parse(path).await?).context("malformed parse reply")?;` (same for `parse_with_title`). A forced studio: `if let Some(s) = forced { parse.studio = Some(s.to_string()); }`. The kind check becomes `parse.has_content()`. The search query: `parse.query.as_deref()`.
- Jev: `let req = matching::jev_request(path, duration, &parse, &cands); let (state, questions) = req.body(); let answer = c.llm.choose(state, questions).await…?; let chosen = matching::jev_pick(answer.get("choice").and_then(Value::as_str), &cands)?; confidence = answer.get("confidence").and_then(Value::as_f64);`
- Primary: `group.sort_by_key(|h| box_index(&h.endpoint))`; stash ids from `h.scene.remote_site_id.as_deref()`; `primary.scene.duration.context("matched scene has no duration")?`.
- `code_prop`: `matching::code_key(h.code.as_deref())`; `chosen.known_duration().map(|d| (d - duration).round_ties_even() as i64)`; `chosen.remote_site_id.as_deref()`.
- `apply`, Scrape branch: build `Resolved` from the candidate:

```rust
            let ep = prop.primary_endpoint.as_deref();
            let mut resolved = Resolved { stash_ids: prop.stash_ids.clone(), ..Resolved::default() };
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
                let Some(name) = x.name.as_deref() else { continue };
                let inp = matching::performer_create_input(x, ep.unwrap_or(""));
                resolved
                    .performer_ids
                    .push(resolve_performer(stash, name, Some(inp), ep, x.remote_site_id.as_deref()).await?);
            }
            resolved.tag_ids = p.tags.iter().filter_map(|t| t.stored_id.clone()).collect();
            let up = matching::scrape_update(scene, p, &resolved, skip_tag_ids, overwrite);
```
- `resolve_studio` / `resolve_performer` take `create_input: Option<StudioCreate>` / `Option<PerformerCreate>` and fall back to `StudioCreate::named(name)` / `PerformerCreate::named(name)`.
- Llm branch: `parse.studio.as_deref()`, `for n in &parse.performers`.
- None branch: `let up = with_cover(SceneUpdate::new(&scene.id), cover); if up.has_changes() { stash.update_scene(&up).await?; }`.
- `english_title(c, scene, mut up: SceneUpdate) -> anyhow::Result<SceneUpdate>`: `if let Some(original) = up.title.as_deref().filter(|t| is_non_latin(t)) { … up.title = Some(title); }`.
- `with_cover(mut up: SceneUpdate, cover) -> SceneUpdate`: `if up.cover_image.is_none() && let Some(uri) = cover.and_then(cover_uri) { up.cover_image = Some(uri); }`.
- `Proposal` fields in this task: `parse: Option<Parse>`, `primary: Option<Candidate>`, `stash_ids: Vec<StashId>`. (Task 3 turns it into an enum.) `format_line` and `outcome_of` read `p.title.as_deref()`, `p.studio_name()`, `p.performers.iter().map(|x| x.name.as_deref().unwrap_or("None"))`, `q.display_title()`, `q.studio.as_deref()`, `q.performers`; `prop.stash_ids.iter().map(|s| &s.endpoint)`.
- `fc2_prop`: `hit.title.as_deref()` for the original.

- [ ] **Step 6: Migrate the tests**

`matching_tests.rs`:
- `fn cand(title, studio, date, duration) -> Candidate` builds the same `json!` and deserializes it; `fn ep(e, c) -> Hit { Hit { endpoint: e.into(), scene: c } }`; `det_parse() -> Parse` deserializes its literal.
- Assertions on candidate fields (`out[1].1["title"]`) become `out[1].scene.title.as_deref() == Some("Other")`.
- Assertions on built payloads (`scrape_update`, `llm_update`, `performer_create_input`, `studio_create_input`, `fc2_scene`) wrap the result in `serde_json::to_value(&x).unwrap()` and keep the expected `json!` literal unchanged. The one exception: `fc2_scene` and `codedb_scene` now return a `Candidate`, so compare against `cand(json!({…expected…}))` rather than JSON (a `Candidate` serializes every field, `null`s included).
- `scrape_update` callers pass `&Resolved { studio_id, performer_ids, tag_ids, stash_ids }` instead of the separate arguments.
- `describe` tests become `summary` tests. Expected values are the new JSON, e.g. `summary(&cand(json!({"title": "A", "studio": {"name": "S"}, "performers": [{"name": "P"}], "date": "2024-01-02", "duration": 348})))` == `r#"{"title":"A","studio":"S","performers":["P"],"date":"2024-01-02","code":null,"duration_seconds":348.0}"#`. These are the named, intended changes in this task.
- `jev_request` tests compare `req.body()` against the old expected state, and against questions whose criteria values are the new `summary` strings.
- `jev_pick` tests pass `Some("c1")` / `Some("none")` / `Some("c9")`.

`identify/tests.rs`:
- `updates: Mutex<Vec<Value>>` stays, and `update_scene` pushes `serde_json::to_value(inp).unwrap()`. `created: Mutex<Vec<(String, Value)>>` does the same for creates. **No update or create assertion changes.** If one fails, the rewrite changed behaviour: fix the code, not the expectation.
- `FakeStash::performers_like` / `studios_like` already return `NamedRecord`s from Task 1.
- `FakeLlm::parse` still returns `Value` in this task.

- [ ] **Step 7: Run everything**

Run: `cargo test 2>&1 | grep -E "^test result|FAILED|panicked"` and `cargo clippy --all-targets -- -D warnings`.
Expected: all pass; `grep -n "truthy\|py_repr\|py_str\|cget" src/identify/matching.rs` prints nothing.

- [ ] **Step 8: Commit**

```bash
git add src/stash src/llm.rs src/identify
git commit -m "refactor(galactica): plab matches and writes typed Stash records"
```

---

### Task 3: Proposal enum, Outcome enum, typed LLM client

**Files:**
- Modify: `src/identify/mod.rs`, `src/llm.rs`, `src/identify/tests.rs`

**Interfaces:**
- Consumes: Task 2's `Parse`, `JevRequest`, `Hit`, `Candidate`, `StashId`.
- Produces:
  - `identify::Proposal::{Nothing, Llm(Parse), Scrape(ScrapeMatch)}`; `ScrapeMatch { rule: Rule, source: &'static str, candidate: Candidate, endpoint: Option<String>, stash_ids: Vec<StashId>, confidence: Option<f64>, delta: Option<i64> }`; `Rule::{Code, Date, Jev}` with `Display` `code`/`date`/`jev`
  - `identify::Outcome::{Scrape, Llm, Nothing, Stash, GaveUp}` with `as_str()` → `scrape`/`llm`/`none`/`stash`/`gave-up`
  - `llm::JevAnswer { choice: Option<String>, confidence: Option<f64> }`
  - `Llm::{parse(&self, path) -> Result<Parse>, parse_with_title(...) -> Result<Parse>, translate_title(...) -> Result<String>, choose(&self, req: &JevRequest) -> Result<JevAnswer>}`

- [ ] **Step 1: Write failing tests for the new display and outcome code**

In `src/identify/tests.rs` add:

```rust
#[test]
fn outcome_strings_are_the_stored_ones() {
    let all = [Outcome::Scrape, Outcome::Llm, Outcome::Nothing, Outcome::Stash, Outcome::GaveUp];
    assert_eq!(all.map(Outcome::as_str), ["scrape", "llm", "none", "stash", "gave-up"]);
}

#[test]
fn format_line_scrape() {
    let s = scene(json!({"id": "5", "files": [{"path": "/media/Vault/Studio/a.mp4", "duration": 300}]}));
    let prop = Proposal::Scrape(ScrapeMatch {
        rule: Rule::Jev,
        source: "",
        candidate: cand(json!({"title": "It's On", "studio": {"name": "S"}, "performers": [{"name": "A"}, {"name": "B"}]})),
        endpoint: Some(BOXES[0].into()),
        stash_ids: vec![StashId { endpoint: BOXES[0].into(), stash_id: "x".into() }],
        confidence: Some(0.91),
        delta: Some(-2),
    });
    assert_eq!(
        format_line(&PATHS, &s, &prop),
        "[5] Studio/a.mp4\n    codedb (jev conf=0.91) | \"It's On\" | S | A, B | Δ-2s"
    );
}

#[test]
fn format_line_llm_and_nothing() {
    let s = scene(json!({"id": "5", "files": [{"path": "/media/Vault/a.mp4", "duration": 300}]}));
    let parse: Parse = serde_json::from_value(json!({"title": "T", "performers": []})).unwrap();
    assert_eq!(format_line(&PATHS, &s, &Proposal::Llm(parse)), "[5] a.mp4\n    llm-only | \"T\" | - | -");
    assert_eq!(format_line(&PATHS, &s, &Proposal::Nothing), "[5] a.mp4\n    nothing found");
}
```

Run: `cargo test identify::tests::format_line identify::tests::outcome` → FAIL to compile (`Outcome`, `ScrapeMatch`, `Rule` undefined).

- [ ] **Step 2: Implement the enums**

In `src/identify/mod.rs`, replace `Kind`, `Proposal` and `Proposal::scrape`:

```rust
/// Which rule confirmed a scrape.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Rule {
    /// The file's product code or FC2 code.
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
                let conf = m.confidence.map_or(String::new(), |c| format!(" conf={c:.2}"));
                let perf: Vec<&str> = c.performers.iter().filter_map(|p| p.name.as_deref()).collect();
                let delta = m.delta.map_or("Δ?".to_string(), |d| format!("Δ{d:+}s"));
                write!(
                    f,
                    "{} ({}{conf}) | {:?} | {} | {} | {delta}",
                    m.source_label(),
                    m.rule,
                    c.title.as_deref().unwrap_or(""),
                    c.studio_name().unwrap_or("-"),
                    or_dash(&perf.join(", ")),
                )
            }
            Proposal::Llm(q) => write!(
                f,
                "llm-only | {:?} | {} | {}",
                q.display_title().unwrap_or_default(),
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
```

`format_line` becomes:

```rust
/// The two lines a pass prints for a scene's proposal.
pub fn format_line(paths: &Paths, scene: &Scene, prop: &Proposal) -> String {
    let file = scene.first_path().unwrap_or("");
    format!("[{}] {}\n    {prop}", scene.id, paths.rel_path(file))
}
```

`outcome_of`:

```rust
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
```

`record_outcome(db, id, outcome: Outcome, label)` calls `db.record_outcome(id, outcome.as_str(), label)`. `record_new` passes `Outcome::Stash`; the give-up path passes `Outcome::GaveUp`.

- [ ] **Step 3: Rewrite the proposal producers and `apply` over the enum**

- `fc2_prop` returns `Ok(Some(Proposal::Scrape(ScrapeMatch::code("fc2", matching::fc2_scene(&hit, &title), None))))`.
- `code_prop` ends:

```rust
    let stash_ids = matching::stash_ids_for(ep, chosen.remote_site_id.as_deref());
    let delta = chosen.known_duration().map(|d| (d - duration).round_ties_even() as i64);
    Ok(Some(Proposal::Scrape(ScrapeMatch {
        stash_ids,
        delta,
        ..ScrapeMatch::code(source, chosen, Some(ep))
    })))
```
  where `ep: &str` and `source: &'static str` (`"stashdb"` / `"codedb"`).
- `identify_scene`:

```rust
    let fallback = if parse.has_content() { Proposal::Llm(parse.clone()) } else { Proposal::Nothing };
    // … searches as in Task 2 …
    if cands.is_empty() {
        return Ok(fallback);
    }
    let mut confidence = None;
    let (chosen, rule) = match matching::deterministic_match(&cands, &parse) {
        Some(chosen) => (Some(chosen), Rule::Date),
        None => {
            let req = matching::jev_request(path, duration, &parse, &cands);
            let answer = c.llm.choose(&req).await.map_err(|e| transient(format!("scene {id}: jev failed: {e:#}")))?;
            confidence = answer.confidence;
            (matching::jev_pick(answer.choice.as_deref(), &cands)?, Rule::Jev)
        }
    };
    let Some(chosen) = chosen else {
        return Ok(fallback);
    };
    // … group / ids / primary_duration as in Task 2 …
    Ok(Proposal::Scrape(ScrapeMatch {
        rule,
        source: "",
        delta: Some((primary_duration - duration).round_ties_even() as i64),
        candidate: primary.scene,
        endpoint: Some(primary.endpoint),
        stash_ids: ids,
        confidence,
    }))
```
- `apply` matches `prop` directly: `Proposal::Scrape(m)` uses `m.candidate`, `m.endpoint.as_deref()`, `m.stash_ids`; `Proposal::Llm(parse)`; `Proposal::Nothing`. The two `.context("… proposal without …")` errors disappear, since the enum makes them impossible.

- [ ] **Step 4: Type the `Llm` trait**

In `src/llm.rs`:

```rust
/// A Jev decision's answer.
#[derive(Debug, Clone, Default, PartialEq, Deserialize)]
pub struct JevAnswer {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub choice: Option<String>,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub confidence: Option<f64>,
}

pub trait Llm: Send + Sync {
    fn parse(&self, path: &str) -> impl Future<Output = anyhow::Result<Parse>> + Send;
    fn parse_with_title(&self, path: &str, title: &str, studio: Option<&str>) -> impl Future<Output = anyhow::Result<Parse>> + Send;
    fn translate_title(&self, title: &str) -> impl Future<Output = anyhow::Result<String>> + Send;
    fn choose(&self, req: &JevRequest) -> impl Future<Output = anyhow::Result<JevAnswer>> + Send;
}
```

`chat_json` becomes generic and keeps its one re-ask on a malformed reply:

```rust
    async fn chat_json<T: serde::de::DeserializeOwned>(&self, prompt: &str, text: &str) -> anyhow::Result<T> {
        let body = json!({ /* unchanged */ });
        for _ in 0..2 {
            let d = self.post(CHAT_PATH, &body).await?;
            let out = d
                .pointer("/choices/0/message/content")
                .and_then(Value::as_str)
                .and_then(|c| serde_json::from_str::<T>(c).ok());
            if let Some(out) = out {
                return Ok(out);
            }
        }
        bail!("malformed reply for {text:?}")
    }
```

A reply that is JSON but not an object (`"[]"`, `"3"`) fails to deserialize into a struct, so it is re-asked, exactly as the old `Value::Object` check did.

`parse_with_title` builds its input with a struct rather than patching a `Value`:

```rust
        #[derive(Serialize)]
        struct Input<'a> {
            release_title: &'a str,
            file: &'a str,
            #[serde(skip_serializing_if = "Option::is_none")]
            studio: Option<&'a str>,
        }
        let input = serde_json::to_string(&Input { release_title: title, file: path, studio })?;
        self.chat_json(&format!("{PARSE_PROMPT}\n\n{TITLE_NOTE}"), &input).await
```

`translate_title`:

```rust
        #[derive(Deserialize)]
        struct Reply {
            #[serde(default, deserialize_with = "de::nonempty")]
            title: Option<String>,
        }
        let out: Reply = self.chat_json(TRANSLATE_PROMPT, title).await?;
        let Some(t) = out.title.map(|t| t.trim().to_string()).filter(|t| !t.is_empty()) else {
            bail!("no translation for {title:?}");
        };
```

`choose`:

```rust
    async fn choose(&self, req: &JevRequest) -> anyhow::Result<JevAnswer> {
        let (state, questions) = req.body();
        let d = self
            .post(DECISIONS_PATH, &json!({"model": self.jev_model, "state": state, "questions": questions}))
            .await?;
        let answer = d.pointer("/answers/match").cloned().context("no match answer")?;
        Ok(serde_json::from_value(answer)?)
    }
```

`classify`'s error for an unexpected choice: replace the hand-built Python-style `shown` with `bail!("unexpected production choice: {choice:?}")`, where `choice: Option<&Value>`. Update its test expectation to the `Debug` text the test produces (`None` or `Some(String("x"))`).

Rename `prompts_match_the_python_text` to `prompts_match_the_fixtures`, and drop "byte-identical to the Python's" from `TITLE_NOTE`'s comment.

- [ ] **Step 5: Migrate the LLM fakes and tests**

- `FakeLlm` in `identify/tests.rs` stores `Parse` replies: wherever a test sets a parse with `json!({…})`, wrap it in `serde_json::from_value::<Parse>(…).unwrap()`. A test that feeds a *malformed* parse (a list, a missing object) now belongs in `llm.rs` (the deserialization lives there); move it there as a wiremock `chat_reply("[]")` test asserting `parse` errors after two calls (`.expect(2)`).
- `FakeLlm::choose(&self, req: &JevRequest)` records `req.body()` where it recorded `(state, questions)` before, and returns `JevAnswer` built from the test's `json!` via `serde_json::from_value`.
- Tests that inspected `prop.kind`, `prop.primary`, `prop.parse` etc. match on the enum instead:

```rust
let Proposal::Scrape(m) = &prop else { panic!("expected a scrape, got {prop:?}") };
assert_eq!(m.rule, Rule::Jev);
assert_eq!(m.candidate.title.as_deref(), Some("Winter Cabin"));
```
  and `assert_eq!(prop, Proposal::Nothing)`, `assert!(matches!(prop, Proposal::Llm(_)))`.
- Log-line assertions that expected Python quoting (`'title'`, `None`) change to the `Display` output above (`"title"` via `{:?}`, `-`). These are the named, intended changes in this task.
- `llm.rs` wiremock tests for `parse_with_title` keep checking the request body. The input text is now `{"release_title":"…","file":"…"}` (compact, field order as declared); update the expected string accordingly.

- [ ] **Step 6: Remove the last helpers**

Delete `str_of`, `repr_list` and the `py` import from `identify/mod.rs`. The scan log becomes `tracing::info!("scan {}", watched.map_or("library".to_string(), |d| format!("{d:?}")))`; the fingerprint warning uses `{:?}` on `m.title.as_deref().unwrap_or("")`.

- [ ] **Step 7: Run everything**

Run: `cargo test 2>&1 | grep -E "^test result|FAILED|panicked"` and `cargo clippy --all-targets -- -D warnings`.
Expected: all pass. `grep -n "Value" src/identify/mod.rs` prints nothing.

- [ ] **Step 8: Commit**

```bash
git add src/identify src/llm.rs
git commit -m "refactor(galactica): plab proposals and LLM replies are typed"
```

---

### Task 4: The remaining `Value` records (the code database, Prowlarr, web replies)

**Files:**
- Modify: `src/codedb.rs`, `src/identify/matching.rs`, `src/identify/mod.rs`, `src/prowlarr.rs`, `src/grab.rs`, `src/web.rs`, `src/web_tests.rs`, `src/plab.rs`, tests in those files

**Interfaces:**
- Consumes: `stash::de`, `Candidate`, `ScrapedStudio`, `ScrapedPerformer`.
- Produces: `codedb::CodeHit` + `impl From<CodeHit> for Candidate`; `CodeSearch::code_search -> Result<Vec<CodeHit>, CodeDbError>`; `prowlarr::ProwlarrResult`; `GrabSource::search -> Result<Vec<ProwlarrResult>>`.

- [ ] **Step 1: Write the failing code-database conversion test**

In `src/codedb.rs`'s test module, port the existing `codedb_scene` tests from `matching_tests.rs` (their input `json!` stays; the conversion changes):

```rust
    #[test]
    fn code_hit_becomes_a_candidate() {
        let hit: CodeHit = serde_json::from_value(json!({
            "title": "T", "external_id": "efgh-796", "date": "2024-01-02", "description": "D",
            "duration": 7200, "slug": "efgh-796", "url": "https://x/1",
            "site": {"name": "Studio A"},
            "performers": [{"name": "Alias", "parent": {"name": "Real"}, "image": "https://i/1"},
                           {"name": "", "parent": null}],
            "background": {"full": "https://bg"}, "poster": "https://p",
        }))
        .unwrap();
        let c = Candidate::from(hit);
        assert_eq!(c.code.as_deref(), Some("EFGH-796"));
        assert_eq!(c.urls, ["https://codedb.example.org/codes/efgh-796", "https://x/1"]);
        assert_eq!(c.image.as_deref(), Some("https://bg"));
        assert_eq!(c.studio_name(), Some("Studio A"));
        assert_eq!(c.performers.len(), 1);
        assert_eq!(c.performers[0].name.as_deref(), Some("Real"));
        assert_eq!(c.performers[0].images, ["https://i/1"]);
        assert!(c.tags.is_empty());
    }
```

Run: `cargo test codedb::` → FAIL to compile (`CodeHit` undefined).

- [ ] **Step 2: Implement `CodeHit`**

```rust
/// A code-database /code record, as far as identify reads it.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct CodeHit {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub title: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub external_id: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub date: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub description: Option<String>,
    #[serde(default, deserialize_with = "de::lenient_f64")]
    pub duration: Option<f64>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub slug: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub url: Option<String>,
    #[serde(default)]
    pub site: Option<CodeSite>,
    #[serde(default, deserialize_with = "de::null_default")]
    pub performers: Vec<CodePerformer>,
    #[serde(default)]
    pub background: Option<CodeBackground>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub poster: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CodeSite {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CodePerformer {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub name: Option<String>,
    #[serde(default, deserialize_with = "de::nonempty")]
    pub image: Option<String>,
    #[serde(default)]
    pub parent: Option<CodeSite>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct CodeBackground {
    #[serde(default, deserialize_with = "de::nonempty")]
    pub full: Option<String>,
}

/// The ScrapedScene shape apply() consumes. There is no remote_site_id: the code database isn't a
/// stash-box, so studio and performers resolve by name. The code database's tags carry no Stash id,
/// so none are passed on.
impl From<CodeHit> for Candidate {
    fn from(h: CodeHit) -> Candidate {
        let performers = h
            .performers
            .into_iter()
            .filter_map(|p| {
                let name = p.parent.and_then(|x| x.name).or(p.name)?;
                Some(ScrapedPerformer { name: Some(name), images: p.image.into_iter().collect(), ..Default::default() })
            })
            .collect();
        let slug_url = h.slug.map(|s| format!("https://codedb.example.org/codes/{s}"));
        Candidate {
            title: h.title,
            code: h.external_id.map(|c| c.to_uppercase()),
            date: h.date,
            details: h.description,
            duration: h.duration,
            image: h.background.and_then(|b| b.full).or(h.poster),
            urls: slug_url.into_iter().chain(h.url).collect(),
            studio: h.site.and_then(|s| s.name).map(|name| ScrapedStudio { name: Some(name), ..Default::default() }),
            performers,
            ..Candidate::default()
        }
    }
}
```

`code_search` deserializes `data` as `Vec<CodeHit>` (`serde_json::from_value(data.take()).context("code search data")`).

In `identify/mod.rs` `code_prop`: filter with `matching::code_key(h.external_id.as_deref()) == key` and map `Candidate::from`. Delete `codedb_scene` and its private helpers from `matching.rs`, and its tests from `matching_tests.rs` (now in `codedb.rs`). `FakeCodeDb` in `identify/tests.rs` stores `Vec<CodeHit>` built from its `json!` literals via `serde_json::from_value`.

Run: `cargo test codedb:: identify::` → PASS.

- [ ] **Step 3: Type Prowlarr results**

In `src/prowlarr.rs`:

```rust
/// One Prowlarr search result. Fields grab cannot do without are optional here, so one
/// malformed result is skipped (see `grab::skip_reason`) rather than failing the search.
#[derive(Debug, Clone, Default, PartialEq, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProwlarrResult {
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub protocol: Option<String>,
    #[serde(default)]
    pub publish_date: Option<String>,
    #[serde(default)]
    pub download_url: Option<String>,
    #[serde(default)]
    pub indexer: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::lenient_f64")]
    pub seeders: Option<f64>,
}

impl ProwlarrResult {
    pub fn title(&self) -> &str {
        self.title.as_deref().unwrap_or("?")
    }
}
```

`Prowlarr::search` returns `Result<Vec<ProwlarrResult>>`. In `grab.rs`: `GrabSource::search` and the impl return `Vec<ProwlarrResult>`; `type Candidate = (ProwlarrResult, BTreeSet<String>)`; `skip_reason(rule, result: &ProwlarrResult, now)` reads `result.title.as_deref().ok_or_else(…)`, `result.protocol.as_deref() != Some("torrent")`, `result.publish_date.as_deref().ok_or_else(…)`; `rank` reads `(result.indexer.as_deref() == Some(QUOTA_INDEXER), -result.seeders.unwrap_or(0.0))`; delete `title_of` (use `result.title()`); `grab()` reads `result.download_url.as_deref().ok_or_else(…)`; the indexer label `result.indexer.as_deref().unwrap_or("?")`. The test helper `res_with` deserializes its `json!` into `ProwlarrResult`, and the test that sets `r["protocol"] = json!("usenet")` sets `r.protocol = Some("usenet".into())`.

- [ ] **Step 4: Plain Rust log formatting in grab, plab, web**

Replace each `repr_str(Some(x))` with `{x:?}` in the format string:
- `grab.rs:84`, `:94`: `format!("… {line:?}")`
- `grab.rs:137`: `.with_context(|| format!("invalid publish date {published:?}"))`
- `grab.rs:337`: `log(&format!("grabbed {label} as {name:?}"))`
- `plab.rs:124`: `warn!("search failed for {term:?}: {e}")`
- `web.rs:418`: `info!(job = "web", "search {q:?} failed: {e}")`

Remove the `use crate::py::repr_str;` lines. Update any test asserting the old `'…'` quoting to `"…"`.

- [ ] **Step 5: Serialize web replies with serde**

In `src/web.rs`'s add/unqueue handler, drop the hand-built Python-dict `shown` strings and log the reply itself as JSON:

```rust
#[derive(serde::Serialize)]
struct AddReply {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    queued: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}
```

Build an `AddReply` per `plab::AddResult` variant (`Added { name }` → `name: Some(name)`, `AlreadyAdded` → `name: Some("already added")`, `Queued { message }` → `queued: Some(true), message: Some(message)`, error → `ok: false, error: Some(…)`, unqueue → `ok: true` only). Respond with `serde_json::to_string(&reply)?`, and log the same string where `shown` was logged. Keep the field order `ok`, `queued`, `name`, `message`, `error`, matching the current replies. Line 487's `py::json(&json!({"images": keys}))` becomes `serde_json::to_string(&json!({"images": keys})).expect("json")`.

In `src/web_tests.rs`, compare reply bodies as JSON rather than text, so separators don't matter:

```rust
fn body_json(r: &Reply) -> serde_json::Value {
    serde_json::from_str(&r.text()).unwrap()
}
// e.g. line 489:
assert_eq!(body_json(&r), json!({"ok": true, "name": "Release"}));
```
(Use the actual reply type name in `web_tests.rs` in place of `Reply`.) Line 361's `starts_with(r#"{"images": ["…", "#)` becomes `body_json(&r)["images"][0] == key(COVER)`.

- [ ] **Step 6: Run everything**

Run: `cargo test 2>&1 | grep -E "^test result|FAILED|panicked"` and `cargo clippy --all-targets -- -D warnings`.
Expected: all pass. `grep -rn "serde_json::Value" src --include=*.rs | grep -v _tests | grep -v "^src/py.rs"` lists only `http.rs` (the generic JSON transport), `stash/` (`gql`, `JobOptions`, job inputs), `llm.rs` (request bodies), `web.rs`'s `json!` image reply, and `stream.rs`.

- [ ] **Step 7: Commit**

```bash
git add src
git commit -m "refactor(galactica): plab types the code database and Prowlarr records and its web replies"
```

---

### Task 5: Delete `py.rs`

**Files:**
- Delete: `src/py.rs`
- Modify: `src/main.rs`, `src/page.rs`, `src/page_tests.rs`, `tests/fixtures/golden_page*.html`

**Interfaces:**
- Consumes: nothing new.
- Produces: no `crate::py`.

- [ ] **Step 1: Swap the page's escaping and JSON**

In `src/page.rs`, replace `use crate::py::{escape as e, json};` with:

```rust
/// HTML-escaped for text and quoted attributes (`&`, `<`, `>`, `"`, `'`).
fn e(s: &str) -> String {
    html_escape::encode_quoted_attribute(s).into_owned()
}

/// `v` as JSON, for embedding in an attribute (callers escape it with `e`).
fn json<T: serde::Serialize + ?Sized>(v: &T) -> String {
    serde_json::to_string(v).expect("page data serializes")
}
```

Line 244: `let keys_json = e(&json(&keys));`. Line 323: `let q = e(&json(tag.as_str()));`. Remove the `Value`/`json as j` imports if they become unused. Drop the module comment's "whose output must stay byte-identical to it (tests/fixtures/golden_page*.html)" and say instead `//! The card grid, rendered from the listing. Pure: no I/O, all data passed in. tests/fixtures/golden_page*.html pin its output.`

Add to `page_tests.rs`:

```rust
#[test]
fn escape_covers_both_quotes() {
    assert_eq!(e(r#"<a href="x">O'Neil & co</a>"#), "&lt;a href=&quot;x&quot;&gt;O&#x27;Neil &amp; co&lt;/a&gt;");
}
```

(If `e` is private to `page.rs`, make it `pub(crate)`.)

- [ ] **Step 2: Delete the module**

```bash
git rm src/py.rs
```
Remove `mod py;` from `src/main.rs`. Run `cargo build`. Expected: compiles. If anything still names `py::`, it was missed in Task 4; fix it with the same `{:?}` / `serde_json::to_string` substitutions.

- [ ] **Step 3: Regenerate the golden pages**

Look at the `golden` module in `src/page_tests.rs`. If its tests *compare* against the fixture files, regenerate by temporarily replacing each `assert_eq!(out, include_str!(…))` with `std::fs::write("tests/fixtures/golden_page….html", &out).unwrap();`, run `cargo test page_tests::golden`, then restore the comparisons. If they already *write* the files (as in the working tree on 2026-11-02), first change them back to comparing against the files with `assert_eq!`, then regenerate the same way, so that afterwards they guard the output again.

Inspect the diff: `git diff --stat tests/fixtures/` and `git diff tests/fixtures/golden_page.html | grep '^[-+]' | grep -v '^[-+][-+]' | head -40`.
Expected: only JSON spacing inside `data-`/`x-` attributes (`[&quot;a&quot;, &quot;b&quot;]` → `[&quot;a&quot;,&quot;b&quot;]`) and raw UTF-8 where Python wrote `\uNNNN`. Any other change is a regression: fix `e` or `json`, don't accept it.

Update the `golden` module doc from "Byte-for-byte against page.py" to `/// tests/fixtures/golden_page*.html pin the rendered page for this state.`

- [ ] **Step 4: Check the page still works in a browser**

Run: `cargo test` (full). Then render a page and confirm Alpine reads the new JSON. `page.js` parses these attributes with `JSON.parse` or Alpine expressions; both accept compact JSON. Run `grep -n "JSON.parse\|data-keys\|toggleTag" assets/page.js` and check that every consumer parses JSON rather than splitting on `", "`.

- [ ] **Step 5: Final sweep**

Run:
```bash
grep -rn "Python\|python\|py::\|repr(\|truthy\|byte-identical" src --include=*.rs
cargo clippy --all-targets -- -D warnings
cargo fmt --check
```
Expected: no `py::`, `truthy` or `byte-identical`. Remaining "Python" mentions are historical comments; rewrite any that describe *current* behaviour as "as the Python did" in present terms, and leave references to the port's history in module docs only.

- [ ] **Step 6: Commit**

```bash
git add -A src tests
git commit -m "refactor(galactica): plab drops its Python parity shims"
```

---

### Task 6: Build and verify on galactica

**Files:** none.

- [ ] **Step 1: Nix build**

From the repo root: `nix build .#nixosConfigurations.galactica.config.system.build.toplevel` (one host, as the user's no-parallel-evals rule requires). Expected: builds; plab's `checkPhase` runs `cargo test`.

- [ ] **Step 2: Push and deploy**

Ask the user before pushing and deploying. On approval: `git push -u origin master`, then `just deploy galactica` from raider.

- [ ] **Step 3: Watch one identify pass**

On galactica: `journalctl -u plab -f` (or the identify unit `systemctl list-units 'plab*'` names). Wait for a sweep or trigger one by dropping a file into a watched folder. Expected: `llm step: N scene(s)` lines, proposal lines in the new format (`codedb (jev conf=0.91) | "Title" | Studio | A, B | Δ-2s`), no deserialization errors (`… in the Stash reply`). Then open the page and check that recent downloads still show their provenance badges.

---

## Self-review notes

- Spec coverage: domain types (Tasks 1–3), `Proposal` enum and `Outcome` (Task 3), `JobOptions` kept opaque (Task 1), mixed types via `de::lenient_f64` on durations, plus seeders and confidence, where the wire format is a number that may arrive as text (Tasks 1, 3, 4), prompts as serde JSON (Task 2's `summary`, Task 3's `Input`), Rust log formatting (Tasks 3–4), errors naming the query (Task 1's `query`), golden regeneration (Task 5), live check (Task 6).
- Deviations from the spec, both small: `Gender` uses `FromStr` rather than `#[serde(other)]`, since they are parsed from scraped free text, not deserialized from a Stash enum; and `strip_nulls` survives as `JobOptions`' private deserializer, because the blob is replayed as a job input.
- Instruction prompt texts are untouched; `prompts_match_the_fixtures` guards them, so their fixture files do not change.
