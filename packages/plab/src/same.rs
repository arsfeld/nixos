//! Whether two releases are the same scene, whichever source named them
//! (design: docs/superpowers/specs/2026-11-06-plab-dedup-design.md).
//!
//! A scene is its release date plus the names its title carries. Two releases are the
//! same scene when the dates are equal and enough names are shared. A title with no
//! readable date has no signature, so it is never merged and never owned: a miss shows a
//! duplicate, it never hides a different scene.

// Callers arrive in the following commits; removed once they do.
#![allow(dead_code)]

use std::collections::{HashMap, HashSet};

use chrono::NaiveDate;

use crate::external::{DMY, GROUPS, SHORT, STOP, YMD, release_date, words};

/// Names two releases must share to be one card, or for a download to own a card. Lists
/// compare same-day titles across every studio, where one shared word ("you", a first
/// name) is too weak.
pub const LIST_MIN: usize = 2;
/// Curated and assistant search compare within one filter term, so one name is enough.
pub const SEARCH_MIN: usize = 1;

#[derive(Debug, Clone, PartialEq)]
pub struct SceneSig {
    pub date: NaiveDate,
    pub names: HashSet<String>,
}

/// The title's scene signature; None when it carries no readable release date.
///
/// Names are its comparable words of three or more letters, minus `STOP`, `noise` and
/// `stop`. A 1337x-style title leads with its studio and then an unbracketed date
/// ("Studio B 26 10 30 Cara Kim ..."), so the words before that date are dropped: shared
/// by every scene of the studio, they would link them all. The tracker keeps its date in a
/// bracket, which `words` strips anyway, so nothing is dropped there.
pub fn sig(title: &str, noise: &[String], stop: &[&str]) -> Option<SceneSig> {
    let date = release_date(title)?;
    let bare = GROUPS.replace_all(title, " ");
    let start = [&*YMD, &*DMY, &*SHORT]
        .iter()
        .filter_map(|re| re.find(&bare))
        .min_by_key(|m| m.start())
        .map_or(0, |m| m.end());
    let names = words(&bare[start..], noise)
        .into_iter()
        .filter(|w| w.chars().count() >= 3 && w.chars().all(char::is_alphabetic))
        .filter(|w| !STOP.contains(&w.as_str()) && !stop.contains(&w.as_str()))
        .collect();
    Some(SceneSig { date, names })
}

/// Same date, and at least `min` names in common.
pub fn same(a: &SceneSig, b: &SceneSig, min: usize) -> bool {
    a.date == b.date && a.names.intersection(&b.names).count() >= min
}

/// Indices grouped by `same(.., LIST_MIN)`, transitively: A like B and B like C make one
/// group even when A and C share nothing. Every index appears once; members are in input
/// order and groups are ordered by their first member.
pub fn groups(sigs: &[Option<SceneSig>]) -> Vec<Vec<usize>> {
    let mut parent: Vec<usize> = (0..sigs.len()).collect();
    fn root(parent: &mut [usize], mut i: usize) -> usize {
        while parent[i] != i {
            parent[i] = parent[parent[i]];
            i = parent[i];
        }
        i
    }
    let mut by_date: HashMap<NaiveDate, Vec<usize>> = HashMap::new();
    for (i, s) in sigs.iter().enumerate() {
        if let Some(s) = s {
            by_date.entry(s.date).or_default().push(i);
        }
    }
    for bucket in by_date.values() {
        for (k, &i) in bucket.iter().enumerate() {
            for &j in &bucket[k + 1..] {
                if same(
                    sigs[i].as_ref().unwrap(),
                    sigs[j].as_ref().unwrap(),
                    LIST_MIN,
                ) {
                    let (ri, rj) = (root(&mut parent, i), root(&mut parent, j));
                    // The smaller index leads, so a group's root is its first member.
                    parent[ri.max(rj)] = ri.min(rj);
                }
            }
        }
    }
    let mut out: Vec<Vec<usize>> = vec![];
    let mut at: HashMap<usize, usize> = HashMap::new();
    for i in 0..sigs.len() {
        let r = root(&mut parent, i);
        match at.get(&r) {
            Some(&g) => out[g].push(i),
            None => {
                at.insert(r, out.len());
                out.push(vec![i]);
            }
        }
    }
    out
}

/// One video download, as the owned check needs it.
#[derive(Debug, Clone, PartialEq)]
pub struct DownloadTitle {
    pub id: i64,
    pub topic_id: Option<u64>,
    pub title: String,
}

/// Which downloads already cover a release: by its own topic id, else by scene.
pub struct Owned {
    by_topic: HashMap<u64, i64>,
    sigs: Vec<(i64, SceneSig)>,
}

