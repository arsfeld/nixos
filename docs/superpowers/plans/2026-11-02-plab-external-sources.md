# plab external sources Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The curated view also shows releases from the other indexers Prowlarr has (for
filter terms marked `@`), with scene-database images, streamable and addable like
tracker cards. The curated searches become a daily job.

**Architecture:**
- A new daily `curated` job runs every curated term on the tracker and every `@` term
  through Prowlarr.
- For the Prowlarr results, it collapses variants, drops duplicates of tracker hits,
  classifies, looks up images, and stores everything in `curated_hit`. Then it rebuilds
  the video list.
- Releases from other indexers get plab ids from `1 << 40` up, through `external_release`,
  so every existing id-keyed path keeps working. Only fetching the torrent and the images
  branches on `db::is_external(id)`.

**Tech Stack:** Rust (tokio, reqwest, rusqlite, regex, chrono, wiremock), Svelte 5 +
TypeScript (vitest, svelte-check), NixOS module, sops-nix.

**Spec:** `docs/superpowers/specs/2026-11-02-plab-external-sources-design.md`

## Global Constraints

- **No explicit content anywhere in the repository.** That covers code, comments, tests,
  fixtures, commit messages and this plan's follow-ups. Use neutral words ("the tracker",
  "other indexers", "the scene database") and placeholder values (`alpha`, `Group A`,
  `Indexer A`, `Primary`, `noisea`). Indexer names, category ids, the scene-database URL
  and title vocabulary exist only in the `plab-sources` sops secret and at runtime.
- Work on `master`, with no branches or worktrees. Use conventional commits with scope
  `galactica`, and never mention Claude. Never `git stash`. Stage files by explicit path,
  because another session may have uncommitted work in this checkout.
- From `packages/plab`, `cargo test` must pass. Record the count in Task 1 and expect it
  to grow. `cargo clippy --all-targets -- -D warnings` may show only the 3 pre-existing
  `collapsible_if` errors in `src/identify/matching.rs`.
- From `packages/plab/ui`, `npm run check` and `npm test` must pass. The package build
  runs both, together with `cargo test`.
- New files must be `git add`ed before any `nix build`, because flakes see only tracked
  files.
- External ids are `>= 1 << 40` (`db::EXTERNAL_BASE`). `db::is_external(id)` is the only
  test of that range.
- The env var is `PLAB_SOURCES_FILE`, pointing at the sops secret `plab-sources`. Its keys
  are `primary_indexer`, `categories`, `scene_url` and `noise`.
- `curated` runs every 24 h at offset 07:00 UTC, over a 32-day window, 20 results per
  tracker term. `refresh` stays at 3 h and does no searches.
- An external release in the class `industrial` is dropped. One whose classification
  fails is held back until the next run. With no classifier configured, the external
  pass is skipped.

---

## File Structure

| File | Responsibility |
|---|---|
| `src/filters.rs` | `Term { text, elsewhere }`, `load_filter_terms`; `load_filters` unchanged for callers |
| `src/sources.rs` (new) | parse the `plab-sources` file into `Sources` |
| `src/config.rs` | `sources_file` from `PLAB_SOURCES_FILE` |
| `src/db/schema_v5.sql` (new), `src/db/mod.rs` | `curated_hit`, `external_release`; `EXTERNAL_BASE`, `is_external`, upsert/lookup/save methods; prune keeps curated topics |
| `src/external.rs` (new) | pure title work: `words`, `title_key`, `release_date`, `person_tokens`, `scene_query`, `collapse`, `is_duplicate`, `Candidate` |
| `src/prowlarr.rs` | result gains `guid`, `info_url`, `leechers`, `size`; `indexers()`, `search_in()` |
| `src/scenes.rs` (new) | scene-database search client `SceneDb`, `accept()` |
| `src/curated.rs` (new) | the `curated` job |
| `src/plab.rs` | `Ctx.prowlarr`; `refresh` reads `curated_hit` instead of searching; external images and Add |
| `src/plab_tests.rs` | curated tests; refresh tests adjusted |
| `src/jobs.rs`, `src/commands.rs`, `src/main.rs`, `src/app.rs` | `CURATED` schedule, the daemon task, `plab curated`, a shared `Prowlarr` |
| `src/rqbit.rs`, `src/stream.rs`, `src/web.rs` | magnet support, external torrent source, `WebState.prowlarr` |
| `src/api.rs`, `ui/src/lib/types.ts`, `ui/src/components/Card.svelte` | `source` and `link` on a card |
| `modules/hosts/galactica/services/plab/default.nix`, `secrets/sops/galactica.yaml` | `PLAB_SOURCES_FILE`, the `plab-sources` secret |

---

### Task 1: Verify rqbit accepts a magnet, record the baseline

There is no commit in this task. It settles the one unverified assumption in the spec.

**Files:** none

- [ ] **Step 1: Record the baseline test count**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "^test result" | awk '{s+=$4} END {print s}'`
Expected: a number. Write it down; later tasks compare against it.

- [ ] **Step 2: Ask rqbit for the file list of a public-domain magnet**

The engine listens inside the VPN namespace and is reachable from galactica's host
through `PLAB_RQBIT_URL`. Use the Blender Foundation's open movie *Big Buck Bunny*
(public domain, a WebTorrent demo torrent):

```bash
ssh galactica.bat-boa.ts.net bash -s <<'EOF'
U=$(systemctl show plab -p Environment --value | tr ' ' '\n' | grep -oP '(?<=PLAB_RQBIT_URL=).*')
[ -z "$U" ] && U=$(sudo grep -oP 'PLAB_RQBIT_URL="\K[^"]+' /etc/systemd/system/plab.service)
echo "rqbit at $U"
time curl -s -m 150 -X POST "$U/torrents?list_only=true" \
  --data-binary 'magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337' \
  | jq '{hash: .details.info_hash, files: [.details.files[]?.name]}'
EOF
```

Expected: an info hash and a file list including `Big Buck Bunny.mp4`, typically within
5–60 s.
- If the URL lookup prints nothing, read the value from `systemctl cat plab`.
- If rqbit answers `400` or refuses the body, stop and report it. Task 10's magnet path
  would need a different call (rqbit's JSON form), and the plan must be revised before
  that task.

---

### Task 2: `@` terms in the filter file

**Files:**
- Modify: `packages/plab/src/filters.rs`

**Interfaces:**
- Produces: `pub struct Term { pub text: String, pub elsewhere: bool }`,
  `pub type FilterTerms = Vec<(String, Vec<Term>)>`,
  `pub fn load_filter_terms(path: Option<&Path>, state_dir: Option<&Path>) -> FilterTerms`.
  `load_filters` keeps its signature and returns terms with the `@` stripped.

- [ ] **Step 1: Write the failing tests** (append inside `mod tests` in `filters.rs`)

```rust
    #[test]
    fn at_marks_a_term_for_other_indexers_and_is_stripped() {
        let dir = tempfile::tempdir().unwrap();
        let p = write(
            &dir,
            "f.txt",
            "[Group A]\n@alpha\nbeta\n@\"two words\"\n[Group B]\n@ gamma\n",
        );
        let terms = load_filter_terms(Some(&p), None);
        let t = |text: &str, elsewhere| Term { text: text.into(), elsewhere };
        assert_eq!(
            terms,
            vec![
                (
                    "Group A".to_string(),
                    vec![t("alpha", true), t("beta", false), t("\"two words\"", true)]
                ),
                ("Group B".to_string(), vec![t("gamma", true)]),
            ]
        );
        // Callers that only search and match see the bare terms.
        assert_eq!(
            load_filters(Some(&p), None),
            vec![
                (
                    "Group A".to_string(),
                    vec!["alpha".to_string(), "beta".into(), "\"two words\"".into()]
                ),
                ("Group B".to_string(), vec!["gamma".to_string()]),
            ]
        );
    }

    #[test]
    fn a_lone_at_is_not_a_term() {
        let dir = tempfile::tempdir().unwrap();
        let p = write(&dir, "f.txt", "[Group A]\n@\nalpha\n");
        assert_eq!(
            load_filter_terms(Some(&p), None),
            vec![(
                "Group A".to_string(),
                vec![Term { text: "alpha".into(), elsewhere: false }]
            )]
        );
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/plab && cargo test filters:: 2>&1 | tail -5`
Expected: compile error, `cannot find function load_filter_terms`.

- [ ] **Step 3: Implement**

In `filters.rs`, replace the body of `load_filters` and add the new items above it:

```rust
/// A filter's search term. `elsewhere`: written `@term`, it is searched through Prowlarr's
/// other indexers as well as on the tracker.
#[derive(Debug, Clone, PartialEq)]
pub struct Term {
    pub text: String,
    pub elsewhere: bool,
}

pub type FilterTerms = Vec<(String, Vec<Term>)>;

fn parse_filters(text: &str) -> FilterTerms {
    let mut filters: FilterTerms = vec![];
    let mut name = "Curated".to_string();
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') && line.len() >= 2 {
            let n = line[1..line.len() - 1].trim();
            name = if n.is_empty() { "Curated" } else { n }.to_string();
            continue;
        }
        let term = match line.strip_prefix('@') {
            Some(rest) => Term { text: rest.trim().to_string(), elsewhere: true },
            None => Term { text: line.to_string(), elsewhere: false },
        };
        if term.text.is_empty() {
            continue;
        }
        if let Some((_, terms)) = filters.iter_mut().find(|(n, _)| *n == name) {
            terms.push(term);
        } else {
            filters.push((name.clone(), vec![term]));
        }
    }
    filters
}

