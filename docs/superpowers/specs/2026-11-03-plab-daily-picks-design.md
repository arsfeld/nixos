# plab daily picks: recommendations as the default view

Date: 2026-11-03. Package: `packages/plab`. Host: galactica.
Builds on `2026-11-03-plab-assistant-design.md`.

## Goal

The assistant's Recommend output becomes plab's landing page: `/` shows today's picks,
refreshed lazily once a day. The chat and its history stay a separate feature on the
Assistant tab.

"Lazily" means that a visit triggers the refresh. There is still no timer and no job. A day
on which plab is never opened costs no LLM call.

## Decisions

| Question | Decision |
|---|---|
| First visit of a new day | Show the last good picks at once with a "refreshing…" note; swap in today's when ready |
| Who triggers and owns the refresh | The server, deduped, with completion pushed over SSE (approach A) |
| URLs | `/` becomes **For you**; the Tracker list moves to `/tracker` |
| Relation to chat history | A daily is a recommend conversation, followable with **Ask about these**, and absent from the history list until followed up |
| Recommend button on the Assistant tab | Removed; **Refresh** on For you replaces it |

Rejected: the client calling `POST /recommend` itself when the picks are stale (two tabs or
two devices each start a generation, and a tab closed mid-turn learns nothing until it
reloads), and precomputing on a timer (not lazy, and it pays for days nobody looks).

## What a daily is

No migration. A daily is a `kind = 'recommend'` conversation, as made by
`Assistant::start(Kind::Recommend, None, now)`. "Today" is the local date on galactica
(`chrono::Local`), compared against the conversation's `created_at`.

Three derived facts, all computed from `db`:

- **Shown daily**: the newest recommend conversation whose last assistant turn has at
  least one pick. That is today's if it succeeded, or else the last good one.
- **Attempted today**: some recommend conversation has a `created_at` that falls on
  today's local date, whatever its outcome.
- **Followed up**: a recommend conversation with more than one user turn.

## Server

### Lazy start and dedupe

`Assistant` gains a `daily_running: AtomicBool`, set with `compare_exchange`, plus a method:

```rust
/// Start today's recommendations on a detached task unless today has been attempted or one is
/// running. Returns whether a generation is now running.
pub fn ensure_daily(self: &Arc<Self>, db: Db, events: Events, now: i64) -> bool
```

- If today has been attempted and nothing is running, it returns `false` and does nothing.
- Otherwise it sets the flag, and `tokio::spawn`s `start(Recommend)`, pruning, and then an
  event. The task clears the flag when it ends, on success or failure. So concurrent requests
  start exactly one generation.
- `ensure_daily` returns `false` without spawning when `ready()` fails (no key, or no
  prompt). The GET then reports the reason, as the other endpoints do.

### Failure

A failed generation stays stored as today's conversation, with its `plab_error` turn, as
`turn()` already does. Because today counts as attempted, later visits do not retry, which
keeps a broken model or prompt from costing a call per page load. The shown daily stays
the last good one, and the GET carries today's error. **Refresh** is the explicit retry.

A restart does not reset this: "attempted today" lives in the DB, not in memory.

### Pruning

When a daily is created, every recommend conversation that is not followed up and is older
than 30 days is deleted in the same task. Followed-up ones are chats now and are kept.

### SSE

`Event` gains a variant `AssistantDaily` (wire: `{"type": "assistantDaily"}`), with no
payload. It is broadcast when a daily generation ends, whatever its outcome. Clients
re-GET.

### API

| Method and path | Purpose |
|---|---|
| `GET /api/assistant/daily` | Call `ensure_daily`; return `{conversation, generatedOn, refreshing, error}` |
| `POST /api/assistant/daily/refresh` | Start a new daily even if today was attempted; 409 while one runs; returns as GET |

- `conversation` is the shown daily as the existing `ConversationDto`, or `null` before
  any daily has ever succeeded.
- `generatedOn` is its local date (`YYYY-MM-DD`).
- `refreshing` is whether a generation is running.
- `error` is the error text of today's attempt when that attempt failed, or a `ready()`
  reason (no key or prompt); otherwise `null`.

