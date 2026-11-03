# plab: one Rust daemon for plab, stash-identify and vault-grab

Date: 2026-11-01
Status: approved design, phase 1

## Goal

Replace three Python tools on galactica with one Rust binary, `plab`, running as one
daemon:

| Today | Lines (prod / tests) | Shape |
|---|---|---|
| `plab` (`modules/hosts/galactica/services/plab/`) | ~1,800 / ~2,100 | page on :8577 + `refresh` (3h timer), `prune` (hourly timer), `set-cookie` |
| `stash-identify` (`.../stash-identify/`) | ~1,150 / ~1,250 | long-running inotify watcher driving Stash |
| `vault-grab` (`.../vault-grab/`) | ~250 / ~300 | 3h timer; borrows plab's `transmission.py` via `PYTHONPATH` |

Motivation: integration (the tracker knows what a release is; stash-identify starts from a
bare filename), consolidation (one binary, one set of clients, one state store instead of
three Python trees sharing code through `PYTHONPATH`), and Rust itself.

The work is split in two:

- **Phase 1 (this spec):** a feature-for-feature port onto a single daemon and a single
  SQLite database. No user-visible change, with the few internal changes listed below.
- **Phase 2 (sketched at the end, own specs):** provenance-driven identification, Stash
  status on the page, tracker images as scene covers.

## Decisions

- **Name:** `plab`. Binary, unit, state directory and the `plab.arsfeld.one` page keep the
  name; the other tools become `plab identify` and `plab grab`.
- **Runtime:** one daemon (`plab.service`) with internal tokio tasks, not one unit per job.
  Separate processes are why plab has a cookie-file mtime reload, possible concurrent
  logins, and temp-file-plus-rename writes everywhere; one process with one tracker client
  and one database removes all three, and phase 2 is about sharing state.
- **State:** one SQLite database, imported once from the three JSON stores.
- **Phasing:** port first at parity, integrate afterwards.

## 1. Architecture

`plab serve` is the daemon. `plab.service` runs it as `media`/`media` with
`StateDirectory=plab`, `UMask=0077`, `Restart=always`, and `Wants=`/`After=` on
`network-online.target`, `transmission.service`, `podman-stash.service` (via
`config.virtualisation.oci-containers.backend`) and `mnt-storage.mount`. `Wants=` on
transmission keeps what `plab-prune`'s `requires` gave after the 2026-10-31 activation
panic: a start of plab starts Transmission if it is down.

A supervisor in `main.rs` builds one shared `App` and spawns long-lived tasks over it:

```rust
struct App { db: Db, tracker: Tracker, transmission: Transmission, stash: Stash,
             llm: Llm, codedb: CodeDb, prowlarr: Prowlarr, config: Config }
```

| Task | Replaces | Schedule |
|---|---|---|
| `web` | `plab serve` | always |
| `identify` | `stash-identify watch` | inotify + 120 s debounce, plus a 24 h sweep |
| `refresh` | `plab-refresh.timer` | every 3 h |
| `prune` | `plab-prune.timer` | hourly |
| `grab` | `vault-grab.timer` | every 3 h, 30 min after refresh's slot |

**Scheduling** (`jobs.rs`): each periodic task loops on `job_run`: read `last_started`,
sleep until due, run, record `last_finished`/`ok`/`error`. A job overdue at daemon start
runs immediately, which is what `Persistent=true` and `OnBootSec` gave. The identify sweep
is a job like the others. An `Err` is logged with the job's name and waits for the next
slot. A panicking task is restarted by the supervisor after a backoff (30 s, doubling to
10 min) and never takes the other tasks down.

**Logging:** `tracing` to stderr (the journal), every line carrying `job=<name>`, so
`journalctl -u plab | grep job=prune` stands in for the per-unit journals.

**CLI** (`clap`): `serve [--bind] [--port] [--tasks web,identify,refresh,prune,grab]`
(default: all tasks; the parity check runs `--tasks web` so a test daemon never prunes or
grabs for real), and one-shot `refresh`, `prune [--dry-run]`,
`grab [--dry-run]`, `identify [--dry-run] [--limit N] [--scene ID…] [--no-jobs] [paths…]`
and `set-cookie <value>`. One-shot commands open the same database and call the same
function the task calls; WAL plus `busy_timeout` makes them safe beside the running
daemon.

