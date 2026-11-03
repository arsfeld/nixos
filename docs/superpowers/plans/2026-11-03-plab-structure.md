# plab structure refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split plab's 2,277-line `db/mod.rs` by domain, tidy its migrations and row
collection, keep SQLite from stalling tokio workers, and replace the repeated backend
generic parameters with two associated-type traits — with no behaviour change.

**Architecture:** `Db` stays one `Arc<Mutex<Connection>>` handle; its methods move into
child modules of `db/`, each an `impl Db` block that reaches the private `Db::with` through
Rust's parent-privacy rule, with public types re-exported so no caller changes. `Db::with`
wraps its call in `tokio::task::block_in_place` on multi-thread runtimes only. Two traits,
`Backends` and `IdentifyBackends`, bundle the tracker/torrent and identify dependencies as
associated types; a `Live` marker carries production's types, test markers carry the fakes.

**Tech Stack:** Rust 2024 (rustc 1.98), tokio, rusqlite 0.37, axum 0.8; Python 3 for the
one-off move script.

Spec: `docs/superpowers/specs/2026-11-03-plab-structure-design.md`.

## Global Constraints

- Pure refactor: no behaviour change, no new dependencies, no change to any SQL text.
- Work on `master` directly in `/home/arosenfeld/Code/nixos`; never branch or use a worktree.
- Commit messages: `refactor(galactica): <subject>`; never mention Claude.
- Every task ends with, run from `packages/plab`: `cargo test` → `test result: ok. 721 passed`
  (or more, if the task adds tests) and `cargo clippy --all-targets` with no warnings.
- Never point `CARGO_TARGET_DIR` at `packages/plab/target` while building a copy of the crate
  elsewhere: tests read fixtures via `env!("CARGO_MANIFEST_DIR")`, and a shared target dir
  can run a binary built with the other path baked in, so 71 fixture tests fail spuriously.
- `cargo` is on PATH on raider; no `nix develop` is needed for `cargo test`/`clippy`.

## File structure

| File | Responsibility after this plan |
|---|---|
| `packages/plab/src/db/mod.rs` | `Db` handle, open/migrate, `with`, shared topic types and helpers, `all`, cross-domain tests and shared test helpers |
| `packages/plab/src/db/{topics,added,downloads,identify,jobs,assistant,external,kv}.rs` | One domain each: its types, its `impl Db` methods, its tests |
| `packages/plab/src/backends.rs` (new) | `Backends`, `IdentifyBackends`, and the production `Live` marker |
| `packages/plab/src/{web.rs,web/assistant_routes.rs,plab.rs,curated.rs,events.rs,commands.rs}` | Signatures move from `<T, C>` to `<B: Backends>` |
| `packages/plab/src/identify/{mod.rs,watch.rs}` | Signatures move from `<S, L, J, T>` to `<B: IdentifyBackends>` |
| `packages/plab/src/{web_tests.rs,plab_tests.rs,identify/tests.rs}` | Test markers for the fakes |

---

### Task 1: Split `db/mod.rs` by domain (moves only)

**Files:**
- Modify: `packages/plab/src/db/mod.rs`
- Create: `packages/plab/src/db/topics.rs`, `added.rs`, `downloads.rs`, `identify.rs`, `jobs.rs`, `assistant.rs`, `external.rs`, `kv.rs`
- Scratch (not committed): `/tmp/plab-split/split_db.py`, `/tmp/plab-split/out/`

**Interfaces:**
- Consumes: nothing.
- Produces: the module layout above. In `db/mod.rs`: `mod topics; … mod kv;` and
  `pub use {topics,added,downloads,identify,jobs,assistant,external}::*;` (not `kv`: its one
  public item, `STREAM_VIEW_GAP`, is used only inside `kv.rs`). `Db::with`, `raw_topic`,
  `topic_of`, `upsert_topic`, `TOPIC_COLS`, `unix_now`, `migrate`, `SCHEMA*`, `USER_VERSION`
  stay in `mod.rs`. In `db::tests`, the helpers `row`, `listed`, `dl`, `added`, `NOW`, `topic`,
  `new_ext` become `pub(super)`; child test modules `use super::super::tests::*;` when they
  use one.

The script moves each item (docs, attributes and body) verbatim by name, and refuses to
write anything if a mapped name is missing or if any line of the original is lost or
altered beyond the allowed scaffolding. It was dry-run against `master` at `a2eba74e`: the
output compiles clippy-clean and passes all 721 tests.

- [ ] **Step 1: Record the baseline**

Run from `packages/plab`:

```bash
cargo test 2>&1 | grep 'test result'
```

Expected: `test result: ok. 721 passed; 0 failed; …`. If the count differs, `db/mod.rs`
changed since this plan was written: re-check the script's name maps against the file before
continuing.

- [ ] **Step 2: Save the move script**

Create `/tmp/plab-split/split_db.py` with exactly this content:

```python
#!/usr/bin/env python3
"""Split packages/plab/src/db/mod.rs into per-domain files, moving items verbatim.

Usage: split_db.py <path/to/db/mod.rs> <output dir>
Writes mod.rs and the domain files into <output dir>; the caller copies them into place.
"""
import re
import sys
from collections import Counter
from pathlib import Path

DOMAINS = {
    "topics": "Topic listings, live-search results, images and cached torrent files.",
    "added": "The added set and the per-section download queue.",
    "downloads": "Downloads, their files, and the scenes those files became.",
    "identify": "Identify bookkeeping: which scenes are done and which keep failing.",
    "jobs": "Job runs: last start per job and the bounded run history.",
    "assistant": "The assistant's conversations and messages.",
    "external": "Releases from other indexers, curated hits, and album entries.",
    "kv": "The key-value store and stream views.",
}

TOP = {
    "SEARCH_TTL": "topics", "Listed": "topics", "Listing": "topics",
    "IDENTIFY_FAILURE_LIMIT": "identify",
    "NewDownload": "added",
    "Link": "downloads", "FileRow": "downloads", "DownloadRow": "downloads",
    "JobRunRow": "jobs", "HISTORY_KEEP": "jobs",
    "STREAM_VIEW_GAP": "kv",
    "ConversationRow": "assistant", "MessageRow": "assistant", "conversation_row": "assistant",
    "EXTERNAL_BASE": "external", "is_external": "external", "External": "external",
    "Kind": "external", "impl Kind": "external", "NewExternal": "external",
    "CuratedHit": "external", "StoredHit": "external",
}

METHODS = {
    "topics": "listing save_listing search_topics save_search set_images find image_urls topic torrent_file store_torrent_file",
    "added": "added queued queued_title enqueue dequeue mark_added set_cover stale_covers clear_cover",
    "downloads": "unsynced_downloads record_files save_files unsynced_among link_scene record_outcome outcome_of grabbed record_grab download_rows",
    "identify": "identify_done identify_mark_done identify_fail identify_failures identify_clear_failures",
    "jobs": "job_last_started job_started job_finished history_start history_finish close_interrupted job_history",
    "assistant": "create_conversation conversations conversation delete_conversation append_message append_messages append messages delete_messages_from",
    "external": "save_curated curated_hits upsert_external external externals externals_where is_album set_scene",
    "kv": "kv_get kv_set kv_delete record_stream_view stream_views",
}
METHOD = {m: d for d, ms in METHODS.items() for m in ms.split()}

TESTS = {
    "topics": "empty_listing_is_default save_listing_round_trips_in_order_per_section save_listing_round_trips_topic_fields save_listing_replaces_section_and_drops_orphans search_topics_expire_after_ttl_and_keep_images save_search_records_rows_without_images search_entries_exactly_a_day_old_are_kept save_search_drops_entries_older_than_a_day search_topics_does_not_write set_images_unknown_topic_is_a_no_op find_prefers_lists_then_search_as_video image_urls_cover_both_lists_and_live_searches torrent_files_round_trip_and_replace",
    "added": "queued_title_prefers_the_topic_then_the_queue_row enqueue_skips_added_and_duplicates queue_is_oldest_first_and_dequeue_unknown_is_a_no_op queues_are_per_section mark_added_promotes_a_queued_row mark_added_persists_across_reopen mark_added_without_topic_always_inserts",
    "downloads": "grabbed_matches_any_key save_files_marks_synced_and_link_finds_the_download re_adding_a_topic_with_a_new_torrent_forgets_the_old_files unsynced_among_names_only_known_unsynced_hashes",
    "identify": "identify_gives_up_on_third_failure_and_clears identify_mark_done",
    "jobs": "job_run_records_start job_history_records_runs_newest_first job_history_keeps_fifty_per_job unfinished_runs_close_as_interrupted",
    "kv": "kv_rev_increments kv_delete_removes_the_key stream_views_dedupe_within_gap",
    "assistant": "conversations_round_trip append_messages_is_one_consecutive_batch",
    "external": "album_rows_keep_their_first_sight_and_are_never_pruned curated_hits_carry_the_release_kind external_ids_start_at_the_base_and_are_stable_per_guid save_curated_replaces_the_hits_and_keeps_images a_pruned_external_id_is_never_handed_out_again",
}
TEST = {t: d for d, ts in TESTS.items() for t in ts.split()}
# Test helpers shared by several files: they stay in db::tests and become pub(super).
HELPERS = {"row", "listed", "dl", "added", "NOW", "topic", "new_ext"}
# kv's only public item, STREAM_VIEW_GAP, is used nowhere outside kv: a re-export would be unused.
NO_REEXPORT = {"kv"}

DECL = re.compile(r"^\s*(?:pub(?:\([a-z]+\))? )?(?:async )?(fn|struct|enum|const|type|static|mod|use|impl)\s+(\w+)")


def items(lines):
    """Split a run of lines into items: leading docs/attrs/comments plus one declaration."""
    out, cur, depth, started = [], [], 0, False
    for line in lines:
        if not cur and not line.strip():
            out.append(("", [line]))  # blank separator, kept in place
            continue
        s = line.strip()
        if not started and not s:
            # A comment run followed by a blank line belongs to what follows the blank:
            # keep it attached by carrying the blank inside the pending item.
            cur.append(line)
            continue
        cur.append(line)
        if not started and (s.startswith("///") or s.startswith("//") or s.startswith("#[")):
            continue
        if not started:
            started = True
            m = DECL.match(line)
            if not m:
                raise SystemExit(f"cannot name item starting at: {line!r}")
            kind, name = m.groups()
            key = f"impl {name}" if kind == "impl" else name
        depth += line.count("{") - line.count("}")
        if depth == 0 and (s.endswith("}") or s.endswith(";")):
            out.append((key, cur))
            cur, started = [], False
    if cur:
        raise SystemExit(f"unterminated item: {cur[:3]}")
    return out


def main(src, outdir):
    text = Path(src).read_text()
    lines = text.split("\n")
    impl_start = lines.index("impl Db {")
    impl_end = next(i for i in range(impl_start, len(lines)) if lines[i] == "}")
    tests_start = lines.index("mod tests {")
    assert lines[tests_start - 1] == "#[cfg(test)]"
    tests_end = len(lines) - 1 - next(i for i, l in enumerate(reversed(lines)) if l == "}")

    top = items(lines[:impl_start])
    meth = items(lines[impl_start + 1:impl_end])
    gap = lines[impl_end + 1:tests_start - 1]
    tst = items(lines[tests_start + 1:tests_end])

    keep_top, keep_meth, keep_tst = [], [], []
    by = {d: {"top": [], "meth": [], "tst": []} for d in DOMAINS}

    def route(seq, table, keep, slot):
        for key, body in seq:
            d = table.get(key)
            if d:
                by[d][slot].append(body)
            else:
                keep.append((key, body))

    route(top, TOP, keep_top, "top")
    route(meth, METHOD, keep_meth, "meth")
    route(tst, TEST, keep_tst, "tst")

    missing = (set(TOP) | set(METHOD) | set(TEST)) - {k for k, _ in top + meth + tst}
    if missing:
        raise SystemExit(f"names in the map but not in the file: {sorted(missing)}")

    def tidy(bodies):
        """Drop leading/trailing blank separators so files do not start with gaps."""
        flat = [l for b in bodies for l in b]
        while flat and not flat[0].strip():
            flat.pop(0)
        while flat and not flat[-1].strip():
            flat.pop()
        return flat

    def join(bodies):
        out = []
        for b in bodies:
            if out:
                out.append("")
            out.extend(b)
        return out

    def helper(key, body):
        if key in HELPERS:
            i = next(i for i, l in enumerate(body) if DECL.match(l))
            body = body.copy()
            body[i] = re.sub(r"^(\s*)(fn|const) ", r"\1pub(super) \2 ", body[i])
        return body

    out = Path(outdir)
    out.mkdir(parents=True, exist_ok=True)
    for d, doc in DOMAINS.items():
        f = [f"//! {doc}", "", "use super::*;", ""]
        if by[d]["top"]:
            f += join(by[d]["top"]) + [""]
        f += ["impl Db {"] + join(by[d]["meth"]) + ["}"]
        if by[d]["tst"]:
            body = "\n".join(l for b in by[d]["tst"] for l in b)
            uses = any(re.search(rf"\b{h}\b(\(|\s*[,;)+\-])", body) for h in HELPERS)
            f += ["", "#[cfg(test)]", "mod tests {"]
            f += ["    use super::super::tests::*;"] if uses else []
            f += ["    use super::*;", ""]
            f += join(by[d]["tst"]) + ["}"]
        (out / f"{d}.rs").write_text("\n".join(f) + "\n")

    head = tidy([b for _, b in keep_top])
    i = head.index("pub mod import;")
    mods = [f"mod {d};" for d in DOMAINS] + [""] + [f"pub use {d}::*;" for d in DOMAINS if d not in NO_REEXPORT]
    head = head[: i + 1] + mods + head[i + 1:]
    m = head + ["", "impl Db {"] + tidy([b for _, b in keep_meth]) + ["}"]
    m += gap + ["#[cfg(test)]", "mod tests {"] + tidy([helper(k, b) for k, b in keep_tst]) + ["}"]
    (out / "mod.rs").write_text("\n".join(m) + "\n")

    # Every non-blank line of the original is somewhere in the output, exactly as often.
    before = Counter(l for l in lines if l.strip())
    after = Counter()
    for p in out.glob("*.rs"):
        after.update(l for l in p.read_text().split("\n") if l.strip())
    added = after - before
    lost = before - after
    allowed = {l for l in added if l.startswith("//! ") or l.startswith("mod ") or l.startswith("pub use ")
               or l.strip() in ("use super::*;", "use super::super::tests::*;", "impl Db {", "}", "#[cfg(test)]", "mod tests {")
               or "pub(super) " in l}
    unexpected_add = {l: n for l, n in added.items() if l not in allowed}
    unexpected_lost = {l: n for l, n in lost.items() if not any(l.strip() in a.replace("pub(super) ", "") for a in added)}
    if unexpected_add or unexpected_lost:
        raise SystemExit(f"line accounting failed:\n added={unexpected_add}\n lost={unexpected_lost}")
    print("ok:", {d: (len(v["meth"]), len(v["tst"])) for d, v in by.items()})


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
```

