# plab external sources — curated releases from more than one indexer

**Host:** galactica · **Code:** `packages/plab/`, `modules/hosts/galactica/services/plab/` ·
**Builds on:** `2026-10-12-plab-curated-filters-design.md`, `2026-11-02-plab-streaming-design.md`,
`2026-10-30-plab-production-ranking-design.md`

## Goal

The curated view (one toggle per filter in the `plab-filter` secret) also shows releases
from the other indexers Prowlarr already has, beside the tracker's own, with images. Each
such card can be streamed and added to Vault like a tracker card. The curated searches
move to a daily job.

**Nothing identifying lives in this repository**: no group name, search term, indexer
name, category, service URL or title vocabulary. All of it comes from sops secrets
exposed to plab as `*_FILE` environment variables. This document, the code, its comments
and the tests use placeholders (`Group A`, `Indexer A`, `alpha`).

## Why: the survey (2026-11-02)

Release counts from Prowlarr on galactica over a 32-day window, per indexer:

| Term | Indexer A | The tracker |
|---|---|---|
| Group A | 40, with 45–52 seeders each | 3 |
| Group B | 80 (capped) | 36 |
| Group C | 0 | 34 |
| a generic term | 52 | — |

- Indexer A adds releases rather than mirroring the tracker. One uploader posts episodic
  releases there that the tracker mostly skips, and its swarms are often larger.
- Some groups exist only on the tracker, so the tracker stays a source; this adds to it.
- Indexer B adds recent creator-run releases with small swarms. Indexers C and D carry
  mostly older material. Indexer E was failing at the time: Prowlarr had disabled it.
- Generic terms bring old re-uploads (a 2012 release posted this week), studio lines that
  merely use the term, and the same release in several resolutions.
- Indexer A's pages sit behind a bot check and are not scraped. Images come from the scene
  database that `codedb.rs` already queries. A lookup on a lightly cleaned title matched 3
  of 4 sampled releases, each with a poster and a background. The miss was 3 days old and
  not catalogued yet.

## Configuration: `plab-sources` (`PLAB_SOURCES_FILE`)

A new sops secret, owned by `media`, exported as `PLAB_SOURCES_FILE` the way `plab-filter`
is. Its format is plain `key = value` lines, with blank lines and `#` comments ignored:

| Key | Meaning |
|---|---|
| `primary_indexer` | Prowlarr name of the tracker's own indexer, excluded from external searches |
| `categories` | Comma-separated Prowlarr category ids to search |
| `scene_url` | Base URL of the scene database's scene search |
| `noise` | Comma-separated title tokens removed when normalizing titles |

- With no file, or with no `categories`, the external part of `curated` is skipped and
  logged once. The tracker's curated searches keep working.
- With no `scene_url`, there are no lookups, and external cards show the placeholder.
- Tests use placeholder values throughout.

## Jobs

| Job | Period | Does |
|---|---|---|
| `refresh` | 3 h (unchanged) | the tracker's weekly top 100; rebuilds the listing from it plus `curated_hit` |
| `curated` (new) | 24 h, offset 07:00 UTC | every curated term on the tracker; `@` terms through Prowlarr; scene lookups; 32-day window |

- `pub const CURATED: Schedule = Schedule { period: 24 * 3600, offset: 7 * 3600 }` in
  `jobs.rs`. It is run by `run_periodic` and recorded through `jobs::record`, so it shows
  on the jobs page. 07:00 UTC avoids the 06:00 refresh and the 04:00 sweep.
- `plab curated` runs it once by hand. A missed slot runs on daemon start, so the first
  deploy fills the view at once.
- The per-term searches move out of `refresh` (the loop over `filters` in `plab.rs`).
  Title-term matching of top-100 topics (`labels::match_term`) stays in `refresh`: it
  needs no search and costs nothing.

## The filter file

A term prefixed with `@` is searched on the tracker as today **and** through Prowlarr:

```text
[Group A]
@alpha
beta
@"two words"
```

The `@` is stripped before the term is searched or matched against titles. A file with no
`@` behaves exactly as before. Parsing lives in `filters.rs`, where a term gains
`elsewhere: bool`.

## Data

All in `state.db`, added by the existing schema migration.