/// The curated filters with each term's `@` flag; see `load_filters` for the file.
pub fn load_filter_terms(path: Option<&Path>, state_dir: Option<&Path>) -> FilterTerms {
    let Some(path) = resolve(path, state_dir, "filter.txt") else {
        return vec![];
    };
    read_text(&path).map_or_else(Vec::new, |t| parse_filters(&t))
}
```

Keep the existing doc comment on `load_filters` and add one sentence to it: "A term
written `@term` is also searched on other indexers (see `load_filter_terms`); here the
`@` is stripped." The new body:

```rust
pub fn load_filters(path: Option<&Path>, state_dir: Option<&Path>) -> Filters {
    load_filter_terms(path, state_dir)
        .into_iter()
        .map(|(name, terms)| (name, terms.into_iter().map(|t| t.text).collect()))
        .collect()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass. The count is the baseline plus 2.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/filters.rs
git commit -m "feat(galactica): plab filter terms marked @ for other indexers"
```

---

### Task 3: The `plab-sources` file

**Files:**
- Create: `packages/plab/src/sources.rs`
- Modify: `packages/plab/src/main.rs` (add `mod sources;`), `packages/plab/src/config.rs`

**Interfaces:**
- Produces: `pub struct Sources { pub primary_indexer: Option<String>, pub categories: Vec<u32>, pub scene_url: Option<String>, pub noise: Vec<String> }`,
  `pub fn sources::parse(text: &str) -> Sources`,
  `pub fn sources::load(path: Option<&Path>) -> Option<Sources>` (None without a file or
  without `categories`), and `Config.sources_file: Option<PathBuf>`.

- [ ] **Step 1: Write `sources.rs` with failing tests first**

```rust
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
        v.split(',').map(str::trim).filter(|x| !x.is_empty()).map(String::from).collect()
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
    let Some(path) = path.filter(|p| p.is_file()) else {
        tracing::info!("no plab-sources file: curated searches the tracker only");
        return None;
    };
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
```

Add `mod sources;` to `main.rs`, in alphabetical order between `prune` and `stash`.

- [ ] **Step 2: Add the config field, with a test**

In `config.rs`, add `pub sources_file: Option<PathBuf>,` to `Config` after `filter_file`,
and in `from_env`, `sources_file: path("PLAB_SOURCES_FILE"),` after `filter_file`. In
the existing test that sets every variable (the one asserting `c.prowlarr_url ==
"http://prowlarr"`), add `("PLAB_SOURCES_FILE", "/sources")` to its pairs and
`assert_eq!(c.sources_file, Some(p("/sources")));`. In `config_defaults`, add
`assert_eq!(c.sources_file, None);`.

- [ ] **Step 3: Run the tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass, with 2 new `sources::` tests.

- [ ] **Step 4: Commit**

```bash
git add packages/plab/src/sources.rs packages/plab/src/main.rs packages/plab/src/config.rs
git commit -m "feat(galactica): plab reads its external-source settings from PLAB_SOURCES_FILE"
```

---

### Task 4: Schema v5 and the database methods

**Files:**
- Create: `packages/plab/src/db/schema_v5.sql`
- Modify: `packages/plab/src/db/mod.rs`
- Modify: `docs/superpowers/specs/2026-11-02-plab-external-sources-design.md` (amendments, Step 6)

**Interfaces:**
- Produces, all in `crate::db`:
  - `pub const EXTERNAL_BASE: u64 = 1 << 40;`
  - `pub fn is_external(id: u64) -> bool`
  - `pub struct External { pub id: u64, pub indexer: String, pub link: String, pub info_url: Option<String>, pub scene_id: Option<String> }`
  - `pub struct NewExternal<'a> { pub indexer: &'a str, pub guid: &'a str, pub link: &'a str, pub info_url: Option<&'a str> }`
  - `pub struct CuratedHit { pub topic_id: u64, pub filter: String, pub reason: String }`
  - `Db::upsert_external(&self, e: &NewExternal<'_>) -> Result<u64>`
  - `Db::external(&self, id: u64) -> Result<Option<External>>`
  - `Db::externals(&self) -> Result<HashMap<u64, External>>`
  - `Db::set_scene(&self, id: u64, scene_id: &str) -> Result<()>`
  - `Db::topic(&self, id: u64) -> Result<Option<Topic>>`
  - `Db::save_curated(&self, topics: &[Topic], hits: &[CuratedHit], now: i64) -> Result<()>`
  - `Db::curated_hits(&self) -> Result<Vec<(Topic, String, String)>>` (topic, filter, reason, in insertion order)

- [ ] **Step 1: Write `schema_v5.sql`**

```sql
-- The last curated run's hits; refresh merges them into the video list. The curated job
-- replaces the whole table in one transaction.
CREATE TABLE curated_hit (
  topic_id INTEGER NOT NULL REFERENCES topic(id),
  filter TEXT NOT NULL,
  reason TEXT NOT NULL,            -- the term that found it: the card's badge
  PRIMARY KEY (topic_id, filter)
);

-- A release from an indexer other than the tracker, and the plab id it is known by.
-- Ids start at 1<<40, far above any tracker topic id.
CREATE TABLE external_release (
  id INTEGER PRIMARY KEY,
  indexer TEXT NOT NULL,
  guid TEXT NOT NULL,
  link TEXT NOT NULL,              -- Prowlarr download URL: yields a .torrent or a magnet
  info_url TEXT,                   -- the release's page, for the card's link
  scene_id TEXT,                   -- the scene database's id; NULL = not matched (yet)
  UNIQUE (indexer, guid)
);
```

- [ ] **Step 2: Write the failing tests** (append inside `mod tests` in `db/mod.rs`; they
  reuse its existing `row(id, title)` helper)

```rust
    fn topic(id: u64, title: &str) -> Topic {
        Topic { row: row(id, title), images: None, production: None }
    }

    fn new_ext<'a>(guid: &'a str, link: &'a str) -> NewExternal<'a> {
        NewExternal { indexer: "Indexer A", guid, link, info_url: Some("http://a/1") }
    }

    #[test]
    fn external_ids_start_at_the_base_and_are_stable_per_guid() {
        let db = Db::open_in_memory().unwrap();
        let a = db.upsert_external(&new_ext("g1", "http://p/1")).unwrap();
        let b = db.upsert_external(&new_ext("g2", "http://p/2")).unwrap();
        assert_eq!(a, EXTERNAL_BASE);
        assert_eq!(b, EXTERNAL_BASE + 1);
        assert!(is_external(a) && !is_external(7_000_000));
        // Same (indexer, guid): same id, link refreshed.
        assert_eq!(db.upsert_external(&new_ext("g1", "http://p/9")).unwrap(), a);
        let e = db.external(a).unwrap().unwrap();
        assert_eq!((e.indexer.as_str(), e.link.as_str()), ("Indexer A", "http://p/9"));
        assert_eq!(e.info_url.as_deref(), Some("http://a/1"));
        db.set_scene(a, "s1").unwrap();
        assert_eq!(db.externals().unwrap()[&a].scene_id.as_deref(), Some("s1"));
    }

    #[test]
    fn save_curated_replaces_the_hits_and_keeps_images() {
        let db = Db::open_in_memory().unwrap();
        let mut t1 = topic(1, "one");
        t1.images = Some(vec!["http://i/1.jpg".into()]);
        let hit = |id, f: &str| CuratedHit { topic_id: id, filter: f.into(), reason: "Alpha".into() };
        db.save_curated(&[t1, topic(2, "two")], &[hit(2, "B"), hit(1, "A")], NOW).unwrap();
        let hits = db.curated_hits().unwrap();
        assert_eq!(
            hits.iter().map(|(t, f, _)| (t.row.id, f.as_str())).collect::<Vec<_>>(),
            vec![(2, "B"), (1, "A")]
        );
        // A later run without images must not erase them; its hits replace the old ones.
        db.save_curated(&[topic(1, "one")], &[hit(1, "A")], NOW).unwrap();
        let hits = db.curated_hits().unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].0.images, Some(vec!["http://i/1.jpg".to_string()]));
        assert_eq!(db.topic(1).unwrap().unwrap().row.title, "one");
        assert_eq!(db.topic(99).unwrap(), None);
    }

    #[test]
    fn prune_keeps_curated_topics_and_drops_orphan_external_rows() {
        let db = Db::open_in_memory().unwrap();
        let ext = db.upsert_external(&new_ext("g1", "http://p/1")).unwrap();
        let gone = db.upsert_external(&new_ext("g2", "http://p/2")).unwrap();
        db.save_curated(
            &[topic(ext, "kept"), topic(gone, "dropped")],
            &[CuratedHit { topic_id: ext, filter: "A".into(), reason: "Alpha".into() }],
            NOW,
        )
        .unwrap();
        // A listing that contains neither: the curated one survives, the other goes.
        db.save_listing(Section::Video, &[], &[], NOW).unwrap();
        assert!(db.topic(ext).unwrap().is_some());
        assert!(db.topic(gone).unwrap().is_none());
        assert!(db.external(gone).unwrap().is_none());
        assert!(db.external(ext).unwrap().is_some());
    }
```

If `NOW` is not defined in that test module, add `const NOW: i64 = 1_800_000_000;` at
its top.

- [ ] **Step 3: Run them to verify they fail**

Run: `cd packages/plab && cargo test db:: 2>&1 | tail -5`
Expected: compile errors (`EXTERNAL_BASE`, `NewExternal`, … not found).

- [ ] **Step 4: Implement**

In `db/mod.rs`:
- Add `const SCHEMA_V5: &str = include_str!("schema_v5.sql");` and set `USER_VERSION`
  to `5`.
- In `migrate`, after the `from < 4` step, add
  `if from < 5 { tx.execute_batch(SCHEMA_V5)?; }`.

Add near the top, after `IDENTIFY_FAILURE_LIMIT`:

```rust
/// The first plab id of a release from another indexer: far above any tracker topic id,
/// and exact in JavaScript (below 2^53), so the ids pass through the API unchanged.
pub const EXTERNAL_BASE: u64 = 1 << 40;

/// Whether `id` names a release from another indexer rather than a tracker topic.
pub fn is_external(id: u64) -> bool {
    id >= EXTERNAL_BASE
}

/// A release from another indexer, as `external_release` holds it.
#[derive(Debug, Clone, PartialEq)]
pub struct External {
    pub id: u64,
    pub indexer: String,
    pub link: String,
    pub info_url: Option<String>,
    pub scene_id: Option<String>,
}

pub struct NewExternal<'a> {
    pub indexer: &'a str,
    pub guid: &'a str,
    pub link: &'a str,
    pub info_url: Option<&'a str>,
}

/// One curated hit: `topic_id` was found for `filter` by the term whose badge is `reason`.
#[derive(Debug, Clone, PartialEq)]
pub struct CuratedHit {
    pub topic_id: u64,
    pub filter: String,
    pub reason: String,
}
```

In `save_listing`, extend the topic prune and drop orphaned external rows. Replace the
`DELETE FROM topic …` execute with:

```rust
            tx.execute(
                "DELETE FROM topic WHERE id NOT IN (SELECT topic_id FROM listing)
                   AND id NOT IN (SELECT topic_id FROM search_hit)
                   AND id NOT IN (SELECT topic_id FROM curated_hit)
                   AND id NOT IN (SELECT topic_id FROM download WHERE topic_id IS NOT NULL)",
                [],
            )?;
            tx.execute("DELETE FROM external_release WHERE id NOT IN (SELECT id FROM topic)", [])?;
```

Add a new section before `// torrent files`:

```rust
    // curated hits and external releases

    /// Insert the topics (images and production kept when `None`) and replace every
    /// curated hit with `hits`, in one transaction.
    pub fn save_curated(&self, topics: &[Topic], hits: &[CuratedHit], now: i64) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for t in topics {
                let images = t.images.as_ref().map(serde_json::to_string).transpose()?;
                let production = t.production.as_ref().map(serde_json::to_string).transpose()?;
                upsert_topic(&tx, &t.row, images.as_deref(), production.as_deref(), now)?;
            }
            tx.execute("DELETE FROM curated_hit", [])?;
            for h in hits {
                tx.execute(
                    "INSERT OR IGNORE INTO curated_hit (topic_id, filter, reason) VALUES (?1, ?2, ?3)",
                    params![h.topic_id, h.filter, h.reason],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    /// Every curated hit with its topic, in the order the last run stored them.
    pub fn curated_hits(&self) -> Result<Vec<(Topic, String, String)>> {
        self.with(|c| {
            let sql = format!(
                "SELECT {TOPIC_COLS}, h.filter, h.reason FROM curated_hit h
                 JOIN topic t ON t.id = h.topic_id ORDER BY h.rowid"
            );
            let mut stmt = c.prepare(&sql)?;
            let raw = stmt
                .query_map([], |r| Ok((raw_topic(r)?, r.get::<_, String>(10)?, r.get::<_, String>(11)?)))?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            raw.into_iter().map(|(t, f, why)| Ok((topic_of(t)?, f, why))).collect()
        })
    }

    pub fn topic(&self, id: u64) -> Result<Option<Topic>> {
        self.with(|c| {
            let sql = format!("SELECT {TOPIC_COLS} FROM topic t WHERE t.id = ?1");
            let raw = c.query_row(&sql, [id], raw_topic).optional()?;
            raw.map(topic_of).transpose()
        })
    }

    /// The plab id of (indexer, guid), allocated from `EXTERNAL_BASE` on first sight; the
    /// link and page are refreshed every time.
    pub fn upsert_external(&self, e: &NewExternal<'_>) -> Result<u64> {
        self.with(|c| {
            Ok(c.query_row(
                "INSERT INTO external_release (id, indexer, guid, link, info_url)
                 VALUES (COALESCE((SELECT MAX(id) + 1 FROM external_release), ?5), ?1, ?2, ?3, ?4)
                 ON CONFLICT(indexer, guid) DO UPDATE SET link = excluded.link, info_url = excluded.info_url
                 RETURNING id",
                params![e.indexer, e.guid, e.link, e.info_url, EXTERNAL_BASE],
                |r| r.get(0),
            )?)
        })
    }

    pub fn external(&self, id: u64) -> Result<Option<External>> {
        Ok(self.externals_where("WHERE id = ?1", Some(id))?.remove(&id))
    }

    /// Every external release, by id. The table holds only what the lists show.
    pub fn externals(&self) -> Result<HashMap<u64, External>> {
        self.externals_where("", None)
    }

    fn externals_where(&self, filter: &str, id: Option<u64>) -> Result<HashMap<u64, External>> {
        self.with(|c| {
            let sql = format!("SELECT id, indexer, link, info_url, scene_id FROM external_release {filter}");
            let mut stmt = c.prepare(&sql)?;
            let map = |r: &rusqlite::Row<'_>| {
                Ok(External {
                    id: r.get(0)?,
                    indexer: r.get(1)?,
                    link: r.get(2)?,
                    info_url: r.get(3)?,
                    scene_id: r.get(4)?,
                })
            };
            let rows = match id {
                Some(id) => stmt.query_map([id], map)?.collect::<rusqlite::Result<Vec<_>>>()?,
                None => stmt.query_map([], map)?.collect::<rusqlite::Result<Vec<_>>>()?,
            };
            Ok(rows.into_iter().map(|e| (e.id, e)).collect())
        })
    }

    pub fn set_scene(&self, id: u64, scene_id: &str) -> Result<()> {
        self.with(|c| {
            c.execute("UPDATE external_release SET scene_id = ?1 WHERE id = ?2", params![scene_id, id])?;
            Ok(())
        })
    }
```

- [ ] **Step 5: Run the tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass. `migrations_set_user_version` now sees 5.

- [ ] **Step 6: Amend the spec to match the plan**

Edit the spec as follows:
- In "Data", remove the `ALTER TABLE topic ADD COLUMN source …` line and the bullet about
  `topic.source`, and add `info_url TEXT` to `external_release` with the comment "the
  release's page, for the card's link". The card's indexer badge and link come from
  `external_release`; `topic` is unchanged.
- In "The `curated` job" step 6, delete "`source` = the indexer,".
- Add a step 9: "**Rebuild.** `refresh` of the video list runs, so the hits show at once."
- In "Classify", say the category passed is the tracker's `Other` (forum 0), and that
  with no classifier configured the external pass is skipped.
- In "Error handling", change the magnet row's status to `502 no peers for metadata`.
  The gateway replaces some 5xx bodies, and 502 is the status plab already uses for
  engine errors.

- [ ] **Step 7: Commit**

```bash
git add packages/plab/src/db/schema_v5.sql packages/plab/src/db/mod.rs docs/superpowers/specs/2026-11-02-plab-external-sources-design.md
git commit -m "feat(galactica): plab stores curated hits and releases from other indexers"
```

---

### Task 5: Title work for releases from other indexers

**Files:**
- Create: `packages/plab/src/external.rs`
- Modify: `packages/plab/src/main.rs` (add `mod external;` between `events` and `filters`)

**Interfaces:**
- Produces, in `crate::external`:
  - `pub struct Candidate { pub indexer: String, pub guid: String, pub link: String, pub info_url: Option<String>, pub title: String, pub size: u64, pub seeders: u32, pub leechers: u32, pub published: i64 }`
  - `pub fn words(title: &str, noise: &[String]) -> Vec<String>`
  - `pub fn title_key(title: &str, noise: &[String]) -> String`
  - `pub fn release_date(title: &str) -> Option<chrono::NaiveDate>`
  - `pub fn person_tokens(title: &str, term: &str, noise: &[String]) -> HashSet<String>`
  - `pub fn scene_query(title: &str, noise: &[String]) -> String`
  - `pub fn collapse(found: Vec<Candidate>, noise: &[String]) -> Vec<Candidate>`
  - `pub fn is_duplicate(title: &str, tracker_titles: &[&str], term: &str, noise: &[String]) -> bool`

- [ ] **Step 1: Write `external.rs` with its tests**

```rust
//! Releases from indexers other than the tracker: comparing titles, collapsing one
//! release's variants (resolutions, re-uploads), and recognizing a release the tracker
//! already has. Pure functions; `curated.rs` runs them.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use chrono::NaiveDate;
use regex::Regex;

/// One search result from another indexer, as the curated job keeps it.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub indexer: String,
    pub guid: String,
    pub link: String,
    pub info_url: Option<String>,
    pub title: String,
    pub size: u64,
    pub seeders: u32,
    pub leechers: u32,
    /// Unix seconds.
    pub published: i64,
}

const CONTAINERS: [&str; 8] = ["mp4", "mkv", "avi", "wmv", "mov", "m4v", "ts", "webm"];
/// Words that never tell two releases apart.
const STOP: [&str; 7] = ["and", "the", "with", "part", "episode", "scene", "feat"];

fn re(p: &str) -> Regex {
    Regex::new(p).unwrap()
}

static GROUPS: LazyLock<Regex> = LazyLock::new(|| re(r"\[[^\]]*\]|\([^)]*\)"));
static RESOLUTION: LazyLock<Regex> = LazyLock::new(|| re(r"^\d{3,4}p$"));
static EPISODE: LazyLock<Regex> = LazyLock::new(|| re(r"^e\d+$"));
static YMD: LazyLock<Regex> = LazyLock::new(|| re(r"\b(20\d{2})[.\- ](\d{2})[.\- ](\d{2})\b"));
static DMY: LazyLock<Regex> = LazyLock::new(|| re(r"\b(\d{2})\.(\d{2})\.(20\d{2})\b"));
static SHORT: LazyLock<Regex> = LazyLock::new(|| re(r"\b(\d{2})[. ](\d{2})[. ](\d{2})\b"));

/// A trailing release-group tag: two or more characters, upper-case letters and digits
/// only, at least one letter.
fn is_group_tag(w: &str) -> bool {
    w.len() >= 2
        && w.chars().any(|c| c.is_ascii_uppercase())
        && w.chars().all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

/// The title's comparable words, lower-cased: bracketed and parenthesized groups,
/// trailing release-group tags, resolutions, container names and `noise` removed.
pub fn words(title: &str, noise: &[String]) -> Vec<String> {
    let bare = GROUPS.replace_all(title, " ");
    let mut raw: Vec<String> = bare
        .split(|c: char| c.is_whitespace() || matches!(c, '.' | '_' | '-' | ','))
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()).to_string())
        .filter(|w| !w.is_empty())
        .collect();
    while raw.last().is_some_and(|w| is_group_tag(w)) {
        raw.pop();
    }
    raw.into_iter()
        .map(|w| w.to_lowercase())
        .filter(|w| {
            !RESOLUTION.is_match(w)
                && !CONTAINERS.contains(&w.as_str())
                && !noise.iter().any(|n| n == w)
        })
        .collect()
}

/// Titles with the same key are variants of one release.
pub fn title_key(title: &str, noise: &[String]) -> String {
    words(title, noise).join(" ")
}

fn ymd(y: &str, m: &str, d: &str) -> Option<NaiveDate> {
    NaiveDate::from_ymd_opt(y.parse().ok()?, m.parse().ok()?, d.parse().ok()?)
}

/// The release date a title carries: `YYYY.MM.DD` (or `-`/space), `DD.MM.YYYY`, or
/// `YY MM DD` (read as 20YY).
pub fn release_date(title: &str) -> Option<NaiveDate> {
    if let Some(c) = YMD.captures(title)
        && let Some(d) = ymd(&c[1], &c[2], &c[3])
    {
        return Some(d);
    }
    if let Some(c) = DMY.captures(title)
        && let Some(d) = ymd(&c[3], &c[2], &c[1])
    {
        return Some(d);
    }
    let c = SHORT.captures(title)?;
    ymd(&format!("20{}", &c[1]), &c[2], &c[3])
}

/// Words likely to be names: comparable words of three or more letters, minus the term's
/// own words, numbers and `STOP` words.
pub fn person_tokens(title: &str, term: &str, noise: &[String]) -> HashSet<String> {
    let term_words: HashSet<String> = words(term, &[]).into_iter().collect();
    words(title, noise)
        .into_iter()
        .filter(|w| w.chars().count() >= 3 && w.chars().all(char::is_alphabetic))
        .filter(|w| !term_words.contains(w) && !STOP.contains(&w.as_str()))
        .collect()
}

/// The query for the scene database: the comparable words without an episode token,
/// and the release date, if any, appended as `YYYY-MM-DD`.
pub fn scene_query(title: &str, noise: &[String]) -> String {
    let date = release_date(title);
    let mut stripped = title.to_string();
    for pattern in [&*YMD, &*DMY, &*SHORT] {
        stripped = pattern.replace(&stripped, " ").into_owned();
    }
    let mut out: Vec<String> = words(&stripped, noise)
        .into_iter()
        .filter(|w| !EPISODE.is_match(w))
        .collect();
    if let Some(d) = date {
        out.push(d.format("%Y-%m-%d").to_string());
    }
    out.join(" ")
}

/// One candidate per release: of the variants sharing a `title_key`, the best seeded,
/// at the position of the first seen.
pub fn collapse(found: Vec<Candidate>, noise: &[String]) -> Vec<Candidate> {
    let mut out: Vec<Candidate> = vec![];
    let mut at: HashMap<String, usize> = HashMap::new();
    for c in found {
        let key = title_key(&c.title, noise);
        match at.get(&key) {
            Some(&i) if out[i].seeders >= c.seeders => {}
            Some(&i) => out[i] = c,
            None => {
                at.insert(key, out.len());
                out.push(c);
            }
        }
    }
    out
}

/// Whether the tracker already has this release: a tracker title of the same filter with
/// the same date and at least one name in common. No readable date: never a duplicate.
pub fn is_duplicate(title: &str, tracker_titles: &[&str], term: &str, noise: &[String]) -> bool {
    let Some(date) = release_date(title) else {
        return false;
    };
    let names = person_tokens(title, term, noise);
    tracker_titles.iter().any(|t| {
        release_date(t) == Some(date) && !person_tokens(t, term, noise).is_disjoint(&names)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noise() -> Vec<String> {
        vec!["noisea".into()]
    }

    fn cand(title: &str, seeders: u32) -> Candidate {
        Candidate {
            indexer: "Indexer A".into(),
            guid: title.into(),
            link: format!("http://p/{seeders}"),
            info_url: None,
            title: title.into(),
            size: 1,
            seeders,
            leechers: 0,
            published: 0,
        }
    }

    #[test]
    fn variants_share_a_key() {
        let a = title_key("Alpha E0012 Ann And Ben Lazy Sunday 1080p MP4 P2P [GR]", &noise());
        let b = title_key("Alpha.E0012.Ann.And.Ben.Lazy.Sunday.480p.MP4.P2P", &noise());
        assert_eq!(a, "alpha e0012 ann and ben lazy sunday");
        assert_eq!(a, b);
        assert_eq!(title_key("Alpha Lazy Sunday NoiseA 720p", &noise()), "alpha lazy sunday");
        // Part 2 is not a tag: digits only.
        assert_eq!(title_key("Alpha Lazy Sunday Part 2", &[]), "alpha lazy sunday part 2");
    }

    #[test]
    fn dates_in_three_styles() {
        let d = NaiveDate::from_ymd_opt(2026, 10, 24);
        assert_eq!(release_date("Alpha 26 10 24 Ann And Ben"), d);
        assert_eq!(release_date("[Alpha.com] Ann Doe - Lazy (24.10.2026)"), d);
        assert_eq!(release_date("[Alpha.com] Ann - Lazy [2026-10-24, tags]"), d);
        assert_eq!(release_date("Alpha.2026.10.24.Ann"), d);
        assert_eq!(release_date("Alpha Lazy Sunday 1080p"), None);
        assert_eq!(release_date("Alpha 26 13 40"), None); // not a date
    }

    #[test]
    fn collapse_keeps_the_best_seeded_variant_in_first_position() {
        let out = collapse(
            vec![
                cand("Alpha Ann Lazy 480p MP4", 5),
                cand("Beta Cat Rain 1080p", 3),
                cand("Alpha.Ann.Lazy.1080p.MP4", 9),
            ],
            &[],
        );
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].seeders, 9);
        assert_eq!(out[1].title, "Beta Cat Rain 1080p");
    }

    #[test]
    fn a_tracker_release_of_the_same_date_and_names_is_a_duplicate() {
        let tracker = ["[Alpha.com] Ann Doe, Ben Roe - Lazy Sunday (24.10.2026)"];
        let ext = "Alpha 26 10 24 Ann And Ben Lazy Sunday 1080p MP4 [GR]";
        assert!(is_duplicate(ext, &tracker, "alpha", &[]));
        // Other date: kept.
        assert!(!is_duplicate("Alpha 26 10 25 Ann And Ben Lazy Sunday", &tracker, "alpha", &[]));
        // Same date, nobody in common: kept.
        assert!(!is_duplicate("Alpha 26 10 24 Cat Dee Rainy Day", &tracker, "alpha", &[]));
        // No readable date: never a duplicate.
        assert!(!is_duplicate("Alpha Ann And Ben Lazy Sunday", &tracker, "alpha", &[]));
    }

    #[test]
    fn person_tokens_drop_the_term_numbers_and_stop_words() {
        let t = person_tokens("Alpha E0012 Ann And Ben Lazy 26 10 24", "alpha", &[]);
        let want: HashSet<String> = ["ann", "ben", "lazy"].map(String::from).into();
        assert_eq!(t, want);
    }

    #[test]
    fn scene_query_drops_the_episode_and_rewrites_the_date() {
        assert_eq!(
            scene_query("Alpha E0012 26 10 24 Ann And Ben Lazy Sunday 1080p MP4 [GR]", &[]),
            "alpha ann and ben lazy sunday 2026-10-24"
        );
        assert_eq!(scene_query("Alpha Lazy Sunday 720p", &[]), "alpha lazy sunday");
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `cd packages/plab && cargo test external:: 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: 6 pass. If one fails, fix `external.rs`, never the test's expectation, unless
the expectation contradicts the spec.

- [ ] **Step 3: Commit**

```bash
git add packages/plab/src/external.rs packages/plab/src/main.rs
git commit -m "feat(galactica): plab compares release titles across indexers"
```

---

### Task 6: Prowlarr: indexer list and targeted search

**Files:**
- Modify: `packages/plab/src/prowlarr.rs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ProwlarrResult` gains `pub guid: Option<String>`, `pub info_url: Option<String>`,
  `pub leechers: Option<f64>`, `pub size: Option<f64>`;
  `pub struct Indexer { pub id: u32, pub name: String, pub enable: bool, pub protocol: String }`;
  `Prowlarr::indexers(&self) -> Result<Vec<Indexer>>`;
  `Prowlarr::search_in(&self, query: &str, categories: &[u32], indexer_ids: &[u32]) -> Result<Vec<ProwlarrResult>>`.
  `search(query)` stays, as `search_in(query, &[], &[])`.

- [ ] **Step 1: Write the failing tests** (in `prowlarr.rs`'s `mod tests`)

```rust
    #[tokio::test]
    async fn indexers_and_a_targeted_search() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/api/v1/indexer"))
            .and(header("X-Api-Key", "k"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {"id": 1, "name": "Primary", "enable": true, "protocol": "torrent", "extra": 1},
                {"id": 2, "name": "Indexer A", "enable": false, "protocol": "torrent"}
            ])))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(path("/api/v1/search"))
            .and(query_param("query", "alpha"))
            .and(query_param("categories", "100"))
            .and(query_param("indexerIds", "2"))
            .and(query_param("indexerIds", "3"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
                {"title": "Alpha one", "guid": "g1", "infoUrl": "http://a/1", "size": 42,
                 "seeders": 3, "leechers": 1, "protocol": "torrent", "indexer": "Indexer A",
                 "downloadUrl": "http://p/1", "publishDate": "2026-10-30T04:00:00Z"}
            ])))
            .mount(&server)
            .await;
        let p = Prowlarr::new(&server.uri(), "k".into());
        let ix = p.indexers().await.unwrap();
        assert_eq!(
            ix,
            vec![
                Indexer { id: 1, name: "Primary".into(), enable: true, protocol: "torrent".into() },
                Indexer { id: 2, name: "Indexer A".into(), enable: false, protocol: "torrent".into() },
            ]
        );
        let r = p.search_in("alpha", &[100], &[2, 3]).await.unwrap();
        assert_eq!(r.len(), 1);
        assert_eq!(r[0].guid.as_deref(), Some("g1"));
        assert_eq!(r[0].info_url.as_deref(), Some("http://a/1"));
        assert_eq!((r[0].size, r[0].leechers), (Some(42.0), Some(1.0)));
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/plab && cargo test prowlarr:: 2>&1 | tail -5`
Expected: compile error (`Indexer`, `indexers`, `search_in` not found).

- [ ] **Step 3: Implement**

Add the four fields to `ProwlarrResult`, after `seeders`:

```rust
    #[serde(default, deserialize_with = "crate::stash::de::nonempty")]
    pub guid: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::nonempty")]
    pub info_url: Option<String>,
    #[serde(default, deserialize_with = "crate::stash::de::lenient_f64")]
    pub leechers: Option<f64>,
    #[serde(default, deserialize_with = "crate::stash::de::lenient_f64")]
    pub size: Option<f64>,
```

Add the indexer type after `impl ProwlarrResult`:

```rust
/// One of Prowlarr's configured indexers, as the curated job chooses among them.
#[derive(Debug, Clone, PartialEq, serde::Deserialize)]
pub struct Indexer {
    pub id: u32,
    pub name: String,
    #[serde(default)]
    pub enable: bool,
    #[serde(default)]
    pub protocol: String,
}
```

Replace `search` with a shared private GET and the two public calls:

```rust
    async fn get<R: serde::de::DeserializeOwned>(&self, path_and_query: &str) -> Result<R> {
        let resp = self
            .http
            .get(format!("{}{path_and_query}", self.base))
            .header("X-Api-Key", &self.key)
            .send()
            .await
            .map_err(reqwest::Error::without_url)?
            .error_for_status()
            .map_err(reqwest::Error::without_url)?;
        Ok(resp.json().await.map_err(reqwest::Error::without_url)?)
    }

    /// Prowlarr's results for `query` across every enabled indexer.
    pub async fn search(&self, query: &str) -> Result<Vec<ProwlarrResult>> {
        self.search_in(query, &[], &[]).await
    }

    /// Results for `query` limited to `categories` and `indexer_ids` (each empty: no limit).
    pub async fn search_in(
        &self,
        query: &str,
        categories: &[u32],
        indexer_ids: &[u32],
    ) -> Result<Vec<ProwlarrResult>> {
        let mut qs = form_urlencoded::Serializer::new(String::new());
        qs.append_pair("query", query)
            .append_pair("type", "search")
            .append_pair("limit", "100");
        for c in categories {
            qs.append_pair("categories", &c.to_string());
        }
        for i in indexer_ids {
            qs.append_pair("indexerIds", &i.to_string());
        }
        self.get(&format!("/api/v1/search?{}", qs.finish())).await
    }

    pub async fn indexers(&self) -> Result<Vec<Indexer>> {
        self.get("/api/v1/indexer").await
    }
```

- [ ] **Step 4: Run all tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass, including the existing `grab` and `prowlarr` tests.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/prowlarr.rs
git commit -m "feat(galactica): plab lists Prowlarr indexers and searches a chosen few"
```

---

### Task 7: The scene-database client

**Files:**
- Create: `packages/plab/src/scenes.rs`
- Modify: `packages/plab/src/main.rs` (add `mod scenes;` between `provenance` and `prowlarr`;
  keep the existing order otherwise)

**Interfaces:**
- Produces: `pub struct SceneDb`; `SceneDb::new(base: &str, key: &str) -> SceneDb`;
  `SceneDb::search(&self, query: &str) -> anyhow::Result<Option<SceneHit>>`;
  `pub struct SceneHit { pub id: String, pub site: Option<String>, pub images: Vec<String> }`;
  `pub fn accept(hit: &SceneHit, term: &str, title: &str) -> bool`.

- [ ] **Step 1: Write `scenes.rs` with its tests**

```rust
//! The scene database's scene search, for a poster and a background of a release from
//! another indexer. Same service and key as `codedb.rs`; the endpoint comes from the
//! plab-sources secret (`scene_url`), not from this repository.

use serde::Deserialize;

use crate::labels::match_term;

pub struct SceneDb {
    http: reqwest::Client,
    base: String,
    key: String,
}

/// The first scene a search returned: its id, site name and images (poster, background).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct SceneHit {
    pub id: String,
    pub site: Option<String>,
    pub images: Vec<String>,
}

#[derive(Deserialize)]
struct Reply {
    #[serde(default)]
    data: Vec<RawScene>,
}

#[derive(Deserialize)]
struct RawScene {
    #[serde(default)]
    id: serde_json::Value,
    #[serde(default)]
    site: Option<RawSite>,
    #[serde(default)]
    poster: Option<String>,
    #[serde(default)]
    background: Option<RawBackground>,
}

#[derive(Deserialize)]
struct RawSite {
    #[serde(default)]
    name: Option<String>,
}

#[derive(Deserialize)]
struct RawBackground {
    #[serde(default)]
    large: Option<String>,
}

impl SceneDb {
    pub fn new(base: &str, key: &str) -> SceneDb {
        SceneDb {
            http: crate::http::client(60),
            base: base.trim_end_matches('/').to_string(),
            key: key.to_string(),
        }
    }

    /// The best match for `query`, or None when the search found nothing.
    pub async fn search(&self, query: &str) -> anyhow::Result<Option<SceneHit>> {
        let reply: Reply = self
            .http
            .get(&self.base)
            .query(&[("parse", query), ("per_page", "1")])
            .header("Authorization", format!("Bearer {}", self.key))
            .header("Accept", "application/json")
            .send()
            .await
            .map_err(reqwest::Error::without_url)?
            .error_for_status()
            .map_err(reqwest::Error::without_url)?
            .json()
            .await
            .map_err(reqwest::Error::without_url)?;
        Ok(reply.data.into_iter().next().and_then(|s| {
            let id = match s.id {
                serde_json::Value::String(v) if !v.is_empty() => v,
                serde_json::Value::Number(n) => n.to_string(),
                _ => return None,
            };
            let images = [s.poster, s.background.and_then(|b| b.large)]
                .into_iter()
                .flatten()
                .filter(|u| !u.is_empty())
                .collect();
            Some(SceneHit { id, site: s.site.and_then(|x| x.name), images })
        }))
    }
}

/// Whether a hit is this release's scene: its site matches the term that found the
/// release, or the release title names the site. Anything else is a miss, so a release
/// found by a generic term never borrows another release's images.
pub fn accept(hit: &SceneHit, term: &str, title: &str) -> bool {
    let Some(site) = hit.site.as_deref() else {
        return false;
    };
    match_term(term, site) || match_term(site, title)
}

#[cfg(test)]
mod tests {
    use super::*;
    use wiremock::matchers::{header, method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn search_decodes_the_first_scene() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/scenes"))
            .and(query_param("parse", "alpha lazy 2026-10-24"))
            .and(header("Authorization", "Bearer k"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": [
                {"id": "abc", "site": {"name": "Alpha"}, "poster": "http://i/p.jpg",
                 "background": {"large": "http://i/b.jpg"}},
                {"id": "other"}
            ]})))
            .mount(&server)
            .await;
        let db = SceneDb::new(&format!("{}/scenes", server.uri()), "k");
        let hit = db.search("alpha lazy 2026-10-24").await.unwrap().unwrap();
        assert_eq!(
            hit,
            SceneHit {
                id: "abc".into(),
                site: Some("Alpha".into()),
                images: vec!["http://i/p.jpg".into(), "http://i/b.jpg".into()],
            }
        );
    }

    #[tokio::test]
    async fn no_scene_is_none_and_a_numeric_id_is_kept() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(query_param("parse", "none"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": []})))
            .mount(&server)
            .await;
        Mock::given(method("GET"))
            .and(query_param("parse", "num"))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": [{"id": 7}]})))
            .mount(&server)
            .await;
        let db = SceneDb::new(&server.uri(), "k");
        assert_eq!(db.search("none").await.unwrap(), None);
        assert_eq!(db.search("num").await.unwrap().unwrap().id, "7");
    }

    #[test]
    fn a_site_mismatch_is_a_miss() {
        let hit = SceneHit { id: "1".into(), site: Some("Alpha Studio".into()), images: vec![] };
        assert!(accept(&hit, "alpha studio", "anything"));
        assert!(accept(&hit, "generic", "AlphaStudio Ann Lazy"));
        assert!(!accept(&hit, "generic", "Beta Ann Lazy"));
        assert!(!accept(&SceneHit::default(), "alpha", "Alpha"));
    }
}
```

- [ ] **Step 2: Run the tests**

Run: `cd packages/plab && cargo test scenes:: 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: 3 pass.