impl Owned {
    pub fn new(downloads: &[DownloadTitle], noise: &[String]) -> Owned {
        let mut by_topic = HashMap::new();
        let mut sigs = vec![];
        for d in downloads {
            if let Some(t) = d.topic_id {
                by_topic.entry(t).or_insert(d.id);
            }
            if let Some(s) = sig(&d.title, noise, &[]) {
                sigs.push((d.id, s));
            }
        }
        Owned { by_topic, sigs }
    }

    /// The id of a download of this release's scene: its own topic's first, then the
    /// first download of the same scene.
    pub fn of(&self, topic_id: u64, sig: Option<&SceneSig>) -> Option<i64> {
        if let Some(&d) = self.by_topic.get(&topic_id) {
            return Some(d);
        }
        let sig = sig?;
        self.sigs
            .iter()
            .find(|(_, s)| same(s, sig, LIST_MIN))
            .map(|(d, _)| *d)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(title: &str) -> SceneSig {
        sig(title, &[], &[]).unwrap()
    }

    #[test]
    fn dated_and_reordered_namings_are_the_same_scene() {
        let x = s("Studio B 26 10 30 Cara Kim And Dana Lee Close To You TAG 1080p MP4 GRP [RG]");
        let lab = s(
            "[StudioB.com] Dana Lee, Cara Kim - Close To You [2026-10-30, Couples, 1080p, SiteRip]",
        );
        assert!(same(&x, &lab, LIST_MIN));
    }

    #[test]
    fn one_shared_word_is_enough_for_search_but_not_lists() {
        let a = s("[Bravo] Ann Lee - Close To You [2026-10-30, 1080p]");
        let b = s("[Delta] Bea Ray - Only You [2026-10-30, 1080p]");
        assert!(same(&a, &b, SEARCH_MIN));
        assert!(!same(&a, &b, LIST_MIN));
    }

    #[test]
    fn a_different_date_is_another_scene() {
        let a = s("[StudioB.com] Dana Lee, Cara Kim - Close To You [2026-10-30, 1080p]");
        let b = s("[StudioB.com] Dana Lee, Cara Kim - Close To You [2026-10-31, 1080p]");
        assert!(!same(&a, &b, SEARCH_MIN));
    }

    #[test]
    fn no_readable_date_has_no_signature() {
        assert!(sig("[StudioB.com] Dana Lee - Close To You [1080p]", &[], &[]).is_none());
    }

    #[test]
    fn studio_prefix_words_do_not_link() {
        let a = s("Studio Bravo 26 10 30 Ann Lee Morning Light 1080p MP4");
        let b = s("Studio Bravo 26 10 30 Bea Ray Evening Walk 1080p MP4");
        assert!(!same(&a, &b, SEARCH_MIN));
    }

    #[test]
    fn stop_and_noise_words_do_not_link() {
        let n = vec!["noisea".to_string()];
        let a = sig("Ann Lee NoiseA Bravo [2026-10-30, 1080p]", &n, &["bravo"]).unwrap();
        let b = sig("Bea Ray NoiseA Bravo [2026-10-30, 1080p]", &n, &["bravo"]).unwrap();
        assert!(!same(&a, &b, SEARCH_MIN));
    }

    #[test]
    fn common_title_words_on_different_dates_do_not_link() {
        let a = s("[Bravo] Ann Lee - Close To You [2026-10-30, 1080p]");
        let b = s("[Delta] Bea Ray - Close To You [2026-09-01, 1080p]");
        assert!(!same(&a, &b, SEARCH_MIN));
    }

    #[test]
    fn grouping_is_transitive() {
        let a = sig("Cara Kim Sunrise [2026-10-30]", &[], &[]);
        let b = sig("Cara Kim, Dana Lee Together [2026-10-30]", &[], &[]);
        let c = sig("Dana Lee Sunset [2026-10-30]", &[], &[]);
        let d = sig("Cara Kim Dana Lee Undated", &[], &[]);
        assert_eq!(groups(&[a, b, c, d]), vec![vec![0, 1, 2], vec![3]]);
    }

    #[test]
    fn owned_by_topic_id_then_by_signature() {
        let o = Owned::new(
            &[
                DownloadTitle {
                    id: 7,
                    topic_id: Some(42),
                    title: "undated".into(),
                },
                DownloadTitle {
                    id: 9,
                    topic_id: None,
                    title: "Studio B 26 10 30 Cara Kim And Dana Lee Close To You 1080p".into(),
                },
            ],
            &[],
        );
        assert_eq!(o.of(42, None), Some(7));
        let lab = sig(
            "[StudioB.com] Dana Lee, Cara Kim - Close To You [2026-10-30, 1080p]",
            &[],
            &[],
        );
        assert_eq!(o.of(1, lab.as_ref()), Some(9));
        assert_eq!(o.of(1, None), None);
    }
}