```sql
-- Hits of the last `curated` run; refresh merges them into the listing.
CREATE TABLE curated_hit (
  topic_id INTEGER NOT NULL REFERENCES topic(id),
  filter TEXT NOT NULL,
  reason TEXT NOT NULL,            -- the term that found it: the card's badge
  PRIMARY KEY (topic_id, filter)
);

-- A release from another indexer, and the plab id it is known by.
CREATE TABLE external_release (
  id INTEGER PRIMARY KEY,          -- >= 1<<40: never a tracker topic id
  indexer TEXT NOT NULL,
  guid TEXT NOT NULL,
  link TEXT NOT NULL,              -- Prowlarr download URL (yields .torrent or magnet)
  info_url TEXT,                   -- the release's page, for the card's link
  scene_id TEXT,                   -- NULL = not matched (yet)
  UNIQUE (indexer, guid)
);
```

- A `curated` run replaces `curated_hit` in one transaction, so a run that fails leaves
  yesterday's hits in place.
- External ids come from an `AUTOINCREMENT` column whose sequence is seeded so the first
  id is `1 << 40`. Ids are never reused, so a stored .torrent or download row can never be
  inherited by a different release. Tracker topic ids are around 7 million. JavaScript
  numbers are exact up to 2^53, so the ids pass through the JSON API and the Svelte app
  unchanged.
- `Source::of(id)` (`id >= 1 << 40` means external) is the only branch point. Everything
  keyed by a topic id works unchanged: listing, filters, production class, `torrent_file`,
  streams, the API routes and the cards.
- The prune that deletes topics no longer in `listing` leaves external releases alone.
  `save_curated` drops the `external_release` rows with no `topic`, in its own
  transaction, so a refresh can never delete a row the curated job is still working on.
- The card's indexer badge and link come from `external_release`; `topic` is unchanged.
  The indexer name comes from Prowlarr at runtime and is never written into the
  repository.

## The `curated` job

1. **Tracker.** For every term of every filter, `tracker.search(term, forums, 32 days,
   20)`, as `refresh` does today. The delay between searches is the same, one failed
   search is logged and skipped, and a login error is fatal. Hits are upserted into
   `topic` and recorded as `(topic, filter, term)`.
2. **Prowlarr.** For every `@` term, one `Prowlarr::search` with the configured
   `categories` and the ids of every enabled torrent indexer except `primary_indexer`.
   The indexer list is read from `/api/v1/indexer` on each run, so an added indexer is
   picked up and a disabled one skipped. Results older than 32 days are dropped, and a
   failed search is logged and skipped.
3. **Variant collapse.** Results whose titles normalize to the same key are one release.
   Normalizing lower-cases the title, unifies separators, and removes resolution tokens
   (`\d{3,4}p`), container extensions, the configured `noise` tokens, and a trailing
   bracketed or all-caps release-group tag. The release keeps the best-seeded result's
   indexer, guid, link, seeders, leechers and size.
4. **Dedup against the tracker.** A release is dropped when a tracker hit of the same
   filter has the same date and shares a person-name token. Dates are read in the
   `YY MM DD`, `YYYY.MM.DD`, `(DD.MM.YYYY)` and `[YYYY-MM-DD` forms. A release with no
   readable date is never treated as a duplicate.
5. **Classify.** A release with no cached production class goes through the existing
   `Classify` client once, with the tracker's `Other` category (forum 0) as the category
   passed. With no classifier configured, the external pass is skipped. **Releases in the class that ranking pushes down
   (`industrial`) are dropped**; the other classes stay and rank by the existing
   weighting. A failed classification holds the release back until the next run, rather
   than showing it unclassified.
6. **Upsert.** Each surviving release gets its `external_release` row (an existing
   (indexer, guid) keeps its id) and a `topic` row
   with title, size, seeders, leechers, `added` (the publish date) and `forum` 0.
7. **Scene lookup.** Every external release among this run's hits with `scene_id` NULL is
   looked up (see Images). A miss leaves it NULL, and it is retried on the next run.
8. **Store.** All hits from steps 1 and 6 replace `curated_hit`.
9. **Rebuild.** `refresh` of the video list runs, so the hits show at once.

## Images

- `codedb.rs` gains `scene_search(title) -> Option<SceneHit>` against
  `<scene_url>?parse=<title>&per_page=1`. It uses the key plab already resolves from
  Stash's stash-box config. `SceneHit` keeps the id, site name, title, date, poster and
  background.
- The title is cleaned before the lookup: the variant-collapse removals, plus an episode
  token (`E\d+`) dropped and a `YY MM DD` date rewritten as `20YY-MM-DD`.
- A hit is accepted only if its site name matches the term that found the release (by
  `labels::match_term`), or the release title contains the site name. Anything else
  counts as a miss, so a release found by a generic term never borrows another release's
  images.
- On a hit, `scene_id` is stored and `topic.images` is set to the poster and background
  (whichever are present), fetched through the existing image cache.
