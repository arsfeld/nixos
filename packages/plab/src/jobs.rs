//! The daemon's scheduling: UTC-aligned slots per periodic job, a job run recorded in
//! `job_run`, and a supervisor that restarts a stopped task after a backoff.

use std::future::Future;
use std::time::Duration;

use crate::db::Db;
use crate::monitor::LiveState;

/// Slots at `offset + k * period` seconds since the Unix epoch.
#[derive(Clone, Copy, Debug)]
pub struct Schedule {
    pub period: i64,
    pub offset: i64,
}

pub const REFRESH: Schedule = Schedule {
    period: 3 * 3600,
    offset: 0,
};
pub const GRAB: Schedule = Schedule {
    period: 3 * 3600,
    offset: 3600 + 1800,
};
pub const PRUNE: Schedule = Schedule {
    period: 3600,
    offset: 0,
};
pub const SWEEP: Schedule = Schedule {
    period: 24 * 3600,
    offset: 4 * 3600,
};

/// Daily at 07:00 UTC: clear of the 06:00 refresh and the 04:00 sweep.
pub const CURATED: Schedule = Schedule {
    period: 24 * 3600,
    offset: 7 * 3600,
};

/// The greatest slot at or before `now`.
pub fn last_slot(s: Schedule, now: i64) -> i64 {
    now - (now - s.offset).rem_euclid(s.period)
}

/// The smallest slot after `now`.
pub fn next_slot(s: Schedule, now: i64) -> i64 {
    last_slot(s, now) + s.period
}

/// Whether the job has not started since the current slot began: never run, or a slot
/// passed (the daemon was down, say) since it last started. A job overdue at daemon start
/// runs at once, as systemd's `Persistent=true` timers did.
pub fn overdue(s: Schedule, last_started: Option<i64>, now: i64) -> bool {
    last_started.is_none_or(|t| t < last_slot(s, now))
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

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
    // The jobs page's history is best-effort: a failed write is logged, never the job's.
    let run = db
        .history_start(name, started)
        .inspect_err(|e| tracing::warn!("{name}: history_start failed: {e:#}"))
        .ok();
    mon.set_state(name, LiveState::Running { since: started });
    let res = job.await;
    let error = res.as_ref().err().map(|e| format!("{e:#}"));
    let finished = unix_now();
    // Order matters: the monitor's pump publishes whatever the history says the moment the
    // state changes, so the history row must be finished before the state moves.
    let marked = db.job_finished(name, finished, error.as_deref());
    if let Some(run) = run
        && let Err(e) = db.history_finish(run, name, finished, error.as_deref())
    {
        tracing::warn!("{name}: history_finish failed: {e:#}");
    }
    // The watcher goes back to watching; it refreshes the pending count itself.
    mon.set_state(
        name,
        if name == "identify" {
            LiveState::Watching { pending: 0 }
        } else {
            LiveState::Idle
        },
    );
    marked?;
    res
}

/// A periodic job's schedule by name; None for the identify watcher.
pub fn schedule(name: &str) -> Option<Schedule> {
    match name {
        "sweep" => Some(SWEEP),
        "curated" => Some(CURATED),
        "refresh" => Some(REFRESH),
        "grab" => Some(GRAB),
        "prune" => Some(PRUNE),
        _ => None,
    }
}

