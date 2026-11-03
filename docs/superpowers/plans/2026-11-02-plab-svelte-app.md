# plab Svelte App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace plab's server-rendered page (`page.rs` and Alpine) with a Svelte 5 single-page app over a JSON API and one SSE stream, and add the jobs monitor.

**Architecture:** Rust keeps every domain rule and serves typed JSON under `/api/*`, a broadcast-backed SSE stream at `/api/events`, the built app's hashed files under `/assets/`, and `index.html` for every other path. A `tracing` layer records what each background job is doing, and `job_history` records its runs. The app in `packages/plab/ui/` is plain Svelte 5 + Vite + TypeScript, built by Nix as `plab.ui` and served from `PLAB_STATIC_DIR`.

**Tech Stack:** Rust (axum 0.8, tokio broadcast, tracing-subscriber `Layer`, rusqlite); Svelte 5 (runes), Vite, TypeScript, Tailwind 4 + daisyUI 5 via `@tailwindcss/vite`, vitest, svelte-check; Nix `buildNpmPackage`.

**Spec:** `docs/superpowers/specs/2026-11-02-plab-svelte-app-design.md`. It amends `docs/superpowers/specs/2026-11-02-plab-jobs-monitor-design.md`, which this plan also implements. Read both before starting.

## Global Constraints

- **One commit on master.** Tasks commit locally as work-in-progress and are **not pushed**. Task 12 squashes them into one commit, `feat(galactica): plab is a Svelte app over a JSON API and SSE`, and pushes. Never push before Task 12. Never branch and never use a worktree: this repo commits straight to master.
- **Record the base first.** Before Task 1, run `git rev-parse HEAD > /tmp/claude-1000/plab-svelte-base` from the repo root. That is the commit holding this plan, and Task 12 squashes everything after it.
- **Rust dev loop,** from `packages/plab/`: `nix shell nixpkgs#cargo nixpkgs#rustc nixpkgs#gcc nixpkgs#rustfmt nixpkgs#clippy -c cargo test <filter>`, written below as `cargo test …`. `cargo fmt` uses the same shell. The full gate from the repo root is `nix build .#plab`, which runs the whole suite in the sandbox.
- **UI dev loop,** from `packages/plab/ui/`: `nix shell --inputs-from /home/arosenfeld/Code/nixos nixpkgs#nodejs -c npm <cmd>`, written below as `npm …`.
- **New files are invisible to `nix build` until `git add`ed.** Use `git add -N` if you build before committing.
- **Commit messages:** conventional, `<type>(galactica): …`. Never mention Claude.
- **Domain logic stays in Rust.** The app never parses a title, ranks topics, or decides a status's meaning. It only formats numbers and times, counts facets and filters.
- **JSON keys:** camelCase for the list, grab and event shapes. The jobs entry keeps the jobs spec's snake_case keys exactly (`restart_at`).
- **Keep today's look:** daisyUI `luxury` theme, today's class names, and today's labels and texts ("Add to Vault", "Queued ⏳", "Showing N of M", …).
- **Svelte:** runes only (`$state`, `$derived`, `$effect`, `$props`). Use event attributes (`onclick`), not `on:click`. Pass class arrays (`class={[…]}`), not `class:` directives with exotic names. `svelte-check` runs with `--fail-on-warnings`, so fix a11y warnings rather than ignoring them. The one allowed ignore is the `<video>` caption warning.
- **Dependencies:** UI devDependencies are exactly `svelte`, `vite`, `@sveltejs/vite-plugin-svelte`, `tailwindcss`, `@tailwindcss/vite`, `daisyui`, `typescript`, `svelte-check`, `vitest`. There are no runtime dependencies, and no new Rust crates.

---

## File map

**Rust (`packages/plab/`):**
- Create `src/db/schema_v4.sql`: the `job_history` table.
- Modify `src/db/mod.rs`: migration to v4, `JobRunRow`, `history_start`, `history_finish`, `close_interrupted`, `job_history`.
- Create `src/monitor.rs`: `Monitor`, `JobLive`, `LiveState`, `Line`, `MonitorLayer`, `global()`.
- Modify `src/main.rs`: a registry subscriber with the monitor layer; module list.
- Modify `src/jobs.rs`: `record` and `supervise` drive the monitor and history; `schedule(name)`.
- Modify `src/identify/watch.rs`, `src/identify/mod.rs`, `src/plab.rs`, `src/grab.rs`: the `Watching` state, progress fields, and publishing events.
- Modify `src/commands.rs`: `serve` closes interrupted runs, registers jobs, creates `Events`, spawns the pump.
- Create `src/api.rs` and `src/api_tests.rs`: the JSON shapes (moved from `page.rs`: `weight`, `score`, `production`, `Downloads`, `TOPIC_URL`).
- Create `src/events.rs` and `src/events_tests.rs`: `Event`, `Events`, the global sender, SSE, the pump.
- Modify `src/web.rs` and `src/web_tests.rs`: `/api/*`, `/assets/*`, the index fallback; page routes removed.
- Delete `src/page.rs`, `src/page_tests.rs`, `assets/`, and `tests/fixtures/golden_page*.html`.
- Modify `package.nix`: `passthru.ui`, and drop `./assets` from the fileset.

**UI (`packages/plab/ui/`):** `package.json`, `package-lock.json`, `vite.config.ts`, `svelte.config.js`, `tsconfig.json`, `index.html`, and under `src/`:
- `main.ts`, `app.css`, `vite-env.d.ts`, `App.svelte`
- `lib/`: `types.ts`, `api.ts`, `storage.ts`, `format.ts`, `status.ts`, `stream.ts`, `jobtime.ts`, `route.ts`, `filters.ts`, `seen.ts`, `reducer.ts` (all pure and each with a `*.test.ts`), plus `router.svelte.ts`, `filters.svelte.ts`, `topics.svelte.ts`, `events.svelte.ts`, `jobs.svelte.ts`, `clock.svelte.ts`
- `components/`: `Navbar`, `ListView`, `FilterBar`, `Card`, `StatusBadge`, `AddButton`, `TagPill`, `GrabsStrip`, `Gallery`, `Player`, `NewReleasesPill`, `JobsView`, `JobCard`

**Nix and docs:** `modules/hosts/galactica/services/plab/default.nix`, `justfile`, `CLAUDE.md`.

---

### Task 1: `job_history` in the database

**Files:**
- Create: `packages/plab/src/db/schema_v4.sql`
- Modify: `packages/plab/src/db/mod.rs` (constants near line 17, `migrate` near line 173, job methods near line 833, tests module at the end)

**Interfaces:**
- Produces: `pub struct JobRunRow { started: i64, finished: Option<i64>, ok: Option<bool>, error: Option<String> }` (Serialize, Clone, PartialEq, Debug), plus these `Db` methods:
  - `history_start(&self, job: &str, now: i64) -> Result<i64>`
  - `history_finish(&self, id: i64, job: &str, now: i64, error: Option<&str>) -> Result<()>`
  - `close_interrupted(&self) -> Result<usize>`
  - `job_history(&self, job: &str, limit: usize) -> Result<Vec<JobRunRow>>`

- [ ] **Step 1: Write the failing tests** (append to the `mod tests` at the end of `src/db/mod.rs`)

```rust
    #[test]
    fn job_history_records_runs_newest_first() {
        let db = Db::open_in_memory().unwrap();
        let a = db.history_start("grab", 100).unwrap();
        db.history_finish(a, "grab", 110, None).unwrap();
        let b = db.history_start("grab", 200).unwrap();
        db.history_finish(b, "grab", 230, Some("boom")).unwrap();
        db.history_start("prune", 300).unwrap();
        assert_eq!(
            db.job_history("grab", 10).unwrap(),
            vec![
                JobRunRow { started: 200, finished: Some(230), ok: Some(false), error: Some("boom".into()) },
                JobRunRow { started: 100, finished: Some(110), ok: Some(true), error: None },
            ]
        );
        assert_eq!(
            db.job_history("prune", 10).unwrap(),
            vec![JobRunRow { started: 300, finished: None, ok: None, error: None }]
        );
    }

    #[test]
    fn job_history_keeps_fifty_per_job() {
        let db = Db::open_in_memory().unwrap();
        for t in 0..60 {
            let id = db.history_start("grab", t).unwrap();
            db.history_finish(id, "grab", t, None).unwrap();
        }
        let other = db.history_start("prune", 0).unwrap();
        db.history_finish(other, "prune", 0, None).unwrap();
        let rows = db.job_history("grab", 100).unwrap();
        assert_eq!(rows.len(), 50);
        assert_eq!((rows[0].started, rows[49].started), (59, 10));
        assert_eq!(db.job_history("prune", 100).unwrap().len(), 1);
    }

    #[test]
    fn unfinished_runs_close_as_interrupted() {
        let db = Db::open_in_memory().unwrap();
        db.history_start("refresh", 500).unwrap();
        assert_eq!(db.close_interrupted().unwrap(), 1);
        assert_eq!(
            db.job_history("refresh", 1).unwrap(),
            vec![JobRunRow { started: 500, finished: Some(500), ok: Some(false), error: Some("interrupted".into()) }]
        );
        assert_eq!(db.close_interrupted().unwrap(), 0);
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cargo test db::tests::job_history db::tests::unfinished_runs`
Expected: compile errors, because `JobRunRow` and `history_start` don't exist yet.

- [ ] **Step 3: Implement**

`src/db/schema_v4.sql`:

```sql
-- One row per job run, for the jobs page; jobs::record writes it. Kept to the newest 50
-- per job. finished/ok are NULL while the run is in progress.
CREATE TABLE job_history (
    id       INTEGER PRIMARY KEY,
    job      TEXT NOT NULL,
    started  INTEGER NOT NULL,
    finished INTEGER,
    ok       INTEGER,
    error    TEXT
);
CREATE INDEX job_history_job ON job_history (job, started DESC);
```

In `src/db/mod.rs`, change `const USER_VERSION: i64 = 3;` to `4`. Under `SCHEMA_V3`, add:

```rust
const SCHEMA_V4: &str = include_str!("schema_v4.sql");
```

In `migrate`, after the `if from < 3 { … }` block, add:

```rust
    if from < 4 {
        tx.execute_batch(SCHEMA_V4)?;
    }
```

Above `impl Db`, add:

```rust
/// One run of a job, for the jobs page; `finished` and `ok` are None while it runs.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct JobRunRow {
    pub started: i64,
    pub finished: Option<i64>,
    pub ok: Option<bool>,
    pub error: Option<String>,
}

/// Runs kept per job in `job_history`.
const HISTORY_KEEP: i64 = 50;
```

After `job_finished`, add:

```rust
    pub fn history_start(&self, job: &str, now: i64) -> Result<i64> {
        self.with(|c| {
            c.execute(
                "INSERT INTO job_history (job, started) VALUES (?1, ?2)",
                params![job, now],
            )?;
            Ok(c.last_insert_rowid())
        })
    }

    /// Close run `id`, then drop all but the job's newest `HISTORY_KEEP` runs.
    pub fn history_finish(&self, id: i64, job: &str, now: i64, error: Option<&str>) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute(
                "UPDATE job_history SET finished = ?2, ok = ?3, error = ?4 WHERE id = ?1",
                params![id, now, error.is_none(), error],
            )?;
            tx.execute(
                "DELETE FROM job_history WHERE job = ?1 AND id NOT IN
                   (SELECT id FROM job_history WHERE job = ?1
                    ORDER BY started DESC, id DESC LIMIT ?2)",
                params![job, HISTORY_KEEP],
            )?;
            tx.commit()?;
            Ok(())
        })
    }

    /// At daemon start: a run left unfinished was cut off by the restart.
    pub fn close_interrupted(&self) -> Result<usize> {
        self.with(|c| {
            Ok(c.execute(
                "UPDATE job_history SET finished = started, ok = 0, error = 'interrupted'
                 WHERE finished IS NULL",
                [],
            )?)
        })
    }

    pub fn job_history(&self, job: &str, limit: usize) -> Result<Vec<JobRunRow>> {
        self.with(|c| {
            let mut stmt = c.prepare(
                "SELECT started, finished, ok, error FROM job_history WHERE job = ?1
                 ORDER BY started DESC, id DESC LIMIT ?2",
            )?;
            let rows = stmt
                .query_map(params![job, limit as i64], |r| {
                    Ok(JobRunRow {
                        started: r.get(0)?,
                        finished: r.get(1)?,
                        ok: r.get(2)?,
                        error: r.get(3)?,
                    })
                })?
                .collect::<rusqlite::Result<Vec<_>>>()?;
            Ok(rows)
        })
    }
```

- [ ] **Step 4: Run the db tests**

Run: `cargo test db::`
Expected: all pass. The existing migration tests assert `USER_VERSION`, so they now check 4.

- [ ] **Step 5: Commit (local only)**

```bash
git add packages/plab/src/db/schema_v4.sql packages/plab/src/db/mod.rs
git commit -m "feat(galactica): plab records each job run in job_history"
```

---

### Task 2: the monitor layer

**Files:**
- Create: `packages/plab/src/monitor.rs`
- Modify: `packages/plab/src/main.rs` (module list; subscriber init near line 89)

**Interfaces:**
- Produces, in `crate::monitor`:
  - `pub struct Line { pub at: i64, pub level: String, pub msg: String }` (Serialize, Clone, PartialEq, Debug)
  - `pub enum LiveState { Idle, Running { since: i64 }, Watching { pending: usize }, Restarting { at: i64 } }` (Copy, PartialEq, Debug)
  - `pub struct JobLive { pub state: LiveState, pub step: Option<Line>, pub progress: Option<(u64, u64)>, pub lines: VecDeque<Line> }` (Clone, PartialEq, Debug, Default = Idle)
  - `#[derive(Clone, Default)] pub struct Monitor` with these methods:
    - `register(&self, job: &str)`
    - `set_state(&self, job: &str, state: LiveState)`. It clears progress and is a no-op for an unregistered job.
    - `get(&self, job: &str) -> Option<JobLive>`
    - `snapshot(&self) -> Vec<(String, JobLive)>`. Registered jobs only, in the order `ORDER = ["identify", "sweep", "refresh", "grab", "prune"]`.
  - `pub fn global() -> &'static Monitor`
  - `pub struct MonitorLayer`, with `MonitorLayer::new(Monitor)`

- [ ] **Step 1: Write the module with its tests**

`src/monitor.rs`:

```rust
//! What each background job is doing now, for /api/jobs. `jobs` sets a job's state; its
//! step and recent lines are its own tracing events, attributed to it by the enclosing
//! `task{job=…}` span that `jobs::supervise` opens. So the page shows what the journal
//! shows. Design: docs/superpowers/specs/2026-11-02-plab-jobs-monitor-design.md.

use std::collections::{HashMap, VecDeque};
use std::fmt::Debug;
use std::sync::{Arc, Mutex, OnceLock};

use tracing::field::{Field, Visit};
use tracing::span::{Attributes, Id};
use tracing::{Event, Subscriber};
use tracing_subscriber::layer::{Context, Layer};
use tracing_subscriber::registry::LookupSpan;

/// Lines kept per job.
pub const RING: usize = 20;
/// The jobs page's order; a job not here is never listed.
pub const ORDER: [&str; 5] = ["identify", "sweep", "refresh", "grab", "prune"];

#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct Line {
    pub at: i64,
    pub level: String,
    pub msg: String,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum LiveState {
    Idle,
    Running { since: i64 },
    /// The identify watcher between passes, with its pending folder count.
    Watching { pending: usize },
    Restarting { at: i64 },
}

#[derive(Debug, Clone, PartialEq)]
pub struct JobLive {
    pub state: LiveState,
    /// The latest event.
    pub step: Option<Line>,
    /// (done, total), from an event's `done` and `total` fields.
    pub progress: Option<(u64, u64)>,
    pub lines: VecDeque<Line>,
}

impl Default for JobLive {
    fn default() -> Self {
        JobLive { state: LiveState::Idle, step: None, progress: None, lines: VecDeque::new() }
    }
}

#[derive(Clone, Default)]
pub struct Monitor(Arc<Mutex<HashMap<String, JobLive>>>);

impl Monitor {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, JobLive>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// List `job`: `serve` registers each job it starts.
    pub fn register(&self, job: &str) {
        self.lock().entry(job.to_string()).or_default();
    }

    /// Set a registered job's state and clear its progress; an unregistered job is ignored.
    pub fn set_state(&self, job: &str, state: LiveState) {
        if let Some(l) = self.lock().get_mut(job) {
            l.state = state;
            l.progress = None;
        }
    }

    pub fn get(&self, job: &str) -> Option<JobLive> {
        self.lock().get(job).cloned()
    }

    /// Registered jobs in `ORDER`.
    pub fn snapshot(&self) -> Vec<(String, JobLive)> {
        let m = self.lock();
        ORDER
            .iter()
            .filter_map(|n| m.get(*n).map(|l| (n.to_string(), l.clone())))
            .collect()
    }

    fn event(&self, job: &str, line: Line, progress: Option<(u64, u64)>) {
        let mut m = self.lock();
        let Some(l) = m.get_mut(job) else { return };
        if progress.is_some() {
            l.progress = progress;
        }
        l.lines.push_back(line.clone());
        if l.lines.len() > RING {
            l.lines.pop_front();
        }
        l.step = Some(line);
    }
}

/// The process's monitor: the layer in `main` and `jobs` both use it.
pub fn global() -> &'static Monitor {
    static M: OnceLock<Monitor> = OnceLock::new();
    M.get_or_init(Monitor::default)
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

pub struct MonitorLayer {
    monitor: Monitor,
}

impl MonitorLayer {
    pub fn new(monitor: Monitor) -> Self {
        MonitorLayer { monitor }
    }
}

/// A `task` span's job, kept in the span's extensions.
struct JobName(String);

#[derive(Default)]
struct Fields {
    message: String,
    job: Option<String>,
    done: Option<u64>,
    total: Option<u64>,
}

impl Visit for Fields {
    fn record_debug(&mut self, f: &Field, v: &dyn Debug) {
        match f.name() {
            "message" => self.message = format!("{v:?}"),
            "job" => self.job = Some(format!("{v:?}")),
            _ => {}
        }
    }

    fn record_str(&mut self, f: &Field, v: &str) {
        match f.name() {
            "message" => self.message = v.to_string(),
            "job" => self.job = Some(v.to_string()),
            _ => {}
        }
    }

    fn record_u64(&mut self, f: &Field, v: u64) {
        match f.name() {
            "done" => self.done = Some(v),
            "total" => self.total = Some(v),
            _ => {}
        }
    }

    fn record_i64(&mut self, f: &Field, v: i64) {
        self.record_u64(f, v.max(0) as u64);
    }
}

impl<S> Layer<S> for MonitorLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(&self, attrs: &Attributes<'_>, id: &Id, ctx: Context<'_, S>) {
        if attrs.metadata().name() != "task" {
            return;
        }
        let mut f = Fields::default();
        attrs.record(&mut f);
        if let (Some(job), Some(span)) = (f.job, ctx.span(id)) {
            span.extensions_mut().insert(JobName(job));
        }
    }

    fn on_event(&self, event: &Event<'_>, ctx: Context<'_, S>) {
        let Some(scope) = ctx.event_scope(event) else { return };
        let Some(job) = scope
            .into_iter()
            .find_map(|s| s.extensions().get::<JobName>().map(|j| j.0.clone()))
        else {
            return;
        };
        // web is a server, not a worker: its request lines would drown its card.
        if job == "web" {
            return;
        }
        let mut f = Fields::default();
        event.record(&mut f);
        let line = Line {
            at: unix_now(),
            level: event.metadata().level().to_string(),
            msg: f.message,
        };
        self.monitor.event(&job, line, f.done.zip(f.total));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tracing_subscriber::prelude::*;

    fn run(m: &Monitor, f: impl FnOnce()) {
        let sub = tracing_subscriber::registry().with(MonitorLayer::new(m.clone()));
        tracing::subscriber::with_default(sub, f);
    }

    fn in_task(job: &str, f: impl FnOnce()) {
        let span = tracing::info_span!("task", job = %job);
        let _g = span.enter();
        f();
    }

    #[test]
    fn an_event_in_a_task_span_sets_the_step_and_a_line() {
        let m = Monitor::default();
        m.register("grab");
        run(&m, || in_task("grab", || tracing::info!("[Studio] searching")));
        let l = m.get("grab").unwrap();
        let step = l.step.unwrap();
        assert_eq!((step.msg.as_str(), step.level.as_str()), ("[Studio] searching", "INFO"));
        assert_eq!(l.lines.len(), 1);
    }

    #[test]
    fn the_ring_keeps_the_last_twenty() {
        let m = Monitor::default();
        m.register("prune");
        run(&m, || in_task("prune", || (0..25).for_each(|i| tracing::info!("line {i}"))));
        let l = m.get("prune").unwrap();
        assert_eq!(l.lines.len(), RING);
        assert_eq!(l.lines.front().unwrap().msg, "line 5");
        assert_eq!(l.lines.back().unwrap().msg, "line 24");
    }

    #[test]
    fn done_and_total_set_progress_and_a_state_change_clears_it() {
        let m = Monitor::default();
        m.register("identify");
        run(&m, || in_task("identify", || tracing::info!(done = 3usize, total = 7usize, "[9] scene")));
        assert_eq!(m.get("identify").unwrap().progress, Some((3, 7)));
        m.set_state("identify", LiveState::Watching { pending: 1 });
        let l = m.get("identify").unwrap();
        assert_eq!((l.progress, l.state), (None, LiveState::Watching { pending: 1 }));
    }

    #[test]
    fn a_nested_span_still_belongs_to_the_job() {
        let m = Monitor::default();
        m.register("refresh");
        run(&m, || {
            in_task("refresh", || {
                let inner = tracing::info_span!("search");
                let _i = inner.enter();
                tracing::info!("deep");
            })
        });
        assert_eq!(m.get("refresh").unwrap().step.unwrap().msg, "deep");
    }

    #[test]
    fn events_outside_tasks_and_in_web_are_ignored() {
        let m = Monitor::default();
        m.register("prune");
        m.register("web");
        run(&m, || {
            tracing::info!("no span");
            in_task("web", || tracing::info!("GET /"));
        });
        assert!(m.get("prune").unwrap().lines.is_empty());
        assert!(m.get("web").unwrap().lines.is_empty());
    }

    #[test]
    fn only_registered_jobs_are_listed_in_order() {
        let m = Monitor::default();
        m.set_state("grab", LiveState::Running { since: 1 });
        for j in ["prune", "identify", "grab", "stream-web"] {
            m.register(j);
        }
        let names: Vec<String> = m.snapshot().into_iter().map(|(n, _)| n).collect();
        assert_eq!(names, ["identify", "grab", "prune"]);
        assert_eq!(m.get("grab").unwrap().state, LiveState::Idle);
    }
}
```

