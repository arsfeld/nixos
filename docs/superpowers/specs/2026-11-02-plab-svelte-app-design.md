# plab: a Svelte app over a JSON API and SSE

Date: 2026-11-02.

Supersedes `2026-10-12-plab-alpinejs-design.md`. Amends
`2026-11-02-plab-jobs-monitor-design.md`: its monitor layer, `job_history` and JSON
shape stand; its Alpine `/jobs` page and its "no SSE" exclusion do not (see `JobsView` under "Client").

## Goal

plab should feel like an app: switching between Videos, Games, Search and Jobs without a
page load, and seeing changes as they happen without reloading. That includes a card
added from another device, a queued topic being added by refresh, a download's status
moving, a job's progress (a stream's progress keeps its own poll; see "Streams are not on SSE").

## Today

`page.rs` renders the whole page as Rust `format!` strings, about 700 lines. Behaviour
comes from roughly 400 lines of Alpine in `assets/page.js`, the styling from daisyUI and
Tailwind's browser runtime. Three golden HTML fixtures pin the output. Every view is a
full page load. The only live data is the stream player's 2 s poll. Nothing else on the
page changes until you reload.

## Decisions

- **A Svelte 5 single-page app built with Vite, in TypeScript, without SvelteKit.** The
  choice was weighed against Nolan Lawson's "The AI cost of JavaScript frameworks"
  (2026-10-28). Framework quality converged across his benchmark, and cost differences
  were modest (about 2× from cheapest to dearest). SvelteKit's high cost came from
  agents re-reading the v3 migration guide, which plain Svelte 5 avoids, while Svelte
  kept a small bundle (36 KiB) and negligible blocking time. The benchmark measured
  meta-frameworks on a content site under Lighthouse, so it does not decide this case
  outright.
- **Rust keeps all domain logic and the app only renders it.** Labels, scoring,
  production class, `Status`, Stash links and the curated filters are computed
  server-side and shipped as typed JSON. The app never parses a title or ranks a card.
- **One SSE stream** carries every live update. The one browser poller left is the stream player's, which is the stream's keep-alive.
- **Parity plus the jobs monitor.** Every current view is rebuilt, the spec'd `/jobs`
  page is built in the app, and today's look (daisyUI `luxury`, current class names)
  carries over. A visual redesign is not part of this.
- **One commit.** The work lands on master as a single commit once the app is complete
  and `page.rs` is deleted. There is no period where both UIs coexist.

## Server

### Routes

`web.rs` keeps dispatch. The new handlers are in `api.rs`, the SSE stream in `events.rs`.

| Route | Replaces | Reply |
|---|---|---|
| `GET /api/list?section=video\|games` | `/`, `/games` | `List` (below) |
| `GET /api/search?q=` | `/search` | `List` with `error` |
| `GET /api/grabs` | the grabs strip | `{now, grabs: [{studio, title, addedAt, status}]}` |
| `GET /api/jobs` | `/jobs.json` | the jobs spec's shape, unchanged |
| `POST /api/add/{id}`, `POST /api/unqueue/{id}` | `add/`, `unqueue/` | today's `AddReply` |
| `GET /api/images/{id}`, `GET /api/thumb/{id}`, `GET /api/img/{key}` | same without `/api` | unchanged |
| `/api/stream/*` | `/stream/*` | unchanged (the stream router on its own port is untouched) |
| `GET /api/events` | every poller | `text/event-stream` |
| `GET /assets/<file>` | `/static/<name>` | a file from `dist/assets/`, `Cache-Control: public, max-age=31536000, immutable` |
| any other `GET` | — | `dist/index.html`, `Cache-Control: no-cache` |

An unknown `/api/*` path is a 404 and is not served `index.html`. An `/assets/` name
containing `/` or `..` is a 404. `STATIC`, `static_file` and the `/static/` arm go away.

### `List`

```json
{"now": 1793501999, "section": "video", "updated": 1793500000,
 "curatedFilters": ["couples", "…"], "pending": 2,
 "topics": [{
   "id": 123, "title": "…full title…", "name": "…release name…",
   "studio": "…"|null, "quality": "1080p"|null, "category": "…",
   "production": "amateur"|"artistic"|"industrial"|null,
   "tags": ["…"], "filters": ["couples"],
   "size": 1234567890, "seeders": 40, "leechers": 3, "added": 1793400000,
   "images": ["<40-hex key>", "…"]|null,
   "state": ""|"queued"|"added",
   "status": Status|null
 }]}
```

- `topics` are sorted by `page::score`, which moves to `api.rs`, descending and stable.
- `images: null` means a live search result whose images are fetched lazily through
  `/api/thumb/{id}`. `[]` means it has no images.
- `fresh`, the age strings and `size` formatting are derived client-side from `added`,
  `size` and `now`.
- Search replies add `query` and `error` (null on success). `curatedFilters` is the
  filter file's names in file order. `pending` is queued but not yet added.
- `production` is the display name (`pro_artistic` is shown as `artistic`), as the badge
  and the Production filter show it today.

`Status` is serialized as a tagged enum. `link` is the Stash URL, or null:

