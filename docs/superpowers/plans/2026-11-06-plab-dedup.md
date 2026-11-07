# plab dedup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One card per scene across the Tracker and Indexers tabs, with the other releases listed as "also". Scenes plab already downloaded through any release are marked "have it" and kept out of the assistant's picks.

**Architecture:** A new pure module, `src/same.rs`, defines "same scene" as the same release date plus a shared name. It also builds an `Owned` matcher over every download title. `api::list` groups a section's topics, plus the other tab's topics, at serve time and emits one card per group. The assistant's `releases()` uses the same `Owned` check. No schema change.

**Tech Stack:** Rust (plab daemon, rusqlite, serde), Svelte 5 + TypeScript (plab UI, vitest).

**Spec:** `docs/superpowers/specs/2026-11-06-plab-dedup-design.md`

## Global Constraints

- **Branch.** Commit straight to `master`. No branches or worktrees.
- **Commits.** Use the format `<type>(galactica): plab …`, one commit per task.
- **Rust.** Run all Rust commands from `packages/plab`: `cargo test <filter>`, `cargo fmt`, `cargo clippy --all-targets -- -D warnings`.
- **UI.** Run UI commands from `packages/plab/ui`: `nix shell nixpkgs#nodejs -c npm test`, and `nix shell nixpkgs#nodejs -c npx svelte-check` if it is configured.
- **Content.** No NSFW names or terms anywhere: code, tests, comments, commits. Use the existing placeholders (`Studio B`, `Cara Kim`, `Indexer A`, `alpha`).
- **Scope.** No schema migration. `grab::scene_keys`, `grab_seen` and `external::collapse` are untouched.
- **Overlap.** Lists and the owned check need 2 shared names (`LIST_MIN`), curated and assistant search need 1 (`SEARCH_MIN`).
- **Fail safe.** A title with no readable date never merges and is never owned through matching.
- **Not grouped.** Albums (`kind == album`) and the Games section are never grouped.

## Review Focus

1. **Two different scenes, same studio, same day, both 1337x-style** (`Studio B 26 10 30 Ann Lee …` vs `Studio B 26 10 30 Bea Ray …`). They must stay two cards, not merge on the studio words. Pinned in Task 1 (`studio_prefix_words_do_not_link`).
2. **An unrelated download or card linked by one common word** (`you`, a shared first name) on the same day. Lists and `Owned` require `LIST_MIN = 2` shared names. Pinned in Task 1 (`one_shared_word_is_enough_for_search_but_not_lists`).
3. **Adding an "also" release, then reloading.** Both the card and the entry must show their new state without a refetch. Pinned in Task 6 (reducer test).
4. **A card whose winner is on the other tab.** It must vanish from this tab, not show up twice. Pinned in Task 4 (`indexers_tab_drops_a_scene_the_tracker_has`).
5. **A queued (not yet added) download of the same scene.** It counts as owned, so it isn't offered twice while it waits in the queue. Pinned in Task 4 (`a_queued_download_makes_its_scene_owned`).

---

### Task 1: `same.rs`: scene signature, grouping, owned matcher

**Files:**
- Create: `packages/plab/src/same.rs`, with tests in a `#[cfg(test)] mod tests` inside it, as `external.rs` does
- Modify: `packages/plab/src/main.rs` (add `mod same;`)
- Modify: `packages/plab/src/external.rs`. Make `release_date`, `words`, `STOP` and the date regexes `YMD`/`DMY`/`SHORT` `pub(crate)` where they are not already.

**Interfaces:**
- Produces:
  ```rust
  pub struct SceneSig { pub date: NaiveDate, pub names: HashSet<String> }
  pub fn sig(title: &str, noise: &[String], stop: &[&str]) -> Option<SceneSig>;
  pub fn same(a: &SceneSig, b: &SceneSig, min: usize) -> bool;
  pub const LIST_MIN: usize = 2;   // lists and Owned
  pub const SEARCH_MIN: usize = 1; // curated and assistant search
  pub fn groups(sigs: &[Option<SceneSig>]) -> Vec<Vec<usize>>;
  pub struct DownloadTitle { pub id: i64, pub topic_id: Option<u64>, pub title: String }
  pub struct Owned { /* private */ }
  impl Owned {
      pub fn new(downloads: &[DownloadTitle], noise: &[String]) -> Owned;
      /// The id of a download of this scene: by topic id first, then by signature.
      pub fn of(&self, topic_id: u64, sig: Option<&SceneSig>) -> Option<i64>;
  }
  pub fn studio_stop(title: &str) -> Vec<String>; // words of labels(title, 0).studio, lower-cased
  ```

