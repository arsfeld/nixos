# plab source tabs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** plab shows each curation source in its own tab (Tracker, Indexers, Albums), and
the daily `curated` job also searches an album index for terms marked `%`.

**Architecture:** Two new `Section`s (`indexers`, `albums`) get their listings from
`curated_hit` rows split by `external_release.kind`, through a new
`curated::rebuild_external` that makes no tracker request. The Tracker (`video`) list
keeps only tracker hits. A new `albums.rs` holds a pure parser for the index's search page
and a small reqwest client. Album cards only link out: add and stream refuse them.

**Tech Stack:** Rust (axum, reqwest, rusqlite, regex, html-escape, wiremock),
Svelte 5 + TypeScript (vitest, svelte-check), sops-nix. Code in `packages/plab/`.

**Spec:** `docs/superpowers/specs/2026-11-03-plab-source-tabs-design.md`

## Global Constraints

- Work on `master`, no branches or worktrees. Conventional commits with scope `galactica`.
  Never mention Claude. Never `git stash`; stage files by explicit path.
- **Nothing identifying in the repository**: no site name, host, label or search term in
  code, comments, tests, fixtures, commits or this plan. Tests use `files.example`,
  `cdn.example`, `Album index A`, `alpha`. The real URL goes only into the `plab-sources`
  sops secret (Task 10).
- From `packages/plab`: `cargo test` must pass. `cargo clippy --all-targets -- -D warnings`
  may show only the pre-existing `collapsible_if` errors in `src/identify/matching.rs`.
- From `packages/plab/ui`: `npm run check` and `npm test` must pass. Run node through
  `nix shell --inputs-from ~/Code/nixos nixpkgs#nodejs -c …` if `npm` is not on PATH.
- The golden pages (`tests/fixtures/golden_page*.html`) stay byte-identical.
- Section ids: `video` (label "Tracker"), `indexers`, `albums`, `games`. `video` keeps its
  id so stored listings and URLs keep working.
- Filter prefixes: `@` = Prowlarr, `%` = album index, combinable in either order.
- `plab-sources` keys added: `album_index_url`, `album_index_label` (default `albums`),
  `album_search_mode` (default `strict`).
- Album search request: `GET <album_index_url>?search=<term>&mode=<mode>&per=40&sort=latest`.
- Window: 32 days (`curated::WINDOW_DAYS`) from an album's `first_seen`. Album
  `external_release` rows are never pruned.
- An album topic: `forum` 0, size/seeders/leechers/completed 0, `added = first_seen`,
  no production class, images = the stored ones or the index thumbnail.
- `POST /api/add/<album>` and `POST /api/stream/<album>` answer `400`.

---

## File Structure

| File | Change |
|---|---|
| `src/filters.rs` | `Term.albums`; `%` prefix parsing |
| `src/sources.rs` | three album keys, `album_label()`, `album_mode()`; `load` keeps a file that has only an album index |
| `src/db/schema_v6.sql` (new) | `kind`, `files`, `first_seen` on `external_release` |
| `src/db/mod.rs` | `Kind`; `Section::{Indexers, Albums}`, `Section::parse`; `External`/`NewExternal` fields; `StoredHit`; `is_album`; prune limited to torrents |
| `src/db/import.rs` | exhaustive `Section` match |
| `src/albums.rs` (new) | `Album`, `AlbumPage`, `parse`, `AlbumIndex` client |
| `tests/fixtures/albums_search.html` (new) | placeholder search page |
| `src/main.rs` | `mod albums;` |
| `src/curated.rs` | `Elsewhere.albums`; `album_pass`; `rebuild_external`; Prowlarr pass needs categories |
| `src/plab.rs` | `refresh` keeps tracker hits only; `run_refresh` rebuilds the external lists; album guard in `external_torrent`; `add_topic` dir for new sections |
| `src/commands.rs` | build the `AlbumIndex` from sources |
| `src/api.rs` | `TopicDto.kind`, `TopicDto.files` |
| `src/web.rs` | list route for every section; 400 on add/stream of an album |
| `src/plab_tests.rs`, `src/api_tests.rs`, `src/web_tests.rs` | tests; external tests read `Section::Indexers` |
| `ui/src/lib/types.ts`, `route.ts`, `topics.svelte.ts`, `filters.svelte.ts`, `format.ts` | sections, routes, `kind`, `files`, `filesLabel` |
| `ui/src/components/Navbar.svelte`, `Card.svelte` | tabs; album card |

---

### Task 1: `%` marks an album-index term

**Files:**
- Modify: `packages/plab/src/filters.rs` (`Term`, `parse_filters`, tests near line 323 and 360)

**Interfaces:**
- Produces: `pub struct Term { pub text: String, pub elsewhere: bool, pub albums: bool }`

- [ ] **Step 1: Write the failing test** — in `filters.rs`'s `mod tests`:

```rust
    #[test]
    fn percent_marks_an_album_index_term_and_combines_with_at() {
        let f = parse_filters("[G]\n%alpha\n@%beta\n% @gamma\ndelta\n%\n");
        let terms: Vec<(&str, bool, bool)> = f[0]
            .1
            .iter()
            .map(|t| (t.text.as_str(), t.elsewhere, t.albums))
            .collect();
        assert_eq!(
            terms,
            vec![
                ("alpha", false, true),
                ("beta", true, true),
                ("gamma", true, true),
                ("delta", false, false),
            ]
        );
    }
```

- [ ] **Step 2: Run it** — `cd packages/plab && cargo test percent_marks 2>&1 | tail -5`.
Expected: compile error, `Term` has no field `albums`.

- [ ] **Step 3: Implement.** Replace the `Term` struct and the `let term = match …` block:

```rust
/// A filter's search term. `elsewhere`: written `@term`, it is searched through Prowlarr's
/// other indexers as well as on the tracker. `albums`: written `%term`, it is also searched
/// on the album index. The prefixes combine, in either order.
#[derive(Debug, Clone, PartialEq)]
pub struct Term {
    pub text: String,
    pub elsewhere: bool,
    pub albums: bool,
}
```

```rust
        let (mut rest, mut elsewhere, mut albums) = (line, false, false);
        loop {
            if let Some(r) = rest.strip_prefix('@') {
                elsewhere = true;
                rest = r.trim_start();
            } else if let Some(r) = rest.strip_prefix('%') {
                albums = true;
                rest = r.trim_start();
            } else {
                break;
            }
        }
        let term = Term {
            text: rest.trim().to_string(),
            elsewhere,
            albums,
        };
```

Add `albums: false` to the two `Term { … }` literals in the existing tests. Extend the
`load_filters` doc sentence: "…here the `@` is stripped" → "…here `@` and `%` are stripped".

- [ ] **Step 4: Run** — `cargo test filters 2>&1 | grep -E "test result|FAILED"`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/filters.rs
git commit -m "feat(galactica): plab filter terms marked % are for the album index"
```

---

### Task 2: album keys in `plab-sources`

**Files:**
- Modify: `packages/plab/src/sources.rs`
- Modify: `packages/plab/src/curated.rs` (`external_pass` guard)
- Modify: `packages/plab/src/plab_tests.rs` (`fn sources()`)

**Interfaces:**
- Produces: `Sources.album_index_url: Option<String>`, `Sources.album_index_label: Option<String>`,
  `Sources.album_search_mode: Option<String>`; `Sources::album_label(&self) -> &str`,
  `Sources::album_mode(&self) -> &str`.

- [ ] **Step 1: Write the failing tests** — in `sources.rs` tests, replace
`every_key_parses`'s input and expected value, and add one test:

```rust
    #[test]
    fn every_key_parses() {
        let s = parse(
            "# comment\nprimary_indexer = Primary\ncategories = 100, 200,x\n\
             scene_url = http://scenes.example/scenes\nnoise = NoiseA, two Words\n\
             album_index_url = http://index.example/\nalbum_index_label = Album index A\n\
             album_search_mode = broad\nbogus = 1\n",
        );
        assert_eq!(
            s,
            Sources {
                primary_indexer: Some("Primary".into()),
                categories: vec![100, 200],
                scene_url: Some("http://scenes.example/scenes".into()),
                noise: vec!["noisea".into(), "two".into(), "words".into()],
                album_index_url: Some("http://index.example/".into()),
                album_index_label: Some("Album index A".into()),
                album_search_mode: Some("broad".into()),
            }
        );
        assert_eq!((s.album_label(), s.album_mode()), ("Album index A", "broad"));
        let d = Sources::default();
        assert_eq!((d.album_label(), d.album_mode()), ("albums", "strict"));
    }

    #[test]
    fn an_album_index_alone_keeps_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("s.txt");
        std::fs::write(&p, "album_index_url = http://index.example/\n").unwrap();
        let s = load(Some(&p)).unwrap();
        assert!(s.categories.is_empty());
        assert_eq!(s.album_index_url.as_deref(), Some("http://index.example/"));
    }
