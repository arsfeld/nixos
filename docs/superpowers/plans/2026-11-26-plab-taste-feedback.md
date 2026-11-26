# plab taste feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The plab assistant's taste profile counts only real watches, treats quick samples as a mild negative, and takes explicit +1/−1 votes on Stash scenes cast from plab's UI.

**Architecture:** Votes live in a new `scene_vote` table behind `/api/votes`. `taste.rs` turns plays (by Stash's `play_duration`) and votes into signed weights and an `avoid` list; `candidates.rs` subtracts avoided terms and drops voted-down scenes; the prompt gets the `avoid` list and two fixed sentences. The Svelte UI adds thumbs beside every Watch button and a Recently watched row on For you.

**Tech Stack:** Rust (axum, rusqlite, serde, wiremock tests), Svelte 5 + TypeScript (vitest).

**Spec:** `docs/superpowers/specs/2026-11-26-plab-taste-feedback-design.md`

## Global Constraints

- All work in `packages/plab`; commit straight to `master`, no branches. Conventional commits, scope `galactica`, never mention Claude.
- Rust checks: `cd packages/plab && cargo test` (all pass) and `cargo clippy --all-targets -- -D warnings`.
- UI checks: `cd packages/plab/ui && npm test && npm run check`.
- Constants exactly: `WATCHED_SECS = 120`, `SAMPLED_SECS = 30`, `VOTE = 2.0`, `SAMPLE = -0.5`, `AVOID_TOP = 10`; existing `HALF_LIFE_DAYS = 30.0`, `TOP = 15`, `LOOKBACK = 60 days` unchanged.
- Recently watched window: 14 days.
- Vote values on the wire: `1`, `-1`, and `0` (clear) in POST bodies; stored votes are only `1` / `-1`.
- Prompt-facing vote markers are ASCII `+1` and `-1`.
- New files follow the existing pattern: a module doc comment naming this spec.

## Review Focus

1. **A profile with only negative terms** (a new user who has only voted −1 or sampled): expect the release shortlist to fall back to what an empty profile offers, minus releases matching an avoided term, not an empty shortlist. Test in Task 3.
2. **Stash's `play_duration` as a float** (`4.27`) or `null`: expect it to parse and, when null, count as watched. Test in Task 2.
3. **A vote on a scene Stash no longer has**: expect gather to succeed with the scene skipped, and the scene still excluded from candidates. Test in Task 3.
4. **A card whose scenes disagree** (a release mapped to two scenes, one voted +1): expect neither thumb lit, and pressing one sets both. Test in Task 5.
5. **Pressing the same thumb twice quickly while the first request is in flight**: expect the second press ignored (button disabled while busy), as Watch does. Covered by the component following `WatchButton`'s `busy` pattern in Task 5; no separate test.

---

### Task 1: Votes table and db API

**Files:**
- Create: `packages/plab/src/db/schema_v10.sql`, `packages/plab/src/db/votes.rs`
- Modify: `packages/plab/src/db/mod.rs` (add `include_str!("schema_v10.sql")` after v9 in the migrations list; `mod votes;`)

**Interfaces:**
- Produces:
  - `Db::vote_set(&self, id: &str, vote: i8, now: i64) -> Result<()>`: upsert; `voted_at` set on insert and when the stored vote differs; same vote again keeps `voted_at`. Panics never; `vote` other than ±1 is the caller's job (the CHECK constraint rejects it as an error).
  - `Db::vote_clear(&self, id: &str) -> Result<()>`
  - `Db::votes(&self) -> Result<Vec<(String, i8, i64)>>`: `(scene_id, vote, voted_at)` ordered by `scene_id`.

- [ ] **Step 1: Write `schema_v10.sql`** with the `scene_vote` table exactly as in the spec's Data section.

- [ ] **Step 2: Write the failing tests** in `db/votes.rs` `#[cfg(test)]` using `Db::open_in_memory()`:

```rust
#[test] fn set_lists_and_clear_removes() {
    // vote_set("5", 1, 100); vote_set("3", -1, 200)
    // votes() == [("3", -1, 200), ("5", 1, 100)]
    // vote_clear("5"); votes() == [("3", -1, 200)]
}
#[test] fn same_vote_again_keeps_voted_at() {
    // vote_set("5", 1, 100); vote_set("5", 1, 900) → votes() == [("5", 1, 100)]
}
#[test] fn switching_refreshes_voted_at() {
    // vote_set("5", 1, 100); vote_set("5", -1, 900) → votes() == [("5", -1, 900)]
}
#[test] fn a_vote_outside_plus_minus_one_is_an_error() {
    // vote_set("5", 2, 100).is_err()
}
```

- [ ] **Step 3: Run** `cargo test db::votes` — expected FAIL (no such methods). `cargo test migrations_set_user_version` should already pass once v10 is included, since `USER_VERSION` derives from the list; confirm.

- [ ] **Step 4: Implement** the three methods in `db/votes.rs` following `db/watchlist.rs` (`self.with(|c| …)`). Upsert: `INSERT … ON CONFLICT(scene_id) DO UPDATE SET vote = excluded.vote, voted_at = excluded.voted_at WHERE scene_vote.vote <> excluded.vote`.

- [ ] **Step 5: Run** `cargo test db::` — expected PASS.

- [ ] **Step 6: Commit** `feat(galactica): plab stores +1/-1 votes on Stash scenes`.

---

### Task 2: Signed taste weights and the avoid list

**Files:**
- Modify: `packages/plab/src/stash/library.rs` (`LibScene.play_duration`, `FIELDS`), `packages/plab/src/taste.rs`

**Interfaces:**
- Produces (all in `taste.rs`):
  - Constants `WATCHED_SECS: u32 = 120`, `SAMPLED_SECS: u32 = 30`, `VOTE: f64 = 2.0`, `SAMPLE: f64 = -0.5`, `AVOID_TOP: usize = 10`.
  - `pub enum Play { Watched, Sampled, Neither }` and `pub fn play(watched_secs: Option<u32>, o_count: u32, rating: Option<u32>) -> Play`: Watched when secs is None, ≥ `WATCHED_SECS`, `o_count > 0` or rating is Some; Sampled when secs < `SAMPLED_SECS` (and not Watched); else Neither.
  - `View` gains `watched_secs: Option<u32>`, `vote: Option<(i8, i64)>`, `vote_only: bool` (true when the scene is here only because of a vote; its `at` is then the `voted_at`). Defaults keep today's behaviour for existing constructions (`watched_secs: None` = watched).
  - `weight(v, now)`: play part (skipped when `vote_only`; streams always use the Watched formula) + vote part `vote × VOTE × decay(voted_at)`.
  - `Profile` gains `avoid: Avoid`, `#[derive(Default, Serialize)] pub struct Avoid { pub studios: Vec<Weighted>, pub performers: Vec<Weighted>, pub tags: Vec<Weighted> }`.
  - Positive lists keep only weight > 0; `avoid` lists hold weight < 0, most negative first, `AVOID_TOP` each.
  - `recent(views, n)`: only views that are Watched, voted, or streamed; line suffixes in this order after the existing parts: `watched N min` (when `watched_secs >= WATCHED_SECS`, N = secs / 60), `+1` / `-1`, `streamed`.
- `LibScene.play_duration: Option<f64>` (`#[serde(default)]`), added to `FIELDS`.

- [ ] **Step 1: Write the failing tests** in `taste.rs` (extend the existing `view()` helper as needed):

```rust
#[test] fn constants() { assert_eq!((WATCHED_SECS, SAMPLED_SECS, AVOID_TOP), (120, 30, 10)); assert_eq!((VOTE, SAMPLE), (2.0, -0.5)); }
#[test] fn play_classifies() {
    assert_eq!(play(Some(120), 0, None), Play::Watched);
    assert_eq!(play(Some(10), 1, None), Play::Watched);      // o-count wins
    assert_eq!(play(Some(10), 0, Some(80)), Play::Watched);  // rating wins
    assert_eq!(play(None, 0, None), Play::Watched);          // no duration: today's behaviour
    assert_eq!(play(Some(29), 0, None), Play::Sampled);
    assert_eq!(play(Some(30), 0, None), Play::Neither);
    assert_eq!(play(Some(119), 0, None), Play::Neither);
}
#[test] fn sampled_weighs_minus_half_and_dead_zone_zero() { /* now=at: Some(5)→-0.5, Some(60)→0.0 */ }
#[test] fn vote_adds_two_decayed_from_its_own_time() {
    // watched (Some(600), o=1) at now + vote (1, now) → 1.5 + 2.0 = 3.5
    // vote_only with vote (-1, now - 30*DAY) → -1.0
}
#[test] fn net_negative_terms_go_to_avoid_only() {
    // Studio A: one watched view (+1) and one vote_only -1 (−2) → net −1: in avoid.studios, absent from studios
    // Studio B: watched → in studios, absent from avoid
}
#[test] fn avoid_is_most_negative_first_and_capped() { /* 12 studios with distinct negative weights → 10, ascending weight */ }
#[test] fn recent_lines_mark_watch_time_and_votes_and_skip_samples() {
    // watched Some(400) with vote +1 → "… · watched 6 min · +1"
    // vote_only -1 → "<voted_at date> · Title · … · -1"
    // sampled Some(5), no vote → no line
}
```

And in `stash/library.rs` tests:

```rust
#[test] fn play_duration_parses_float_and_null() {
    // serde_json::from_value(json!({"id":"1","play_duration":4.27})) → Some(4.27)
    // json!({"id":"1","play_duration":null}) → None
}
```

Update existing taste tests only where `Profile` construction now needs `avoid` (use `..Default::default()`); existing assertions must keep passing unchanged.

- [ ] **Step 2: Run** `cargo test taste stash::library` — expected FAIL (missing items).

- [ ] **Step 3: Implement** the interfaces above. `profile()` keeps one signed `HashMap` per kind (as now), then splits each into positives (`top`) and negatives (sorted ascending, truncated to `AVOID_TOP`). `watched_secs` comes from `play_duration` as `secs.max(0.0) as u32` (done in Task 3's `view_of`; here only the type).

- [ ] **Step 4: Run** `cargo test` — expected PASS (whole crate: `View` gained fields, so `context.rs` constructions must still compile via `..View::default()`).

- [ ] **Step 5: Commit** `feat(galactica): plab taste profile counts real watches and votes, and lists what to avoid`.

---

### Task 3: Context, shortlist, tools and prompt use votes

**Files:**
- Modify: `packages/plab/src/assistant/context.rs`, `packages/plab/src/candidates.rs`, `packages/plab/src/assistant/tools.rs`, `packages/plab/src/assistant/mod.rs`

**Interfaces:**
- Consumes: Task 1 `Db::votes()`; Task 2 `View` fields, `Profile.avoid`.
- Produces:
  - `context::views(db, stash, now)` (signature unchanged): fills `watched_secs` from `play_duration`, merges each scene's vote; voted scenes absent from the plays are fetched in one `stash.lib_scenes(&ids)` and added as `vote_only` views with `at = voted_at`. Votes on scenes Stash does not return are skipped.
  - `pub fn voted_down(db: &Db) -> HashSet<String>` in `context.rs` (empty on a db error, logged like the other reads).
  - `Context` gains nothing; `gather` passes `voted_down(db)` to `candidates`.
  - `candidates::candidates(profile: &Profile, scenes: &[SceneIn], releases: &[ReleaseIn], voted_down: &HashSet<String>) -> Vec<Candidate>`: `terms()` folds in `profile.avoid` (negative weights); scenes in `voted_down` excluded before scoring; candidates with score ≤ 0 dropped. When the profile has no **positive** term, releases fall back as today's empty-profile branch does, minus those scoring < 0.
  - `find_stash_scenes` leaves out `voted_down(db)` ids.
  - `assistant::mod`: `const TASTE_NOTES: &str` appended to the system content in `start` after CANDIDATES and before the degraded note, exactly:
    `"Terms under \"avoid\" in the profile are things the user voted down or sampled and abandoned: do not recommend on them, and say so if asked. +1 and -1 on recent views are the user's explicit votes and weigh more than plays."`

- [ ] **Step 1: Write the failing tests.**

`candidates.rs`:
```rust
#[test] fn an_avoided_term_lowers_a_score() { /* scene matching studio +3 and performer −2 scores 1.0 */ }
#[test] fn a_score_at_or_below_zero_is_dropped() { /* scene matching only an avoided performer → absent */ }
#[test] fn voted_down_scenes_are_excluded_even_when_they_match() { /* id "7" in voted_down, matches top studio → absent */ }
#[test] fn only_negative_terms_still_offer_releases_that_avoid_nothing() {
    // profile: avoid.studios = [StudioX −1]; releases "[StudioX.com] …" and "[StudioY.com] …"
    // → only the StudioY release is offered
}
```
Update existing `candidates(...)` call sites to pass `&HashSet::new()`.

`context.rs` (wiremock Stash, following the existing mocked-Stash tests in `assistant/mod.rs`):
```rust
#[tokio::test] async fn a_voted_never_played_scene_shapes_the_profile() {
    // db: vote_set("9", -1, now); Stash recent plays: []; lib_scenes(["9"]) → scene 9 with studio "Studio X"
    // views(...) has one vote_only view; profile(...).avoid.studios[0].name == "Studio X"
}
#[tokio::test] async fn a_vote_on_a_scene_stash_lost_is_skipped() { /* lib_scenes returns [] → views empty, no error, ok == true */ }
#[tokio::test] async fn stash_down_keeps_voted_down_exclusion() { /* voted_down(&db) == {"9"} with no Stash reachable */ }
#[test] fn play_duration_becomes_watched_secs() { /* view_of on a LibScene with play_duration 271.6 → Some(271) */ }
```

`tools.rs`:
```rust
#[tokio::test] async fn find_stash_scenes_leaves_out_voted_down() { /* Stash search → scenes 1, 2; vote −1 on "2" → only ref "s:1" */ }
```

`assistant/mod.rs`: in the existing test that inspects the stored system message, assert it contains `TASTE_NOTES` and `"avoid"`.

- [ ] **Step 2: Run** `cargo test candidates context tools assistant` — expected FAIL.

- [ ] **Step 3: Implement** the interfaces above.

- [ ] **Step 4: Run** `cargo test && cargo clippy --all-targets -- -D warnings` — expected PASS, no warnings.

- [ ] **Step 5: Commit** `feat(galactica): plab assistant drops voted-down scenes and steers away from avoided traits`.

---

### Task 4: Votes and Recently watched routes

**Files:**
- Create: `packages/plab/src/web/vote_routes.rs`
- Modify: `packages/plab/src/web.rs` (`mod vote_routes;`; route `/api/votes` and `/api/recent` like `/api/watchlist` at line ~321), `packages/plab/src/events.rs`, `packages/plab/src/web_tests.rs`

**Interfaces:**
- Consumes: Task 1 db API; Task 2 `taste::play`; `scene_dto::scene_dto`; `stash.recent_plays`.
- Produces:
  - `Event::Votes { votes: BTreeMap<String, i8> }` (serializes as `{"type":"votes","votes":{…}}`).
  - `GET /api/votes` → `{"votes": {id: ±1}}`.
  - `POST /api/votes` body `{"scenes": [String], "vote": i8}`: 1/−1 set, 0 clears, each scene; replies like GET and publishes `Event::Votes`. 400 when `vote` ∉ {−1,0,1} or `scenes` empty; body limit 64 KiB as the watchlist.
  - `GET /api/recent` → `{"scenes": [SceneDto]}`: `recent_plays(100)` filtered to `taste::play(...) == Play::Watched` and `last_played_at` within 14 days of now, newest first. Stash error → 502 with the error text.

- [ ] **Step 1: Write the failing tests** in `web_tests.rs`, following `watchlist_add_lists_ids_and_broadcasts`:

```rust
#[tokio::test] async fn votes_set_switch_clear_and_broadcast() {
    // POST {"scenes":["5","3"],"vote":1} → {"votes":{"3":1,"5":1}}; event Votes received with the same map
    // POST {"scenes":["5"],"vote":-1} → {"3":1,"5":-1}
    // POST {"scenes":["3"],"vote":0} → {"5":-1}; GET /api/votes → same
}
#[tokio::test] async fn votes_reject_bad_input() { /* vote 2 → 400; scenes [] → 400 */ }
#[tokio::test] async fn recent_keeps_real_watches_from_the_last_two_weeks() {
    // Stash plays: A 300 s 1 day ago; B 5 s 1 day ago; C 300 s 20 days ago; D null duration 2 days ago
    // → ids [A, D]
}
#[tokio::test] async fn recent_is_502_when_stash_fails() {}
```

- [ ] **Step 2: Run** `cargo test web_tests::votes web_tests::recent` — expected FAIL.

- [ ] **Step 3: Implement** `vote_routes.rs` with `pub async fn votes<B>(st, method, body)` and `pub async fn recent<B>(st)`, structured like `watchlist_routes.rs`; add the `Votes` variant to `events.rs`.

- [ ] **Step 4: Run** `cargo test && cargo clippy --all-targets -- -D warnings` — expected PASS.

- [ ] **Step 5: Commit** `feat(galactica): plab serves votes and recently watched scenes`.

---

### Task 5: Thumbs beside every Watch button

**Files:**
- Create: `packages/plab/ui/src/lib/votes.ts`, `packages/plab/ui/src/lib/votes.test.ts`, `packages/plab/ui/src/lib/votes.svelte.ts`, `packages/plab/ui/src/components/VoteButtons.svelte`
- Modify: `packages/plab/ui/src/lib/types.ts` (`ServerEvent` gains `| { type: 'votes'; votes: Votes }`; `export type Votes = Record<string, 1 | -1>`), `packages/plab/ui/src/lib/api.ts`, `packages/plab/ui/src/App.svelte` (load and apply beside `watchlist`), `SceneCard.svelte`, `Card.svelte`, `GrabPoster.svelte`, `GrabsStrip.svelte` (place `<VoteButtons scenes={…} small? />` right after each `WatchButton`, same `scenes` and `small`)

**Interfaces:**
- Consumes: Task 4 routes and event.
- Produces:
  - `api.ts`: `fetchVotes(): Promise<Votes>`, `postVotes(scenes: string[], vote: 1 | -1 | 0): Promise<Votes>`.
  - `votes.ts`: `voteOf(votes: Votes, scenes: string[]): 1 | -1 | 0` (±1 only if non-empty and all agree), `voteAction(current: 1 | -1 | 0, pressed: 1 | -1): 1 | -1 | 0`, `nextVotes(votes: Votes, ev: ServerEvent): Votes`, `unvotedFirst<T extends { id: string }>(scenes: T[], votes: Votes): T[]` (stable).
  - `votes.svelte.ts`: `export const votes` store with `map: Votes` (`$state`), `load()`, `apply(ev)`, `set(scenes, vote)`, mirroring `WatchlistStore`.
  - `VoteButtons.svelte`: props `{ scenes: string[]; small?: boolean }`; renders nothing when `scenes` is empty; 👍 / 👎 ghost buttons, the active one `text-success` / `text-error`, the other `opacity-50` when a vote exists; disabled while busy; `title` "Liked: press to clear" / "Like" (and the dislike equivalents), or the error.

- [ ] **Step 1: Write the failing tests** in `votes.test.ts`:

```ts
test('voteOf needs every scene to agree', () => {
  expect(voteOf({ a: 1, b: 1 }, ['a', 'b'])).toBe(1);
  expect(voteOf({ a: 1 }, ['a', 'b'])).toBe(0);
  expect(voteOf({ a: 1, b: -1 }, ['a', 'b'])).toBe(0);
  expect(voteOf({}, [])).toBe(0);
});
test('voteAction toggles and switches', () => {
  expect(voteAction(0, 1)).toBe(1);
  expect(voteAction(1, 1)).toBe(0);
  expect(voteAction(1, -1)).toBe(-1);
});
test('nextVotes takes a votes event and ignores others', () => { /* votes event → its map; watchlist event → unchanged object */ });
test('unvotedFirst keeps order within each group', () => { /* [a(voted), b, c(voted), d] → [b, d, a, c] */ });
```

- [ ] **Step 2: Run** `npm test` — expected FAIL.

- [ ] **Step 3: Implement** the interfaces and place the component.

- [ ] **Step 4: Run** `npm test && npm run check` — expected PASS, no warnings.

- [ ] **Step 5: Commit** `feat(galactica): plab has thumbs up and down beside every Watch button`.

---

### Task 6: Recently watched on For you

**Files:**
- Modify: `packages/plab/ui/src/lib/api.ts` (`fetchRecent(): Promise<SceneDto[]>`, using the existing scene type the watchlist uses), `packages/plab/ui/src/components/DailyView.svelte`

**Interfaces:**
- Consumes: Task 4 `GET /api/recent`; Task 5 `votes` store, `unvotedFirst`.

- [ ] **Step 1: Implement** a "Recently watched" section below the picks in `DailyView`: fetch once on mount; render `unvotedFirst(scenes, votes.map)` as `SceneCard`s (they carry Watch and the thumbs); hidden when the list is empty or the fetch failed (no error shown). Ordering reacts to the store, so no refetch on vote.

- [ ] **Step 2: Run** `npm test && npm run check && npm run build` — expected PASS.

- [ ] **Step 3: Commit** `feat(galactica): plab For you lists recently watched scenes to vote on`.

---

### Task 7: Build, deploy, accept

- [ ] **Step 1: Build** `nix build .#nixosConfigurations.galactica.config.system.build.toplevel` from the repo root — expected success (the package's `cargoHash`/`npmDepsHash` are unchanged since no dependency was added; if one fails, update it).
- [ ] **Step 2: Push** `git push origin master`, then ask the user before deploying; on approval `nix develop -c just deploy galactica`.
- [ ] **Step 3: Accept on galactica:** in plab, vote −1 on a scene under Recently watched; press Recommend; read the new conversation's system message (`sqlite3` on plab's `state.db`, table `message`, role `system`) and confirm: that scene's studio or performers under `"avoid"` or lower than before; no candidate `"ref":"s:<that id>"`; no recent line from a 1-9 s sample; `TASTE_NOTES` present.
- [ ] **Step 4: Update the spec** if anything measured differs, and commit.
