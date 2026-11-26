# plab taste feedback: votes and real watches

Date: 2026-11-26. Package: `packages/plab`. Host: galactica. Builds on
`2026-11-03-plab-assistant-design.md` (taste profile, candidates, prompt) and
`2026-11-16-plab-watchlist-design.md` (the pattern for scene state, routes and events).

## Goal

Give the assistant better input so its recommendations (Recommend, chat, daily picks) follow
what was actually enjoyed:

- **Explicit votes**: +1 / −1 on any Stash scene, from plab.
- **Real watches**: a play counts only when more than a tiny part of the scene was watched;
  sampling a scene and abandoning it is a mild negative.

Success: the profile stops being shaped by scenes that were only sampled, voted-down scenes
are never offered again, and the traits of voted-down scenes lose weight.

## Why: what Stash records today

Measured on galactica's Stash (v0.32.0), 2026-11-26. The assistant counts every scene with
`play_count > 0` as a view, but Stash increments `play_count` as soon as a scene starts. Of
the 25 most recent plays, 9 had `play_duration` of 1-9 s (several after skipping deep into
the scene, `resume_time` 300-3700 s): samples, rejected. Real watches had 2-14 minutes of
`play_duration`. Even scenes rated 100 or with an o-count show only 9-57% of their length
watched, so "watched" is an absolute duration, never a fraction of the scene. Today a 1 s
sample adds as much to its studio, performers and tags as a 10-minute watch.

## Decisions

| Question | Decision |
|---|---|
| Where votes live | plab's `state.db`, keyed by Stash scene id. Stash ratings untouched and still read |
| What −1 does | The scene is never offered again **and** its studio, performers, tags lose weight, as much as a +1 adds |
| What counts as watched | ≥ 2 min watched (or any o-count, or a rating) is a view; < 30 s is a weak negative (¼ of a vote); in between is ignored |
| Where to vote | Beside every Watch button, plus a "Recently watched" strip on For you |
| Approach | Signed weights in the existing deterministic pipeline (`taste.rs`, `candidates.rs`) |

Approaches rejected: putting votes and durations only in the prompt (the shortlist would still
be built from the noisy profile, so the model would only re-rank bad candidates), and separate
like/avoid profiles scored as `like − k·avoid` (an extra tuning constant, and it double-counts a
performer both watched and voted down, which a net sum resolves).

## Data

Migration `schema_v10.sql`:

```sql
-- A +1 or −1 on a Stash scene. One row per scene; clearing a vote deletes the row.
-- `voted_at` is when the vote was last set, for decay.
CREATE TABLE scene_vote (
  scene_id TEXT PRIMARY KEY,
  vote INTEGER NOT NULL CHECK (vote IN (-1, 1)),
  voted_at INTEGER NOT NULL
);
```

`db/votes.rs`:

- `vote_set(id, vote, now)`: upsert. `voted_at` is set on insert and refreshed when the vote
  changes; setting the same vote again keeps its `voted_at`.
- `vote_clear(id)`: delete.
- `votes() -> Vec<(String, i8, i64)>`: `(scene_id, vote, voted_at)`.

Votes never expire. A −1 keeps its scene out of the shortlist forever; its weight on traits
fades with age (below). A scene Stash no longer has keeps its row; it is skipped wherever it
is read (`lib_scenes` leaves it out), so no pruning is needed.

## HTTP

`web/vote_routes.rs`, routed from `web.rs` like `/api/watchlist`:

- `GET /api/votes` → `{"votes": {"<scene id>": 1 | -1}}`.
- `POST /api/votes` with `{"scenes": [ids], "vote": 1 | -1 | 0}`: sets each scene's vote, 0
  clears. Answers with the new map and publishes `Event::Votes { votes }`, so every open page
  updates. Any other `vote`, or an empty `scenes`, is 400.
- `GET /api/recent` → the Stash scenes really watched (the rule below) whose `last_played_at`
  is within 14 days, as the watchlist's scene DTO (`web/scene_dto.rs`), unvoted first, then
  newest first. Stash unreachable is 502.

## Taste math (`taste.rs`, pure)

`LibScene` gains `play_duration: Option<f64>` (added to `FIELDS` in `stash/library.rs`).
`View` gains:

- `watched_secs: Option<u32>`: Stash's `play_duration`; `None` for streams and when Stash
  has none.
- `vote: Option<(i8, i64)>`: the vote and its `voted_at`.
- `played: bool`: whether the play part applies (played within `LOOKBACK`). A scene known only
  through a vote has `played = false`.

Constants, each pinned by a test:

```rust
pub const WATCHED_SECS: u32 = 120;
pub const SAMPLED_SECS: u32 = 30;
pub const VOTE: f64 = 2.0;
pub const SAMPLE: f64 = -0.5;
```

`weight(v, now)` is the sum of two parts, each decayed by `HALF_LIFE_DAYS` (30) from its own
time:

