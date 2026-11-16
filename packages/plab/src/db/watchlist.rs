//! Stash scenes queued to watch (design: 2026-11-16-plab-watchlist-design.md).

use super::*;

impl Db {
    /// Queue `ids` at `now`; an id already queued keeps its first `added_at`.
    pub fn watch_add(&self, ids: &[String], now: i64) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for id in ids {
                tx.execute(
                    "INSERT OR IGNORE INTO watchlist (scene_id, added_at) VALUES (?1, ?2)",
                    params![id, now],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    pub fn watch_remove(&self, ids: &[String]) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for id in ids {
                tx.execute("DELETE FROM watchlist WHERE scene_id = ?1", [id])?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    /// `(scene_id, added_at)`, oldest first.
    pub fn watch_list(&self) -> Result<Vec<(String, i64)>> {
        self.with(|c| {
            let mut s =
                c.prepare("SELECT scene_id, added_at FROM watchlist ORDER BY added_at, scene_id")?;
            let rows = s.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
            all(rows)
        })
    }

    pub fn watch_ids(&self) -> Result<Vec<String>> {
        Ok(self.watch_list()?.into_iter().map(|(id, _)| id).collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn add_then_list_is_oldest_first() {
        let db = Db::open_in_memory().unwrap();
        db.watch_add(&ids(&["2"]), 200).unwrap();
        db.watch_add(&ids(&["1"]), 100).unwrap();
        assert_eq!(
            db.watch_list().unwrap(),
            vec![("1".to_string(), 100), ("2".to_string(), 200)]
        );
    }

    #[test]
    fn add_keeps_first_added_at() {
        let db = Db::open_in_memory().unwrap();
        db.watch_add(&ids(&["1"]), 100).unwrap();
        db.watch_add(&ids(&["1", "2"]), 300).unwrap();
        assert_eq!(
            db.watch_list().unwrap(),
            vec![("1".to_string(), 100), ("2".to_string(), 300)]
        );
    }

    #[test]
    fn remove_drops_only_named() {
        let db = Db::open_in_memory().unwrap();
        db.watch_add(&ids(&["1", "2"]), 100).unwrap();
        db.watch_remove(&ids(&["1", "9"])).unwrap();
        assert_eq!(db.watch_ids().unwrap(), ids(&["2"]));
    }
}
