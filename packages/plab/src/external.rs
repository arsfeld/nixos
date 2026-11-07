//! Releases from indexers other than the tracker: comparing titles, collapsing one
//! release's variants (resolutions, re-uploads), and recognizing a release the tracker
//! already has. Pure functions; `curated.rs` runs them.

use std::collections::{HashMap, HashSet};
use std::sync::LazyLock;

use chrono::NaiveDate;
use regex::Regex;

/// One search result from another indexer, as the curated job keeps it.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate {
    pub indexer: String,
    pub guid: String,
    pub link: String,
    pub info_url: Option<String>,
    pub title: String,
    pub size: u64,
    pub seeders: u32,
    pub leechers: u32,
    /// Unix seconds.
    pub published: i64,
}

const CONTAINERS: [&str; 8] = ["mp4", "mkv", "avi", "wmv", "mov", "m4v", "ts", "webm"];
/// Words that never tell two releases apart.
pub(crate) const STOP: [&str; 7] = ["and", "the", "with", "part", "episode", "scene", "feat"];

fn re(p: &str) -> Regex {
    Regex::new(p).unwrap()
}

pub(crate) static GROUPS: LazyLock<Regex> = LazyLock::new(|| re(r"\[[^\]]*\]|\([^)]*\)"));
static RESOLUTION: LazyLock<Regex> = LazyLock::new(|| re(r"^\d{3,4}p$"));
static EPISODE: LazyLock<Regex> = LazyLock::new(|| re(r"^e\d+$"));
pub(crate) static YMD: LazyLock<Regex> =
    LazyLock::new(|| re(r"\b(20\d{2})[.\- ](\d{2})[.\- ](\d{2})\b"));
pub(crate) static DMY: LazyLock<Regex> = LazyLock::new(|| re(r"\b(\d{2})\.(\d{2})\.(20\d{2})\b"));
pub(crate) static SHORT: LazyLock<Regex> =
    LazyLock::new(|| re(r"\b(\d{2})[. ](\d{2})[. ](\d{2})\b"));