- [ ] **Step 3: Run it into a scratch directory**

```bash
cd /home/arosenfeld/Code/nixos
rm -rf /tmp/plab-split/out
python3 -I /tmp/plab-split/split_db.py packages/plab/src/db/mod.rs /tmp/plab-split/out
```

Expected output:
`ok: {'topics': (10, 13), 'added': (9, 7), 'downloads': (10, 4), 'identify': (5, 2), 'jobs': (7, 4), 'assistant': (9, 2), 'external': (8, 5), 'kv': (5, 3)}`
(methods, tests per domain). Any `SystemExit` message means stop and fix the map, not the
check.

- [ ] **Step 4: Copy the files into place**

```bash
cp /tmp/plab-split/out/*.rs packages/plab/src/db/
git -C /home/arosenfeld/Code/nixos add -N packages/plab/src/db/
```

(`git add -N` makes the new files visible to any flake build; cargo does not need it.)

- [ ] **Step 5: Verify**

From `packages/plab`:

```bash
cargo clippy --all-targets 2>&1 | grep -E '^(warning|error)'   # expect no output
cargo test 2>&1 | grep 'test result'                           # expect 721 passed
wc -l src/db/*.rs                                              # mod.rs ≈ 506 lines
```

- [ ] **Step 6: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add packages/plab/src/db/
git commit -m "refactor(galactica): plab db methods live in one file per domain"
```

---

### Task 2: Tidy the db layer — migrations as a list, one collect helper, `from_row`

**Files:**
- Modify: `packages/plab/src/db/mod.rs` (migrations, `all`, migration tests)
- Modify: `packages/plab/src/db/{topics,added,downloads,jobs,assistant,external,kv}.rs` (collect sites)
- Modify: `packages/plab/src/db/assistant.rs` (`ConversationRow::from_row`)

**Interfaces:**
- Consumes: Task 1's layout.
- Produces: `const MIGRATIONS: &[&str]` and `const USER_VERSION: i64 = MIGRATIONS.len() as i64;`
  in `db/mod.rs` (the `SCHEMA`…`SCHEMA_V7` constants are gone);
  `fn all<T>(rows: impl Iterator<Item = rusqlite::Result<T>>) -> Result<Vec<T>>` in
  `db/mod.rs`, private, reachable from every child; `ConversationRow::from_row`.
  `db/import.rs` keeps importing `USER_VERSION` unchanged.

This task changes no behaviour, so the existing migration tests
(`migrations_set_user_version`, `v1_database_migrates_to_v2_keeping_rows`,
`a_version_2_database_gains_torrent_file`, and the `db::import` tests) are the regression
gate. Step 1 adds the one new invariant worth pinning.

- [ ] **Step 1: Add a test pinning the migration list to the schema files**

In `db/mod.rs`'s `mod tests`, add:

```rust
    #[test]
    fn every_schema_file_is_one_migration_step() {
        let files = std::fs::read_dir(concat!(env!("CARGO_MANIFEST_DIR"), "/src/db"))
            .unwrap()
            .filter_map(|e| e.ok()?.file_name().into_string().ok())
            .filter(|n| n.starts_with("schema") && n.ends_with(".sql"))
            .count();
        assert_eq!(MIGRATIONS.len(), files);
        assert_eq!(USER_VERSION, files as i64);
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `cargo test every_schema_file_is_one_migration_step`
Expected: compile error `cannot find value MIGRATIONS in this scope`.

- [ ] **Step 3: Replace the schema constants with the list**

In `db/mod.rs`, replace the eight lines `const SCHEMA: &str = include_str!("schema.sql");`
through `const USER_VERSION: i64 = 7;` with:

```rust
/// The schema, one step per version: a database at `user_version` N has run the first N.
/// A new version is a new `schema_vN.sql` and one entry here.
const MIGRATIONS: &[&str] = &[
    include_str!("schema.sql"),
    include_str!("schema_v2.sql"),
    include_str!("schema_v3.sql"),
    include_str!("schema_v4.sql"),
    include_str!("schema_v5.sql"),
    include_str!("schema_v6.sql"),
    include_str!("schema_v7.sql"),
];
const USER_VERSION: i64 = MIGRATIONS.len() as i64;
```

In `migrate`, replace everything from the comment
`// Stepwise: a fresh database runs every step, a v1 one only what it lacks.` through the
`if from < 7 { … }` block with:

```rust
    // Stepwise: a fresh database runs every step, a v1 one only what it lacks.
    for (step, sql) in MIGRATIONS.iter().enumerate().skip(from as usize) {
        tx.execute_batch(sql)?;
        // The legacy import fills the v1 tables, so it runs right after step 0 creates them.
        if step == 0
            && let Some(legacy) = legacy
        {
            import::run(&tx, legacy, now)?;
        }
    }
```

Leave the two `version(..)? >= USER_VERSION` early returns, the `Immediate` transaction,
the `pragma_update` and the `commit` exactly as they are.

In `mod tests`, the two migration tests that build old databases by hand use the removed
constants. Replace `c.execute_batch(SCHEMA).unwrap();` with
`c.execute_batch(MIGRATIONS[0]).unwrap();` (two places) and
`c.execute_batch(SCHEMA_V2).unwrap();` with `c.execute_batch(MIGRATIONS[1]).unwrap();`.
Find them with `grep -n 'SCHEMA' packages/plab/src/db/mod.rs`; after the edit that grep
must print nothing.

- [ ] **Step 4: Run the migration tests**

Run: `cargo test db::` (from `packages/plab`)
Expected: all `db::` tests pass, including `every_schema_file_is_one_migration_step`,
`migrations_set_user_version`, `v1_database_migrates_to_v2_keeping_rows`,
`a_version_2_database_gains_torrent_file`, and every `db::import::tests::*`.

- [ ] **Step 5: Add `all` and use it at every Vec collect**

In `db/mod.rs`, next to `unix_now`, add:

```rust
/// A query's rows, or its first error.
fn all<T>(rows: impl Iterator<Item = rusqlite::Result<T>>) -> Result<Vec<T>> {
    Ok(rows.collect::<rusqlite::Result<Vec<T>>>()?)
}
```

Then list the sites:

```bash
grep -n 'collect::<rusqlite::Result<' packages/plab/src/db/*.rs
```

There are 16 (in `topics`, `added`, `downloads`, `jobs`, `assistant`, `external`, `kv`).
Rewrite the 15 that collect into a `Vec` — `collect::<rusqlite::Result<Vec<_>>>()?`,
`collect::<rusqlite::Result<Vec<u64>>>()?`, and the three `collect::<rusqlite::Result<_>>()?`
whose function returns `Result<Vec<_>>` — so the iterator is passed to `all`:

```rust
// before
let raw = stmt.query_map([now - SEARCH_TTL], raw_topic)?.collect::<rusqlite::Result<Vec<_>>>()?;
// after
let raw = all(stmt.query_map([now - SEARCH_TTL], raw_topic)?)?;

// before
Ok(rows.collect::<rusqlite::Result<_>>()?)
// after
all(rows)

// before (method chain)
stmt.query_map(params![job, limit as i64], |r| { … })?
    .collect::<rusqlite::Result<Vec<_>>>()?;
// after
all(stmt.query_map(params![job, limit as i64], |r| { … })?)?;
```

Leave the one collect into a `HashSet` (in `Db::added`) as it is. If a
site's element type was only fixed by its turbofish (`Vec<u64>`), give it to `all` instead:
`all::<u64>(…)`. After the edit:

```bash
grep -n 'collect::<rusqlite::Result<Vec\|collect::<rusqlite::Result<_>>' packages/plab/src/db/*.rs
```

must print only the line inside `fn all`, and the `HashSet` one must still be there.

- [ ] **Step 6: `ConversationRow::from_row`**

In `db/assistant.rs`, replace the free function `fn conversation_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<ConversationRow> { … }`
with an associated function on the struct, keeping its body:

```rust
impl ConversationRow {
    fn from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Self> {
        Ok(ConversationRow {
            id: r.get(0)?,
            title: r.get(1)?,
            kind: r.get(2)?,
            created_at: r.get(3)?,
            updated_at: r.get(4)?,
        })
    }
}
```

and replace each `conversation_row` argument (`query_map(.., conversation_row)`,
`query_row(.., conversation_row)`) with `ConversationRow::from_row`. `RawTopic` stays a
tuple: the spec explains why.

- [ ] **Step 7: Verify**

From `packages/plab`: `cargo clippy --all-targets` (no warnings) and `cargo test`
(`722 passed`: 721 + the new test).

- [ ] **Step 8: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add packages/plab/src/db/
git commit -m "refactor(galactica): plab migrations are a list and row collects share a helper"
```

---

### Task 3: Keep SQLite off tokio's workers

**Files:**
- Modify: `packages/plab/src/db/mod.rs` (`Db::with` and a test)

**Interfaces:**
- Consumes: `Db::with(&self, f: impl FnOnce(&mut Connection) -> Result<R>) -> Result<R>`, private.
- Produces: same signature, same behaviour for callers; on a multi-thread runtime the call runs
  under `block_in_place`.

- [ ] **Step 1: Write the failing test**

In `db/mod.rs`'s `mod tests`, add:

```rust
    // One worker: while a slow query holds it, nothing else spawned can run unless the
    // query gives the worker up.
    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn a_slow_query_does_not_hold_the_worker() {
        let db = Db::open_in_memory().unwrap();
        let (started, started_rx) = tokio::sync::oneshot::channel();
        let slow = tokio::spawn({
            let db = db.clone();
            async move {
                db.with(|_| {
                    started.send(()).unwrap();
                    std::thread::sleep(Duration::from_millis(500));
                    Ok(())
                })
                .unwrap();
                std::time::Instant::now()
            }
        });
        started_rx.await.unwrap();
        let other = tokio::spawn(async { std::time::Instant::now() }).await.unwrap();
        let slow_done = slow.await.unwrap();
        assert!(other < slow_done, "a spawned task waited for the query to finish");
    }
```

The test body runs in `block_on` on the main thread; spawned tasks run only on the single
worker. Before the change, `slow` occupies that worker for 500 ms, so `other` runs after it.

- [ ] **Step 2: Run it to see it fail**

Run: `cargo test a_slow_query_does_not_hold_the_worker`
Expected: FAIL with `a spawned task waited for the query to finish`.

- [ ] **Step 3: Implement**

Replace `Db::with` and its doc comment in `db/mod.rs` with:

```rust
    /// Run `f` with the connection locked. Never call this across an `.await`.
    ///
    /// On the daemon's multi-thread runtime the call runs under `block_in_place`, so a
    /// slow query or a busy wait (up to the 30 s busy timeout) hands this worker's other
    /// tasks to another thread instead of stalling them. Tests run current-thread and the
    /// one-shot commands may run outside a runtime; `block_in_place` panics in both, so
    /// there the call runs directly, as it always did.
    fn with<R>(&self, f: impl FnOnce(&mut Connection) -> Result<R>) -> Result<R> {
        let run = || {
            let mut conn = self.0.lock().unwrap_or_else(|e| e.into_inner());
            f(&mut conn)
        };
        match tokio::runtime::Handle::try_current().map(|h| h.runtime_flavor()) {
            Ok(tokio::runtime::RuntimeFlavor::MultiThread) => tokio::task::block_in_place(run),
            _ => run(),
        }
    }
```

- [ ] **Step 4: Run the test and the suite**

Run: `cargo test a_slow_query_does_not_hold_the_worker` → PASS.
Run: `cargo test` → `723 passed`. Run: `cargo clippy --all-targets` → no warnings.

- [ ] **Step 5: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add packages/plab/src/db/mod.rs
git commit -m "refactor(galactica): plab database calls give up their tokio worker while they block"
```

---

### Task 4: `Backends` and `IdentifyBackends`

**Files:**
- Create: `packages/plab/src/backends.rs`
- Modify: `packages/plab/src/main.rs` (add `mod backends;`)
- Modify: `packages/plab/src/web.rs`, `web/assistant_routes.rs`, `plab.rs`, `curated.rs`, `events.rs`, `commands.rs`
- Modify: `packages/plab/src/identify/mod.rs`, `identify/watch.rs`
- Modify: `packages/plab/src/web_tests.rs`, `plab_tests.rs`, `identify/tests.rs`

**Interfaces:**
- Consumes: traits `TrackerApi` (`crate::tracker`), `TorrentClient` (`crate::transmission`),
  `StashApi` (`crate::stash`), `Llm` (`crate::llm`), `CodeSearch` (`crate::codedb`); the
  real types `crate::tracker::Tracker`, `crate::transmission::Transmission`,
  `crate::stash::Stash`, `crate::llm::OpenRouter`, `crate::codedb::CodeDb`.
- Produces: `crate::backends::{Backends, IdentifyBackends, Live}`;
  `plab::Ctx<'a, B: Backends>`, `web::WebState<B: Backends>`,
  `identify::Clients<'a, B: IdentifyBackends>`.

No new test: this is a type-level change, and the 723 existing tests that drive these
paths through fakes and through `Live` are the check. The compiler is the main tool. Make
the declaration changes first, then follow its errors.

- [ ] **Step 1: Create `src/backends.rs`**

```rust
//! The clients plab's code is generic over, bundled so a signature names one parameter
//! instead of one per client. Production uses `Live`; tests define a marker per set of
//! fakes, next to the fakes.

use crate::codedb::{CodeDb, CodeSearch};
use crate::llm::{Llm, OpenRouter};
use crate::stash::{Stash, StashApi};
use crate::tracker::{Tracker, TrackerApi};
use crate::transmission::{TorrentClient, Transmission};

/// The tracker and the torrent client: what the list refresh, adds, curated runs and the
/// web server use. The `'static` bounds are what axum's router state needs; four web.rs
/// functions spelled them out as `T: TrackerApi + 'static`.
pub trait Backends: Send + Sync + 'static {
    type Tracker: TrackerApi + 'static;
    type Torrents: TorrentClient + 'static;
}

