# plab assistant release search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The plab assistant gains a `search_releases(q)` tool that searches the tracker and Prowlarr, and its picks from those results render as cards drawn from the stored tool result.

**Architecture:** A pure-ish `search_releases` over `Ctx` does both halves and stores hits as search hits. The `Assistant` reaches it through a `ReleaseSearch` trait object set after `WebState` exists (it holds a `Weak<WebState>`, because `WebState` owns the assistant). The conversation builder falls back to the conversation's own stored tool results for picks that are not on a list.

**Tech Stack:** Rust (tokio, serde_json, rusqlite, wiremock in tests), Svelte 5 + vitest for the UI.

**Spec:** `docs/superpowers/specs/2026-11-06-plab-assistant-search-design.md`

## Global Constraints

- All work under `packages/plab/`. Run Rust tests from there: `cargo test <name>`; UI from `packages/plab/ui`: `npm test` and `npm run check`.
- Commit straight to `master`; conventional commits, scope `galactica` (e.g. `feat(galactica): plab …`), matching the package's history. Never mention Claude.
- Tool results are JSON strings; a failure the model can read is data (`{"error": …}` or an `errors` entry), never an `Err` out of `tools::run`.
- At most 20 results per call (`tools::LIMIT`).
- Prowlarr's `download_url` never appears in a tool result.
- Search hits live `SEARCH_TTL` (86400 s); nothing in this plan adds a table or migration.

## Review Focus

1. **Same release from both halves** — a Prowlarr result that is the tracker hit under another name must be dropped, not shown twice (Task 1 test `search_releases_drops_prowlarr_duplicate_of_tracker_hit`).
2. **A pick naming a ref the model invented, or one from a different conversation's search** — must still be dropped; only this conversation's `search_releases` results back a card (Task 4 test `pick_from_another_conversations_search_is_dropped`).
3. **The same ref in two searches in one conversation** — the latest snapshot wins (Task 4 test `latest_search_result_wins`).
4. **A hidden title** — the hide rule drops it from both halves, so the model never sees it (Task 1 test `search_releases_applies_hide_rule`).
5. **Assistant built without a search handle (tests, or before `set_search`)** — the tool is not offered and a stray call returns an error, not a panic (Task 2 test `search_tool_absent_without_handle`).

---

### Task 1: `search_releases` over `Ctx`

**Files:**
- Create: `packages/plab/src/assistant/search.rs` (declare `pub mod search;` in `assistant/mod.rs`)
- Modify: `packages/plab/src/curated.rs:294` — `candidate` becomes `pub(crate)`
- Test: `packages/plab/src/plab_tests.rs` (its `Env`, `FakeTracker`, `prowlarr()`, `ext_result()` fixtures)

**Interfaces:**
- Consumes: `plab::run_search(ctx, q, now) -> anyhow::Result<Vec<Listed>>`, `curated::candidate(&ProwlarrResult, cutoff: i64) -> Option<Candidate>`, `external::{collapse, is_duplicate}`, `Db::{upsert_external, save_search}`, `filters::{load_excludes, title_terms, HideRule::hides}`, `Prowlarr::{indexers, search_in}`.
- Produces: `pub async fn search_releases<B: Backends>(ctx: &Ctx<'_, B>, sources: Option<&Sources>, hide: &HideRule, q: &str, now: i64) -> anyhow::Result<serde_json::Value>` returning `{"results": [Hit…], "errors"?: [String…]}`, each hit `{"ref": "t:<id>", "title", "source", "size", "seeders", "leechers", "published"}`. `source` is `"tracker"` or the indexer name.

