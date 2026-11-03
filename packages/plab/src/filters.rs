//! The curated filters and exclusion patterns, read from their files.

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

/// Regex exclusion patterns, case-insensitive, from `path` or `<state_dir>/exclude.txt`.
/// Python raised on a bad pattern; here it is logged and skipped so one typo cannot sink
/// the refresh.
pub fn load_excludes(path: Option<&Path>, state_dir: Option<&Path>) -> Vec<fancy_regex::Regex> {
    let Some(path) = resolve(path, state_dir, "exclude.txt") else {
        return vec![];
    };
    let Some(text) = read_text(&path) else {
        return vec![];
    };
    let mut patterns = vec![];
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // An inline flag, not RegexBuilder::case_insensitive: fancy-regex 0.14 drops the
        // builder's flag for some patterns (`\b` ones among them), so `\bword` never
        // matched "Word".
        match fancy_regex::Regex::new(&format!("(?i){line}")) {
            Ok(re) => patterns.push(re),
            Err(err) => tracing::warn!("bad exclude pattern {line:?}: {err}"),
        }
    }
    patterns
}

/// True if the title matches any exclusion pattern (the negation of Python's `exclude_predicate`).
pub fn excluded(patterns: &[fancy_regex::Regex], title: &str) -> bool {
    patterns.iter().any(|p| p.is_match(title).unwrap_or(false))
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
        assert_eq!(patterns.len(), 2);
        assert!(excluded(&patterns, "A big red apple pie"));
        assert!(excluded(&patterns, "Sweet bananas for sale"));
        assert!(!excluded(&patterns, "Fresh orange juice"));
    }

    #[test]
    fn a_word_boundary_pattern_ignores_case() {
        let d = tempfile::tempdir().unwrap();
        let p = write(&d, "terms.txt", "\\bbanana\\w*\n\\bkiwi\\b\n");
        let patterns = load_excludes(Some(&p), None);
        assert!(excluded(&patterns, "Sweet BANANAS for sale"));
        assert!(excluded(&patterns, "One Kiwi, peeled"));
        assert!(!excluded(&patterns, "Kiwifruit jam"));
    }

    #[test]
    fn load_excludes_fallback_to_state_dir() {
        let d = tempfile::tempdir().unwrap();
        write(&d, "exclude.txt", "pear\n");
        let patterns = load_excludes(None, Some(d.path()));
        assert_eq!(patterns.len(), 1);
        assert!(excluded(&patterns, "A sweet PEAR"));
        assert!(!excluded(&patterns, "An orange"));
    }

    #[test]
    fn load_excludes_missing_file_returns_empty() {
        let d = tempfile::tempdir().unwrap();
        let patterns = load_excludes(Some(Path::new("/nonexistent/file/path")), Some(d.path()));
        assert!(patterns.is_empty());
        assert!(!excluded(&patterns, "anything"));
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
}