**What `sig` does:**
1. `date` is `release_date(title)`. If there is none, return `None`.
2. Strip bracketed and parenthesized groups as `words` does, then find the first `YMD`/`DMY`/`SHORT` date match in the stripped text. If there is one, keep only the text after it. In 1337x-style titles everything before an unbracketed date is the studio. Tracker titles keep their date inside brackets, so nothing is dropped for them.
3. Run `words(rest, noise)`, then filter: keep words of 3+ characters that are all alphabetic, that are not in `STOP`, and whose lowercase is not in `stop`.

`same` means equal dates and at least `min` names in common (`names.intersection(..).count() >= min`). `groups` and `Owned` use `LIST_MIN`. `groups` is union-find over indices, comparing only entries whose dates are equal (bucket by date). Every index appears exactly once, groups keep input order, and the groups themselves are ordered by their first member.

`Owned::new` computes `sig(title, noise, &studio_stop(title))` once per download. `of(topic_id, sig)` checks two things in order:
1. a download whose `topic_id == Some(topic_id)` (any state);
2. otherwise, the first download whose signature is `same` as `sig`.

- [ ] **Step 1: Write the failing tests** in `same.rs`:

```rust
#[test] fn dated_and_reordered_namings_are_the_same_scene() {
    let x = sig("Studio B 26 10 30 Cara Kim And Dana Lee Close To You TAG 1080p MP4 GRP [RG]", &[], &[]).unwrap();
    let lab = sig("[StudioB.com] Dana Lee, Cara Kim - Close To You [2026-10-30, Couples, 1080p, SiteRip]", &[], &[]).unwrap();
    assert!(same(&x, &lab, LIST_MIN));
}
#[test] fn one_shared_word_is_enough_for_search_but_not_lists() {
    // same date, only "you" in common
    let a = sig("[Bravo] Ann Lee - Close To You [2026-10-30, 1080p]", &[], &[]).unwrap();
    let b = sig("[Delta] Bea Ray - Only You [2026-10-30, 1080p]", &[], &[]).unwrap();
    assert!(same(&a, &b, SEARCH_MIN));
    assert!(!same(&a, &b, LIST_MIN));
}
#[test] fn a_different_date_is_another_scene() { /* same names, 2026-10-31: !same(.., SEARCH_MIN) */ }
#[test] fn no_readable_date_has_no_signature() {
    assert!(sig("[StudioB.com] Dana Lee - Close To You [1080p]", &[], &[]).is_none());
}
#[test] fn studio_prefix_words_do_not_link() {
    let a = sig("Studio Bravo 26 10 30 Ann Lee Morning Light 1080p MP4", &[], &[]).unwrap();
    let b = sig("Studio Bravo 26 10 30 Bea Ray Evening Walk 1080p MP4", &[], &[]).unwrap();
    assert!(!same(&a, &b, SEARCH_MIN));
}
#[test] fn stop_and_noise_words_do_not_link() {
    // two bracket-dated titles sharing only "noisea" (noise) and "bravo" (stop)
    let n = vec!["noisea".to_string()];
    let a = sig("[Bravo] Ann Lee NoiseA Bravo [2026-10-30, 1080p]", &n, &["bravo"]).unwrap();
    let b = sig("[Bravo] Bea Ray NoiseA Bravo [2026-10-30, 1080p]", &n, &["bravo"]).unwrap();
    assert!(!same(&a, &b, SEARCH_MIN));
}
#[test] fn common_title_words_on_different_dates_do_not_link() { /* "... Close To You [2026-10-30]" vs other names "... Close To You [2026-09-01]": !same(.., SEARCH_MIN) */ }
#[test] fn grouping_is_transitive() {
    // all 2026-10-30: A shares "cara kim" with B, B shares "dana lee" with C (A and C share nothing); D has no date
    assert_eq!(groups(&[a, b, c, None]), vec![vec![0, 1, 2], vec![3]]);
}
#[test] fn owned_by_topic_id_then_by_signature() {
    let o = Owned::new(&[
        DownloadTitle { id: 7, topic_id: Some(42), title: "undated".into() },
        DownloadTitle { id: 9, topic_id: None, title: "Studio B 26 10 30 Cara Kim And Dana Lee Close To You 1080p".into() },
    ], &[]);
    assert_eq!(o.of(42, None), Some(7));
    let lab = sig("[StudioB.com] Dana Lee, Cara Kim - Close To You [2026-10-30, 1080p]", &[], &[]);
    assert_eq!(o.of(1, lab.as_ref()), Some(9));
    assert_eq!(o.of(1, None), None);
}
```

