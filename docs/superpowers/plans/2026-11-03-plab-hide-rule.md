# plab hide rule Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Hide a configured kind of scene from plab's listings and from the Assistant, but only when its tags or words make the kind certain.

**Architecture:** `filters.rs` gains a pure `HideRule` (hide terms and keep terms), parsed from two new sections of the existing exclude file. `load_excludes` now returns an `Excludes` holding the regexes and the rule, so every listing path that already applies the exclude list applies the rule too. The Assistant holds the rule and drops Stash scenes it hides. A man listed in a scene's cast always keeps that scene.

**Tech Stack:** Rust (edition 2024), fancy-regex, serde, wiremock for tests. Spec: `docs/superpowers/specs/2026-11-03-plab-hide-rule-design.md`.

## Global Constraints

- **No NSFW words anywhere in the repo:** not in code, comments, tests, commits or docs. The real terms live only in the `plab-exclude` sops secret. Tests use placeholder words (`pear`, `plum`, `kiwi`, `fig`), like the existing filter tests.
- Commits: `<type>(galactica): <subject>`, straight to `master`, no branches. Never mention Claude.
- Run Rust commands from `packages/plab`: `cargo test`, `cargo clippy --all-targets -- -D warnings`.
- Section headers are exactly `[hide]` or `[keep]` after trimming. Any other line, including one starting with `[`, keeps its current meaning.
- An empty `[hide]` list never hides anything: a file without the sections behaves exactly as it does today.
- Album names use the regex patterns only, never the rule.
- A performer whose Stash `gender` is `MALE` always keeps a scene. The cast is never a reason to hide one.

---

### Task 1: The rule and the `Excludes` type in `filters.rs`

**Files:**
- Modify: `packages/plab/src/filters.rs` (replace `load_excludes`/`excluded` at lines ~119-149; add the new types; tests in the existing `mod tests`)
- Modify: `packages/plab/src/candidates.rs:65` (make `has_word` `pub(crate)`)
- Modify: `packages/plab/src/stash/library.rs:12-16` (add `gender` to `Named`)

**Interfaces:**
- Produces:
  - `pub struct HideRule { pub hide: Vec<String>, pub keep: Vec<String> }` (lowercase terms; `Default`, `Clone`, `Debug`, `PartialEq`)
  - `pub enum Terms { Tags(Vec<String>), Words(String) }` (lowercase)
  - `impl HideRule { pub fn hides(&self, terms: &Terms) -> bool }`
  - `pub fn title_terms(title: &str) -> Terms`
  - `pub fn scene_hidden(rule: &HideRule, scene: &crate::stash::library::LibScene) -> bool`
  - `pub struct Excludes { pub patterns: Vec<fancy_regex::Regex>, pub rule: HideRule }` with `Default`; `impl From<Vec<fancy_regex::Regex>> for Excludes`; methods `excluded(&self, title: &str) -> bool`, `pattern_excluded(&self, title: &str) -> bool`, `is_empty(&self) -> bool`
  - `pub fn parse_excludes(text: &str) -> Excludes`
  - `pub fn load_excludes(path: Option<&Path>, state_dir: Option<&Path>) -> Excludes`. Same arguments as before, new return type.
  - The free function `excluded` is removed.
  - `stash::library::Named` gains `#[serde(default)] pub gender: Option<String>`.

This task changes `load_excludes`'s return type, so the crate will not compile until Task 2 updates the callers. Steps 1–4 below are therefore checked with `cargo test filters::` only after the minimal caller fixes in Step 3b. Tasks 1 and 2 are committed together at the end of Task 2.

- [ ] **Step 1: Write the failing tests** in `filters.rs`'s `mod tests` (they sit beside the existing `load_excludes_*` tests):