Behaviour the tests pin:
- Tracker half: `run_search`; titles the hide rule hides (`hide.hides(&title_terms(title))`) are dropped; `published` is `row.added`.
- Prowlarr half, skipped silently when `ctx.prowlarr` is `None`: indexers enabled, `protocol == "torrent"`, name ≠ `sources.primary_indexer`; none left → error `"Prowlarr: no enabled indexer besides the tracker's"`. `sources` `None` or no categories → error `"Prowlarr: plab-sources names no categories"`. `candidate(r, i64::MIN)` (no age cutoff), exclude list, hide rule, `collapse(_, noise)`, then drop `is_duplicate(title, &tracker_titles, q, noise)`. Each survivor: `upsert_external(&NewExternal{kind: Kind::Torrent, files: None, seen: now, …})` for its id, then `ctx.db.save_search(&[Row{id, title, forum: 0, size, seeders, leechers, completed: 0, added: published}], now)`. Prowlarr hits sorted by seeders, descending, after the tracker hits.
- Either half's failure is an `errors` entry prefixed `"Tracker: "` / `"Prowlarr: "`; a storage error (`upsert_external`/`save_search`) is the function's `Err`.
- Truncate the merged list to `tools::LIMIT` (make it `pub(crate)`).

- [ ] **Step 1: Write the failing tests** in `plab_tests.rs`:
  - `search_releases_returns_tracker_and_prowlarr_hits` — tracker `searched["alpha"]` holds row 7 "Alpha One"; `prowlarr("alpha", [ext_result("g1", "Alpha Two 1080p", 5, …)])`. Assert results `[0]` is `{"ref":"t:7","source":"tracker",…}`, `[1]` has `source == "Indexer A"` and a ref `t:<id>` with `id >= EXTERNAL_BASE`, `env.db.find(id, NOW)` is `Some`, `db.external(id)` is `Some`, no `errors` key, and the serialized output does not contain the mock's download URL.
  - `search_releases_drops_prowlarr_duplicate_of_tracker_hit` — same release title on both sides; one result.
  - `search_releases_applies_hide_rule` — a hide term in both halves' titles; neither returned.
  - `search_releases_reports_one_half_failing` — `search_error = Some(Fail::Http)`; Prowlarr hit still returned, `errors[0]` starts with `"Tracker: "`.
  - `search_releases_without_prowlarr_is_tracker_only` — `env.prowlarr = None`; tracker hit, no `errors` key.

- [ ] **Step 2: Run** `cargo test search_releases` — expect compile failure (`search_releases` not found).
- [ ] **Step 3: Implement** `search_releases` in `assistant/search.rs` per the behaviour above; make `curated::candidate` and `tools::LIMIT` `pub(crate)`.
- [ ] **Step 4: Run** `cargo test search_releases` — expect 5 passed; then `cargo test` — all pass, `cargo clippy --all-targets` clean.
- [ ] **Step 5: Commit** `feat(galactica): plab searches the tracker and other indexers for the assistant`

---

### Task 2: the `search_releases` tool on the Assistant

**Files:**
- Modify: `packages/plab/src/assistant/search.rs` (trait), `assistant/tools.rs`, `assistant/mod.rs`
- Test: `packages/plab/src/assistant/mod.rs` tests (wiremock OpenRouter, as the existing tool-call test)

**Interfaces:**
- Produces:
  ```rust
  pub trait ReleaseSearch: Send + Sync {
      fn search<'a>(&'a self, q: &'a str, now: i64)
          -> Pin<Box<dyn Future<Output = anyhow::Result<Value>> + Send + 'a>>;
  }
  ```
  `Assistant` field `search: OnceLock<Arc<dyn ReleaseSearch>>`; `pub fn set_search(&self, s: Arc<dyn ReleaseSearch>)` (ignores a second set). A setter on `&self`, not the spec's `with_search` builder: the handle needs the `WebState` that owns the already-built `Arc<Assistant>` (Task 3).
  `tools::definitions(search: bool) -> Value` — appends the `search_releases` definition only when `search` is true, description verbatim from the spec: "Search the tracker and other indexers for releases not on plab's lists. Returns refs usable as stream or download picks."
  `tools::run(stash, db, hide, search: Option<&dyn ReleaseSearch>, name, arguments, now)` — `"search_releases"` parses `q` with `query`, `None` → error `"search is not available"`, `Err(e)` → error `format!("{e:#}")`.