- [ ] **Step 2: Wire it into `main.rs`**

Add `mod monitor;` to the module list in alphabetical order, after `mod llm;`. Then replace the `tracing_subscriber::fmt()…init();` statement at the top of `main` with:

```rust
    use tracing_subscriber::prelude::*;
    // The filter is a global layer, so the monitor sees exactly what the journal does.
    tracing_subscriber::registry()
        .with(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .with(
            tracing_subscriber::fmt::layer()
                .with_writer(std::io::stderr)
                .with_ansi(false)
                .without_time(), // the journal timestamps lines
        )
        .with(monitor::MonitorLayer::new(monitor::global().clone()))
        .init();
```

- [ ] **Step 3: Run the tests**

Run: `cargo test monitor::`
Expected: 6 pass. Unused-code warnings for `global` and `get` are fine until Task 3.

- [ ] **Step 4: Commit (local only)**

```bash
git add packages/plab/src/monitor.rs packages/plab/src/main.rs
git commit -m "feat(galactica): plab monitors its jobs from their tracing events"
```

---

### Task 3: jobs drive the monitor and history

**Files:**
- Modify: `packages/plab/src/jobs.rs` (`record`, `supervise`, the new `schedule`, tests)
- Modify: `packages/plab/src/identify/watch.rs` (`Debouncer::pending`, the `watch` loop)
- Modify: `packages/plab/src/identify/mod.rs` (the scene loop near line 856)
- Modify: `packages/plab/src/plab.rs` (`refresh`'s term loop near line 111)
- Modify: `packages/plab/src/grab.rs` (`run`'s rule loop near line 257)
- Modify: `packages/plab/src/commands.rs` (`serve`, near line 194)

**Interfaces:**
- Consumes: the Task 1 `Db` history methods and the Task 2 `monitor::{global, LiveState}`.
- Produces: `pub fn jobs::schedule(name: &str) -> Option<Schedule>` (the schedules of sweep, refresh, grab and prune; None for anything else), and `record` writing `job_history` and monitor state.

- [ ] **Step 1: Write the failing test** (in `jobs.rs` `mod tests`)

```rust
    #[tokio::test]
    async fn record_writes_history_and_moves_the_monitor() {
        use crate::monitor::{LiveState, global};
        let db = Db::open_in_memory().unwrap();
        let m = global();
        m.register("test-record"); // a name no other test uses: the monitor is global
        record(&db, "test-record", async {
            assert!(matches!(m.get("test-record").unwrap().state, LiveState::Running { .. }));
            Ok(())
        })
        .await
        .unwrap();
        assert_eq!(m.get("test-record").unwrap().state, LiveState::Idle);
        let _ = record(&db, "test-record", async { anyhow::bail!("boom") }).await;
        let runs = db.job_history("test-record", 10).unwrap();
        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].error.as_deref(), Some("boom"));
        assert_eq!(runs[1].ok, Some(true));
    }

    #[test]
    fn schedules_by_name() {
        assert_eq!(schedule("prune").map(|s| s.period), Some(PRUNE.period));
        assert_eq!(schedule("sweep").map(|s| s.offset), Some(SWEEP.offset));
        assert!(schedule("identify").is_none());
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cargo test jobs::tests::record_writes jobs::tests::schedules`
Expected: compile error, because `schedule` doesn't exist yet.

- [ ] **Step 3: Implement in `jobs.rs`**

Replace `record` with:

```rust
/// Run `job` once, recorded in `job_run` (which scheduling reads) and `job_history` (which
/// the jobs page reads) as `name`, with its live state in the monitor; its error is
/// returned as well as recorded. A one-shot command records the same way, so a manual run
/// counts as the slot's and shows in the history.
pub async fn record<Fut>(db: &Db, name: &str, job: Fut) -> anyhow::Result<()>
where
    Fut: Future<Output = anyhow::Result<()>>,
{
    let mon = crate::monitor::global();
    let started = unix_now();
    db.job_started(name, started)?;
    let run = db.history_start(name, started)?;
    mon.set_state(name, LiveState::Running { since: started });
    let res = job.await;
    let error = res.as_ref().err().map(|e| format!("{e:#}"));
    let finished = unix_now();
    // The watcher goes back to watching; it refreshes the pending count itself.
    mon.set_state(
        name,
        if name == "identify" { LiveState::Watching { pending: 0 } } else { LiveState::Idle },
    );
    db.history_finish(run, name, finished, error.as_deref())?;
    db.job_finished(name, finished, error.as_deref())?;
    res
}

/// A periodic job's schedule by name; None for the identify watcher.
pub fn schedule(name: &str) -> Option<Schedule> {
    match name {
        "sweep" => Some(SWEEP),
        "refresh" => Some(REFRESH),
        "grab" => Some(GRAB),
        "prune" => Some(PRUNE),
        _ => None,
    }
}
```

Add `use crate::monitor::LiveState;` to the imports. In `supervise`, replace `tokio::time::sleep(wait).await;` with:

```rust
        let mon = crate::monitor::global();
        mon.set_state(name, LiveState::Restarting { at: unix_now() + wait.as_secs() as i64 });
        tokio::time::sleep(wait).await;
        mon.set_state(name, LiveState::Idle);
```

- [ ] **Step 4: Have the watcher record its passes and report `Watching`**

In `identify/watch.rs`, add to `impl Debouncer`:

```rust
    /// How many folders wait for the quiet period.
    pub fn pending(&self) -> usize {
        self.pending.len()
    }
```

In `watch`, replace everything from `let mut tick = …` to the end of the `loop` with:

```rust
    let mut tick = tokio::time::interval(Duration::from_secs(10));
    let mon = crate::monitor::global();
    let mut shown = usize::MAX; // forces the first Watching below
    loop {
        tokio::select! {
            ev = rx.recv() => match ev {
                Some(Ok(dir)) => debouncer.add(dir, Instant::now()),
                Some(Err(e)) => return Err(anyhow::anyhow!("watcher failed: {e}")),
                None => anyhow::bail!("watcher channel closed"),
            },
            _ = tick.tick() => {}
        }
        if let Some(dirs) = debouncer.ready(Instant::now()) {
            tracing::info!("changed: {dirs:?}");
            let pass = super::locked_pass(c, db, pass_lock, Some(dirs));
            if let Err(e) = crate::jobs::record(db, "identify", pass).await {
                tracing::error!("pass failed: {e:#}");
            }
            shown = usize::MAX; // record left Watching { pending: 0 }
        }
        if debouncer.pending() != shown {
            shown = debouncer.pending();
            mon.set_state("identify", crate::monitor::LiveState::Watching { pending: shown });
        }
    }
```

- [ ] **Step 5: Add the progress fields**

In `identify/mod.rs`, change the scene loop's head `for scene in &todo {` to:

```rust
    for (i, scene) in todo.iter().enumerate() {
        tracing::info!(done = i + 1, total = todo.len(), "[{}] scene {}/{}", scene.id, i + 1, todo.len());
```

(The loop body stays as it is.)

In `plab.rs` `refresh`, just before `for (name, terms) in &filters {`, add:

```rust
    let total: usize = filters.iter().map(|(_, terms)| terms.len()).sum();
    let mut done = 0usize;
```

As the first line of the inner `for term in terms {`, add:

```rust
            done += 1;
            info!(done, total, "search {term:?}");
```

In `grab.rs` `run`, change `for rule in rules {` to:

```rust
    for (i, rule) in rules.iter().enumerate() {
        tracing::info!(done = i + 1, total = rules.len(), "[{}] searching", rule.name);
```

- [ ] **Step 6: Make `serve` close interrupted runs and register its jobs**

In `commands.rs` `serve`, right after `let app = Arc::new(App::build(cfg)?);`, add:

```rust
    if let Err(e) = app.db.close_interrupted() {
        tracing::warn!("closing interrupted job runs: {e:#}");
    }
    // Only the jobs this daemon runs are listed on the jobs page.
    let mon = crate::monitor::global();
    for task in &tasks {
        match task {
            Task::Identify => {
                mon.register("identify");
                mon.register("sweep");
            }
            Task::Refresh => mon.register("refresh"),
            Task::Grab => mon.register("grab"),
            Task::Prune => mon.register("prune"),
            Task::Web => {}
        }
    }
```

If `tasks` is moved by the following `for task in tasks`, this borrow must come before it, which it does.

- [ ] **Step 7: Run the suite**

Run: `cargo test`
Expected: all pass. If an identify test asserted the exact log lines of a pass, update it for the new `[id] scene i/n` line rather than removing the line.

- [ ] **Step 8: Commit (local only)**

```bash
git add -u packages/plab/src
git commit -m "feat(galactica): plab jobs report state, progress and history to the monitor"
```

---

### Task 4: the JSON shapes (`api.rs`)

**Files:**
- Create: `packages/plab/src/api.rs`, `packages/plab/src/api_tests.rs`
- Modify: `packages/plab/src/page.rs`. Remove `weight`, `score`, `production`, `TOPIC_URL`, `Downloads` and its `impl`, and import them from `crate::api` instead. `page.rs` is deleted in Task 6, so this only keeps it compiling until then.
- Modify: `packages/plab/src/web.rs` (import `Downloads` from `crate::api`)
- Modify: `packages/plab/src/main.rs` (add `mod api;`)

**Interfaces:**
- Consumes: `monitor::{Monitor, JobLive, LiveState, Line}`, `db::JobRunRow`, `jobs::{schedule, next_slot}`.
- Produces, in `crate::api`:
  - `pub const TOPIC_URL: &str`
  - `pub fn score(&Listed) -> f64` and `pub fn production(&Listed) -> Option<&str>`
  - `pub struct Downloads { by_topic: HashMap<u64, Status>, grabs: Vec<(DownloadRow, Status)>, stash: Option<String> }` (Debug, Default), with `pub(crate) fn link(&self, &Status) -> Option<String>` and `pub fn status_of(&self, &Status) -> StatusDto`
  - `#[serde(tag = "kind", rename_all = "camelCase")] pub enum StatusDto { Queued, Downloading { percent: u8 }, Added, InStash { link: Option<String> }, Identified { label: String, more: usize, guess: bool, link: Option<String> }, Failed { reason: &'static str, detail: String } }` (Serialize, Clone, PartialEq, Debug)
  - `pub fn status(&Status, link: Option<String>) -> StatusDto`
  - `pub struct SearchReply { pub query: String, pub error: Option<String> }`
  - `pub fn list(listing: &Listing, added: &HashSet<u64>, queued: &HashSet<u64>, now: i64, section: Section, downloads: &Downloads, search: Option<SearchReply>) -> ListDto`
  - `pub fn grabs(&Downloads, now: i64) -> GrabsDto`
  - `pub struct JobDto { name, state: &'static str, since, pending, restart_at, next, step, progress, lines, runs }` (Serialize, Clone, PartialEq, Debug)
  - `pub fn job(name: &str, live: &JobLive, db: &Db, now: i64) -> JobDto` and `pub fn jobs(&Monitor, &Db, now: i64) -> JobsDto`

- [ ] **Step 1: Write the failing tests**

`src/api_tests.rs`:

```rust
use super::*;
use crate::db::{DownloadRow, Listed, Listing, Production, Section, Topic};
use crate::provenance::{Failure, Status};
use crate::tracker::parse::Row;
use serde_json::{Value, json};

const COVER: &str = "https://i128.fastpic.org/big/2026/1004/19/cover.jpg";

fn row(id: u64, title: &str, seeders: u32) -> Row {
    Row { id, title: title.into(), forum: 1875, size: 2048, seeders, leechers: 1, completed: 0, added: 1000 }
}

fn listed(row: Row, class: Option<&str>, images: Option<&[&str]>) -> Listed {
    Listed {
        topic: Topic {
            row,
            images: images.map(|v| v.iter().map(|s| s.to_string()).collect()),
            production: class.map(|c| Production { class: c.into(), confidence: None }),
        },
        filters: vec![],
        curated_reason: None,
    }
}

fn listing(topics: Vec<Listed>) -> Listing {
    Listing { updated: 900, filters: vec!["couples".into()], topics }
}

fn reply(l: &Listing, added: &[u64], queued: &[u64], d: &Downloads, search: Option<SearchReply>) -> Value {
    let added = added.iter().copied().collect();
    let queued = queued.iter().copied().collect();
    serde_json::to_value(list(l, &added, &queued, 5000, Section::Video, d, search)).unwrap()
}

fn ids(v: &Value) -> Vec<u64> {
    v["topics"].as_array().unwrap().iter().map(|t| t["id"].as_u64().unwrap()).collect()
}

#[test]
fn topics_rank_by_production_weighted_seeders() {
    // industrial 40 × 0.25 = 10 < amateur 10 × 1.5 = 15 < unclassified 20 × 1.0
    let l = listing(vec![
        listed(row(1, "A", 40), Some("industrial"), None),
        listed(row(2, "B", 10), Some("amateur"), None),
        listed(row(3, "C", 20), None, None),
    ]);
    let v = reply(&l, &[], &[], &Downloads::default(), None);
    assert_eq!(ids(&v), [3, 2, 1]);
    assert_eq!(v["topics"][0]["production"], Value::Null);
    assert_eq!(v["topics"][1]["production"], "amateur");
    assert_eq!(v["topics"][2]["production"], "industrial");
}

#[test]
fn artistic_is_the_name_of_pro_artistic() {
    let l = listing(vec![listed(row(1, "A", 1), Some("pro_artistic"), None)]);
    assert_eq!(reply(&l, &[], &[], &Downloads::default(), None)["topics"][0]["production"], "artistic");
}

#[test]
fn a_topic_carries_its_row_and_labels() {
    let title = "[Studio Name] Alice, Bob - A Scene Title (2026) [1080p]";
    let l = listing(vec![listed(row(7, title, 3), None, None)]);
    let t = &reply(&l, &[], &[], &Downloads::default(), None)["topics"][0];
    let lab = crate::labels::labels(title, 1875);
    assert_eq!(t["title"], title);
    assert_eq!(t["name"], lab.name);
    assert_eq!(t["studio"], json!(lab.studio));
    assert_eq!(t["quality"], json!(lab.quality));
    assert_eq!(t["category"], lab.category);
    assert_eq!(t["tags"], json!(lab.tags));
    assert_eq!((t["size"].clone(), t["seeders"].clone(), t["leechers"].clone(), t["added"].clone()), (json!(2048), json!(3), json!(1), json!(1000)));
    assert_eq!(t["filters"], json!([]));
}

#[test]
fn images_are_null_empty_or_keys() {
    let l = listing(vec![
        listed(row(1, "A", 3), None, None),
        listed(row(2, "B", 2), None, Some(&[])),
        listed(row(3, "C", 1), None, Some(&[COVER])),
    ]);
    let v = reply(&l, &[], &[], &Downloads::default(), None);
    assert_eq!(v["topics"][0]["images"], Value::Null);
    assert_eq!(v["topics"][1]["images"], json!([]));
    assert_eq!(v["topics"][2]["images"], json!([crate::images::key(COVER)]));
}

#[test]
fn state_and_pending_come_from_added_and_queued() {
    let l = listing(vec![
        listed(row(1, "A", 3), None, None),
        listed(row(2, "B", 2), None, None),
        listed(row(3, "C", 1), None, None),
    ]);
    let v = reply(&l, &[1], &[1, 2], &Downloads::default(), None);
    let states: Vec<&str> = v["topics"].as_array().unwrap().iter().map(|t| t["state"].as_str().unwrap()).collect();
    assert_eq!(states, ["added", "queued", ""]);
    assert_eq!(v["pending"], 1);
}

#[test]
fn the_list_names_its_section_and_inputs() {
    let v = reply(&listing(vec![]), &[], &[], &Downloads::default(), None);
    assert_eq!(v["section"], "video");
    assert_eq!((v["now"].clone(), v["updated"].clone()), (json!(5000), json!(900)));
    assert_eq!(v["topicUrl"], TOPIC_URL);
    assert_eq!(v["curatedFilters"], json!(["couples"]));
    assert!(v.get("query").is_none() && v.get("error").is_none());
}

#[test]
fn a_search_reply_adds_query_and_error() {
    let s = SearchReply { query: "alpha".into(), error: None };
    let v = reply(&listing(vec![]), &[], &[], &Downloads::default(), Some(s));
    assert_eq!(v["query"], "alpha");
    assert!(v.as_object().unwrap().contains_key("error") && v["error"].is_null());
}

#[test]
fn statuses_serialize_by_kind() {
    let cases = [
        (Status::Queued, None, json!({"kind": "queued"})),
        (Status::Downloading(42), None, json!({"kind": "downloading", "percent": 42})),
        (Status::Added, None, json!({"kind": "added"})),
        (
            Status::InStash { scenes: vec!["7".into()], folder: None },
            Some("https://s/scenes/7".to_string()),
            json!({"kind": "inStash", "link": "https://s/scenes/7"}),
        ),
        (
            Status::Identified { label: "Studio – Title".into(), more: 2, guess: true, scenes: vec![], folder: None },
            None,
            json!({"kind": "identified", "label": "Studio – Title", "more": 2, "guess": true, "link": null}),
        ),
        (
            Status::Failed(Failure::Transmission("stalled".into())),
            None,
            json!({"kind": "failed", "reason": "download", "detail": "stalled"}),
        ),
        (
            Status::Failed(Failure::Identify),
            None,
            json!({"kind": "failed", "reason": "identify", "detail": "identify found nothing or gave up"}),
        ),
        (
            Status::Failed(Failure::Lost),
            None,
            json!({"kind": "failed", "reason": "lost", "detail": "the torrent is gone and no scene came of it"}),
        ),
    ];
    for (s, link, want) in cases {
        assert_eq!(serde_json::to_value(status(&s, link)).unwrap(), want);
    }
}

#[test]
fn a_topic_with_a_download_carries_its_status() {
    let l = listing(vec![listed(row(1, "A", 2), None, None), listed(row(2, "B", 1), None, None)]);
    let d = Downloads { by_topic: HashMap::from([(1, Status::Downloading(50))]), ..Downloads::default() };
    let v = reply(&l, &[1], &[], &d, None);
    assert_eq!(v["topics"][0]["status"], json!({"kind": "downloading", "percent": 50}));
    assert_eq!(v["topics"][1]["status"], Value::Null);
}

#[test]
fn grabs_carry_studio_title_age_and_status() {
    let r = DownloadRow {
        id: 1,
        source: "grab".into(),
        topic_id: None,
        release_title: "Rel".into(),
        studio: Some("Studio".into()),
        state: "added".into(),
        hash: None,
        added_at: Some(900),
        files_synced: false,
        files: vec![],
    };
    let d = Downloads { grabs: vec![(r, Status::Added)], ..Downloads::default() };
    assert_eq!(
        serde_json::to_value(grabs(&d, 1000)).unwrap(),
        json!({"now": 1000, "grabs": [{"studio": "Studio", "title": "Rel", "addedAt": 900, "status": {"kind": "added"}}]})
    );
}

#[test]
fn jobs_list_registered_jobs_in_order_with_history_and_next_slot() {
    let m = Monitor::default();
    m.register("prune");
    m.register("identify");
    m.set_state("identify", LiveState::Watching { pending: 2 });
    m.set_state("prune", LiveState::Running { since: 990 });
    let db = Db::open_in_memory().unwrap();
    let id = db.history_start("prune", 900).unwrap();
    db.history_finish(id, "prune", 950, Some("boom")).unwrap();
    let v = serde_json::to_value(jobs(&m, &db, 1000)).unwrap();
    assert_eq!(v["now"], 1000);
    assert_eq!(v["jobs"].as_array().unwrap().len(), 2);
    let (idf, pr) = (&v["jobs"][0], &v["jobs"][1]);
    assert_eq!((idf["name"].clone(), idf["state"].clone(), idf["pending"].clone()), (json!("identify"), json!("watching"), json!(2)));
    assert_eq!((idf["next"].clone(), idf["since"].clone(), idf["restart_at"].clone()), (Value::Null, Value::Null, Value::Null));
    assert_eq!((pr["state"].clone(), pr["since"].clone()), (json!("running"), json!(990)));
    assert_eq!(pr["next"], crate::jobs::next_slot(crate::jobs::PRUNE, 1000));
    assert_eq!(pr["runs"], json!([{"started": 900, "finished": 950, "ok": false, "error": "boom"}]));
    assert_eq!((pr["step"].clone(), pr["progress"].clone(), pr["lines"].clone()), (Value::Null, Value::Null, json!([])));
}
```

- [ ] **Step 2: Run them to see them fail**

Add `mod api;` to `main.rs` after `mod app;`, and create an empty `src/api.rs` containing only:

```rust
#[cfg(test)]
#[path = "api_tests.rs"]
mod tests;
```

Run: `cargo test api::`
Expected: compile errors, because `list`, `Downloads` and the other names aren't defined yet.

- [ ] **Step 3: Implement `src/api.rs`**

```rust
//! The JSON the app reads: a section's list, a search, recent grabs, and the jobs. Pure:
//! the handlers in `web` gather the data, these functions shape it. Every rule about a
//! topic (its labels, rank, production class, status) is decided here, never in the app.

use crate::db::{Db, DownloadRow, JobRunRow, Listed, Listing, Section};
use crate::images::key;
use crate::jobs;
use crate::labels::labels;
use crate::monitor::{JobLive, Line, LiveState, Monitor};
use crate::provenance::{self, Failure, Status};
use serde::Serialize;
use std::collections::{HashMap, HashSet};

pub const TOPIC_URL: &str = "https://tracker.example.org/forum/viewtopic.php?t=";

/// Seeders count for more or less by how the release was produced, so mass-produced releases
/// sink below amateur and artistic ones. Unclassified counts as 1.0.
fn weight(class: Option<&str>) -> f64 {
    match class {
        Some("amateur") => 1.5,
        Some("pro_artistic") => 1.0,
        Some("industrial") => 0.25,
        _ => 1.0,
    }
}

pub fn production(t: &Listed) -> Option<&str> {
    t.topic.production.as_ref().map(|p| p.class.as_str())
}

/// A production class as the page names it (its badge and Production filter).
fn production_name(class: Option<&str>) -> Option<&'static str> {
    match class {
        Some("amateur") => Some("amateur"),
        Some("pro_artistic") => Some("artistic"),
        Some("industrial") => Some("industrial"),
        _ => None,
    }
}

pub fn score(t: &Listed) -> f64 {
    t.topic.row.seeders as f64 * weight(production(t))
}

/// What became of the downloads the app shows: plab's by topic, and recent grabs.
#[derive(Debug, Default)]
pub struct Downloads {
    pub by_topic: HashMap<u64, Status>,
    pub grabs: Vec<(DownloadRow, Status)>,
    /// Stash's web address, for links to a download's scenes; None gives no links.
    pub stash: Option<String>,
}

impl Downloads {
    pub(crate) fn link(&self, s: &Status) -> Option<String> {
        provenance::stash_link(self.stash.as_deref()?, s)
    }

    pub fn status_of(&self, s: &Status) -> StatusDto {
        status(s, self.link(s))
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StatusDto {
    Queued,
    Downloading { percent: u8 },
    Added,
    InStash { link: Option<String> },
    Identified { label: String, more: usize, guess: bool, link: Option<String> },
    Failed { reason: &'static str, detail: String },
}

pub fn status(s: &Status, link: Option<String>) -> StatusDto {
    match s {
        Status::Queued => StatusDto::Queued,
        Status::Downloading(p) => StatusDto::Downloading { percent: *p },
        Status::Added => StatusDto::Added,
        Status::InStash { .. } => StatusDto::InStash { link },
        Status::Identified { label, more, guess, .. } => StatusDto::Identified {
            label: label.clone(),
            more: *more,
            guess: *guess,
            link,
        },
        Status::Failed(f) => {
            let (reason, detail) = match f {
                Failure::Transmission(why) => ("download", why.clone()),
                Failure::Identify => ("identify", "identify found nothing or gave up".into()),
                Failure::Lost => ("lost", "the torrent is gone and no scene came of it".into()),
            };
            StatusDto::Failed { reason, detail }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TopicDto {
    pub id: u64,
    pub title: String,
    pub name: String,
    pub studio: Option<String>,
    pub quality: Option<String>,
    pub category: &'static str,
    pub production: Option<&'static str>,
    pub tags: Vec<String>,
    pub filters: Vec<String>,
    pub size: u64,
    pub seeders: u32,
    pub leechers: u32,
    pub added: i64,
    /// None: a live search result whose images come lazily through /api/thumb.
    pub images: Option<Vec<String>>,
    pub state: &'static str,
    pub status: Option<StatusDto>,
}

#[derive(Debug, Serialize)]
pub struct SearchReply {
    pub query: String,
    pub error: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListDto {
    pub now: i64,
    pub section: &'static str,
    pub updated: i64,
    pub topic_url: &'static str,
    /// The filter file's names, in file order.
    pub curated_filters: Vec<String>,
    /// Queued and not yet added.
    pub pending: usize,
    pub topics: Vec<TopicDto>,
    #[serde(flatten)]
    pub search: Option<SearchReply>,
}

pub fn list(
    listing: &Listing,
    added: &HashSet<u64>,
    queued: &HashSet<u64>,
    now: i64,
    section: Section,
    downloads: &Downloads,
    search: Option<SearchReply>,
) -> ListDto {
    // A stable sort, descending: equal scores keep the tracker's order.
    let mut topics: Vec<&Listed> = listing.topics.iter().collect();
    topics.sort_by(|a, b| score(b).partial_cmp(&score(a)).unwrap());
    ListDto {
        now,
        section: section.as_str(),
        updated: listing.updated,
        topic_url: TOPIC_URL,
        curated_filters: listing.filters.clone(),
        pending: queued.difference(added).count(),
        topics: topics.into_iter().map(|t| topic(t, added, queued, downloads)).collect(),
        search,
    }
}

fn topic(t: &Listed, added: &HashSet<u64>, queued: &HashSet<u64>, downloads: &Downloads) -> TopicDto {
    let row = &t.topic.row;
    let l = labels(&row.title, row.forum);
    let state = if added.contains(&row.id) {
        "added"
    } else if queued.contains(&row.id) {
        "queued"
    } else {
        ""
    };
    TopicDto {
        id: row.id,
        title: row.title.clone(),
        name: l.name,
        studio: l.studio,
        quality: l.quality,
        category: l.category,
        production: production_name(production(t)),
        tags: l.tags,
        filters: t.filters.clone(),
        size: row.size,
        seeders: row.seeders,
        leechers: row.leechers,
        added: row.added,
        images: t.topic.images.as_ref().map(|v| v.iter().map(|u| key(u)).collect()),
        state,
        status: downloads.by_topic.get(&row.id).map(|s| downloads.status_of(s)),
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GrabDto {
    pub studio: Option<String>,
    pub title: String,
    pub added_at: Option<i64>,
    pub status: StatusDto,
}

#[derive(Debug, Serialize)]
pub struct GrabsDto {
    pub now: i64,
    pub grabs: Vec<GrabDto>,
}

pub fn grabs(d: &Downloads, now: i64) -> GrabsDto {
    GrabsDto {
        now,
        grabs: d
            .grabs
            .iter()
            .map(|(r, s)| GrabDto {
                studio: r.studio.clone(),
                title: r.release_title.clone(),
                added_at: r.added_at,
                status: d.status_of(s),
            })
            .collect(),
    }
}

/// One job as the jobs spec's `/jobs.json` entry; its keys are that spec's, unchanged.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct JobDto {
    pub name: String,
    pub state: &'static str,
    pub since: Option<i64>,
    pub pending: Option<usize>,
    pub restart_at: Option<i64>,
    pub next: Option<i64>,
    pub step: Option<Line>,
    pub progress: Option<(u64, u64)>,
    pub lines: Vec<Line>,
    pub runs: Vec<JobRunRow>,
}

#[derive(Debug, Serialize)]
pub struct JobsDto {
    pub now: i64,
    pub jobs: Vec<JobDto>,
}

/// Runs shown per job.
const RUNS: usize = 10;

pub fn job(name: &str, live: &JobLive, db: &Db, now: i64) -> JobDto {
    let (state, since, pending, restart_at) = match live.state {
        LiveState::Idle => ("idle", None, None, None),
        LiveState::Running { since } => ("running", Some(since), None, None),
        LiveState::Watching { pending } => ("watching", None, Some(pending), None),
        LiveState::Restarting { at } => ("restarting", None, None, Some(at)),
    };
    // A failed history read still serves the live state.
    let runs = db.job_history(name, RUNS).unwrap_or_else(|e| {
        tracing::info!(job = "web", "job history {name}: {e:#}");
        vec![]
    });
    JobDto {
        name: name.to_string(),
        state,
        since,
        pending,
        restart_at,
        next: jobs::schedule(name).map(|s| jobs::next_slot(s, now)),
        step: live.step.clone(),
        progress: live.progress,
        lines: live.lines.iter().cloned().collect(),
        runs,
    }
}

pub fn jobs(m: &Monitor, db: &Db, now: i64) -> JobsDto {
    JobsDto { now, jobs: m.snapshot().iter().map(|(n, l)| job(n, l, db, now)).collect() }
}

#[cfg(test)]
#[path = "api_tests.rs"]
mod tests;
```

In `page.rs`:
- Delete `TOPIC_URL`, `weight`, `production`, `score`, the `Downloads` struct and its `impl`.
- Add `use crate::api::{Downloads, TOPIC_URL, production, score};`.
- Keep `label` (it carries the badge colour) until Task 6 deletes the file.

In `web.rs`, change `use crate::page::{self, Downloads, SearchInfo};` to `use crate::api::Downloads;` plus `use crate::page::{self, SearchInfo};`.

- [ ] **Step 4: Run the tests**

Run: `cargo test api:: page::`
Expected: all pass. The page tests are unchanged because they reach the moved items through `super::*`.

- [ ] **Step 5: Commit (local only)**

```bash
git add packages/plab/src/api.rs packages/plab/src/api_tests.rs
git add -u packages/plab/src
git commit -m "feat(galactica): plab shapes its lists, grabs and jobs as JSON"
```

---

### Task 5: events and SSE (`events.rs`)

**Files:**
- Create: `packages/plab/src/events.rs`, `packages/plab/src/events_tests.rs`
- Modify: `packages/plab/src/main.rs` (add `mod events;`)

**Interfaces:**
- Consumes: `api::{StatusDto, JobDto}`.
- Produces, in `crate::events`:
  - `#[serde(tag = "type", rename_all = "camelCase")] pub enum Event { TopicState { id: u64, state: &'static str }, TopicStatus { id: u64, status: Option<StatusDto> }, Job(JobDto), Listing { section: &'static str }, Resync }` (Serialize, Clone, PartialEq, Debug)
  - `#[derive(Clone)] pub struct Events`, with these methods:
    - `Default` (capacity 256) and `with_capacity(usize)`
    - `publish(&self, Event)` and `subscribe(&self) -> broadcast::Receiver<Event>`
    - `clients(&self) -> usize`
  - `set_global(Events)` and `publish(Event)` (a no-op until set)
  - `stream(Receiver) -> impl Stream<Item = Event>` and `sse(&Events) -> Response<Body>`
  - `status_changes(prev, cur) -> Vec<Event>`
  - `pump(Arc<WebState<T, C>>)`, added in Task 6 once `WebState` has `events`

- [ ] **Step 1: Write the failing tests**

`src/events_tests.rs`:

```rust
use super::*;
use crate::api::StatusDto;
use futures::StreamExt;
use serde_json::json;
use std::collections::HashMap;

#[test]
fn events_serialize_with_their_type() {
    let cases = [
        (Event::TopicState { id: 1, state: "added" }, json!({"type": "topicState", "id": 1, "state": "added"})),
        (
            Event::TopicStatus { id: 2, status: Some(StatusDto::Added) },
            json!({"type": "topicStatus", "id": 2, "status": {"kind": "added"}}),
        ),
        (Event::TopicStatus { id: 3, status: None }, json!({"type": "topicStatus", "id": 3, "status": null})),
        (Event::Listing { section: "games" }, json!({"type": "listing", "section": "games"})),
        (Event::Resync, json!({"type": "resync"})),
    ];
    for (e, want) in cases {
        assert_eq!(serde_json::to_value(&e).unwrap(), want);
    }
}

#[test]
fn a_job_event_is_its_entry_with_a_type() {
    let job = crate::api::JobDto {
        name: "grab".into(),
        state: "idle",
        since: None,
        pending: None,
        restart_at: None,
        next: Some(5),
        step: None,
        progress: None,
        lines: vec![],
        runs: vec![],
    };
    let v = serde_json::to_value(Event::Job(job)).unwrap();
    assert_eq!((v["type"].clone(), v["name"].clone(), v["next"].clone()), (json!("job"), json!("grab"), json!(5)));
}

#[tokio::test]
async fn a_lagging_client_gets_resync_then_the_newest() {
    let ev = Events::with_capacity(1);
    let mut s = Box::pin(stream(ev.subscribe()));
    for section in ["video", "games", "video"] {
        ev.publish(Event::Listing { section });
    }
    assert_eq!(s.next().await, Some(Event::Resync));
    assert_eq!(s.next().await, Some(Event::Listing { section: "video" }));
}

#[test]
fn publish_without_clients_or_global_is_harmless() {
    Events::default().publish(Event::Resync);
    publish(Event::Resync); // the global is never set in tests
}

#[test]
fn status_changes_report_new_changed_and_gone_topics() {
    let prev = HashMap::from([(1, StatusDto::Added), (3, StatusDto::Queued), (4, StatusDto::Added)]);
    let cur = HashMap::from([
        (1, StatusDto::Downloading { percent: 50 }),
        (2, StatusDto::Queued),
        (4, StatusDto::Added),
    ]);
    assert_eq!(
        status_changes(&prev, &cur),
        vec![
            Event::TopicStatus { id: 1, status: Some(StatusDto::Downloading { percent: 50 }) },
            Event::TopicStatus { id: 2, status: Some(StatusDto::Queued) },
            Event::TopicStatus { id: 3, status: None },
        ]
    );
}
```

- [ ] **Step 2: Run them to see them fail**

Add `mod events;` to `main.rs` after `mod db;`, and create `src/events.rs` with only the `#[cfg(test)] #[path = "events_tests.rs"] mod tests;` lines.

Run: `cargo test events::`
Expected: compile errors, because `Event` doesn't exist yet.

- [ ] **Step 3: Implement `src/events.rs`**

```rust
//! Live updates for the app: one broadcast of `Event`s, served to each browser as SSE at
//! /api/events. Handlers publish through `WebState.events`; jobs that run without a
//! `WebState` (refresh) publish through the process-wide sender `serve` sets. There is no
//! replay: a client that reconnects, or lags and gets `resync`, refetches its view.

use crate::api::{JobDto, StatusDto};
use axum::body::Body;
use axum::http::Response;
use axum::response::IntoResponse;
use axum::response::sse::{Event as SseEvent, KeepAlive, Sse};
use futures::StreamExt;
use serde::Serialize;
use std::collections::HashMap;
use std::convert::Infallible;
use std::sync::OnceLock;
use std::time::Duration;
use tokio::sync::broadcast::{self, error::RecvError};

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum Event {
    /// "" | "queued" | "added", after an add, an unqueue, or the queue drain.
    TopicState { id: u64, state: &'static str },
    /// The status diff saw this topic's download status change; None: it has none now.
    TopicStatus { id: u64, status: Option<StatusDto> },
    Job(JobDto),
    /// refresh wrote a new list for the section.
    Listing { section: &'static str },
    /// The client fell behind: refetch.
    Resync,
}

#[derive(Clone)]
pub struct Events(broadcast::Sender<Event>);

impl Default for Events {
    fn default() -> Self {
        Events::with_capacity(256)
    }
}

impl Events {
    pub fn with_capacity(n: usize) -> Self {
        Events(broadcast::channel(n).0)
    }

    /// Send to every connected client; nobody listening is not an error.
    pub fn publish(&self, e: Event) {
        let _ = self.0.send(e);
    }

    pub fn subscribe(&self) -> broadcast::Receiver<Event> {
        self.0.subscribe()
    }

    pub fn clients(&self) -> usize {
        self.0.receiver_count()
    }
}

static GLOBAL: OnceLock<Events> = OnceLock::new();

/// `serve` sets this to the sender its `WebState` holds.
pub fn set_global(e: Events) {
    let _ = GLOBAL.set(e);
}

/// Publish from code that has no `WebState`; a no-op in one-shot commands and tests.
pub fn publish(e: Event) {
    if let Some(g) = GLOBAL.get() {
        g.publish(e);
    }
}

/// A client's events: a lag becomes one `Resync`, then it carries on from the newest.
pub fn stream(rx: broadcast::Receiver<Event>) -> impl futures::Stream<Item = Event> {
    futures::stream::unfold(rx, |mut rx| async move {
        let e = match rx.recv().await {
            Ok(e) => e,
            Err(RecvError::Lagged(_)) => Event::Resync,
            Err(RecvError::Closed) => return None,
        };
        Some((e, rx))
    })
}

/// GET /api/events.
pub fn sse(events: &Events) -> Response<Body> {
    let s = stream(events.subscribe()).map(|e| {
        Ok::<_, Infallible>(SseEvent::default().data(serde_json::to_string(&e).expect("event json")))
    });
    Sse::new(s)
        .keep_alive(KeepAlive::new().interval(Duration::from_secs(15)).text("keep-alive"))
        .into_response()
}

/// A `TopicStatus` for each topic whose status differs between the two samples, by id.
pub fn status_changes(prev: &HashMap<u64, StatusDto>, cur: &HashMap<u64, StatusDto>) -> Vec<Event> {
    let mut ids: Vec<u64> = prev.keys().chain(cur.keys()).copied().collect();
    ids.sort_unstable();
    ids.dedup();
    ids.into_iter()
        .filter(|id| prev.get(id) != cur.get(id))
        .map(|id| Event::TopicStatus { id, status: cur.get(&id).cloned() })
        .collect()
}

#[cfg(test)]
#[path = "events_tests.rs"]
mod tests;
```

- [ ] **Step 4: Run the tests**

Run: `cargo test events::`
Expected: 5 pass.

- [ ] **Step 5: Commit (local only)**

```bash
git add packages/plab/src/events.rs packages/plab/src/events_tests.rs packages/plab/src/main.rs
git commit -m "feat(galactica): plab broadcasts live events over SSE"
```

---

### Task 6: the API routes replace the page

**Files:**
- Modify: `packages/plab/src/web.rs` (whole routing section; `WebState`; `post`; `list`; `search`; `downloads` and `now` become `pub(crate)`)
- Modify: `packages/plab/src/web_tests.rs` (Fx; the page-route tests ported; new tests)
- Modify: `packages/plab/src/events.rs` (add `pump`)
- Modify: `packages/plab/src/plab.rs` (publish from `drain_queue` and `refresh`)
- Modify: `packages/plab/src/commands.rs` (`serve`: `Events`, `WebState` fields, the pump task)
- Modify: `packages/plab/src/main.rs` (remove `mod page;`)
- Delete: `packages/plab/src/page.rs`, `packages/plab/src/page_tests.rs`, `packages/plab/assets/`, `packages/plab/tests/fixtures/golden_page.html`, `golden_page_games.html`, `golden_page_search_error.html`
- Modify: `packages/plab/package.nix` (drop `(lib.fileset.maybeMissing ./assets)`)

**Interfaces:**
- Consumes: everything from Tasks 4 and 5.
- Produces: the HTTP contract in the spec's route table, plus these changes:
  - `WebState` gains `pub events: Events` and `pub monitor: Monitor`.
  - `pub(crate) fn web::now()` and `pub(crate) async fn web::downloads(&WebState, now) -> Downloads`.
  - `pub async fn events::pump(Arc<WebState<T, C>>) -> anyhow::Result<()>`.

- [ ] **Step 1: Update the test fixture and write the new route tests first**

In `web_tests.rs`:

1. In `Fx::with`'s `WebState { … }`, add `events: crate::events::Events::default(),` and `monitor: crate::monitor::Monitor::default(),`.
2. Add `use crate::events::Event;` and `use futures::StreamExt;` to the imports.
3. Delete these tests: `blank_query_redirects_to_the_list`, `results_page`, `search_failure_is_shown_on_the_page`, `static_fx` and the five `static_*` tests, `serve_filters_cached_topics`, `games_route`, `unrouted_paths_are_404_text`, `a_downloaded_topic_links_to_its_stash_scene`, `a_downloading_topic_shows_its_progress`, `a_games_download_gets_no_status_badge`, and `the_page_still_renders_when_transmission_fails`. Their replacements follow.
4. Change these paths in the remaining tests:
   - `"/search?q=alpha"` → `"/api/search?q=alpha"`
   - `"/thumb/` → `"/api/thumb/`
   - `"/images/` → `"/api/images/`
   - `"/add/` → `"/api/add/`
   - `"/unqueue/` → `"/api/unqueue/`
   - `format!("/img/…")` → `format!("/api/img/…")`

   The thumb redirect's expected `location` stays `../img/<key>`. Relative to `/api/thumb/5`, that resolves to `/api/img/<key>`.
5. In the `// Streaming` section, give every path sent through `fx.page`, `fx.get`, `fx.post` or `fx.request` that starts with `/stream/` an `/api` prefix. Leave every `fx.tailnet(…)` call and every expected `external` URL (`https://plab-stream.example/stream/…`) unchanged.
6. Add:

```rust
// Search

#[tokio::test]
async fn a_blank_search_is_400() {
    assert_eq!(Fx::new().get("/api/search?q=+").await.status, 400);
}

#[tokio::test]
async fn search_returns_its_results_as_json() {
    let fx = Fx::with(searching(), |_, _| {});
    let r = fx.get("/api/search?q=alpha").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.header("content-type"), "application/json");
    assert_eq!(r.header("cache-control"), "no-store");
    let v = r.json();
    assert_eq!((v["query"].clone(), v["error"].clone()), (json!("alpha"), Value::Null));
    assert_eq!(v["topics"][0]["id"], 5);
    assert_eq!(v["topics"][0]["images"], Value::Null);
    assert_eq!(
        *fx.state.tracker.searches.lock().unwrap(),
        vec![("alpha".to_string(), None, plab::SEARCH_LIMIT, Some(1))]
    );
}

#[tokio::test]
async fn a_search_failure_is_its_error() {
    let t = searching();
    *t.search_error.lock().unwrap() = Some("login needs captcha".into());
    let v = Fx::with(t, |_, _| {}).get("/api/search?q=alpha").await.json();
    assert!(v["error"].as_str().unwrap().contains("login needs captcha"), "{v}");
    assert_eq!(v["topics"], json!([]));
}

// The app

fn app_fx() -> Fx {
    Fx::with(FakeTracker::default(), |dir, st| {
        let dist = dir.join("dist");
        std::fs::create_dir_all(dist.join("assets")).unwrap();
        std::fs::write(dist.join("index.html"), "<!doctype html>app").unwrap();
        std::fs::write(dist.join("assets/index-abc123.js"), "js").unwrap();
        std::fs::write(dist.join("assets/index-abc123.css"), "css").unwrap();
        std::fs::write(dist.join("secret.txt"), "secret").unwrap();
        st.static_dir = Some(dist);
    })
}

#[tokio::test]
async fn app_routes_serve_the_index() {
    let fx = app_fx();
    for path in ["/", "/games", "/jobs", "/search?q=x", "/anything/else"] {
        let r = fx.get(path).await;
        assert_eq!(r.status, 200, "{path}");
        assert_eq!(r.header("content-type"), "text/html; charset=utf-8");
        assert_eq!(r.header("cache-control"), "no-cache");
        assert_eq!(r.text(), "<!doctype html>app");
    }
}

#[tokio::test]
async fn assets_are_served_immutable_with_their_types() {
    let fx = app_fx();
    for (name, ctype, body) in [
        ("index-abc123.js", "text/javascript; charset=utf-8", "js"),
        ("index-abc123.css", "text/css; charset=utf-8", "css"),
    ] {
        let r = fx.get(&format!("/assets/{name}")).await;
        assert_eq!(r.status, 200, "{name}");
        assert_eq!(r.header("content-type"), ctype);
        assert_eq!(r.header("cache-control"), "public, max-age=31536000, immutable");
        assert_eq!(r.text(), body);
    }
}

#[tokio::test]
async fn asset_traversal_unknown_types_and_missing_files_are_404() {
    let fx = app_fx();
    for name in ["../secret.txt", "..%2fsecret.txt", "sub/x.js", ".hidden.js", "index-abc123.txt", "", "gone.js"] {
        assert_eq!(fx.get(&format!("/assets/{name}")).await.status, 404, "{name}");
    }
}

#[tokio::test]
async fn without_a_built_app_the_index_is_503() {
    let r = Fx::new().get("/").await;
    assert_eq!(r.status, 503);
}

#[tokio::test]
async fn unrouted_api_paths_are_404_text() {
    let fx = Fx::new();
    for (method, path) in [
        ("GET", "/api/nope"),
        ("GET", "/api/img/xyz"),
        ("GET", "/api/thumb/abc"),
        ("GET", "/api/thumb/"),
        ("POST", "/"),
        ("POST", "/api/add/x"),
        ("POST", "/api/search"),
        ("POST", "/add/1"),
        ("DELETE", "/api/list"),
    ] {
        let r = fx.request(method, path).await;
        assert_eq!((r.status, r.text().as_str()), (404, "not found"), "{method} {path}");
        assert_eq!(r.header("content-type"), "text/plain");
    }
    assert_eq!(fx.get("/api/list?section=x").await.status, 400);
}

// Lists

#[tokio::test]
async fn the_list_leaves_out_excluded_topics() {
    let fx = Fx::with(FakeTracker::default(), |dir, st| {
        let path = dir.join("exclude.txt");
        std::fs::write(&path, "cherry\n").unwrap();
        st.exclude_file = Some(path);
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[]), listed(row(2, "Ripe Cherry"), &[])]);
    for path in ["/api/list", "/api/list?section=video"] {
        let r = fx.get(path).await;
        assert_eq!((r.status, r.header("cache-control")), (200, "no-store"));
        let v = r.json();
        assert_eq!(v["section"], "video");
        assert_eq!(v["topics"].as_array().unwrap().len(), 1);
        assert_eq!(v["topics"][0]["title"], "Fresh Apple");
    }
}

#[tokio::test]
async fn the_games_list() {
    let fx = Fx::with(FakeTracker::default(), |_, st| st.games_dir = Some("/games".into()));
    fx.state.db.save_listing(Section::Games, &[listed(row(2, "A Game"), &[])], &[], now()).unwrap();
    let v = fx.get("/api/list?section=games").await.json();
    assert_eq!((v["section"].clone(), v["topics"][0]["title"].clone()), (json!("games"), json!("A Game")));
}

fn mark(fx: &Fx, id: u64, section: Section, dir: &str, hash: &str, at: i64) -> i64 {
    fx.state
        .db
        .mark_added(crate::db::NewDownload {
            source: "plab",
            topic_id: Some(id),
            release_title: "Fresh Apple",
            section,
            download_dir: Some(dir),
            torrent_hash: Some(hash),
            now: at,
        })
        .unwrap()
}

#[tokio::test]
async fn a_downloaded_topic_links_to_its_stash_scene() {
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.stash_web_url = Some("https://stash.example".into());
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[])]);
    let id = mark(&fx, 1, Section::Video, "/vault", "abc", now());
    fx.state.db.save_files(id, &["Rel/a.mp4".into()]).unwrap();
    fx.state.db.link_scene("Rel/a.mp4", Some("42")).unwrap();
    let v = fx.get("/api/list").await.json();
    assert_eq!(v["topics"][0]["status"]["link"], "https://stash.example/scenes/42", "{v}");
}

#[tokio::test]
async fn a_downloading_topic_carries_its_progress() {
    let mut d = crate::provenance::tests::detail("abc", "/d", 0.5, &[]);
    d.activity_date = now();
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.torrents = Arc::new(FakeTorrents { details: vec![d], ..Default::default() });
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[])]);
    mark(&fx, 1, Section::Video, "/vault", "abc", now());
    let v = fx.get("/api/list").await.json();
    assert_eq!(v["topics"][0]["status"], json!({"kind": "downloading", "percent": 50}));
}

#[tokio::test]
async fn a_games_download_has_no_status() {
    // Games land outside the Vault library, so provenance never covers them: an old one
    // Transmission no longer has must not read "failed: lost".
    let fx = Fx::with(FakeTracker::default(), |_, st| st.games_dir = Some("/games".into()));
    fx.state.db.save_listing(Section::Games, &[listed(row(2, "A Game"), &[])], &[], now()).unwrap();
    mark(&fx, 2, Section::Games, "/games", "g1", now() - 3 * 86400);
    let v = fx.get("/api/list?section=games").await.json();
    assert_eq!(v["topics"][0]["status"], Value::Null);
}

#[tokio::test]
async fn the_list_still_serves_when_transmission_fails() {
    let fx = Fx::with(FakeTracker::default(), |_, st| {
        st.torrents = Arc::new(FakeTorrents { details_fail: true, ..Default::default() });
    });
    fx.save_video(&[listed(row(1, "Fresh Apple"), &[])]);
    mark(&fx, 1, Section::Video, "/vault", "abc", now());
    let r = fx.get("/api/list").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.json()["topics"][0]["status"], json!({"kind": "added"}));
}

#[tokio::test]
async fn grabs_and_jobs_are_json() {
    let fx = Fx::new();
    fx.state.monitor.register("prune");
    fx.state.monitor.register("identify");
    let g = fx.get("/api/grabs").await;
    assert_eq!((g.status, g.json()["grabs"].clone()), (200, json!([])));
    let j = fx.get("/api/jobs").await.json();
    let names: Vec<&str> = j["jobs"].as_array().unwrap().iter().map(|x| x["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["identify", "prune"]);
    assert!(j["jobs"][1]["next"].is_i64());
}

// Events

#[tokio::test]
async fn add_and_unqueue_publish_the_topic_state() {
    let mut t = FakeTracker::default();
    t.limit.insert(2);
    let fx = Fx::with(t, |_, _| {});
    fx.save_video(&[listed(row(1, "t1"), &[]), listed(row(2, "t2"), &[])]);
    let mut rx = fx.state.events.subscribe();
    fx.post("/api/add/1").await;
    fx.post("/api/add/2").await;
    fx.post("/api/unqueue/2").await;
    fx.post("/api/add/99").await; // fails: publishes nothing
    let got: Vec<Event> = std::iter::from_fn(|| rx.try_recv().ok()).collect();
    assert_eq!(
        got,
        vec![
            Event::TopicState { id: 1, state: "added" },
            Event::TopicState { id: 2, state: "queued" },
            Event::TopicState { id: 2, state: "" },
        ]
    );
}

#[tokio::test]
async fn events_is_an_event_stream() {
    let fx = Fx::new();
    let resp = router(fx.state.clone())
        .oneshot(Request::get("/api/events").body(Body::empty()).unwrap())
        .await
        .unwrap();
    assert_eq!(resp.status(), 200);
    assert_eq!(resp.headers()["content-type"], "text/event-stream");
    let mut body = resp.into_body().into_data_stream();
    fx.state.events.publish(Event::Listing { section: "video" });
    let chunk = tokio::time::timeout(std::time::Duration::from_secs(2), body.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(
        std::str::from_utf8(&chunk).unwrap(),
        "data: {\"type\":\"listing\",\"section\":\"video\"}\n\n"
    );
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cargo test web::`
Expected: compile errors, because `WebState` has no `events` or `monitor` field yet.

- [ ] **Step 3: Rewrite the routing in `web.rs`**

- Replace the module doc with: `//! plab's HTTP server: the JSON API under /api, its SSE stream, the app's built files under /assets, and the app's index.html for every other path (the app routes itself). Plus the tailnet listener that only reads streams.`
- Delete `STATIC`, `static_file`, `html`, and the `page` and `SearchInfo` imports.
- Add these imports:
  - `use crate::api::{self, Downloads, SearchReply};`
  - `use crate::events::{self, Event, Events};`
  - `use crate::monitor::Monitor;`
  - `use std::path::Path;`
- Add to `WebState`:

```rust
    /// Live updates to every connected app.
    pub events: Events,
    pub monitor: Monitor,
```

- Change `fn now()` to `pub(crate) fn now()`, and `async fn downloads` to `pub(crate) async fn downloads`.
- Replace `handle`, `get`, `list`, `search` and `post` (keep `topic_images`, `images_error`, `AddReply`, the stream functions and `tailnet`) with:

```rust
async fn handle<T: TrackerApi + 'static, C: TorrentClient + 'static>(
    State(st): State<Arc<WebState<T, C>>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
) -> Response<Body> {
    let path = uri.path();
    if let Some(route) = path.strip_prefix("/api").and_then(stream_route) {
        let range = headers.get(header::RANGE).and_then(|v| v.to_str().ok());
        return stream_page(&st, method, route, range).await;
    }
    match method {
        Method::GET => get(&st, path, uri.query()).await,
        Method::POST => post(&st, path).await,
        _ => not_found(),
    }
}

async fn get<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    path: &str,
    query: Option<&str>,
) -> Response<Body> {
    if let Some(rest) = path.strip_prefix("/api/") {
        return api_get(st, rest, query).await;
    }
    if let Some(name) = path.strip_prefix("/assets/") {
        return asset(st.static_dir.as_deref(), name).await;
    }
    index(st.static_dir.as_deref()).await
}

fn param(query: Option<&str>, name: &str) -> Option<String> {
    form_urlencoded::parse(query.unwrap_or("").as_bytes())
        .find(|(k, _)| k == name)
        .map(|(_, v)| v.into_owned())
}

fn json_body<V: Serialize>(v: &V) -> Response<Body> {
    send(200, serde_json::to_string(v).expect("json"), "application/json", "no-store")
}

async fn api_get<T: TrackerApi, C: TorrentClient>(
    st: &WebState<T, C>,
    path: &str,
    query: Option<&str>,
) -> Response<Body> {
    match path {
        "list" => {
            return match param(query, "section").as_deref() {
                None | Some("video") => list(st, Section::Video).await,
                Some("games") => list(st, Section::Games).await,
                Some(_) => text(400, "section is video or games"),
            };
        }
        "search" => {
            let q = param(query, "q").map(|q| q.trim().to_string()).unwrap_or_default();
            if q.is_empty() {
                return text(400, "q is required");
            }
            return search(st, &q).await;
        }
        "grabs" => {
            let t = now();
            return json_body(&api::grabs(&downloads(st, t).await, t));
        }
        "jobs" => return json_body(&api::jobs(&st.monitor, &st.db, now())),
        "events" => return events::sse(&st.events),
        _ => {}
    }
    let slashed = format!("/{path}");
    for kind in ["thumb", "images"] {
        if let Some(id) = id_after(&slashed, &format!("/{kind}")) {
            return topic_images(st, kind, id).await;
        }
    }
    if let Some(k) = path.strip_prefix("img/")
        && k.len() == 40
        && k.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
    {
        match plab::image_for(&st.ctx(), k, now()).await {
            Err(e) => {
                info!(job = "web", "image {k}: {e}");
                return text(502, "image unavailable");
            }
            Ok(Some((data, ctype))) => return send(200, data, ctype, "private, max-age=604800"),
            Ok(None) => {}
        }
    }
    not_found()
}

/// The content type of a built asset by extension; anything else is not served.
fn asset_type(name: &str) -> Option<&'static str> {
    match name.rsplit_once('.')?.1 {
        "js" => Some("text/javascript; charset=utf-8"),
        "css" => Some("text/css; charset=utf-8"),
        "svg" => Some("image/svg+xml"),
        "woff2" => Some("font/woff2"),
        "png" => Some("image/png"),
        _ => None,
    }
}

/// A file from the build's assets/. Its name carries its hash, so it is cached forever.
async fn asset(dir: Option<&Path>, name: &str) -> Response<Body> {
    let plain = !name.is_empty() && !name.contains('/') && !name.contains("..") && !name.starts_with('.');
    let (Some(dir), Some(ctype)) = (dir, plain.then(|| asset_type(name)).flatten()) else {
        return not_found();
    };
    match tokio::fs::read(dir.join("assets").join(name)).await {
        Ok(data) => send(200, data, ctype, "public, max-age=31536000, immutable"),
        Err(_) => not_found(),
    }
}

/// The app's shell, for every path the app routes itself. Never cached: it names the
/// current build's assets.
async fn index(dir: Option<&Path>) -> Response<Body> {
    let Some(dir) = dir else {
        return text(503, "the app is not built: PLAB_STATIC_DIR is not set");
    };
    match tokio::fs::read(dir.join("index.html")).await {
        Ok(body) => send(200, body, "text/html; charset=utf-8", "no-cache"),
        Err(_) => text(503, "the app is not built: PLAB_STATIC_DIR has no index.html"),
    }
}

async fn search<T: TrackerApi, C: TorrentClient>(st: &WebState<T, C>, q: &str) -> Response<Body> {
    let t = now();
    let (topics, error) = match plab::run_search(&st.ctx(), q, t).await {
        Ok(topics) => (topics, None),
        Err(e) => {
            info!(job = "web", "search {q:?} failed: {e}");
            (vec![], Some(e.to_string()))
        }
    };
    let downloads = downloads(st, t).await;
    let reply = st.db.listing(Section::Video).and_then(|l| {
        let listing = Listing { topics, ..l };
        let queued = st.db.queued(Section::Video)?.into_iter().collect();
        Ok(api::list(
            &listing,
            &st.db.added()?,
            &queued,
            t,
            Section::Video,
            &downloads,
            Some(SearchReply { query: q.to_string(), error }),
        ))
    });
    match reply {
        Ok(v) => json_body(&v),
        Err(e) => text(500, e.to_string()),
    }
}

async fn list<T: TrackerApi, C: TorrentClient>(st: &WebState<T, C>, section: Section) -> Response<Body> {
    let t = now();
    let downloads = downloads(st, t).await;
    let reply = st.db.listing(section).and_then(|mut listing| {
        let patterns = load_excludes(st.exclude_file.as_deref(), Some(&st.state_dir));
        if !patterns.is_empty() {
            listing.topics.retain(|t| !excluded(&patterns, &t.topic.row.title));
        }
        let queued = st.db.queued(section)?.into_iter().collect();
        Ok(api::list(&listing, &st.db.added()?, &queued, t, section, &downloads, None))
    });
    match reply {
        Ok(v) => json_body(&v),
        Err(e) => text(500, e.to_string()),
    }
}
```

In `post`, change its parameter from `target` to `path` and the lookup to `id_after(path, &format!("/api/{a}"))`. In the `Ok(reply)` arm, before the `info!`, add:

```rust
            let state = if action == "unqueue" {
                ""
            } else if reply.queued == Some(true) {
                "queued"
            } else {
                "added"
            };
            st.events.publish(Event::TopicState { id, state });
```

Remove imports the compiler reports as unused (`redirect` stays, because `topic_images` uses it).

- [ ] **Step 4: Add the pump to `events.rs`**

```rust
use crate::transmission::TorrentClient;
use crate::tracker::TrackerApi;
use crate::web::{self, WebState};
use std::sync::Arc;

/// How often the pump wakes; jobs are sampled on every wake (at most 4 events a second
/// per job), download statuses on every `STATUS_EVERY`th (10 s).
const SAMPLE: Duration = Duration::from_millis(250);
const STATUS_EVERY: u64 = 40;

/// Publish what changed in the jobs and the download statuses, while anyone listens.
/// With no clients it only sleeps; the first status sample after a client arrives is a
/// baseline, not a burst of events (the client fetched the list itself).
pub async fn pump<T: TrackerApi, C: TorrentClient>(st: Arc<WebState<T, C>>) -> anyhow::Result<()> {
    let mut statuses: Option<HashMap<u64, StatusDto>> = None;
    let mut sent: HashMap<String, crate::monitor::JobLive> = HashMap::new();
    let mut tick = tokio::time::interval(SAMPLE);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut n: u64 = 0;
    loop {
        tick.tick().await;
        if st.events.clients() == 0 {
            statuses = None;
            sent.clear();
            n = 0;
            continue;
        }
        let now = web::now();
        for (name, live) in st.monitor.snapshot() {
            if sent.get(&name) != Some(&live) {
                st.events.publish(Event::Job(crate::api::job(&name, &live, &st.db, now)));
                sent.insert(name, live);
            }
        }
        if n % STATUS_EVERY == 0 {
            let d = web::downloads(&st, now).await;
            let cur: HashMap<u64, StatusDto> =
                d.by_topic.iter().map(|(id, s)| (*id, d.status_of(s))).collect();
            if let Some(prev) = &statuses {
                for e in status_changes(prev, &cur) {
                    st.events.publish(e);
                }
            }
            statuses = Some(cur);
        }
        n += 1;
    }
}
```

- [ ] **Step 5: Publish from `refresh` and the queue drain** (`plab.rs`)

In `drain_queue`, after `info!("queued {topic_id} dropped: {e}");`, add `crate::events::publish(crate::events::Event::TopicState { id: topic_id, state: "" });`. After `info!("queued {topic_id}: added");`, add `crate::events::publish(crate::events::Event::TopicState { id: topic_id, state: "added" });`.

In `refresh`, right after `ctx.db.save_listing(section, &topics, &names, now)?;`, add:

```rust
    crate::events::publish(crate::events::Event::Listing { section: section.as_str() });
```

- [ ] **Step 6: Wire `serve`** (`commands.rs`)

Before `for task in tasks {`, add:

```rust
    // One broadcast for the whole daemon: the web handlers hold it in WebState, refresh
    // reaches it through the global.
    let events = crate::events::Events::default();
    crate::events::set_global(events.clone());
```

In the `WebState { … }` literal, add `events: events.clone(),` and `monitor: crate::monitor::global().clone(),`. After the `stream-reaper` spawn, inside `Task::Web`, add:

```rust
                let pump_state = state.clone();
                tokio::spawn(supervise("events", move || {
                    let st = pump_state.clone();
                    async move { crate::events::pump(st).await }
                }));
```

If `state` was moved into the `stream-web` closure above, clone it before that closure (`let pump_state = state.clone();` placed before `if let Some(sp)`).

- [ ] **Step 7: Delete the page**

```bash
cd packages/plab
git rm src/page.rs src/page_tests.rs assets/page.css assets/page.js \
  tests/fixtures/golden_page.html tests/fixtures/golden_page_games.html tests/fixtures/golden_page_search_error.html
```

Remove `mod page;` from `main.rs` and `(lib.fileset.maybeMissing ./assets)` from `package.nix`. Grep for leftovers: `grep -rn 'page::\|golden_page\|STATIC\b' src` should print nothing.

- [ ] **Step 8: Run everything**

Run: `cargo test`, then `cargo clippy --all-targets -- -D warnings`, then `cargo fmt`.
Expected: all green. Fix whatever clippy reports at its source.

- [ ] **Step 9: Build in the sandbox** (repo root)

Run: `nix build .#plab`
Expected: builds and passes its checkPhase.

- [ ] **Step 10: Commit (local only)**

```bash
git add -A packages/plab
git commit -m "feat(galactica): plab serves a JSON API and the app shell instead of the page"
```

---

### Task 7: the app scaffold, types and pure helpers

**Files:**
- Create: `packages/plab/ui/package.json`, `vite.config.ts`, `svelte.config.js`, `tsconfig.json`, `index.html`, `.gitignore`, `src/main.ts`, `src/app.css`, `src/vite-env.d.ts`, and `src/App.svelte` (a placeholder for now)
- Create: `src/lib/types.ts`, `src/lib/api.ts`, `src/lib/storage.ts`, `src/lib/format.ts`, `src/lib/status.ts`, `src/lib/stream.ts`, `src/lib/jobtime.ts`, `src/lib/route.ts`, plus `format.test.ts`, `status.test.ts`, `stream.test.ts`, `jobtime.test.ts`, `route.test.ts`

**Interfaces:**
- Produces: these TypeScript types (exactly as below):
  - `Section`, `TopicState`, `Status`, `Topic`, `List`, `Grab`, `Line`, `JobRun`, `Job`, `AddReply`, `ServerEvent`, `StreamFile`, `Stats`
- And these functions:
  - `fetchList`, `fetchSearch`, `fetchGrabs`, `fetchJobs`, `fetchImages`, `imgUrl`, `thumbUrl`, `postTopic`, `streamCall`, `HttpError`
  - `readStr`, `writeStr`, `readJson`
  - `size`, `age`, `freshShort`, `isFresh`, `day`, `duration`
  - `statusText`, `streamProgress`, `jobWhen`
  - `parse(path, search): Route`, with `Route = {view:'video'} | {view:'games'} | {view:'search'; q:string} | {view:'jobs'}`

- [ ] **Step 1: Create the project and install the pinned tools**

`packages/plab/ui/package.json`:

```json
{
  "name": "plab-ui",
  "private": true,
  "type": "module",
  "scripts": {
    "dev": "vite",
    "build": "vite build",
    "check": "svelte-check --tsconfig ./tsconfig.json --fail-on-warnings",
    "test": "vitest run"
  }
}
```

Run from `packages/plab/ui/`: `npm install -D svelte vite @sveltejs/vite-plugin-svelte tailwindcss @tailwindcss/vite daisyui@5 typescript svelte-check vitest`. npm writes the resolved versions into `package.json` and `package-lock.json`, and those two files are the pin.

`.gitignore`:

```
node_modules/
dist/
```

`vite.config.ts`:

```ts
import { defineConfig } from 'vitest/config';
import { svelte } from '@sveltejs/vite-plugin-svelte';
import tailwindcss from '@tailwindcss/vite';

// In dev, /api (including the SSE stream) goes to a running `plab serve`: a local one, or
// galactica's through `ssh -L 8577:127.0.0.1:8577 galactica`.
export default defineConfig({
  plugins: [tailwindcss(), svelte()],
  server: {
    proxy: { '/api': { target: process.env.PLAB_DEV_BACKEND ?? 'http://127.0.0.1:8577', changeOrigin: true } },
  },
  build: { outDir: 'dist', assetsDir: 'assets' },
  test: { environment: 'node', include: ['src/**/*.test.ts'] },
});
```

`svelte.config.js`:

```js
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

export default { preprocess: vitePreprocess() };
```

`tsconfig.json`:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "strict": true,
    "noEmit": true,
    "isolatedModules": true,
    "verbatimModuleSyntax": true,
    "skipLibCheck": true
  },
  "include": ["src/**/*.ts", "src/**/*.svelte", "vite.config.ts"]
}
```

`src/vite-env.d.ts`:

```ts
/// <reference types="svelte" />
/// <reference types="vite/client" />
```

`index.html`:

```html
<!doctype html>
<html lang="en" data-theme="luxury">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="referrer" content="no-referrer" />
    <title>plab</title>
  </head>
  <body class="min-h-screen bg-base-100 text-base-content overflow-x-hidden">
    <div id="app"></div>
    <script type="module" src="/src/main.ts"></script>
  </body>
