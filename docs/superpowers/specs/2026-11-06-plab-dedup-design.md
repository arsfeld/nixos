# plab dedup — one card per scene, and scenes already owned say so

**Host:** galactica · **Code:** `packages/plab/` ·
**Builds on:** `2026-11-03-plab-source-tabs-design.md`, `2026-11-02-plab-external-sources-design.md`,
`2026-11-03-plab-daily-picks-design.md`

## Goal

Two problems, one cause:

1. **Same scene, two cards.** One scene released on the tracker and on another indexer (or
   twice on one source, under a different naming or quality) shows up as several cards.
2. **Already-owned scenes re-offered.** A card counts as "have it" only when *its own* id has
   a download row (`Downloads.by_topic`, `db.added()`). A scene downloaded through a different
   release, indexer or grab still looks new on the lists, and the assistant's daily picks
   still offer it.

Both lack the same thing: a way to say that two releases are the same scene. plab has three
partial answers today, none of them usable for this:

- `grab::scene_keys` needs a per-studio `Rule` to strip the studio prefix. It serves the
  auto-grab rules, whose keys persist in `grab_seen`. **Out of scope; left as is.**
- `external::is_duplicate` matches same release date plus one shared performer name. It is
  one-directional (external vs tracker titles) and needs the curated filter term.
- `external::collapse` merges exact re-encodes by `title_key`. **Stays**: it works without a
  date.

**Decided with the user:**

- duplicates collapse into one card that lists the other releases as alternatives;
- "owned" means plab downloaded the scene, through any release or source;
- an owned card stays visible, marked, with Add disabled; picks skip it;
- the matching is rule-free (date plus names) and runs at serve time, with no schema change.

## 1. What "the same scene" means: `src/same.rs`

The only definition. It replaces `external::is_duplicate`.

```rust
pub struct SceneSig { pub date: NaiveDate, pub names: HashSet<String> }

/// None when the title carries no readable release date.
pub fn sig(title: &str, noise: &[String], stop: &[&str]) -> Option<SceneSig>;
/// Same date, and at least one name in common.
pub fn same(a: &SceneSig, b: &SceneSig) -> bool;
/// Indices grouped by `same`, transitively (union-find); singletons included,
/// each group in input order, groups ordered by their first member.
pub fn groups(sigs: &[Option<SceneSig>]) -> Vec<Vec<usize>>;
```

- `date` comes from `external::release_date`, which already reads `YYYY-MM-DD`,
  `DD.MM.YYYY` and 1337x's `yy mm dd`.
- `names` uses the `person_tokens` rule: words of 3+ alphabetic characters that aren't in
  `STOP`, `noise` or `stop`. `person_tokens` takes a single filter `term`; `sig` takes
  `stop: &[&str]`, a list of words to drop. At serve time a card has no single term, so
  callers pass the words of both cards' studio labels (the `studio` that `labels::labels` reads from a title).
  Otherwise a studio word shared by two different scenes from the same day would link them.
  Curated and assistant search pass their term's words, which keeps today's behavior.
- `same` is not transitive, so `groups` takes the transitive closure. Only signatures with
  equal dates are compared, so the pairwise work is per-date buckets and stays small.
- **Fails safe.** No readable date means no signature, which means never merged and never
  owned. A miss leaves a duplicate visible; it can never hide a different scene.
- **Accepted false-positive risk:** two different scenes from one studio on the same day,
  sharing a performer. The second release still appears under "also" (§2), so nothing is
  lost.

`external::is_duplicate` is removed. `curated.rs` and `assistant/search.rs` call
`same::sig`/`same::same` instead, and its tests move to `same.rs` with the same expected
results.

## 2. One card, the other releases as "also"

Applied when a list is served (`web::list`, `web::search` → `api::list`), not at refresh.
Statuses change between refreshes, and serve time needs no stored state.

- **Tracker tab (`video`).** `web::list` also loads the `indexers` listing. The two sets of
  topics are grouped together. Each group's card is its tracker topic (the highest-seeded
  one if there are several). Every other member becomes an `also` entry.