- **Play part** (only when `played`, dated `v.at`):
  - **Watched**: `watched_secs ≥ WATCHED_SECS`, or `o_count > 0`, or a rating, or
    `watched_secs` is `None` (Stash gave no duration: today's behaviour, nothing lost).
    Weight `decay × (1 + 0.5·o) × rating/60` (unrated ×1), today's formula.
  - **Sampled**: `watched_secs < SAMPLED_SECS`, no o, no rating. Weight `SAMPLE × decay`.
  - Otherwise 0.
  - Streams keep today's weight (+1 decayed); plab knows nothing of their watch time.
- **Vote part**: `vote × VOTE × decay(voted_at)`. No lookback cut-off; decay alone retires
  old votes (⅛ at 3 months).

Worked examples: watched with an o then +1 = 1.5 + 2 = 3.5; watched then −1 = −1; sampled
once = −0.5. A performer across several real watches stays positive despite one −1.

`profile()` sums signed weights per term as now, then:

- `studios`, `performers`, `tags`: terms with net weight > 0, top `TOP` (15) each.
- New `avoid: Avoid { studios, performers, tags }`: terms with net weight < 0, most negative
  first, at most `AVOID_TOP` (10) each. Serialized into the prompt with the rest.
- `recent`: the `RECENT_LINES` newest views that are watched, voted or streamed (samples left
  out; they act through weights only), each line suffixed with what applies: `watched N min`,
  `+1`, `−1`, `streamed`. A vote-only line is dated `voted_at`.

## Context, shortlist, tools, prompt

`context::views`:

- Reads `db.votes()` with Stash's recent plays. Voted scenes not among those plays are fetched
  with one `lib_scenes(ids)` call for their studio, performers and tags. Plays and votes are
  merged per scene id into one `View`.
- Stash down: votes cannot be resolved to traits; the profile falls back to the stream log as
  today (`degraded: ["stash"]`).

`context::gather` passes the set of −1 scene ids to `candidates`.

`candidates.rs`:

- `terms()` also folds in `profile.avoid` (negative weights), so an avoided trait lowers a
  candidate's score.
- Scene ids voted −1 are excluded before scoring: a hard rule, not a weight. It holds when
  Stash is down too, since it needs only ids.
- A candidate whose score is ≤ 0 is dropped (today any match counts).

Tools: `find_stash_scenes` leaves out −1 scenes, as `drop_owned` keeps owned releases out of
the release searches. `recent_views` returns the annotated lines.

System prompt, two added sentences: terms under `avoid` are things the user voted down or
sampled and abandoned, so do not recommend on them (and say so if asked); `+1` / `−1` on recent
views are explicit votes and weigh above plays.

Daily picks use the same `gather` and change with no work of their own.

## UI

- `lib/votes.ts` (pure): `nextVotes(map, event)`; `voteAction(current, pressed)` (pressing the
  active thumb gives 0, otherwise the pressed value); `voteOf(map, scenes)` (±1 only when every
  listed scene agrees, otherwise none).
- `lib/votes.svelte.ts`: `VotesStore` mirroring `WatchlistStore`: `load()`, `apply(ev)` for
  `Votes` events, `set(scenes, vote)`. One shared map for every card.
- `components/VoteButtons.svelte`: 👍 and 👎 ghost buttons, props `scenes` and `small` like
  `WatchButton`, acting on every listed scene (a release card's ids are copies of one scene).
  The active thumb filled (success / error colour), the other dimmed; the `title` explains the
  toggle, and on failure shows the error. No optimistic update. Placed right after
  `WatchButton` in `SceneCard`, `Card`, `GrabPoster`, `GrabsStrip`, `WatchlistView`.
- For you (`DailyView`): a "Recently watched" row below the picks, `SceneCard`s from
  `GET /api/recent`, loaded with the page and refreshed on a `Votes` event. Hidden when empty
  or when the request fails.

No page listing all votes; a vote is undone wherever its scene appears.

## Testing

Rust:

- `taste.rs`: watched by duration; watched by o with a short duration; sampled; the 30-120 s
  zone scores 0; no `play_duration` counts as watched; vote only; vote plus play; vote decay;
  net-negative terms in `avoid` and never in the positive lists; recent-line suffixes and
  samples left out; one test per constant.
- `candidates.rs`: an avoided term lowers a score; a score ≤ 0 is dropped; −1 ids excluded even
  when they would score high.
- `db/votes.rs`: set, switch, clear, `voted_at` refreshed on a change and kept on a repeat.
- `context.rs` (wiremock Stash): a voted, never-played scene shapes the profile; a Stash
  failure keeps −1 exclusion.
- Tools: `find_stash_scenes` leaves out −1 scenes.
- Web routes (`web_tests.rs` style): `GET`/`POST /api/votes`, vote 0 clears, 400 on bad input,
  `Event::Votes` published; `/api/recent` keeps only real watches within 14 days, unvoted
  first.

UI (vitest): `votes.test.ts` for `voteAction`, `voteOf` (mixed scenes give none), `nextVotes`.

Acceptance on galactica after deploy: vote −1 on a scene in Recently watched; start Recommend;
the stored system message's PROFILE has that scene's studio or performers under `avoid` or
reduced, no candidate is that scene, and the recent lines show no 1-9 s samples.
