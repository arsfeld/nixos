//! Tags, quality, studio and category read from a release title. Pure.

#[derive(Debug, Clone, PartialEq)]
pub struct Labels {
    pub tags: Vec<String>,
    pub quality: Option<String>,
    pub studio: Option<String>,
    pub category: &'static str,
    pub name: String,
}

use crate::tracker::forums::category;
use regex::Regex;
use std::sync::LazyLock;

static GROUP: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\[([^\[\]]*)\]").unwrap());
// Anchored: Python used fullmatch.
static DATE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^(?:\d{4}(?:\s*г\.?)?|\d{1,2}[./-]\d{1,2}[./-]\d{4}|\d{4}[./-]\d{1,2}[./-]\d{1,2})$",
    )
    .unwrap()
});
static RES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\d{3,4}p$").unwrap());
static NON_WORD: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[\W_]+").unwrap());
static SPACES: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").unwrap());

fn quality(token: &str) -> Option<String> {
    if RES.is_match(token) {
        return Some(token.to_string());
    }
    matches!(token, "4k" | "uhd").then(|| "2160p".to_string())
}

// The rip, not the content: never a tag.
const NOISE: &[&str] = &[
    "siterip", "webrip", "web-dl", "camrip", "dvdrip", "hd", "fullhd",
];

/// The title's parts: studio, the release's own name, tags and quality, plus the forum's category.
pub fn labels(title: &str, forum: u32) -> Labels {
    let mut tags: Vec<String> = vec![];
    let mut qual: Option<String> = None;
    let mut site: Option<String> = None;
    let title = title.trim();
    // The leading bracket is the studio, not a tag list, even if it holds a comma.
    let groups: Vec<_> = GROUP
        .captures_iter(title)
        .filter(|m| m[1].contains(',') && m.get(0).unwrap().start() != 0)
        .collect();
    // A performer list has commas too; the tag list is the one dated or carrying a quality.
    let mut dated = groups.iter().filter(|m| {
        m[1].split(',').any(|x| {
            let t = x.trim().to_lowercase();
            DATE.is_match(&t) || quality(&t).is_some()
        })
    });
    let tag_group = dated.next_back().or_else(|| groups.last());
    if let Some(g) = tag_group {
        for raw in g[1].split(',') {
            let token = raw.trim();
            let low = token.to_lowercase();
            if low.is_empty() || DATE.is_match(&low) || NOISE.contains(&low.as_str()) {
                continue;
            }
            if let Some(q) = quality(&low) {
                qual.get_or_insert(q);
            } else if low.contains('.') {
                // a site named among the tags, as the Russian titles do
                site.get_or_insert_with(|| token.to_string());
            } else if !tags.contains(&low) {
                tags.push(low);
            }
        }
    }
    let mut studio = site;
    let mut name = match tag_group {
        Some(g) => {
            let r = g.get(0).unwrap();
            format!("{}{}", &title[..r.start()], &title[r.end()..])
        }
        None => title.to_string(),
    };
    if title.starts_with('[')
        && let Some(m) = GROUP
            .captures(title)
            .filter(|m| m.get(0).unwrap().start() == 0)
    {
        let first = m[1].split(" / ").next().unwrap_or("").trim();
        if first.contains('.') {
            studio = Some(first.to_string());
            name = name[m.get(0).unwrap().end()..].to_string();
        }
    }
    let name = SPACES.replace_all(&name, " ").trim().to_string();
    Labels {
        tags,
        quality: qual,
        studio,
        category: category(forum),
        name: if name.is_empty() {
            title.to_string()
        } else {
            name
        },
    }
}

fn squash(s: &str) -> String {
    NON_WORD.replace_all(&s.to_lowercase(), "").into_owned()
}

/// True if `title` contains the search `term`, ignoring case, spaces and punctuation.
pub fn match_term(term: &str, title: &str) -> bool {
    let t = squash(term);
    !t.is_empty() && squash(title).contains(&t)
}