```json
{"kind": "queued"} | {"kind": "downloading", "percent": 42} | {"kind": "added"}
| {"kind": "inStash", "link": …}
| {"kind": "identified", "label": "…", "more": 2, "guess": false, "link": …}
| {"kind": "failed", "reason": "download"|"identify"|"lost", "detail": "…"}
```

The badge's colour, text and tooltip move into `StatusBadge.svelte` and keep today's
mapping (`status_badge` in `page.rs`).

### SSE (`events.rs`)

`WebState` gains `events: tokio::sync::broadcast::Sender<Event>` (capacity 256).
`GET /api/events` subscribes and writes each event as `data: <json>\n\n`, with a
`: keep-alive` comment every 15 s. A receiver that lags gets one `{"type":"resync"}` and
carries on from the newest event.

| `type` | Payload | Sent when |
|---|---|---|
| `topicState` | `{id, state}` | add or unqueue succeeds; `refresh`'s `drain_queue` adds a queued topic |
| `topicStatus` | `{id, status}` | the status diff sees a topic's `Status` change (including from none) |
| `job` | one `/api/jobs` entry | that entry changed since the last sample (sampled every 250 ms, so at most 4 per second per job, latest wins) |
| `listing` | `{section}` | `refresh` has written a new listing for that section |
| `resync` | — | the receiver lagged |

`state` and `status` travel apart so that neither event has to carry the other's value:
an add never sends a `status` that would clobber the badge, and the diff never touches
`state`.

- **The status diff and the job sampler** run in one `events::pump` task beside the web
  server. While `events.receiver_count() > 0` it recomputes `Downloads` every 10 s (the
  same Transmission and Stash reads the listing does today) and publishes a
  `topicStatus` for each topic whose status changed. It also samples the monitor every
  250 ms and publishes a `job` event for each entry that differs from the last one sent.
  With no clients, it does nothing but sleep.
- **Reaching the broadcast.** `refresh` runs inside `serve` without a `WebState`, so it
  publishes through `events::global()`, a process-wide `OnceLock` that `serve` sets to the
  same sender `WebState` holds. One-shot CLI commands never set it, so they publish
  nothing.
- **No replay.** On reconnect the client refetches its current view.
- **Streams are not on SSE.** The player keeps its 2 s poll of `GET /api/stream/{id}`.
  That poll is the stream's keep-alive: each one counts as a read for the idle reaper
  (`the_stats_poll_counts_as_a_read`). A server-side poll would keep every stream alive
  forever, and pushing progress without it would need a second keep-alive channel.

## Client (`packages/plab/ui/`)

`package.json`, `vite.config.ts`, `tsconfig.json`, `src/`. Dependencies: `svelte`,
`vite`, `@sveltejs/vite-plugin-svelte`, `tailwindcss`, `@tailwindcss/vite`, `daisyui`,
`typescript`, `svelte-check`, `vitest`. Nothing else.

### Routing

`src/lib/router.svelte.ts` is a small history router (no dependency) covering `/`,
`/games`, `/search?q=` and `/jobs`. Links are intercepted, `popstate` is handled, and an
unknown path shows the Videos view.

### Stores (`src/lib/*.svelte.ts`)

- `api.ts`: typed `fetch` wrappers and the TypeScript types for `List`, `Topic`,
  `Status`, `Job`, `Event`. They are hand-written, and the Rust serializer tests pin the
  shapes they mirror.
- `topics.svelte.ts`: one cached `List` per section (and the last search), with topics in
  a `Map<id, Topic>`. A `topicState` or `topicStatus` event patches the matching entry in whichever lists hold
  it.
- `filters.svelte.ts`: `st` = `{h24, new, hide, f, prod, cat, studio, q, tags}`, the
  `isVisible` predicate (today's, plus the curated filter `f` and `prod`), and sync to
  `location.hash` and `localStorage['plab.filters' + suffix]`. Keys and the hash format
  are kept so that saved filters survive the switch.
- `seen.svelte.ts`: the NEW logic ported unchanged (`plab.seen` + suffix, 30-minute
  window).
- `events.svelte.ts`: one `EventSource('/api/events')` opened at startup. It dispatches
  events to the stores, exposes `connected`, and on `open` after an error, or on
  `resync`, refetches the current view.
- `jobs.svelte.ts`: seeded from `/api/jobs` when `/jobs` is opened, then updated by `job`
  events.

### Components (`src/components/`)

`App`, `Navbar` (the Videos · Games · Jobs tabs, the search box, the connection dot),
`FilterBar` (toggles, selects, the tag menu with datalist and top-20 chips, the selected
tags, "Showing N of M", Clear), `Grid`, `Card`, `StatusBadge`, `AddButton`, `TagPill`,
`GrabsStrip`, `Gallery`, `Player`, `JobsView`, `JobCard`, `NewReleasesPill`.

- **Filter bar per view.** It shows exactly what each view shows today. Games has the
  toggles only. Search has no "New" toggle and no Production select.
- **`AddButton`.** Labels and states are as today ("Add to Vault"/"Add to Games",
  "Adding…", "Queued ⏳", hover shows "Remove ✕", "Added ✓", "Retry"). The state is set
  from the reply. A failure restores the previous state and shows the inline error.
- **`Player`.** Today's dialog: the file select, progress text, Copy URL for VLC and
  Stop. Progress comes from its 2 s poll of `GET /api/stream/{id}`, as today. The start step, elapsed time
  and "drop a start that finishes after close" behaviours are kept.
- **`NewReleasesPill`.** On a `listing` event for the current section, a "New releases ·
  reload" pill appears. Clicking it refetches. The grid is never reshuffled on its own.
- **`JobsView` / `JobCard`.** The jobs spec's card layout (header and state badge with a
  countdown, step and progress, last result, Log and History collapses). It runs off
  `jobs.svelte.ts` rather than a 2 s poll. The jobs spec's `visibilitychange` rule no
  longer applies.
