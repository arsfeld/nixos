# plab assistant: on-demand recommendations and chat

Date: 2026-11-03. Package: `packages/plab`. Host: galactica.

## Goal

Help decide what to download and what to watch. Two entry points, one feature:

- **Recommend**: a button. It builds a taste profile from recent views and returns a short
  list of picks, each one a real card with a one-line reason.
- **Chat**: ask follow-up or free questions ("something short tonight", "is this release
  worth grabbing?") with the same context.

Recommend is a conversation whose first turn is a canned request, so its picks can be
followed up like any chat. Nothing runs in the background: no job, no timer. A
recommendation exists only because the button was pressed.

## Decisions

| Question | Decision |
|---|---|
| Shape | Recommend button **and** chat, unified as conversations |
| Watch pool | Unwatched Stash scenes **and** streamable releases on plab's lists |
| View signals | Stash play history (plays, o-count, rating) **plus** a new plab stream log |
| Model power | Advise only. Read-only tools; every action is a card button the user presses |
| History | Every conversation kept in `state.db`, browsable and deletable |
| Approach | Rust builds profile and candidates deterministically; the model ranks and explains |

Approaches rejected: dumping the raw lists into the prompt (hundreds of entries, costly, and
the model's ids drift), and embeddings with a vector store (a new store and an indexing job,
over-built for an on-demand button).

## Data

Migration `schema_v7.sql`:

```sql
-- One row per stream started from the page's Stream button. Streams never reach Stash, so
-- without this a streamed-but-never-downloaded release is invisible to the recommender.
CREATE TABLE stream_view (
  id INTEGER PRIMARY KEY,
  topic_id INTEGER NOT NULL,       -- tracker topic or external_release id
  started_at INTEGER NOT NULL
);
CREATE INDEX stream_view_at ON stream_view(started_at);

CREATE TABLE conversation (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  kind TEXT NOT NULL,              -- 'recommend' | 'chat'
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- The full transcript, tool calls and tool results included, so a conversation resumes
-- exactly as the model last saw it.
CREATE TABLE message (
  id INTEGER PRIMARY KEY,
  conversation_id INTEGER NOT NULL REFERENCES conversation(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,
  role TEXT NOT NULL,              -- 'user' | 'assistant' | 'tool'
  content TEXT NOT NULL,           -- JSON
  at INTEGER NOT NULL,
  UNIQUE (conversation_id, seq)
);
```

`stream_view` is written by `Streams::start` (`src/stream.rs`) once a stream has started.
A start for the same topic within 6 hours of its last row is not recorded again, so a
reopen or a file switch is not counted as a second view.

## Modules

Each has one job. The two pure modules are tested without an LLM or a network.

### `taste.rs` (pure)

`fn profile(views: &[View], now: i64) -> Profile`.

- `View { at, studio, performers, tags, o_count, rating }`. Stash plays give all fields;
  a `stream_view` gives the topic's title only. A streamed topic that has a matched scene
  takes that scene's studio, performers and tags.
- Each view's weight is `0.5^(age_days / 30)` (a 30-day half-life) times
  `1 + 0.5 * o_count` times a rating factor (`rating100 / 60`, or 1 when unrated).
- `Profile` is the weighted studios, performers and tags, each list sorted and capped at
  15, plus the 20 most recent views as short lines for the prompt.

### `candidates.rs` (pure)

`fn candidates(profile, listings, unwatched_scenes) -> Vec<Candidate>`, at most 40.

- `Candidate { ref_, kind, title, why_matched }`. `ref_` is `s:<scene id>` for a Stash
  scene or `t:<id>` for a tracker topic or external release. `kind` is `watch` for a scene,
  `stream_or_download` for a release.
- A release scores by profile terms found in its title, or in its matched scene's studio
  and performers. A scene scores by its studio, performers and tags.
- Excluded: releases already downloaded (a `download` row), albums (they can be neither
  added nor streamed), and scenes with plays.
- Capped at about 25 scenes and 25 releases before the overall cap of 40, so neither pool
  crowds out the other.

### Stash queries (`src/stash/`)

Two new queries, wiremock-tested like the existing ones:

- **Recent plays**: scenes with `last_played_at` in the last 60 days, carrying `play_count`,
  `o_counter`, `rating100`, studio, performers and tags.
- **Unwatched**: `play_count: 0` scenes filtered to the profile's top studios or performers
  (an `INCLUDES` scene filter). The screenshot path rides along, for the card.

### `assistant.rs`

The conversation loop over the existing `OpenRouter` in `llm.rs`, which gains a
`chat_tools` call next to `chat_json`.

- **System prompt**: the new `assistant` field of `site::Prompts`, which lives in the
  `plab-site` secret like the other prompts, so nothing about content lands in the repo.
  It is `#[serde(default)]`: a deploy that comes before the secret has been updated keeps
  plab running, and the assistant answers 503 until the prompt is set. Rust appends the
  profile and the candidate list as JSON.
- **Model**: `PLAB_ASSISTANT_MODEL` (`config.rs`), defaulting to the parse model. It must
  support tool calling.
- **Tools** (read-only):
  - `search_lists(q)` matches the current Video and Indexers listings, up to 20 (not Albums, which can't be added or streamed, nor Games).
  - `find_stash_scenes(q)` is a Stash text search, up to 20, with play counts.
  - `recent_views()` returns the profile's recent-views lines in full.
- **Loop**: send, run any tool calls, send their results back. At most 6 rounds.
- **Final answer**: a JSON object, `{"text": "…", "picks": [{"ref": "t:123", "action":
  "watch|stream|download", "reason": "…"}]}`. Every pick is resolved against the DB or
  Stash. One that does not resolve is dropped, and the drop is logged at debug level.
- **Recommend**: a conversation with `kind = 'recommend'` and a fixed first user turn
  asking for up to 5 watch and 5 download or stream picks. Its title is
  `Recommendations · <date>`. A chat's title is its first message, truncated to 60
  characters.
- **Lock**: one turn per conversation at a time.

## API

All under plab's existing Authelia-gated vhost.

| Method and path | Purpose |
|---|---|
| `POST /api/assistant/recommend` | Start a recommend conversation and run its first turn; returns `{conversation_id, messages}` |
| `POST /api/assistant/conversations/<id>/messages` | Body `{text}`; append a turn and run it |
| `POST /api/assistant/conversations` | Body `{text}`; start a chat with its first turn |
| `GET /api/assistant/conversations` | `[{id, title, kind, updated_at}]`, newest first |
| `GET /api/assistant/conversations/<id>` | Transcript, picks resolved to card DTOs |
| `DELETE /api/assistant/conversations/<id>` | Delete it |

`web.rs`'s `post()` does not read request bodies today. It gains a JSON-body reader with a
16 KB cap, and the dispatcher gains `DELETE`.

A turn is a plain request that returns when the model is done; tool rounds included, that
is typically 5–30 s. There is no token streaming. The transcript DTO shows only the user
and assistant text and the picks. Tool messages are stored but not shown.

Resolved picks reuse the list views' card DTO for releases. A scene gets a new
`SceneDto { id, title, studio, performers, screenshot, link }`, with `link` built from
`PLAB_STASH_WEB_URL`.

## UI

- Route `/assistant` (`route.ts`) and an **Assistant** tab in `Navbar`.
- `AssistantView.svelte`:
  - On the left, the conversation list with **Recommend** and **New chat** above it.
  - On the right, the transcript, with an input at the bottom. While a turn runs the input
    is disabled and shows a spinner.
- Download and stream picks render as the existing `Card` (Add and Stream buttons, live
  status through the SSE store). Watch picks render as a new `SceneCard.svelte`:
  screenshot, title, studio and performers, and **Open in Stash**. Each card shows its
  pick's reason.
- `lib/assistant.svelte.ts` is the store for the list and the transcript. Its pure reducer
  lives in `lib/assistant.ts`, where vitest can reach it.

## Errors

- **No OpenRouter key or no `assistant` prompt**: the assistant endpoints answer 503 with
  the reason, and the tab shows it. The rest of plab is unaffected.
- **Stash unreachable**: the turn runs on the stream log and the lists alone. The system
  prompt says Stash data is missing, and the reply carries `degraded: ["stash"]`, which the
  UI shows as a small note.
- **Model failure** (an HTTP error, a malformed final answer after one re-ask, or the
  round cap reached): the user turn is kept, and an assistant message `{"error": "…"}` is
  stored. The UI offers **Retry**, which re-runs the last user turn.
- **Bad tool arguments**: the tool returns an error as its result, so the model can correct
  itself.
- **A turn already running on the conversation**: 409.
- **Body over 16 KB**: 413.

## Testing

- `taste.rs`: the decay, the o-count and rating boost, the merge with stream views, the caps.
- `candidates.rs`: matching, the exclusions (downloaded, albums, played), the per-pool and
  overall caps.
- `assistant.rs`: OpenRouter wiremock scripted through a tool call, a tool result and a
  final answer. Cases: the round cap, an unresolvable ref, a malformed final answer, Stash
  degraded.
- `stash`: the two new query shapes.
- `web_tests.rs`: every endpoint over an in-memory DB, the 409, the 413, the 503.
- `db`: the v7 migration over a v6 database. A `stream_view` repeat within 6 hours is not
  recorded.
- UI (vitest): route parsing for `/assistant`, and the reducer (pick resolution, the error
  and retry state).

## Out of scope

The model taking actions itself, token streaming, background or scheduled
recommendations, embeddings, and recommending games.