</html>
```

`src/app.css`:

```css
@import "tailwindcss";
@plugin "daisyui" {
  themes: luxury --default;
}

/* A queued button turns into its Remove action on hover. */
.add.queued:not(:disabled):hover {
  --btn-color: var(--color-error);
  --btn-fg: var(--color-error-content);
}
```

`src/main.ts`:

```ts
import { mount } from 'svelte';
import './app.css';
import App from './App.svelte';

mount(App, { target: document.getElementById('app')! });
```

`src/App.svelte` (a placeholder, replaced in Task 9):

```svelte
<p class="p-4">plab</p>
```

- [ ] **Step 2: Write the types and the fetch layer**

`src/lib/types.ts`:

```ts
// The server's JSON, as packages/plab/src/api.rs and events.rs shape it (their tests pin
// these shapes). The jobs entry keeps the jobs spec's snake_case keys.

export type Section = 'video' | 'games';
export type TopicState = '' | 'queued' | 'added';

export type Status =
  | { kind: 'queued' }
  | { kind: 'downloading'; percent: number }
  | { kind: 'added' }
  | { kind: 'inStash'; link: string | null }
  | { kind: 'identified'; label: string; more: number; guess: boolean; link: string | null }
  | { kind: 'failed'; reason: 'download' | 'identify' | 'lost'; detail: string };

