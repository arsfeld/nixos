# plab: background jobs monitor

Date: 2026-11-02.

## Goal

A `/jobs` page shows what each of plab's background workers is doing right now, and what
it did recently: whether it is running, its current step and progress, its recent log
lines, when it runs next, and its last runs with their durations and errors. It is
read-only; nothing on it starts or stops a job.

## Today

`plab serve` runs every worker as a supervised task in one process
(`commands::serve`): the identify watcher, `sweep`, `refresh`, `prune` and `grab`, plus
`web`. `jobs::supervise` runs each inside a `task{job=<name>}` tracing span, and the jobs
already log their steps there (`scan [...]`, `N new scene(s)`, `llm step: 12 scene(s)`,
`[id] failed, will retry next pass`, `queued 123: added`, `kept X: …`). The only record
of a run is `job_run`, one row per job holding its last start, last finish and last
error. It drives scheduling (`jobs::overdue`) and is shown nowhere. Watcher passes are
not recorded at all.

## Approach

The monitor reads the jobs' existing tracing events rather than having each job report
its progress through a handle. A `tracing_subscriber::Layer` attributes every event to
its job by the enclosing `task` span. So the page shows exactly what the journal shows,
and the generic `Ctx`/`Clients` code needs no new parameter. State transitions
(running, idle, restarting) are not inferred from log text. `jobs::record` and
`jobs::supervise` set them explicitly.

The cost is that a step reads however its log line was written, and a future
`tokio::spawn` inside a job falls outside the span unless it is `.instrument`ed. No job
spawns subtasks today.

## The `monitor` module (`src/monitor.rs`)

`Monitor` is a cheap `Clone` around an `Arc<Mutex<HashMap<&'static str, JobLive>>>`,
held in a process-wide `OnceLock` (`monitor::global()`). It is global, and not on `App`,
so that the layer needs no handle and the one-shot CLI commands, which build no `App`,
are unaffected.

```rust
pub struct JobLive {
    pub state: LiveState,
    pub step: Option<Line>,              // the latest event
    pub progress: Option<(u64, u64)>,    // (done, total)
    pub lines: VecDeque<Line>,           // the last 20 events
}
pub enum LiveState {
    Idle,
    Running { since: i64 },
    Watching { pending: usize },         // the identify watcher between passes
    Restarting { at: i64 },
}
pub struct Line { pub at: i64, pub level: Level, pub msg: String }
```

`MonitorLayer`:

- `on_new_span`: for a span named `task`, store its `job` field in the span's
  extensions.
- `on_event`: walk the event's span scope to the nearest span that carries a job.
  - If there is none, or the job is `web`, ignore the event. `web` is a server, not a
    worker, and its request logs would drown its card.
  - Otherwise, format the event's `message` field, append it to the job's ring (capped
    at 20) and make it the job's `step`.
  - If the event carries integer fields `done` and `total`, set `progress`.

`main.rs` changes from `tracing_subscriber::fmt()…init()` to a `registry()` with the
same `fmt` layer and `EnvFilter`, plus `MonitorLayer`. The monitor sees only events that
the filter passes, which is `info` and above by default.

### State transitions

- `jobs::record(db, name, job)`: before running, set `Running { since: now }` and clear
  `progress`; after, set `Idle` (or `Watching` for `identify`, below) and clear
  `progress`.
- `jobs::supervise`: before its backoff sleep, set `Restarting { at: now + wait }`.
- The identify watcher wraps each pass in `jobs::record(db, "identify", …)`, so passes
  get history and the `Running` state. Between passes it sets `Watching { pending }`,
  the debouncer's pending folder count, whenever that count changes. `record`'s
  `job_run` write for `identify` is harmless, because no schedule reads that row.

### Progress fields

These are added to existing log lines only, with no new lines:

- identify (`run_pass`): the per-scene loop logs `done = i + 1, total = todo.len()` on
  the scene's line.
- refresh (`plab::refresh`): each filter term's search logs `done`/`total` over all of
  the terms.
- grab (`grab::run`): each rule logs `done`/`total` over the rules.

Prune and sweep show their step text only.

## History (`job_history`)

The migration takes `USER_VERSION` from 3 to 4:

```sql
CREATE TABLE job_history (
    id       INTEGER PRIMARY KEY,
    job      TEXT NOT NULL,
    started  INTEGER NOT NULL,
    finished INTEGER,          -- NULL while running
    ok       INTEGER,          -- NULL while running
    error    TEXT
);
CREATE INDEX job_history_job ON job_history (job, started DESC);
```