**Configuration:** environment variables, as today. `default.nix` sets the existing
`PLAB_*` set (username/password/exclude/filter/OpenRouter key files, state dir,
Transmission URL in the PIA namespace, Vault and Games download dirs, static dir) plus
the variables stash-identify and vault-grab read today, renamed under `PLAB_*`
(`PLAB_GRAB_RULES_FILE`, `PLAB_PROWLARR_URL`, `PLAB_PROWLARR_CONFIG`, Stash URL and the
Vault library host/container paths). Secrets are read from their sops file paths at
startup. `Config` fails startup naming the missing variable.

**Crate layout** (`packages/plab/`, loaded as `pkgs.plab` by `packagesFromDirectoryRecursive`):

| Group | Modules | From |
|---|---|---|
| Clients | `tracker/` (session, parse, forums), `transmission.rs`, `stash/` (GraphQL, stash-box search through Stash), `codedb.rs`, `prowlarr.rs`, `llm.rs` | `lab.py`, `parse.py`, `forums.py`, `transmission.py`, `stash.py`, `codedb.py`, vault-grab's client code, `llm.py` + `classify.py`'s HTTP |
| Domain | `refresh.rs`, `prune.rs`, `grab.rs`, `identify/` (match, code, fc2, apply, watch), `classify.rs`, `labels.rs`, `filters.rs` | the rest of the Python |
| Infrastructure | `web/` (axum), `page.rs`, `db.rs`, `jobs.rs`, `config.rs`, `main.rs` | `main.py`, `page.py`, `store.py`, `assets.py` |

Crates: axum, reqwest (rustls; redirects followed by hand so every Set-Cookie on the way
is kept), rusqlite (bundled), regex and fancy-regex (the tracker's markup is parsed with
regexes, as `parse.py` does; fancy-regex for user-supplied patterns and lookaround),
encoding_rs (cp1251), serde / serde_json, clap, notify, tokio, tracing, thiserror, anyhow,
chrono, sha1; wiremock for tests.

OpenRouter is one client (`llm.rs`) serving the filename parse, Jev scene choice and FC2
title translation for identify, and the Jev production classifier for refresh. Today the
same key is read by two separate code paths.

## 2. State

`/var/lib/plab/state.db`: WAL mode, `busy_timeout`, schema versioned by
`PRAGMA user_version` with SQL migrations embedded in the binary. 0600 via `UMask`; it
holds the tracker session. The image cache stays as files, `img/<sha1 of url>`.

| Table | Holds | Replaces |
|---|---|---|
| `topic` | tracker topic: id, title, forum, size, seeders, leechers, completed, posted time, images (JSON, null until fetched), label/classification, `seen_at` | rows in `cache.json`, `games.json`, `search.json` |
| `listing` | `(section, position, topic_id)`, rewritten in one transaction per refresh | the list files |
| `listing_meta` | per section: `updated`, `filters` (JSON) | the lists' header fields |
| `search_hit` | `(topic_id, at)`; older than 24 h is ignored, then deleted | `search.json` |
| `download` | id, `source` (`plab`/`grab`), `topic_id` (nullable), `release_title`, `section`, `download_dir`, `state` (`queued`/`added`), `torrent_hash` (nullable), `queued_at`, `added_at` | `added.json`, `queued.json`, `games-queued.json` |
| `grab_seen` | `(studio, scene_key)` → `title`, `at`, `download_id` (nullable) | vault-grab `state.json` |
| `identify_attempt` | `scene_id` → `failures`, `done` | `attempted.json`, `failures.json` |
| `job_run` | job → `last_started`, `last_finished`, `ok`, `error` | nothing (daemon scheduling) |
| `kv` | `tracker_cookies` and other singletons | `cookies.txt` |

The `download` table is the one step past strict parity: it records the hash Transmission
returns on add, which the Python receives and discards. Phase 2 then needs a join, not a
migration. No phase-2 behaviour is built in phase 1.

**One-time import**, inside migration 1's transaction on first start:

1. Read each legacy file that exists: `/var/lib/plab/{cache,games,search,added,queued,games-queued}.json`
   and `cookies.txt`, `/var/lib/stash-identify/{attempted,failures}.json`,
   `/var/lib/vault-grab/state.json`. All are owned by `media`.
