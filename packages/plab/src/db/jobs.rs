//! Job runs: last start per job and the bounded run history.

use super::*;

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

impl Db {
    // jobs

    pub fn job_last_started(&self, job: &str) -> Result<Option<i64>> {
        self.with(|c| {
            let v: Option<Option<i64>> = c
                .query_row(
                    "SELECT last_started FROM job_run WHERE job = ?1",
                    [job],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(v.flatten())
        })
    }

    pub fn job_started(&self, job: &str, now: i64) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO job_run (job, last_started) VALUES (?1, ?2)
                 ON CONFLICT(job) DO UPDATE SET last_started = excluded.last_started",
                params![job, now],
            )?;
            Ok(())
        })
    }

    pub fn job_finished(&self, job: &str, now: i64, error: Option<&str>) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO job_run (job, last_finished, ok, error) VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(job) DO UPDATE SET last_finished = excluded.last_finished, ok = excluded.ok, error = excluded.error",
                params![job, now, error.is_none(), error],
            )?;
            Ok(())
        })
    }

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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn job_run_records_start() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.job_last_started("prune").unwrap(), None);
        db.job_started("prune", 50).unwrap();
        db.job_finished("prune", 60, Some("boom")).unwrap();
        assert_eq!(db.job_last_started("prune").unwrap(), Some(50));
    }

    // test_corrupt_json_reads_as_defaults: N/A, SQLite has no half-written-file state.
    // test_ensure_image_fetches_once, test_prune_images, test_prune_keeps_in_flight_temp_files:
    // image files, ported in Task 4.

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
                JobRunRow {
                    started: 200,
                    finished: Some(230),
                    ok: Some(false),
                    error: Some("boom".into())
                },
                JobRunRow {
                    started: 100,
                    finished: Some(110),
                    ok: Some(true),
                    error: None
                },
            ]
        );
        assert_eq!(
            db.job_history("prune", 10).unwrap(),
            vec![JobRunRow {
                started: 300,
                finished: None,
                ok: None,
                error: None
            }]
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
            vec![JobRunRow {
                started: 500,
                finished: Some(500),
                ok: Some(false),
                error: Some("interrupted".into())
            }]
        );
        assert_eq!(db.close_interrupted().unwrap(), 0);
    }
}
