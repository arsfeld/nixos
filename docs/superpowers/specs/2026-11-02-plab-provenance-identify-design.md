# plab: identify from provenance, Stash status, tracker covers

Date: 2026-11-02. Builds on `2026-11-01-plab-rust-merge-design.md` (the daemon) and
`2026-09-27-stash-llm-identify-design.md` (the identify pass).

## Goal

Every Vault download plab knows about (a plab add from the tracker page, or a grab
through Prowlarr) carries information that the file name lost: the release title, and for
grabs the studio named by the grab rule. Three features use it:

1. **Identify from provenance.** When a new scene appears in Stash, find the download it
   came from through Transmission's file list for the stored torrent hash. Then identify it
   using the release title and the studio, not the bare file name.
2. **Stash status on the page.** Each added release shows queued, downloading,
   in Stash, identified (as what), or failed. Grabs, which have no tracker card, get a
   "Recent grabs" strip.
3. **Tracker images as covers.** A plab add's tracker post image becomes the scene cover
   when no StashDB or the code database match supplies one.

Only scenes that appear after this ships are affected. Existing scenes, including
llm-identified guesses, are not relinked or re-identified.

## Constraints found in the code

- **Prune races identify.** `prune::decide` removes non-tracker torrents (every grab) as
  soon as they finish, and prune runs hourly, while identify runs 2 min after the files
  settle. A live Transmission lookup at identify time can find the torrent already gone.
  So the file list is stored in plab's database, and prune records it before removing.
- **Only plab adds have a post.** Grabs have no `topic_id`, no card and no cached image.
  `ImageCache::prune` keeps only images of current listings and searches, so a cover must
  be copied out of the cache at add time.
- **Downloads land in the library.** `PLAB_DOWNLOAD_DIR` (`Downloads/Vault`) is a symlink
  to `Vault`, the Stash library. A torrent file's `downloadDir/name`, canonicalized, is the
  host path of the scene's file. Transmission uses `rename-partial-files`, so on disk an
  unfinished file is named `*.part` and loses the suffix the moment it completes, which is
  when the watcher runs a pass. The RPC's `files[].name` is the logical name and never
  carries `.part`; whether a file is complete is `bytesCompleted == length`.
- **Only videos are covered.** `PLAB_GAMES_DIR` (`Downloads/Games`) is outside the
  library, so a games download has no scene to link. Games are never synced and get no
  status.
- Rows imported from `added.json` have no torrent hash and can never be linked. Neither
  can Vault-category downloads plab never saw, nor downloads added before v2 (see
  "Data"). All keep today's behaviour.

## Data

Schema version 2, in a new stepwise migration: `migrate` today only knows 0→1. A v1
database runs only the v2 statements, and a fresh one runs `SCHEMA` (which includes them)
and lands on 2.

```sql
CREATE TABLE download_file (
  download_id INTEGER NOT NULL REFERENCES download(id),
  path TEXT NOT NULL,            -- library-relative, the form Paths::rel_path gives
  scene_id TEXT,                 -- set once a Stash scene with this path is seen
  outcome TEXT,                  -- 'stash' | 'scrape' | 'llm' | 'none' | 'gave-up'
  label TEXT,                    -- "Title · Studio": what it was identified as
  PRIMARY KEY (download_id, path)
);
CREATE INDEX download_file_path ON download_file(path);
CREATE INDEX download_file_scene ON download_file(scene_id);
-- 0: files pending, 1: files recorded (the torrent finished), 2: added before provenance
ALTER TABLE download ADD COLUMN files_synced INTEGER NOT NULL DEFAULT 0;
UPDATE download SET files_synced = 2 WHERE state = 'added';
ALTER TABLE download ADD COLUMN cover TEXT;   -- absolute path of the copied cover
```

A download already added when the migration runs predates provenance: its files were
never recorded and its torrent may be long gone, so it would read "failed: lost". It is
marked 2, is never synced, and gets no status. Queued rows have not started, so they stay 0.

Re-adding a topic with a different torrent hash deletes the old torrent's `download_file`
rows and resets `files_synced` to 0, so the new torrent is synced afresh.

The migration is additive. Rollback is a revert, because old code ignores the new table
and columns.

## Components

### `provenance.rs` (new)