- `Assistant::turn` passes `self.search.get().is_some()` to `definitions` and `self.search.get().map(|s| &**s)` to `run`.

- [ ] **Step 1: Write the failing tests:**
  - `search_tool_offered_and_result_stored` — a fake `ReleaseSearch` returning `{"results":[{"ref":"t:9","title":"X"}]}`; OpenRouter mock asserts the first request's `tools` names include `search_releases`, replies with a `search_releases` call, then a final answer. Assert the stored `tool` message's `content` equals the fake's JSON and the fake saw `q`.
  - `search_tool_absent_without_handle` — no `set_search`: the request's tools omit `search_releases`; a scripted call to it anyway stores a tool result containing `"search is not available"` and the turn still completes.
- [ ] **Step 2: Run** `cargo test search_tool` — expect compile failure.
- [ ] **Step 3: Implement** the trait, field, setter, and the `definitions`/`run` parameters; update every existing caller and test of both.
- [ ] **Step 4: Run** `cargo test` — all pass; clippy clean.
- [ ] **Step 5: Commit** `feat(galactica): plab assistant offers search_releases when it has a search handle`

---

### Task 3: wire the live search into the web task

**Files:**
- Modify: `packages/plab/src/web.rs` (`WebState` gains `pub sources: Option<Sources>`), `packages/plab/src/commands.rs:~290` (fill it from the `sources` already loaded at `commands.rs:125`; after `Arc::new(WebState…)`, `set_search` on the assistant), `packages/plab/src/web/assistant_routes.rs` (the adapter)
- Test: `packages/plab/src/web_tests.rs`

**Interfaces:**
- Consumes: Task 1's `search_releases`, Task 2's `ReleaseSearch`, `WebState::ctx()`.
- Produces: `pub struct WebSearch<B: Backends>(pub Weak<WebState<B>>)` implementing `ReleaseSearch` by upgrading (gone → `Err("plab is shutting down")`) and calling `search_releases(&st.ctx(), st.sources.as_ref(), &hide, q, now)`, where `hide` is `load_excludes(st.exclude_file.as_deref(), Some(&st.state_dir)).rule` read per call, as the web routes read excludes.

