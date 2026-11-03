# plab: Rust idioms after the port

## Why

plab was ported from Python with byte-for-byte parity as a hard requirement
(`2026-11-01-plab-rust-merge-design.md`): the parity check was a diff against the
Python's output. The Python is gone, so the code that existed only to serve that diff
can go too. It is concentrated in the identify path:

- `serde_json::Value` used as Python dicts in `identify/matching.rs`, `stash.rs`,
  `identify/mod.rs` and `llm.rs`, read through a small Python runtime: `truthy`, `or`,
  `cget` ("`dict.get` then serialise"), `py_str`, `py_repr`, `compact`, `to_float`.
- `src/py.rs`: `html.escape`, `json.dumps` (ensure_ascii, `", "` separators, Python
  float repr) and `repr(str)`, kept so the golden pages and LLM prompts matched Python.
- Python `repr` (`None`, `'quoted'`, `[...]`) in log lines and LLM prompt inputs.

The rest of the crate (`db`, `tracker`, `provenance`, the `thiserror` enums, typed
listing rows) is already idiomatic and is not touched. `page.rs` keeps its string-built
HTML; templating it is out of scope.

## Domain types

Stash and stash-box records become `serde` structs, one per shape the code reads.

**Read from Stash / stash-boxes:**

- `Scene`: `id`, `title`, `code`, `details`, `director`, `date`, `urls`,
  `studio: Option<StudioRef>`, `performers: Vec<Ref>`, `tags: Vec<Ref>`,
  `stash_ids: Vec<StashId>`, `files: Vec<VideoFile { path, duration }>`. Methods replace
  the free helpers: `first_file()`, `is_filled()` (was `filled`), `is_upgrade()`.
- `Candidate`: a ScrapedScene (`title`, `code`, `date`, `details`, `duration`, `image`,
  `urls`, `studio: Option<ScrapedStudio>`, `performers: Vec<ScrapedPerformer>`, `tags`,
  `remote_site_id`). `codedb_scene` and `fc2_scene` become constructors from a typed
  `CodeDbHit`. `describe()` becomes `impl Display for Candidate`.
- `ScrapedPerformer`, `ScrapedStudio`: the attributes `performer_create_input` and
  `studio_create_input` copy across today.
- `StashId { endpoint, stash_id }`, `Ref { id }`.

**Written to Stash:** `SceneUpdate`, `PerformerCreate`, `StudioCreate`, all `Serialize`
with `#[serde(skip_serializing_if = "Option::is_none")]` (or `Vec::is_empty` where an
empty list was dropped before), replacing `compact`, `strip_nulls`, `to_enum` and null
handling. `Gender` becomes an enum; an unknown upstream value
deserializes to an `Unknown` variant (`#[serde(other)]`) and is not written, which is
what the `GENDERS` filter did.

`scrape_update`'s eight arguments become
`scene.update_from(&candidate, &Resolved { studio_id, performer_ids, tag_ids, stash_ids }, drop_tags, overwrite) -> SceneUpdate`,
removing its `too_many_arguments` allow. The fill-empty-only / overwrite semantics are
unchanged.

**LLM:** `Parse` (title, studio, performers, date, time, series, clip_id, …) replaces
the `Value` from `Llm::parse`/`parse_with_title`; `display_title()` becomes a method on
it. `Llm::choose` takes and returns typed `JevState`/`JevAnswer`.

**Proposal becomes an enum:**

```rust
enum Proposal { Nothing, Llm(Parse), Scrape(ScrapeMatch) }
struct ScrapeMatch { rule, source, candidate: Candidate, endpoint, stash_ids, confidence, delta }
```

`format_line` becomes `Display`. `outcome_of`'s `&'static str` becomes an `Outcome`
enum whose `as_str()` keeps the stored values (`scrape`, `llm`, `none`, `stash`), so
the database needs no migration.

**Where `Value` stays:** Stash's `configuration.defaults` scan/generate/identify blobs.
plab never reads inside them; it merges a few keys and sends them back. They become
`JobOptions(serde_json::Map<String, Value>)` with a `with(extra)` method. `web.rs` keeps
`json!` only for response bodies whose shape is not fixed.

**Mixed types:** `de::lenient_f64` (number or numeric string) goes on `duration` only.
Another field gets a lenient deserializer only when a real reply (a test fixture taken
from the code database or StashDB) shows it sends mixed types.

## Sequence

One commit per step; `cargo test` passes after each, and each step's tests change in
the same commit as its code.

1. **Types and `StashApi`.** Add the types; the trait and the `Stash` client return and
   take them (`at`, `list`, `strip_nulls`, `with` go). The fake Stash in
   `identify/tests.rs` builds typed values. `matching` is reached through a temporary
   `serde_json::to_value` shim, deleted in step 2.
2. **`matching.rs`** over the typed records. `truthy`, `or`, `get`, `cget`, `as_str`,
   `py_str`, `py_repr`, `compact`, `to_float`, `to_int`, `to_float_value`, `to_enum`,
   `aliases` go. `matching_tests.rs` moves to typed fixtures.
3. **`identify/mod.rs` and `llm.rs`.** The `Proposal` enum, `Outcome`, typed `Parse`
   and Jev structs, `Display` for the pass's log lines. `str_of` and `repr_list` go.
4. **Remaining `Value`:** Prowlarr results in `grab.rs` become `ProwlarrResult`
   (`rank`, `title_of` read fields); the stragglers in `codedb.rs`, `transmission.rs`,
   `rqbit.rs`; fixed-shape `web.rs` replies become `#[derive(Serialize)]` structs.
5. **Delete `py.rs`.** `escape` becomes the `html-escape` crate; `json` becomes
   `serde_json::to_string`, with `<`, `>` and `&` escaped as `<`, `>`,
   `&` where the JSON lands inside `<script>` or an attribute. The golden fixtures
   are regenerated once, and the "byte-identical to page.py" comments go.

## Prompts and logs

- Record inputs to the LLM (Jev candidates, the parse input) are serialized with
  `serde_json`. Instruction text is unchanged word for word.
  `tests/fixtures/*_prompt.txt` are regenerated; their diff must show formatting only.
- Log lines use Rust formatting: `{:?}` where a string or list was quoted, `-` for a
  missing value instead of `None`. Same fields in the same order, so journal greps keep
  working.

## Errors

A reply that fails to deserialize names its query (`.with_context(|| "findScenes reply")`)
and is an ordinary error for that scene or pass, as a missing key is today. `Transient`
is unchanged.

## Testing and rollout

- The existing behaviour tests are the net. Their fixture construction changes; every
  assertion about what is written to Stash stays.
- One new test per field given a lenient deserializer.
- After deploying to galactica, watch one identify pass in the journal and the page's
  provenance statuses.

**Prerequisite:** the plab work uncommitted at the time of writing (identify, stash,
page, llm and the golden fixtures) lands first; step 1 touches the same files.