- `sync(db, torrents, paths, only: Option<&[hash]>)` handles every `state='added'`
  video download that has a `torrent_hash` and `files_synced = 0` (or exactly those in
  `only`). It does this:
  1. Calls `TorrentClient::details(hashes)` once, returning `Detail`. This is a new method
     doing `torrent-get` by hash with `hashString, files, downloadDir, percentDone, error,
     errorString, activityDate`; each of `files` carries `name`, `length` and
     `bytesCompleted`.
  2. Takes the torrent's complete files, `bytesCompleted == length` and `length > 0`,
     whatever the torrent's progress: with a multi-file torrent, identify runs on each file
     as it completes, before the torrent is done.
  3. Builds each file's path as `canonicalize(downloadDir)/name` and stores it relative to
     the library root (`Paths.host`). Every file is stored, with no extension filter: a
     non-video path never matches a scene. A path outside the library is skipped with a
     warning.
  4. Inserts the rows (`INSERT OR IGNORE`, so a later pass adds the rest) and, once
     `percentDone` reaches 1, sets `files_synced = 1`, in one transaction. A torrent under
     100% stays unsynced.
- `link(db, scene) -> Option<Provenance>` looks up `rel_path(scene.files[0].path)` in
  `download_file`, sets `scene_id`, and returns:

  ```rust
  pub struct Provenance {
      pub download_id: i64,
      pub title: String,          // download.release_title
      pub studio: Option<String>, // grab: grab_seen.studio for the row; plab: labels(title).studio
      pub forced: bool,           // true for source = 'grab'
      pub cover: Option<PathBuf>, // download.cover, an absolute path
  }
  ```
- `record(db, scene_id, outcome, label)` writes the outcome.
- `status(download, files, live: Option<&Detail>, now) -> Status` is a pure
  function (see "Status").

### Identify (`identify/mod.rs`)

- `run_pass` calls `provenance::sync` first. `identify::Clients` gains a
  `T: TorrentClient` parameter and a `torrents: Option<&T>` field for it. A failure is logged and the pass continues.