The GET answers 200 even when the assistant is not ready, because For you is now the
landing page and must render. The reason travels in `error`.

### History list

`GET /api/assistant/conversations` leaves out recommend conversations that are not
followed up. `GET /api/assistant/conversations/<id>` still opens any conversation, which
is how **Ask about these** works: once a follow-up is sent, the conversation is followed up
and joins the list.

`POST /api/assistant/recommend` is removed. Its only caller was the Assistant tab's
Recommend button.

## UI

### Routing

- `route.ts`: `/` → `{view: 'daily'}`, and `/tracker` → `{view: 'video'}`. The fallback for an
  unknown path becomes `daily`.
- `Navbar`: a first tab **For you** at `/`, then **Tracker** at `/tracker`; the rest are
  unchanged.
- Every place that links to `/` as "the Tracker list" is updated to `/tracker`.

### `DailyView.svelte`

- Header: "Picks for <generatedOn>". While `refreshing`, it shows a spinner and
  "refreshing…". It has a **Refresh** button (disabled while refreshing) and an **Ask
  about these** link to `/assistant/<id>`.
- `error`: an alert with the text, and **Retry** (the same call as Refresh).
- The picks are in two groups: **Watch** (`SceneCard`), and **Stream / download** (`Card`,
  with live status from the SSE store). Each card shows its reason, and a group with no picks
  is not shown.
- The model's text turn is shown above the groups, clamped to three lines and expandable on click.
- The Stash-degraded notes (`degraded`, `scenesUnavailable`) carry over from
  `AssistantView`.
- With no conversation and `refreshing`, it shows a full loading state: "Picking for
  today…".

### Shared pick rendering

The pick grid moves out of `AssistantView.svelte` into `Picks.svelte`, which takes the
conversation, its picks, a `grouped` flag, and the gallery and player callbacks. Both
views use it.

### Stores

`lib/daily.svelte.ts` holds `{conversation, generatedOn, refreshing, error}`:

- It loads on mount of `DailyView`.
- It re-fetches on `assistantDaily` and on SSE reconnect while the route is `daily`.
- `refresh()` POSTs and adopts the response.

The pure parts (grouping picks by action, the header state) live in `lib/daily.ts` for
vitest.

### Assistant tab

The Recommend button and `assistant.recommend()` go. **New chat**, the history list and
the transcript stay. The empty-state text becomes "Ask something below; today's picks are
on For you."

## Errors

| Case | Behaviour |
|---|---|
| No key or no prompt | For you renders, with the reason in `error`; there are no picks and no Refresh spinner |
| Today's generation fails | The last good picks stay, with an error alert and Retry; no automatic retry until tomorrow |
| Refresh while running | 409; the button is disabled anyway |
| Stash unreachable | As before: the picks are degraded, and the notes show |
| No daily ever succeeded, and today failed | Error alert and Retry, with nothing else |

## Testing

Rust (`web_tests.rs`, `assistant` tests, with OpenRouter on wiremock):

- Two concurrent GETs on a stale day start exactly one generation (one wiremock hit).
- Today attempted and failed: a GET returns the previous good daily plus `error`, and
  starts nothing.
- Stale across local midnight: yesterday's daily counts as stale, and today's as fresh.
- Refresh: it starts a generation on an attempted day, and answers 409 while one runs.
- The history list leaves out unfollowed recommend conversations and includes followed-up
  ones.
- Pruning deletes unfollowed dailies older than 30 days and keeps followed-up ones.
- The `assistantDaily` event is broadcast on success and on failure.
- Not ready: the GET is 200 with `error` set.

UI (vitest):

- Route parsing: `/`, `/tracker`, and an unknown path.
- Grouping picks by action.
- The daily store's adoption of a response, and a refresh while refreshing.

## Out of scope

Timed precomputation, per-pick dismissal or feedback, more than one daily per day without
an explicit Refresh, and push notifications for new picks.