- [ ] **Step 2:** Run `cargo test same::`. Expected: compile failure (module missing).
- [ ] **Step 3:** Implement `same.rs` per the Interfaces block and the "What `sig` does" section above. Add a module doc comment that points to the spec.
- [ ] **Step 4:** Run `cargo test same::`. Expected: all pass. Then run `cargo clippy --all-targets -- -D warnings`. Expected: clean, apart from the `dead_code` that `#[allow]` covers until Task 4 (remove that allow in Task 4).
- [ ] **Step 5:** Commit: `feat(galactica): plab knows when two releases are the same scene`

### Task 2: curated and assistant search use `same` and `is_duplicate` goes

**Files:**
- Modify: `packages/plab/src/curated.rs:~376`
- Modify: `packages/plab/src/assistant/search.rs:~139`
- Modify: `packages/plab/src/external.rs`. Delete `is_duplicate` and, if it has no other callers, `person_tokens`, along with their tests.
- Test: `packages/plab/src/same.rs` tests

**Interfaces:**
- Consumes: `same::sig`, `same::same` (Task 1).

The replacement is a duplicate check: a candidate `c` is a duplicate when it has a signature that is `same(.., SEARCH_MIN)` as the signature of any title in `titles`. The two callers pass different stop words:
- **Curated** passes the term's lowercased words as `stop`, on both sides.
- **Assistant search** passes `&[]`, matching today's empty term.

Compute the tracker-title signatures once, outside the per-candidate loop.

- [ ] **Step 1: Port the tests.** Move `a_tracker_release_of_the_same_date_and_names_is_a_duplicate` into `same.rs`, rewritten against `sig`/`same` with the term's words as `stop`. Keep every one of its assertions and expected booleans.
- [ ] **Step 2:** Run `cargo test same::`. Expected: the ported test passes. If any original case flips, stop and report it rather than adjusting the expectation.
- [ ] **Step 3:** Swap both call sites and delete `is_duplicate`.
- [ ] **Step 4:** Run `cargo test` (the full suite). Expected: pass, including `plab_tests.rs`'s search duplicate tests from `cafef4a6`.
- [ ] **Step 5:** Commit: `refactor(galactica): plab curated and assistant search share the same-scene test`

### Task 3: every download's title, and a status per download

**Files:**
- Modify: `packages/plab/src/db/downloads.rs` (new method and its test, next to `download_rows`)
- Modify: `packages/plab/src/api.rs` (`Downloads`)
- Modify: `packages/plab/src/web.rs:446-491` (`downloads()` fills the new map)

**Interfaces:**
- Consumes: `same::DownloadTitle` (Task 1).
- Produces:
  - `Db::download_titles(&self) -> Result<Vec<same::DownloadTitle>>`. Returns every `download` row with `section = 'video'`, both states and all ages, ordered by `id`.
  - `Downloads.by_download: HashMap<i64, Status>`, filled in `web::downloads` for every row it already loops over.

- [ ] **Step 1: Write the failing test** `download_titles_cover_every_video_download`. Seed a queued video row, an added video row older than 30 days, a grab with no topic, and a games row. Assert that the result holds exactly the three video rows, with their ids, topic ids and titles.
- [ ] **Step 2:** Run `cargo test download_titles`. Expected: FAIL (no method).
- [ ] **Step 3:** Implement the method and the `by_download` map.
- [ ] **Step 4:** Run `cargo test`. Expected: pass.
- [ ] **Step 5:** Commit: `feat(galactica): plab reads every download's title and keys statuses by download`

### Task 4: one card per scene, the rest as "also", owned marked

**Files:**
- Modify: `packages/plab/src/api.rs` (`list`, `topic`, `TopicDto`, new `AlsoDto`)
- Modify: `packages/plab/src/web.rs` (`list`, `search`), plus any other `api::list` caller (`grep -rn "api::list("`)
- Test: `packages/plab/src/api_tests.rs`. Update the `reply`/`list_with_externals` helpers for the new parameters.