/// A trailing release-group tag: two or more characters, upper-case letters and digits
/// only, at least one letter.
fn is_group_tag(w: &str) -> bool {
    w.len() >= 2
        && w.chars().any(|c| c.is_ascii_uppercase())
        && w.chars()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

/// The title's comparable words, lower-cased: bracketed and parenthesized groups,
/// trailing release-group tags, resolutions, container names and `noise` removed.
pub fn words(title: &str, noise: &[String]) -> Vec<String> {
    let bare = GROUPS.replace_all(title, " ");
    let mut raw: Vec<String> = bare
        .split(|c: char| c.is_whitespace() || matches!(c, '.' | '_' | '-' | ','))
        .map(|w| w.trim_matches(|c: char| !c.is_alphanumeric()).to_string())
        .filter(|w| !w.is_empty())
        .collect();
    while raw.last().is_some_and(|w| is_group_tag(w)) {
        raw.pop();
    }
    raw.into_iter()
        .map(|w| w.to_lowercase())
        .filter(|w| {
            !RESOLUTION.is_match(w)
                && !CONTAINERS.contains(&w.as_str())
                && !noise.iter().any(|n| n == w)
        })
        .collect()
}

/// Titles with the same key are variants of one release.
pub fn title_key(title: &str, noise: &[String]) -> String {
    words(title, noise).join(" ")
}

fn ymd(y: &str, m: &str, d: &str) -> Option<NaiveDate> {
    NaiveDate::from_ymd_opt(y.parse().ok()?, m.parse().ok()?, d.parse().ok()?)
}

/// The release date a title carries: `YYYY.MM.DD` (or `-`/space), `DD.MM.YYYY`, or
/// `YY MM DD` (read as 20YY).
pub fn release_date(title: &str) -> Option<NaiveDate> {
    if let Some(c) = YMD.captures(title)
        && let Some(d) = ymd(&c[1], &c[2], &c[3])
    {
        return Some(d);
    }
    if let Some(c) = DMY.captures(title)
        && let Some(d) = ymd(&c[3], &c[2], &c[1])
    {
        return Some(d);
    }
    let c = SHORT.captures(title)?;
    ymd(&format!("20{}", &c[1]), &c[2], &c[3])
}

/// Words likely to be names: comparable words of three or more letters, minus the term's
/// own words, numbers and `STOP` words.
pub fn person_tokens(title: &str, term: &str, noise: &[String]) -> HashSet<String> {
    let term_words: HashSet<String> = words(term, &[]).into_iter().collect();
    words(title, noise)
        .into_iter()
        .filter(|w| w.chars().count() >= 3 && w.chars().all(char::is_alphabetic))
        .filter(|w| !term_words.contains(w) && !STOP.contains(&w.as_str()))
        .collect()
}

/// The query for the scene database: the comparable words without an episode token,
/// and the release date, if any, appended as `YYYY-MM-DD`.
pub fn scene_query(title: &str, noise: &[String]) -> String {
    let date = release_date(title);
    let mut stripped = title.to_string();
    for pattern in [&*YMD, &*DMY, &*SHORT] {
        stripped = pattern.replace(&stripped, " ").into_owned();
    }
    let mut out: Vec<String> = words(&stripped, noise)
        .into_iter()
        .filter(|w| !EPISODE.is_match(w))
        .collect();
    if let Some(d) = date {
        out.push(d.format("%Y-%m-%d").to_string());
    }
    out.join(" ")
}

/// One candidate per release: of the variants sharing a `title_key`, the best seeded,
/// at the position of the first seen.
pub fn collapse(found: Vec<Candidate>, noise: &[String]) -> Vec<Candidate> {
    let mut out: Vec<Candidate> = vec![];
    let mut at: HashMap<String, usize> = HashMap::new();
    for c in found {
        let key = title_key(&c.title, noise);
        match at.get(&key) {
            Some(&i) if out[i].seeders >= c.seeders => {}
            Some(&i) => out[i] = c,
            None => {
                at.insert(key, out.len());
                out.push(c);
            }
        }
    }
    out
}

/// Whether the tracker already has this release: a tracker title of the same filter with
/// the same date and at least one name in common. No readable date: never a duplicate.
pub fn is_duplicate(title: &str, tracker_titles: &[&str], term: &str, noise: &[String]) -> bool {
    let Some(date) = release_date(title) else {
        return false;
    };
    let names = person_tokens(title, term, noise);
    tracker_titles.iter().any(|t| {
        release_date(t) == Some(date) && !person_tokens(t, term, noise).is_disjoint(&names)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noise() -> Vec<String> {
        vec!["noisea".into()]
    }

    fn cand(title: &str, seeders: u32) -> Candidate {
        Candidate {
            indexer: "Indexer A".into(),
            guid: title.into(),
            link: format!("http://p/{seeders}"),
            info_url: None,
            title: title.into(),
            size: 1,
            seeders,
            leechers: 0,
            published: 0,
        }
    }

    #[test]
    fn variants_share_a_key() {
        let a = title_key(
            "Alpha E0012 Ann And Ben Lazy Sunday 1080p MP4 P2P [GR]",
            &noise(),
        );
        let b = title_key("Alpha.E0012.Ann.And.Ben.Lazy.Sunday.480p.MP4.P2P", &noise());
        assert_eq!(a, "alpha e0012 ann and ben lazy sunday");
        assert_eq!(a, b);
        assert_eq!(
            title_key("Alpha Lazy Sunday NoiseA 720p", &noise()),
            "alpha lazy sunday"
        );
        // Part 2 is not a tag: digits only.
        assert_eq!(
            title_key("Alpha Lazy Sunday Part 2", &[]),
            "alpha lazy sunday part 2"
        );
    }

    #[test]
    fn dates_in_three_styles() {
        let d = NaiveDate::from_ymd_opt(2026, 10, 24);
        assert_eq!(release_date("Alpha 26 10 24 Ann And Ben"), d);
        assert_eq!(release_date("[Alpha.com] Ann Doe - Lazy (24.10.2026)"), d);
        assert_eq!(release_date("[Alpha.com] Ann - Lazy [2026-10-24, tags]"), d);
        assert_eq!(release_date("Alpha.2026.10.24.Ann"), d);
        assert_eq!(release_date("Alpha Lazy Sunday 1080p"), None);
        assert_eq!(release_date("Alpha 26 13 40"), None); // not a date
    }

    #[test]
    fn collapse_keeps_the_best_seeded_variant_in_first_position() {
        let out = collapse(
            vec![
                cand("Alpha Ann Lazy 480p MP4", 5),
                cand("Beta Cat Rain 1080p", 3),
                cand("Alpha.Ann.Lazy.1080p.MP4", 9),
            ],
            &[],
        );
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].seeders, 9);
        assert_eq!(out[1].title, "Beta Cat Rain 1080p");
    }

    #[test]
    fn a_tracker_release_of_the_same_date_and_names_is_a_duplicate() {
        let tracker = ["[Alpha.com] Ann Doe, Ben Roe - Lazy Sunday (24.10.2026)"];
        let ext = "Alpha 26 10 24 Ann And Ben Lazy Sunday 1080p MP4 [GR]";
        assert!(is_duplicate(ext, &tracker, "alpha", &[]));
        // Other date: kept.
        assert!(!is_duplicate(
            "Alpha 26 10 25 Ann And Ben Lazy Sunday",
            &tracker,
            "alpha",
            &[]
        ));
        // Same date, nobody in common: kept.
        assert!(!is_duplicate(
            "Alpha 26 10 24 Cat Dee Rainy Day",
            &tracker,
            "alpha",
            &[]
        ));
        // No readable date: never a duplicate.
        assert!(!is_duplicate(
            "Alpha Ann And Ben Lazy Sunday",
            &tracker,
            "alpha",
            &[]
        ));
    }

    #[test]
    fn person_tokens_drop_the_term_numbers_and_stop_words() {
        let t = person_tokens("Alpha E0012 Ann And Ben Lazy 26 10 24", "alpha", &[]);
        let want: HashSet<String> = ["ann", "ben", "lazy"].map(String::from).into();
        assert_eq!(t, want);
    }

    #[test]
    fn scene_query_drops_the_episode_and_rewrites_the_date() {
        assert_eq!(
            scene_query(
                "Alpha E0012 26 10 24 Ann And Ben Lazy Sunday 1080p MP4 [GR]",
                &[]
            ),
            "alpha ann and ben lazy sunday 2026-10-24"
        );
        assert_eq!(
            scene_query("Alpha Lazy Sunday 720p", &[]),
            "alpha lazy sunday"
        );
    }
}