- [ ] **Step 3: Commit**

```bash
git add packages/plab/src/scenes.rs packages/plab/src/main.rs
git commit -m "feat(galactica): plab looks up scene images for releases from other indexers"
```

---

### Task 8: The `curated` job, and `refresh` reading its hits

**Files:**
- Create: `packages/plab/src/curated.rs`
- Modify: `packages/plab/src/main.rs` (add `mod curated;` between `config` and `db`)
- Modify: `packages/plab/src/plab.rs` (`Ctx.prowlarr`; `refresh` reads `curated_hit`, never searches, never fetches an external topic's page)
- Modify: `packages/plab/src/plab_tests.rs`
- Modify: every other `Ctx { … }` literal: `packages/plab/src/commands.rs` (`refresh_with`), `packages/plab/src/web.rs` (`WebState::ctx`)

**Interfaces:**
- Consumes:
  - `filters::{load_filter_terms, Term, FilterTerms}` (Task 2) and `sources::Sources` (Task 3);
  - `db::{CuratedHit, NewExternal, is_external}` and the `Db` methods (Task 4);
  - `external::{Candidate, collapse, is_duplicate, scene_query}` (Task 5);
  - `Prowlarr::{indexers, search_in}` (Task 6);
  - `scenes::{SceneDb, accept}` (Task 7).
- Produces:
  - `plab::Ctx` gains `pub prowlarr: Option<&'a Prowlarr>`;
  - `pub struct curated::Elsewhere<'a> { pub sources: &'a Sources, pub scenes: Option<&'a SceneDb> }`;
  - `pub async fn curated::run_curated<T: TrackerApi, C: TorrentClient, K: Classify>(ctx: &Ctx<'_, T, C>, classify: Option<&K>, elsewhere: Option<Elsewhere<'_>>, now: i64) -> anyhow::Result<()>`;
  - `pub const curated::WINDOW_DAYS: u32 = 32`;
  - `pub const curated::DOWN_RANKED: &str = "industrial"`.

- [ ] **Step 1: Add `prowlarr` to `Ctx`**

In `plab.rs`, add `use crate::prowlarr::Prowlarr;` and, in `struct Ctx`, after
`fetch_slots`:

```rust
    /// Prowlarr, for curated releases from other indexers; None turns them off.
    pub prowlarr: Option<&'a Prowlarr>,
```

Set it in every `Ctx` literal:
- `commands.rs` `refresh_with`: `prowlarr: None,`. Task 9 passes the real one.
- `web.rs` `WebState::ctx`: `prowlarr: None,`. Task 10 passes the real one.
- `plab_tests.rs` `Env::ctx`: add `prowlarr: Option<Prowlarr>` to `Env` (with `None` in
  `Env::new`), and `prowlarr: self.prowlarr.as_ref(),` in `ctx`.
- Any other `Ctx {` the compiler reports, the same way.

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked|error"`
Expected: compiles; everything still passes.

- [ ] **Step 2: Write the failing tests** (append to `plab_tests.rs`)

Add the imports at the top of `plab_tests.rs`: `use crate::curated::{Elsewhere, run_curated};`,
`use crate::sources::Sources;`, `use crate::scenes::SceneDb;`,
`use wiremock::matchers::{method, path, query_param};` and
`use wiremock::{Mock, MockServer, ResponseTemplate};`. Then add these helpers and tests:

```rust
impl Env {
    async fn curated(&self, lab: &FakeTracker) -> anyhow::Result<()> {
        run_curated::<_, _, FakeClassify>(&self.ctx(lab), None, None, NOW).await
    }
}

/// Prowlarr with two torrent indexers besides the tracker's ("Primary"): "Indexer A"
/// (id 2) enabled, "Indexer B" (id 3) disabled. A search for `term` returns `results`.
async fn prowlarr(term: &str, results: serde_json::Value) -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/api/v1/indexer"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!([
            {"id": 1, "name": "Primary", "enable": true, "protocol": "torrent"},
            {"id": 2, "name": "Indexer A", "enable": true, "protocol": "torrent"},
            {"id": 3, "name": "Indexer B", "enable": false, "protocol": "torrent"}
        ])))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/api/v1/search"))
        .and(query_param("query", term))
        .and(query_param("categories", "100"))
        .and(query_param("indexerIds", "2"))
        .respond_with(ResponseTemplate::new(200).set_body_json(results))
        .mount(&server)
        .await;
    server
}

fn ext_result(guid: &str, title: &str, seeders: u32, published: &str) -> serde_json::Value {
    serde_json::json!({"guid": guid, "title": title, "seeders": seeders, "leechers": 1,
        "size": 10, "protocol": "torrent", "indexer": "Indexer A",
        "downloadUrl": format!("http://p/{guid}"), "infoUrl": format!("http://a/{guid}"),
        "publishDate": published})
}

fn sources() -> Sources {
    Sources {
        primary_indexer: Some("Primary".into()),
        categories: vec![100],
        scene_url: None,
        noise: vec![],
    }
}

/// NOW is 2027-01-15; these are within the 32-day window, OLD is not.
const RECENT: &str = "2027-01-10T00:00:00Z";
const OLD: &str = "2026-11-01T00:00:00Z";

#[tokio::test]
async fn refresh_searches_nothing_and_merges_stored_curated_hits() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\nAlpha\n"));
    let lab = FakeTracker::new(vec![row(1)]);
    env.db
        .save_curated(
            &[Topic { row: titled(9, "Alpha nine"), images: None, production: None }],
            &[crate::db::CuratedHit { topic_id: 9, filter: "Group A".into(), reason: "Alpha".into() }],
            NOW,
        )
        .unwrap();
    env.refresh(&lab).await.unwrap();
    assert!(lab.calls().searches.is_empty());
    let listing = env.db.listing(Section::Video).unwrap();
    let nine = listing.topics.iter().find(|l| l.topic.row.id == 9).unwrap();
    assert_eq!(nine.filters, vec!["Group A".to_string()]);
    assert_eq!(nine.curated_reason.as_deref(), Some("Alpha"));
}

#[tokio::test]
async fn curated_searches_every_term_over_the_window_and_lists_the_hits() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n[Group B]\nBeta\n"));
    let mut lab = FakeTracker::new(vec![row(1)]);
    lab.searched.insert("Alpha".into(), vec![titled(5, "Alpha five")]);
    lab.searched.insert("Beta".into(), vec![titled(6, "Beta six")]);
    env.curated(&lab).await.unwrap();
    let searches = lab.calls().searches.clone();
    assert_eq!(
        searches.iter().map(|s| (s.0.as_str(), s.1)).collect::<Vec<_>>(),
        vec![("Alpha", Some(32)), ("Beta", Some(32))]
    );
    let listing = env.db.listing(Section::Video).unwrap();
    let ids: Vec<u64> = listing.topics.iter().map(|l| l.topic.row.id).collect();
    assert!(ids.contains(&5) && ids.contains(&6), "{ids:?}");
}

#[tokio::test]
async fn curated_lists_classified_releases_from_other_indexers() {
    let server = prowlarr(
        "Alpha",
        serde_json::json!([
            ext_result("g1", "Alpha Ann Lazy Sunday 480p MP4", 5, RECENT),
            ext_result("g2", "Alpha.Ann.Lazy.Sunday.1080p.MP4", 9, RECENT),
            ext_result("g3", "Alpha Old One 720p", 50, OLD),
        ]),
    )
    .await;
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let lab = FakeTracker::new(vec![row(1)]);
    let k = FakeClassify::answering("pro_artistic", Some(0.9));
    let s = sources();
    run_curated(&env.ctx(&lab), Some(&k), Some(Elsewhere { sources: &s, scenes: None }), NOW)
        .await
        .unwrap();
    let listing = env.db.listing(Section::Video).unwrap();
    let ext: Vec<_> = listing.topics.iter().filter(|l| crate::db::is_external(l.topic.row.id)).collect();
    // Two variants collapse to the best seeded; the old one is out of the window.
    assert_eq!(ext.len(), 1);
    assert_eq!(ext[0].topic.row.seeders, 9);
    assert_eq!(ext[0].filters, vec!["Group A".to_string()]);
    let e = env.db.external(ext[0].topic.row.id).unwrap().unwrap();
    assert_eq!((e.indexer.as_str(), e.link.as_str()), ("Indexer A", "http://p/g2"));
    // The external release's page is never fetched from the tracker.
    assert!(!lab.calls().topics.contains(&ext[0].topic.row.id));
}

#[tokio::test]
async fn curated_drops_the_down_ranked_class_and_holds_back_unclassified() {
    let server = prowlarr("Alpha", serde_json::json!([ext_result("g1", "Alpha Ann Lazy", 5, RECENT)])).await;
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let lab = FakeTracker::new(vec![row(1)]);
    let s = sources();
    for k in [FakeClassify::answering(crate::curated::DOWN_RANKED, None), FakeClassify::failing()] {
        run_curated(&env.ctx(&lab), Some(&k), Some(Elsewhere { sources: &s, scenes: None }), NOW)
            .await
            .unwrap();
        let listing = env.db.listing(Section::Video).unwrap();
        assert!(!listing.topics.iter().any(|l| crate::db::is_external(l.topic.row.id)));
    }
}

#[tokio::test]
async fn curated_drops_what_the_tracker_already_has() {
    let server = prowlarr(
        "Alpha",
        serde_json::json!([ext_result("g1", "Alpha 27 01 05 Ann And Ben Lazy Sunday 1080p", 5, RECENT)]),
    )
    .await;
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let mut lab = FakeTracker::new(vec![row(1)]);
    lab.searched.insert(
        "Alpha".into(),
        vec![titled(5, "[Alpha.com] Ann Doe, Ben Roe - Lazy Sunday (05.01.2027)")],
    );
    let k = FakeClassify::answering("pro_artistic", None);
    let s = sources();
    run_curated(&env.ctx(&lab), Some(&k), Some(Elsewhere { sources: &s, scenes: None }), NOW)
        .await
        .unwrap();
    let listing = env.db.listing(Section::Video).unwrap();
    assert!(!listing.topics.iter().any(|l| crate::db::is_external(l.topic.row.id)));
    assert!(listing.topics.iter().any(|l| l.topic.row.id == 5));
}

#[tokio::test]
async fn curated_keeps_tracker_hits_when_prowlarr_is_down_and_ids_stay_stable() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    // Nothing listens on port 1: Prowlarr is down.
    env.prowlarr = Some(Prowlarr::new("http://127.0.0.1:1", "k".into()));
    let mut lab = FakeTracker::new(vec![row(1)]);
    lab.searched.insert("Alpha".into(), vec![titled(5, "Alpha five")]);
    let k = FakeClassify::answering("pro_artistic", None);
    let s = sources();
    run_curated(&env.ctx(&lab), Some(&k), Some(Elsewhere { sources: &s, scenes: None }), NOW)
        .await
        .unwrap();
    let ids: Vec<u64> = env.db.listing(Section::Video).unwrap().topics.iter().map(|l| l.topic.row.id).collect();
    assert!(ids.contains(&5));

    // The same guid on a later run keeps its id.
    let server = prowlarr("Alpha", serde_json::json!([ext_result("g1", "Alpha Ann Lazy", 5, RECENT)])).await;
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    for _ in 0..2 {
        run_curated(&env.ctx(&lab), Some(&k), Some(Elsewhere { sources: &s, scenes: None }), NOW)
            .await
            .unwrap();
    }
    assert_eq!(env.db.externals().unwrap().keys().copied().collect::<Vec<_>>(), vec![crate::db::EXTERNAL_BASE]);
}

#[tokio::test]
async fn curated_sets_scene_images_on_an_accepted_hit_only() {
    let server = prowlarr(
        "Alpha",
        serde_json::json!([
            ext_result("g1", "Alpha Ann Lazy", 5, RECENT),
            ext_result("g2", "Alpha Cat Rain", 4, RECENT),
        ]),
    )
    .await;
    let scenes = MockServer::start().await;
    Mock::given(method("GET"))
        .and(query_param("parse", "alpha ann lazy"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": [
            {"id": "s1", "site": {"name": "Alpha"}, "poster": "http://i/p.jpg"}]})))
        .mount(&scenes)
        .await;
    Mock::given(method("GET"))
        .and(query_param("parse", "alpha cat rain"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({"data": [
            {"id": "s2", "site": {"name": "Unrelated"}, "poster": "http://i/q.jpg"}]})))
        .mount(&scenes)
        .await;
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n@Alpha\n"));
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let lab = FakeTracker::new(vec![row(1)]);
    let k = FakeClassify::answering("pro_artistic", None);
    let s = sources();
    let db = SceneDb::new(&scenes.uri(), "k");
    run_curated(&env.ctx(&lab), Some(&k), Some(Elsewhere { sources: &s, scenes: Some(&db) }), NOW)
        .await
        .unwrap();
    let ext = env.db.externals().unwrap();
    let by_title = |t: &str| {
        env.db
            .listing(Section::Video)
            .unwrap()
            .topics
            .into_iter()
            .find(|l| l.topic.row.title == t)
            .unwrap()
    };
    let ann = by_title("Alpha Ann Lazy");
    assert_eq!(ann.topic.images, Some(vec!["http://i/p.jpg".to_string()]));
    assert_eq!(ext[&ann.topic.row.id].scene_id.as_deref(), Some("s1"));
    let cat = by_title("Alpha Cat Rain");
    assert_eq!(cat.topic.images.unwrap_or_default(), Vec::<String>::new());
    assert_eq!(ext[&cat.topic.row.id].scene_id, None);
}
```

Check `NOW` (1_800_000_000) against the dates above. 1_800_000_000 is 2027-01-15, so
`RECENT` (2027-01-10) is inside the 32-day window and `OLD` (2026-11-01) is outside it.
The date in `curated_drops_what_the_tracker_already_has` (`27 01 05`, `05.01.2027`) is
just a matching pair; any date works.

- [ ] **Step 3: Move the existing curated-search tests from refresh to curated**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "^test .*FAILED"` after Step 4. Until
then, the test above that references `run_curated` keeps the build from compiling. For
each existing test in `plab_tests.rs` that expects `refresh` to search curated terms
(`refresh_merges_search_results_into_their_filter`, and those near it at lines ~550–610
that set a filter file and inspect `searches` or search-found topics), do two things:
- replace `env.refresh(&lab)` with `env.curated(&lab)`;
- rename the test's `refresh_` prefix to `curated_`.

`run_curated` ends by rebuilding the list, so their listing assertions still hold. Tests
that only use title matching on top-list rows
(`refresh_assigns_top_list_rows_to_filters_by_title`) stay on `refresh`.
`run_refresh_passes_filter_file` keeps checking `refresh`'s use of the filter file
through title matching. Change its expectation if it counted searches.

- [ ] **Step 4: Write `curated.rs`**

```rust
//! The `curated` job, daily: every curated filter's terms searched on the tracker over
//! `WINDOW_DAYS`, and the terms marked `@` through Prowlarr's other indexers. Releases
//! from other indexers are collapsed to one per release, dropped when the tracker has
//! them, classified (the down-ranked class is dropped) and given scene images when the
//! scene database knows them. The hits replace `curated_hit`, then the video list is
//! rebuilt so they show at once.

use std::collections::{HashMap, HashSet};

use anyhow::{Context, bail};
use tracing::{info, warn};

use crate::db::{CuratedHit, NewExternal, Section, Topic};
use crate::external::{Candidate, collapse, is_duplicate, scene_query};
use crate::filters::{FilterTerms, load_excludes, load_filter_terms};
use crate::labels::term_label;
use crate::llm::Classify;
use crate::plab::{CLASSIFY_FAILURE_LIMIT, Ctx, ensure_image, refresh};
use crate::prowlarr::ProwlarrResult;
use crate::scenes::{SceneDb, accept};
use crate::sources::Sources;
use crate::tracker::forums::{self, category};
use crate::tracker::parse::Row;
use crate::tracker::{TrackerApi, TrackerError};
use crate::transmission::TorrentClient;

pub const WINDOW_DAYS: u32 = 32;
/// Tracker results per term.
const PER_TERM: usize = 20;
/// The production class whose releases from other indexers are not shown.
pub const DOWN_RANKED: &str = "industrial";

/// What the external pass needs besides `Ctx`.
pub struct Elsewhere<'a> {
    pub sources: &'a Sources,
    pub scenes: Option<&'a SceneDb>,
}

