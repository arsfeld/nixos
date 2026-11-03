# plab source tabs — one tab per curation source, plus an album index

**Host:** galactica · **Code:** `packages/plab/`, `modules/hosts/galactica/services/plab/` ·
**Builds on:** `2026-11-02-plab-external-sources-design.md`, `2026-10-12-plab-curated-filters-design.md`

## Goal

Curated releases from very different sources currently share one grid: the tracker's own
topics and releases from other torrent indexers sit side by side, told apart only by a
badge. That is confusing. This design gives each kind of source its own tab, and adds a
third kind: an **album index**, a site that lists albums hosted on a direct-HTTP file host.

The album source is for curation only. plab does not stream, download or resolve files from
the file host; an album card links out to the album page, where it can be watched.

**Nothing identifying lives in this repository**, as in the external-sources design: the
index's URL and label come from the `plab-sources` sops secret. This document, the code, its
comments and the tests use placeholders (`Album index A`, `alpha`).

## What the index offers (surveyed 2026-11-03)

- An HTML search, `<base>/?search=<term>&mode=<mode>&per=<n>&sort=latest&page=<p>`. Modes:
  broad, strict, fuzzy, substring, whole word. Page sizes 20, 40, 60, 100. No login, no API,
  no feed. Its "top" pages render client-side and are not used.
- Each result is an `<a href>` to the album page on the file host, holding a thumbnail
  `<img>` on the file host's CDN, an `<h3>` with the album name, and an `N files` count.
- **No date, size or seeders.** `sort=latest` orders by recency, but no timestamp is shown.

## Tabs

The navbar becomes **Tracker / Indexers / Albums / Games / Jobs**.

| Tab | Section | Contents |
|---|---|---|
| Tracker | `video` (unchanged id) | weekly top 100 + the tracker's curated hits |
| Indexers | `indexers` (new) | curated hits from other Prowlarr torrent indexers |
| Albums | `albums` (new) | curated hits from the album index |

- `Section` (`db/mod.rs`) gains `Indexers` and `Albums`; `listing` is already keyed by
  section, so each tab is a listing like Games. The `video` section id stays so existing
  URLs and stored listings keep working; only the tab label changes to "Tracker".
- Albums have no seeders, so the list is ordered newest `added` first; within equal `added`, terms
  interleave round-robin (every term's 1st album, then every term's 2nd), ties in filter-file order.
- `refresh` of `video` builds the Tracker listing from the top 100 and the `curated_hit`
  rows whose topic is a tracker topic, and the other two listings from the hits whose
  `external_release.kind` is `torrent` or `album` respectively. External releases no
  longer appear in the Tracker listing.
- Each tab has its own filter bar. The curated-filter chips list only filters with hits in
  that tab, with that tab's counts.
- Indexer cards are unchanged: badge, Stream and Add to Vault as before.

## The filter file

A term prefixed with `%` is searched on the album index. Prefixes combine (`@%alpha` is
searched on the tracker, through Prowlarr and on the album index), in either order:

```text
[Group A]
@alpha
%beta
@%"two words"
```

All prefixes are stripped before searching or matching titles. A term gains
`albums: bool` beside `elsewhere` in `filters.rs`. A file with no `%` behaves as before.

## Configuration: `plab-sources`

Three new keys in the existing `PLAB_SOURCES_FILE`:

| Key | Meaning |
|---|---|
| `album_index_url` | Base URL of the index's search page |
| `album_index_label` | The badge and `external_release.indexer` value; defaults to `albums` |
| `album_search_mode` | The index's `mode` parameter; defaults to `strict` (every word must appear) |

Without `album_index_url`, `%` terms are searched nowhere else and a warning is logged once
per run. The tracker and Prowlarr parts of `curated` are unaffected.

## The `curated` job: album step

Added after the Prowlarr step, before the store:

1. For every `%` term, one `GET` of the first search page with `sort=latest`, `per=40` and
   the configured mode, made directly from galactica (not through PIA: no media traffic
   flows, only a few dozen HTML pages a day). The same inter-search delay as the tracker
   applies. A failed request is logged and the term skipped.
2. **Parse** (`albums.rs`, pure): each result anchor yields album id (the last path segment
   of its href), href, name, file count and thumbnail URL. A page that reports results but
   yields zero parsed cards (its `page 1 of N` header has N > 0) is logged as a warning naming the term, so a layout change
   cannot pass for an empty day.
3. **Upsert.** Each album gets an `external_release` row (`kind = 'album'`, `indexer` = the
   label, `guid` = album id, `link` = `info_url` = href, `files` = count; an existing
   (indexer, guid) keeps its id) and a `topic` row with the name as title, `forum` 0, size,
   seeders and leechers 0, and `added` set to the album's `first_seen`: **the time plab first
   saw it**, stored on `external_release` at insert and never updated.
4. **Window.** Albums first seen more than 32 days ago are not recorded as hits. On the
   first run every returned album is new; that is bounded by 40 × the number of `%` terms.
   Album rows are **never pruned**: an album that ages out but stays on the results page
   must not be re-seen as new once its topic row is gone. A row is about 100 bytes and only
   genuinely new albums add one.
5. **No classification and no scene lookup.** Album names are free text: they fit neither the
   classifier's input nor the scene database. Every album hit is kept.
6. **Images.** `topic.images` is set to the thumbnail URL, fetched through the existing
   image cache on first view. A missing thumbnail renders the existing placeholder.
7. Album hits join the other hits in the single `curated_hit` replacement, so a failed
   run leaves yesterday's hits in place exactly as before.

## Data

Added by the schema migration (`schema_v6.sql`):

```sql
ALTER TABLE external_release ADD COLUMN kind TEXT NOT NULL DEFAULT 'torrent';  -- 'torrent' | 'album'
ALTER TABLE external_release ADD COLUMN files INTEGER;                         -- albums: file count
ALTER TABLE external_release ADD COLUMN first_seen INTEGER NOT NULL DEFAULT 0; -- unix time of first sight
```

Existing rows are torrent releases, which the default records. `save_curated`'s prune of
external rows without a topic is limited to `kind = 'torrent'`. `Source::of(id)` stays the
tracker/external split; `kind` is read only where tracker-vs-external is not enough
(listing split, the card, and refusing stream and add).

## API and card

- Topic JSON gains `kind: 'tracker' | 'torrent' | 'album'` and `files: number | null`.
- `Card.svelte` for an album shows thumbnail, name, `N files` and the source badge, and one
  **Open** button linking to `link` in a new tab. No size, seeders, Stream or Add to Vault.
- The stream and add routes answer `400` for an album topic, so a stale page or a hand-made
  request cannot reach the torrent path with an album id.

## Tests

- `albums.rs` parser against a fixture: a captured search page with every title and
  thumbnail replaced by placeholders, plus a variant with the result markup changed, which
  must yield zero cards and the warning.
- `curated` against a wiremock index: `%` terms searched, others not; no `album_index_url`
  skips the step; first-seen `added` is kept across two runs; an album past 32 days of
  first sight is not a hit.
- `refresh`: each section's listing holds only its own kind; Tracker holds no external
  release.
- Filter parsing: `%`, `@%`, `%@`, quoted terms.
- API: album topic serializes `kind` and `files`; stream and add refuse it with `400`.
- Vitest (the app tests `lib/` only, in node): the route parser maps `/indexers` and
  `/albums`; the album card's `N files` label.

## Out of scope

- Streaming, downloading or resolving files from the file host.
- Live search against the album index.
- Classification of album names.