```rust
    fn rule(hide: &[&str], keep: &[&str]) -> HideRule {
        HideRule {
            hide: hide.iter().map(|s| s.to_string()).collect(),
            keep: keep.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn tags(t: &[&str]) -> Terms {
        Terms::Tags(t.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn sections_split_patterns_from_terms() {
        let ex = parse_excludes(
            "apple\n[a-z]fruit\n\n[hide]\nPear\n# note\nwild plum\n[keep]\nKiwi\n",
        );
        assert_eq!(ex.patterns.len(), 2); // `[a-z]fruit` is a character class, not a header
        assert_eq!(ex.rule, rule(&["pear", "wild plum"], &["kiwi"]));
    }

    #[test]
    fn no_sections_means_an_empty_rule() {
        let ex = parse_excludes("apple\nbanana\n");
        assert_eq!(ex.patterns.len(), 2);
        assert_eq!(ex.rule, HideRule::default());
        assert!(!ex.excluded("[Site] Name [2020, Pear, 1080p]"));
    }

    #[test]
    fn hides_on_whole_tags() {
        let r = rule(&["pear"], &["kiwi"]);
        assert!(r.hides(&tags(&["fig", "pear"])));
        assert!(!r.hides(&tags(&["pear", "kiwi"])));
        assert!(!r.hides(&tags(&["pear/plum"]))); // a compound tag is not the term
        assert!(!r.hides(&tags(&["fig"])));
        assert!(!HideRule::default().hides(&tags(&["pear"])));
    }

    #[test]
    fn hides_on_whole_words() {
        let r = rule(&["pear", "wild plum"], &["kiwi"]);
        assert!(r.hides(&Terms::Words("site pear video".into())));
        assert!(!r.hides(&Terms::Words("pearl video".into())));
        assert!(r.hides(&Terms::Words("a wild plum, ripe".into())));
        assert!(!r.hides(&Terms::Words("pear and kiwi".into())));
    }

    #[test]
    fn title_terms_prefer_the_tag_list() {
        assert_eq!(
            title_terms("[Site.com] A Pear Story [2026-10-01, Fig, Kiwi, 1080p, SiteRip]"),
            tags(&["fig", "kiwi"])
        );
        assert_eq!(title_terms("Site 26 01 01 Pear Video 1080p"), Terms::Words("site 26 01 01 pear video 1080p".into()));
    }

    #[test]
    fn a_tagged_title_ignores_its_free_text() {
        let ex = parse_excludes("[hide]\npear\n");
        assert!(!ex.excluded("[Site.com] A Pear Story [2026-10-01, Fig, 1080p]"));
        assert!(ex.excluded("[Site.com] A Story [2026-10-01, Fig, Pear, 1080p]"));
        assert!(ex.excluded("site pear video"));
    }

    #[test]
    fn excluded_is_patterns_or_rule_and_albums_use_patterns_only() {
        let ex = parse_excludes("apple\n[hide]\npear\n");
        assert!(ex.excluded("an apple"));
        assert!(ex.excluded("a pear"));
        assert!(ex.pattern_excluded("an apple"));
        assert!(!ex.pattern_excluded("a pear"));
    }

    fn scene(tags: &[&str], genders: &[Option<&str>]) -> crate::stash::library::LibScene {
        serde_json::from_value(serde_json::json!({
            "id": "1",
            "tags": tags.iter().map(|t| serde_json::json!({"id": "t", "name": t})).collect::<Vec<_>>(),
            "performers": genders.iter().map(|g| serde_json::json!({"id": "p", "name": "P", "gender": g})).collect::<Vec<_>>(),
        }))
        .unwrap()
    }

    #[test]
    fn scene_hidden_uses_tags_and_a_listed_man_keeps() {
        let r = rule(&["pear"], &["kiwi"]);
        assert!(scene_hidden(&r, &scene(&["Pear"], &[Some("FEMALE"), Some("FEMALE")])));
        assert!(scene_hidden(&r, &scene(&["Pear"], &[]))); // an empty cast proves nothing
        assert!(scene_hidden(&r, &scene(&["Pear"], &[None])));
        assert!(!scene_hidden(&r, &scene(&["Pear", "Kiwi"], &[Some("FEMALE")])));
        assert!(!scene_hidden(&r, &scene(&["Pear"], &[Some("FEMALE"), Some("MALE")])));
        assert!(!scene_hidden(&r, &scene(&["Fig"], &[Some("FEMALE")])));
    }
```

