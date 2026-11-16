# plab Watchlist Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Watchlist tab of Stash scenes queued to watch, with a ☆ on every plab card that has a Stash scene, and auto-removal once Stash records a play after queueing.

**Architecture:** A `watchlist` table keyed by Stash scene id. `/api/watchlist…` routes (own module, like `assistant_routes`) read and write it, expire played scenes on GET via one `lib_scenes` call, and broadcast a `watchlist` event. Download statuses expose their scene ids so release cards and Recent grabs can show the ☆; `SceneCard` covers For you and assistant picks.

**Tech Stack:** Rust (plab daemon: rusqlite, axum, serde, wiremock tests), Svelte 5 + TypeScript (vitest, svelte-check).

**Spec:** `docs/superpowers/specs/2026-11-16-plab-watchlist-design.md`

## Global Constraints

- Rust commands run from `packages/plab`: `cargo test <filter>`, `cargo fmt`, `cargo clippy --all-targets -- -D warnings`.
- UI commands run from `packages/plab/ui`: `nix shell nixpkgs#nodejs -c npm test`, `nix shell nixpkgs#nodejs -c npm run check`, `nix shell nixpkgs#nodejs -c npm run build`.
- Commit straight to master, conventional commits, scope `galactica` (e.g. `feat(galactica): plab …`), matching the existing plab history. Never mention Claude.
- A new file must be `git add`ed (or `git add -N`) before any `nix build` sees it.
- The assistant gains no tool: it stays read-only.
- Empty-state copy, verbatim: `Nothing queued. ☆ Watch appears on any card for a scene that's in Stash.`
- Button labels, verbatim: `☆ Watch` / `★ Watching`.

## Review Focus

1. **Pack partly queued:** a pack card with 2 of 3 scenes queued shows `☆ Watch`, and clicking it queues the missing one rather than removing the two. Pinned in Task 5 (`toggle` test).
2. **Stash down while the Watchlist loads:** nothing is removed and the tab shows the error. If an outage looked like "every scene gone", the whole list would be wiped. Pinned in Task 4 (`watchlist_get_with_stash_down_removes_nothing`).
3. **Re-queueing a scene already watched:** a scene played last month and queued today stays on the list. Pinned in Task 2 (`played_before_queued_stays`).
4. **Re-adding an already-queued scene** (e.g. a pack whose scenes are partly queued) keeps the original `added_at`, so the order and the expiry clock don't reset. Pinned in Task 1 (`add_keeps_first_added_at`).
5. **Another open tab:** queueing on one page flips the star on another page without a reload. Pinned in Task 4 (the add test asserts the broadcast) and Task 5 (`applyEvent` test).

---

### Task 1: The `watchlist` table

**Files:**
- Create: `packages/plab/src/db/schema_v8.sql`, `packages/plab/src/db/watchlist.rs`
- Modify: `packages/plab/src/db/mod.rs` (`mod watchlist; pub use watchlist::*;`, one `MIGRATIONS` entry)

**Interfaces:**
- Produces, on `impl Db`:
  - `watch_add(&self, ids: &[String], now: i64) -> Result<()>`
  - `watch_remove(&self, ids: &[String]) -> Result<()>`
  - `watch_list(&self) -> Result<Vec<(String, i64)>>`: `(scene_id, added_at)`, oldest `added_at` first, ties broken by `scene_id`
  - `watch_ids(&self) -> Result<Vec<String>>`: the ids, in the same order

- [ ] **Step 1: Write the failing tests** in a `#[cfg(test)] mod tests` in `db/watchlist.rs`, opening a `Db` on a tempdir as other db tests do:
  - `add_then_list_is_oldest_first`: add `["2"]` at 200, then `["1"]` at 100 → `watch_list() == [("1",100),("2",200)]`.
  - `add_keeps_first_added_at`: add `["1"]` at 100, then `["1","2"]` at 300 → `[("1",100),("2",300)]`.
  - `remove_drops_only_named`: add `["1","2"]`, remove `["1","9"]` → `watch_ids() == ["2"]`.
