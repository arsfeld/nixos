//! The curated filters, exclusion patterns and the hide rule, read from their files.

use crate::labels::{match_term, term_label};
use std::collections::HashMap;
use std::path::Path;

pub type Filters = Vec<(String, Vec<String>)>;

/// `path`, else `<state_dir>/<fallback>` if that file exists; None if neither is a file.
/// A `path` that is given but missing does not fall back, as in Python.
fn resolve(
    path: Option<&Path>,
    state_dir: Option<&Path>,
    fallback: &str,
) -> Option<std::path::PathBuf> {
    let path = match path {
        Some(p) => p.to_path_buf(),
        None => {
            let candidate = state_dir?.join(fallback);
            if !candidate.is_file() {
                return None;
            }
            candidate
        }
    };
    path.is_file().then_some(path)
}

/// The file's text; None when it vanished since `resolve`, and None (logged) when it
/// exists but cannot be read, which would otherwise pass for an empty file.
fn read_text(path: &Path) -> Option<String> {
    match std::fs::read_to_string(path) {
        Ok(t) => Some(t),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => {
            tracing::error!("cannot read {}: {e}", path.display());
            None
        }
    }
}

/// A filter's search term. `elsewhere`: written `@term`, it is searched through Prowlarr's
/// other indexers as well as on the tracker. `albums`: written `%term`, it is also searched
/// on the album index. The prefixes combine, in either order.
#[derive(Debug, Clone, PartialEq)]
pub struct Term {
    pub text: String,
    pub elsewhere: bool,
    pub albums: bool,
}

pub type FilterTerms = Vec<(String, Vec<Term>)>;

fn parse_filters(text: &str) -> FilterTerms {
    let mut filters: FilterTerms = vec![];
    let mut name = "Curated".to_string();
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') && line.len() >= 2 {
            let n = line[1..line.len() - 1].trim();
            name = if n.is_empty() { "Curated" } else { n }.to_string();
            continue;
        }
        let (mut rest, mut elsewhere, mut albums) = (line, false, false);
        loop {
            if let Some(r) = rest.strip_prefix('@') {
                elsewhere = true;
                rest = r.trim_start();
            } else if let Some(r) = rest.strip_prefix('%') {
                albums = true;
                rest = r.trim_start();
            } else {
                break;
            }
        }
        let term = Term {
            text: rest.trim().to_string(),
            elsewhere,
            albums,
        };
        if term.text.is_empty() {
            continue;
        }
        if let Some((_, terms)) = filters.iter_mut().find(|(n, _)| *n == name) {
            terms.push(term);
        } else {
            filters.push((name.clone(), vec![term]));
        }
    }
    filters
}

/// The curated filters with each term's `@` flag; see `load_filters` for the file.
pub fn load_filter_terms(path: Option<&Path>, state_dir: Option<&Path>) -> FilterTerms {
    let Some(path) = resolve(path, state_dir, "filter.txt") else {
        return vec![];
    };
    read_text(&path).map_or_else(Vec::new, |t| parse_filters(&t))
}

/// The curated filters as [(name, [search terms])], in file order.
///
/// Read from `path`, falling back to `filter.txt` in `state_dir`; neither means no curated
/// filters. A `[Name]` line starts a filter, each line under it is a tracker search term,
/// and terms before any header belong to "Curated". Blank lines and `#` comments are
/// ignored. On galactica the file is the plab-filter sops secret: the names and terms are
/// kept out of this repository on purpose. A term written `@term` is also searched on other
/// indexers, and `%term` on the album index (see `load_filter_terms`); here `@` and `%` are
/// stripped.
pub fn load_filters(path: Option<&Path>, state_dir: Option<&Path>) -> Filters {
    load_filter_terms(path, state_dir)
        .into_iter()
        .map(|(name, terms)| (name, terms.into_iter().map(|t| t.text).collect()))
        .collect()
}

/// The hide rule: a scene is hidden when one of its terms is a hide term and none is a
/// keep term, so it hides only what its own tags make certain. Lowercase. On galactica
/// both lists are the `[hide]` and `[keep]` sections of the plab-exclude sops secret; the
/// words are kept out of this repository on purpose.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct HideRule {
    pub hide: Vec<String>,
    pub keep: Vec<String>,
}

