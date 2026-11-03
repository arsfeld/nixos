//! Identify bookkeeping: which scenes are done and which keep failing.

use super::*;

pub const IDENTIFY_FAILURE_LIMIT: i64 = 3;

impl Db {
    // identify

    pub fn identify_done(&self, scene_id: &str) -> Result<bool> {
        self.with(|c| {
            let done: Option<i64> = c
                .query_row(
                    "SELECT done FROM identify_attempt WHERE scene_id = ?1",
                    [scene_id],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(done == Some(1))
        })
    }

    pub fn identify_mark_done(&self, scene_id: &str) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO identify_attempt (scene_id, done) VALUES (?1, 1)
                 ON CONFLICT(scene_id) DO UPDATE SET done = 1",
                [scene_id],
            )?;
            Ok(())
        })
    }

    /// Count a failure; the third gives up (marks the scene done) and returns true.
    pub fn identify_fail(&self, scene_id: &str) -> Result<bool> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute(
                "INSERT INTO identify_attempt (scene_id, failures) VALUES (?1, 1)
                 ON CONFLICT(scene_id) DO UPDATE SET failures = failures + 1",
                [scene_id],
            )?;
            let failures: i64 = tx.query_row(
                "SELECT failures FROM identify_attempt WHERE scene_id = ?1",
                [scene_id],
                |r| r.get(0),
            )?;
            let gave_up = failures >= IDENTIFY_FAILURE_LIMIT;
            if gave_up {
                tx.execute(
                    "UPDATE identify_attempt SET done = 1 WHERE scene_id = ?1",
                    [scene_id],
                )?;
            }
            tx.commit()?;
            Ok(gave_up)
        })
    }

    /// The failure count `identify_fail` has reached for a scene (0 when never failed).
    #[cfg(test)]
    pub fn identify_failures(&self, scene_id: &str) -> Result<i64> {
        self.with(|c| {
            let n: Option<i64> = c
                .query_row(
                    "SELECT failures FROM identify_attempt WHERE scene_id = ?1",
                    [scene_id],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(n.unwrap_or(0))
        })
    }

    pub fn identify_clear_failures(&self, scene_id: &str) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE identify_attempt SET failures = 0 WHERE scene_id = ?1",
                [scene_id],
            )?;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identify_gives_up_on_third_failure_and_clears() {
        let db = Db::open_in_memory().unwrap();
        assert!(!db.identify_fail("7").unwrap());
        db.identify_clear_failures("7").unwrap();
        assert!(!db.identify_fail("7").unwrap());
        assert!(!db.identify_fail("7").unwrap());
        assert!(db.identify_fail("7").unwrap());
        assert!(db.identify_done("7").unwrap());
    }

    #[test]
    fn identify_mark_done() {
        let db = Db::open_in_memory().unwrap();
        assert!(!db.identify_done("1").unwrap());
        db.identify_mark_done("1").unwrap();
        assert!(db.identify_done("1").unwrap());
    }
}