/// What an identify pass uses.
pub trait IdentifyBackends: Send + Sync + 'static {
    type Stash: StashApi + 'static;
    type Llm: Llm + 'static;
    type CodeSearch: CodeSearch + 'static;
    type Torrents: TorrentClient + 'static;
}

/// The real clients.
pub struct Live;

impl Backends for Live {
    type Tracker = Tracker;
    type Torrents = Transmission;
}

impl IdentifyBackends for Live {
    type Stash = Stash;
    type Llm = OpenRouter;
    type CodeSearch = CodeDb;
    type Torrents = Transmission;
}
```

Add `mod backends;` to `src/main.rs` on the line after `mod assistant;`.

- [ ] **Step 2: Change the three struct declarations**

`plab.rs`:

```rust
pub struct Ctx<'a, B: Backends> {
    pub tracker: &'a B::Tracker,
    pub torrents: &'a B::Torrents,
    // every other field unchanged
```

`web.rs`:

```rust
pub struct WebState<B: Backends> {
    pub tracker: Arc<B::Tracker>,
    pub torrents: Arc<B::Torrents>,
    // every other field unchanged
}

impl<B: Backends> WebState<B> {
    fn ctx(&self) -> Ctx<'_, B> {
        // body unchanged
```

`identify/mod.rs`:

```rust
pub struct Clients<'a, B: IdentifyBackends> {
    pub stash: &'a B::Stash,
    pub llm: &'a B::Llm,
    pub codedb: Option<&'a B::CodeSearch>,
    pub paths: &'a Paths,
    /// Transmission, for recording download files at the start of a pass; None in a
    /// dry run's tests.
    pub torrents: Option<&'a B::Torrents>,
}
```

- [ ] **Step 3: Rewrite the signatures**

From `packages/plab/src`, apply these exact textual rewrites (each pattern below occurs
only in generic parameter lists and type arguments):

```bash
cd /home/arosenfeld/Code/nixos/packages/plab/src
sed -i \
  -e 's/<T: TrackerApi, C: TorrentClient, K: Classify>/<B: Backends, K: Classify>/g' \
  -e 's/<T: TrackerApi, C: TorrentClient>/<B: Backends>/g' \
  -e "s/<T: TrackerApi + 'static, C: TorrentClient + 'static>/<B: Backends>/g" \
  -e 's/WebState<T, C>/WebState<B>/g' \
  -e "s/Ctx<'_, T, C>/Ctx<'_, B>/g" \
  -e 's/::<T, C>/::<B>/g' \
  web.rs web/assistant_routes.rs plab.rs curated.rs events.rs