```

- [ ] **Step 2: Run** — `cargo test sources 2>&1 | tail -5`. Expected: compile errors (unknown fields).

- [ ] **Step 3: Implement** in `sources.rs`:
  - Add to `Sources`:

```rust
    /// The album index's search page (e.g. `https://host/`); None: `%` terms go nowhere else.
    pub album_index_url: Option<String>,
    /// The album index's badge and `external_release.indexer`.
    pub album_index_label: Option<String>,
    /// The index's `mode` search parameter.
    pub album_search_mode: Option<String>,
```

  - Add three `match` arms in `parse`:

```rust
            "album_index_url" => s.album_index_url = value_opt,
            "album_index_label" => s.album_index_label = value_opt,
            "album_search_mode" => s.album_search_mode = value_opt,
```

  - Add:

```rust
impl Sources {
    pub fn album_label(&self) -> &str {
        self.album_index_label.as_deref().unwrap_or("albums")
    }

    /// `strict`: every word of the term must appear.
    pub fn album_mode(&self) -> &str {
        self.album_search_mode.as_deref().unwrap_or("strict")
    }
}
```

  - In `load`, replace the final `categories` check:

```rust
    let s = parse(&text);
    if s.categories.is_empty() && s.album_index_url.is_none() {
        tracing::warn!("plab-sources names no categories and no album index: curated searches the tracker only");
        return None;
    }
    Some(s)
```

  - Update the module doc's first line to "Settings for the curated job's other sources".
  - The existing test `no_file_or_no_categories_disables_the_external_pass` keeps passing
    unchanged (its file has neither key).

- [ ] **Step 4: Guard the Prowlarr pass.** In `curated.rs::external_pass`, right after the
early return for "no `@` term", add:

```rust
    if e.sources.categories.is_empty() {
        info!("plab-sources names no categories: other indexers are not searched");
        return Ok((vec![], vec![]));
    }
```

- [ ] **Step 5: Fix the test helper.** In `plab_tests.rs`, `fn sources()` ends with
`noise: vec![],` → add `..Default::default()` after it.

- [ ] **Step 6: Run** — `cargo test 2>&1 | grep -E "test result|FAILED|panicked"`. Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add packages/plab/src/sources.rs packages/plab/src/curated.rs packages/plab/src/plab_tests.rs
git commit -m "feat(galactica): plab-sources can name an album index"
```

---

### Task 3: schema v6, `Kind`, the new sections

**Files:**
- Create: `packages/plab/src/db/schema_v6.sql`
- Modify: `packages/plab/src/db/mod.rs`, `packages/plab/src/db/import.rs`,
  `packages/plab/src/plab.rs`, `packages/plab/src/curated.rs`, and every test file that
  builds `External { … }` or `NewExternal { … }` or destructures `curated_hits()`.

**Interfaces:**
- Produces:
  - `pub enum Kind { Torrent, Album }` with `as_str()`; `Kind: Copy + Eq + Hash + Debug`.
  - `pub struct External { id, indexer, link, info_url, scene_id, pub kind: Kind, pub files: Option<u32>, pub first_seen: i64 }`
  - `pub struct NewExternal<'a> { indexer, guid, link, info_url, pub kind: Kind, pub files: Option<u32>, pub seen: i64 }`
  - `pub struct StoredHit { pub topic: Topic, pub filter: String, pub reason: String, pub kind: Option<Kind> }` (`kind` None = tracker topic); `Db::curated_hits(&self) -> Result<Vec<StoredHit>>`
  - `Section::{Video, Games, Indexers, Albums}`, `Section::ALL` (4), `Section::parse(&str) -> Option<Section>`
  - `Db::is_album(&self, id: u64) -> Result<bool>`

- [ ] **Step 1: Write the failing tests** — in `db/mod.rs`, in the test module that defines
`NOW`, `topic(id, title)` and `new_ext(guid, link)` (near line 1787; update `new_ext` to
the new struct in Step 4):

```rust
    #[test]
    fn album_rows_keep_their_first_sight_and_are_never_pruned() {
        let db = Db::open_in_memory().unwrap();
        let album = |seen| NewExternal {
            indexer: "Album index A",
            guid: "AbC123",
            link: "https://files.example/a/AbC123",
            info_url: Some("https://files.example/a/AbC123"),
            kind: Kind::Album,
            files: Some(3),
            seen,
        };
        let id = db.upsert_external(&album(NOW)).unwrap();
        assert_eq!(db.upsert_external(&album(NOW + 99)).unwrap(), id);
        let e = db.external(id).unwrap().unwrap();
        assert_eq!((e.kind, e.files, e.first_seen), (Kind::Album, Some(3), NOW));
        assert!(db.is_album(id).unwrap());
        // No topic and no hit: a torrent row would be pruned here, an album row is kept.
        db.save_curated(&[], &[], NOW).unwrap();
        assert!(db.external(id).unwrap().is_some());
    }

    #[test]
    fn curated_hits_carry_the_release_kind() {
        let db = Db::open_in_memory().unwrap();
        let torrent = db.upsert_external(&new_ext("g1", "http://p/1")).unwrap();
        let hit = |id: u64| CuratedHit {
            topic_id: id,
            filter: "A".into(),
            reason: "Alpha".into(),
        };
        db.save_curated(
            &[topic(5, "five"), topic(torrent, "ext")],
            &[hit(5), hit(torrent)],
            NOW,
        )
        .unwrap();
        let kinds: Vec<_> = db
            .curated_hits()
            .unwrap()
            .into_iter()
            .map(|h| (h.topic.row.id, h.kind))
            .collect();
        assert_eq!(kinds, vec![(5, None), (torrent, Some(Kind::Torrent))]);
        assert!(!db.is_album(torrent).unwrap());
        assert!(!db.is_album(5).unwrap());
    }

    #[test]
    fn sections_parse_by_id() {
        assert_eq!(Section::parse("albums"), Some(Section::Albums));
        assert_eq!(Section::parse("indexers"), Some(Section::Indexers));
        assert_eq!(Section::parse("video"), Some(Section::Video));
        assert_eq!(Section::parse("nope"), None);
    }
```


- [ ] **Step 2: Run** — `cargo test db:: 2>&1 | tail -5`. Expected: compile errors.

- [ ] **Step 3: Implement.**

  `src/db/schema_v6.sql`:

```sql
-- What an external release is: 'torrent' (a Prowlarr result) or 'album' (an album index
-- entry, which plab only links to). files: an album's file count. first_seen: unix time
-- plab first saw the release; an album's age is measured from it, since the index shows
-- no dates. Album rows are never pruned, so an album that ages out is not re-seen as new.
ALTER TABLE external_release ADD COLUMN kind TEXT NOT NULL DEFAULT 'torrent';
ALTER TABLE external_release ADD COLUMN files INTEGER;
ALTER TABLE external_release ADD COLUMN first_seen INTEGER NOT NULL DEFAULT 0;
```

  In `db/mod.rs`:
  - `const SCHEMA_V6: &str = include_str!("schema_v6.sql");`, `USER_VERSION = 6`, and in
    `migrate` after the v5 step: `if from < 6 { tx.execute_batch(SCHEMA_V6)?; }`.
  - Add after `is_external`:

```rust
/// What an external release is. Only torrents can be streamed or added.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Kind {
    Torrent,
    Album,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Torrent => "torrent",
            Kind::Album => "album",
        }
    }

    fn from_db(s: &str) -> Kind {
        if s == "album" { Kind::Album } else { Kind::Torrent }
    }
}
```

  - `External` gains `pub kind: Kind, pub files: Option<u32>, pub first_seen: i64`;
    `NewExternal` gains `pub kind: Kind, pub files: Option<u32>, pub seen: i64` (doc:
    "`seen`: now; stored as `first_seen` on insert only").
  - `upsert_external` SQL becomes:

```rust
                "INSERT INTO external_release (id, indexer, guid, link, info_url, kind, files, first_seen)
                 VALUES (NULL, ?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT(indexer, guid) DO UPDATE SET
                   link = excluded.link, info_url = excluded.info_url, files = excluded.files
                 RETURNING id",
                params![e.indexer, e.guid, e.link, e.info_url, e.kind.as_str(), e.files, e.seen],
```

  - `externals_where`: select `id, indexer, link, info_url, scene_id, kind, files, first_seen`
    and map `kind: Kind::from_db(&r.get::<_, String>(5)?), files: r.get(6)?, first_seen: r.get(7)?`.
  - Add:

```rust
    /// Whether `id` is an album index entry: linked to, never streamed or added.
    pub fn is_album(&self, id: u64) -> Result<bool> {
        Ok(is_external(id) && self.external(id)?.is_some_and(|e| e.kind == Kind::Album))
    }
```

  - In `save_curated`, the prune becomes
    `"DELETE FROM external_release WHERE kind = 'torrent' AND id NOT IN (SELECT id FROM topic)"`
    and its comment gains: "Album rows are kept: see schema_v6.sql."
  - Add `StoredHit` next to `CuratedHit`:

```rust
/// A stored curated hit with its topic. `kind`: None for a tracker topic.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredHit {
    pub topic: Topic,
    pub filter: String,
    pub reason: String,
    pub kind: Option<Kind>,
}
```

  and `curated_hits` becomes:

```rust
    /// Every curated hit with its topic and release kind, in the order the last run stored them.
    pub fn curated_hits(&self) -> Result<Vec<StoredHit>> {
        self.with(|c| {
            let sql = format!(
                "SELECT {TOPIC_COLS}, h.filter, h.reason, e.kind FROM curated_hit h
                 JOIN topic t ON t.id = h.topic_id
                 LEFT JOIN external_release e ON e.id = h.topic_id
                 ORDER BY h.rowid"
            );
            let mut stmt = c.prepare(&sql)?;
            let raw = stmt
                .query_map([], |r| {
                    Ok((
                        raw_topic(r)?,
                        r.get::<_, String>(10)?,
                        r.get::<_, String>(11)?,
                        r.get::<_, Option<String>>(12)?,
                    ))
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            raw.into_iter()
                .map(|(t, filter, reason, kind)| {
                    Ok(StoredHit {
                        topic: topic_of(t)?,
                        filter,
                        reason,
                        kind: kind.as_deref().map(Kind::from_db),
                    })
                })
                .collect()
        })
    }
```

  - `Section` gains `Indexers` and `Albums`; `ALL` lists all four (Video, Games, Indexers,
    Albums); `as_str` returns `"indexers"`/`"albums"`; add:

```rust
    pub fn parse(s: &str) -> Option<Section> {
        Section::ALL.into_iter().find(|x| x.as_str() == s)
    }
```

- [ ] **Step 4: Fix every exhaustive match and constructor** the compiler now reports:
  - `db/import.rs` (~line 127): add `Section::Indexers | Section::Albums => {}`.
  - `plab.rs::refresh`: make the first `match section` end with
    `Section::Indexers | Section::Albums => bail!("the {} list is rebuilt from curated hits, not refreshed", section.as_str()),`
    and change the later `Section::Games => vec![]` arms to `_ => vec![]`. The hits loop
    becomes `for h in hits { let (topic, filter, reason) = (h.topic, h.filter, h.reason); … }`
    (Task 7 adds the kind filter; keep behaviour the same here).
  - `plab.rs::add_topic`: `Section::Video | Section::Indexers => Some(ctx.download_dir), Section::Games => ctx.games_dir, Section::Albums => None,`
  - `curated.rs` torrent pass: `NewExternal { …, kind: Kind::Torrent, files: None, seen: now }`
    and import `Kind` from `crate::db`.
  - `db/mod.rs` tests: `new_ext` gains `kind: Kind::Torrent, files: None, seen: NOW`; the
    existing `curated_hits` test destructures `(t, f, _)` → use `h.topic.row.id, h.filter.as_str()`
    and `hits[0].topic.images`.
  - `api_tests.rs` and any other `External { … }` literal: add
    `kind: crate::db::Kind::Torrent, files: None, first_seen: 0`.
  Find them all with `cargo test --no-run 2>&1 | grep -E "^error|-->"`.

- [ ] **Step 5: Run** — `cargo test 2>&1 | grep -E "test result|FAILED|panicked"`. Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add packages/plab/src/db packages/plab/src/plab.rs packages/plab/src/curated.rs packages/plab/src/api_tests.rs packages/plab/src/plab_tests.rs packages/plab/src/web_tests.rs
git commit -m "feat(galactica): plab records each external release's kind and first sight"
```

  (Stage only the files `git status` shows modified among these.)

---

### Task 4: parse the album index's search page

**Files:**
- Create: `packages/plab/src/albums.rs`
- Create: `packages/plab/tests/fixtures/albums_search.html`
- Modify: `packages/plab/src/main.rs` (`mod albums;` beside the other `mod` lines)

**Interfaces:**
- Produces:
  - `pub struct Album { pub id: String, pub href: String, pub name: String, pub files: u32, pub thumb: Option<String> }`
  - `pub struct AlbumPage { pub albums: Vec<Album>, pub pages: Option<u32> }` with `pub fn looks_broken(&self) -> bool`
  - `pub fn parse(html: &str) -> AlbumPage`

- [ ] **Step 1: Create the fixture** `tests/fixtures/albums_search.html`. It mirrors the
real page's structure with placeholder names and hosts only:

```html
<!doctype html>
<html><head><title>Index</title></head><body>
<nav><a href="/">Search</a> <a href="/topalbums">Albums</a> <a href="https://fonts.example/css">x</a></nav>
<div class="hdr"><div>
  results for <span class="q">"alpha"</span>
  <span></span>
  page <span class="text-[var(--text)]">1</span> of <span class="text-[var(--text)]">3</span>
  <span></span>
  mode <span class="m">strict</span>
</div></div>
<section class="grid" style="grid-template-columns: repeat(auto-fill, minmax(220px, 1fr))">
  <a href="https://files.example/a/AbC123" target="_blank" class="card">
    <div class="thumb">
      <img src="/img/host.svg" alt="" style="position:absolute;inset:0">
      <img src="https://cdn.example/thumbs/one.png" alt="Alpha One" onerror="this.remove()">
      <div class="meta"><div class="pill"><span class="v"><svg width="12" height="12"><circle cx="12" cy="12" r="3"/></svg>12</span></div></div>
    </div>
    <div class="body">
      <h3 class="title">Alpha One &amp; Two</h3>
      <div class="row">View album <span class="n">3 files</span> <span>→ Open</span></div>
    </div>
  </a>
  <a href="https://files.example/a/Def_456" target="_blank" class="card">
    <div class="thumb"><img src="/img/host.svg" alt=""></div>
    <div class="body">
      <h3 class="title">Alpha Solo</h3>
      <div class="row">View album <span class="n">1 file</span> <span>→ Open</span></div>
    </div>
  </a>