- After `stash_jobs`, each new scene id is linked. A linked scene that is no longer bare
  (Stash's own fingerprint identify filled it) is recorded `outcome='stash'`, with its
  title and studio as the label.
- `pass_scene` links the scene and passes the `Option<Provenance>` to `identify_scene`.
  A database error in the lookup counts as unlinked.
- `identify_scene(c, scene, prov)`:
  - `code_prop` runs first, unchanged (the code is in the file name).
  - When linked, the parse is `Llm::parse_with_title(path, title, studio_hint)`. The
    prompt says that the title describes the whole torrent and the file name picks out the
    scene within it. When unlinked, it stays `Llm::parse(path)`, unchanged.
  - A **forced** studio (grabs) replaces `parse.studio`, and stash-box candidates whose
    studio does not match it (case-insensitive, name or aliases) are dropped before
    `deterministic_match` or Jev. If none are left, the result is `Kind::Llm` with the
    rule's studio, never another studio's scene.
  - A **hinted** studio (plab adds) is only an LLM input. Nothing is filtered.
- `apply`: when the update sets no `cover_image` (`Kind::Llm`, `Kind::None`, or a scrape
  whose primary has no `image`) and `prov.cover` exists, the scene's `cover_image` is set
  to a `data:` URI of the file. `Kind::None` with a cover writes a cover-only update and
  nothing else. A missing cover file is skipped with an info log.
- After `apply`, the outcome and label are recorded: `scrape` or `llm` with the
  proposal's title and studio, or `none`. When `identify_fail` reaches the cap, the
  outcome is set to `gave-up`. Transient failures record nothing.

### Covers (`plab.rs`)

`add_topic` and `drain_queue`, after `mark_added`, copy the topic's first image into
`<state_dir>/covers/<download_id>` (no extension) and set `download.cover` to that absolute path. If a search result's
images were never fetched, `topic_images` runs first. Any failure is a warning: the add
has already happened. Grabs get no cover.

Covers are deleted by the refresh job 90 days after the download's `added_at`, whatever
the outcomes.

### Prune (`commands.rs` / `prune.rs`)

Before `remove(ids)`, prune calls `provenance::sync(only = hashes of those ids)` (the
`Clients` torrent client, `details` for the live data). A
video torrent whose sync fails is left in Transmission this run and retried next run.
Nothing leaves Transmission unrecorded. A games torrent is never held back. `prune::decide` is unchanged. `torrents()` gains
`hashString` in `FIELDS` so prune can pass hashes.

### Page (`page.rs`, `web.rs`)

- The page handler makes one `TorrentClient::details` call with a 2-second timeout for the
  hashes of video downloads added in the last 30 days (games, and downloads that predate
  provenance, get no status and no badge). If that fails, statuses are derived
  without live data.
- `render` takes `HashMap<u64, Status>` (by topic id) in place of the `added` set, plus
  `grabs: Vec<(Download, Status)>`.
- **Cards.** The "Added ✓" button stays, and a status badge sits beside it (the page JS
  is unchanged):

  | Status | Badge |
  |---|---|
  | queued | `warning`, still click-to-unqueue |
  | downloading | `info`, with the percentage |
  | in Stash | `neutral` |
  | identified | `success`, with the label (first file's label, plus "+N" for more files; " (guess)" for llm) |
  | failed | `error`, with the reason in the tooltip |

- **Recent grabs**, on the Videos tab only: a collapsible section above the grid with
  grab downloads from the last 14 days, newest first. Each row shows the studio, release
  title, status badge and age. No images and no filters. Hidden when empty.
- Statuses are recomputed on each page load. No polling.

## Status

`provenance::status`: the first rule that matches wins.

1. **queued**: `download.state = 'queued'`.
2. **failed: transmission**: the live torrent has a local error (`error = 3`) at any
   time, or a tracker warning or error (`error` 1 or 2) while under 100%, or it is under
   100% and `activityDate` is more than 3 days old. A finished torrent's tracker complaint
   is not a failure: the data is all here.
3. **downloading N%**: the live torrent has `percentDone < 1`.
4. **failed: identify**: any linked file has outcome `gave-up` or `none`.
5. **identified as ...**: every linked file has outcome `stash`, `scrape` or `llm`.
6. **in Stash**: at least one file has a `scene_id`.
7. **failed: lost**: unsynced and absent from a successful live lookup, or synced with no
   `scene_id` 2 days after `added_at`.
8. **added**: anything else, for example complete and waiting for the watcher, or
   Transmission unreachable.

## Errors

| Failure | Effect |
|---|---|
| Transmission down during an identify pass | sync is skipped; unlinked scenes use file-name identify |
| Transmission down during prune | nothing is removed that run |
| Transmission down during page render | statuses fall back to database-only states |
| Hash unknown to Transmission | stays unsynced; shown as lost after the window |
| Provenance lookup database error | treated as unlinked |
| Recording an outcome fails | warning; the scene is already written, so it is no identify failure |
| Cover copy or read fails | warning; the add and the identify proceed |

The identify failure cap and the transient-error rules are unchanged.

## Testing

- `provenance`:
  - a path through a symlinked download dir (tempdir and a real symlink) normalizes to
    the library-relative path
  - every complete file is stored, video or not; an incomplete one never is
  - a partly complete torrent records its finished files and stays unsynced; once done it
    is synced
  - games downloads are never pending and get no status
  - a path outside the library is skipped
  - one `status` case per rule above, including no live data
- `transmission`: `details()` request fields and reply parsing.
- `prune`: sync precedes remove; a failed sync skips those removals.
- `identify`:
  - a forced studio drops another studio's candidate
  - no candidates left gives `Llm` with the rule's studio
  - a hinted studio filters nothing
  - an unlinked scene calls `parse(path)` exactly as before
  - the tracker cover is used for `Llm`, `None` and an image-less scrape, and not for a
    scrape with an image
  - outcome and label are recorded; `gave-up` is set at the cap
  - a new scene filled by Stash is recorded `stash`
- `db`: a v1 database migrates to v2 with its data intact and its added downloads marked
  as predating provenance; a fresh one lands on v2.
- `page`: a badge for each status, and the grabs strip. The golden pages
  (`tests/fixtures/golden_page*.html`) stay byte-identical: the badge renders only for a
  download with a status, and the strip renders nothing when empty.

## Rollout

One deploy to galactica. Smoke test: after the next grab lands,
`sudo -u media plab identify --dry-run --scene <id>` shows the release title in the
parse, and the page's Recent grabs strip shows the row moving through its states.