Then rename the existing tests' calls: `excluded(&patterns, …)` becomes `patterns.excluded(…)`, and `patterns.is_empty()` stays as it is (`Excludes::is_empty`).

- [ ] **Step 2: Add `gender` to `Named`** in `src/stash/library.rs`:

```rust
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Named {
    pub id: String,
    pub name: String,
    /// Performers only: Stash's enum spelling (`MALE`, `FEMALE`, …).
    #[serde(default)]
    pub gender: Option<String>,
}
```

Change `has_word` in `src/candidates.rs` from `fn has_word` to `pub(crate) fn has_word`.

- [ ] **Step 3: Implement** in `filters.rs`. Replace the `load_excludes` and `excluded` functions with:

```rust
/// The hide rule: a scene is hidden when one of its terms is a hide term and none is a
/// keep term, so it hides only what its own tags make certain. Lowercase. On galactica
/// both lists are the `[hide]` and `[keep]` sections of the plab-exclude sops secret; the
/// words are kept out of this repository on purpose.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct HideRule {
    pub hide: Vec<String>,
    pub keep: Vec<String>,
}

/// What a scene is matched on, lowercase: its whole tags, or, for a title with no tag
/// list, the title's whole words.
#[derive(Debug, Clone, PartialEq)]
pub enum Terms {
    Tags(Vec<String>),
    Words(String),
}

impl Terms {
    fn has(&self, term: &str) -> bool {
        match self {
            Terms::Tags(tags) => tags.iter().any(|t| t == term),
            Terms::Words(text) => crate::candidates::has_word(text, term),
        }
    }
}

impl HideRule {
    pub fn hides(&self, terms: &Terms) -> bool {
        self.hide.iter().any(|h| terms.has(h)) && !self.keep.iter().any(|k| terms.has(k))
    }
}

/// A release title's terms: the tag list `labels` finds, else the title's words. A tagged
/// title's free text is not used: it can name a term the scene is not.
pub fn title_terms(title: &str) -> Terms {
    let tags = crate::labels::labels(title, 0).tags;
    if tags.is_empty() {
        Terms::Words(title.to_lowercase())
    } else {
        Terms::Tags(tags)
    }
}

/// A Stash scene under the rule, on its tags. A man in the cast keeps it: Stash casts often
/// leave male performers out, so a listed one proves presence and a missing one proves
/// nothing.
pub fn scene_hidden(rule: &HideRule, scene: &crate::stash::library::LibScene) -> bool {
    if scene.performers.iter().any(|p| p.gender.as_deref() == Some("MALE")) {
        return false;
    }
    rule.hides(&Terms::Tags(scene.tags.iter().map(|t| t.name.to_lowercase()).collect()))
}

/// The exclude file: regex patterns, then the optional `[hide]` and `[keep]` sections.
#[derive(Debug, Default)]
pub struct Excludes {
    pub patterns: Vec<fancy_regex::Regex>,
    pub rule: HideRule,
}

impl From<Vec<fancy_regex::Regex>> for Excludes {
    fn from(patterns: Vec<fancy_regex::Regex>) -> Self {
        Excludes { patterns, rule: HideRule::default() }
    }
}

impl Excludes {
    /// True if a pattern matches the title or the rule hides it.
    pub fn excluded(&self, title: &str) -> bool {
        self.pattern_excluded(title) || self.rule.hides(&title_terms(title))
    }

    /// The patterns alone: for album names, which are not scenes.
    pub fn pattern_excluded(&self, title: &str) -> bool {
        self.patterns.iter().any(|p| p.is_match(title).unwrap_or(false))
    }

    pub fn is_empty(&self) -> bool {
        self.patterns.is_empty() && self.rule.hide.is_empty()
    }
}

/// Lines before any section are regexes, case-insensitive; Python raised on a bad pattern,
/// here it is logged and skipped so one typo cannot sink the refresh. A line that is exactly
/// `[hide]` or `[keep]` starts that section, whose lines are plain terms. Blank lines and
/// `#` comments are ignored throughout.
pub fn parse_excludes(text: &str) -> Excludes {
    #[derive(PartialEq)]
    enum In {
        Patterns,
        Hide,
        Keep,
    }
    let mut at = In::Patterns;
    let mut ex = Excludes::default();
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        match line {
            "[hide]" => at = In::Hide,
            "[keep]" => at = In::Keep,
            _ if at == In::Hide => ex.rule.hide.push(line.to_lowercase()),
            _ if at == In::Keep => ex.rule.keep.push(line.to_lowercase()),
            // An inline flag, not RegexBuilder::case_insensitive: fancy-regex 0.14 drops the
            // builder's flag for some patterns (`\b` ones among them), so `\bword` never
            // matched "Word".
            _ => match fancy_regex::Regex::new(&format!("(?i){line}")) {
                Ok(re) => ex.patterns.push(re),
                Err(err) => tracing::warn!("bad exclude pattern {line:?}: {err}"),
            },
        }
    }
    ex
}