- `topic_images` for an external topic never calls the tracker. It returns the stored
  images, or an empty list, which the card renders as its existing no-image placeholder.

## Streaming

- `stream.rs` gets the torrent for a topic through `torrent_source(id)`:
  - Tracker topic: unchanged (`torrent_file`, else one tracker grab, which is stored).
  - External topic: `torrent_file` if stored, else `Prowlarr::fetch(link)`. A `.torrent`
    answer is stored in `torrent_file` like a tracker grab. A magnet is used as is.
- `Rqbit::list` and `Rqbit::add` take a `TorrentSource`: bytes as today, or the magnet
  string as the request body, which rqbit's `POST /torrents` accepts. This has not been
  checked yet; the plan's first task verifies it against rqbit 8.1.1. For a magnet,
  `list_only` waits for metadata from peers, and the start-progress step reads
  "Resolving magnet".
- No tracker limit applies, so an external start never yields `429`.

## Add to Vault

`add_topic` for an external topic sends the same `TorrentSource` to Transmission: the
stored `.torrent`, or `Prowlarr::fetch(link)`. It never touches the tracker, so it is
never queued. It is recorded with `source = 'plab'` and the topic id, like any plab add.
`save_cover` uses the topic's first image when there is one and skips the cover
otherwise.

## Page

Cards from another indexer carry a small badge with the indexer name, which comes from the
API data. Nothing else in the Svelte app changes: the cards, filters, Stream and Add to
Vault all work on the ids they already have.

## Error handling

| Case | Behaviour |
|---|---|
| `plab-sources` missing or incomplete | external pass skipped and logged; tracker hits still stored |
| Prowlarr unreachable | all `@` searches skipped and logged; tracker hits still stored; yesterday's external releases drop out of `curated_hit` for a day |
| One indexer failing or disabled in Prowlarr | skipped; the others still answer |
| Scene database unreachable, or no key | no lookups this run; cards show the placeholder; retried next run |
| Classifier failure on a release | that release is held back until the next run |
| `curated` fails outright | `curated_hit` keeps yesterday's rows; the jobs page shows the error |
| `Prowlarr::fetch` fails on Stream or Add | the error reaches the toast, as a tracker failure does now |
| Magnet with no peers for metadata | the start shows "Resolving magnet"; `list` is bounded at 120 s, then fails with `502 no peers for metadata` (the gateway replaces some 5xx bodies, and 502 is the status plab already uses for engine errors) |

## Testing

`cargo test`, run by the package build, with placeholder names and values throughout:

- `filters.rs`: `@` sets `elsewhere` and is stripped; a quoted `@"two words"` works; a file
  with no `@` parses as before.
- `plab-sources` parsing: every key; a missing file and a missing `categories` both
  disable the external pass.
- `jobs.rs`: `CURATED` slots and `overdue`.
- Variant collapse: resolution, noise-token and group-tag variants of one title become one
  release, and the best-seeded copy is kept; different titles stay apart.
- Dedup: the same date plus a shared person-name token in two title styles drops the
  external release; a title with no readable date is never dropped.
- `curated`, with a stub tracker, Prowlarr, classifier and scene database:
  - the down-ranked class is dropped;
  - a classifier failure holds the release back;
  - an existing (indexer, guid) keeps its id, and new ids start at `1 << 40`;
  - a failed run leaves `curated_hit` unchanged;
  - tracker hits are stored when Prowlarr is down.
- `Prowlarr::search` sends `categories` and `indexerIds`, and the indexer list excludes
  `primary_indexer` and disabled indexers (wiremock, like the existing tests).
- `scene_search` decoding; title cleaning; a site-name mismatch counts as a miss.
- `refresh` merges `curated_hit` into the listing. External topics survive prune while
  listed, and their `external_release` row goes with them.
- Stream and Add for an external id, with a stub Prowlarr: a `.torrent` is stored and
  reused; a magnet goes to rqbit and Transmission as a magnet; the tracker is never
  called.
- `rqbit.rs`: a magnet `list` and `add` send the magnet as the body.

Manual, after deploy:

1. Write the `plab-sources` secret.
2. Mark the terms with `@` in `plab-filter`.
3. Run `plab curated`.
4. The curated view shows badged cards from another indexer, with images.
5. Stream one from a magnet and seek.
6. Add one to Vault and see it in Transmission.

## Out of scope

- Scraping indexer pages.
- Scene-database images beyond the poster and background.
- Frames grabbed from the swarm.
- External releases outside the curated filters: the weekly top and live search stay
  tracker-only.
- Seeding.