/// Run `job` whenever it is overdue, then sleep to the next slot. A failed run is logged
/// and waits for the next slot; only a database error ends the loop.
pub async fn run_periodic<F, Fut>(
    db: Db,
    name: &'static str,
    s: Schedule,
    job: F,
) -> anyhow::Result<()>
where
    F: Fn() -> Fut,
    Fut: Future<Output = anyhow::Result<()>>,
{
    loop {
        if overdue(s, db.job_last_started(name)?, unix_now())
            && let Err(e) = record(&db, name, job()).await
        {
            tracing::error!("{name} failed: {e:#}");
        }
        let now = unix_now();
        let wait = (next_slot(s, now) - now).max(1) as u64;
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}

const BACKOFF_MIN: Duration = Duration::from_secs(30);
const BACKOFF_MAX: Duration = Duration::from_secs(600);
/// A task that ran this long before stopping was healthy: its backoff starts over.
const HEALTHY_RUN: Duration = Duration::from_secs(600);

/// (wait before this restart, the backoff for the next one), given the current backoff and
/// how long the task ran.
pub fn backoff(current: Duration, ran: Duration) -> (Duration, Duration) {
    let wait = if ran >= HEALTHY_RUN {
        BACKOFF_MIN
    } else {
        current
    };
    (wait, (wait * 2).min(BACKOFF_MAX))
}

/// Run `task` forever: when it stops (an error, a panic, or an unexpected return), log it
/// and restart it after a backoff, 30 s doubling to 10 min. Its log lines carry
/// `job=<name>`.
pub async fn supervise<F, Fut>(name: &'static str, task: F)
where
    F: Fn() -> Fut + Send + Sync + 'static,
    Fut: Future<Output = anyhow::Result<()>> + Send + 'static,
{
    use tracing::Instrument;
    let span = tracing::info_span!("task", job = %name);
    let mut next = BACKOFF_MIN;
    loop {
        let started = tokio::time::Instant::now();
        let outcome = tokio::spawn(task().instrument(span.clone())).await;
        span.in_scope(|| match outcome {
            Ok(Ok(())) => tracing::error!("task {name} stopped: returned"),
            Ok(Err(e)) => tracing::error!("task {name} stopped: {e:#}"),
            Err(e) => tracing::error!("task {name} stopped: {e}"),
        });
        let (wait, after) = backoff(next, started.elapsed());
        next = after;
        let mon = crate::monitor::global();
        mon.set_state(
            name,
            LiveState::Restarting {
                at: unix_now() + wait.as_secs() as i64,
            },
        );
        tokio::time::sleep(wait).await;
        mon.set_state(name, LiveState::Idle);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[test]
    fn slots_align_to_utc() {
        // 2026-11-01T02:59:59Z
        let now = 1_793_501_999;
        assert_eq!(last_slot(REFRESH, now) % (3 * 3600), 0);
        assert_eq!(next_slot(REFRESH, now) - last_slot(REFRESH, now), 3 * 3600);
        assert_eq!((last_slot(GRAB, now) - 5400).rem_euclid(3 * 3600), 0);
    }

    #[test]
    fn slot_boundaries() {
        let slot = 1_793_498_400; // 2026-11-01T02:00:00Z, a prune slot
        assert_eq!(last_slot(PRUNE, slot), slot);
        assert_eq!(next_slot(PRUNE, slot), slot + 3600);
        assert_eq!(last_slot(PRUNE, slot - 1), slot - 3600);
        assert_eq!(next_slot(GRAB, slot), slot + 9000); // 04:30Z
        assert!(last_slot(SWEEP, slot) <= slot && slot < next_slot(SWEEP, slot));
        assert_eq!((last_slot(SWEEP, slot) - 4 * 3600) % 86400, 0);
    }

    #[test]
    fn overdue_when_never_run_or_missed_a_slot() {
        let now = 1_793_501_999;
        assert!(overdue(PRUNE, None, now));
        assert!(overdue(PRUNE, Some(last_slot(PRUNE, now) - 1), now));
        assert!(!overdue(PRUNE, Some(last_slot(PRUNE, now)), now));
    }

    // stash-identify's watch loop decided the sweep; these replace its tests.

    #[test]
    fn sweep_runs_at_startup_when_never_run() {
        assert!(overdue(SWEEP, None, 1_793_501_999));
    }

    #[test]
    fn sweep_not_starved_by_pending_events() {
        // The sweep is its own job, independent of the watcher's pending folders: once a
        // day has passed since it last ran, it is due, whatever the watcher is doing.
        let ran = 1_793_501_999;
        assert!(!overdue(SWEEP, Some(ran), ran + 60));
        assert!(overdue(SWEEP, Some(ran), ran + 24 * 3600));
    }

    #[test]
    fn nothing_due() {
        let now = 1_793_501_999;
        for s in [SWEEP, REFRESH, GRAB, PRUNE] {
            assert!(!overdue(s, Some(now), now));
            assert!(!overdue(s, Some(now - 1), now));
        }
    }

    #[tokio::test]
    async fn record_marks_started_and_finished() {
        let db = Db::open_in_memory().unwrap();
        record(&db, "prune", async { Ok(()) }).await.unwrap();
        assert!(db.job_last_started("prune").unwrap().is_some());
        let e = record(&db, "grab", async { anyhow::bail!("boom") })
            .await
            .unwrap_err();
        assert_eq!(e.to_string(), "boom");
        assert!(db.job_last_started("grab").unwrap().is_some());
        assert_eq!(db.job_last_started("refresh").unwrap(), None);
    }

    #[tokio::test]
    async fn record_writes_history_and_moves_the_monitor() {
        use crate::monitor::{LiveState, global};
        let db = Db::open_in_memory().unwrap();
        let m = global();
        m.register("test-record"); // a name no other test uses: the monitor is global
        record(&db, "test-record", async {
            assert!(matches!(
                m.get("test-record").unwrap().state,
                LiveState::Running { .. }
            ));
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
        // Both rows are finished by the time record returns.
        assert!(runs.iter().all(|r| r.finished.is_some()));
    }

    #[test]
    fn curated_runs_daily_at_seven_utc() {
        let day = 86400;
        assert_eq!(schedule("curated").unwrap().period, day);
        assert_eq!(last_slot(CURATED, 10 * day + 8 * 3600), 10 * day + 7 * 3600);
        assert_eq!(next_slot(CURATED, 10 * day + 8 * 3600), 11 * day + 7 * 3600);
        assert!(overdue(
            CURATED,
            Some(10 * day + 6 * 3600),
            10 * day + 7 * 3600
        ));
    }

    #[test]
    fn schedules_by_name() {
        assert_eq!(schedule("prune").map(|s| s.period), Some(PRUNE.period));
        assert_eq!(schedule("sweep").map(|s| s.offset), Some(SWEEP.offset));
        assert!(schedule("identify").is_none());
    }

    #[test]
    fn backoff_doubles_to_ten_minutes_and_resets_after_a_long_run() {
        let s = Duration::from_secs;
        assert_eq!(backoff(s(30), s(1)), (s(30), s(60)));
        assert_eq!(backoff(s(60), s(1)), (s(60), s(120)));
        assert_eq!(backoff(s(480), s(1)), (s(480), s(600)));
        assert_eq!(backoff(s(600), s(1)), (s(600), s(600)));
        // A run of 10 min or more was healthy: start over at 30 s.
        assert_eq!(backoff(s(600), s(600)), (s(30), s(60)));
    }

    /// Runs `body` on a paused-clock runtime in its own thread, bounded in real time so a
    /// supervisor that never yields fails the test instead of hanging the suite.
    fn paused<T: Send + 'static>(body: impl Future<Output = T> + Send + 'static) -> T {
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .start_paused(true)
                .build()
                .unwrap();
            let _ = tx.send(rt.block_on(body));
        });
        rx.recv_timeout(Duration::from_secs(30))
            .expect("supervise did not yield")
    }

    #[test]
    fn supervise_restarts_a_failing_task() {
        let n = paused(async {
            let n = Arc::new(AtomicUsize::new(0));
            let n2 = n.clone();
            tokio::spawn(supervise("t", move || {
                let n = n2.clone();
                async move {
                    n.fetch_add(1, Ordering::SeqCst);
                    anyhow::bail!("x")
                }
            }));
            tokio::time::sleep(Duration::from_secs(100)).await;
            n.load(Ordering::SeqCst)
        });
        // Runs at 0, 30 and 90 s.
        assert!(n >= 3);
        assert_eq!(n, 3);
    }

    #[test]
    fn supervise_restarts_a_panicking_task() {
        let n = paused(async {
            let n = Arc::new(AtomicUsize::new(0));
            let n2 = n.clone();
            tokio::spawn(supervise("t", move || {
                let n = n2.clone();
                async move {
                    if n.fetch_add(1, Ordering::SeqCst) < 5 {
                        panic!("deliberate");
                    }
                    Ok(())
                }
            }));
            tokio::time::sleep(Duration::from_secs(40)).await;
            n.load(Ordering::SeqCst)
        });
        assert_eq!(n, 2);
    }
}