/// The exclude file from `path` or `<state_dir>/exclude.txt`; none means nothing excluded.
pub fn load_excludes(path: Option<&Path>, state_dir: Option<&Path>) -> Excludes {
    resolve(path, state_dir, "exclude.txt")
        .and_then(|p| read_text(&p))
        .map_or_else(Excludes::default, |t| parse_excludes(&t))
}
```

Also update the module doc line 1 to `//! The curated filters, exclusion patterns and the hide rule, read from their files.`

- [ ] **Step 3b: Make the crate compile.** Do Task 2, Steps 1–2 now, because the tests cannot run until the callers are updated.

- [ ] **Step 4: Run the tests**

Run: `cargo test filters::`
Expected: PASS, including the 8 new tests and the existing `load_excludes_*` tests.

### Task 2: Every caller takes `&Excludes`; albums use patterns only

**Files:**
- Modify: `packages/plab/src/tracker/mod.rs:51,59,303,308,399,420` (trait and impl signatures, `rows`)
- Modify: `packages/plab/src/curated.rs:18,220,244,322,375`
- Modify: `packages/plab/src/web.rs:6,546-551`
- Modify: `packages/plab/src/stream.rs:488,498` (test fake)
- Modify: `packages/plab/src/web_tests.rs:67,78` (test fake)
- Modify: `packages/plab/src/plab_tests.rs:138-140,151,166` (test fake)
- Modify: `packages/plab/src/tracker/tests.rs:95-110,221,236,279,292,696-697`

**Interfaces:**
- Consumes: `Excludes`, `Excludes::excluded`, `Excludes::pattern_excluded`, `Excludes::is_empty` and `impl From<Vec<Regex>> for Excludes` from Task 1.
- Produces: `TrackerApi::top(…, excludes: &Excludes)` and `TrackerApi::search(…, excludes: &Excludes, pages)`.

