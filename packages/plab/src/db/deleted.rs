//! Stash scenes deleted from plab: hidden everywhere and never offered again. Unlike a −1
//! vote this says nothing about taste, so nothing in `taste` or the profile reads it.

use std::collections::HashSet;

use super::*;

impl Db {
    /// Record `ids` as deleted; one already recorded keeps its first time.
    pub fn deleted_add(&self, ids: &[String], now: i64) -> Result<()> {
        self.with(|c| {
            let tx = c.transaction()?;
            for id in ids {
                tx.execute(
                    "INSERT OR IGNORE INTO scene_deleted (scene_id, deleted_at) VALUES (?1, ?2)",
                    params![id, now],
                )?;
            }
            tx.commit()?;
            Ok(())
        })
    }

    pub fn deleted_ids(&self) -> Result<HashSet<String>> {
        self.with(|c| {
            let mut s = c.prepare("SELECT scene_id FROM scene_deleted")?;
            let rows = s.query_map([], |r| r.get(0))?;
            Ok(all(rows)?.into_iter().collect())
        })
    }

    /// Record a deleted scene's Stash file paths, replacing any earlier ones.
    pub fn deleted_set_paths(&self, id: &str, paths: &[String]) -> Result<()> {
        self.with(|c| {
            c.execute(
                "UPDATE scene_deleted SET paths = ?2 WHERE scene_id = ?1",
                params![id, paths.join("\n")],
            )?;
            Ok(())
        })
    }

    /// Every recorded file path of a deleted scene.
    pub fn deleted_paths(&self) -> Result<Vec<String>> {
        self.with(|c| {
            let mut s = c.prepare("SELECT paths FROM scene_deleted WHERE paths IS NOT NULL")?;
            let rows = s.query_map([], |r| r.get::<_, String>(0))?;
            Ok(all(rows)?
                .iter()
                .flat_map(|p| p.lines().map(str::to_owned))
                .collect())
        })
    }

    /// The torrent hashes of the downloads any of whose files became one of `scene_ids`.
    pub fn hashes_of_scenes(&self, scene_ids: &[String]) -> Result<Vec<String>> {
        self.with(|c| {
            let mut s = c.prepare(
                "SELECT DISTINCT d.torrent_hash FROM download d
                 JOIN download_file f ON f.download_id = d.id
                 WHERE f.scene_id = ?1 AND d.torrent_hash IS NOT NULL",
            )?;
            let mut out: Vec<String> = vec![];
            for id in scene_ids {
                for h in all(s.query_map([id], |r| r.get::<_, String>(0))?)? {
                    if !out.contains(&h) {
                        out.push(h);
                    }
                }
            }
            Ok(out)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::super::tests::*;
    use super::*;

    #[test]
    fn add_lists_and_keeps_the_first_time() {
        let db = Db::open_in_memory().unwrap();
        db.deleted_add(&["5".into(), "3".into()], 100).unwrap();
        db.deleted_add(&["5".into()], 900).unwrap();
        assert_eq!(
            db.deleted_ids().unwrap(),
            HashSet::from(["3".to_string(), "5".to_string()])
        );
        let at: i64 = db
            .with(|c| {
                Ok(c.query_row(
                    "SELECT deleted_at FROM scene_deleted WHERE scene_id = '5'",
                    [],
                    |r| r.get(0),
                )?)
            })
            .unwrap();
        assert_eq!(at, 100);
    }

    #[test]
    fn deleting_is_not_a_vote() {
        let db = Db::open_in_memory().unwrap();
        db.deleted_add(&["5".into()], 100).unwrap();
        assert!(db.votes().unwrap().is_empty());
    }

    #[test]
    fn deleted_paths_lists_every_recorded_path() {
        let db = Db::open_in_memory().unwrap();
        db.deleted_add(&["1".into(), "2".into(), "3".into()], 10)
            .unwrap();
        db.deleted_set_paths("1", &["/d/A/x.mp4".into(), "/d/A/y.mp4".into()])
            .unwrap();
        db.deleted_set_paths("2", &["/d/B/z.mp4".into()]).unwrap();
        db.deleted_set_paths("9", &["/d/C/w.mp4".into()]).unwrap();
        let mut p = db.deleted_paths().unwrap();
        p.sort();
        assert_eq!(p, ["/d/A/x.mp4", "/d/A/y.mp4", "/d/B/z.mp4"]);
    }

    #[test]
    fn hashes_of_scenes_names_each_download_once() {
        let db = Db::open_in_memory().unwrap();
        let a = added(&db, "plab", Some(1), "A", Some("ha"));
        let b = added(&db, "grab", None, "B", Some("hb"));
        added(&db, "plab", Some(3), "C", None);
        db.save_files(a, &["A/x.mp4".into(), "A/y.mp4".into()])
            .unwrap();
        db.save_files(b, &["B/z.mp4".into()]).unwrap();
        db.link_scene("A/x.mp4", Some("1")).unwrap();
        db.link_scene("A/y.mp4", Some("2")).unwrap();
        db.link_scene("B/z.mp4", Some("3")).unwrap();
        let ids = ["1".to_string(), "2".to_string(), "9".to_string()];
        assert_eq!(db.hashes_of_scenes(&ids).unwrap(), vec!["ha".to_string()]);
    }
}