- [ ] **Step 1: Write the failing test** `chat_search_pick_renders_card` in `web_tests.rs`: the fake tracker's `searched["alpha"]` holds row 7 "Alpha One"; `assistant_fx` plus `set_search(Arc::new(WebSearch(Arc::downgrade(&fx.state))))`; OpenRouter scripted: a `search_releases {"q":"alpha"}` call, then `{"text":"Here.","picks":[{"ref":"t:7","action":"download","reason":"r"}]}`. Start a chat, then GET the conversation: `topics[0].id == 7`, `topics[0].expired == false`, the turn's picks hold `t:7`.
- [ ] **Step 2: Run** `cargo test chat_search_pick_renders_card` — expect failure (no `WebSearch`; once it exists, the pick is dropped by `resolve_topics` until Task 4 — expect the `topics` assertion to fail).
- [ ] **Step 3: Implement** `WebSearch`, the `sources` field (`None` in the test fixture's `WebState`), and the `commands.rs` wiring.
- [ ] **Step 4:** Leave the test failing on the card assertion only; confirm with `cargo test chat_search_pick_renders_card` that the failure is `topics` being empty, not a panic or a missing tool call. It passes after Task 4.
- [ ] **Step 5: Commit** `feat(galactica): plab web task gives the assistant the live release search` (mark the test `#[ignore = "cards from search results: next commit"]` for this commit, and remove the attribute in Task 4).

---

### Task 4: cards from stored search results

**Files:**
- Modify: `packages/plab/src/web/assistant_routes.rs` (`build`, `PickedTopic`)
- Test: `packages/plab/src/web_tests.rs`

**Interfaces:**
- Consumes: the stored transcript (`st.db.messages(id)`): an assistant message whose `tool_calls[i].function.name == "search_releases"` and the `tool` messages answering those ids by `tool_call_id`.
- Produces: `PickedTopic` gains `expired: bool` (serialized `expired`). New `fn searched_hits(msgs: &[MessageRow]) -> HashMap<u64, Value>` mapping a `t:` id to its latest hit object, skipping unparseable results.

Resolution in `build`, after `resolve_topics`: for each picked topic id it did not return and `searched_hits` holds —
- `st.db.find(id, t)` is `Some((topic, _))`: `api::topic` over `Listed{topic, filters: vec![], curated_reason: None}` with the same `added`/`queued`/`downloads`/`externals` sets `resolve_topics` uses; `expired: false`.
- else: a `TopicDto` from the snapshot (`id`, `title`, `size`, `seeders`, `leechers`, `added = published`, `source` = indexer or `None` for `"tracker"`, `kind` `"torrent"` or `"tracker"`, `images: None`, the label fields from `labels(&title, 0)` as `api::topic` derives them, `state`/`status` as for a not-added release); `expired: true`. Factor the label-derived part of `api::topic` into a helper both use rather than copying it.
- `section: "video"` either way. Topics resolved from lists carry `expired: false`. Order stays "order the picks first named them".

- [ ] **Step 1: Write the failing tests** (seed messages with `append_messages`, as the existing daily tests seed picks):
  - remove `#[ignore]` from `chat_search_pick_renders_card`.
  - `search_pick_card_outlives_search_hit` — a stored `search_releases` round holding `t:7` and a final pick of it, no `search_hit` row: the conversation's `topics[0]` has `id 7`, `title` from the snapshot, `expired == true`.
  - `latest_search_result_wins` — two rounds both holding `t:7` with seeders 1 then 9: `topics[0].seeders == 9`.
  - `pick_from_another_conversations_search_is_dropped` — conversation A holds the search round, conversation B picks `t:7`: B's turn has no picks and `topics` is empty.
- [ ] **Step 2: Run** `cargo test search_pick chat_search_pick latest_search pick_from_another` — expect failures.
- [ ] **Step 3: Implement** `searched_hits`, the fallback, the `expired` field, and the shared label helper in `api.rs`.
- [ ] **Step 4: Run** `cargo test` — all pass; clippy clean.
- [ ] **Step 5: Commit** `feat(galactica): plab assistant picks from a search render from the stored result`

---

### Task 5: the expired state in the UI

**Files:**
- Modify: `packages/plab/ui/src/lib/types.ts:155` (`PickedTopic = Topic & { section: Section; expired?: boolean }`), `packages/plab/ui/src/components/Picks.svelte`
- Test: `packages/plab/ui/src/lib/assistant.test.ts`

**Interfaces:**
- Consumes: `expired` from Task 4.
- Produces: an expired topic card renders the text `Search result expired, search again` in place of its Stream/Download buttons; everything else on the card is unchanged.

- [ ] **Step 1: Write the failing test** in `assistant.test.ts` (or a component test beside it, following whatever `Picks` testing exists; if none, test the helper `Picks.svelte` uses to choose its actions): an expired `PickedTopic` yields no actions and the expired message; a non-expired one yields its usual actions.
- [ ] **Step 2: Run** `npm test` — expect failure.
- [ ] **Step 3: Implement** the type and the card state.
- [ ] **Step 4: Run** `npm test` and `npm run check` — pass, no warnings. Then `nix build .#nixosConfigurations.galactica.config.system.build.toplevel` from the repo root (the package builds its UI and runs its tests) — succeeds.
- [ ] **Step 5: Commit** `feat(galactica): plab marks an expired search pick`