/// A search term as a badge: quotes dropped, an all-lowercase term capitalized.
pub fn term_label(term: &str) -> String {
    let t = term.trim().trim_matches(|c| c == '"' || c == '\'');
    if t == t.to_lowercase() {
        py_title(t)
    } else {
        t.to_string()
    }
}

/// `str.title()`: upper-case a cased char that follows an uncased one, lower-case it otherwise.
pub fn py_title(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_cased = false;
    for c in s.chars() {
        if c.is_lowercase() || c.is_uppercase() {
            if prev_cased {
                out.extend(c.to_lowercase());
            } else {
                out.extend(c.to_uppercase());
            }
            prev_cased = true;
        } else {
            out.push(c);
            prev_cased = false;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tags(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn bracket_site_and_tags() {
        let r = labels(
            "[SiteA.com] Performer A, Performer B [2026, Alpha, Big Beta, Gamma, Redhead, 1080p, SiteRip]",
            1875,
        );
        assert_eq!(r.tags, tags(&["alpha", "big beta", "gamma", "redhead"])); // siterip is the rip, not content
        assert_eq!(r.quality.as_deref(), Some("1080p"));
        assert_eq!(r.studio.as_deref(), Some("SiteA.com"));
        assert_eq!(r.category, "Clips");
        assert_eq!(r.name, "Performer A, Performer B");
    }

    #[test]
    fn site_in_tag_list_is_the_studio() {
        let r = labels(
            "Заплатил дважды / I Paid Twice! [2026 г, SiteA.com, Beta, alpha, 1080p, HD][Uploader]",
            1741,
        );
        assert_eq!(r.studio.as_deref(), Some("SiteA.com"));
        assert_eq!(r.tags, tags(&["beta", "alpha"]));
        assert_eq!(r.name, "Заплатил дважды / I Paid Twice! [Uploader]");
    }

    #[test]
    fn tag_list_is_the_group_with_a_date_or_quality() {
        let r = labels(
            "Заплатил / I Pay [2026 г, SiteA.com, Beta, alpha, 1080p] [UserA, UserB aka ChannelC]",
            1741,
        );
        assert_eq!(r.tags, tags(&["beta", "alpha"]));
        assert_eq!(r.name, "Заплатил / I Pay [UserA, UserB aka ChannelC]");
    }

    #[test]
    fn bracket_studio_wins_over_site_in_tags() {
        let r = labels("[SiteB.com] A - B [2026, SiteA.com, Beta]", 1878);
        assert_eq!(r.studio.as_deref(), Some("SiteB.com"));
        assert_eq!(r.tags, tags(&["beta"]));
    }

    #[test]
    fn multi_studio_with_date() {
        let r = labels(
            "[SiteC.com / SiteD.com] Performer D - Some Title [05.10.2026, Alpha, Delta To Epsilon, Brunette]",
            1875,
        );
        assert_eq!(r.tags, tags(&["alpha", "delta to epsilon", "brunette"]));
        assert_eq!(r.quality, None);
        assert_eq!(r.studio.as_deref(), Some("SiteC.com"));
    }

    #[test]
    fn last_comma_group_wins() {
        let r = labels(
            "[SiteE.com / SiteF.com / SiteG.com / Studio Group] Performer E - ... (5321022) [2026-10-02, Alpha, Zeta, 1080p]",
            1823,
        );
        assert_eq!(r.tags, tags(&["alpha", "zeta"]));
        assert_eq!(r.quality.as_deref(), Some("1080p"));
        assert_eq!(r.studio.as_deref(), Some("SiteE.com"));
        assert_eq!(r.category, "VR");
    }

    #[test]
    fn no_bracket_studio() {
        let r = labels(
            "Performer C - It's A Test [ABC-123] [2026 г., 1080p]",
            424242,
        );
        assert!(r.tags.is_empty());
        assert_eq!(r.quality.as_deref(), Some("1080p"));
        assert_eq!(r.studio, None);
        assert_eq!(r.category, "Other");
        assert_eq!(r.name, "Performer C - It's A Test [ABC-123]");
    }

    #[test]
    fn plain_title() {
        let r = labels("Just a title", 10);
        assert_eq!(
            r,
            Labels {
                tags: vec![],
                quality: None,
                studio: None,
                category: "Group A",
                name: "Just a title".into()
            }
        );
    }

    #[test]
    fn date_shapes_dropped() {
        let r = labels(
            "x [2026, 2025 г., 05.10.2026, 2026-10-02, 5.1.2026, 2026.10.02, Foo]",
            1,
        );
        assert_eq!(r.tags, tags(&["foo"]));
    }

    #[test]
    fn four_k_and_uhd() {
        assert_eq!(
            labels("[S.com] a [2026, 4K, Alpha]", 1).quality.as_deref(),
            Some("2160p")
        );
        assert_eq!(
            labels("[S.com] a [2026, UHD, Alpha]", 1).quality.as_deref(),
            Some("2160p")
        );
        assert_eq!(
            labels("[S.com] a [2026, 4K, Alpha]", 1).tags,
            tags(&["alpha"])
        );
    }

    #[test]
    fn first_quality_wins_and_all_removed_from_tags() {
        let r = labels("a [Alpha, 720p, 1080p]", 1);
        assert_eq!(r.quality.as_deref(), Some("720p"));
        assert_eq!(r.tags, tags(&["alpha"]));
    }

    #[test]
    fn dedupe_and_order() {
        let r = labels("a [Alpha, alpha , Zeta, ALPHA, Eta]", 1);
        assert_eq!(r.tags, tags(&["alpha", "zeta", "eta"]));
    }

    #[test]
    fn leading_bracket_never_tags() {
        let r = labels("[Site.com, Other.com] Title [2026, Alpha]", 1);
        assert_eq!(r.tags, tags(&["alpha"]));
        assert!(labels("[A, B] Title", 1).tags.is_empty());
    }

    #[test]
    fn studio_needs_a_domain() {
        assert_eq!(labels("[Studio] a [2026, Alpha]", 1).studio, None);
        assert_eq!(
            labels("  [Site.com] a [2026, Alpha]", 1).studio.as_deref(),
            Some("Site.com")
        );
    }

    #[test]
    fn studio_only_if_title_starts_with_bracket() {
        assert_eq!(labels("x [Studio.com] y [a, b]", 1).studio, None);
    }

    #[test]
    fn bracket_without_comma_ignored_for_tags() {
        assert!(labels("[Studio] y [solo]", 1).tags.is_empty());
    }

    #[test]
    fn match_term_ignores_case_spaces_and_punctuation() {
        assert!(match_term(
            "Alpha Studio",
            "[AlphaStudio.com] Scene [1080p]"
        ));
        assert!(match_term("\"two words\"", "Some Two-Words Release"));
        assert!(match_term("A-B", "ab release"));
        assert!(!match_term("Alpha Studio", "Beta Studio Release"));
        assert!(!match_term("\"\"", "anything"));
    }

    #[test]
    fn term_label_capitalizes() {
        assert_eq!(term_label("\"two words\""), "Two Words");
        assert_eq!(term_label("AlphaCo"), "AlphaCo");
    }

    #[test]
    fn py_title_matches_cpython() {
        assert_eq!(py_title("two words"), "Two Words");
        assert_eq!(py_title("it's a-b 3rd"), "It'S A-B 3Rd");
        assert_eq!(py_title("ЗАПЛАТИЛ жопой"), "Заплатил Жопой");
        assert_eq!(py_title(""), "");
        // Uncased letters (CJK) do not count as cased, so they do not lower what follows.
        assert_eq!(py_title("日本a"), "日本A");
        assert_eq!(py_title("o'neil"), "O'Neil");
        assert_eq!(py_title("aǆb"), "Aǆb");
    }
}