sed -i \
  -e 's/<S: StashApi, L: Llm, J: CodeSearch, T: TorrentClient>/<B: IdentifyBackends>/g' \
  -e "s/Clients<'_, S, L, J, T>/Clients<'_, B>/g" \
  identify/mod.rs identify/watch.rs
grep -n 'C: TorrentClient\|J: CodeSearch\|L: Llm' web.rs web/assistant_routes.rs plab.rs curated.rs events.rs identify/mod.rs identify/watch.rs
```

The final grep must print nothing. Functions generic over a single client keep their
parameter and are not part of this change: `plab::ensure_image<T: TrackerApi>` and
identify's `resolve_studio`, `resolve_performer`, `stash_jobs` and `fingerprint_suspects`
(`<S: StashApi>`). Inside a `<B: …>` function they are called with the field
(`ensure_image(ctx.tracker, …)`), and `T` is inferred as `B::Tracker`. In each of those files, add the matching import —
`use crate::backends::Backends;` (web.rs, web/assistant_routes.rs, plab.rs, curated.rs,
events.rs) or `use crate::backends::IdentifyBackends;` (identify/mod.rs, identify/watch.rs).
Remove trait imports that are now unused: `cargo clippy` names them in Step 5. Do not
remove a trait import that is still needed to call its methods. Rust only needs the trait
in scope for method calls on a concrete type, not on `B::Tracker`, so let the compiler
decide.

- [ ] **Step 4: Name `Live` at production construction sites**

In `commands.rs`:
- Both `let ctx = plab::Ctx {` (around lines 79 and 110) become `let ctx = plab::Ctx::<Live> {`.
- `let state = Arc::new(WebState {` (around line 291) becomes `let state = Arc::new(WebState::<Live> {`.
- `fn clients<'a>(…) -> anyhow::Result<Clients<'a, crate::stash::Stash, OpenRouter, crate::codedb::CodeDb, Transmission>>`
  becomes `-> anyhow::Result<Clients<'a, Live>>`, and its `Ok(Clients {` becomes `Ok(Clients::<Live> {`.
- `let c = Clients {` in `identify` (around line 540) becomes `let c = Clients::<Live> {`.
- Add `use crate::backends::Live;`.

- [ ] **Step 5: Compile production code**

Run: `cargo clippy 2>&1 | grep -E '^(error|warning)' -A6 | head -60` (from `packages/plab`).
Fix what it names. Expect only:
- An unused trait import: remove it.
- A missing trait in scope where a body calls a trait method on a field (`c.stash.foo()`):
  add the trait import back.
- A struct literal whose `B` cannot be inferred (`type annotations needed`): add `::<Live>`.

Do not change any function body beyond these. Repeat until there is no output.

- [ ] **Step 6: Test markers**

`web_tests.rs` — next to `impl TorrentClient for FakeTorrents`, add:

```rust
/// The fakes, as one `Backends`.
struct Fakes;

impl crate::backends::Backends for Fakes {
    type Tracker = FakeTracker;
    type Torrents = FakeTorrents;
}
```

and rewrite `WebState<FakeTracker, FakeTorrents>` → `WebState<Fakes>` (both places) and the
`WebState {` literal around line 190 → `WebState::<Fakes> {`.

`plab_tests.rs` — the same `struct Fakes;` and `impl crate::backends::Backends for Fakes`
with its own `FakeTracker`/`FakeTorrents`, next to `impl TorrentClient for FakeTorrents`.
Then:
- `fn ctx<'a>(&'a self, tracker: &'a FakeTracker) -> Ctx<'a, FakeTracker, FakeTorrents>` →
  `-> Ctx<'a, Fakes>`, and its `Ctx {` → `Ctx::<Fakes> {`.
- `ctx: &'a Ctx<'a, crate::tracker::Tracker, crate::transmission::Transmission>` (around
  line 1252) → `ctx: &'a Ctx<'a, crate::backends::Live>`, plus `::<crate::backends::Live>`
  on the literal that builds it, if the compiler asks.

`identify/tests.rs` — next to `impl CodeSearch for FakeCodeDb`, add:

```rust
/// The fakes, as one `IdentifyBackends`.
struct Fakes;

impl crate::backends::IdentifyBackends for Fakes {
    type Stash = FakeStash;
    type Llm = FakeLlm;
    type CodeSearch = FakeCodeDb;
    type Torrents = crate::provenance::tests::FakeTorrents;
}
```

and rewrite the helper around line 426:
`) -> Clients<'a, FakeStash, FakeLlm, FakeCodeDb, crate::provenance::tests::FakeTorrents> {`
→ `) -> Clients<'a, Fakes> {`, and its `Clients {` → `Clients::<Fakes> {`. The struct-update
literal around line 2136 (`Clients { torrents: …, ..clients(…) }`) infers `B` from its base
and needs no change.

Then run `cargo clippy --all-targets 2>&1 | grep -E '^(error|warning)' -A6 | head -60` and
fix the remaining errors the same way as in Step 5. Any other test that spells out
`Ctx<…, …>`, `WebState<…, …>` or `Clients<…>` with concrete fakes gets the matching marker.

- [ ] **Step 7: Verify**

From `packages/plab`: `cargo clippy --all-targets` (no warnings) and `cargo test`
(`723 passed`). Then confirm the parameter lists are gone:

```bash
cd src && grep -n "C: TorrentClient\|L: Llm, J: CodeSearch" web.rs web/assistant_routes.rs plab.rs curated.rs events.rs identify/mod.rs identify/watch.rs | wc -l   # expect 0
# prune.rs, grab.rs and provenance.rs keep their own <C: TorrentClient>: out of scope.
```

- [ ] **Step 8: Commit**

```bash
cd /home/arosenfeld/Code/nixos
git add packages/plab/src/
git commit -m "refactor(galactica): plab names its clients through Backends and IdentifyBackends"
```

---

### Task 5: Build, push, deploy, check

**Files:** none.

- [ ] **Step 1: Build the package the way galactica does**

```bash
cd /home/arosenfeld/Code/nixos
nice nix build .#plab --no-link --print-out-paths
```

Expected: a store path. This runs `cargo test` in the sandbox (`checkPhase`), so it must
also report 723 passing in its log on failure. Build only this package, not several hosts
in parallel.

- [ ] **Step 2: Push**

```bash
git push -u origin master
```

- [ ] **Step 3: Deploy galactica and check plab**

From raider:

```bash
just deploy galactica
ssh galactica.bat-boa.ts.net 'systemctl is-active plab; systemctl --failed --no-legend'
```

Expected: `active`, and no failed units. Then confirm `/api` answers: run
`systemctl cat plab` to find the listen address, and request
`curl -fsS http://<that address>/api/downloads | head -c 200` on galactica. Expected: JSON,
not an error. Nothing user-visible changed, so that is the whole check.