- **Indexers tab.** A group that contains a tracker topic is left out: that scene's card
  lives on the Tracker tab. The remaining groups collapse to their highest-seeded release.
- **Search results** group the same way as the Tracker tab.
- **Albums and Games** are not grouped. Albums carry no dates, and games aren't scenes.
- Ordering: the card takes the position of its winner under the existing `score` sort.
- A merged card's `filters` is the union of its members' filters. That way a filter whose
  only hit is now an "also" still shows its chip, and the chip counts are counts of cards.

**DTO.** `TopicDto` gains:

```rust
pub also: Vec<AlsoDto>,
pub struct AlsoDto {
    pub id: u64,               // tracker topic or external_release id: valid for add/stream
    pub source: Option<String>,// None: the tracker
    pub seeders: u32,
    pub size: u64,
    pub quality: Option<String>,
    pub link: Option<String>,  // http(s) only, as `TopicDto.link`
    pub state: &'static str,   // its own added/queued state
}
```

**UI.** `types.ts` gains `also: Also[]`. A card with alternatives shows one line such as
`also: Indexer A · 42 seeders · 1080p`. Each entry has its own Add and Stream, which post
to that entry's `id` through the existing endpoints, so the add/stream paths do not change.

## 3. Owned scenes keep their card and show the existing download

- **New db call:** `download_titles() -> Vec<DownloadTitle { id, topic_id, release_title }>`
  covering every `download` row, queued ones included. `added()` already spans all time,
  so this does too.
- `api::list` computes `sig` once per download title (stop words: the title's own studio
  label). A card or `also` entry is **owned** when either:
  - its own id is in `added`/`queued`, the check that exists today, or
  - `same::same` matches its signature against a download's.
- **Badge.** An owned card gets `ownedBy: Some(download_id)`. Its badge is that download's
  status. `Downloads` gains `by_download: HashMap<i64, Status>` next to `by_topic`, because
  a grab has no `topic_id`. A download older than the 30-day live window has no status, and
  the card then shows `added`.
- **Actions.** Add is disabled and labeled "have it". Stream stays available. The `also`
  entries of an owned card are owned too.
- **Assistant and daily picks.** `assistant/context.rs` sets `ReleaseIn.downloaded` with the
  same owned test, replacing `added.contains(&row.id)`. `candidates()` already drops
  `downloaded` releases, so picks stop offering owned scenes with no further change.

The owned check lives in one function, `same::Owned::new(&[DownloadTitle], noise)` with
`.matches(&SceneSig) -> Option<i64>`. `api::list` and `context.rs` both use it.

## 4. Errors and tests

Nothing new here can fail at runtime: it is all pure functions over data already loaded. A
failing `download_titles` returns a 500, the same as a failing `added()` does today.

**`same.rs` unit tests:**

- the 1337x and tracker pair from `686115c5` (dated `yy mm dd`, "And" against commas,
  performers reordered) is `same`;
- a different date is not `same`;
- no readable date gives no signature;
- studio and noise words alone do not link two scenes;
- grouping is transitive (A↔B, B↔C gives one group);
- `is_duplicate`'s existing cases keep their results.

**`api` tests (`api_tests.rs`):**

- tracker plus indexer release give one card with one `also`, and the tracker topic wins;
- the Indexers tab drops the scene that has a tracker topic;
- two indexer releases of one scene give one card, and the higher-seeded wins;
- a card matching a download from a *different* source shows that download's status and
  `ownedBy`;
- filters are unioned on a merged card.

**Other tests:**

- **Assistant:** an owned-through-another-release scene is `downloaded` and absent from
  `candidates()`.
- **UI (vitest):** the formatting of the "also" line.

## Not in scope

- Matching against the whole Stash library (scenes not downloaded by plab).
- Scene-database ids as an identity (`external_release.scene_id`); revisit only if date
  plus names misses real cases.
- Changing `grab::scene_keys` or `grab_seen`.