- [ ] **Step 1: Change the signatures.** Every `excludes: &[fancy_regex::Regex]` and `_: &[fancy_regex::Regex]` in the files above becomes `excludes: &crate::filters::Excludes` (or `_: &crate::filters::Excludes`). Then make these call changes:
  - `tracker/mod.rs` `rows`: `.filter(|r| !excludes.excluded(&r.title))`
  - `curated.rs`: drop `excluded` from the `use crate::filters::{…}` list. The external pass becomes `.filter(|c| !excludes.excluded(&c.title))`. The album pass becomes `if excludes.pattern_excluded(&a.name) {`, with this comment above it: `// Album names are image sets, not scenes: the patterns apply, the hide rule does not.`
  - `web.rs`: `use crate::filters::load_excludes;`. In `list`:

    ```rust
        let excludes = load_excludes(st.exclude_file.as_deref(), Some(&st.state_dir));
        if !excludes.is_empty() {
            listing
                .topics
                .retain(|t| !excludes.excluded(&t.topic.row.title));
        }
    ```
  - `plab_tests.rs` `keep`: `fn keep(rows: &[Row], excludes: &crate::filters::Excludes) -> Vec<Row>`, filtering with `!excludes.excluded(&r.title)`.
  - `plab.rs` needs no edit, because it passes `&excludes` straight through.

- [ ] **Step 2: Update the tracker tests.** In `src/tracker/tests.rs`, `not_3313754()` and `not_3314001()` return `crate::filters::Excludes` and end with `.into()` on the `Vec` they build today. Each `&[]` passed as an excludes argument becomes `&crate::filters::Excludes::default()`.

- [ ] **Step 3: Add a listing test for the rule** in `src/plab_tests.rs`, next to `run_search_all_time_excludes_and_records`:

```rust
#[tokio::test]
async fn run_search_applies_the_hide_rule() {
    let (mut env, lab) = search_env();
    env.exclude_file = Some(env.write("ex.txt", "[hide]\ncherry\n"));
    let topics = run_search(&env.ctx(&lab), "alpha", NOW).await.unwrap();
    assert_eq!(topics.iter().map(|l| l.topic.row.id).collect::<Vec<_>>(), [5]);
}
```

`search_env` returns `titled(6, "Ripe Cherry")`. That title has no tag list, so it is matched on whole words.

- [ ] **Step 4: Run everything**

Run: `cargo test` and then `cargo clippy --all-targets -- -D warnings`
Expected: all tests pass, and clippy is clean.

- [ ] **Step 5: Commit Tasks 1 and 2**

```bash
git add packages/plab/src
git commit -m "feat(galactica): plab exclude file gains a hide rule"
```

### Task 3: The Assistant drops hidden Stash scenes

**Files:**
- Modify: `packages/plab/src/stash/library.rs:64` (`FIELDS`)
- Modify: `packages/plab/src/assistant/mod.rs:174-215,290` (`Assistant` field, `with_hide`, pass the rule)
- Modify: `packages/plab/src/assistant/context.rs:137-160` (`gather` takes the rule)
- Modify: `packages/plab/src/assistant/tools.rs:57-80` (`run` takes the rule)
- Modify: `packages/plab/src/app.rs:132-141`
- Test: `packages/plab/src/assistant/mod.rs` `mod tests`

**Interfaces:**
- Consumes: `HideRule`, `scene_hidden`, `load_excludes` from Task 1; `Named.gender`.
- Produces: `Assistant::with_hide(self, rule: HideRule) -> Assistant`; `context::gather(db, stash, hide: &HideRule, now)`; `tools::run(stash, db, hide: &HideRule, name, arguments, now)`.

- [ ] **Step 1: Write the failing test** in `assistant/mod.rs`'s `mod tests`. The test serves two scenes from the mocked Stash and checks that the hidden one never reaches the model, either in the candidates or through `find_stash_scenes`:

