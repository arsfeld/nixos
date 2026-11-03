//! The tracker's video forums, grouped under the names the page shows as categories, and
//! its game forums, which make the separate games list. Both come from the `plab-site`
//! secret (`site::Site::groups` and `games`). Photos, magazines, comics, games and the
//! rules, discussion and archive forums are left out of the video groups on purpose.

/// The games list (/games). Never in `forums()`, so neither list holds the other's releases.
pub fn games() -> &'static [u32] {
    &crate::site::get().games
}

/// Every video forum, groups flattened in order.
pub fn forums() -> Vec<u32> {
    crate::site::get()
        .groups
        .iter()
        .flat_map(|g| g.forums.iter().copied())
        .collect()
}

pub fn category(forum: u32) -> &'static str {
    crate::site::get()
        .groups
        .iter()
        .find(|g| g.forums.contains(&forum))
        .map_or("Other", |g| g.name.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn groups_flatten_in_order() {
        assert_eq!(forums(), [10, 11, 1875, 1878, 1877, 1800, 1823]);
    }

    #[test]
    fn games_are_not_video_forums() {
        let f = forums();
        assert!(games().iter().all(|g| !f.contains(g)));
    }

    #[test]
    fn category_lookup() {
        assert_eq!(category(10), "Group A");
        assert_eq!(category(1875), "Clips");
        assert_eq!(category(1823), "VR");
        assert_eq!(category(999999), "Other");
    }
}
