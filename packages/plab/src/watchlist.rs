//! The watchlist's auto-removal rule (design: 2026-11-16-plab-watchlist-design.md).

use crate::stash::library::LibScene;

/// The rows to drop: their scene was played after it was queued, or Stash no longer has
/// it. An unparseable play time counts as no play. Row order is kept.
pub fn expired(rows: &[(String, i64)], scenes: &[LibScene]) -> Vec<String> {
    rows.iter()
        .filter(|(id, added_at)| match scenes.iter().find(|s| &s.id == id) {
            None => true,
            Some(s) => s
                .last_played_at
                .as_deref()
                .and_then(|t| chrono::DateTime::parse_from_rfc3339(t).ok())
                .is_some_and(|t| t.timestamp() > *added_at),
        })
        .map(|(id, _)| id.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// 2026-11-10T12:00:00Z.
    const T: i64 = 1794312000;

    fn scene(id: &str, played: Option<&str>) -> LibScene {
        serde_json::from_value(json!({"id": id, "last_played_at": played})).unwrap()
    }

    fn row() -> Vec<(String, i64)> {
        vec![("1".to_string(), T)]
    }

    #[test]
    fn played_after_queued_expires() {
        assert_eq!(
            expired(&row(), &[scene("1", Some("2026-11-11T00:00:00Z"))]),
            ["1"]
        );
    }

    #[test]
    fn played_before_queued_stays() {
        assert!(expired(&row(), &[scene("1", Some("2026-10-01T00:00:00Z"))]).is_empty());
    }

    #[test]
    fn never_played_stays() {
        assert!(expired(&row(), &[scene("1", None)]).is_empty());
    }

    #[test]
    fn missing_from_stash_expires() {
        assert_eq!(expired(&row(), &[]), ["1"]);
    }

    #[test]
    fn unparseable_play_time_stays() {
        assert!(expired(&row(), &[scene("1", Some("yesterday"))]).is_empty());
    }

    #[test]
    fn offset_times_compare_as_instants() {
        assert_eq!(
            expired(&row(), &[scene("1", Some("2026-11-10T08:00:01-04:00"))]),
            ["1"]
        );
    }
}