2. `added.json` ids become `download` rows, state `added`, no hash, `source = 'plab'`;
   each section's queue becomes `queued` rows in that section; vault-grab keys become
   `grab_seen` rows; attempted ids become `identify_attempt` rows with `done = 1`, and
   `failures.json` counts become `failures`.
3. A missing file is skipped. A corrupt one aborts the migration and the daemon exits
   with an error naming the file. A silent empty import would re-download everything
   already added, so it must never happen quietly.
4. The legacy files are never modified or deleted by the binary.

`set-cookie` writes `kv.tracker_cookies`; the tracker client reads the session from the
database, so "no restart needed" holds without a file-mtime check.

## 3. Web and tracker

Routes, URLs and responses are unchanged:

| Route | Serves |
|---|---|
| `GET /`, `GET /games` | video and games lists |
| `GET /search?q=` | live search |
| `GET /thumb/<id>`, `GET /images/<id>` | a topic's images, fetched lazily |
| `GET /static/<name>` | daisyUI, Tailwind, Alpine from the Nix `linkFarm` (`PLAB_STATIC_DIR`) |
| `GET /img/<sha1>` | cached image bytes, content type sniffed |
| `POST /add/<id>`, `POST /unqueue/<id>` | add to Transmission / remove from the queue |

`page.py` is ported function for function (`format!`, not a template engine): it is a set
of small composing functions the tests assert on directly. With an `html.escape` twin and
a `json.dumps` twin (`", "`/`": "` separators, `ensure_ascii`), the Rust page is
byte-identical to the Python one for the same state, which makes the parity check a diff.
`assets.py`'s CSS and JS move verbatim to `assets/page.css` and `assets/page.js`, included
with `include_str!`. The static asset `linkFarm` stays in `default.nix`.