export interface Topic {
  id: number;
  title: string;
  name: string;
  studio: string | null;
  quality: string | null;
  category: string;
  production: 'amateur' | 'artistic' | 'industrial' | null;
  tags: string[];
  filters: string[];
  size: number;
  seeders: number;
  leechers: number;
  added: number;
  /** null: a live search result, whose images come through /api/thumb. */
  images: string[] | null;
  state: TopicState;
  status: Status | null;
}

export interface List {
  now: number;
  section: Section;
  updated: number;
  topicUrl: string;
  curatedFilters: string[];
  pending: number;
  topics: Topic[];
  /** Search replies only. */
  query?: string;
  error?: string | null;
}

export interface Grab {
  studio: string | null;
  title: string;
  addedAt: number | null;
  status: Status;
}

export interface Line {
  at: number;
  level: string;
  msg: string;
}

export interface JobRun {
  started: number;
  finished: number | null;
  ok: boolean | null;
  error: string | null;
}

export interface Job {
  name: string;
  state: 'idle' | 'running' | 'watching' | 'restarting';
  since: number | null;
  pending: number | null;
  restart_at: number | null;
  next: number | null;
  step: Line | null;
  progress: [number, number] | null;
  lines: Line[];
  runs: JobRun[];
}

export interface AddReply {
  ok: boolean;
  queued?: boolean;
  name?: string;
  message?: string;
  error?: string;
}