</section>
<a href="/?search=alpha&amp;mode=strict&amp;per=40&amp;sort=latest&amp;page=2">2</a>
</body></html>
```

- [ ] **Step 2: Write the failing tests** — `src/albums.rs` (module doc and tests first,
`parse` as `todo!()` so it compiles):

```rust
#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> String {
        let p = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/albums_search.html");
        std::fs::read_to_string(p).unwrap()
    }

    #[test]
    fn every_card_is_read() {
        let page = parse(&fixture());
        assert_eq!(page.pages, Some(3));
        assert_eq!(
            page.albums,
            vec![
                Album {
                    id: "AbC123".into(),
                    href: "https://files.example/a/AbC123".into(),
                    name: "Alpha One & Two".into(),
                    files: 3,
                    thumb: Some("https://cdn.example/thumbs/one.png".into()),
                },
                Album {
                    id: "Def_456".into(),
                    href: "https://files.example/a/Def_456".into(),
                    name: "Alpha Solo".into(),
                    files: 1,
                    thumb: None,
                },
            ]
        );
        assert!(!page.looks_broken());
    }

    #[test]
    fn an_empty_result_is_not_a_broken_page() {
        let html = fixture()
            .replace(">3</span>", ">0</span>")
            .replace("<a href=\"https://files.example/a/", "<a data-x href=\"https://files.example/a/");
        let page = parse(&html);
        assert!(page.albums.is_empty());
        assert!(!page.looks_broken());
    }

    #[test]
    fn results_reported_but_none_read_is_a_broken_page() {
        // The card markup changed: the header still says 3 pages.
        let html = fixture()
            .replace("<a href=\"https://files.example/a/", "<a data-x href=\"https://files.example/a/");
        assert!(parse(&html).looks_broken());
        // No header at all is broken too.
        assert!(parse("<html><body>nothing</body></html>").looks_broken());
    }
}
```

- [ ] **Step 3: Run** — `cargo test albums 2>&1 | tail -5`. Expected: FAIL (panics at `todo!()`).

- [ ] **Step 4: Implement** the top of `src/albums.rs`:

```rust
//! The album index: a site that lists albums kept on a direct-HTTP file host. The curated
//! job scrapes its search page for terms marked `%`; plab never streams, downloads or
//! resolves anything on the file host, whose album page the card links to. The index's
//! address and label come from `plab-sources`, never from this repository.

use std::sync::LazyLock;

use regex::Regex;