pub async fn run_curated<T: TrackerApi, C: TorrentClient, K: Classify>(
    ctx: &Ctx<'_, T, C>,
    classify: Option<&K>,
    elsewhere: Option<Elsewhere<'_>>,
    now: i64,
) -> anyhow::Result<()> {
    let filters = load_filter_terms(ctx.filter_file, Some(ctx.state_dir));
    let excludes = load_excludes(ctx.exclude_file, Some(ctx.state_dir));
    let forums = forums::forums();
    let mut topics: Vec<Topic> = vec![];
    let mut hits: Vec<CuratedHit> = vec![];
    let mut seen: HashSet<(u64, String)> = HashSet::new();
    // filter name -> the tracker titles it found, for the duplicate check
    let mut tracker_titles: HashMap<String, Vec<String>> = HashMap::new();
    let total: usize = filters.iter().map(|(_, t)| t.len()).sum();
    let mut done = 0usize;
    for (name, terms) in &filters {
        for term in terms {
            done += 1;
            info!(done, total, "search {:?}", term.text);
            tokio::time::sleep(ctx.delay).await;
            let results = match ctx
                .tracker
                .search(&term.text, &forums, Some(WINDOW_DAYS), PER_TERM, &excludes, None)
                .await
            {
                Ok(r) => r,
                Err(e @ TrackerError::Login(_)) => return Err(e.into()),
                // One failed search must not sink the run.
                Err(e) => {
                    warn!("search failed for {:?}: {e}", term.text);
                    continue;
                }
            };
            for r in results {
                tracker_titles.entry(name.clone()).or_default().push(r.title.clone());
                if seen.insert((r.id, name.clone())) {
                    hits.push(CuratedHit { topic_id: r.id, filter: name.clone(), reason: term_label(&term.text) });
                }
                topics.push(Topic { row: r, images: None, production: None });
            }
        }
    }
    if let Some(e) = elsewhere {
        match external_pass(ctx, classify, &e, &filters, &tracker_titles, now).await {
            Ok((t, h)) => {
                topics.extend(t);
                hits.extend(h.into_iter().filter(|h| seen.insert((h.topic_id, h.filter.clone()))));
            }
            // The tracker's hits are still stored.
            Err(err) => warn!("other indexers skipped: {err:#}"),
        }
    }
    ctx.db.save_curated(&topics, &hits, now)?;
    info!("curated: {} hits", hits.len());
    refresh(ctx, Section::Video, classify, now).await
}

