# plab: database layout, blocking SQLite, and backend generics

## Why

Clippy is clean and production code rarely unwraps, so what makes plab costly to change is
its structure:

- `src/db/mod.rs` is 2,277 lines: about 1,060 lines of 70 `Db` methods over every
  domain plab has, then an 860-line `mod tests`. Finding the method that owns a table means
  scrolling past all the others.
- `<T: TrackerApi, C: TorrentClient>` is spelled out 22 times and
  `<S: StashApi, L: Llm, J: CodeSearch, T: TorrentClient>` 10 times. A new trait-bound
  dependency would mean editing every one.
- `Db` is an `Arc<Mutex<Connection>>` that is called directly from async code, with a 30 s
  busy timeout and no `spawn_blocking` anywhere. A slow query or a busy wait stalls a tokio
  worker and every task scheduled on it. No symptom has been seen; this is insurance.

This work changes structure only. No behaviour changes, except that §3 moves where SQLite
work runs.

## Not in scope

- **Swapping rusqlite for another library.** rusqlite is already contained: nothing
  outside `src/db/` uses it except one test in `grab.rs`. sqlx's compile-time checking
  would mean rewriting 77 queries, adopting the v7 `user_version` databases into its own
  migration table, and keeping `.sqlx` offline metadata current so the Nix sandbox build
  works. That costs more than it gains on a single-user sqlite file. diesel and sea-orm are
  heavier still.
- **An async `Db`.** `spawn_blocking` or tokio-rusqlite would add `.await` at 358
  production call sites and force borrowed arguments to become owned. §3 gets the same
  benefit with one function changed.
- **Per-domain repository structs** (`db.topics().find(..)`). That churns every caller and
  buys nothing over §1.

## 1. Split `db/` by domain

`db/mod.rs` keeps `Db`, `open_with`, `open_in_memory`, the private `with`, `migrate`,
`unix_now`, and the types that more than one domain uses (`Section`, `Topic`, `Row`,
`TOPIC_COLS`, `raw_topic`/`topic_of`, `upsert_topic`). Each domain moves into a child
module holding its own `impl Db` block, its row types, and its tests. A child module can see
its parent's private items, so every file reaches `with` without making it public.

| File | Methods |
|---|---|
| `db/topics.rs` | `listing`, `save_listing`, `search_topics`, `save_search`, `set_images`, `find`, `image_urls`, `topic`, `torrent_file`, `store_torrent_file` |
| `db/added.rs` | `added`, `queued`, `queued_title`, `enqueue`, `dequeue`, `mark_added`, `set_cover`, `stale_covers`, `clear_cover` |
| `db/downloads.rs` | `unsynced_downloads`, `record_files`, `save_files`, `unsynced_among`, `link_scene`, `set_scene`, `record_outcome`, `outcome_of`, `grabbed`, `record_grab`, `download_rows` |
| `db/identify.rs` | `identify_done`, `identify_mark_done`, `identify_fail`, `identify_failures`, `identify_clear_failures` |
| `db/jobs.rs` | `job_last_started`, `job_started`, `job_finished`, `history_start`, `history_finish`, `close_interrupted`, `job_history` |
| `db/assistant.rs` | `create_conversation`, `conversations`, `conversation`, `delete_conversation`, `append_message`, `append_messages`, `messages`, `delete_messages_from` |
| `db/external.rs` | `save_curated`, `curated_hits`, `upsert_external`, `external`, `externals`, `is_album`, `is_external` |
| `db/kv.rs` | `kv_get`, `kv_set`, `kv_delete`, `record_stream_view`, `stream_views` |

`user_version` and `exec` stay in `mod.rs` next to `open`. A method goes in the file that
owns the table it writes. Where a method touches two domains, it goes with the table it
writes, and the call is made when its body is read. `mod.rs` re-exports every public type
(`pub use topics::Listing;` and so on), so `crate::db::X` paths do not change and no file
outside `db/` is edited.

Tests move with the methods they exercise. Tests that cover several domains, such as the
migration tests and anything built on `open_in_memory` plus several writers, stay in
`mod.rs`. A test helper used by more than one file becomes `#[cfg(test)] pub(super)` in
`mod.rs`.

This commit only moves code. Every function body is identical before and after, which is
what makes a reviewer's diff readable.

## 2. Tidy the layer

These go in a separate commit after the move:

- **Migrations as data.** `const MIGRATIONS: &[&str] = &[SCHEMA, SCHEMA_V2, …, SCHEMA_V7];`
  with `const USER_VERSION: i64 = MIGRATIONS.len() as i64;`. The seven `if from < N`
  blocks become one loop over `MIGRATIONS[from as usize..]` that runs `import::run` right
  after step 0 when `legacy` is set. The double-checked `user_version` read and the
  `Immediate` transaction stay exactly as they are. Adding a schema version becomes one
  `.sql` file plus one array entry.
- **One collect helper.** About 20 sites end in
  `.query_map(..)?.collect::<rusqlite::Result<Vec<_>>>()?`. Replace them with a
  `fn all<T>(rows: impl Iterator<Item = rusqlite::Result<T>>) -> Result<Vec<T>>` in
  `mod.rs`. The two `HashSet` collects keep their own form.
- **`from_row` beside its struct.** The free `conversation_row` becomes
  `ConversationRow::from_row(r: &rusqlite::Row<'_>) -> rusqlite::Result<Self>`.
  `RawTopic` stays a tuple: `topic_of` parses its JSON columns with anyhow context
  (`topic.images`, `topic.production`), and a `rusqlite::Result` constructor could only
  carry that as a `FromSqlConversionFailure`, a worse error for no gain. Mappings that
  are already a clear closure are left alone.

## 3. SQLite off the tokio workers

`Db::with` becomes:

```rust
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

`block_in_place` tells the runtime that this worker is about to block, so tokio hands the
worker's other tasks to another thread. The calling task still waits, exactly as it does
today. The daemon's `#[tokio::main]` is multi-thread. The 362 `#[tokio::test]`s run
current-thread and the one-shot commands may run with no runtime; `block_in_place` panics
in both cases, so those call `run()` directly. The doc comment says this, and keeps the
existing rule: never hold the result of `with` across an `.await`.

Test: a `#[tokio::test(flavor = "multi_thread", worker_threads = 2)]` that runs a `Db`
write and read while a spawned task completes, and asserts that both finish. It shows that
the multi-thread path runs and does not panic. It does not try to measure scheduling.

## 4. Backend bundles for the generics

```rust
pub trait Backends: Send + Sync + 'static {
    type Tracker: TrackerApi;
    type Torrents: TorrentClient;
}

pub trait IdentifyBackends: Send + Sync + 'static {
    type Stash: StashApi;
    type Llm: Llm;
    type CodeSearch: CodeSearch;
    type Torrents: TorrentClient;
}
```

- `WebState<T, C>` becomes `WebState<B: Backends>` and `Ctx<'a, T, C>` becomes
  `Ctx<'a, B: Backends>`. Fields become `Arc<B::Tracker>` and so on. Every
  `<T: TrackerApi, C: TorrentClient>` function in `web.rs`, `web/assistant_routes.rs`,
  `plab.rs`, `curated.rs` and `events.rs` becomes `<B: Backends>`.
- The `K: Classify` parameter on `refresh` and `run_curated` stays separate. It is a
  per-call strategy, not a backend, so those signatures read `<B: Backends, K: Classify>`.
- `identify::Clients<'a, S, L, J, T>` becomes `Clients<'a, B: IdentifyBackends>`, with
  `watch` and the identify-pass functions to match.
- `GrabSource` sites (two) are left alone, since a two-parameter signature used twice is
  not a burden.
- Both traits and production's `pub struct Live;` live in a new `src/backends.rs`.
  `Live` implements both with the real `Tracker`, `Transmission`, `Stash`, `OpenRouter`
  and `CodeDb` types.
- A projection like `B::Tracker` does not let the compiler infer `B` from a struct
  literal, so each construction site names it: `Ctx::<Live> { .. }`,
  `WebState::<Live> { .. }`, `Clients::<Live> { .. }`. Calls to the generic functions
  still infer `B` from their `Ctx`/`WebState`/`Clients` argument.
- Tests: one zero-sized marker per fake combination already in use, defined next to
  the fakes. `web_tests` and most of `plab_tests` use `FakeTracker` + `FakeTorrents`;
  `plab_tests.rs:1252` uses the real `Tracker` + `Transmission` and gets `Live`. The
  identify tests get the markers that their current `Clients` instantiations imply.

## Sequence and verification

Four commits, each `refactor(galactica): …`, in this order:

1. db split, moves only
2. db tidy (migrations, `all`, `from_row`)
3. `block_in_place` in `Db::with`, with its test
4. `Backends` / `IdentifyBackends`

After each commit, `cargo test` and `cargo clippy --all-targets` are green in
`packages/plab`. Before pushing, `nix build .#plab` must pass. It runs `cargo test` in
`checkPhase`, so it is the gate. After deploy, the check is that `plab.service` on galactica is active and
`/api` answers, because nothing user-visible is supposed to change.