export type ServerEvent =
  | { type: 'topicState'; id: number; state: TopicState }
  | { type: 'topicStatus'; id: number; status: Status | null }
  | ({ type: 'job' } & Job)
  | { type: 'listing'; section: Section }
  | { type: 'resync' };

export interface StreamFile {
  index: number;
  name: string;
  length: number;
}

export interface Stats {
  progress: number;
  total: number;
  finished: boolean;
  mbps: number;
  peers: number;
  state: string;
  error?: string | null;
}
```

`src/lib/api.ts`:

```ts
import type { AddReply, Grab, Job, List, Section } from './types';

export class HttpError extends Error {
  constructor(
    message: string,
    public status: number,
  ) {
    super(message);
  }
}

async function getJson<T>(url: string): Promise<T> {
  const r = await fetch(url);
  if (!r.ok) throw new HttpError((await r.text()) || `HTTP ${r.status}`, r.status);
  return (await r.json()) as T;
}

export const fetchList = (section: Section) => getJson<List>(`/api/list?section=${section}`);
export const fetchSearch = (q: string) => getJson<List>(`/api/search?q=${encodeURIComponent(q)}`);
export const fetchGrabs = () => getJson<{ now: number; grabs: Grab[] }>('/api/grabs');
export const fetchJobs = () => getJson<{ now: number; jobs: Job[] }>('/api/jobs');
export const fetchImages = (id: number) => getJson<{ images: string[] }>(`/api/images/${id}`);
export const imgUrl = (key: string) => `/api/img/${key}`;
export const thumbUrl = (id: number) => `/api/thumb/${id}`;

/** Add or unqueue. A reply that is not JSON (a gateway's error page) asks for a reload. */
export async function postTopic(action: 'add' | 'unqueue', id: number): Promise<AddReply> {
  const r = await fetch(`/api/${action}/${id}`, { method: 'POST' });
  let j: AddReply;
  try {
    j = (await r.json()) as AddReply;
  } catch {
    throw new Error(`HTTP ${r.status} — reload the page`);
  }
  if (!j.ok) throw new Error(j.error ?? `HTTP ${r.status}`);
  return j;
}

/** A call under /api/stream/: its JSON when ok, else an HttpError with its reason. */
export async function streamCall<T>(path: string, method = 'GET'): Promise<T> {
  const r = await fetch(`/api/stream/${path}`, { method });
  let j: { ok: boolean; error?: string } & T;
  try {
    j = await r.json();
  } catch {
    throw new HttpError(`HTTP ${r.status}`, r.status);
  }
  if (!j.ok) throw new HttpError(j.error ?? `HTTP ${r.status}`, r.status);
  return j;
}
```

`src/lib/storage.ts`:

```ts
// localStorage can be missing or throw (private windows, blocked storage): every read
// falls back to nothing, every write may silently fail.

export function readStr(key: string): string | null {
  try {
    return localStorage.getItem(key);
  } catch {
    return null;
  }
}

export function writeStr(key: string, value: string): void {
  try {
    localStorage.setItem(key, value);
  } catch {
    /* not persisted */
  }
}

export function readJson(key: string): unknown {
  const s = readStr(key);
  if (s === null) return null;
  try {
    return JSON.parse(s);
  } catch {
    return null;
  }
}
```

- [ ] **Step 3: Write the failing tests for the pure helpers**

`src/lib/format.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { age, day, duration, freshShort, isFresh, size } from './format';

describe('format', () => {
  it('sizes in binary units', () => {
    expect(size(512)).toBe('512 B');
    expect(size(2048)).toBe('2.0 KB');
    expect(size(5 * 1024 * 1024)).toBe('5.0 MB');
    expect(size(3.5 * 1024 ** 3)).toBe('3.5 GB');
  });
  it('ages in minutes then hours', () => {
    expect(age(0, 100)).toBe('never');
    expect(age(1000, 1000 + 59 * 60)).toBe('59 min ago');
    expect(age(1000, 1000 + 125 * 60)).toBe('2 h ago');
    expect(age(2000, 1000)).toBe('0 min ago');
    expect(freshShort(1000, 1000 + 5 * 60)).toBe('5m');
    expect(freshShort(1000, 1000 + 3 * 3600)).toBe('3h');
  });
  it('is fresh under a day', () => {
    expect(isFresh(1000, 1000 + 86399)).toBe(true);
    expect(isFresh(1000, 1000 + 86400)).toBe(false);
  });
  it('dates in UTC', () => {
    expect(day(1793501999)).toBe('2026-11-01');
  });
  it('durations', () => {
    expect(duration(42)).toBe('42s');
    expect(duration(125)).toBe('2m 5s');
    expect(duration(3 * 3600 + 7 * 60)).toBe('3h 7m');
  });
});
```

`src/lib/status.test.ts`:

```ts
import { expect, it } from 'vitest';
import { statusText } from './status';

it('reads each status as the page always has', () => {
  expect(statusText({ kind: 'queued' })).toBe('queued');
  expect(statusText({ kind: 'downloading', percent: 42 })).toBe('downloading 42%');
  expect(statusText({ kind: 'added' })).toBe('added');
  expect(statusText({ kind: 'inStash', link: null })).toBe('in Stash');
  expect(statusText({ kind: 'identified', label: 'S – T', more: 2, guess: true, link: null })).toBe('S – T +2 (guess)');
  expect(statusText({ kind: 'identified', label: 'S – T', more: 0, guess: false, link: null })).toBe('S – T');
  expect(statusText({ kind: 'failed', reason: 'lost', detail: 'x' })).toBe('failed: lost');
});
```

`src/lib/stream.test.ts`:

```ts
import { expect, it } from 'vitest';
import { streamProgress } from './stream';

const stats = { progress: 512 * 1024 ** 2, total: 1024 ** 3, finished: false, mbps: 3.25, peers: 4, state: 'live' };
const files = [{ index: 0, name: 'Rel/a.mp4', length: 1 }];

it('reads like the old player', () => {
  expect(streamProgress(stats, files, 0, 1000)).toBe('a.mp4 · 50.0% of 1.00 GiB · 3.3 MiB/s · 4 peers');
  expect(streamProgress({ ...stats, state: 'paused' }, [], null, 1000)).toBe('50.0% of 1.00 GiB · 3.3 MiB/s · 4 peers · paused');
  expect(streamProgress({ ...stats, peers: 0 }, files, 0, 61000)).toBe('no peers yet');
  expect(streamProgress({ ...stats, total: 0 }, [], null, 0)).toContain('0.0% of 0.00 GiB');
});
```

`src/lib/jobtime.test.ts`:

```ts
import { expect, it } from 'vitest';
import { jobWhen } from './jobtime';
import type { Job } from './types';

const job = (over: Partial<Job>): Job => ({
  name: 'grab', state: 'idle', since: null, pending: null, restart_at: null, next: null,
  step: null, progress: null, lines: [], runs: [], ...over,
});

it('says how long it has run, until it restarts, or until its next slot', () => {
  expect(jobWhen(job({ state: 'running', since: 100 }), 165)).toBe('running for 1m 5s');
  expect(jobWhen(job({ state: 'restarting', restart_at: 130 }), 100)).toBe('restarting in 30s');
  expect(jobWhen(job({ next: 100 + 3600 }), 100)).toBe('next in 1h 0m');
  expect(jobWhen(job({ state: 'watching' }), 100)).toBe('');
});
```

`src/lib/route.test.ts`:

```ts
import { expect, it } from 'vitest';
import { parse } from './route';

it('maps paths to views', () => {
  expect(parse('/', '')).toEqual({ view: 'video' });
  expect(parse('/games', '')).toEqual({ view: 'games' });
  expect(parse('/jobs', '')).toEqual({ view: 'jobs' });
  expect(parse('/search', '?q=%20alpha%20')).toEqual({ view: 'search', q: 'alpha' });
  expect(parse('/search', '?q=')).toEqual({ view: 'video' });
  expect(parse('/nowhere', '')).toEqual({ view: 'video' });
});
```

Run: `npm test`
Expected: every suite fails to import, because the modules don't exist yet.

- [ ] **Step 4: Implement them**

`src/lib/format.ts`:

```ts
// The page's number and time formats, ported from page.rs.

export function size(n: number): string {
  if (n < 1024) return `${n} B`;
  let x = n / 1024;
  for (const unit of ['KB', 'MB']) {
    if (x < 1024) return `${x.toFixed(1)} ${unit}`;
    x /= 1024;
  }
  return `${x.toFixed(1)} GB`;
}

const minutes = (t: number, now: number) => Math.max(0, Math.floor((now - t) / 60));

export function age(t: number, now: number): string {
  if (t === 0) return 'never';
  const m = minutes(t, now);
  return m < 60 ? `${m} min ago` : `${Math.floor(m / 60)} h ago`;
}

export function freshShort(t: number, now: number): string {
  const m = minutes(t, now);
  return m < 60 ? `${m}m` : `${Math.floor(m / 60)}h`;
}

/** Uploaded within the last day. */
export const isFresh = (added: number, now: number) => now - added < 86400;

/** YYYY-MM-DD in UTC, as the server rendered it. */
export const day = (t: number) => new Date(t * 1000).toISOString().slice(0, 10);

export function duration(s: number): string {
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}
```

`src/lib/status.ts`:

```ts
import type { Status } from './types';

/** A status badge's text. */
export function statusText(s: Status): string {
  switch (s.kind) {
    case 'queued':
      return 'queued';
    case 'downloading':
      return `downloading ${s.percent}%`;
    case 'added':
      return 'added';
    case 'inStash':
      return 'in Stash';
    case 'identified':
      return s.label + (s.more > 0 ? ` +${s.more}` : '') + (s.guess ? ' (guess)' : '');
    case 'failed':
      return `failed: ${s.reason}`;
  }
}

export const STATUS_COLOR: Record<Status['kind'], string> = {
  queued: 'badge-warning',
  downloading: 'badge-info',
  added: 'badge-ghost',
  inStash: 'badge-neutral',
  identified: 'badge-success',
  failed: 'badge-error',
};
```

`src/lib/stream.ts`:

```ts
import type { Stats, StreamFile } from './types';

/** The player's progress line for a live stream. */
export function streamProgress(s: Stats, files: StreamFile[], selected: number | null, elapsedMs: number): string {
  if (s.peers === 0 && elapsedMs > 60000) return 'no peers yet';
  const gib = (b: number) => (b / 1073741824).toFixed(2) + ' GiB';
  const f = files.find((x) => x.index === selected);
  const name = f ? f.name.split('/').pop() + ' · ' : '';
  const pct = s.total > 0 ? ((s.progress / s.total) * 100).toFixed(1) : '0.0';
  const state = s.state !== 'live' ? ' · ' + s.state : '';
  return `${name}${pct}% of ${gib(s.total)} · ${s.mbps.toFixed(1)} MiB/s · ${s.peers} peers${state}`;
}
```

`src/lib/jobtime.ts`:

```ts
import { duration } from './format';
import type { Job } from './types';

/** A job card's header time: how long it has run, until it restarts, or until its next slot. */
export function jobWhen(j: Job, now: number): string {
  switch (j.state) {
    case 'running':
      return j.since !== null ? `running for ${duration(now - j.since)}` : 'running';
    case 'restarting':
      return j.restart_at !== null ? `restarting in ${duration(Math.max(0, j.restart_at - now))}` : 'restarting';
    default:
      return j.next !== null ? `next in ${duration(Math.max(0, j.next - now))}` : '';
  }
}
```

`src/lib/route.ts`:

```ts
export type Route = { view: 'video' } | { view: 'games' } | { view: 'search'; q: string } | { view: 'jobs' };

