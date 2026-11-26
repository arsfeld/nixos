//! +1 / −1 votes on Stash scenes (design: 2026-11-26-plab-taste-feedback-design.md).

use super::*;

impl Db {
    /// Set a scene's vote. `voted_at` is set on insert and when the vote changes; the same
    /// vote again keeps it. Anything but 1 or −1 fails the table's CHECK.
    pub fn vote_set(&self, id: &str, vote: i8, now: i64) -> Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO scene_vote (scene_id, vote, voted_at) VALUES (?1, ?2, ?3)
                 ON CONFLICT(scene_id) DO UPDATE SET vote = excluded.vote, voted_at = excluded.voted_at
                 WHERE scene_vote.vote <> excluded.vote",
                params![id, vote, now],
            )?;
            Ok(())
        })
    }

    pub fn vote_clear(&self, id: &str) -> Result<()> {
        self.with(|c| {
            c.execute("DELETE FROM scene_vote WHERE scene_id = ?1", [id])?;
            Ok(())
        })
    }

    /// `(scene_id, vote, voted_at)`, by scene id.
    pub fn votes(&self) -> Result<Vec<(String, i8, i64)>> {
        self.with(|c| {
            let mut s =
                c.prepare("SELECT scene_id, vote, voted_at FROM scene_vote ORDER BY scene_id")?;
            let rows = s.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
            all(rows)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(id: &str, vote: i8, at: i64) -> (String, i8, i64) {
        (id.to_string(), vote, at)
    }

    #[test]
    fn set_lists_and_clear_removes() {
        let db = Db::open_in_memory().unwrap();
        db.vote_set("5", 1, 100).unwrap();
        db.vote_set("3", -1, 200).unwrap();
        assert_eq!(db.votes().unwrap(), vec![v("3", -1, 200), v("5", 1, 100)]);
        db.vote_clear("5").unwrap();
        assert_eq!(db.votes().unwrap(), vec![v("3", -1, 200)]);
    }

    #[test]
    fn same_vote_again_keeps_voted_at() {
        let db = Db::open_in_memory().unwrap();
        db.vote_set("5", 1, 100).unwrap();
        db.vote_set("5", 1, 900).unwrap();
        assert_eq!(db.votes().unwrap(), vec![v("5", 1, 100)]);
    }

    #[test]
    fn switching_refreshes_voted_at() {
        let db = Db::open_in_memory().unwrap();
        db.vote_set("5", 1, 100).unwrap();
        db.vote_set("5", -1, 900).unwrap();
        assert_eq!(db.votes().unwrap(), vec![v("5", -1, 900)]);
    }

    #[test]
    fn a_vote_outside_plus_minus_one_is_an_error() {
        let db = Db::open_in_memory().unwrap();
        assert!(db.vote_set("5", 2, 100).is_err());
    }
}
