//! Pure HTML -> data for the tracker's pages. No I/O, so it is tested against fixtures.
//!
//! The tracker's markup is old, regular phpBB-style HTML; each field sits in a fixed cell,
//! so a regex per field over one row's markup is enough and far shorter than a parser.

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct Row {
    pub id: u64,
    pub title: String,
    pub forum: u32,
    pub size: u64,
    pub seeders: u32,
    pub leechers: u32,
    pub completed: u32,
    pub added: i64,
}

use regex::Regex;
use std::sync::LazyLock;

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap()
}

static TAGS: LazyLock<Regex> = LazyLock::new(|| re(r"<[^>]+>"));
static LIMIT: LazyLock<Regex> = LazyLock::new(|| re(r"текущий лимит:\s*(\d+)"));
static INFO: LazyLock<Regex> = LazyLock::new(|| re(r#"(?s)<div class="mrg_16">(.*?)</div>"#));
static LINK: LazyLock<Regex> = LazyLock::new(|| {
    re(r#"(?s)class="[^"]*\btLink\b[^"]*" href="\./viewtopic\.php\?t=(\d+)">(.*?)</a>"#)
});
static FORUM: LazyLock<Regex> = LazyLock::new(|| re(r#"(?s)href="tracker\.php\?f=(\d+)""#));
static SIZE: LazyLock<Regex> = LazyLock::new(|| re(r"(?s)<u>(\d+)</u>\s*<a [^>]*\btr-dl\b"));
static SEEDERS: LazyLock<Regex> =
    LazyLock::new(|| re(r#"(?s)class="row4 seed[^"]*"><u>(\d+)</u>"#));
static LEECHERS: LazyLock<Regex> =
    LazyLock::new(|| re(r#"(?s)class="row4 leech[^"]*"[^>]*><b>(\d+)</b>"#));
static COMPLETED: LazyLock<Regex> =
    LazyLock::new(|| re(r#"(?s)<td class="row4 small">(\d+)</td>"#));
static ADDED: LazyLock<Regex> = LazyLock::new(|| re(r#"(?s)title="Добавлен">\s*<u>(\d+)</u>"#));
static POST_IMG: LazyLock<Regex> =
    LazyLock::new(|| re(r#"<var class="postImg[^"]*" title="([^"]+)""#));

/// Decodes every HTML5 named entity plus numeric `&#NNN;` and `&#xHH;`, as Python's
/// `html.unescape` did before the port.
pub fn html_unescape(s: &str) -> String {
    html_escape::decode_html_entities(s).into_owned()
}

fn int<T: std::str::FromStr + Default>(re: &Regex, text: &str) -> T {
    re.captures(text)
        .and_then(|m| m[1].parse().ok())
        .unwrap_or_default()
}

fn text(fragment: &str) -> String {
    html_unescape(&TAGS.replace_all(fragment, ""))
        .trim()
        .to_string()
}

pub fn logged_in(page: &str) -> bool {
    // The top menu's logout link only renders for a live session.
    page.contains("{logout: 1}")
}

pub fn needs_captcha(page: &str) -> bool {
    page.contains("cap_sid")
}

/// The tracker's per-day .torrent quota if `page` is its limit-reached reply, else None.
pub fn daily_limit(page: &str) -> Option<u32> {
    if !page.contains("исчерпали суточный лимит") {
        return None;
    }
    Some(
        LIMIT
            .captures(page)
            .and_then(|m| m[1].parse().ok())
            .unwrap_or(0),
    )
}

/// Text of the tracker's info box (first mrg_16 div), or None; best effort.
pub fn info_message(page: &str) -> Option<String> {
    let m = INFO.captures(page)?;
    let joined = html_unescape(&TAGS.replace_all(&m[1], " "))
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    (!joined.is_empty()).then_some(joined)
}

/// Tracker result rows in page order.
pub fn rows(page: &str) -> Vec<Row> {
    let Some(start) = page.find(r#"id="tor-tbl""#) else {
        return vec![];
    };
    let Some(open) = page[start..].find("<tbody>").map(|i| start + i) else {
        return vec![];
    };
    let close = page[start..]
        .find("</tbody>")
        .map_or(page.len(), |i| start + i);
    let body = page.get(open..close).unwrap_or("");
    let mut out = vec![];
    for chunk in body.split(r#"<tr class="tCenter">"#).skip(1) {
        let Some(link) = LINK.captures(chunk) else {
            continue;
        };
        out.push(Row {
            id: link[1].parse().unwrap_or(0),
            title: text(&link[2]),
            forum: int(&FORUM, chunk),
            size: int(&SIZE, chunk),
            seeders: int(&SEEDERS, chunk),
            leechers: int(&LEECHERS, chunk),
            completed: int(&COMPLETED, chunk),
            added: int(&ADDED, chunk),
        });
    }
    out
}

/// The pager's link to the results page beginning at row `start`, if there is one.
pub fn page_link(page: &str, start: usize) -> Option<String> {
    let re = Regex::new(&format!(
        r#"href="(tracker\.php\?search_id=[^"&]+&amp;start={start})""#
    ))
    .unwrap();
    re.captures(page).map(|m| html_unescape(&m[1]))
}

/// Image URLs of the topic's first post (the release), in order, without repeats.
pub fn images(page: &str) -> Vec<String> {
    let Some(start) = page.find(r#"class="post_body""#) else {
        return vec![];
    };
    let find_after = |needle: &str, from: usize| page.get(from..)?.find(needle).map(|i| from + i);
    let end = [
        find_after(r#"id="tor-reged""#, start),
        find_after(r#"class="post_body""#, start + 1),
    ]
    .into_iter()
    .flatten()
    .filter(|&i| i > 0)
    .min();
    let post = &page[start..end.unwrap_or(page.len())];
    let mut out: Vec<String> = vec![];
    for m in POST_IMG.captures_iter(post) {
        let url = html_unescape(&m[1]);
        if (url.starts_with("https://") || url.starts_with("http://")) && !out.contains(&url) {
            out.push(url);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(name: &str) -> String {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(name);
        let bytes = std::fs::read(path).unwrap();
        match std::str::from_utf8(&bytes) {
            Ok(s) => s.to_owned(),
            Err(_) => encoding_rs::WINDOWS_1251.decode(&bytes).0.into_owned(),
        }
    }

    #[test]
    fn logged_in_marker() {
        assert!(logged_in(&fixture("tracker.html")));
        assert!(!logged_in(
            "<html><form action=\"/forum/login.php\"></html>"
        ));
    }

    #[test]
    fn needs_captcha_marker() {
        assert!(needs_captcha(
            r#"<input type="hidden" name="cap_sid" value="x">"#
        ));
        assert!(!needs_captcha(&fixture("tracker.html")));
    }

    #[test]
    fn daily_limit_value() {
        assert_eq!(daily_limit(&fixture("limit.html")), Some(10));
    }

    #[test]
    fn daily_limit_without_number() {
        assert_eq!(
            daily_limit("<div>Вы уже исчерпали суточный лимит скачиваний</div>"),
            Some(0)
        );
    }

    #[test]
    fn daily_limit_absent() {
        assert_eq!(daily_limit(&fixture("tracker.html")), None);
    }

    #[test]
    fn info_message_text() {
        assert_eq!(
            info_message(&fixture("limit.html")).as_deref(),
            Some(
                "Вы уже исчерпали суточный лимит скачиваний торрент-файлов Ваш текущий лимит: 10 в день"
            )
        );
        assert_eq!(
            info_message("<div class=\"mrg_16\"> Тема\n  удалена &amp; всё </div>").as_deref(),
            Some("Тема удалена & всё")
        );
    }

    #[test]
    fn info_message_absent() {
        assert_eq!(info_message("<html></html>"), None);
    }

    #[test]
    fn rows_fixture() {
        assert_eq!(
            rows(&fixture("tracker.html")),
            vec![
                Row {
                    id: 3313754,
                    title:
                        "[Studio.com] Performer A, Performer B [2026, Rock & Roll, 1080p, SiteRip]"
                            .into(),
                    forum: 1875,
                    size: 2254024095,
                    seeders: 310,
                    leechers: 4,
                    completed: 3189,
                    added: 1791117232,
                },
                Row {
                    id: 3314001,
                    title: "Performer C - It's A Test [ABC-123] [2026 г., 1080p]".into(),
                    forum: 1818,
                    size: 5000000000,
                    seeders: 12,
                    leechers: 0,
                    completed: 40,
                    added: 1791200000,
                },
            ]
        );
    }

    #[test]
    fn no_table() {
        assert!(rows("<html>nothing</html>").is_empty());
    }

    #[test]
    fn page_link_by_start() {
        let page = fixture("tracker.html");
        assert_eq!(
            page_link(&page, 50).as_deref(),
            Some("tracker.php?search_id=AbCdEf123&start=50")
        );
        assert_eq!(
            page_link(&page, 100).as_deref(),
            Some("tracker.php?search_id=AbCdEf123&start=100")
        );
        assert_eq!(page_link(&page, 150), None);
    }

    #[test]
    fn first_post_only_in_order_deduplicated() {
        assert_eq!(
            images(&fixture("topic.html")),
            vec![
                "https://i128.fastpic.org/big/2026/1004/19/cover.jpg",
                "https://i128.fastpic.org/thumb/2026/1004/a1/_a.jpeg",
                "https://i128.fastpic.org/thumb/2026/1004/04/_b.jpeg?x=1&y=2",
            ]
        );
    }

    #[test]
    fn no_post() {
        assert!(images("<html></html>").is_empty());
    }

    #[test]
    fn unescape_entities() {
        assert_eq!(
            html_unescape(
                "a &amp; b &lt;&gt; &quot;q&quot; &#39;x&#039; &apos; &#x41;&#66; &nbsp;|&radic;"
            ),
            "a & b <> \"q\" 'x' ' AB \u{a0}|\u{221a}"
        );
        // Entities the fixtures never happened to contain.
        assert_eq!(
            html_unescape("&laquo;Тема&raquo; &mdash; часть 1&hellip;"),
            "«Тема» — часть 1…"
        );
        assert_eq!(
            html_unescape("&unknown; & &#xZZ; &amp"),
            "&unknown; & &#xZZ; &amp"
        );
    }
}
