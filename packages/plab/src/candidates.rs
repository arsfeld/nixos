//! The assistant's shortlist: unwatched scenes and listed releases that share studios,
//! performers or tags with the taste profile. Pure; `assistant::context` builds the inputs.

use std::collections::HashMap;

use serde::Serialize;

use crate::taste::Profile;

pub const PER_POOL: usize = 25;
pub const MAX: usize = 40;

#[derive(Debug, Clone, PartialEq)]
pub struct SceneIn {
    pub id: String,
    pub title: String,
    pub studio: Option<String>,
    pub performers: Vec<String>,
    pub tags: Vec<String>,
    pub plays: u32,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ReleaseIn {
    pub id: u64,
    pub title: String,
    /// The studio `labels` reads from the title, when it finds one.
    pub studio: Option<String>,
    pub downloaded: bool,
    pub album: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Candidate {
    #[serde(rename = "ref")]
    pub ref_: String,
    pub kind: &'static str,
    pub title: String,
    /// The profile terms it matched, strongest first.
    pub matched: Vec<String>,
    #[serde(skip)]
    pub score: f64,
}

/// Every profile term by lowercase name: its display name and summed weight, in profile
/// order (studios, performers, tags).
fn terms(p: &Profile) -> Vec<(String, String, f64)> {
    let mut by: HashMap<String, usize> = HashMap::new();
    let mut out: Vec<(String, String, f64)> = vec![];
    for w in p.studios.iter().chain(&p.performers).chain(&p.tags) {
        let key = w.name.to_lowercase();
        match by.get(&key) {
            Some(&i) => out[i].2 += w.weight,
            None => {
                by.insert(key.clone(), out.len());
                out.push((key, w.name.clone(), w.weight));
            }
        }
    }
    out
}

/// Whether `needle` (lowercase) occurs in `hay` (lowercase) with no letter or digit on
/// either side.
fn has_word(hay: &str, needle: &str) -> bool {
    if needle.is_empty() {
        return false;
    }
    hay.match_indices(needle).any(|(i, _)| {
        let before = hay[..i].chars().next_back();
        let after = hay[i + needle.len()..].chars().next();
        !before.is_some_and(char::is_alphanumeric) && !after.is_some_and(char::is_alphanumeric)
    })
}

fn score(terms: &[(String, String, f64)], hit: impl Fn(&str) -> bool) -> (f64, Vec<String>) {
    let mut s = 0.0;
    let mut matched = vec![];
    for (key, name, w) in terms {
        if hit(key) {
            s += w;
            matched.push(name.clone());
        }
    }
    (s, matched)
}

fn best(mut v: Vec<Candidate>, n: usize) -> Vec<Candidate> {
    v.sort_by(|a, b| b.score.total_cmp(&a.score)); // stable: ties keep input order
    v.truncate(n);
    v
}

pub fn candidates(profile: &Profile, scenes: &[SceneIn], releases: &[ReleaseIn]) -> Vec<Candidate> {
    let terms = terms(profile);
    let releases = releases.iter().filter(|r| !r.downloaded && !r.album);
    if terms.is_empty() {
        return releases
            .take(PER_POOL)
            .map(|r| Candidate {
                ref_: format!("t:{}", r.id),
                kind: "stream_or_download",
                title: r.title.clone(),
                matched: vec![],
                score: 0.0,
            })
            .collect();
    }
    let scenes: Vec<Candidate> = scenes
        .iter()
        .filter(|s| s.plays == 0)
        .filter_map(|s| {
            let names: Vec<String> = s
                .studio
                .iter()
                .chain(&s.performers)
                .chain(&s.tags)
                .map(|n| n.to_lowercase())
                .collect();
            let (score, matched) = score(&terms, |k| names.iter().any(|n| n == k));
            (score > 0.0).then(|| Candidate {
                ref_: format!("s:{}", s.id),
                kind: "watch",
                title: s.title.clone(),
                matched,
                score,
            })
        })
        .collect();
    let releases: Vec<Candidate> = releases
        .filter_map(|r| {
            let title = r.title.to_lowercase();
            let studio = r.studio.as_deref().map(str::to_lowercase);
            let (score, matched) =
                score(&terms, |k| has_word(&title, k) || studio.as_deref() == Some(k));
            (score > 0.0).then(|| Candidate {
                ref_: format!("t:{}", r.id),
                kind: "stream_or_download",
                title: r.title.clone(),
                matched,
                score,
            })
        })
        .collect();
    let mut all = best(scenes, PER_POOL);
    all.extend(best(releases, PER_POOL));
    best(all, MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::taste::Weighted;

    fn w(name: &str, weight: f64) -> Weighted {
        Weighted { name: name.into(), id: None, weight }
    }

    fn profile() -> Profile {
        Profile {
            studios: vec![w("Studio A", 2.0)],
            performers: vec![w("Performer B", 1.0)],
            tags: vec![w("Outdoor", 0.5)],
            recent: vec![],
        }
    }

    fn scene(id: &str, studio: Option<&str>, performers: &[&str], plays: u32) -> SceneIn {
        SceneIn {
            id: id.into(),
            title: format!("Scene {id}"),
            studio: studio.map(Into::into),
            performers: performers.iter().map(|p| p.to_string()).collect(),
            tags: vec!["outdoor".into()],
            plays,
        }
    }

    fn release(id: u64, title: &str) -> ReleaseIn {
        ReleaseIn { id, title: title.into(), studio: None, downloaded: false, album: false }
    }

    #[test]
    fn scenes_score_by_studio_performers_and_tags() {
        let c = candidates(&profile(), &[scene("1", Some("studio a"), &["Performer B"], 0)], &[]);
        assert_eq!(c.len(), 1);
        assert_eq!(c[0].ref_, "s:1");
        assert_eq!(c[0].kind, "watch");
        assert!((c[0].score - 3.5).abs() < 1e-9);
        assert_eq!(c[0].matched, vec!["Studio A", "Performer B", "Outdoor"]);
    }

    #[test]
    fn releases_match_whole_words_in_the_title() {
        let rs = [
            release(1, "Studio A - Night with Performer B [1080p]"),
            release(2, "Studio Ab something"),
            release(3, "Unrelated"),
        ];
        let c = candidates(&profile(), &[], &rs);
        assert_eq!(c.iter().map(|c| c.ref_.as_str()).collect::<Vec<_>>(), vec!["t:1"]);
        assert_eq!(c[0].kind, "stream_or_download");
    }

    #[test]
    fn exclusions() {
        let mut downloaded = release(1, "Studio A one");
        downloaded.downloaded = true;
        let mut album = release(2, "Studio A two");
        album.album = true;
        let c = candidates(
            &profile(),
            &[scene("9", Some("Studio A"), &[], 3)],
            &[downloaded, album],
        );
        assert!(c.is_empty());
    }

    #[test]
    fn caps_per_pool_and_overall() {
        let scenes: Vec<SceneIn> = (0..30).map(|i| scene(&i.to_string(), Some("Studio A"), &[], 0)).collect();
        let releases: Vec<ReleaseIn> = (0..30).map(|i| release(i, "Performer B release")).collect();
        let c = candidates(&profile(), &scenes, &releases);
        assert_eq!(c.len(), MAX);
        assert!(c.iter().filter(|c| c.kind == "watch").count() <= PER_POOL);
        assert!(c.iter().filter(|c| c.kind != "watch").count() >= MAX - PER_POOL);
    }

    #[test]
    fn empty_profile_falls_back_to_listing_order() {
        let releases: Vec<ReleaseIn> = (0..30).map(|i| release(i, "anything")).collect();
        let c = candidates(&Profile::default(), &[], &releases);
        assert_eq!(c.len(), PER_POOL);
        assert_eq!(c[0].ref_, "t:0");
        assert!(c[0].matched.is_empty());
    }
}