- **Section cache.** A section's `List` stays cached for the session. Revisiting a tab
  renders it at once and does not refetch, unless a `listing` event or a reconnect has
  marked it stale.

### Styling

`src/app.css` imports Tailwind 4 and daisyUI 5 (`@plugin "daisyui"` with the `luxury`
theme). Class names are carried over from `page.rs` and `page.css`. The target is under
60 KiB gzipped for the JavaScript and CSS together. Going over that is worth a look but
does not fail the build.

## Build and deploy

- `packages/plab/package.nix` gains `passthru.ui`, a `buildNpmPackage` over `./ui` (its
  own `lib.fileset`, so it does not see `src/`) with `npmDepsHash`. It runs
  `npm run build` and installs `dist/` to `$out`. Its `checkPhase` runs `svelte-check`
  and `vitest run`.
- The Rust fileset already excludes `ui/`, so a UI change does not rebuild plab and a
  Rust change does not rebuild the UI. The Rust fileset drops `./assets`.
- `modules/hosts/galactica/services/plab/default.nix` sets
  `PLAB_STATIC_DIR=${plab.ui}` and deletes the `static` `linkFarm` and its four
  `fetchurl`s.
- **Development.** `just plab-ui-dev` runs `npm run dev` in `ui/` under
  `nix develop`. Vite proxies `/api` to `PLAB_DEV_BACKEND`, default
  `http://127.0.0.1:8577`: a local `plab serve`, or `ssh -L 8577:127.0.0.1:8577
  galactica`.

## Removed

`src/page.rs`, `src/page_tests.rs`, `assets/page.js`, `assets/page.css`,
`tests/fixtures/golden_page*.html`, the `/`, `/games`, `/search`, `/static/`, `/add/`,
`/unqueue/`, `/thumb/`, `/images/`, `/img/` and `/stream/` arms on the page port (their
`/api` equivalents replace them), and the Alpine and Tailwind entries in the Nix
module. Shared helpers that `page.rs` owned and something else still needs (`score`,
`size` for logs, `TOPIC_URL`) move to `api.rs` or to where they are used.

## Errors

- REST failures show inline: the card's error text, the search error in the summary
  line, an alert on `/jobs`, and an alert in place of the grid when `/api/list` fails.
- When SSE drops, the connection dot turns amber. `EventSource` retries on its own, and
  the reopen refetches the current view.
- A 502 from `/api/stream` shows in the player, as today.
- There is no page without JavaScript. That is accepted.

## Testing

- **`api.rs`.** From the seeded listings the golden fixtures used: the video, games and
  search `List` (sort order, `production` names, `images` null/empty/keys,
  `state`, `status` per kind with links), and `grabs`. These replace the golden HTML
  tests.
- **`web_tests.rs`.**
  - Every `/api` route returns its status and content type.
  - An unknown `/api/x` is a 404.
  - `/games` and `/jobs` serve `index.html` with `no-cache`.
  - `/assets/<hashed>` has the immutable header, and `../` is rejected.
  - Add and unqueue still return `AddReply`.
- **`events.rs`.**
  - A successful add publishes a `topicState` event.
  - Each event serializes with its `type` tag; a `job` event is its jobs entry plus the tag.
  - A lagged receiver gets `resync`.
  - `status_changes` reports new, changed and gone topics, and nothing else. (The pump's
    sampling cadence and its idling with no receivers are read, not unit-tested.)
- The jobs monitor tests are as in its spec.
- **`ui/` (vitest).** The `isVisible` predicate (each filter, and the AND of tags),
  filter hash and localStorage round-trip including today's format, the seen/NEW
  window, and the event reducer applying `topicState` and `topicStatus` to every list that holds the id.
- **By hand on galactica:**
  - Add from the phone and watch the desktop card flip.
  - Filter, reload, and check the filters survive.
  - Open `/jobs` during a watcher pass.
  - Stream a release and Stop.
  - Restart plab with the page open and check that the dot goes amber, then green, and
    the view refetches.

## Out of scope

- A visual redesign, a release detail view, infinite scroll, keyboard navigation.
- Starting or stopping jobs from the page.
- Event replay (`Last-Event-ID`). A reconnect refetches.
- Auth changes: plab stays behind the gateway's Authelia as today.