/// One result card.
#[derive(Debug, Clone, PartialEq)]
pub struct Album {
    /// The file host's album id: the last segment of `href`.
    pub id: String,
    pub href: String,
    pub name: String,
    pub files: u32,
    /// The card's thumbnail on the file host's CDN, if it has one.
    pub thumb: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct AlbumPage {
    pub albums: Vec<Album>,
    /// The page count from the `page 1 of N` header; None when there is no header.
    pub pages: Option<u32>,
}

impl AlbumPage {
    /// No cards read, although the page does not say it is empty: its layout changed.
    pub fn looks_broken(&self) -> bool {
        self.albums.is_empty() && self.pages != Some(0)
    }
}

fn re(p: &str) -> Regex {
    Regex::new(p).unwrap()
}

static CARD: LazyLock<Regex> =
    LazyLock::new(|| re(r#"(?s)<a href="(https?://[^"/]+/a/([A-Za-z0-9_-]+))"[^>]*>(.*?)</a>"#));
static THUMB: LazyLock<Regex> = LazyLock::new(|| re(r#"<img src="(https?://[^"]+)""#));
static NAME: LazyLock<Regex> = LazyLock::new(|| re(r"(?s)<h3[^>]*>(.*?)</h3>"));
static FILES: LazyLock<Regex> = LazyLock::new(|| re(r"\b(\d+) files?\b"));
static PAGES: LazyLock<Regex> =
    LazyLock::new(|| re(r"page <span[^>]*>\d+</span> of <span[^>]*>(\d+)</span>"));

pub fn parse(html: &str) -> AlbumPage {
    let albums = CARD
        .captures_iter(html)
        .filter_map(|c| {
            let body = c.get(3)?.as_str();
            let name = html_escape::decode_html_entities(NAME.captures(body)?[1].trim()).into_owned();
            if name.is_empty() {
                return None;
            }
            Some(Album {
                id: c[2].to_string(),
                href: c[1].to_string(),
                name,
                files: FILES
                    .captures(body)
                    .and_then(|f| f[1].parse().ok())
                    .unwrap_or(0),
                thumb: THUMB.captures(body).map(|t| t[1].to_string()),
            })
        })
        .collect();
    AlbumPage {
        albums,
        pages: PAGES.captures(html).and_then(|c| c[1].parse().ok()),
    }
}
```

  Add `mod albums;` in `main.rs` in alphabetical position. Until Task 6 uses it, add
  `#![allow(dead_code)]` at the top of `albums.rs` only if clippy complains, and remove it
  in Task 6.

- [ ] **Step 5: Run** — `cargo test albums 2>&1 | grep -E "test result|FAILED"`. Expected: 3 pass.

- [ ] **Step 6: Commit**

```bash
git add packages/plab/src/albums.rs packages/plab/src/main.rs packages/plab/tests/fixtures/albums_search.html
git commit -m "feat(galactica): plab reads the album index's search page"
```

---

### Task 5: the album index client

**Files:**
- Modify: `packages/plab/src/albums.rs`

**Interfaces:**
- Consumes: `parse`, `AlbumPage` (Task 4).
- Produces: `pub struct AlbumIndex`, `AlbumIndex::new(url: &str, label: &str, mode: &str) -> AlbumIndex`,
  `AlbumIndex::label(&self) -> &str`, `async fn search(&self, term: &str) -> anyhow::Result<AlbumPage>`,
  `pub const PER_PAGE: u32 = 40`.

- [ ] **Step 1: Write the failing tests** — append to `albums.rs`'s `mod tests`:

```rust
    use wiremock::matchers::{method, path, query_param};
    use wiremock::{Mock, MockServer, ResponseTemplate};

    #[tokio::test]
    async fn search_asks_for_the_latest_page_in_the_configured_mode() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .and(path("/"))
            .and(query_param("search", "alpha beta"))
            .and(query_param("mode", "strict"))
            .and(query_param("per", "40"))
            .and(query_param("sort", "latest"))
            .respond_with(ResponseTemplate::new(200).set_body_string(fixture()))
            .expect(1)
            .mount(&server)
            .await;
        let index = AlbumIndex::new(&format!("{}/", server.uri()), "Album index A", "strict");
        assert_eq!(index.label(), "Album index A");
        let page = index.search("alpha beta").await.unwrap();
        assert_eq!(page.albums.len(), 2);
    }

    #[tokio::test]
    async fn a_server_error_is_an_error() {
        let server = MockServer::start().await;
        Mock::given(method("GET"))
            .respond_with(ResponseTemplate::new(503))
            .mount(&server)
            .await;
        let index = AlbumIndex::new(&format!("{}/", server.uri()), "Album index A", "strict");
        assert!(index.search("alpha").await.is_err());
    }
```

- [ ] **Step 2: Run** — `cargo test albums 2>&1 | tail -5`. Expected: compile error (`AlbumIndex` unknown).

- [ ] **Step 3: Implement** — add to `albums.rs` (after `parse`):

```rust
/// Results asked for per search.
pub const PER_PAGE: u32 = 40;

/// The index's search page, fetched directly from galactica: a few dozen HTML pages a
/// day and no media, so not through PIA.
pub struct AlbumIndex {
    http: reqwest::Client,
    url: String,
    label: String,
    mode: String,
}

impl AlbumIndex {
    pub fn new(url: &str, label: &str, mode: &str) -> AlbumIndex {
        AlbumIndex {
            http: reqwest::Client::builder()
                .user_agent("Mozilla/5.0")
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .expect("reqwest client"),
            url: url.to_string(),
            label: label.to_string(),
            mode: mode.to_string(),
        }
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    /// The newest `PER_PAGE` albums matching `term`.
    pub async fn search(&self, term: &str) -> anyhow::Result<AlbumPage> {
        let per = PER_PAGE.to_string();
        let url = url::Url::parse_with_params(
            &self.url,
            [("search", term), ("mode", &self.mode), ("per", &per), ("sort", "latest")],
        )?;
        let html = self.http.get(url).send().await?.error_for_status()?.text().await?;
        Ok(parse(&html))
    }
}
```

- [ ] **Step 4: Run** — `cargo test albums 2>&1 | grep -E "test result|FAILED"`. Expected: 5 pass.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/albums.rs
git commit -m "feat(galactica): plab album index client"
```

---

### Task 6: the curated job searches the album index

**Files:**
- Modify: `packages/plab/src/curated.rs` (`Elsewhere`, `run_curated`, new `album_pass`)
- Modify: `packages/plab/src/commands.rs` (~line 124-139)
- Modify: `packages/plab/src/plab_tests.rs` (existing `Elsewhere { … }` literals; new tests)

**Interfaces:**
- Consumes: `Term.albums` (Task 1), `Sources::album_label/album_mode` (Task 2),
  `NewExternal`/`Kind`/`External.first_seen` (Task 3), `AlbumIndex` (Task 5).
- Produces: `pub struct Elsewhere<'a> { pub sources: &'a Sources, pub scenes: Option<&'a SceneDb>, pub albums: Option<&'a AlbumIndex> }`

- [ ] **Step 1: Write the failing tests** — in `plab_tests.rs`, after the other curated
tests (add `use crate::albums::AlbumIndex;` and `use crate::db::Kind;` to its imports if
absent):

```rust
/// An album index answering every search with the placeholder fixture page.
async fn album_index() -> MockServer {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/"))
        .respond_with(ResponseTemplate::new(200).set_body_string(fixture("albums_search.html")))
        .mount(&server)
        .await;
    server
}

impl Env {
    async fn curated_albums(&self, lab: &FakeTracker, index: &AlbumIndex, now: i64) {
        let s = Sources::default();
        run_curated::<_, _, FakeClassify>(
            &self.ctx(lab),
            None,
            Some(Elsewhere {
                sources: &s,
                scenes: None,
                albums: Some(index),
            }),
            now,
        )
        .await
        .unwrap();
    }

    fn album_hits(&self) -> Vec<(String, i64, Option<Vec<String>>)> {
        self.db
            .curated_hits()
            .unwrap()
            .into_iter()
            .filter(|h| h.kind == Some(Kind::Album))
            .map(|h| (h.topic.row.title, h.topic.row.added, h.topic.images))
            .collect()
    }
}

#[tokio::test]
async fn curated_searches_only_percent_terms_on_the_album_index() {
    let server = album_index().await;
    let index = AlbumIndex::new(&format!("{}/", server.uri()), "Album index A", "strict");
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n%Alpha\nBeta\n"));
    let lab = FakeTracker::new(vec![row(1)]);
    env.curated_albums(&lab, &index, NOW).await;
    let asked: Vec<String> = server
        .received_requests()
        .await
        .unwrap()
        .iter()
        .filter_map(|r| r.url.query_pairs().find(|(k, _)| k == "search").map(|(_, v)| v.into_owned()))
        .collect();
    assert_eq!(asked, vec!["Alpha".to_string()]);
    let hits = env.album_hits();
    assert_eq!(hits.len(), 2);
    assert_eq!(hits[0].0, "Alpha One & Two");
    assert_eq!(hits[0].1, NOW);
    assert_eq!(hits[0].2, Some(vec!["https://cdn.example/thumbs/one.png".to_string()]));
    // Both are still searched on the tracker as before.
    assert_eq!(lab.calls().searches.len(), 2);
}

#[tokio::test]
async fn an_album_keeps_its_first_sight_and_ages_out_for_good() {
    let server = album_index().await;
    let index = AlbumIndex::new(&format!("{}/", server.uri()), "Album index A", "strict");
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n%Alpha\n"));
    let lab = FakeTracker::new(vec![row(1)]);
    env.curated_albums(&lab, &index, NOW).await;
    env.curated_albums(&lab, &index, NOW + 10 * 86400).await;
    assert!(env.album_hits().iter().all(|h| h.1 == NOW));
    // 33 days after first sight: out of the window, although the page still lists them.
    env.curated_albums(&lab, &index, NOW + 33 * 86400).await;
    assert!(env.album_hits().is_empty());
    // And not re-seen as new once their topics are gone.
    env.curated_albums(&lab, &index, NOW + 34 * 86400).await;
    assert!(env.album_hits().is_empty());
}

#[tokio::test]
async fn percent_terms_without_an_album_index_still_store_the_tracker_hits() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\n%Alpha\n"));
    let mut lab = FakeTracker::new(vec![row(1)]);
    lab.searched.insert("Alpha".into(), vec![titled(5, "Alpha five")]);
    env.curated(&lab).await.unwrap();
    let ids: Vec<u64> = env.db.curated_hits().unwrap().iter().map(|h| h.topic.row.id).collect();
    assert_eq!(ids, vec![5]);
}
```

  Also add `albums: None,` to every existing `Elsewhere { … }` literal in `plab_tests.rs`.

- [ ] **Step 2: Run** — `cargo test curated 2>&1 | tail -5`. Expected: compile error (`Elsewhere` has no field `albums`).

- [ ] **Step 3: Implement** in `curated.rs`:
  - Imports: `use crate::albums::AlbumIndex;`, add `Kind` to the `crate::db` import, add
    `excluded` is already imported.
  - Module doc: append "Terms marked `%` are also searched on the album index, whose
    albums are linked to, never classified or looked up."
  - `Elsewhere` gains `pub albums: Option<&'a AlbumIndex>,` (doc: "None: `%` terms are
    searched nowhere else").
  - In `run_curated`, replace `if let Some(e) = elsewhere {` with
    `if let Some(e) = elsewhere.as_ref() {` and pass `e` (not `&e`) to `external_pass`.
    After that block, before `ctx.db.save_curated`:

```rust
    if filters.iter().any(|(_, t)| t.iter().any(|t| t.albums)) {
        match elsewhere.as_ref().and_then(|e| e.albums) {
            Some(index) => match album_pass(ctx, index, &filters, &excludes, now).await {
                Ok((t, h)) => {
                    topics.extend(t);
                    hits.extend(
                        h.into_iter()
                            .filter(|h| seen.insert((h.topic_id, h.filter.clone()))),
                    );
                }
                Err(err) => warn!("album index skipped: {err:#}"),
            },
            None => warn!("filter terms are marked % but plab-sources names no album_index_url"),
        }
    }
```

  - Add:

```rust
/// Every `%` term searched on the album index. An album's age is from plab's first sight
/// of it (the index shows no dates); one first seen more than `WINDOW_DAYS` ago is not a
/// hit. No classification and no scene lookup: album names are free text.
async fn album_pass<T: TrackerApi, C: TorrentClient>(
    ctx: &Ctx<'_, T, C>,
    index: &AlbumIndex,
    filters: &FilterTerms,
    excludes: &[fancy_regex::Regex],
    now: i64,
) -> anyhow::Result<(Vec<Topic>, Vec<CuratedHit>)> {
    let cutoff = now - i64::from(WINDOW_DAYS) * 86400;
    let mut topics = vec![];
    let mut hits = vec![];
    let mut kept: HashSet<u64> = HashSet::new();
    for (name, terms) in filters {
        for term in terms.iter().filter(|t| t.albums) {
            tokio::time::sleep(ctx.delay).await;
            let page = match index.search(&term.text).await {
                Ok(p) => p,
                Err(err) => {
                    warn!("album index: search failed for {:?}: {err:#}", term.text);
                    continue;
                }
            };
            if page.looks_broken() {
                warn!(
                    "album index: no album read for {:?} although the page is not empty; has its layout changed?",
                    term.text
                );
            }
            for a in page.albums {
                if excluded(excludes, &a.name) {
                    continue;
                }
                let id = ctx.db.upsert_external(&NewExternal {
                    indexer: index.label(),
                    guid: &a.id,
                    link: &a.href,
                    info_url: Some(&a.href),
                    kind: Kind::Album,
                    files: Some(a.files),
                    seen: now,
                })?;
                let first_seen = ctx.db.external(id)?.map_or(now, |e| e.first_seen);
                if first_seen < cutoff {
                    continue;
                }
                hits.push(CuratedHit {
                    topic_id: id,
                    filter: name.clone(),
                    reason: term_label(&term.text),
                });
                if !kept.insert(id) {
                    continue;
                }
                let stored = ctx.db.topic(id)?.and_then(|t| t.images).filter(|v| !v.is_empty());
                topics.push(Topic {
                    row: Row {
                        id,
                        title: a.name,
                        forum: 0,
                        size: 0,
                        seeders: 0,
                        leechers: 0,
                        completed: 0,
                        added: first_seen,
                    },
                    images: stored.or_else(|| a.thumb.map(|u| vec![u])),
                    production: None,
                });
            }
        }
    }
    Ok((topics, hits))
}
```

  In `commands.rs`, after `let scenes = …;`:

```rust
    let albums = sources.as_ref().and_then(|s| {
        s.album_index_url
            .as_deref()
            .map(|u| crate::albums::AlbumIndex::new(u, s.album_label(), s.album_mode()))
    });
```

  and add `albums: albums.as_ref(),` to the `curated::Elsewhere { … }` literal. Remove any
  `#![allow(dead_code)]` added in Task 4.

- [ ] **Step 4: Run** — `cargo test 2>&1 | grep -E "test result|FAILED|panicked"`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/curated.rs packages/plab/src/commands.rs packages/plab/src/plab_tests.rs packages/plab/src/albums.rs
git commit -m "feat(galactica): plab curated searches the album index for % terms"
```

---

### Task 7: one list per source

**Files:**
- Modify: `packages/plab/src/curated.rs` (new `rebuild_external`; `run_curated` calls it)
- Modify: `packages/plab/src/plab.rs` (`refresh` keeps tracker hits only; `run_refresh` calls `rebuild_external`)
- Modify: `packages/plab/src/plab_tests.rs`

**Interfaces:**
- Consumes: `StoredHit`, `Kind`, `Section::{Indexers, Albums}` (Task 3).
- Produces: `pub async fn rebuild_external<T: TrackerApi, C: TorrentClient>(ctx: &Ctx<'_, T, C>, now: i64) -> anyhow::Result<()>`

- [ ] **Step 1: Write the failing test** — in `plab_tests.rs`:

```rust
#[tokio::test]
async fn each_source_kind_gets_its_own_list() {
    let mut env = Env::new();
    env.filter_file = Some(env.write("f.txt", "[Group A]\nAlpha\n[Group B]\nBeta\n[Group C]\nGamma\n"));
    let ext = |guid: &str, kind| crate::db::NewExternal {
        indexer: "Indexer A",
        guid,
        link: "http://p/1",
        info_url: Some("http://a/1"),
        kind,
        files: None,
        seen: NOW,
    };
    let torrent = env.db.upsert_external(&ext("g1", Kind::Torrent)).unwrap();
    let album = env.db.upsert_external(&ext("a1", Kind::Album)).unwrap();
    let hit = |id: u64, f: &str| crate::db::CuratedHit {
        topic_id: id,
        filter: f.into(),
        reason: "Alpha".into(),
    };
    let t = |id: u64, title: &str| Topic {
        row: titled(id, title),
        images: None,
        production: None,
    };
    env.db
        .save_curated(
            &[t(9, "Alpha nine"), t(torrent, "Beta ext"), t(album, "Gamma album")],
            &[hit(9, "Group A"), hit(torrent, "Group B"), hit(album, "Group C")],
            NOW,
        )
        .unwrap();
    let lab = FakeTracker::new(vec![row(1)]);
    env.refresh(&lab).await.unwrap();
    crate::curated::rebuild_external(&env.ctx(&lab), NOW).await.unwrap();
    let ids = |s| -> Vec<u64> {
        env.db.listing(s).unwrap().topics.iter().map(|l| l.topic.row.id).collect()
    };
    let video = ids(Section::Video);
    assert!(video.contains(&9) && !video.contains(&torrent) && !video.contains(&album));
    assert_eq!(ids(Section::Indexers), vec![torrent]);
    assert_eq!(ids(Section::Albums), vec![album]);
    // A list names only the filters it holds hits of.
    assert_eq!(env.db.listing(Section::Indexers).unwrap().filters, vec!["Group B".to_string()]);
    assert_eq!(env.db.listing(Section::Albums).unwrap().filters, vec!["Group C".to_string()]);
    // No tracker page is fetched for an external release.
    assert!(!lab.calls().topics.contains(&torrent) && !lab.calls().topics.contains(&album));
}
```

- [ ] **Step 2: Run** — `cargo test each_source_kind 2>&1 | tail -5`. Expected: compile error (`rebuild_external` unknown).

- [ ] **Step 3: Implement.**
  In `plab.rs::refresh`, the `hits` binding becomes:

```rust
    // The curated job's stored hits on the tracker (video only); other sources have
    // their own lists (`curated::rebuild_external`).
    let hits: Vec<crate::db::StoredHit> = match section {
        Section::Video => ctx
            .db
            .curated_hits()?
            .into_iter()
            .filter(|h| h.kind.is_none())
            .collect(),
        _ => vec![],
    };
```

  In `curated.rs`, add (imports: `Listed` from `crate::db`, `load_filters` is not needed —
  use `load_filter_terms`; `ensure_image` is already imported):

```rust
/// The Indexers and Albums lists, rebuilt from the stored curated hits. No tracker request:
/// their releases carry only the images the curated job gave them. A filter is named on a
/// list only when the list holds one of its hits.
pub async fn rebuild_external<T: TrackerApi, C: TorrentClient>(
    ctx: &Ctx<'_, T, C>,
    now: i64,
) -> anyhow::Result<()> {
    let order: Vec<String> = load_filter_terms(ctx.filter_file, Some(ctx.state_dir))
        .into_iter()
        .map(|(name, _)| name)
        .collect();
    let rank = |f: &String| order.iter().position(|n| n == f).unwrap_or(usize::MAX);
    let hits = ctx.db.curated_hits()?;
    for (section, kind) in [(Section::Indexers, Kind::Torrent), (Section::Albums, Kind::Album)] {
        let mut listed: Vec<Listed> = vec![];
        let mut at: HashMap<u64, usize> = HashMap::new();
        for h in hits.iter().filter(|h| h.kind == Some(kind)) {
            match at.get(&h.topic.row.id) {
                Some(&i) => {
                    if !listed[i].filters.contains(&h.filter) {
                        listed[i].filters.push(h.filter.clone());
                    }
                }
                None => {
                    at.insert(h.topic.row.id, listed.len());
                    listed.push(Listed {
                        topic: h.topic.clone(),
                        filters: vec![h.filter.clone()],
                        curated_reason: Some(h.reason.clone()),
                    });
                }
            }
        }
        for l in &mut listed {
            l.filters.sort_by_key(rank);
            if let Some(first) = l.topic.images.as_ref().and_then(|v| v.first())
                && let Err(e) = ensure_image(ctx.tracker, ctx.images, first).await
            {
                warn!("image {first}: {e:#}");
            }
        }
        let names: Vec<String> = order
            .iter()
            .filter(|n| listed.iter().any(|l| l.filters.contains(n)))
            .cloned()
            .collect();
        ctx.db.save_listing(section, &listed, &names, now)?;
        crate::events::publish(crate::events::Event::Listing {
            section: section.as_str(),
        });
        info!("rebuilt {}: {} releases", section.as_str(), listed.len());
    }
    Ok(())
}
```

  In `run_curated`, the tail becomes:

```rust
    ctx.db.save_curated(&topics, &hits, now)?;
    info!("curated: {} hits", hits.len());
    rebuild_external(ctx, now).await?;
    refresh(ctx, Section::Video, classify, now).await
```

  and the module doc's last sentence: "The hits replace `curated_hit`; then the Indexers
  and Albums lists and the Tracker list are rebuilt so they show at once."

  In `plab.rs::run_refresh`, right after the `match drained { … }` block:

```rust
    // Cheap (no tracker request), and fills the source lists on the first start after a
    // deploy, before the next curated run.
    if let Err(e) = crate::curated::rebuild_external(ctx, now).await {
        warn!("rebuilding the source lists failed: {e:#}");
    }
```

- [ ] **Step 4: Run all tests** — `cargo test 2>&1 | grep -E "test result|FAILED|panicked"`.
  Expected: the new test passes; the existing external tests from
  `curated_lists_classified_releases_from_other_indexers` through
  `curated_sets_scene_images_on_an_accepted_hit_only` fail where they look for an external
  release in `env.db.listing(Section::Video)`. In each of them, change that call to
  `env.db.listing(Section::Indexers)` **only where it is looking up an external release**;
  assertions about tracker topics keep `Section::Video`. Re-run until all pass.

- [ ] **Step 5: Clippy** — `cargo clippy --all-targets -- -D warnings 2>&1 | grep -E "^error" | sort | uniq -c`. Expected: only the pre-existing `collapsible_if` errors.

- [ ] **Step 6: Commit**

```bash
git add packages/plab/src/curated.rs packages/plab/src/plab.rs packages/plab/src/plab_tests.rs
git commit -m "feat(galactica): plab lists tracker, indexer and album hits separately"
```

---

### Task 8: API kind and files; albums are never added or streamed

**Files:**
- Modify: `packages/plab/src/api.rs` (`TopicDto`, `topic`)
- Modify: `packages/plab/src/web.rs` (`api_get` list route, `post`, `stream_page`)
- Modify: `packages/plab/src/plab.rs` (`external_torrent` guard)
- Test: `packages/plab/src/api_tests.rs`, `packages/plab/src/web_tests.rs`

**Interfaces:**
- Consumes: `Kind`, `External.files`, `Db::is_album`, `Section::parse` (Task 3).
- Produces: JSON topic fields `kind: "tracker" | "torrent" | "album"` and `files: number | null`;
  `GET /api/list?section=indexers|albums`.

- [ ] **Step 1: Write the failing tests.**
  In `api_tests.rs` (beside `an_external_card_carries_its_indexer_and_page`):

```rust
#[test]
fn a_card_says_what_kind_of_release_it_is() {
    let id = crate::db::EXTERNAL_BASE;
    let ext = |kind, files| {
        let mut m = std::collections::HashMap::new();
        m.insert(
            id,
            crate::db::External {
                id,
                indexer: "Album index A".into(),
                link: "https://files.example/a/AbC123".into(),
                info_url: Some("https://files.example/a/AbC123".into()),
                scene_id: None,
                kind,
                files,
                first_seen: 0,
            },
        );
        m
    };
    let album = list_with_externals(id, &ext(crate::db::Kind::Album, Some(3)));
    assert_eq!((album.topics[0].kind, album.topics[0].files), ("album", Some(3)));
    let torrent = list_with_externals(id, &ext(crate::db::Kind::Torrent, None));
    assert_eq!(torrent.topics[0].kind, "torrent");
    let tracker = list_with_externals(5, &ext(crate::db::Kind::Album, Some(3)));
    assert_eq!((tracker.topics[0].kind, tracker.topics[0].files), ("tracker", None));
}
```

  In `web_tests.rs`:

```rust
#[tokio::test]
async fn an_album_is_never_added_or_streamed() {
    let fx = Fx::new();
    let id = fx
        .state
        .db
        .upsert_external(&crate::db::NewExternal {
            indexer: "Album index A",
            guid: "AbC123",
            link: "https://files.example/a/AbC123",
            info_url: Some("https://files.example/a/AbC123"),
            kind: crate::db::Kind::Album,
            files: Some(3),
            seen: 0,
        })
        .unwrap();
    assert_eq!(fx.post(&format!("/api/add/{id}")).await.status, 400);
    assert_eq!(fx.post(&format!("/api/stream/{id}")).await.status, 400);
}

#[tokio::test]
async fn every_section_has_a_list() {
    let fx = Fx::new();
    for s in ["video", "games", "indexers", "albums"] {
        let r = fx.get(&format!("/api/list?section={s}")).await;
        assert_eq!(r.status, 200, "{s}");
        assert_eq!(r.json()["section"], s);
    }
    assert_eq!(fx.get("/api/list?section=nope").await.status, 400);
}
```

  If `/api/stream/<id>` is not the POST path `stream_route` recognizes, use the path the
  existing stream tests in `web_tests.rs` POST to.

- [ ] **Step 2: Run** — `cargo test kind_of_release album_is_never every_section 2>&1 | tail -8`
  (run them one name at a time if cargo rejects several filters). Expected: compile error / failures.

- [ ] **Step 3: Implement.**
  `api.rs` — `TopicDto` gains, after `link`:

```rust
    /// "tracker", or the external release's kind: "torrent" or "album".
    pub kind: &'static str,
    /// An album's file count.
    pub files: Option<u32>,
```

  and in `topic()`:

```rust
        kind: match ext.map(|e| e.kind) {
            None => "tracker",
            Some(crate::db::Kind::Torrent) => "torrent",
            Some(crate::db::Kind::Album) => "album",
        },
        files: ext.and_then(|e| e.files),
```

  `web.rs` — the `"list"` arm of `api_get`:

```rust
        "list" => {
            return match param(query, "section").as_deref() {
                None => list(st, Section::Video).await,
                Some(s) => match Section::parse(s) {
                    Some(section) => list(st, section).await,
                    None => text(400, "unknown section"),
                },
            };
        }
```

  `web.rs::post`, right after the `let Some((action, id)) = … else { … };`:

```rust
    if action == "add" && st.db.is_album(id).unwrap_or(false) {
        return json_reply(400, json!({"ok": false, "error": "an album is opened on its site, not added"}));
    }
```

  `web.rs::stream_page`, as its first statement:

```rust
    let topic = match &route {
        StreamRoute::Topic(t) | StreamRoute::Select(t, _) => Some(*t),
        StreamRoute::File(..) => None,
    };
    if method == Method::POST
        && let Some(t) = topic
        && st.db.is_album(t).unwrap_or(false)
    {
        return json_reply(400, json!({"ok": false, "error": "an album is watched on its site, not streamed"}));
    }
```

  `plab.rs::external_torrent`, after `let ext = …?;`:

```rust
    if ext.kind == crate::db::Kind::Album {
        bail!("release {id} is an album, not a torrent");
    }
```

- [ ] **Step 4: Run** — `cargo test 2>&1 | grep -E "test result|FAILED|panicked"`. Expected: all pass.
  Golden-page tests, if any compare API JSON, gain `"kind"`/`"files"` keys: update only the
  inline expected JSON in Rust tests, never `tests/fixtures/golden_page*.html`.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/src/api.rs packages/plab/src/web.rs packages/plab/src/plab.rs packages/plab/src/api_tests.rs packages/plab/src/web_tests.rs
git commit -m "feat(galactica): plab serves the source lists and refuses to add or stream an album"
```

---

### Task 9: the app — tabs and the album card

**Files:**
- Modify: `packages/plab/ui/src/lib/types.ts`, `lib/route.ts`, `lib/route.test.ts`,
  `lib/topics.svelte.ts`, `lib/filters.svelte.ts`, `lib/format.ts`, `lib/format.test.ts`
- Modify: `packages/plab/ui/src/components/Navbar.svelte`, `components/Card.svelte`

**Interfaces:**
- Consumes: JSON `kind`, `files`; `GET /api/list?section=indexers|albums` (Task 8).
- Produces: `Section = 'video' | 'indexers' | 'albums' | 'games'`; `filesLabel(n: number): string`.

- [ ] **Step 1: Write the failing tests.**
  `lib/route.test.ts`, inside the existing `it`:

```ts
  expect(parse('/indexers', '')).toEqual({ view: 'indexers' });
  expect(parse('/albums', '')).toEqual({ view: 'albums' });
```

  `lib/format.test.ts`:

```ts
import { filesLabel } from './format';

it('counts an album\'s files', () => {
  expect(filesLabel(1)).toBe('1 file');
  expect(filesLabel(3)).toBe('3 files');
  expect(filesLabel(0)).toBe('0 files');
});
```

  (Merge the import into the file's existing `import … from './format'` line, and `it`
  into its vitest import if absent.)

- [ ] **Step 2: Run** — `cd packages/plab/ui && npm test 2>&1 | tail -8`. Expected: FAIL.

- [ ] **Step 3: Implement.**
  - `types.ts`: `export type Section = 'video' | 'indexers' | 'albums' | 'games';` and in
    `Topic`, after `link`:

```ts
  /** 'tracker', or an external release's kind; an album is only linked to. */
  kind: 'tracker' | 'torrent' | 'album';
  /** An album's file count. */
  files: number | null;
```

  - `route.ts`: `export type Route = { view: Section } | { view: 'search'; q: string } | { view: 'jobs' };`
    (import `type Section` from `./types`), and add cases:

```ts
    case '/indexers':
      return { view: 'indexers' };
    case '/albums':
      return { view: 'albums' };
```

  - `format.ts`:

```ts
export const filesLabel = (n: number) => `${n} ${n === 1 ? 'file' : 'files'}`;
```

  - `topics.svelte.ts`: the seen key becomes
    `const seenKey = 'plab.seen' + (key === 'video' ? '' : '.' + key);` (games keeps
    `plab.seen.games`), and `resync` loops over
    `['video', 'indexers', 'albums', 'games'] as const`.
  - `filters.svelte.ts`: add
    `indexers: new FilterState('plab.filters.indexers'),` and
    `albums: new FilterState('plab.filters.albums'),`.
  - `Navbar.svelte` tabs:

```ts
  const tabs = [
    ['video', '/', 'Tracker'],
    ['indexers', '/indexers', 'Indexers'],
    ['albums', '/albums', 'Albums'],
    ['games', '/games', 'Games'],
    ['jobs', '/jobs', 'Jobs'],
  ] as const;
```

  - `Card.svelte`: import `filesLabel`; add `const album = $derived(topic.kind === 'album');`.
    Replace the meta line `<div class="text-xs text-base-content/60">…</div>` with:

```svelte
    <div class="text-xs text-base-content/60">
      {#if album}
        {filesLabel(topic.files ?? 0)} · first seen {day(topic.added)}
      {:else}
        {size(topic.size)} · ▲ {topic.seeders} ▼ {topic.leechers} ·
        {#if fresh}<span class="text-warning font-bold">uploaded {age(topic.added, now)}</span>{:else}{day(topic.added)}{/if}
      {/if}
    </div>
```

    and the actions block with:

```svelte
    <div class="card-actions mt-auto items-center">
      {#if album}
        {#if topic.link}
          <a class="btn btn-sm btn-primary" href={topic.link} target="_blank" rel="noreferrer">Open ↗</a>
        {/if}
      {:else}
        <AddButton {topic} {section} />
        {#if stream}
          <button type="button" class="btn btn-sm btn-ghost" onclick={() => onstream(topic.id)}>Stream ▶</button>
        {/if}
        {#if topic.status}<StatusBadge status={topic.status} />{/if}
      {/if}
    </div>
```

    Hide the freshness badge for albums: `{#if fresh && !album}` on the `freshShort` badge.

- [ ] **Step 4: Run** — `npm run check 2>&1 | tail -5 && npm test 2>&1 | tail -5`. Expected:
  0 errors, 0 warnings; all tests pass. Fix any `svelte-check` exhaustiveness errors that
  the widened `Section` type exposes (e.g. a `Record<Section, …>` literal missing keys) by
  adding the two new keys.

- [ ] **Step 5: Commit**

```bash
git add packages/plab/ui/src
git commit -m "feat(galactica): plab app has Tracker, Indexers and Albums tabs"
```

---

### Task 10: the secret, build, deploy and check

**Files:**
- Modify: `secrets/sops/galactica.yaml` (through `sops set`, never by hand)

- [ ] **Step 1: Add the album index to `plab-sources`.** The URL is the one the user gave
  in conversation; it is typed into the shell only, never into a file in the repository.

```bash
cd ~/Code/nixos
nix develop -c sops --decrypt --extract '["plab-sources"]' secrets/sops/galactica.yaml > "$SCRATCH/plab-sources.txt"
printf 'album_index_url = %s\n' "$ALBUM_INDEX_URL" >> "$SCRATCH/plab-sources.txt"
nix develop -c sops set secrets/sops/galactica.yaml '["plab-sources"]' "$(jq -Rs . < "$SCRATCH/plab-sources.txt")"
rm "$SCRATCH/plab-sources.txt"
nix develop -c sops --decrypt --extract '["plab-sources"]' secrets/sops/galactica.yaml | grep -c '^album_index_url'
```

  `$SCRATCH` is the session scratchpad directory. Expected: `1`.

- [ ] **Step 2: Mark terms with `%`.** Ask the user with AskUserQuestion which filter
  groups' terms should also be searched on the album index, naming the groups only in the
  question, never in a file. Then:

```bash
nix develop -c sops --decrypt --extract '["plab-filter"]' secrets/sops/galactica.yaml > "$SCRATCH/plab-filter.txt"
# prefix the chosen terms with % (keep any @)
nix develop -c sops set secrets/sops/galactica.yaml '["plab-filter"]' "$(jq -Rs . < "$SCRATCH/plab-filter.txt")"
rm "$SCRATCH/plab-filter.txt"
```

- [ ] **Step 3: Build galactica** — `just fmt && nix build .#nixosConfigurations.galactica.config.system.build.toplevel --no-link 2>&1 | tail -5`.
  Expected: success (the package's checkPhase runs `cargo test`, `npm run check`, `npm test`).

- [ ] **Step 4: Commit and push**

```bash
git add secrets/sops/galactica.yaml
git commit -m "feat(galactica): plab searches the album index"
git push -u origin master
```

- [ ] **Step 5: Deploy and run once** — `just deploy galactica`, then run the curated job
  by hand the way the external-sources plan's Task 12 did (the service's environment plus
  `plab curated`), and check its log for `album index` warnings and the
  `rebuilt albums: N releases` line. Open `https://plab.arsfeld.one/albums` and
  `/indexers` and confirm cards show; an album card's Open opens the album page.
