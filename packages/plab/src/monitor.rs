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
    Running {
        since: i64,
    },
    /// The identify watcher between passes, with its pending folder count.
    Watching {
        pending: usize,
    },
    Restarting {
        at: i64,
    },
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
        JobLive {
            state: LiveState::Idle,
            step: None,
            progress: None,
            lines: VecDeque::new(),
        }
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

    #[cfg(test)]
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
        let Some(scope) = ctx.event_scope(event) else {
            return;
        };
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
        run(&m, || {
            in_task("grab", || tracing::info!("[Studio] searching"))
        });
        let l = m.get("grab").unwrap();
        let step = l.step.unwrap();
        assert_eq!(
            (step.msg.as_str(), step.level.as_str()),
            ("[Studio] searching", "INFO")
        );
        assert_eq!(l.lines.len(), 1);
    }

    #[test]
    fn the_ring_keeps_the_last_twenty() {
        let m = Monitor::default();
        m.register("prune");
        run(&m, || {
            in_task("prune", || (0..25).for_each(|i| tracing::info!("line {i}")))
        });
        let l = m.get("prune").unwrap();
        assert_eq!(l.lines.len(), RING);
        assert_eq!(l.lines.front().unwrap().msg, "line 5");
        assert_eq!(l.lines.back().unwrap().msg, "line 24");
    }

    #[test]
    fn done_and_total_set_progress_and_a_state_change_clears_it() {
        let m = Monitor::default();
        m.register("identify");
        run(&m, || {
            in_task("identify", || {
                tracing::info!(done = 3usize, total = 7usize, "[9] scene")
            })
        });
        assert_eq!(m.get("identify").unwrap().progress, Some((3, 7)));
        m.set_state("identify", LiveState::Watching { pending: 1 });
        let l = m.get("identify").unwrap();
        assert_eq!(
            (l.progress, l.state),
            (None, LiveState::Watching { pending: 1 })
        );
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