- [ ] **Step 2: Run** `cargo test db::watchlist`. Expected: compile failure (no such methods).
- [ ] **Step 3: Implement.** `schema_v8.sql` is the spec's `CREATE TABLE watchlist` verbatim, comment included. Append `include_str!("schema_v8.sql")` to `MIGRATIONS`. Use `INSERT OR IGNORE` for add, one transaction per call, and the `self.with(|c| …)` pattern from `db/kv.rs`.
- [ ] **Step 4: Run** `cargo test db::` (all db tests, the migration ones included). Expected: PASS.
- [ ] **Step 5: Commit:** `feat(galactica): plab stores a watchlist of Stash scenes`.

### Task 2: The auto-removal rule

**Files:**
- Create: `packages/plab/src/watchlist.rs`
- Modify: `packages/plab/src/main.rs` (`mod watchlist;`)

**Interfaces:**
- Consumes: `crate::stash::library::LibScene` (`id: String`, `last_played_at: Option<String>`, RFC 3339).
- Produces: `pub fn expired(rows: &[(String, i64)], scenes: &[LibScene]) -> Vec<String>`. It returns the row ids, in row order, whose scene was played after `added_at` or is missing from `scenes`.

- [ ] **Step 1: Write the failing tests** (build `LibScene`s with `serde_json::from_value`, as `stash/library.rs`'s tests do). Each case uses a row `("1", T)` where `T` = `2026-11-10T12:00:00Z` as unix time:
  - `played_after_queued_expires`: `last_played_at = "2026-11-11T00:00:00Z"` → `["1"]`
  - `played_before_queued_stays`: `"2026-10-01T00:00:00Z"` → `[]`
  - `never_played_stays`: `None` → `[]`
  - `missing_from_stash_expires`: `scenes` empty → `["1"]`
  - `unparseable_play_time_stays`: `"yesterday"` → `[]`
  - `offset_times_compare_as_instants`: `"2026-11-10T08:00:01-04:00"` (one second after `T`) → `["1"]`
- [ ] **Step 2: Run** `cargo test watchlist::`. Expected: compile failure.
- [ ] **Step 3: Implement `expired`.** Parse with the RFC 3339 parser already in plab's dependency tree. Check `Cargo.toml` (`chrono` or `time`) and do not add a crate.
- [ ] **Step 4: Run** `cargo test watchlist::`. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(galactica): plab expires watchlist scenes played after they were queued`.

### Task 3: Statuses carry their scene ids

**Files:**
- Modify: `packages/plab/src/api.rs` (`StatusDto::InStash`, `StatusDto::Identified`, `fn status`)
- Modify: `packages/plab/ui/src/lib/types.ts` (`Status`)
- Test: `packages/plab/src/api_tests.rs`

**Interfaces:**
- Produces: `StatusDto::InStash { link: Option<String>, scenes: Vec<String> }`, and `Identified { …, scenes: Vec<String> }`. JSON: `{"kind":"inStash","link":…,"scenes":["12"]}`. On the TS side, `inStash` and `identified` gain `scenes: string[]`.

- [ ] **Step 1: Write the failing test.** `in_stash_and_identified_statuses_carry_scenes` calls `api::status` on a `Status::InStash { scenes: vec!["12".into(), "13".into()], folder: None }` and on an `Identified` with `scenes: vec!["7".into()]`, and asserts the serialized JSON's `scenes` arrays are `["12","13"]` and `["7"]`. Update any existing test that pins the full JSON of these two statuses so it includes `scenes`.
- [ ] **Step 2: Run** `cargo test api`. Expected: FAIL.
- [ ] **Step 3: Implement.** Clone `scenes` from the `Status` in `fn status`, then add `scenes: string[]` to both TS variants.
- [ ] **Step 4: Run** `cargo test` (full suite: `grabs_carry_studio_title_age_and_status` and the web JSON tests must still pass), then `nix shell nixpkgs#nodejs -c npm run check` in `ui`. Expected: PASS.
- [ ] **Step 5: Commit:** `feat(galactica): plab download statuses list their Stash scene ids`.

### Task 4: `/api/watchlist` routes and the `watchlist` event

**Files:**
- Create: `packages/plab/src/web/scene_dto.rs`: `SceneDto`, `scene_dto` and `rebase`, moved verbatim from `web/assistant_routes.rs` (with their tests, if any) and made `pub(super)`. `assistant_routes` imports them from here.
- Create: `packages/plab/src/web/watchlist_routes.rs`
- Modify: `packages/plab/src/web.rs`: `mod scene_dto; mod watchlist_routes;`, a `pub stash: Option<Stash>` field on `WebState`, and dispatch in `handle` before the method match: `if let Some(rest) = path.strip_prefix("/api/watchlist") { return watchlist_routes::route(&st, &method, rest, body).await; }`
- Modify: `packages/plab/src/commands.rs` (`stash: Some(crate::app::stash(&a.cfg))` in the `WebState` literal)
- Modify: `packages/plab/src/events.rs` (`Event::Watchlist { ids: Vec<String> }`)
- Test: `packages/plab/src/web_tests.rs` (`Fx` gets `stash: None`; a wiremock-backed variant sets `Some(Stash::new(&format!("{uri}/graphql"), None))` as `assistant_fx` does)

**Interfaces:**
- Consumes: Task 1's `watch_*`, Task 2's `watchlist::expired`, `Stash::lib_scenes(&[String]) -> anyhow::Result<Vec<LibScene>>`, and `assistant::context::bounded` for the Stash call's timeout, as the picks route uses it.
- Produces, with these routes (`rest` is the path after `/api/watchlist`):

| method, `rest` | reply |
|---|---|
| GET `""` | 200 `{now, scenes: WatchSceneDto[], error: string \| null}` |
| GET `"/ids"` | 200 `{ids: string[]}` |
| POST `"/add"`, POST `"/remove"` | body `{scenes: string[]}` → 200 `{ids: string[]}` (the full set after the change), then `events.publish(Event::Watchlist { ids })` |
| anything else | 404 |

  - `WatchSceneDto` is `SceneDto` flattened (`#[serde(flatten)]`) plus `added_at` (serialized as `addedAt`), in `watch_list` order.
  - GET `""` sequence: `watch_list()`, then `lib_scenes(ids)`. On `Ok`: `watch_remove(expired(..))` and return the remaining rows' scenes. On `Err`, or `stash` is `None`: remove nothing, `scenes: []`, `error: Some(message)`; the message for `None` is `"Stash is not configured"`.
  - A body that isn't JSON, or whose `scenes` is missing or empty → 400. Read it with `axum::body::to_bytes(body, BODY_LIMIT)`, as `read_text` does.

- [ ] **Step 1: Write the failing tests** in `web_tests.rs`:
  - `watchlist_add_lists_ids_and_broadcasts`: subscribe to `fx.state.events`, POST `/api/watchlist/add` `{"scenes":["5","3"]}` → 200 `{"ids":["5","3"]}`, and the next event is `Event::Watchlist { ids: ["5","3"] }`. Then GET `/api/watchlist/ids` → `{"ids":["5","3"]}`.
  - `watchlist_remove_replies_with_rest`: add `["1","2"]`, remove `["1"]` → `{"ids":["2"]}`.
  - `watchlist_bad_body_is_400`: POST `/api/watchlist/add` with `{}` and with `{"scenes":[]}` → 400 each.
  - `watchlist_get_expires_played_and_missing`: wiremock Stash. Seed rows `a` (added at `T`), `b` (`T`), `c` (`T`). `findScenes` returns `a` played after `T` and `b` never played; `c` is absent. Assert the reply's `scenes` contains only `b`, with `id`, `title`, `addedAt == T`, and `link == "https://stash.example/scenes/b"` (set `stash_web_url`). Assert `db.watch_ids() == ["b"]`.
  - `watchlist_get_with_stash_down_removes_nothing`: wiremock answers 500. The reply has `error` non-null and `scenes == []`; `watch_ids()` is unchanged.
  - `watchlist_get_without_stash_reports_it`: `Fx::new()` → `error == "Stash is not configured"`.
  - Events: `Event::Watchlist { ids: vec!["1".into()] }` serializes to `{"type":"watchlist","ids":["1"]}` (in `events_tests.rs`, beside the other shape tests).
- [ ] **Step 2: Run** `cargo test watchlist`. Expected: compile failure.
- [ ] **Step 3: Implement** the move, the field, the event and the routes as specified above.
- [ ] **Step 4: Run** `cargo test`, `cargo clippy --all-targets -- -D warnings`, `cargo fmt --check`. Expected: all clean. Run the assistant picks tests by name too (`cargo test assistant`) to confirm the `scene_dto` move changed nothing.
- [ ] **Step 5: Commit:** `feat(galactica): plab serves the watchlist and expires played scenes`.

### Task 5: UI state: types, API calls, the watched set, the route

**Files:**
- Create: `packages/plab/ui/src/lib/watchlist.ts` (pure), `packages/plab/ui/src/lib/watchlist.svelte.ts` (store), `packages/plab/ui/src/lib/watchlist.test.ts`
- Modify: `ui/src/lib/types.ts`, `ui/src/lib/api.ts`, `ui/src/lib/route.ts`, `ui/src/lib/route.test.ts`, `ui/src/App.svelte` (event wiring, initial load)

**Interfaces:**
- Consumes: Task 4's routes and event.
- Produces:
  - `types.ts`: `interface WatchScene extends SceneCardData { addedAt: number }`; `interface WatchlistReply { now: number; scenes: WatchScene[]; error: string | null }`; `ServerEvent` gains `{ type: 'watchlist'; ids: string[] }`.
  - `api.ts`: `fetchWatchlist(): Promise<WatchlistReply>`, `fetchWatchIds(): Promise<string[]>`, `postWatch(action: 'add' | 'remove', scenes: string[]): Promise<string[]>` (throws on non-200 with the response text).
  - `watchlist.ts` (pure):
    - `watching(set: ReadonlySet<string>, ids: string[]): boolean`: true iff `ids` is non-empty and every id is in `set`.
    - `toggleAction(set, ids): 'add' | 'remove'`: `'remove'` iff `watching(set, ids)`.
  - `watchlist.svelte.ts`: `export const watchlist` with `ids: Set<string>` (reactive, `SvelteSet` or a replaced `$state` Set), `load(): Promise<void>`, `apply(ev: ServerEvent): void` (replaces `ids` on a `watchlist` event, ignores others), and `toggle(ids: string[]): Promise<void>` (calls `postWatch(toggleAction(…))` and replaces `ids` with the reply).
  - `route.ts`: `Route` gains `{ view: 'watchlist' }`; `parse('/watchlist', '')` returns it.
  - `App.svelte`: `watchlist.load()` on mount and on reconnect; `watchlist.apply(ev)` on every event.

- [ ] **Step 1: Write the failing tests:**
  - `watchlist.test.ts`: `watching(new Set(['1','2']), ['1','2']) === true`; `watching(new Set(['1']), ['1','2']) === false`; `watching(new Set(), []) === false`; `toggleAction(new Set(['1','2']), ['1','2','3']) === 'add'` (pack partly queued → add); `toggleAction(new Set(['1']), ['1']) === 'remove'`.
  - `watchlist.test.ts`: `apply` replaces `ids` from `{type:'watchlist', ids:['9']}` and leaves them alone on `{type:'resync'}`. Test it through an exported pure `nextIds(current, ev)` in `watchlist.ts` if the store is awkward to test.
  - `route.test.ts`: `parse('/watchlist', '')` → `{ view: 'watchlist' }`.
- [ ] **Step 2: Run** `nix shell nixpkgs#nodejs -c npm test`. Expected: FAIL.
- [ ] **Step 3: Implement** the above.
- [ ] **Step 4: Run** `npm test` and `npm run check`. Expected: PASS, no warnings.
- [ ] **Step 5: Commit:** `feat(galactica): plab UI keeps the set of watched scenes`.

### Task 6: UI components: the ☆ button and the Watchlist tab

**Files:**
- Create: `ui/src/components/WatchButton.svelte`, `ui/src/components/WatchlistView.svelte`
- Modify: `ui/src/components/Card.svelte` (action row, after `StatusBadge`), `ui/src/components/GrabsStrip.svelte` (after each row's `StatusBadge`), `ui/src/components/SceneCard.svelte` (action row; `reason` becomes optional; the action row also renders when `link` is null so the ☆ still shows), `ui/src/components/Navbar.svelte` (tab `['watchlist', '/watchlist', 'Watchlist']` right after For you), `ui/src/App.svelte` (`{:else if router.route.view === 'watchlist'}<WatchlistView />`)

**Interfaces:**
- Consumes: Task 5's `watchlist` store, `fetchWatchlist`, `watching`; Task 3's `status.scenes`.
- Produces:
  - `WatchButton` props: `{ scenes: string[]; small?: boolean }`. It renders nothing for `[]`, and `btn-ghost` with `btn-xs` when `small`, else `btn-sm`. The label is `★ Watching` when `watching(watchlist.ids, scenes)`, else `☆ Watch`. A failed toggle sets the button's `title` to the error.
  - Scene ids for a release card or a grab: `status.kind === 'inStash' || status.kind === 'identified' ? status.scenes : []`. Put this in `watchlist.ts` as `statusScenes(status: Status | null): string[]`, and add a test for it to `watchlist.test.ts` in this task (`inStash` → its scenes, `added` → `[]`, `null` → `[]`).
  - `WatchlistView`: loads on mount, on a `watchlist` event, and on `resync`, discarding a stale reply as `ListView` does. Heading `Watchlist ({n})`, the error (if any) in the same alert style the list views use, then the For you grid (copy `DailyView`'s grid classes) of `SceneCard`s with `reason={'added ' + age(s.addedAt, now)}`. A scene whose id leaves `watchlist.ids` disappears at once (filter by the set). Empty copy is in Global Constraints.

- [ ] **Step 1: Write the failing test:** `statusScenes` cases in `watchlist.test.ts`. Run `npm test`: FAIL.
- [ ] **Step 2: Implement** `statusScenes`, the two components and the five modifications.
- [ ] **Step 3: Run** `npm test`, `npm run check`, `npm run build`. Expected: all pass, no warnings.
- [ ] **Step 4: Check it in a browser.** Run the daemon locally if the repo's existing dev setup allows it. Otherwise run `npm run dev` with a mocked `/api`, or describe what could not be checked. Confirm:
  - the tab appears after For you
  - ☆ shows on an in-Stash card and on a pick, and toggles to ★
  - the Watchlist tab lists the scene, and ★ there removes it
  - the empty state text matches
  Report what was and was not checked.
- [ ] **Step 5: Commit:** `feat(galactica): plab has a Watchlist tab and a Watch button on every Stash scene`.

### Task 7: Build and deploy

**Files:** none new.

- [ ] **Step 1:** From the repo root: `nix build .#plab` (or the attribute `packages/plab/package.nix` is exposed as; check with `nix eval .#packages.x86_64-linux --apply builtins.attrNames`). Expected: builds, with Rust and UI tests run in the derivation if it runs them.
- [ ] **Step 2:** `nix build .#nixosConfigurations.galactica.config.system.build.toplevel`. Expected: builds. One host only, niced.
- [ ] **Step 3:** Push to `origin master`, then ask the user before deploying: `nix develop -c just deploy galactica`.
- [ ] **Step 4:** After deploy:
  - `journalctl -u plab -n 50` shows the v8 migration ran without error.
  - `curl` of `/api/watchlist/ids` via `localhost:8577` on galactica returns `{"ids":[]}`.