```rust
    #[tokio::test]
    async fn hidden_scenes_never_reach_the_model() {
        let server = MockServer::start().await;
        let scenes = json!({"data": {"findScenes": {"scenes": [
            {"id": "1", "title": "Pear Scene", "tags": [{"id": "t1", "name": "Pear"}],
             "performers": [{"id": "p1", "name": "Ann", "gender": "FEMALE"}], "play_count": 0},
            {"id": "2", "title": "Fig Scene", "tags": [{"id": "t2", "name": "Fig"}],
             "performers": [{"id": "p1", "name": "Ann", "gender": "FEMALE"}], "play_count": 0}
        ]}}});
        Mock::given(path("/graphql"))
            .respond_with(ResponseTemplate::new(200).set_body_json(scenes))
            .mount(&server)
            .await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(tool_call("find_stash_scenes", r#"{"q":"scene"}"#))
            .up_to_n_times(1)
            .mount(&server)
            .await;
        Mock::given(path(crate::llm::CHAT_PATH))
            .respond_with(final_reply("ok", json!([])))
            .mount(&server)
            .await;
        let llm = OpenRouter::new(&server.uri(), "k".into(), "p".into(), "j".into());
        let stash = Stash::new(&format!("{}/graphql", server.uri()), None);
        let rule = crate::filters::HideRule { hide: vec!["pear".into()], keep: vec![] };
        let a = Assistant::new(llm, stash, "m".into(), "x".into()).with_hide(rule);
        let db = Db::open_in_memory().unwrap();
        a.start(&db, Kind::Chat, Some("hi"), 0).await.unwrap();
        let bodies = sent(&server).await;
        let all = bodies.join("\n");
        assert!(all.contains("Fig Scene"));
        assert!(!all.contains("Pear Scene"));
    }
```

Before writing it, check the fixture helpers the other tests use: `tool_call`, `final_reply`, `sent`, and whether `start` also runs the turn or a separate `a.turn(&db, id, None, 0)` is needed. `a_tool_round_then_an_answer` shows the call order. Mirror that test's sequence exactly, adding the `turn` call if `start` does not run the turn. A profile with no views leaves `unwatched` with no ids, so `gather` may never query Stash for candidates. If so, the scenes reach the model only through the tool, and the assertions still prove the tool path. Note in the test which path it covers.

- [ ] **Step 2: Run it to verify it fails**

Run: `cargo test assistant::tests::hidden_scenes_never_reach_the_model`
Expected: it fails to compile, because there is no `with_hide`.

- [ ] **Step 3: Implement.**

`stash/library.rs` `FIELDS`: `performers { id name }` becomes `performers { id name gender }`.

`assistant/mod.rs`: add a field `hide: crate::filters::HideRule` to `Assistant`, initialize it with `HideRule::default()` in `new`, and add:

```rust
    /// The exclude file's hide rule, applied to the Stash scenes the model sees.
    pub fn with_hide(mut self, hide: crate::filters::HideRule) -> Assistant {
        self.hide = hide;
        self
    }
```

In `start`: `context::gather(db, &self.stash, &self.hide, now)`. In the turn loop: `tools::run(&self.stash, db, &self.hide, name, args, now)`.

`assistant/context.rs` `gather`: add the parameter `hide: &crate::filters::HideRule` after `stash`, and filter before mapping into `SceneIn`:

```rust
    let scenes: Vec<SceneIn> = scenes
        .iter()
        .filter(|s| !crate::filters::scene_hidden(hide, s))
        .map(|s| SceneIn {
```

`assistant/tools.rs` `run`: add the parameter `hide: &crate::filters::HideRule` after `db`. In `find_stash_scenes`, put `.filter(|s| !crate::filters::scene_hidden(hide, s))` before the `.map(|s| { json!(…) })`.

`app.rs` `assistant`: chain the rule on after `Assistant::new(…)`:

```rust
        crate::assistant::Assistant::new(
            llm,
            stash(cfg),
            cfg.assistant_model.clone(),
            crate::site::get().prompts.assistant.clone(),
        )
        .with_hide(crate::filters::load_excludes(cfg.exclude_file.as_deref(), Some(&cfg.state_dir)).rule)
```

The file is read once, at startup. The restart after a secret change comes from `restartUnits = ["plab.service"]` on `sops.secrets.plab-exclude` (sops-nix restarts nothing by itself), so the rule is picked up then.

- [ ] **Step 4: Run tests**