**Interfaces:**
- Consumes: `same::{sig, groups, Owned, studio_stop}` (Task 1), `Downloads.by_download` (Task 3).
- Produces:
  ```rust
  pub fn list(listing: &Listing, others: &[Listed], owned: &Owned, noise: &[String],
              added: &HashSet<u64>, queued: &HashSet<u64>, now: i64, section: Section,
              downloads: &Downloads, search: Option<SearchReply>,
              externals: &HashMap<u64, External>) -> ListDto;
  // TopicDto gains:
  pub also: Vec<AlsoDto>,
  pub owned_by: Option<i64>,   // serde: "ownedBy"
  #[derive(Debug, Serialize)] #[serde(rename_all = "camelCase")]
  pub struct AlsoDto { pub id: u64, pub source: Option<String>, pub seeders: u32,
                       pub size: u64, pub quality: Option<String>,
                       pub link: Option<String>, pub state: &'static str }
  ```

**Which listing `others` is, per caller:**

| Caller | `others` |
|---|---|
| `web::list(Video)` | the `indexers` listing's topics |
| `web::list(Indexers)` | the `video` listing's topics |
| everything else, including search | `&[]` |

Run the exclude filter `web::list` already applies over `others` as well. Noise is `crate::sources::load(st.sources_file.as_deref()).map(|s| s.noise)` or empty if that is absent. `owned` is `Owned::new(&st.db.download_titles()?, &noise)`.

**How `list` builds the cards:**
1. Sort this section's topics by `score`, as today.
2. Albums and Games skip grouping: every topic is its own group.
3. Otherwise, the pool is the sorted topics followed by `others`. Compute `sig(title, noise, &studio_stop(title))` for each and run `groups`.
4. Pick each group's winner. Members that are tracker topics (`!db::is_external(id)`) come first, and among those, the most seeders wins. The first member breaks ties.
5. Walk the sorted section topics. When a topic is its group's winner, emit its card with:
   - `also` set to the other members, in pool order;
   - `filters` set to the union of every member's filters, in first-seen order.

   A group whose winner is in `others` emits nothing on this tab.
6. `owned_by` for a card is `owned.of(id, sig)` over the winner first, then over each member, taking the first hit.
   - If it is `Some(d)` and the card's own `status` is `None`, use `downloads.by_download.get(&d)`, and failing that `StatusDto::Added`.
   - An `AlsoDto.state` comes from `added`/`queued` for its own id. It is `"added"` when the card has `owned_by` and the entry is in neither set.

`pending` and the other `ListDto` fields keep their current meaning.

- [ ] **Step 1: Write the failing tests** in `api_tests.rs`, using an indexer `External` for ids `≥ 1<<40` and the titles from Task 1's first test:
  - `a_tracker_and_an_indexer_release_of_one_scene_are_one_card`: the Video listing holds the tracker topic; `others` holds the indexer release. Expect one topic, `id` = tracker, `also[0].id` = the external, `also[0].source = "Indexer A"`.
  - `indexers_tab_drops_a_scene_the_tracker_has`: the same pair, with `section = Indexers` and the roles swapped. Expect `topics` to be empty.
  - `two_indexer_releases_of_one_scene_keep_the_better_seeded`: the Indexers section holds two externals with seeders 3 and 9. Expect one card, with `id` = the 9-seeder release.
  - `a_merged_card_carries_every_members_filters`: the members have filters `["a"]` and `["b"]`. Expect `["a","b"]`.
  - `a_scene_downloaded_through_another_release_is_owned`: `Owned` holds `DownloadTitle { id: 5, topic_id: None, title: <1337x title> }` and `by_download[5] = Status::InStash…` (use whatever variant `a_topic_with_a_download_carries_its_status` uses). Expect the tracker card to have `ownedBy = 5` and that status.
  - `a_queued_download_makes_its_scene_owned`: a download in the queued state with an old status, or no status at all. Expect `ownedBy` set, and the status `queued` if `by_download` has it, else `added`.
  - `albums_are_never_grouped`: two album externals with the same date and names. Expect two cards.
  - `undated_releases_are_never_merged_or_owned`.