/// What a scene is matched on, lowercase: its whole tags, or, for a title with no tag
/// list, the title's whole words.
#[derive(Debug, Clone, PartialEq)]
pub enum Terms {
    Tags(Vec<String>),
    Words(String),
}

impl Terms {
    fn has(&self, term: &str) -> bool {
        match self {
            Terms::Tags(tags) => tags.iter().any(|t| t == term),
            Terms::Words(text) => crate::candidates::has_word(text, term),
        }
    }
}

impl HideRule {
    pub fn hides(&self, terms: &Terms) -> bool {
        self.hide.iter().any(|h| terms.has(h)) && !self.keep.iter().any(|k| terms.has(k))
    }
}

/// A release title's terms: the tag list `labels` finds, else the title's words. A tagged
/// title's free text is not used: it can name a term the scene is not.
pub fn title_terms(title: &str) -> Terms {
    let tags = crate::labels::labels(title, 0).tags;
    if tags.is_empty() {
        Terms::Words(title.to_lowercase())
    } else {
        Terms::Tags(tags)
    }
}

/// A Stash scene under the rule, on its tags. A man in the cast keeps it: Stash casts often
/// leave male performers out, so a listed one proves presence and a missing one proves
/// nothing.
pub fn scene_hidden(rule: &HideRule, scene: &crate::stash::library::LibScene) -> bool {
    if scene.performers.iter().any(|p| p.gender.as_deref() == Some("MALE")) {
        return false;
    }
    rule.hides(&Terms::Tags(scene.tags.iter().map(|t| t.name.to_lowercase()).collect()))
}

/// The exclude file: regex patterns, then the optional `[hide]` and `[keep]` sections.
#[derive(Debug, Default)]
pub struct Excludes {
    pub patterns: Vec<fancy_regex::Regex>,
    pub rule: HideRule,
}

impl From<Vec<fancy_regex::Regex>> for Excludes {
    fn from(patterns: Vec<fancy_regex::Regex>) -> Self {
        Excludes { patterns, rule: HideRule::default() }
    }
}

impl Excludes {
    /// True if a pattern matches the title or the rule hides it.
    pub fn excluded(&self, title: &str) -> bool {
        self.pattern_excluded(title) || self.rule.hides(&title_terms(title))
    }

    /// The patterns alone: for album names, which are not scenes.
    pub fn pattern_excluded(&self, title: &str) -> bool {
        self.patterns.iter().any(|p| p.is_match(title).unwrap_or(false))
    }

    pub fn is_empty(&self) -> bool {
        self.patterns.is_empty() && self.rule.hide.is_empty()
    }
}

/// Lines before any section are regexes, case-insensitive; Python raised on a bad pattern,
/// here it is logged and skipped so one typo cannot sink the refresh. A line that is exactly
/// `[hide]` or `[keep]` starts that section, whose lines are plain terms. Blank lines and
/// `#` comments are ignored throughout.
pub fn parse_excludes(text: &str) -> Excludes {
    #[derive(PartialEq)]
    enum In {
        Patterns,
        Hide,
        Keep,
    }
    let mut at = In::Patterns;
    let mut ex = Excludes::default();
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        match line {
            "[hide]" => at = In::Hide,
            "[keep]" => at = In::Keep,
            _ if at == In::Hide => ex.rule.hide.push(line.to_lowercase()),
            _ if at == In::Keep => ex.rule.keep.push(line.to_lowercase()),
            // An inline flag, not RegexBuilder::case_insensitive: fancy-regex 0.14 drops the
            // builder's flag for some patterns (`\b` ones among them), so `\bword` never
            // matched "Word".
            _ => match fancy_regex::Regex::new(&format!("(?i){line}")) {
                Ok(re) => ex.patterns.push(re),
                Err(err) => tracing::warn!("bad exclude pattern {line:?}: {err}"),
            },
        }
    }
    ex
}

/// The exclude file from `path` or `<state_dir>/exclude.txt`; none means nothing excluded.
pub fn load_excludes(path: Option<&Path>, state_dir: Option<&Path>) -> Excludes {
    resolve(path, state_dir, "exclude.txt")
        .and_then(|p| read_text(&p))
        .map_or_else(Excludes::default, |t| parse_excludes(&t))
}