fn candidate(r: &ProwlarrResult, cutoff: i64) -> Option<Candidate> {
    if r.protocol.as_deref() != Some("torrent") {
        return None;
    }
    let published = chrono::DateTime::parse_from_rfc3339(r.publish_date.as_deref()?)
        .ok()?
        .timestamp();
    if published < cutoff {
        return None;
    }
    Some(Candidate {
        indexer: r.indexer.clone()?,
        guid: r.guid.clone()?,
        link: r.download_url.clone()?,
        info_url: r.info_url.clone(),
        title: r.title.clone()?,
        size: r.size.unwrap_or(0.0) as u64,
        seeders: r.seeders.unwrap_or(0.0) as u32,
        leechers: r.leechers.unwrap_or(0.0) as u32,
        published,
    })
}

async fn external_pass<T: TrackerApi, C: TorrentClient, K: Classify>(
    ctx: &Ctx<'_, T, C>,
    classify: Option<&K>,
    e: &Elsewhere<'_>,
    filters: &FilterTerms,
    tracker_titles: &HashMap<String, Vec<String>>,
    now: i64,
) -> anyhow::Result<(Vec<Topic>, Vec<CuratedHit>)> {
    if !filters.iter().any(|(_, terms)| terms.iter().any(|t| t.elsewhere)) {
        return Ok((vec![], vec![]));
    }
    let prowlarr = ctx.prowlarr.context("Prowlarr is not configured")?;
    let classify = classify.context("no classifier: releases from other indexers are shown only classified")?;
    let ids: Vec<u32> = prowlarr
        .indexers()
        .await?
        .into_iter()
        .filter(|i| i.enable && i.protocol == "torrent")
        .filter(|i| e.sources.primary_indexer.as_deref() != Some(i.name.as_str()))
        .map(|i| i.id)
        .collect();
    if ids.is_empty() {
        bail!("no enabled indexer besides the tracker's");
    }
    let cutoff = now - i64::from(WINDOW_DAYS) * 86400;
    let noise = &e.sources.noise;
    let mut topics = vec![];
    let mut hits = vec![];
    let mut classify_failures = 0u32;
    for (name, terms) in filters {
        let titles: Vec<&str> = tracker_titles
            .get(name)
            .map(|v| v.iter().map(String::as_str).collect())
            .unwrap_or_default();
        for term in terms.iter().filter(|t| t.elsewhere) {
            let results = match prowlarr.search_in(&term.text, &e.sources.categories, &ids).await {
                Ok(r) => r,
                Err(err) => {
                    warn!("other indexers: search failed for {:?}: {err:#}", term.text);
                    continue;
                }
            };
            let found: Vec<Candidate> = results.iter().filter_map(|r| candidate(r, cutoff)).collect();
            for c in collapse(found, noise) {
                if is_duplicate(&c.title, &titles, &term.text, noise) {
                    continue;
                }
                let id = ctx.db.upsert_external(&NewExternal {
                    indexer: &c.indexer,
                    guid: &c.guid,
                    link: &c.link,
                    info_url: c.info_url.as_deref(),
                })?;
                let known = ctx.db.topic(id)?;
                let production = match known.as_ref().and_then(|t| t.production.clone()) {
                    Some(p) => p,
                    None if classify_failures >= CLASSIFY_FAILURE_LIMIT => continue,
                    None => match classify.classify(&c.title, category(0)).await {
                        Ok(p) => {
                            classify_failures = 0;
                            p
                        }
                        // Held back until the next run: never shown unclassified.
                        Err(err) => {
                            classify_failures += 1;
                            warn!("classify {:?}: {err:#}", c.title);
                            continue;
                        }
                    },
                };
                if production.class == DOWN_RANKED {
                    continue;
                }
                let mut images = known.and_then(|t| t.images).filter(|v| !v.is_empty());
                if images.is_none()
                    && let Some(scenes) = e.scenes
                {
                    match scenes.search(&scene_query(&c.title, noise)).await {
                        Ok(Some(hit)) if accept(&hit, &term.text, &c.title) && !hit.images.is_empty() => {
                            ctx.db.set_scene(id, &hit.id)?;
                            if let Err(err) = ensure_image(ctx.tracker, ctx.images, &hit.images[0]).await {
                                warn!("image {}: {err:#}", hit.images[0]);
                            }
                            images = Some(hit.images);
                        }
                        Ok(_) => {}
                        Err(err) => warn!("scene search for {:?}: {err:#}", c.title),
                    }
                }
                topics.push(Topic {
                    row: Row {
                        id,
                        title: c.title.clone(),
                        forum: 0,
                        size: c.size,
                        seeders: c.seeders,
                        leechers: c.leechers,
                        completed: 0,
                        added: c.published,
                    },
                    images,
                    production: Some(production),
                });
                hits.push(CuratedHit { topic_id: id, filter: name.clone(), reason: term_label(&term.text) });
            }
        }
    }
    Ok((topics, hits))
}
```

- [ ] **Step 5: Change `refresh` in `plab.rs`**

Remove the per-term search loop: everything from the comment "Each filter's terms are
searched over a longer window" down to the end of its `for (name, terms)` loop. The
`filters` binding (from `load_filters`) stays, for `match_filters` and the listing's
filter names. Put this in place of the loop:

```rust
    // The curated job's stored hits (video only): their topics join the list, under the
    // filters that found them.
    let hits = match section {
        Section::Video => ctx.db.curated_hits()?,
        Section::Games => vec![],
    };
    // topic id -> {filter name: badge of the first term that found it}
    let mut found: HashMap<u64, HashMap<String, String>> = HashMap::new();
    let mut stored: HashMap<u64, Topic> = HashMap::new();
    let mut extra_rows = vec![];
    for (topic, filter, reason) in hits {
        found.entry(topic.row.id).or_default().entry(filter).or_insert(reason);
        if !stored.contains_key(&topic.row.id) {
            extra_rows.push(topic.row.clone());
            stored.insert(topic.row.id, topic);
        }
    }
