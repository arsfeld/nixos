# plab — a Games section

**Host:** galactica · **URL:** `https://plab.arsfeld.one/games` · **Code:** `modules/hosts/galactica/services/plab/`

Builds on `2026-10-09-plab-design.md`, which left the tracker's game forums out on purpose.

## Goal

A second, deliberately simple list beside the video one: the 100 most-seeded releases of
the tracker's game forums over the last 32 days, one click into Transmission, landing in
`/mnt/storage/media/Downloads/Games` rather than the Stash library.

32 days, not 30: the tracker's `tm` select has no 30, and 32 is the value live search
already uses. Game uploads are far rarer than video, so a 7-day window would be thin.

## What the page carries

`GET /games` renders the same card grid as `/`: images and gallery, the Add button, the
daily-limit queue, NEW badges and the "uploaded N ago" indicators. A Videos | Games tab pair
sits in the header of both pages.

Left out, on purpose: live search, curated filters, the production ranking (Jev), and the
category / studio / quality / tag selects. The games filter bar has only the toggles
(last 24 h, new, hide added) and the Showing count. Cards sort by seeders.

## Components

| File | Change |
|---|---|
| `forums.py` | `GAMES`: the 11 game forum ids (1838 1750 1756 1869 1785 1790 1827 1870 1828 1829 1865). The "left out on purpose" comment now points at it. `FORUMS` (video) is unchanged. |
| `store.py` | `games.json` (the games list, same shape as `cache.json`) and `games-queued.json` (its queue). `added.json` stays shared: topic ids are unique across the tracker. |
| `main.py` | Games refresh, per-section add/drain, `/games` route, image-prune union. Details below. |
| `page.py` | `render(..., section="video" | "games")`: tabs in the header; for games a toggles-only filter bar and no curated summary. |
| `assets.py` | The localStorage keys (`plab.seen`, `plab.filters`) gain a `.games` suffix on the games page, read from a `data-section` attribute on `<body>`, so the two pages never overwrite each other's seen state. |
| `prune.py` | `decide(torrents, now, dirs)`: a torrent qualifies if it is under any of the dirs. Same rules (ratio 2, 7 days idle); `MAX_SEEDING = 50` is one cap across both dirs. |
| `default.nix` | `PLAB_GAMES_DIR=${vars.storageDir}/media/Downloads/Games`. Transmission creates the directory on the first add. |

### Why a separate queue

A queued topic need not be on any current list, so a bare id cannot tell `drain_queue`
which directory to download into. Two queue files, each drained with its own directory,
answer that without changing `queued.json`'s format.

### Image pruning

`store.prune_images` keeps only the URLs it is given. Both refreshes must pass the union
of `cache.json`, `games.json` and recent searches, or each refresh deletes the other
list's thumbnails. `_image_urls` and `image_for`'s allowlist both include `games.json`.

## Data flow

### Refresh

`run_refresh`:

1. Drain the video queue into Vault, then the games queue into Games. Each stops at the
   first limit reply; a limit hit in the first means the second is skipped (it would only
   fetch the limit page again).
2. Video refresh, as today.
3. Games refresh: `lab.top(GAMES, 32, 100)` with the same exclude predicate, topic images
   as for video, no curated filters, no classifier; written to `games.json`.

Steps 2 and 3 each run in their own `try`: a failure in one logs and leaves the other's
list untouched, and the run exits non-zero if either failed. A `LoginError` anywhere still
aborts the whole run.

### Serve

- `GET /games` — the games page from `games.json`, exclude patterns applied as on `/`.
- `POST /add/<topic>` — `_listed` reports which list holds the topic; games go to
  `PLAB_GAMES_DIR` and queue into `games-queued.json`, everything else as today.
- `POST /unqueue/<topic>` — removes the id from both queues.
- `/thumb`, `/images`, `/img` — accept games topics and images.

## Testing

Unit tests (`python3 -m unittest -v`):

- add picks the dir and queue by section; drain uses each queue's dir
- prune_images keeps games images across a video refresh, and vice versa
- a failing games refresh leaves `cache.json` alone, and vice versa
- `prune.decide` across two dirs, with the shared seeding cap
- games page renders the tabs, `data-section="games"`, and no selects or search box

Live check after deploy: `systemctl start plab-refresh`, open `/games`, add one release,
confirm it appears in Transmission under `Downloads/Games`.

## Out of scope

Search, curated filters, ranking and label selects on the games page; other windows;
installing or unpacking games.