/// The curated filters a release belongs to, in file order, and the badge of the first.
///
/// `found` holds {filter name: badge} for filters whose search returned it; any other
/// filter claims it when the title names one of its terms.
pub fn match_filters(
    filters: &Filters,
    title: &str,
    found: Option<&HashMap<String, String>>,
) -> (Vec<String>, Option<String>) {
    let mut matched = found.cloned().unwrap_or_default();
    for (name, terms) in filters {
        if matched.contains_key(name) {
            continue;
        }
        if let Some(term) = terms.iter().find(|t| match_term(t, title)) {
            matched.insert(name.clone(), term_label(term));
        }
    }
    let names: Vec<String> = filters
        .iter()
        .filter(|(n, _)| matched.contains_key(n))
        .map(|(n, _)| n.clone())
        .collect();
    let badge = names.first().map(|n| matched[n].clone());
    (names, badge)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(dir: &tempfile::TempDir, name: &str, text: &str) -> std::path::PathBuf {
        let p = dir.path().join(name);
        std::fs::write(&p, text).unwrap();
        p
    }

    fn f(name: &str, terms: &[&str]) -> (String, Vec<String>) {
        (name.into(), terms.iter().map(|s| s.to_string()).collect())
    }

    #[cfg(unix)]
    #[test]
    fn unreadable_file_is_logged_not_silent() {
        use std::os::unix::fs::PermissionsExt;
        let d = tempfile::tempdir().unwrap();
        let p = write(&d, "f.txt", "[A]\nx\n");
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o000)).unwrap();
        if std::fs::read_to_string(&p).is_ok() {
            return; // running as root: permissions do not apply
        }
        let out = crate::testlog::capture(|| {
            assert!(load_filters(Some(&p), None).is_empty());
            assert!(load_excludes(Some(&p), None).is_empty());
        });
        assert_eq!(out.matches("cannot read").count(), 2, "{out}");
        assert!(out.contains("ERROR") && out.contains("f.txt"), "{out}");
    }

    #[test]
    fn no_file_means_no_filters() {
        let d = tempfile::tempdir().unwrap();
        assert!(load_filters(Some(Path::new("/nonexistent/file")), Some(d.path())).is_empty());
    }

    #[test]
    fn sections_comments_and_whitespace() {
        let d = tempfile::tempdir().unwrap();
        let p = write(
            &d,
            "f.txt",
            "# comment\n\n[Group A]\n  Alpha  \n# more\n\"two words\"\n\n[ Group B ]\nBeta\n[Empty]\n",
        );
        assert_eq!(
            load_filters(Some(&p), None),
            vec![
                f("Group A", &["Alpha", "\"two words\""]),
                f("Group B", &["Beta"])
            ]
        );
    }

    #[test]
    fn terms_before_any_header_are_curated() {
        let d = tempfile::tempdir().unwrap();
        let p = write(&d, "f.txt", "Alpha\n[Group B]\nBeta\n");
        assert_eq!(
            load_filters(Some(&p), None),
            vec![f("Curated", &["Alpha"]), f("Group B", &["Beta"])]
        );
    }

    #[test]
    fn repeated_header_extends_the_filter() {
        let d = tempfile::tempdir().unwrap();
        let p = write(&d, "f.txt", "[A]\nx\n[B]\ny\n[A]\nz\n");
        assert_eq!(
            load_filters(Some(&p), None),
            vec![f("A", &["x", "z"]), f("B", &["y"])]
        );
    }

    #[test]
    fn filters_from_state_dir() {
        let d = tempfile::tempdir().unwrap();
        write(&d, "filter.txt", "[Group A]\nAlpha\n");
        assert_eq!(
            load_filters(None, Some(d.path())),
            vec![f("Group A", &["Alpha"])]
        );
    }

    #[test]
    fn filters_none_without_path_or_state_dir() {
        assert!(load_filters(None, None).is_empty());
    }

    #[test]
    fn load_excludes_from_file() {
        let d = tempfile::tempdir().unwrap();
        let p = write(
            &d,
            "terms.txt",
            "# comment line\n\n  apple  \n\\bbanana\\w*  \n",
        );
        let patterns = load_excludes(Some(&p), None);
        assert_eq!(patterns.patterns.len(), 2);
        assert!(patterns.excluded("A big red apple pie"));
        assert!(patterns.excluded("Sweet bananas for sale"));
        assert!(!patterns.excluded("Fresh orange juice"));
    }

    #[test]
    fn a_word_boundary_pattern_ignores_case() {
        let d = tempfile::tempdir().unwrap();
        let p = write(&d, "terms.txt", "\\bbanana\\w*\n\\bkiwi\\b\n");
        let patterns = load_excludes(Some(&p), None);
        assert!(patterns.excluded("Sweet BANANAS for sale"));
        assert!(patterns.excluded("One Kiwi, peeled"));
        assert!(!patterns.excluded("Kiwifruit jam"));
    }

    #[test]
    fn load_excludes_fallback_to_state_dir() {
        let d = tempfile::tempdir().unwrap();
        write(&d, "exclude.txt", "pear\n");
        let patterns = load_excludes(None, Some(d.path()));
        assert_eq!(patterns.patterns.len(), 1);
        assert!(patterns.excluded("A sweet PEAR"));
        assert!(!patterns.excluded("An orange"));
    }

    #[test]
    fn load_excludes_missing_file_returns_empty() {
        let d = tempfile::tempdir().unwrap();
        let patterns = load_excludes(Some(Path::new("/nonexistent/file/path")), Some(d.path()));
        assert!(patterns.is_empty());
        assert!(!patterns.excluded("anything"));
    }

    #[test]
    fn match_filters_prefers_found_badges() {
        let filters = vec![f("A", &["alpha"]), f("B", &["one"])];
        let found = HashMap::from([("B".to_string(), "Searched".to_string())]);
        assert_eq!(
            match_filters(&filters, "Alpha One", Some(&found)),
            (
                vec!["A".to_string(), "B".to_string()],
                Some("Alpha".to_string())
            )
        );
        assert_eq!(match_filters(&filters, "nothing", None), (vec![], None));
    }

    #[test]
    fn at_marks_a_term_for_other_indexers_and_is_stripped() {
        let dir = tempfile::tempdir().unwrap();
        let p = write(
            &dir,
            "f.txt",
            "[Group A]\n@alpha\nbeta\n@\"two words\"\n[Group B]\n@ gamma\n",
        );
        let terms = load_filter_terms(Some(&p), None);
        let t = |text: &str, elsewhere| Term {
            text: text.into(),
            elsewhere,
            albums: false,
        };
        assert_eq!(
            terms,
            vec![
                (
                    "Group A".to_string(),
                    vec![t("alpha", true), t("beta", false), t("\"two words\"", true)]
                ),
                ("Group B".to_string(), vec![t("gamma", true)]),
            ]
        );
        // Callers that only search and match see the bare terms.
        assert_eq!(
            load_filters(Some(&p), None),
            vec![
                (
                    "Group A".to_string(),
                    vec!["alpha".to_string(), "beta".into(), "\"two words\"".into()]
                ),
                ("Group B".to_string(), vec!["gamma".to_string()]),
            ]
        );
    }

    #[test]
    fn a_lone_at_is_not_a_term() {
        let dir = tempfile::tempdir().unwrap();
        let p = write(&dir, "f.txt", "[Group A]\n@\nalpha\n");
        assert_eq!(
            load_filter_terms(Some(&p), None),
            vec![(
                "Group A".to_string(),
                vec![Term {
                    text: "alpha".into(),
                    elsewhere: false,
                    albums: false,
                }]
            )]
        );
    }

    #[test]
    fn percent_marks_an_album_index_term_and_combines_with_at() {
        let f = parse_filters("[G]\n%alpha\n@%beta\n% @gamma\ndelta\n%\n");
        let terms: Vec<(&str, bool, bool)> = f[0]
            .1
            .iter()
            .map(|t| (t.text.as_str(), t.elsewhere, t.albums))
            .collect();
        assert_eq!(
            terms,
            vec![
                ("alpha", false, true),
                ("beta", true, true),
                ("gamma", true, true),
                ("delta", false, false),
            ]
        );
    }

    fn rule(hide: &[&str], keep: &[&str]) -> HideRule {
        HideRule {
            hide: hide.iter().map(|s| s.to_string()).collect(),
            keep: keep.iter().map(|s| s.to_string()).collect(),
        }
    }

    fn tags(t: &[&str]) -> Terms {
        Terms::Tags(t.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn sections_split_patterns_from_terms() {
        let ex = parse_excludes(
            "apple\n[a-z]fruit\n\n[hide]\nPear\n# note\nwild plum\n[keep]\nKiwi\n",
        );
        assert_eq!(ex.patterns.len(), 2); // `[a-z]fruit` is a character class, not a header
        assert_eq!(ex.rule, rule(&["pear", "wild plum"], &["kiwi"]));
    }

    #[test]
    fn no_sections_means_an_empty_rule() {
        let ex = parse_excludes("apple\nbanana\n");
        assert_eq!(ex.patterns.len(), 2);
        assert_eq!(ex.rule, HideRule::default());
        assert!(!ex.excluded("[Site] Name [2020, Pear, 1080p]"));
    }

    #[test]
    fn hides_on_whole_tags() {
        let r = rule(&["pear"], &["kiwi"]);
        assert!(r.hides(&tags(&["fig", "pear"])));
        assert!(!r.hides(&tags(&["pear", "kiwi"])));
        assert!(!r.hides(&tags(&["pear/plum"]))); // a compound tag is not the term
        assert!(!r.hides(&tags(&["fig"])));
        assert!(!HideRule::default().hides(&tags(&["pear"])));
    }

    #[test]
    fn hides_on_whole_words() {
        let r = rule(&["pear", "wild plum"], &["kiwi"]);
        assert!(r.hides(&Terms::Words("site pear video".into())));
        assert!(!r.hides(&Terms::Words("pearl video".into())));
        assert!(r.hides(&Terms::Words("a wild plum, ripe".into())));
        assert!(!r.hides(&Terms::Words("pear and kiwi".into())));
    }

    #[test]
    fn title_terms_prefer_the_tag_list() {
        assert_eq!(
            title_terms("[Site.com] A Pear Story [2026-10-01, Fig, Kiwi, 1080p, SiteRip]"),
            tags(&["fig", "kiwi"])
        );
        assert_eq!(title_terms("Site 26 01 01 Pear Video 1080p"), Terms::Words("site 26 01 01 pear video 1080p".into()));
    }

    #[test]
    fn a_tagged_title_ignores_its_free_text() {
        let ex = parse_excludes("[hide]\npear\n");
        assert!(!ex.excluded("[Site.com] A Pear Story [2026-10-01, Fig, 1080p]"));
        assert!(ex.excluded("[Site.com] A Story [2026-10-01, Fig, Pear, 1080p]"));
        assert!(ex.excluded("site pear video"));
    }

    #[test]
    fn excluded_is_patterns_or_rule_and_albums_use_patterns_only() {
        let ex = parse_excludes("apple\n[hide]\npear\n");
        assert!(ex.excluded("an apple"));
        assert!(ex.excluded("a pear"));
        assert!(ex.pattern_excluded("an apple"));
        assert!(!ex.pattern_excluded("a pear"));
    }

    fn scene(tags: &[&str], genders: &[Option<&str>]) -> crate::stash::library::LibScene {
        serde_json::from_value(serde_json::json!({
            "id": "1",
            "tags": tags.iter().map(|t| serde_json::json!({"id": "t", "name": t})).collect::<Vec<_>>(),
            "performers": genders.iter().map(|g| serde_json::json!({"id": "p", "name": "P", "gender": g})).collect::<Vec<_>>(),
        }))
        .unwrap()
    }

    #[test]
    fn scene_hidden_uses_tags_and_a_listed_man_keeps() {
        let r = rule(&["pear"], &["kiwi"]);
        assert!(scene_hidden(&r, &scene(&["Pear"], &[Some("FEMALE"), Some("FEMALE")])));
        assert!(scene_hidden(&r, &scene(&["Pear"], &[]))); // an empty cast proves nothing
        assert!(scene_hidden(&r, &scene(&["Pear"], &[None])));
        assert!(!scene_hidden(&r, &scene(&["Pear", "Kiwi"], &[Some("FEMALE")])));
        assert!(!scene_hidden(&r, &scene(&["Pear"], &[Some("FEMALE"), Some("MALE")])));
        assert!(!scene_hidden(&r, &scene(&["Fig"], &[Some("FEMALE")])));
    }
}