**Tracker client** (`tracker/`): one instance shared by the page and refresh. Kept from
`lab.py`: the browser user agent, the 5-minute backoff after a failed login, captcha and
daily-limit detection with the page's existing button text, 1 s between topic fetches, at
most 2 concurrent topic-page fetches for search thumbnails. Changed: a
`tokio::sync::Mutex` around login, so callers that find the session expired wait for one
login instead of each attempting their own, now also across refresh and the page, which
used to be separate processes. Request pacing is otherwise unchanged (1 s between
refresh's topic fetches; thumbnails are not paced), so search thumbnails load as fast as
today.

**Refresh, classifier, filters:** unchanged. 7-day video window, 32-day games window, 100
topics per list; exclude and filter files from sops; Jev production ranking through
OpenRouter's decisions API with `typesafe/jev-1.13`, the classify failure limit of 3, and
seeders-only ranking without a key. After a refresh: drain the queues, delete images no
listing, search hit or queued download references.

**Prune and grab:** straight ports of `prune.py` (tracker torrents kept until they stop
earning ratio, the rest removed on completion, files always kept; Vault and Games dirs)
and vault-grab's `main.py` (Prowlarr search per rule, one 1080p copy per new scene, added
under `Vault/<Studio>`; Prowlarr's API key read from its `config.xml` at run time). Both
write `download` rows, `source = 'plab'` and `'grab'`.

## 4. Identify

A port of stash-identify with the same behaviour, tag (`llm-identified`) and thresholds.

**Watcher:** `notify`'s inotify backend, recursive over `/mnt/storage/media/Vault`, on
`close_write` and `moved_to`, replacing the `inotifywait` subprocess. `changed_dir` maps
an event to the folder to scan (directories as-is, video files by Stash's extension
list). The debouncer runs a pass after 120 s without events.

**A pass:**

1. Stash's own scan → generate → identify for the new scenes, with the defaults saved in
   the Stash UI. A library sweep generates library-wide. Failures here are logged and the
   LLM step still runs.
2. LLM step over bare scenes not `done` in `identify_attempt`, plus `llm-identified`
   scenes eligible for a product-code upgrade.
3. Per scene: product code first (StashDB, then the code database's product-code API; FC2-PPV through the FC2
   article via Stash, title translated); otherwise LLM filename parse → search the code database
   then StashDB, 6 hits each → duration filter → deterministic date match, else Jev's
   pick → stash ids gathered from the chosen scene's twins on both boxes.
4. Re-fetch the scene before writing; skip it if it was edited by hand or deleted
   meanwhile (an explicit `--scene` run applies regardless of edits).
5. Errors: a typed `Transient` variant (network failure, stash-box search failure, Jev
   failure) is retried next pass without counting; any other error increments
   `identify_attempt.failures`, and the third gives the scene up (`done = 1`).

**Changed:** the sweep is a `job_run` job, so it runs at daemon start only when 24 h have
passed since the last one. Today every restart, so every deploy, triggers a full library
sweep.

**Failure containment:** a failed pass (Stash down, say) is logged and the watcher
continues. A failure of the watch itself (inotify limit, the library unmounted) ends the
task with an error; the supervisor restarts it with backoff and the page keeps serving.

## 5. Testing and cutover

**Tests:** the Python suites become `#[test]`s beside the code, organized by behaviour, not
transliterated. `plab/fixtures/` moves to `packages/plab/tests/fixtures/`. HTTP clients
are tested against `wiremock` on localhost, which works in the Nix build sandbox.
`buildRustPackage` runs `cargo test` in its check phase, so a failing test fails the
galactica build in CI and in `just deploy`. `Cargo.lock` is committed and consumed via
`cargoLock.lockFile`.

**Parity check, before the switch,** on galactica with the Python still running:

1. **Commit 1** adds `packages/plab` and installs it on galactica as `plab-rs` in
   `environment.systemPackages` (a one-line `runCommand` symlinking `bin/plab` to
   `bin/plab-rs`, so it cannot shadow the Python `plab`). No units.
2. Copy `/var/lib/{plab,stash-identify,vault-grab}` to a scratch directory, point
   `PLAB_STATE_DIR` and the legacy-import paths at the copies, and compare:
   - **import:** row counts match the JSON (topics per list, added ids, queued ids,
     vault-grab keys, attempted scene ids);
   - **`prune --dry-run`** lists the same torrents as `plab prune --dry-run`;
   - **`grab --dry-run`** lists the same releases as `vault-grab run --dry-run`;
   - **`identify --dry-run --no-jobs --scene <ids>`** on about 20 scenes: proposal lines
     match Python's in their deterministic parts (product-code lookups, date matches). LLM
     replies are not reproducible run to run, so differences there are not failures;
   - **`serve` on a spare port:** `/`, `/games` and a search compared side by side, and
     one real add of a throwaway topic.
3. **Commit 2 (cutover):** `plab/default.nix` becomes the single daemon unit (secrets,
   `media.services.plab` with `host = "127.0.0.1"` unchanged, static `linkFarm`, env);
   `plab/*.py`, `plab/fixtures/`, `stash-identify/` and `vault-grab/` are deleted with
   their units and timers; the `plab-rs` alias goes. `just deploy galactica`. The first
   start imports the real legacy files.

**Rollback:** revert commit 2 and redeploy. The Python resumes from its untouched JSON.
Anything added through the Rust page in the meantime is missing from Python's
`added.json`; that is cosmetic, because Transmission rejects a duplicate add.

**After cutover:** in `journalctl -u plab`, each task's start line, then one completed
refresh, prune, grab and sweep, then a real file arriving in Vault and being identified.
After two clean weeks, delete `/var/lib/stash-identify`, `/var/lib/vault-grab` and plab's
legacy JSON by hand.

**Docs:** update the comments at the top of `plab/default.nix` (what the daemon does, the
captcha recovery via `sudo -u media plab set-cookie`, `plab prune --dry-run`), and the
host-local module list in `CLAUDE.md` (`stash-identify/` goes; `plab` remains).

## Out of scope

- Any phase-2 behaviour.
- A clippy flake check.
- Changing the page's look, routes or front-end stack.
- Moving any of this into k3s or `media.services` containers.

## Phase 2 (sketch; separate specs)

1. **Provenance → identify.** When a new Stash scene appears, map its file path to a
   `download` row through Transmission's file list for the stored hash, and give the
   matcher the tracker title or Prowlarr release title, plus the grab rule's studio, in
   place of the bare filename.
2. **Stash status on the page.** Added cards show queued / downloading / in Stash /
   identified (as what) / failed.
3. **Images as cover.** Use the post's cached image as the scene cover when no stash-box
   match supplies one.