```

In the per-row loop:
- change `let prev = previous.get(&row.id);` to
  `let prev = previous.get(&row.id).or_else(|| stored.get(&row.id));`
- change `if images.is_empty() {` to
  `if images.is_empty() && !crate::db::is_external(row.id) {`. A release from another
  indexer has only the images the curated job gave it.

Remove `term_label` from `plab.rs`'s imports if it is now unused, and make
`CLASSIFY_FAILURE_LIMIT` and `ensure_image` reachable from `curated.rs`. Both are
already `pub`.

- [ ] **Step 6: Run all tests**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Expected: all pass. If a moved test fails, compare its expectation with the spec. The
search window is still 32 days and 20 results, so only *where* the search runs changed.

Run: `cd packages/plab && cargo clippy --all-targets -- -D warnings 2>&1 | grep -E "^error" | sort | uniq -c`
Expected: only the 3 pre-existing `collapsible_if` errors.

- [ ] **Step 7: Commit**

```bash
git add packages/plab/src/curated.rs packages/plab/src/main.rs packages/plab/src/plab.rs packages/plab/src/plab_tests.rs packages/plab/src/commands.rs packages/plab/src/web.rs
git commit -m "feat(galactica): plab curated job searches daily, other indexers included"
```

---

### Task 9: Schedule `curated`, `plab curated`, a shared Prowlarr

**Files:**
- Modify: `packages/plab/src/jobs.rs`, `packages/plab/src/app.rs`, `packages/plab/src/commands.rs`, `packages/plab/src/main.rs`

**Interfaces:**
- Consumes: `curated::{run_curated, Elsewhere}`, `sources::load`, `scenes::SceneDb`,
  `Prowlarr::new`, `prowlarr::api_key`, and `StashApi::codedb_api_key`, which returns the
  key `SceneDb` uses.
- Produces: `jobs::CURATED`; `App.prowlarr: Option<Arc<Prowlarr>>`;
  `app::prowlarr(cfg: &Config) -> Option<Prowlarr>`; `commands::curated(cfg: &Config) -> anyhow::Result<()>`;
  the CLI subcommand `plab curated`.

- [ ] **Step 1: Write the failing test** (in `jobs.rs`'s tests)

```rust
    #[test]
    fn curated_runs_daily_at_seven_utc() {
        let day = 86400;
        assert_eq!(schedule("curated").unwrap().period, day);
        assert_eq!(last_slot(CURATED, 10 * day + 8 * 3600), 10 * day + 7 * 3600);
        assert_eq!(next_slot(CURATED, 10 * day + 8 * 3600), 11 * day + 7 * 3600);
        assert!(overdue(CURATED, Some(10 * day + 6 * 3600), 10 * day + 7 * 3600));
    }
```

Run: `cd packages/plab && cargo test jobs:: 2>&1 | tail -3`
Expected: compile error (`CURATED` not found).

- [ ] **Step 2: Implement the schedule**

In `jobs.rs`, after `SWEEP`:

```rust
/// Daily at 07:00 UTC: clear of the 06:00 refresh and the 04:00 sweep.
pub const CURATED: Schedule = Schedule {
    period: 24 * 3600,
    offset: 7 * 3600,
};
```

and in `schedule`, add `"curated" => Some(CURATED),`.

- [ ] **Step 3: Build Prowlarr once in `App`**

In `app.rs`:

```rust
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
```

Add `pub prowlarr: Option<Arc<crate::prowlarr::Prowlarr>>,` to `App`, and in `App::build`
add `prowlarr: prowlarr(&cfg).map(Arc::new),` before `cfg: Arc::new(cfg)`.

- [ ] **Step 4: The job body, the daemon task, the one-shot**

In `commands.rs`, add `CURATED` to the `crate::jobs` import, and add `curated` and
`sources` to the `crate::{…}` import. Add:

```rust
/// One curated run. The filter and sources files and the scene key are read each run, so
/// editing a secret needs no restart.
#[allow(clippy::too_many_arguments)]
async fn curated_with(
    cfg: &Config,
    db: &Db,
    images: &ImageCache,
    tracker: &Tracker,
    torrents: &Transmission,
    classify: Option<&OpenRouter>,
    fetch_slots: &Semaphore,
    prowlarr: Option<&Prowlarr>,
    stash: &crate::stash::Stash,
) -> anyhow::Result<()> {
    let ctx = plab::Ctx {
        tracker,
        torrents,
        db,
        images,
        state_dir: &cfg.state_dir,
        exclude_file: cfg.exclude_file.as_deref(),
        filter_file: cfg.filter_file.as_deref(),
        download_dir: Config::require(&cfg.download_dir, "PLAB_DOWNLOAD_DIR")?,
        games_dir: cfg.games_dir.as_deref(),
        delay: plab::DELAY,
        fetch_slots,
        prowlarr,
    };
    let sources = sources::load(cfg.sources_file.as_deref());
    let key = match stash.codedb_api_key().await {
        Ok(k) => k,
        Err(e) => {
            tracing::warn!("scene key from Stash: {e:#}");
            None
        }
    };
    let scenes = match (sources.as_ref().and_then(|s| s.scene_url.as_deref()), key) {
        (Some(url), Some(key)) => Some(crate::scenes::SceneDb::new(url, &key)),
        _ => None,
    };
    let elsewhere = sources.as_ref().map(|s| curated::Elsewhere {
        sources: s,
        scenes: scenes.as_ref(),
    });
    curated::run_curated(&ctx, classify, elsewhere, now_f64() as i64).await
}
```

In `refresh_with`, change `prowlarr: None,` to take a new last parameter
`prowlarr: Option<&Prowlarr>`, and pass it through. Update both callers: the daemon
passes `a.prowlarr.as_deref()`, and the one-shot `refresh` passes the value of
`app::prowlarr(cfg)`.

In `serve`, under `Task::Refresh`:
- register the job: `Task::Refresh => { mon.register("refresh"); mon.register("curated"); }`
- next to the existing refresh `tokio::spawn`, spawn the curated loop:

```rust
                let c = app.clone();
                tokio::spawn(supervise("curated", move || {
                    let a = c.clone();
                    async move {
                        let a: &App = &a;
                        run_periodic(a.db.clone(), "curated", CURATED, || {
                            curated_with(
                                &a.cfg,
                                &a.db,
                                &a.images,
                                &a.tracker,
                                &a.transmission,
                                a.openrouter.as_ref(),
                                &a.fetch_slots,
                                a.prowlarr.as_deref(),
                                &a.stash,
                            )
                        })
                        .await
                    }
                }));
```

The one-shot, after `refresh`:

```rust
/// The `curated` job once. Recorded as the slot's run.
pub async fn curated(cfg: &Config) -> anyhow::Result<()> {
    let db = app::open_db(cfg)?;
    let images = app::images(cfg)?;
    let tracker = app::tracker(cfg, &db)?;
    let torrents = app::transmission(cfg)?;
    let classify = app::openrouter(cfg, llm::OPENROUTER)?;
    let prowlarr = app::prowlarr(cfg);
    let stash = app::stash(cfg);
    let slots = Semaphore::new(app::FETCH_SLOTS);
    let job = curated_with(
        cfg,
        &db,
        &images,
        &tracker,
        &torrents,
        classify.as_ref(),
        &slots,
        prowlarr.as_ref(),
        &stash,
    );
    jobs::record(&db, "curated", job).await
}
```

In `main.rs`, add a subcommand after `Refresh`:

```rust
    /// Search the curated terms (the tracker, and other indexers for terms marked @), then
    /// rebuild the video list.
    Curated,
```

and its arm: `Cmd::Curated => commands::curated(&cfg).await?,`.

- [ ] **Step 5: Run all tests and clippy**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"; cargo clippy --all-targets -- -D warnings 2>&1 | grep -E "^error" | sort | uniq -c`
Expected: all pass, and only the 3 pre-existing clippy errors. If clippy objects to
`too_many_arguments` on `refresh_with`, give it the same `#[allow]`.

- [ ] **Step 6: Commit**

```bash
git add packages/plab/src/jobs.rs packages/plab/src/app.rs packages/plab/src/commands.rs packages/plab/src/main.rs
git commit -m "feat(galactica): plab runs the curated job daily and as plab curated"
```

---

### Task 10: Stream and Add a release from another indexer

**Files:**
- Modify: `packages/plab/src/rqbit.rs`, `packages/plab/src/stream.rs`, `packages/plab/src/plab.rs`, `packages/plab/src/web.rs`, `packages/plab/src/commands.rs` (WebState literal), `packages/plab/src/web_tests.rs` (WebState literal)
- Test: `packages/plab/src/rqbit.rs` tests, `packages/plab/src/plab_tests.rs`, `packages/plab/src/stream.rs` tests

**Interfaces:**
- Consumes: `db::{is_external, Db::external}`, `Prowlarr::fetch`, `TorrentSource`.
- Produces:
  - `pub async fn plab::external_torrent(prowlarr: Option<&Prowlarr>, db: &Db, id: u64, now: i64) -> anyhow::Result<TorrentSource>`;
  - `Rqbit::list(&self, torrent: &TorrentSource)` and `Rqbit::add(&self, torrent: &TorrentSource, file: usize)`;
  - `rqbit::NoMetadata`;
  - `StreamError::NoMetadata`;
  - `Streams::start` gains `prowlarr: Option<&Prowlarr>` as its second parameter;
  - `WebState.prowlarr: Option<Arc<Prowlarr>>`.

- [ ] **Step 1: Write the failing rqbit test** (in `rqbit.rs`'s tests, after the existing `list`/`add` tests; reuse their server setup style)

```rust
    #[tokio::test]
    async fn a_magnet_is_sent_as_the_body() {
        let server = MockServer::start().await;
        let magnet = "magnet:?xt=urn:btih:0000000000000000000000000000000000000000&dn=x";
        Mock::given(method("POST"))
            .and(path("/torrents"))
            .and(wiremock::matchers::body_string(magnet))
            .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
                "details": {"info_hash": "h", "files": [{"name": "a.mp4", "length": 5}]}})))
            .mount(&server)
            .await;
        let r = Rqbit::new(&server.uri());
        let src = TorrentSource::Magnet(magnet.into());
        assert_eq!(r.list(&src).await.unwrap()[0].name, "a.mp4");
        assert_eq!(r.add(&src, 0).await.unwrap(), "h");
    }
```

If `AddReply`'s JSON shape in the existing tests differs (for example, `details` nested
differently), copy the shape the existing `list` test uses.

- [ ] **Step 2: Change rqbit to take a `TorrentSource`**

In `rqbit.rs`, add `use crate::transmission::TorrentSource;`. Add:

```rust
/// rqbit fetches a magnet's metadata from peers before it can list the files; past this,
/// the swarm is taken to have no peers.
const MAGNET_LIST_TIMEOUT: Duration = Duration::from_secs(120);

/// A magnet whose metadata no peer sent within `MAGNET_LIST_TIMEOUT`.
#[derive(Debug, thiserror::Error)]
#[error("no peers for metadata")]
pub struct NoMetadata;

fn body(torrent: &TorrentSource) -> Vec<u8> {
    match torrent {
        TorrentSource::Bytes(b) => b.clone(),
        TorrentSource::Magnet(m) => m.as_bytes().to_vec(),
    }
}
```

Change `post_torrent` to take `torrent: &TorrentSource` and use `.body(body(torrent))`.
When the source is a magnet, set `.timeout(MAGNET_LIST_TIMEOUT)` on that request, and map
a timeout to `NoMetadata`:

```rust
    async fn post_torrent(&self, torrent: &TorrentSource, query: &[(&str, String)]) -> Result<AddReply> {
        let mut req = self.http.post(self.url("torrents")).query(query).body(body(torrent));
        if matches!(torrent, TorrentSource::Magnet(_)) {
            req = req.timeout(MAGNET_LIST_TIMEOUT);
        }
        let resp = match req.send().await {
            Ok(r) => r,
            Err(e) if e.is_timeout() && matches!(torrent, TorrentSource::Magnet(_)) => {
                return Err(NoMetadata.into());
            }
            Err(e) => return Err(anyhow::Error::new(e).context("rqbit unreachable")),
        };
        Ok(checked(resp, None).await?.json().await?)
    }
```

Change `list(&self, torrent: &[u8])` to `list(&self, torrent: &TorrentSource)`, and
`add(&self, torrent: &[u8], file)` to `add(&self, torrent: &TorrentSource, file)`.
Update the existing rqbit tests to pass `&TorrentSource::Bytes(…)`.

- [ ] **Step 3: `external_torrent` and its tests**

In `plab.rs`:

```rust
/// A release from another indexer's torrent: the stored `.torrent`, else Prowlarr's
/// download link, whose `.torrent` answer is stored for next time (a magnet is used as is).
pub async fn external_torrent(
    prowlarr: Option<&Prowlarr>,
    db: &Db,
    id: u64,
    now: i64,
) -> anyhow::Result<TorrentSource> {
    if let Some(bytes) = db.torrent_file(id)? {
        return Ok(TorrentSource::Bytes(bytes));
    }
    let ext = db.external(id)?.with_context(|| format!("release {id} is not known"))?;
    let prowlarr = prowlarr.context("Prowlarr is not configured")?;
    let src = prowlarr.fetch(&ext.link).await?;
    if let TorrentSource::Bytes(b) = &src {
        db.store_torrent_file(id, b, now)?;
    }
    Ok(src)
}
```

Tests in `plab_tests.rs`:

```rust
#[tokio::test]
async fn external_torrent_stores_a_torrent_and_passes_a_magnet() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/dl/1"))
        .respond_with(ResponseTemplate::new(200).set_body_bytes(b"d4:infod1:xi1eee".to_vec()))
        .expect(1)
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/dl/2"))
        .respond_with(ResponseTemplate::new(302).insert_header("Location", "magnet:?xt=urn:btih:00"))
        .mount(&server)
        .await;
    let env = Env::new();
    let p = Prowlarr::new(&server.uri(), "k".into());
    let (l1, l2) = (format!("{}/dl/1", server.uri()), format!("{}/dl/2", server.uri()));
    let mk = |guid, link| crate::db::NewExternal { indexer: "Indexer A", guid, link, info_url: None };
    let a = env.db.upsert_external(&mk("1", &l1)).unwrap();
    let b = env.db.upsert_external(&mk("2", &l2)).unwrap();
    for _ in 0..2 {
        // The second call reads the stored file: the mock expects one fetch.
        assert!(matches!(external_torrent(Some(&p), &env.db, a, NOW).await.unwrap(), TorrentSource::Bytes(_)));
    }
    assert!(matches!(
        external_torrent(Some(&p), &env.db, b, NOW).await.unwrap(),
        TorrentSource::Magnet(m) if m.starts_with("magnet:")
    ));
}
```

- [ ] **Step 4: Stream start**

In `stream.rs`:
- add `NoMetadata` to the `StreamError` enum with `#[error("no peers for metadata")]` and
  status `502`;
- in `engine_err`, map `e.downcast_ref::<crate::rqbit::NoMetadata>()` to
  `StreamError::NoMetadata` before the `Engine` fallback;
- change `Streams::add(&self, engine, bytes: &[u8], file)` to take `torrent: &TorrentSource`;
- change `start`'s signature to
  `pub async fn start<T: TrackerApi>(&self, tracker: &T, prowlarr: Option<&Prowlarr>, db: &Db, engine: &Rqbit, topic: u64, now: i64)`.

Replace the block that obtains `bytes` with:

```rust
        let source = if crate::db::is_external(topic) {
            progress.step("Fetching torrent from indexer");
            crate::plab::external_torrent(prowlarr, db, topic, now)
                .await
                .map_err(|e| StreamError::Tracker(format!("{e:#}")))?
        } else {
            let stored = db
                .torrent_file(topic)
                .map_err(|e| StreamError::Tracker(format!("{e:#}")))?;
            TorrentSource::Bytes(match stored {
                Some(bytes) => {
                    progress.step("Using stored torrent");
                    bytes
                }
                None => {
                    progress.step("Fetching torrent from tracker");
                    torrent_bytes(tracker, db, topic, now).await?
                }
            })
        };
        progress.step(if matches!(source, TorrentSource::Magnet(_)) {
            "Resolving magnet"
        } else {
            "Reading file list"
        });
        let files = engine.list(&source).await.map_err(engine_err)?;
```

and pass `&source` to `self.add`. Update stream.rs's own tests: the `start(...)` calls
gain `None` as the second argument, and engine stubs that took bytes now take
`TorrentSource::Bytes`.

In `web.rs`:
- add `pub prowlarr: Option<Arc<Prowlarr>>,` to `WebState`;
- set `prowlarr: self.prowlarr.as_deref(),` in `WebState::ctx`;
- in `stream_page`, pass `st.prowlarr.as_deref()` as `start`'s second argument.

Set the field in `commands.rs` (`prowlarr: a.prowlarr.clone(),`) and in every
`WebState { … }` in `web_tests.rs` (`prowlarr: None,`).

- [ ] **Step 5: Add to Vault and images**

In `plab.rs` `add_topic`, replace the `let torrent = match ctx.tracker.torrent(topic_id)…`
block and the `add(&TorrentSource::Bytes(torrent), dir)` call with:

```rust
    let torrent = if crate::db::is_external(topic_id) {
        // Not the tracker: no daily limit, never queued.
        external_torrent(ctx.prowlarr, ctx.db, topic_id, now).await?
    } else {
        match ctx.tracker.torrent(topic_id).await {
            Ok(t) => TorrentSource::Bytes(t),
            Err(e @ TrackerError::Limit(_)) => {
                ctx.db.enqueue(topic_id, section, now)?;
                return Ok(AddResult::Queued { message: e.to_string() });
            }
            Err(e) => return Err(e.into()),
        }
    };
    let added = ctx.torrents.add(&torrent, dir).await?;
```

In `topic_images`, right after the `if let Some(found) = found { return Ok(found); }`, add:

```rust
    // A release from another indexer has only the images the curated job found for it.
    if crate::db::is_external(topic_id) {
        return Ok(vec![]);
    }
```

Add to `plab_tests.rs`:

```rust
#[tokio::test]
async fn adding_an_external_release_never_touches_the_tracker() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/dl/1"))
        .respond_with(ResponseTemplate::new(302).insert_header("Location", "magnet:?xt=urn:btih:00"))
        .mount(&server)
        .await;
    let mut env = Env::new();
    let link = format!("{}/dl/1", server.uri());
    let id = env
        .db
        .upsert_external(&crate::db::NewExternal { indexer: "Indexer A", guid: "1", link: &link, info_url: None })
        .unwrap();
    env.db
        .save_curated(
            &[Topic { row: titled(id, "Alpha one"), images: None, production: None }],
            &[crate::db::CuratedHit { topic_id: id, filter: "A".into(), reason: "Alpha".into() }],
            NOW,
        )
        .unwrap();
    let lab = FakeTracker::new(vec![row(1)]);
    env.refresh(&lab).await.unwrap(); // lists it
    env.prowlarr = Some(Prowlarr::new(&server.uri(), "k".into()));
    let r = add_topic(&env.ctx(&lab), id, NOW).await.unwrap();
    assert!(matches!(r, AddResult::Added { .. }), "{r:?}");
    assert!(lab.calls().torrents.is_empty());
    assert!(topic_images(&env.ctx(&lab), id, NOW).await.unwrap().is_empty());
}
```

`FakeTorrents` records `(Vec<u8>, String)`. If it panics or fails on a magnet, extend its
`add` to record a magnet's bytes as the string's bytes. Do not change what it records for
`.torrent` bytes.

- [ ] **Step 6: Run all tests and clippy**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"; cargo clippy --all-targets -- -D warnings 2>&1 | grep -E "^error" | sort | uniq -c`
Expected: all pass, and only the 3 pre-existing clippy errors.

- [ ] **Step 7: Commit**

```bash
git add packages/plab/src/rqbit.rs packages/plab/src/stream.rs packages/plab/src/plab.rs packages/plab/src/plab_tests.rs packages/plab/src/web.rs packages/plab/src/web_tests.rs packages/plab/src/commands.rs
git commit -m "feat(galactica): plab streams and adds releases from other indexers"
```

---

### Task 11: The card shows its indexer and links to its page

**Files:**
- Modify: `packages/plab/src/api.rs`, `packages/plab/src/api_tests.rs`, `packages/plab/src/web.rs`
- Modify: `packages/plab/ui/src/lib/types.ts`, `packages/plab/ui/src/components/Card.svelte`, every `Topic` literal under `packages/plab/ui/src/**/*.test.ts`

**Interfaces:**
- Consumes: `Db::externals() -> HashMap<u64, External>`.
- Produces: `TopicDto.source: Option<String>`, `TopicDto.link: Option<String>`
  (JSON `source`, `link`); `api::list(…, externals: &HashMap<u64, External>, …)` as a new
  last parameter.

- [ ] **Step 1: Write the failing Rust test** (in `api_tests.rs`; reuse its helpers for
  building a `Listing` with one topic and calling `list`)

```rust
#[test]
fn an_external_card_carries_its_indexer_and_page() {
    let mut externals = std::collections::HashMap::new();
    let id = crate::db::EXTERNAL_BASE;
    externals.insert(
        id,
        crate::db::External {
            id,
            indexer: "Indexer A".into(),
            link: "http://p/1".into(),
            info_url: Some("http://a/1".into()),
            scene_id: None,
        },
    );
    // Build a one-topic listing with topic id `id` the way the other tests here do, then:
    let dto = list_with_externals(id, &externals);
    assert_eq!(dto.topics[0].source.as_deref(), Some("Indexer A"));
    assert_eq!(dto.topics[0].link.as_deref(), Some("http://a/1"));
    let tracker = list_with_externals(5, &externals);
    assert_eq!((tracker.topics[0].source.clone(), tracker.topics[0].link.clone()), (None, None));
}
```

`list_with_externals(id, externals)` is a small helper you add next to the existing
helpers. It builds a `Listing` holding one `Listed` with that topic id, and calls
`api::list` with empty `added`/`queued`, the existing default `Downloads`, `None` for the
search reply, and `externals`.

Run: `cd packages/plab && cargo test api 2>&1 | tail -3`
Expected: compile error.

- [ ] **Step 2: Implement in Rust**

In `api.rs`, add to `TopicDto` after `status`:

```rust
    /// The indexer a release from another indexer came from; None for the tracker's own.
    pub source: Option<String>,
    /// That release's page; None for the tracker's own (the app builds the tracker link).
    pub link: Option<String>,
```

Give `list` a last parameter `externals: &HashMap<u64, crate::db::External>` and pass it
to `topic`. In `topic`, add `let ext = externals.get(&row.id);` and set
`source: ext.map(|e| e.indexer.clone()), link: ext.and_then(|e| e.info_url.clone()),`.
Update every other `TopicDto { … }` literal (the compiler lists them) with
`source: None, link: None`.

In `web.rs`, at both `api::list(` call sites, load `let externals = st.db.externals()?;`
(map the error as the neighboring db calls do) and pass `&externals`.

- [ ] **Step 3: Implement in the app**

`types.ts`, in `interface Topic` after `status`:

```ts
  /** The indexer of a release from another indexer; null for the tracker's own. */
  source: string | null;
  /** That release's page; null for the tracker's own. */
  link: string | null;
```

`Card.svelte`:
- in the studio/quality row, show the indexer, and render the row when there is a source:

```svelte
    {#if topic.studio || topic.quality || topic.source}
      <div class="flex flex-wrap items-center gap-2 text-xs">
        {#if topic.studio}<span class="font-semibold uppercase tracking-wide text-primary">{topic.studio}</span>{/if}
        {#if topic.quality}<span class="badge badge-xs badge-outline">{topic.quality}</span>{/if}
        {#if topic.source}<span class="badge badge-xs badge-secondary">{topic.source}</span>{/if}
      </div>
    {/if}
```

- change the title link's `href={topicUrl + topic.id}` to `href={topic.link ?? topicUrl + topic.id}`.

Find every `Topic` literal in the UI tests and add `source: null, link: null`:

Run: `cd packages/plab/ui && grep -rln "production:" src --include=*.test.ts`

- [ ] **Step 4: Run both suites**

Run: `cd packages/plab && cargo test 2>&1 | grep -E "test result|FAILED|panicked"`
Run: `cd packages/plab/ui && npm run check && npm test`
Expected: all pass, with svelte-check showing 0 errors and 0 warnings.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/api.rs packages/plab/src/api_tests.rs packages/plab/src/web.rs packages/plab/ui/src/lib/types.ts packages/plab/ui/src/components/Card.svelte
git add $(cd packages/plab/ui && git ls-files -m src | sed 's|^|packages/plab/ui/|')
git commit -m "feat(galactica): plab cards name the indexer of a release from elsewhere"
```

---

### Task 12: The secret, the module, deploy and check

**Files:**
- Modify: `modules/hosts/galactica/services/plab/default.nix`
- Modify: `secrets/sops/galactica.yaml` (through `sops set`, never by hand)

- [ ] **Step 1: Create the `plab-sources` secret**

The values come from galactica at runtime, and none of them is written into the
repository or this plan. Collect them like this:
- `primary_indexer`: the `name` of the tracker's own indexer in Prowlarr's
  `/api/v1/indexer` (the semi-private one that plab's tracker client logs into).
- `categories`: the top-level category id the 2026-11-02 survey searched with. It is the
  category id the tracker's indexer lists in its `capabilities.categories`, in the
  thousands range.
- `scene_url`: the scene search endpoint on the same host as `codedb::CODE_URL`, with the
  path `/scenes`.
- `noise`: the format words that recur in titles from the other indexers and are not
  resolutions or container names. Take them from a sample of `title`s returned by a
  `search_in` over the survey's terms.

```bash
cd ~/Code/nixos
printf 'primary_indexer = %s\ncategories = %s\nscene_url = %s\nnoise = %s\n' \
  "$PRIMARY" "$CATEGORIES" "$SCENE_URL" "$NOISE" > /tmp/plab-sources.txt
nix develop -c sops set secrets/sops/galactica.yaml '["plab-sources"]' "$(jq -Rs . < /tmp/plab-sources.txt)"
rm /tmp/plab-sources.txt
nix develop -c sops --decrypt --extract '["plab-sources"]' secrets/sops/galactica.yaml | grep -c '='
```

Set the four shell variables first. Expected: `4`.

- [ ] **Step 2: Mark terms with `@`**

Ask the user which curated terms should also be searched on other indexers. Use
AskUserQuestion and list the filter groups by name, never in a repository file. Then
rewrite the `plab-filter` secret with `@` in front of the chosen terms:

```bash
nix develop -c sops --decrypt --extract '["plab-filter"]' secrets/sops/galactica.yaml > /tmp/plab-filter.txt
# edit /tmp/plab-filter.txt: prefix the chosen terms with @
nix develop -c sops set secrets/sops/galactica.yaml '["plab-filter"]' "$(jq -Rs . < /tmp/plab-filter.txt)"
rm /tmp/plab-filter.txt
```

- [ ] **Step 3: Wire the secret into the module**

In `default.nix`, after the `PLAB_FILTER_FILE` export:

```nix
        export PLAB_SOURCES_FILE="''${PLAB_SOURCES_FILE:-${secrets.plab-sources.path}}"
```

and after `sops.secrets.plab-filter.owner = vars.user;`:

```nix
    sops.secrets.plab-sources.owner = vars.user;
```

- [ ] **Step 4: Format and build galactica**

Run: `cd ~/Code/nixos && just fmt && nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link 2>&1 | tail -5`
Expected: the build succeeds. The package's checkPhase runs `cargo test`,
`npm run check` and `npm test`.

- [ ] **Step 5: Commit and push**

```bash
git add modules/hosts/galactica/services/plab/default.nix secrets/sops/galactica.yaml
git commit -m "feat(galactica): plab gets its external-source settings from sops"
git push -u origin master
```

- [ ] **Step 6: Deploy and run once**

Run: `just deploy galactica`, then:

```bash
ssh galactica.bat-boa.ts.net 'sudo -u media env $(systemctl show plab -p Environment --value) plab curated 2>&1 | tail -20'
```

If the service exports its variables in a wrapper script rather than through
`Environment=`, run the wrapper with the subcommand instead. The header of `default.nix`
documents `sudo -u media plab refresh`; use the same form with `curated`.

Expected: per-term search lines, `curated: N hits`, then the refresh log line. No error.

- [ ] **Step 7: Check in the app**

On `https://plab.arsfeld.one`:
1. Under a filter with `@` terms, cards with an indexer badge appear, and some show
   scene images.
2. The title link of such a card opens its indexer page.
3. **Stream** on one: the modal shows "Resolving magnet" or "Fetching torrent from
   indexer", then plays. Seek to the middle.
4. **Add to Vault** on another: Transmission shows it, and the card's state turns to
   added.
5. The jobs page lists `curated` with its next run at 07:00 UTC.

Report each result. If any fails, use superpowers:systematic-debugging before changing
code.
