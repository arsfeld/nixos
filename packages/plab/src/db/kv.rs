//! The key-value store and stream views.

use super::*;

/// A stream of the same release within this many seconds of the last is not a new view.
pub const STREAM_VIEW_GAP: i64 = 6 * 3600;

impl Db {
    /// Record that `topic_id` started streaming, unless it already did in the last
    /// `STREAM_VIEW_GAP` seconds: a reopen or a file switch is not a second view.
    pub fn record_stream_view(&self, topic_id: u64, now: i64) -> Result<bool> {
        self.with(|c| {
            let last: Option<i64> = c.query_row(
                "SELECT MAX(started_at) FROM stream_view WHERE topic_id = ?1",
                params![topic_id],
                |r| r.get(0),
            )?;
            if last.is_some_and(|l| now - l < STREAM_VIEW_GAP) {
                return Ok(false);
            }
            c.execute(
                "INSERT INTO stream_view (topic_id, started_at) VALUES (?1, ?2)",
                params![topic_id, now],
            )?;
            Ok(true)
        })
    }

    pub fn stream_views(&self, since: i64) -> Result<Vec<(u64, i64)>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT topic_id, started_at FROM stream_view WHERE started_at >= ?1
                 ORDER BY started_at DESC, id DESC",
            )?;
            let rows = s.query_map(params![since], |r| Ok((r.get(0)?, r.get(1)?)))?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        })
    }

    // kv

    pub fn kv_get(&self, key: &str) -> Result<Option<(String, i64)>> {
        self.with(|c| {
            Ok(
                c.query_row("SELECT value, rev FROM kv WHERE key = ?1", [key], |r| {
                    Ok((r.get(0)?, r.get(1)?))
                })
                .optional()?,
            )
        })
    }

    pub fn kv_set(&self, key: &str, value: &str) -> Result<i64> {
        self.with(|c| {
            let tx = c.transaction()?;
            tx.execute(
                "INSERT INTO kv (key, value, rev) VALUES (?1, ?2, COALESCE((SELECT max(rev) FROM kv), 0) + 1)
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, rev = excluded.rev",
                params![key, value],
            )?;
            let rev = tx.query_row("SELECT rev FROM kv WHERE key = ?1", [key], |r| r.get(0))?;
            tx.commit()?;
            Ok(rev)
        })
    }

    pub fn kv_delete(&self, key: &str) -> Result<()> {
        self.with(|c| {
            c.execute("DELETE FROM kv WHERE key = ?1", [key])?;
            Ok(())
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kv_rev_increments() {
        let db = Db::open_in_memory().unwrap();
        assert_eq!(db.kv_get("k").unwrap(), None);
        let r1 = db.kv_set("k", "a").unwrap();
        let r2 = db.kv_set("k", "b").unwrap();
        assert!(r2 > r1);
        assert_eq!(db.kv_get("k").unwrap(), Some(("b".into(), r2)));
    }

    #[test]
    fn kv_delete_removes_the_key() {
        let db = Db::open_in_memory().unwrap();
        db.kv_set("k", "a").unwrap();
        db.kv_delete("k").unwrap();
        assert_eq!(db.kv_get("k").unwrap(), None);
        db.kv_delete("k").unwrap(); // absent: no error
    }

    #[test]
    fn stream_views_dedupe_within_gap() {
        let db = Db::open_in_memory().unwrap();
        assert!(db.record_stream_view(7, 1_000).unwrap());
        assert!(
            !db.record_stream_view(7, 1_000 + STREAM_VIEW_GAP - 1)
                .unwrap()
        );
        assert!(db.record_stream_view(7, 1_000 + STREAM_VIEW_GAP).unwrap());
        assert!(db.record_stream_view(8, 1_001).unwrap());
        assert_eq!(
            db.stream_views(0).unwrap(),
            vec![(7, 1_000 + STREAM_VIEW_GAP), (8, 1_001), (7, 1_000)]
        );
        assert_eq!(db.stream_views(1_001).unwrap().len(), 2);
    }
}