- [ ] **Step 2:** Run `cargo test api_tests`. Expected: compile failure, then the new tests fail.
- [ ] **Step 3:** Implement, and update the existing callers and test helpers. Existing tests pass `&[]`, `&Owned::new(&[], &[])` and `&[]`.
- [ ] **Step 4:** Run `cargo test`, `cargo fmt`, and `cargo clippy --all-targets -- -D warnings`. Expected: all clean. Remove Task 1's `dead_code` allow.
- [ ] **Step 5:** Commit: `feat(galactica): plab shows one card per scene and marks scenes it already has`

### Task 5: the assistant does not offer owned scenes

**Files:**
- Modify: `packages/plab/src/assistant/context.rs:146-165` (`releases`)
- Test: `packages/plab/src/assistant/context.rs` tests, or `plab_tests.rs`, wherever `releases`/`gather` is tested today

**Interfaces:**
- Consumes: `Db::download_titles` (Task 3), `same::{Owned, sig, studio_stop}` (Task 1).

`releases(db, noise: &[String])` builds an `Owned` once and sets `downloaded = owned.of(row.id, sig(..).as_ref()).is_some()`. `gather` gets `noise` the way `assistant_routes.rs:371` gets sources (thread it through from the caller, or load `sources` there). Pick whichever needs fewer signature changes, and say which in the commit body.

- [ ] **Step 1: Write the failing test** `a_release_owned_through_another_source_is_downloaded`. Seed a Video listing with the tracker title and a grab `download` row (topic NULL) with the 1337x title. Expect `releases()` to report it `downloaded == true`. Assert also that an unrelated release reports `false`.
- [ ] **Step 2:** Run `cargo test a_release_owned`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `cargo test`. Expected: pass.
- [ ] **Step 5:** Commit: `feat(galactica): plab assistant leaves out scenes plab already downloaded`

### Task 6: the UI shows "also" and "have it"

**Files:**
- Modify: `packages/plab/ui/src/lib/types.ts` (`Topic` gains `also: Also[]` and `ownedBy: number | null`; new `Also`)
- Modify: `packages/plab/ui/src/lib/reducer.ts`. The `topicState` action also updates any `also` entry with that id.
- Modify: `packages/plab/ui/src/lib/format.ts`. Add `alsoLabel(a: Also): string`.
- Modify: `packages/plab/ui/src/components/AddButton.svelte`. Props become `{ id: number; state: TopicState; owned?: boolean; section: Section }`.
- Modify: `packages/plab/ui/src/components/Card.svelte`
- Test: `ui/src/lib/reducer.test.ts`, `ui/src/lib/format.test.ts`

**Interfaces:**
- Consumes: the JSON from Task 4. An `also` entry is `{id, source, seeders, size, quality, link, state}`; `ownedBy` is a number or null.

**UI copy:**
- `alsoLabel` gives `${source ?? 'Tracker'} · ${seeders} seeders`, followed by ` · ${quality}` when there is a quality.
- An owned card's AddButton reads `Have it ✓` and is disabled (no toggle).
- Each `also` entry is a row under the card's meta line: `also: <alsoLabel>`, a link to `link` when present, and a small AddButton (`btn-xs`) for its id. Stream follows whatever Card uses today for its own id.

- [ ] **Step 1: Write the failing tests.**
  - `reducer.test.ts` → `topicState updates a matching also entry`. Given a list whose topic 1 has `also: [{id: 2, state: ''}]`, the action `{type:'topicState', id: 2, state:'added'}` sets `also[0].state` to `'added'` and leaves topic 1's state alone.
  - `format.test.ts` → `alsoLabel` gives `'Indexer A · 42 seeders · 1080p'` and `'Tracker · 3 seeders'`.
- [ ] **Step 2:** Run `nix shell nixpkgs#nodejs -c npm test`. Expected: the new tests fail.
- [ ] **Step 3:** Implement. Update every `AddButton` usage to the new props (`grep -rn AddButton ui/src`).
- [ ] **Step 4:** Run `nix shell nixpkgs#nodejs -c npm test` and `nix shell nixpkgs#nodejs -c npm run build`. Expected: pass and build. Then run `cd ../../.. && nix build .#nixosConfigurations.galactica.config.services.plab.package 2>/dev/null || nix build .#plab`, using whichever attribute exists (check `package.nix`). Expected: build succeeds, since `package.nix` runs cargo tests and builds the UI.
- [ ] **Step 5:** Commit: `feat(galactica): plab cards list a scene's other releases and say when plab has it`
