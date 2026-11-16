# plab watchlist — a queue of Stash scenes to watch

**Host:** galactica · **Code:** `packages/plab/` · **Builds on:**
`2026-11-02-plab-stash-links-design.md`, `2026-11-03-plab-daily-picks-design.md`,
`2026-11-03-plab-assistant-design.md`

## Goal

A Watchlist tab listing Stash scenes queued to watch, oldest first, each opening in Stash.
Any card plab shows for a scene that is in Stash has a ☆ to queue it. A scene leaves the
list when it is removed by hand or once Stash records a play of it after it was queued.

Playback stays in Stash. plab does not serve library files.

## Scope

- **In:** scenes that are in Stash: plab downloads whose files Stash has linked, and any
  Stash scene shown on a pick card (For you, assistant chat).
- **Out:** releases not yet in Stash (queued, downloading, added but unlinked), albums and
  games. They get no ☆; it appears by itself once identify links the download's files.
- **Out:** reordering, a "mark watched" button (a play in Stash is the signal), and any
  assistant tool that writes the watchlist. The assistant stays read-only: its watch picks
  render as scene cards, which carry the ☆, so queueing from chat is one click by the user.

## Data

`schema_v8.sql`, included after `schema_v7.sql` in `db/mod.rs`:

```sql
-- Stash scenes queued to watch (design: 2026-11-16-plab-watchlist-design.md).
CREATE TABLE watchlist (
  scene_id TEXT PRIMARY KEY,       -- Stash scene id
  added_at INTEGER NOT NULL        -- unix time it was queued
);
```

The key is the Stash scene id alone. A pack is several scenes, so it is several rows.

`db/watchlist.rs`:

- `watch_add(ids, now)`: insert each id with `added_at = now`; an id already present keeps
  its original `added_at` (`INSERT OR IGNORE`).
- `watch_remove(ids)`: delete each id.
- `watch_list() -> Vec<(String, i64)>`: every row, oldest `added_at` first.
- `watch_ids() -> Vec<String>`: the ids alone, for the stars.

## Auto-removal

Pure: `watchlist::expired(rows, scenes) -> Vec<String>` over the rows and the `LibScene`s
`Stash::lib_scenes` returned for them. A row expires when:

1. its scene's `last_played_at` (RFC 3339) is later than its `added_at`, or
2. Stash returned no scene with its id (deleted from the library).

A play before the scene was queued does not count, so a scene watched before can be queued
again. An unparseable `last_played_at` counts as no play.

It runs inside `GET /api/watchlist`, the only reader that needs scene details anyway: one
`lib_scenes` call for every row, then `watch_remove(expired)`, then the reply. There is no
background job. If Stash is unreachable, nothing expires and the reply carries `error`, the
way the list replies do, and an empty `scenes`.

## API

Routes go through `web.rs`'s existing dispatch (`api_get` for GET, the POST branch for
writes; the POST handler reads a JSON body as `assistant_routes` does).

| Route | Body | Reply |
|---|---|---|
| `GET /api/watchlist` | – | `{now, scenes: WatchScene[], error?}` |
| `GET /api/watchlist/ids` | – | `{ids: string[]}` |
| `POST /api/watchlist/add` | `{scenes: string[]}` | `{ids: string[]}` |
| `POST /api/watchlist/remove` | `{scenes: string[]}` | `{ids: string[]}` |

- `WatchScene` is the assistant's `SceneDto` (`ref`, `id`, `title`, `studio`,
  `performers`, `screenshot`, `link`) plus `addedAt`. `scene_dto` and `rebase` move from
  `web/assistant_routes.rs` to a shared place both routes use, rather than being copied.
- Add and remove reply with the full id set after the change. An empty or non-string
  `scenes` is a 400. Ids are not checked against Stash on add: every caller got them from
  Stash, and a stale one expires on the next load.
- After add or remove the server broadcasts `{type: 'watchlist', ids}` on the existing
  event stream, so every open page updates its stars and its Watchlist tab.

### Scene ids on statuses

`StatusDto::InStash` and `StatusDto::Identified` gain `scenes: string[]`, taken from
`provenance::Status`'s existing `scenes` (in `download_file.path` order, each once). That
reaches every card that can show one: a release's own download, a card `ownedBy` another
download (which already takes that download's status in `api::list`), and Recent grabs rows.
The TS `Status` type gains the field.

## UI

### Shared state

`lib/watchlist.svelte.ts`: a reactive `Set` of watched scene ids, loaded from
`GET /api/watchlist/ids` at startup and replaced by every `watchlist` event and every
add/remove reply. `watching(ids)` is true when every id is in the set; `toggle(ids)` adds
them all when any is missing, else removes them all. The set logic is pure in
`lib/watchlist.ts`, tested like the other reducers.

### `WatchButton.svelte`

Takes `scenes: string[]`; renders nothing when it is empty. Ghost button, `☆ Watch` /
`★ Watching`, `btn-sm` or `small` (`btn-xs`) like `AddButton`. On a failed request it shows
the error as its title and leaves the set unchanged.

### Where it appears

- **Release cards** (`Card.svelte`, Tracker, Indexers, search): in the action row beside
  the status badge, with the status's `scenes`. A pack's ☆ queues all its scenes, and shows
  ★ only when all of them are queued.
- **Recent grabs** (`GrabsStrip.svelte`): `small`, after each row's status badge.
- **Scene cards** (`SceneCard.svelte`): in its action row beside Open in Stash, with
  `[scene.id]`. This covers For you picks and the assistant's watch picks in chat, both of
  which render through it.

### The Watchlist tab

- Route `/watchlist`, `{ view: 'watchlist' }` in `route.ts`; a `Watchlist` tab after
  For you in `Navbar.svelte`.
- `WatchlistView.svelte` loads `GET /api/watchlist` on open and on every `watchlist` event
  and `resync`. Heading `Watchlist (N)`, then the same grid as For you of `SceneCard`s,
  oldest first. `SceneCard` takes an optional `reason`; here the line reads `added 3d ago`
  (`format.age`).
- Removing the ★ on this tab drops the card at once.
- Empty: "Nothing queued. ☆ Watch appears on any card for a scene that's in Stash."
- An `error` shows above the grid as the list views show theirs.

## Testing

- **db:** migration applies on top of v7; add is idempotent and keeps the first
  `added_at`; remove; list order.
- **auto-removal (`expired`):** played after queued expires; played before queued stays;
  never played stays; missing from Stash expires; unparseable `last_played_at` stays.
- **API (`api_tests.rs`, `web_tests.rs`):** `GET /api/watchlist` against a wiremock Stash
  drops expired rows and returns `WatchScene`s; Stash down returns `error` and removes
  nothing; add/remove reply with the id set and broadcast the event; a bad body is a 400;
  `InStash`/`Identified` statuses carry `scenes`.
- **UI (vitest):** `route.ts` parses `/watchlist`; the set reducer's `watching`/`toggle`
  for one scene and for a pack, partly queued included.