/** The view for a URL; anything unknown is the video list. */
export function parse(path: string, search: string): Route {
  switch (path) {
    case '/games':
      return { view: 'games' };
    case '/jobs':
      return { view: 'jobs' };
    case '/search': {
      const q = new URLSearchParams(search).get('q')?.trim() ?? '';
      return q ? { view: 'search', q } : { view: 'video' };
    }
    default:
      return { view: 'video' };
  }
}
```

- [ ] **Step 5: Run the checks**

Run: `npm test`, then `npm run check`, then `npm run build`.
Expected: the tests pass, svelte-check reports 0 errors and 0 warnings, and `dist/index.html` plus `dist/assets/index-*.{js,css}` exist.

- [ ] **Step 6: Commit (local only)**

```bash
git add packages/plab/ui
git commit -m "feat(galactica): plab-ui scaffold, API types and formatting helpers"
```

---

### Task 8: filters, NEW, the event reducer, and the stores

**Files:**
- Create: `src/lib/filters.ts`, `src/lib/seen.ts`, `src/lib/reducer.ts`, plus `filters.test.ts`, `seen.test.ts`, `reducer.test.ts`
- Create: `src/lib/router.svelte.ts`, `src/lib/filters.svelte.ts`, `src/lib/topics.svelte.ts`, `src/lib/events.svelte.ts`, `src/lib/jobs.svelte.ts`, `src/lib/clock.svelte.ts`

**Interfaces:**
- Consumes: Task 7's types, `api`, `storage`, and `route.parse`.
- Produces:
  - `filters.ts`: `Filters`, `empty()`, `fromHash`, `toHash`, `isVisible(s, t, fresh, isNew)`, `mostCommon`, `valueOf`, `offered(list)`, `prune(s, offered)`, `TOGGLES`, `SELECTS`, `Toggle`, `Select`
  - `seen.ts`: `nextSeen(raw, ids, nowMs) -> { next, newIds }`
  - `reducer.ts`: `applyTopic(lists, ev)`
  - `router` and the `link` action
  - `FilterState` and `filters.{video, games, search}`
  - `topics`, with these methods and fields:
    - `lists`, `newIds`, `stale`, `errors`
    - `load(section)`, `ensure(section)`, `search(q)`, `apply(ev)`, `setState(id, state)`, `resync(view)`
  - `live` (`connected`, `on`, `onReconnect`, `start`)
  - `jobs` (`list`, `error`, `load`, `apply`)
  - `clock` (`now`, `sync`)

- [ ] **Step 1: Write the failing tests**

`src/lib/filters.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { empty, fromHash, isVisible, mostCommon, offered, prune, toHash } from './filters';
import type { List, Topic } from './types';

const topic = (over: Partial<Topic> = {}): Topic => ({
  id: 1, title: 't', name: 'n', studio: 'Studio', quality: '1080p', category: 'Couples',
  production: 'amateur', tags: ['a', 'b'], filters: ['couples'], size: 1, seeders: 1,
  leechers: 0, added: 0, images: [], state: '', status: null, ...over,
});

describe('hash', () => {
  it('reads the format the old page wrote', () => {
    const s = fromHash('#h24=1&cat=Foo%20Bar&f=couples&tags=a,b%20c');
    expect(s).toEqual({ ...empty(), h24: true, cat: 'Foo Bar', f: 'couples', tags: ['a', 'b c'] });
  });
  it('round-trips, in the old key order', () => {
    const s = { ...empty(), new: true, hide: true, q: '4K', prod: 'amateur', tags: ['x,y'] };
    expect(toHash(s)).toBe('new=1&hide=1&q=4K&prod=amateur&tags=x%2Cy');
    expect(fromHash(toHash(s))).toEqual(s);
    expect(toHash(empty())).toBe('');
  });
  it('ignores junk', () => {
    expect(fromHash('#zzz=1&cat=%E0%A4%A&&tags=,,')).toEqual(empty());
  });
});

describe('isVisible', () => {
  it('passes everything with no filters', () => {
    expect(isVisible(empty(), topic(), false, false)).toBe(true);
  });
  it('applies each filter', () => {
    const t = topic();
    expect(isVisible({ ...empty(), h24: true }, t, false, false)).toBe(false);
    expect(isVisible({ ...empty(), h24: true }, t, true, false)).toBe(true);
    expect(isVisible({ ...empty(), new: true }, t, false, false)).toBe(false);
    expect(isVisible({ ...empty(), hide: true }, topic({ state: 'queued' }), false, false)).toBe(false);
    expect(isVisible({ ...empty(), f: 'other' }, t, false, false)).toBe(false);
    expect(isVisible({ ...empty(), cat: 'Couples', q: '1080p', studio: 'Studio', prod: 'amateur' }, t, false, false)).toBe(true);
    expect(isVisible({ ...empty(), studio: 'Studio' }, topic({ studio: null }), false, false)).toBe(false);
  });
  it('ANDs tags', () => {
    expect(isVisible({ ...empty(), tags: ['a', 'b'] }, topic(), false, false)).toBe(true);
    expect(isVisible({ ...empty(), tags: ['a', 'c'] }, topic(), false, false)).toBe(false);
  });
});

describe('facets', () => {
  it('counts by frequency, ties alphabetical, blanks dropped', () => {
    expect(mostCommon(['b', 'a', 'b', '', 'c', 'a'])).toEqual([['a', 2], ['b', 2], ['c', 1]]);
  });
  it('drops a saved value no longer offered, and keeps the object when nothing changes', () => {
    const list = { curatedFilters: ['couples'], topics: [topic()] } as List;
    const o = offered(list);
    const ok = { ...empty(), studio: 'Studio', f: 'couples' };
    expect(prune(ok, o)).toBe(ok);
    expect(prune({ ...ok, studio: 'Gone', f: 'renamed' }, o)).toEqual({ ...empty() });
  });
});
```

`src/lib/seen.test.ts`:

```ts
import { expect, it } from 'vitest';
import { nextSeen, WINDOW } from './seen';

it('marks nothing new on the first visit', () => {
  const r = nextSeen(null, ['1', '2'], 1000);
  expect(r.newIds.size).toBe(0);
  expect(r.next).toEqual({ prev: ['1', '2'], cur: ['1', '2'], at: 1000 });
});

it('keeps the previous mark inside the window', () => {
  const r = nextSeen({ prev: ['1'], cur: ['1', '2'], at: 1000 }, ['1', '2', '3'], 1000 + WINDOW);
  expect([...r.newIds]).toEqual(['2', '3']);
  expect(r.next).toEqual({ prev: ['1'], cur: ['1', '2', '3'], at: 1000 });
});

it('moves the mark after the window', () => {
  const r = nextSeen({ prev: ['1'], cur: ['1', '2'], at: 1000 }, ['1', '2', '3'], 1001 + WINDOW);
  expect([...r.newIds]).toEqual(['3']);
  expect(r.next).toEqual({ prev: ['1', '2'], cur: ['1', '2', '3'], at: 1001 + WINDOW });
});

it('reads the oldest format, a bare array', () => {
  const r = nextSeen([1, 2], ['1', '2', '3'], 5);
  expect([...r.newIds]).toEqual(['3']);
});
```

`src/lib/reducer.test.ts`:

```ts
import { expect, it } from 'vitest';
import { applyTopic } from './reducer';
import type { List, Topic } from './types';

const t = (id: number): Topic => ({
  id, title: '', name: '', studio: null, quality: null, category: '', production: null, tags: [],
  filters: [], size: 0, seeders: 0, leechers: 0, added: 0, images: [], state: '', status: null,
});
const list = (...ids: number[]) => ({ topics: ids.map(t) }) as List;

it('patches the topic in every list that holds it', () => {
  const a = list(1, 2);
  const b = list(2, 3);
  applyTopic([a, b], { type: 'topicState', id: 2, state: 'added' });
  expect([a.topics[1].state, b.topics[0].state, b.topics[1].state]).toEqual(['added', 'added', '']);
  applyTopic([a, b], { type: 'topicStatus', id: 2, status: { kind: 'downloading', percent: 5 } });
  expect(a.topics[1].status).toEqual({ kind: 'downloading', percent: 5 });
  expect(a.topics[1].state).toBe('added');
});

it('ignores other events', () => {
  const a = list(1);
  applyTopic([a], { type: 'listing', section: 'video' });
  expect(a.topics[0]).toEqual(t(1));
});
```

Run: `npm test`
Expected: the three new suites fail to import.

- [ ] **Step 2: Implement the pure modules**

`src/lib/filters.ts`:

```ts
import type { List, Topic } from './types';

// The filter state and its URL-hash form, ported unchanged from the old page.js so saved
// filters (localStorage and bookmarked hashes) keep working.

export const TOGGLES = ['h24', 'new', 'hide'] as const;
/** In the old page's key order, which toHash keeps. f: the active curated filter. */
export const SELECTS = ['cat', 'q', 'studio', 'prod', 'f'] as const;
export type Toggle = (typeof TOGGLES)[number];
export type Select = (typeof SELECTS)[number];

export interface Filters {
  h24: boolean;
  new: boolean;
  hide: boolean;
  f: string;
  cat: string;
  q: string;
  studio: string;
  prod: string;
  tags: string[];
}

export const empty = (): Filters => ({ h24: false, new: false, hide: false, f: '', cat: '', q: '', studio: '', prod: '', tags: [] });