Run: `cargo test` then `cargo clippy --all-targets -- -D warnings`
Expected: all pass, and clippy is clean. If the `stash::library` tests pin the query body with `body_string_contains("performers { id name }")`, update that string to include `gender`.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src
git commit -m "feat(galactica): plab assistant leaves out scenes the hide rule hides"
```

### Task 4: Docs, verification against real data, deploy, secret

**Files:**
- Modify: `modules/hosts/galactica/services/plab/default.nix` (the header comment block, lines 1-45)
- Modify: `docs/superpowers/specs/2026-11-03-plab-hide-rule-design.md` (the "Behaviour notes" bullet about refreshes)
- Scratch: a verification binary or test under the session scratchpad. Not committed.

- [ ] **Step 1: Correct the spec.** `web.rs::list` re-applies the exclude file on every page load, so listings change at once and not "at the next refresh". Replace that bullet with: `Listings re-read the exclude file on every page load (web.rs list), so listings pick up a secret change at once, and the Assistant picks it up because the secret's restartUnits restarts plab; the refresh also stops listing hidden releases.`

- [ ] **Step 2: Document the module.** Add a paragraph next to the existing notes in the `default.nix` header comment:

```nix
# plab-exclude holds regexes, then optional [hide] and [keep] sections of plain terms: a
# release or Stash scene is hidden when a hide term is one of its tags (or, untagged, a
# whole word of its title) and no keep term is; a man in a Stash cast always keeps it.
# Design: docs/superpowers/specs/2026-11-03-plab-hide-rule-design.md.
```

- [ ] **Step 3: Verify against real data, outside the repo.** Build the `[hide]`/`[keep]` lists from the measurements in the spec. The lists themselves live only in the secret.

  Write them to `<scratchpad>/exclude.txt`, after the current secret's regex lines. Then write a throwaway `#[test] #[ignore]` in a scratch copy of the crate, or a `cargo run --example` kept in the scratchpad (never committed). It loads that file, runs `Excludes::excluded` over every title in the scratchpad's copy of `state.db`, and runs `scene_hidden` over the scratchpad's `scenes.json`. The scenes dump needs `performers { gender }` and `tags { name }`, which it already has. Print what is hidden and what is kept. It must match the spec:
  - The multi-scene pack (2843317) and the ambiguous release (1889687) are kept.
  - No game forum release is hidden.
  - No Stash scene that lists a `MALE` performer is hidden.
  - The broad tag alone hides nothing.

  Fix the lists, not the code, if any of these fails. Report the counts.

- [ ] **Step 4: Commit docs, then build galactica**

```bash
git add modules/hosts/galactica/services/plab/default.nix docs/superpowers/specs/2026-11-03-plab-hide-rule-design.md
git commit -m "docs(galactica): plab hide rule in the module notes"
just build galactica
```

- [ ] **Step 5: Write the secret.** sops is fully automated: no interactive editor. Read the current value with `nix develop -c sops --decrypt --extract '["plab-exclude"]' secrets/sops/galactica.yaml`. Append the verified `[hide]` and `[keep]` sections, and write it back with `nix develop -c sops set secrets/sops/galactica.yaml '["plab-exclude"]' "$(jq -Rs . < <scratchpad>/exclude.txt)"`. Decrypt again to confirm the value round-trips. Then commit:

```bash
git add secrets/sops/galactica.yaml
git commit -m "chore(secrets): plab hide rule terms"
```

- [ ] **Step 6: Push and deploy**

```bash
git push -u origin master
just deploy galactica
```

Then check `ssh galactica.bat-boa.ts.net systemctl is-active plab`. Open the Video list through the API (`curl -s https://plab.arsfeld.one/api/list/video`, or whatever route `web.rs` serves for `list`) and confirm that none of the hidden topic ids from Step 3 appear. Then delete the scratchpad copies of `state.db`, `scenes.json` and `exclude.txt`.