- `jobs::record` inserts a row at start and fills in `finished`/`ok`/`error` at the
  end. In that same transaction it deletes all but the newest 50 rows for the job.
- At daemon start (`commands::serve`), every row with `finished IS NULL` is closed as
  `finished = started, ok = 0, error = 'interrupted'`. A run cut off by a restart would
  otherwise show as running forever.
- `job_run` is unchanged. Scheduling keeps reading it.
- A one-shot command (`plab refresh`, say) writes history through `record` as it
  already writes `job_run`, so the page lists it among the job's runs. Its live state is
  in the other process and never shows.

## `GET /jobs.json`

```json
{"now": 1793501999, "jobs": [
  {"name": "identify", "state": "running", "since": 1793501900, "pending": null,
   "restart_at": null, "next": null,
   "step": {"at": 1793501990, "level": "INFO", "msg": "[812] llm guess, no code match yet"},
   "progress": [12, 40],
   "lines": [{"at": …, "level": "WARN", "msg": "…"}],
   "runs": [{"started": …, "finished": …, "ok": true, "error": null}]}
]}
```

- `state` is one of `idle`, `running`, `watching`, `restarting`. Each takes its own
  field (`since`, `pending`, `restart_at`); the others are null.
- `next` is `jobs::next_slot(schedule, now)` for sweep, refresh, grab and prune, and
  null for identify.
- `runs` holds the newest 10 rows of `job_history`.
- Jobs come in a fixed order: identify, sweep, refresh, grab, prune. A job the daemon is
  not running (a `--tasks` subset) is omitted. `serve` registers the jobs it starts in
  the monitor, and only registered jobs are listed.
- If the history read fails, it is logged and `runs` is `[]`. The live state is still
  served.
- Served by a match arm in `web::get` beside `/` and `/games`, with `Cache-Control:
  no-store`.

`WebState` gains a `monitor: Monitor` field, so tests can pass their own instead of the
global.

## `GET /jobs`

- Server-rendered by `page.rs` with the listing's `<head>`, theme and navbar. The
  navbar gains a "Jobs" link on every page.
- The body is an empty `x-data="plabJobs"` shell, with no job content rendered on the
  server. The first fetch fills it, so cards render in one place, in JS.
- `plabJobs` in `assets/page.js` fetches `/jobs.json` every 2 s. It stops while
  `document.hidden` and fetches immediately on `visibilitychange` back to visible. If a
  fetch fails, it shows a "plab not responding" alert and keeps polling.
- One daisyUI card per job:
  - **Header:** the name; a state badge (running is success; watching and idle are
    neutral; restarting is error, with a countdown to `restart_at`); then the time
    since `since` or until `next`.
  - **Body:** the `step` message and its age, then a `<progress>` with "12 / 40" when
    `progress` is set. The last run's result follows, with an error in a collapsible
    `<pre>`.
  - **Collapses:** "Log" lists `lines`, newest first, with the level colored; "History"
    is a table of `runs` (start, duration, ok/error), where an `interrupted` run reads
    as such.

## Testing

- `monitor.rs`, against a `Registry` with only `MonitorLayer`:
  - an event in `task{job="grab"}` sets the step and appends a line;
  - the ring caps at 20;
  - `done`/`total` set the progress;
  - an event in a span nested under the task span is still attributed to the job;
  - events outside any task span, and in `job="web"`, are ignored.
- `jobs.rs`: `record` writes a `job_history` row with ok/error and moves the monitor
  state `Running` → `Idle`; history keeps 50 rows per job; closing unfinished rows marks
  them `interrupted`.
- `db`: the migration test, at the new `USER_VERSION`.
- `web_tests.rs`: `/jobs.json` from a seeded monitor and DB has the shape and order
  above and omits unregistered jobs; `/jobs` is 200 HTML with the navbar's Jobs link.
- By hand, after deploying to galactica:
  - open `/jobs` during a watcher pass (copy a file into the library) and watch the
    step and progress move;
  - restart `plab` during a refresh and check that the run shows as interrupted.

## Out of scope

- Starting, stopping or retrying a job from the page.
- A running-count badge on the navbar's Jobs link. Keeping it live would make every
  page poll `/jobs.json`. The link is plain.
- Streaming (SSE or websockets). 2 s polling of a few KB is enough.
- Log lines beyond the in-memory 20 per job; the journal still has everything.