export function fromHash(h: string): Filters {
  const o = empty();
  for (const p of h.replace(/^#/, '').split('&')) {
    if (!p) continue;
    const i = p.indexOf('=');
    const k = i < 0 ? p : p.slice(0, i);
    const v = i < 0 ? '' : p.slice(i + 1);
    try {
      if ((TOGGLES as readonly string[]).includes(k)) o[k as Toggle] = v === '1';
      else if ((SELECTS as readonly string[]).includes(k)) o[k as Select] = decodeURIComponent(v);
      else if (k === 'tags')
        for (const t of v.split(',').filter(Boolean)) {
          try {
            o.tags.push(decodeURIComponent(t));
          } catch {
            /* skip a malformed tag */
          }
        }
    } catch {
      /* skip a malformed value */
    }
  }
  return o;
}

export function toHash(s: Filters): string {
  const p: string[] = [];
  for (const k of TOGGLES) if (s[k]) p.push(k + '=1');
  for (const k of SELECTS) if (s[k]) p.push(k + '=' + encodeURIComponent(s[k]));
  if (s.tags.length) p.push('tags=' + s.tags.map(encodeURIComponent).join(','));
  return p.join('&');
}

/** The value a select filters a topic on. */
export function valueOf(t: Topic, k: Exclude<Select, 'f'>): string {
  switch (k) {
    case 'cat':
      return t.category;
    case 'q':
      return t.quality ?? '';
    case 'studio':
      return t.studio ?? '';
    case 'prod':
      return t.production ?? '';
  }
}

export function isVisible(s: Filters, t: Topic, fresh: boolean, isNew: boolean): boolean {
  return (
    (!s.h24 || fresh) &&
    (!s.new || isNew) &&
    (!s.hide || !t.state) &&
    (!s.f || t.filters.includes(s.f)) &&
    (!s.cat || valueOf(t, 'cat') === s.cat) &&
    (!s.q || valueOf(t, 'q') === s.q) &&
    (!s.studio || valueOf(t, 'studio') === s.studio) &&
    (!s.prod || valueOf(t, 'prod') === s.prod) &&
    s.tags.every((x) => t.tags.includes(x))
  );
}

/** Values by count descending, ties alphabetical; empty values are not counted. */
export function mostCommon(values: Iterable<string>): [string, number][] {
  const c = new Map<string, number>();
  for (const v of values) if (v) c.set(v, (c.get(v) ?? 0) + 1);
  return [...c].sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
}

/** Each select's offered values for a list. */
export function offered(l: List): Record<Select, Set<string>> {
  const vals = (k: Exclude<Select, 'f'>) => new Set(l.topics.map((t) => valueOf(t, k)).filter(Boolean));
  return { cat: vals('cat'), q: vals('q'), studio: vals('studio'), prod: vals('prod'), f: new Set(l.curatedFilters) };
}

/** Clear any select whose saved value is no longer offered: it would hide every card. The
 * same object comes back when nothing changes, so an effect can compare by identity. */
export function prune(s: Filters, o: Record<Select, Set<string>>): Filters {
  const drop = SELECTS.filter((k) => s[k] && !o[k].has(s[k]));
  if (!drop.length) return s;
  const n = { ...s, tags: [...s.tags] };
  for (const k of drop) n[k] = '';
  return n;
}
```

`src/lib/seen.ts`:

```ts
// "New since your last visit", ported from page.js initSeen. The stored record holds the
// ids at the previous mark (prev) and now (cur); the mark moves once 30 minutes have
// passed, so a reload within a visit keeps showing the same cards as new.

export const WINDOW = 30 * 60 * 1000;

export interface SeenRecord {
  prev: string[];
  cur: string[];
  at: number;
}

export function nextSeen(raw: unknown, ids: string[], now: number): { next: SeenRecord; newIds: Set<string> } {
  let rec: SeenRecord | null = null;
  if (Array.isArray(raw)) rec = { prev: raw.map(String), cur: raw.map(String), at: now };
  else if (raw && typeof raw === 'object') {
    const r = raw as { prev?: unknown; cur?: unknown; at?: unknown };
    if (Array.isArray(r.prev) && Array.isArray(r.cur))
      rec = { prev: r.prev.map(String), cur: r.cur.map(String), at: Number(r.at) || 0 };
  }
  let next: SeenRecord;
  if (!rec) next = { prev: ids, cur: ids, at: now };
  else if (now - rec.at > WINDOW) next = { prev: rec.cur, cur: ids, at: now };
  else next = { prev: rec.prev, cur: ids, at: rec.at };
  const prev = new Set(next.prev);
  const newIds = rec ? new Set(ids.filter((id) => !prev.has(id))) : new Set<string>();
  return { next, newIds };
}
```

`src/lib/reducer.ts`:

```ts
import type { List, ServerEvent } from './types';

/** Apply a topic event to every loaded list holding that topic. A topic's state and its
 * status arrive as separate events, so neither overwrites the other. */
export function applyTopic(lists: Iterable<List>, ev: ServerEvent): void {
  if (ev.type !== 'topicState' && ev.type !== 'topicStatus') return;
  for (const l of lists)
    for (const t of l.topics)
      if (t.id === ev.id) {
        if (ev.type === 'topicState') t.state = ev.state;
        else t.status = ev.status;
      }
}
```

- [ ] **Step 3: Run the tests**

Run: `npm test`
Expected: all pass.

- [ ] **Step 4: Write the stores**

`src/lib/router.svelte.ts`:

```ts
import { parse, type Route } from './route';

class Router {
  route = $state<Route>(parse(location.pathname, location.search));

  constructor() {
    addEventListener('popstate', () => {
      this.route = parse(location.pathname, location.search);
    });
  }

  go(url: string) {
    const u = new URL(url, location.href);
    history.pushState(null, '', u.pathname + u.search + u.hash);
    this.route = parse(u.pathname, u.search);
  }
}

export const router = new Router();

/** `use:link` on an <a>: a plain left click navigates in the app. */
export function link(node: HTMLAnchorElement) {
  const on = (e: MouseEvent) => {
    if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
    e.preventDefault();
    router.go(node.href);
  };
  node.addEventListener('click', on);
  return { destroy: () => node.removeEventListener('click', on) };
}
```

`src/lib/filters.svelte.ts`:

```ts
import { empty, fromHash, toHash, type Filters, type Toggle } from './filters';
import { readStr, writeStr } from './storage';

/** One view's filters. The lists keep theirs in the URL hash and localStorage (the old
 * page's keys); a search's are in memory only, so they never overwrite the list's. */
export class FilterState {
  st = $state<Filters>(empty());

  constructor(private key: string | null) {}

  /** On entering the view: the hash wins, then the saved filters. */
  activate() {
    if (this.key === null) return;
    const raw = location.hash.length > 1 ? location.hash : readStr(this.key);
    this.st = raw ? fromHash(raw) : empty();
  }

  save() {
    if (this.key === null) return;
    const h = toHash(this.st);
    try {
      history.replaceState(history.state, '', h ? '#' + h : location.pathname + location.search);
    } catch {
      /* not reflected in the URL */
    }
    writeStr(this.key, h);
  }

  toggle(k: Toggle) {
    this.st[k] = !this.st[k];
  }

  toggleTag(t: string) {
    const i = this.st.tags.indexOf(t);
    if (i < 0) this.st.tags.push(t);
    else this.st.tags.splice(i, 1);
  }

  addTag(t: string) {
    if (t && !this.st.tags.includes(t)) this.st.tags.push(t);
  }

  clear() {
    this.st = empty();
  }
}

export const filters = {
  video: new FilterState('plab.filters'),
  games: new FilterState('plab.filters.games'),
  search: new FilterState(null),
};
```

`src/lib/topics.svelte.ts`:

```ts
import { fetchList, fetchSearch } from './api';
import { applyTopic } from './reducer';
import { nextSeen } from './seen';
import { readJson, writeStr } from './storage';
import type { List, Section, ServerEvent, TopicState } from './types';

type Key = Section | 'search';

/** The loaded lists, cached for the session: a tab switch shows its list at once. Events
 * patch topics in place; a `listing` event only marks the section stale (the reload pill). */
class Topics {
  lists = $state<Partial<Record<Key, List>>>({});
  stale = $state<Partial<Record<Section, boolean>>>({});
  errors = $state<Partial<Record<Key, string>>>({});
  /** Topic ids new since the last visit, per section. */
  newIds = $state.raw<Partial<Record<Section, Set<string>>>>({});
  private loading: Partial<Record<Key, boolean>> = {};

  async load(key: Section) {
    this.loading[key] = true;
    try {
      const l = await fetchList(key);
      const seenKey = 'plab.seen' + (key === 'games' ? '.games' : '');
      const r = nextSeen(readJson(seenKey), l.topics.map((t) => String(t.id)), Date.now());
      writeStr(seenKey, JSON.stringify(r.next));
      this.newIds = { ...this.newIds, [key]: r.newIds };
      this.lists[key] = l;
      this.stale[key] = false;
      delete this.errors[key];
    } catch (e) {
      this.errors[key] = e instanceof Error ? e.message : String(e);
    } finally {
      this.loading[key] = false;
    }
  }

  ensure(key: Section) {
    if (!this.lists[key] && !this.loading[key]) void this.load(key);
  }

  async search(q: string) {
    delete this.lists.search;
    try {
      this.lists.search = await fetchSearch(q);
      delete this.errors.search;
    } catch (e) {
      this.errors.search = e instanceof Error ? e.message : String(e);
    }
  }

  private all(): List[] {
    return Object.values(this.lists).filter((l): l is List => !!l);
  }

  apply(ev: ServerEvent) {
    applyTopic(this.all(), ev);
    if (ev.type === 'listing') this.stale[ev.section] = true;
  }

  /** After an add or unqueue reply, in every list holding the topic. */
  setState(id: number, state: TopicState) {
    applyTopic(this.all(), { type: 'topicState', id, state });
  }

  /** After a reconnect or a lag: refetch what is on screen, forget the rest. */
  resync(view: string) {
    for (const k of ['video', 'games'] as const) {
      if (k === view) void this.load(k);
      else delete this.lists[k];
    }
    const q = this.lists.search?.query;
    if (view === 'search' && q) void this.search(q);
  }
}

export const topics = new Topics();
```

`src/lib/events.svelte.ts`:

```ts
import type { ServerEvent } from './types';

/** The one SSE connection. EventSource retries a dropped connection itself; a refused one
 * (the gateway's 502 while plab restarts) closes it for good, so that is retried here. */
class Live {
  connected = $state(false);
  private handlers: ((e: ServerEvent) => void)[] = [];
  private reconnects: (() => void)[] = [];
  private es: EventSource | null = null;
  private lost = false;

  on(h: (e: ServerEvent) => void) {
    this.handlers.push(h);
  }

  /** Called after a reconnect and on `resync`: the client may have missed events. */
  onReconnect(h: () => void) {
    this.reconnects.push(h);
  }

  start() {
    if (this.es) return;
    const es = new EventSource('/api/events');
    this.es = es;
    es.onopen = () => {
      this.connected = true;
      if (this.lost) {
        this.lost = false;
        this.reconnects.forEach((f) => f());
      }
    };
    es.onerror = () => {
      this.connected = false;
      this.lost = true;
      if (es.readyState === EventSource.CLOSED) {
        this.es = null;
        setTimeout(() => this.start(), 5000);
      }
    };
    es.onmessage = (m) => {
      let ev: ServerEvent;
      try {
        ev = JSON.parse(m.data) as ServerEvent;
      } catch {
        return;
      }
      if (ev.type === 'resync') this.reconnects.forEach((f) => f());
      else this.handlers.forEach((h) => h(ev));
    };
  }
}

export const live = new Live();
```

`src/lib/clock.svelte.ts`:

```ts
const secs = () => Math.floor(Date.now() / 1000);

/** Server time, ticking each second: job cards count against it, not the client's clock. */
class Clock {
  private offset = 0;
  now = $state(secs());

  constructor() {
    setInterval(() => {
      this.now = secs() + this.offset;
    }, 1000);
  }

  sync(server: number) {
    this.offset = server - secs();
    this.now = server;
  }
}

export const clock = new Clock();
```

`src/lib/jobs.svelte.ts`:

```ts
import { fetchJobs } from './api';
import { clock } from './clock.svelte';
import type { Job, ServerEvent } from './types';

class Jobs {
  list = $state<Job[]>([]);
  error = $state('');

  async load() {
    try {
      const r = await fetchJobs();
      this.list = r.jobs;
      clock.sync(r.now);
      this.error = '';
    } catch {
      this.error = 'plab not responding';
    }
  }

  apply(ev: ServerEvent) {
    if (ev.type !== 'job') return;
    const { type: _type, ...job } = ev;
    const i = this.list.findIndex((j) => j.name === job.name);
    if (i >= 0) this.list[i] = job;
  }
}

export const jobs = new Jobs();
```

- [ ] **Step 5: Run the checks**

Run: `npm test`, then `npm run check`.
Expected: the tests pass and the check is clean.

- [ ] **Step 6: Commit (local only)**

```bash
git add packages/plab/ui
git commit -m "feat(galactica): plab-ui filters, NEW marks, live events and stores"
```

---

### Task 9: the list views and cards

**Files:**
- Create: `src/components/Navbar.svelte`, `ListView.svelte`, `FilterBar.svelte`, `Card.svelte`, `StatusBadge.svelte`, `AddButton.svelte`, `TagPill.svelte`, `GrabsStrip.svelte`, `Gallery.svelte`, `NewReleasesPill.svelte`
- Modify: `src/App.svelte` (replace the placeholder)

**Interfaces:**
- Consumes: Tasks 7 and 8.
- Produces: `Navbar` (a `children` snippet for the summary line) and `ListView` (`kind: 'video' | 'games' | 'search'`, `q?: string`), used by `App`. `ListView` mounts the `Player` from Task 10, so create `src/components/Player.svelte` as a stub in this task:

```svelte
<script lang="ts">
  export function open(_id: number) {}
</script>
```

- [ ] **Step 1: Write the components**

`src/components/Navbar.svelte`:

```svelte
<script lang="ts">
  import type { Snippet } from 'svelte';
  import { live } from '../lib/events.svelte';
  import { link, router } from '../lib/router.svelte';

  let { children }: { children?: Snippet } = $props();
  const tabs = [
    ['video', '/', 'Videos'],
    ['games', '/games', 'Games'],
    ['jobs', '/jobs', 'Jobs'],
  ] as const;
</script>

<header class="navbar min-h-0 p-0 mb-2 flex-wrap items-baseline gap-x-4 gap-y-1">
  <h1 class="text-xl font-bold">plab</h1>
  <div role="tablist" class="tabs tabs-box tabs-sm">
    {#each tabs as [view, href, name] (view)}
      <a role="tab" class={['tab', router.route.view === view && 'tab-active']} {href} use:link>{name}</a>
    {/each}
  </div>
  <span
    class={['inline-block size-2 rounded-full self-center', live.connected ? 'bg-success' : 'bg-warning']}
    title={live.connected ? 'live' : 'reconnecting'}
  ></span>
  <span class="text-sm text-base-content/60">{@render children?.()}</span>
</header>
```

`src/components/StatusBadge.svelte`:

```svelte
<script lang="ts">
  import { STATUS_COLOR, statusText } from '../lib/status';
  import type { Status } from '../lib/types';

  let { status }: { status: Status } = $props();
  const cls = $derived(['badge badge-sm max-w-full truncate', STATUS_COLOR[status.kind]]);
  const link = $derived('link' in status ? status.link : null);
</script>

{#if link}
  <a class={cls} href={link} target="_blank" rel="noreferrer" title="Open in Stash">{statusText(status)}</a>
{:else}
  <span class={cls} title={status.kind === 'failed' ? status.detail : undefined}>{statusText(status)}</span>
{/if}
```

`src/components/TagPill.svelte`:

```svelte
<script lang="ts">
  import type { FilterState } from '../lib/filters.svelte';

  let { tag, fs }: { tag: string; fs: FilterState } = $props();
</script>

<button
  type="button"
  class={['badge badge-sm badge-outline cursor-pointer', fs.st.tags.includes(tag) && 'badge-primary']}
  onclick={() => fs.toggleTag(tag)}>{tag}</button
>
```

`src/components/AddButton.svelte`:

```svelte
<script lang="ts">
  import { postTopic } from '../lib/api';
  import { topics } from '../lib/topics.svelte';
  import type { Section, Topic } from '../lib/types';

  let { topic, section }: { topic: Topic; section: Section } = $props();
  let loading = $state(false);
  let hover = $state(false);
  let error = $state('');

  const label = $derived.by(() => {
    if (loading) return topic.state === 'queued' ? 'Removing…' : 'Adding…';
    if (topic.state === 'added') return 'Added ✓';
    if (topic.state === 'queued') return hover ? 'Remove ✕' : 'Queued ⏳';
    return error ? 'Retry' : section === 'games' ? 'Add to Games' : 'Add to Vault';
  });

  async function toggle() {
    if (loading || topic.state === 'added') return;
    const unqueue = topic.state === 'queued';
    loading = true;
    error = '';
    try {
      const j = await postTopic(unqueue ? 'unqueue' : 'add', topic.id);
      if (unqueue) topics.setState(topic.id, '');
      else if (j.queued) {
        topics.setState(topic.id, 'queued');
        error = j.message ?? '';
      } else topics.setState(topic.id, 'added');
    } catch (e) {
      error = e instanceof Error ? e.message : String(e);
    } finally {
      loading = false;
      hover = false;
    }
  }
</script>

<button
  class={['add btn btn-sm', topic.state === 'queued' ? 'btn-warning queued' : 'btn-primary']}
  disabled={loading || topic.state === 'added'}
  title={topic.state === 'queued' ? 'Click to remove from queue' : undefined}
  onmouseenter={() => (hover = topic.state === 'queued' && !loading)}
  onmouseleave={() => (hover = false)}
  onclick={toggle}>{label}</button
>
<span class="text-xs text-error">{error}</span>
```

`src/components/Card.svelte`:

```svelte
<script lang="ts">
  import { fetchImages, imgUrl, thumbUrl } from '../lib/api';
  import type { FilterState } from '../lib/filters.svelte';
  import { age, day, freshShort, isFresh, size } from '../lib/format';
  import type { Section, Topic } from '../lib/types';
  import AddButton from './AddButton.svelte';
  import StatusBadge from './StatusBadge.svelte';
  import TagPill from './TagPill.svelte';

  let {
    topic,
    section,
    now,
    topicUrl,
    isNew,
    fs,
    stream,
    ongallery,
    onstream,
  }: {
    topic: Topic;
    section: Section;
    now: number;
    topicUrl: string;
    isNew: boolean;
    fs: FilterState;
    stream: boolean;
    ongallery: (images: string[]) => void;
    onstream: (id: number) => void;
  } = $props();

  const PRODUCTION = { amateur: 'badge-success', artistic: 'badge-info', industrial: 'badge-neutral' } as const;
  const fresh = $derived(isFresh(topic.added, now));
  let thumbFailed = $state(false);

  async function openTopicGallery() {
    try {
      const j = await fetchImages(topic.id);
      if (j.images.length) ongallery(j.images);
    } catch {
      /* the card keeps its thumbnail */
    }
  }
</script>

<div class={['card bg-base-200 shadow-sm overflow-hidden', isNew && 'is-new ring-2 ring-(--color-accent)']}>
  <figure class="relative aspect-[16/10] bg-black">
    {#if isNew}<span class="badge badge-accent badge-lg font-bold absolute top-2 left-2 z-[1]">NEW</span>{/if}
    {#if fresh}
      <span class="badge badge-warning font-bold absolute top-2 right-2 z-[1]">{freshShort(topic.added, now)}</span>
    {/if}
    {#if topic.production}
      <span class={['badge font-bold absolute bottom-2 right-2 z-[1]', PRODUCTION[topic.production]]}>{topic.production}</span>
    {/if}
    {#if topic.images === null && !thumbFailed}
      <button type="button" class="block w-full h-full cursor-zoom-in" onclick={openTopicGallery}>
        <img class="w-full h-full object-cover" loading="lazy" src={thumbUrl(topic.id)} alt="" onerror={() => (thumbFailed = true)} />
      </button>
    {:else if topic.images?.length}
      <button type="button" class="block w-full h-full cursor-zoom-in" onclick={() => ongallery(topic.images ?? [])}>
        <img class="w-full h-full object-cover" loading="lazy" src={imgUrl(topic.images[0])} alt="" />
      </button>
    {:else}
      <div class="w-full h-full"></div>
    {/if}
  </figure>
  <div class="card-body p-3 gap-2">
    {#if topic.studio || topic.quality}
      <div class="flex flex-wrap items-center gap-2 text-xs">
        {#if topic.studio}<span class="font-semibold uppercase tracking-wide text-primary">{topic.studio}</span>{/if}
        {#if topic.quality}<span class="badge badge-xs badge-outline">{topic.quality}</span>{/if}
      </div>
    {/if}
    <a
      class="link link-hover font-semibold break-words"
      href={topicUrl + topic.id}
      target="_blank"
      rel="noreferrer"
      title={topic.title}>{topic.name}</a
    >
    {#if topic.tags.length}
      <div class="flex flex-wrap gap-1">
        {#each topic.tags as tag (tag)}<TagPill {tag} {fs} />{/each}
      </div>
    {/if}
    <div class="text-xs text-base-content/60">
      {size(topic.size)} · ▲ {topic.seeders} ▼ {topic.leechers} ·
      {#if fresh}<span class="text-warning font-bold">uploaded {age(topic.added, now)}</span>{:else}{day(topic.added)}{/if}
    </div>
    <div class="card-actions mt-auto items-center">
      <AddButton {topic} {section} />
      {#if stream}
        <button type="button" class="btn btn-sm btn-ghost" onclick={() => onstream(topic.id)}>Stream ▶</button>
      {/if}
      {#if topic.status}<StatusBadge status={topic.status} />{/if}
    </div>
  </div>
</div>
```

`src/components/FilterBar.svelte`:

```svelte
<script lang="ts">
  import { mostCommon, valueOf, type Select, type Toggle } from '../lib/filters';
  import type { FilterState } from '../lib/filters.svelte';
  import { router } from '../lib/router.svelte';
  import type { List } from '../lib/types';

  let { kind, list, fs, shown }: { kind: 'video' | 'games' | 'search'; list: List; fs: FilterState; shown: number } =
    $props();

  const games = $derived(kind === 'games');
  const search = $derived(kind === 'search');
  // A search is all time, and its results are not new or classified by production.
  const toggles = $derived<[Toggle, string][]>(
    search
      ? [['h24', 'Last 24h'], ['hide', 'Hide added']]
      : [['h24', 'Last 24h'], ['new', 'New'], ['hide', 'Hide added']],
  );
  const selects = $derived.by(() => {
    const keys: [Exclude<Select, 'f'>, string][] = [
      ...(search ? [] : [['prod', 'Production'] as [Exclude<Select, 'f'>, string]]),
      ['cat', 'Category'],
      ['studio', 'Studio'],
      ['q', 'Quality'],
    ];
    const out: { key: Select; name: string; options: [string, number][] }[] = keys.map(([key, name]) => ({
      key,
      name,
      options: mostCommon(list.topics.map((t) => valueOf(t, key))),
    }));
    // The curated filters, in file order; at most one is active.
    if (list.curatedFilters.length)
      out.splice(1, 0, {
        key: 'f',
        name: 'Curated',
        options: list.curatedFilters.map((n) => [n, list.topics.filter((t) => t.filters.includes(n)).length]),
      });
    return out;
  });
  const tagCounts = $derived(mostCommon(list.topics.flatMap((t) => t.tags)));
  const known = $derived(new Set(tagCounts.map(([t]) => t)));
  const allTags = $derived([...known].sort());

  let typed = $state('');
  let q = $state(search ? (list.query ?? '') : '');

  function addTyped() {
    const t = typed.trim().toLowerCase();
    typed = '';
    fs.addTag(t);
  }

  // Picking a datalist suggestion adds it at once.
  function onTagInput() {
    const v = typed.trim().toLowerCase();
    if (known.has(v)) {
      typed = '';
      fs.addTag(v);
    }
  }

  function submit(e: SubmitEvent) {
    e.preventDefault();
    const v = q.trim();
    if (v) router.go('/search?q=' + encodeURIComponent(v));
  }
</script>

<div class="sm:sticky top-0 z-10 bg-base-100 py-2 mb-4 border-b border-base-300 flex flex-wrap items-center gap-2">
  {#if !games}
    <form class="join" role="search" onsubmit={submit}>
      <input class="input input-sm join-item w-48" type="search" bind:value={q} placeholder="Search the tracker" required />
      <button class="btn btn-sm join-item">Search</button>
    </form>
  {/if}
  <div class="join">
    {#each toggles as [k, name] (k)}
      <button type="button" class={['btn btn-sm join-item', fs.st[k] && 'btn-primary']} onclick={() => fs.toggle(k)}>{name}</button>
    {/each}
  </div>
  {#if !games}
    {#each selects as s (s.key)}
      <label class="select select-sm w-auto max-w-full">
        <span class="label">{s.name}</span>
        <select aria-label={s.name} bind:value={fs.st[s.key]}>
          <option value="">All</option>
          {#each s.options as [v, n] (v)}<option value={v}>{v} ({n})</option>{/each}
        </select>
      </label>
    {/each}
    <details class="dropdown">
      <summary class="btn btn-sm">
        Tags{#if fs.st.tags.length}<span class="badge badge-sm badge-primary">{fs.st.tags.length}</span>{/if}
      </summary>
      <div class="dropdown-content z-20 mt-1 w-80 max-w-[90vw] rounded-box bg-base-200 p-3 shadow-lg flex flex-col gap-2">
        <input
          class="input input-sm w-full"
          list="taglist"
          placeholder="type a tag"
          autocomplete="off"
          bind:value={typed}
          oninput={onTagInput}
          onkeydown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault();
              addTyped();
            }
          }}
        />
        <datalist id="taglist">
          {#each allTags as t (t)}<option value={t}></option>{/each}
        </datalist>
        <div class="flex flex-wrap gap-1 max-h-48 overflow-y-auto">
          {#each tagCounts.slice(0, 20) as [t, n] (t)}
            <button type="button" class={['btn btn-xs', fs.st.tags.includes(t) && 'btn-primary']} onclick={() => fs.toggleTag(t)}
              >{t}<span class="badge badge-xs">{n}</span></button
            >
          {/each}
        </div>
      </div>
    </details>
  {/if}
  <span class="flex flex-wrap gap-1">
    {#each fs.st.tags as t (t)}
      <button type="button" class="badge badge-primary cursor-pointer" onclick={() => fs.toggleTag(t)}>{t} ×</button>
    {/each}
  </span>
  <button type="button" class="btn btn-ghost btn-sm" onclick={() => fs.clear()}>Clear</button>
  <span class="ml-auto text-sm text-base-content/60">Showing {shown} of {list.topics.length}</span>
</div>
```

`src/components/GrabsStrip.svelte`:

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import { fetchGrabs } from '../lib/api';
  import { age } from '../lib/format';
  import type { Grab } from '../lib/types';
  import StatusBadge from './StatusBadge.svelte';

  let grabs = $state<Grab[]>([]);
  let now = $state(0);

  onMount(async () => {
    try {
      const r = await fetchGrabs();
      grabs = r.grabs;
      now = r.now;
    } catch {
      /* no strip */
    }
  });
</script>

{#if grabs.length}
  <details class="mb-4 rounded-box bg-base-200 p-3">
    <summary class="cursor-pointer font-semibold">Recent grabs ({grabs.length})</summary>
    <ul class="mt-2 flex flex-col gap-1">
      {#each grabs as g, i (i)}
        <li class="flex flex-wrap items-center gap-2 text-sm">
          <span class="font-semibold uppercase text-xs text-primary">{g.studio ?? ''}</span>
          <span class="break-all">{g.title}</span>
          <StatusBadge status={g.status} />
          <span class="text-xs text-base-content/60">{g.addedAt === null ? '' : age(g.addedAt, now)}</span>
        </li>
      {/each}
    </ul>
  </details>
{/if}
```

`src/components/Gallery.svelte`:

```svelte
<script lang="ts">
  import { imgUrl } from '../lib/api';

  let images = $state<string[]>([]);
  let dlg = $state<HTMLDialogElement>();

  export function open(keys: string[]) {
    images = keys;
    dlg?.showModal();
  }
</script>

<dialog bind:this={dlg} class="modal" onclose={() => (images = [])}>
  <button type="button" class="modal-box w-11/12 max-w-5xl p-2 cursor-zoom-out" onclick={() => dlg?.close()}>
    {#each images as img (img)}<img class="block mx-auto mb-3 max-w-full" loading="lazy" src={imgUrl(img)} alt="" />{/each}
  </button>
  <form method="dialog" class="modal-backdrop"><button>close</button></form>
</dialog>
```

`src/components/NewReleasesPill.svelte`:

```svelte
<script lang="ts">
  let { onreload }: { onreload: () => void } = $props();
</script>

<div class="toast toast-top toast-center z-30">
  <button type="button" class="btn btn-sm btn-accent shadow-lg" onclick={onreload}>New releases · reload</button>
</div>
```

`src/components/ListView.svelte`:

```svelte
<script lang="ts">
  import { onMount, untrack } from 'svelte';
  import { isVisible, offered, prune, toHash } from '../lib/filters';
  import { filters } from '../lib/filters.svelte';
  import { age, isFresh } from '../lib/format';
  import { link } from '../lib/router.svelte';
  import { topics } from '../lib/topics.svelte';
  import type { Section } from '../lib/types';
  import Card from './Card.svelte';
  import FilterBar from './FilterBar.svelte';
  import Gallery from './Gallery.svelte';
  import GrabsStrip from './GrabsStrip.svelte';
  import Navbar from './Navbar.svelte';
  import NewReleasesPill from './NewReleasesPill.svelte';
  import Player from './Player.svelte';

  let { kind, q = '' }: { kind: Section | 'search'; q?: string } = $props();
  // kind is fixed for this instance: App keys ListView by view and query.
  const fs = untrack(() => filters[kind]);
  const section: Section = untrack(() => (kind === 'search' ? 'video' : kind));
  let gallery = $state<ReturnType<typeof Gallery>>();
  let player = $state<ReturnType<typeof Player>>();

  fs.activate();
  onMount(() => {
    if (kind === 'search') void topics.search(q);
    else topics.ensure(kind);
  });

  const list = $derived(topics.lists[kind]);
  const newIds = $derived(kind === 'search' ? undefined : topics.newIds[kind]);
  const isNew = (id: number) => !!newIds?.has(String(id));
  const shown = $derived(
    list ? list.topics.filter((t) => isVisible(fs.st, t, isFresh(t.added, list.now), isNew(t.id))) : [],
  );
  const curated = $derived(list ? list.topics.filter((t) => t.filters.length).length : 0);

  // A saved value no longer offered would hide every card.
  $effect(() => {
    if (!list) return;
    const p = prune(fs.st, offered(list));
    if (p !== fs.st) fs.st = p;
  });
  $effect(() => {
    toHash(fs.st);
    untrack(() => fs.save());
  });
</script>

<Navbar>
  {#if list}
    {#if kind === 'search'}
      <a class="link link-hover" href="/" use:link>← weekly list</a> ·
      {#if list.error}<span class="text-error">{list.error}</span>{:else}
        {list.topics.length} result{list.topics.length === 1 ? '' : 's'} for “{list.query}” · all time
      {/if}
    {:else}
      {list.topics.length} releases · {kind === 'games' ? 'last 32 days' : 'last 7 days'} · updated {age(list.updated, list.now)}
      {#if curated}· {curated} curated{/if}
      {#if list.pending}· {list.pending} queued{/if}
      {#if newIds?.size}· {newIds.size} new{/if}
    {/if}
  {/if}
</Navbar>

{#if topics.errors[kind]}<div role="alert" class="alert alert-error mb-4">{topics.errors[kind]}</div>{/if}
{#if kind !== 'search' && topics.stale[section]}<NewReleasesPill onreload={() => topics.load(section)} />{/if}

{#if list}
  <FilterBar {kind} {list} {fs} shown={shown.length} />
  {#if kind === 'video'}<GrabsStrip />{/if}
  <div class="grid gap-4 grid-cols-[repeat(auto-fill,minmax(min(280px,100%),1fr))]">
    {#each shown as t (t.id)}
      <Card
        topic={t}
        {section}
        now={list.now}
        topicUrl={list.topicUrl}
        isNew={isNew(t.id)}
        {fs}
        stream={section === 'video'}
        ongallery={(images) => gallery?.open(images)}
        onstream={(id) => player?.open(id)}
      />
    {/each}
  </div>
{:else if !topics.errors[kind]}
  <span class="loading loading-dots"></span>
{/if}

<Gallery bind:this={gallery} />
{#if section === 'video'}<Player bind:this={player} />{/if}
```

`src/App.svelte`:

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import { live } from './lib/events.svelte';
  import { jobs } from './lib/jobs.svelte';
  import { router } from './lib/router.svelte';
  import { topics } from './lib/topics.svelte';
  import JobsView from './components/JobsView.svelte';
  import ListView from './components/ListView.svelte';

  onMount(() => {
    live.on((ev) => {
      topics.apply(ev);
      jobs.apply(ev);
    });
    live.onReconnect(() => {
      topics.resync(router.route.view);
      if (router.route.view === 'jobs') void jobs.load();
    });
    live.start();
  });
</script>

<div class="p-4">
  {#if router.route.view === 'jobs'}
    <JobsView />
  {:else if router.route.view === 'search'}
    {#key router.route.q}<ListView kind="search" q={router.route.q} />{/key}
  {:else}
    {#key router.route.view}<ListView kind={router.route.view} />{/key}
  {/if}
</div>
```

`App` imports `JobsView`, which Task 10 writes. For now, create `src/components/JobsView.svelte` containing only `<p>jobs</p>`.

- [ ] **Step 2: Check and build**

Run: `npm run check`, then `npm test`, then `npm run build`.
Expected: clean. Fix any svelte-check warning at its source. For example, if it reports `state_referenced_locally` for `list.query` in FilterBar's initial `q`, wrap the initial value in `untrack(() => …)`.

- [ ] **Step 3: Smoke-test against galactica**

Run `ssh -L 8577:127.0.0.1:8577 galactica` in one terminal and `npm run dev` in another, then open the printed URL. Check each of these, and fix anything that differs from the live page at `https://plab.arsfeld.one`:
- The grid loads with images.
- Filters filter, survive a reload, and appear in the hash.
- A tag pill toggles its tag.
- The Games tab switches instantly the second time.
- A search shows results with lazy thumbnails.
- The gallery opens.

- [ ] **Step 4: Commit (local only)**

```bash
git add packages/plab/ui
git commit -m "feat(galactica): plab-ui list views, cards, filters and gallery"
```

---

### Task 10: the player and the jobs view

**Files:**
- Modify: `src/components/Player.svelte` (replace the stub), `src/components/JobsView.svelte` (replace the stub)
- Create: `src/components/JobCard.svelte`

**Interfaces:**
- Consumes: `streamCall`, `HttpError`, `streamProgress`, `jobs`, `clock`, `jobWhen`, and `duration`.
- Produces: `Player.open(id)`, as ListView calls it.

- [ ] **Step 1: Write the player** (a port of page.js `openStream` and its neighbours; the same behaviours)

`src/components/Player.svelte`:

```svelte
<script lang="ts">
  import { onDestroy } from 'svelte';
  import { HttpError, streamCall } from '../lib/api';
  import { streamProgress } from '../lib/stream';
  import type { Stats, StreamFile } from '../lib/types';

  interface Info {
    files: StreamFile[];
    selected: number;
    external: string | null;
  }
  interface Poll {
    stats?: Stats;
    starting?: { step: string; since: number };
  }

  let dlg = $state<HTMLDialogElement>();
  let video = $state<HTMLVideoElement>();
  let id = $state<number | null>(null);
  let files = $state<StreamFile[]>([]);
  let selected = $state<number | null>(null);
  let src = $state('');
  let external = $state('');
  let progress = $state('');
  let error = $state('');
  let copied = $state(false);
  // Not shown, only read by the timers.
  let started = 0;
  let posted = false;
  let step = 'Starting';
  let starting = false;
  let pollTimer: ReturnType<typeof setInterval> | undefined;
  let clockTimer: ReturnType<typeof setInterval> | undefined;

  const message = (e: unknown) => (e instanceof Error ? e.message : String(e));

  function stopTimers() {
    clearInterval(pollTimer);
    clearInterval(clockTimer);
  }

  // The start line while the engine is not up yet: "<step>… <n>s".
  function tick() {
    if (id === null || !starting) return;
    progress = `${step}… ${Math.floor((Date.now() - started) / 1000)}s`;
  }

  function apply(t: number, j: Info) {
    id = t;
    files = j.files ?? [];
    selected = j.selected;
    src = `/api/stream/${t}/${j.selected}`;
    external = j.external ?? '';
    error = '';
  }

  export async function open(t: number) {
    id = t;
    files = [];
    selected = null;
    src = '';
    external = '';
    progress = 'Starting… 0s';
    error = '';
    copied = false;
    started = Date.now();
    posted = false;
    step = 'Starting';
    starting = true;
    dlg?.showModal();
    // Poll at once: the POST can take minutes, and the poll says what it is doing. The
    // poll is also the stream's keep-alive (each counts as a read for the reaper).
    stopTimers();
    pollTimer = setInterval(poll, 2000);
    clockTimer = setInterval(tick, 1000);
    void poll();
    try {
      const j = await streamCall<Info>(`${t}`, 'POST');
      if (id !== t) return; // closed, or reopened on another topic, meanwhile
      posted = true;
      apply(t, j);
      void poll();
    } catch (e) {
      if (id !== t) return;
      stopTimers();
      starting = false;
      progress = '';
      error = message(e);
    }
  }

  async function select(index: number) {
    const t = id;
    if (t === null) return;
    try {
      const j = await streamCall<Info>(`${t}/select/${index}`, 'POST');
      if (id === t) apply(t, j);
    } catch (e) {
      if (id === t) error = message(e);
    }
  }

  async function poll() {
    const t = id;
    if (t === null) return;
    // A 404 before the POST resolved only means the start has not registered yet.
    const wasPosted = posted;
    try {
      const j = await streamCall<Poll>(`${t}`);
      if (id !== t) return;
      if (j.starting) {
        starting = true;
        step = j.starting.step;
        tick();
        return;
      }
      starting = false;
      if (!j.stats) return;
      progress = streamProgress(j.stats, files, selected, Date.now() - started);
      if (j.stats.error) error = j.stats.error;
    } catch (e) {
      if (id !== t) return;
      const status = e instanceof HttpError ? e.status : 0;
      if (status === 410 || (status === 404 && wasPosted)) {
        stopTimers();
        starting = false;
        src = '';
        error = message(e) + ' — press Stream again';
      } else if (status === 502) {
        starting = false;
        progress = message(e);
      }
    }
  }

  // Closing does not stop the stream: a VLC playback keeps it alive until the reaper.
  function onclose() {
    stopTimers();
    video?.pause();
    src = '';
    id = null;
  }

  async function stop() {
    const t = id;
    dlg?.close();
    if (t !== null) {
      try {
        await fetch(`/api/stream/${t}`, { method: 'DELETE' });
      } catch {
        /* the reaper takes it */
      }
    }
  }

  async function copy() {
    try {
      await navigator.clipboard.writeText(external);
      copied = true;
      setTimeout(() => (copied = false), 2000);
    } catch {
      window.prompt('Stream URL', external);
    }
  }

  onDestroy(stopTimers);
</script>

<dialog bind:this={dlg} class="modal" {onclose}>
  <div class="modal-box w-11/12 max-w-5xl p-3">
    {#if error}<p class="text-error text-sm">{error}</p>{/if}
    {#if src}
      <!-- svelte-ignore a11y_media_has_caption -->
      <video bind:this={video} class="w-full max-h-[70vh] bg-black" controls autoplay {src}></video>
    {/if}
    <div class="flex flex-wrap items-center gap-2 mt-2">
      {#if files.length > 1}
        <select class="select select-sm max-w-xs" value={selected} onchange={(e) => select(+e.currentTarget.value)}>
          {#each files as f (f.index)}<option value={f.index}>{f.name}</option>{/each}
        </select>
      {/if}
      <span class="text-sm text-base-content/70">{progress}</span>
      <span class="grow"></span>
      {#if external}
        <button type="button" class="btn btn-sm" onclick={copy}>{copied ? 'Copied ✓' : 'Copy URL for VLC'}</button>
      {/if}
      <button type="button" class="btn btn-sm btn-error" onclick={stop}>Stop</button>
    </div>
  </div>
  <form method="dialog" class="modal-backdrop"><button>close</button></form>
</dialog>
```

- [ ] **Step 2: Write the jobs view**

`src/components/JobCard.svelte`:

```svelte
<script lang="ts">
  import { clock } from '../lib/clock.svelte';
  import { duration } from '../lib/format';
  import { jobWhen } from '../lib/jobtime';
  import type { Job } from '../lib/types';

  let { job }: { job: Job } = $props();
  const BADGE = { running: 'badge-success', watching: 'badge-neutral', idle: 'badge-neutral', restarting: 'badge-error' } as const;
  const LEVEL: Record<string, string> = { ERROR: 'text-error', WARN: 'text-warning' };
  const last = $derived(job.runs.find((r) => r.finished !== null));
  const result = (ok: boolean | null, error: string | null) =>
    ok ? 'ok' : error === 'interrupted' ? 'interrupted' : (error ?? 'failed');
</script>

<div class="card bg-base-200 shadow-sm">
  <div class="card-body p-4 gap-2">
    <div class="flex flex-wrap items-center gap-2">
      <h2 class="card-title text-base">{job.name}</h2>
      <span class={['badge badge-sm', BADGE[job.state]]}
        >{job.state}{#if job.state === 'watching' && job.pending} · {job.pending} pending{/if}</span
      >
      <span class="ml-auto text-xs text-base-content/60">{jobWhen(job, clock.now)}</span>
    </div>
    {#if job.step}
      <p class="text-sm break-words">
        {job.step.msg} <span class="text-xs text-base-content/50">{duration(Math.max(0, clock.now - job.step.at))} ago</span>
      </p>
    {/if}
    {#if job.progress}
      <div class="flex items-center gap-2">
        <progress class="progress progress-primary grow" value={job.progress[0]} max={job.progress[1]}></progress>
        <span class="text-xs">{job.progress[0]} / {job.progress[1]}</span>
      </div>
    {/if}
    {#if last}
      <p class="text-xs">
        last run {last.ok ? 'ok' : last.error === 'interrupted' ? 'interrupted' : 'failed'} · took {duration(
          (last.finished ?? last.started) - last.started,
        )}
      </p>
      {#if !last.ok && last.error && last.error !== 'interrupted'}
        <details>
          <summary class="text-xs text-error cursor-pointer">error</summary>
          <pre class="text-xs whitespace-pre-wrap break-words">{last.error}</pre>
        </details>
      {/if}
    {/if}
    <details class="collapse collapse-arrow bg-base-100">
      <summary class="collapse-title text-sm">Log</summary>
      <div class="collapse-content">
        <ul class="text-xs font-mono flex flex-col gap-1">
          {#each [...job.lines].reverse() as l, i (i)}<li class={LEVEL[l.level] ?? ''}>{l.msg}</li>{/each}
        </ul>
      </div>
    </details>
    <details class="collapse collapse-arrow bg-base-100">
      <summary class="collapse-title text-sm">History</summary>
      <div class="collapse-content overflow-x-auto">
        <table class="table table-xs">
          <thead><tr><th>started</th><th>took</th><th>result</th></tr></thead>
          <tbody>
            {#each job.runs as r, i (i)}
              <tr>
                <td>{new Date(r.started * 1000).toLocaleString()}</td>
                <td>{r.finished === null ? 'running' : duration(r.finished - r.started)}</td>
                <td class={r.ok ? 'text-success' : r.ok === false ? 'text-error' : ''}>{r.finished === null ? '…' : result(r.ok, r.error)}</td>
              </tr>
            {/each}
          </tbody>
        </table>
      </div>
    </details>
  </div>
</div>
```

`src/components/JobsView.svelte`:

```svelte
<script lang="ts">
  import { onMount } from 'svelte';
  import { jobs } from '../lib/jobs.svelte';
  import JobCard from './JobCard.svelte';
  import Navbar from './Navbar.svelte';

  onMount(() => {
    void jobs.load();
  });
</script>

<Navbar>{jobs.list.length} job{jobs.list.length === 1 ? '' : 's'}</Navbar>
{#if jobs.error}<div role="alert" class="alert alert-error mb-4">{jobs.error}</div>{/if}
<div class="grid gap-4 grid-cols-[repeat(auto-fill,minmax(min(360px,100%),1fr))]">
  {#each jobs.list as job (job.name)}<JobCard {job} />{/each}
</div>
```

- [ ] **Step 3: Check, build and smoke-test**

Run: `npm run check`, then `npm test`, then `npm run build`.
Expected: clean.

The dev server against galactica can't show the jobs page or live events yet, because galactica still runs the old binary. Instead, run the new Rust locally and point Vite at it. From `packages/plab/`, run `PLAB_STATE_DIR=$(mktemp -d) PLAB_DOWNLOAD_DIR=/tmp cargo run -- serve --tasks web --port 8599`, then `PLAB_DEV_BACKEND=http://127.0.0.1:8599 npm run dev`. If `serve` needs more of the environment to start, read `config.rs` for the required variables and set dummies. Then check:
- `/jobs` renders, even if it lists no jobs.
- The connection dot is green.
- Killing the server turns the dot amber, and restarting it turns the dot green again.

- [ ] **Step 4: Commit (local only)**

```bash
git add packages/plab/ui
git commit -m "feat(galactica): plab-ui stream player and jobs monitor"
```

---

### Task 11: Nix packaging, deployment wiring and docs

**Files:**
- Modify: `packages/plab/package.nix`
- Modify: `modules/hosts/galactica/services/plab/default.nix` (the `static` linkFarm near line 52 and `PLAB_STATIC_DIR` near line 100; the header comment)
- Modify: `justfile` (add `plab-ui-dev` after `update-packages`)
- Modify: `CLAUDE.md` (the host-local modules line mentioning plab)

**Interfaces:**
- Produces: `pkgs.plab.ui`, a store path holding `index.html` and `assets/`.

- [ ] **Step 1: Package the UI**

`packages/plab/package.nix`:

```nix
{
  lib,
  rustPlatform,
  buildNpmPackage,
}: let
  # The Svelte app, served by plab from PLAB_STATIC_DIR. Its own derivation: a Rust change
  # does not rebuild it, and a UI change does not rebuild plab.
  ui = buildNpmPackage {
    pname = "plab-ui";
    version = "0.1.0";
    src = lib.fileset.toSource {
      root = ./ui;
      fileset = lib.fileset.unions [
        ./ui/package.json
        ./ui/package-lock.json
        ./ui/index.html
        ./ui/vite.config.ts
        ./ui/svelte.config.js
        ./ui/tsconfig.json
        ./ui/src
      ];
    };
    npmDepsHash = lib.fakeHash;
    # svelte-check and vitest gate the build, as cargo test gates plab's.
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      npm run check
      npm test
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      cp -r dist $out
      runHook postInstall
    '';
  };
in
  rustPlatform.buildRustPackage {
    pname = "plab";
    version = "0.1.0";
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./Cargo.toml
        ./Cargo.lock
        ./src
        (lib.fileset.maybeMissing ./tests)
      ];
    };
    cargoLock.lockFile = ./Cargo.lock;
    # cargo test runs in checkPhase (the default): a failing test fails the galactica build.
    passthru = {inherit ui;};
    meta = {
      description = "plab: tracker app, Stash identification and studio grabs for galactica";
      mainProgram = "plab";
    };
  }
```

- [ ] **Step 2: Get the npm hash and build**

From the repo root:

```bash
git add -A packages/plab
nix build .#plab.ui 2>&1 | grep -A2 'got:'
```

Copy the `got: sha256-…` value into `npmDepsHash`, then run `nix build .#plab.ui && ls result result/assets`.
Expected: `index.html` and `assets/index-*.js` and `index-*.css`.
Then check the size target: `cat result/assets/*.js result/assets/*.css | gzip -9 | wc -c` should be under about 61440 (60 KiB). Over that, look at what is large; it does not fail the build.

If the build fails loading a native addon (`@rolldown/binding-*`, `@tailwindcss/oxide-*` or `lightningcss-*`) with `libstdc++.so.6: cannot open shared object file`, add `nativeBuildInputs = [autoPatchelfHook];` and `buildInputs = [stdenv.cc.cc.lib];` to `ui` (and `autoPatchelfHook` and `stdenv` to the function arguments), then rebuild. Don't change bundlers to avoid it.

- [ ] **Step 3: Point galactica at it**

In `modules/hosts/galactica/services/plab/default.nix`:
- Delete the `static = pkgs.linkFarm "plab-static" [ … ];` binding and the comment above it.
- Change the `PLAB_STATIC_DIR` export to:

```nix
        export PLAB_STATIC_DIR="''${PLAB_STATIC_DIR:-${pkgs.plab.ui}}"
```

- In the header comment, after the Provenance design line, add:

```nix
# The page is a Svelte app (packages/plab/ui, built as plab.ui) over plab's JSON API and
# its SSE stream (/api/events); the jobs monitor is its Jobs tab.
# Design: docs/superpowers/specs/2026-11-02-plab-svelte-app-design.md
```

Build the host closure (one host at a time, niced, per the standing rule):

```bash
nice nix build .#nixosConfigurations.galactica.config.system.build.toplevel
```

Expected: builds.

- [ ] **Step 4: Add the dev recipe**

In `justfile`, after the `update-packages` recipe:

```just
# plab's Svelte app with hot reload. /api (and its SSE stream) goes to PLAB_DEV_BACKEND,
# default http://127.0.0.1:8577: a local `plab serve`, or galactica's through
# `ssh -L 8577:127.0.0.1:8577 galactica`.
plab-ui-dev:
    cd packages/plab/ui && nix shell --inputs-from {{ justfile_directory() }} nixpkgs#nodejs -c sh -c 'npm install && npm run dev'
```

- [ ] **Step 5: Update CLAUDE.md**

In `CLAUDE.md`, change `plab/` (plab is a Rust daemon in `packages/plab`) to `plab/` (plab is a Rust daemon in `packages/plab`, with its Svelte app in `packages/plab/ui`).

- [ ] **Step 6: Format and commit (local only)**

```bash
just fmt
git add -A packages/plab modules/hosts/galactica/services/plab/default.nix justfile CLAUDE.md
git commit -m "feat(galactica): plab serves the Svelte app built by Nix"
```

---

### Task 12: squash, push, deploy, verify

- [ ] **Step 1: Run the full gate one last time**

```bash
nix build .#plab .#plab.ui
nice nix build .#nixosConfigurations.galactica.config.system.build.toplevel
```

Also run `grep -rn 'alpine\|tailwind.js\|daisyui.css\|page::' packages/plab/src modules/hosts/galactica/services/plab`, which must print nothing.

- [ ] **Step 2: Squash into one commit**

```bash
git reset --soft "$(cat /tmp/claude-1000/plab-svelte-base)"
git commit -m "feat(galactica): plab is a Svelte app over a JSON API and SSE" -m "The page is a Svelte 5 app (packages/plab/ui, built as plab.ui) over a JSON API under /api and one SSE stream at /api/events. page.rs, page.js, the golden fixtures and the vendored daisyUI, Tailwind runtime and Alpine are gone. The jobs monitor lands with it: a tracing layer tracks each job's step and progress, job_history keeps its runs, and the app's Jobs tab shows both live. Design: docs/superpowers/specs/2026-11-02-plab-svelte-app-design.md"
git log --oneline -3
```

Expected: one new commit on top of the plan and spec commits.

- [ ] **Step 3: Push**

```bash
git push -u origin master
```

- [ ] **Step 4: Deploy galactica, and ask the user first.** Deploying restarts plab and is outward-facing, so get an explicit go-ahead, then run `just deploy galactica` from raider.

- [ ] **Step 5: Verify by hand on `https://plab.arsfeld.one`**, and report each result with what you saw:
  - The Videos list renders like before: images, badges, NEW marks, and the counts in the summary.
  - Saved filters survived the switch, from the same browser that used the old page.
  - Add a release on a phone and watch the desktop card flip to "Added ✓" without a reload.
  - Switch to Games and back: instant, with no spinner the second time.
  - Search runs without a page load, and thumbnails fill in lazily.
  - Stream a release: progress moves, Copy URL works, and Stop works.
  - `/jobs` during a watcher pass (copy a file into the library): the identify card shows running, then its step and progress move, then it returns to watching.
  - Restart plab (`ssh galactica sudo systemctl restart plab`) with the page open: the dot goes amber, then green, and the view refetches. Do it again during a refresh run, and check the jobs page lists that run as `interrupted`.
  - With the page open, `curl -sN https://plab.arsfeld.one/api/events` (from a browser session, or on galactica: `curl -sN 127.0.0.1:8577/api/events`) prints `: keep-alive` every 15 s. That proves the gateway and the tunnel pass SSE unbuffered. If events arrive in bursts instead, the gateway is buffering, so stop and report it rather than working around it.
