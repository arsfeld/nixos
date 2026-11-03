//! The tracker session's cookies: name -> value, for the one site plab talks to.
//!
//! Python kept a MozillaCookieJar on disk; plab keeps this map as JSON in `kv`. Only the
//! tracker's own cookies are ever stored, so domain and path matching collapse to "is the
//! request for the tracker's host" (see `Tracker::open`).

use std::collections::BTreeMap;

#[derive(Debug, Clone, Default, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct CookieJar(pub BTreeMap<String, String>);

impl CookieJar {
    /// The `Cookie` request header ("a=1; b=2", in name order), or None for an empty jar.
    pub fn header(&self) -> Option<String> {
        if self.0.is_empty() {
            return None;
        }
        Some(
            self.0
                .iter()
                .map(|(k, v)| format!("{k}={v}"))
                .collect::<Vec<_>>()
                .join("; "),
        )
    }

    /// Apply one `Set-Cookie` response header: Max-Age <= 0 or an Expires in the past remove it.
    pub fn apply_set_cookie(&mut self, header: &str) {
        let mut parts = header.split(';');
        let Some((name, value)) = parts.next().and_then(|p| p.split_once('=')) else {
            return;
        };
        let (name, value) = (name.trim(), value.trim());
        if name.is_empty() {
            return;
        }
        let mut max_age = None;
        let mut expires = None;
        for attr in parts {
            let (k, v) = attr.split_once('=').unwrap_or((attr, ""));
            match k.trim().to_ascii_lowercase().as_str() {
                "max-age" => max_age = v.trim().parse::<i64>().ok(),
                "expires" => expires = parse_http_date(v.trim()),
                _ => {}
            }
        }
        // Max-Age wins over Expires (RFC 6265 5.3 step 3).
        let gone = match (max_age, expires) {
            (Some(age), _) => age <= 0,
            (None, Some(at)) => at <= chrono::Utc::now().timestamp(),
            (None, None) => false,
        };
        if gone {
            self.0.remove(name);
        } else {
            self.0.insert(name.to_string(), value.to_string());
        }
    }

    /// A cookies.txt (MozillaCookieJar) file's cookies for the tracker's domain. Like
    /// `MozillaCookieJar.load` (with ignore_discard), session cookies are kept, expired ones
    /// dropped, and one malformed line fails the whole file, which lab.py read as an empty jar.
    pub fn from_netscape(text: &str) -> CookieJar {
        Self::try_from_netscape(text, chrono::Utc::now().timestamp()).unwrap_or_default()
    }

    fn try_from_netscape(text: &str, now: i64) -> Option<CookieJar> {
        let mut jar = CookieJar::default();
        let site = crate::site::get().tracker_domain();
        for line in text.lines() {
            let line = line.strip_prefix("#HttpOnly_").unwrap_or(line);
            let trimmed = line.trim();
            if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with('$') {
                continue;
            }
            let fields: Vec<&str> = line.split('\t').collect();
            let [
                domain,
                domain_specified,
                _path,
                _secure,
                expires,
                name,
                value,
            ] = fields[..]
            else {
                return None;
            };
            if (domain_specified == "TRUE") != domain.starts_with('.') {
                return None;
            }
            let expires = match expires {
                "" | "0" => None,
                e => Some(e.parse::<i64>().ok()?),
            };
            if name.is_empty() || expires.is_some_and(|e| e <= now) {
                continue;
            }
            let host = domain.trim_start_matches('.');
            if host == site || host.ends_with(&format!(".{site}")) {
                jar.set(name, value);
            }
        }
        Some(jar)
    }

    pub fn set(&mut self, name: &str, value: &str) {
        self.0.insert(name.to_string(), value.to_string());
    }
}

/// Unix seconds of a cookie Expires date: "Thu, 01 Jan 1970 00:00:01 GMT", or with dashes
/// ("01-Jan-1970"), as servers commonly send it.
fn parse_http_date(s: &str) -> Option<i64> {
    let s = s.replace('-', " ");
    let s = s
        .split_once(',')
        .map_or(s.as_str(), |(_, rest)| rest)
        .trim();
    chrono::NaiveDateTime::parse_from_str(s, "%d %b %Y %H:%M:%S GMT")
        .or_else(|_| chrono::NaiveDateTime::parse_from_str(s, "%d %b %y %H:%M:%S GMT"))
        .ok()
        .map(|t| t.and_utc().timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jar(pairs: &[(&str, &str)]) -> CookieJar {
        CookieJar(
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        )
    }

    #[test]
    fn header_empty_is_none() {
        assert_eq!(CookieJar::default().header(), None);
    }

    #[test]
    fn header_orders_by_name() {
        assert_eq!(
            jar(&[("b", "2"), ("a", "1")]).header().as_deref(),
            Some("a=1; b=2")
        );
    }

    #[test]
    fn set_cookie_adds() {
        let mut j = CookieJar::default();
        j.apply_set_cookie("bb_data=abc; path=/forum/; domain=.tracker.example; HttpOnly");
        assert_eq!(j, jar(&[("bb_data", "abc")]));
    }

    #[test]
    fn set_cookie_replaces() {
        let mut j = jar(&[("bb_data", "old"), ("x", "1")]);
        j.apply_set_cookie("bb_data=new; Max-Age=3600");
        assert_eq!(j, jar(&[("bb_data", "new"), ("x", "1")]));
    }

    #[test]
    fn set_cookie_max_age_zero_deletes() {
        let mut j = jar(&[("bb_data", "old"), ("x", "1")]);
        j.apply_set_cookie("bb_data=deleted; Max-Age=0; path=/forum/");
        assert_eq!(j, jar(&[("x", "1")]));
        j.apply_set_cookie("x=; max-age=-1");
        assert_eq!(j, CookieJar::default());
    }

    #[test]
    fn set_cookie_past_expires_deletes() {
        let mut j = jar(&[("a", "1"), ("b", "2")]);
        j.apply_set_cookie("a=deleted; expires=Thu, 01-Jan-1970 00:00:01 GMT; path=/");
        j.apply_set_cookie("b=deleted; Expires=Thu, 01 Jan 1970 00:00:01 GMT");
        assert_eq!(j, CookieJar::default());
    }

    #[test]
    fn set_cookie_future_expires_keeps() {
        let mut j = CookieJar::default();
        j.apply_set_cookie("a=1; expires=Fri, 31-Dec-2100 23:59:59 GMT");
        assert_eq!(j, jar(&[("a", "1")]));
    }

    #[test]
    fn set_cookie_value_keeps_equals_signs() {
        let mut j = CookieJar::default();
        j.apply_set_cookie(" tok = a=b== ; path=/");
        assert_eq!(j, jar(&[("tok", "a=b==")]));
    }

    #[test]
    fn set_cookie_without_name_is_ignored() {
        let mut j = CookieJar::default();
        j.apply_set_cookie("novalue; path=/");
        j.apply_set_cookie("=x");
        assert_eq!(j, CookieJar::default());
    }

    #[test]
    fn set_overwrites() {
        let mut j = jar(&[("bb_data", "old")]);
        j.set("bb_data", "new");
        assert_eq!(j, jar(&[("bb_data", "new")]));
    }

    #[test]
    fn from_netscape_mozilla_jar() {
        let text = "# Netscape HTTP Cookie File\n\
                    # http://curl.haxx.se/rfc/cookie_spec.html\n\
                    # This is a generated file!  Do not edit.\n\
                    \n\
                    .tracker.example\tTRUE\t/forum/\tTRUE\t4102444800\tbb_data\tabc123\n\
                    #HttpOnly_.tracker.example\tTRUE\t/forum/\tTRUE\t\tbb_session\ts1\n\
                    tracker.example\tFALSE\t/\tFALSE\t0\tplain\tv\n\
                    .example.com\tTRUE\t/\tFALSE\t4102444800\tother\tx\n\
                    .tracker.example\tTRUE\t/forum/\tFALSE\t1000\texpired\tgone\n\
                    .tracker.example\tTRUE\t/forum/\tFALSE\t4102444800\tempty\t\n";
        assert_eq!(
            CookieJar::from_netscape(text),
            jar(&[
                ("bb_data", "abc123"),
                ("bb_session", "s1"),
                ("empty", ""),
                ("plain", "v"),
            ])
        );
    }

    #[test]
    fn from_netscape_one_bad_line_empties_the_jar() {
        // MozillaCookieJar.load raises LoadError on any malformed line; lab.py's _load
        // then clears the jar.
        let good = ".tracker.example\tTRUE\t/forum/\tTRUE\t4102444800\tbb_data\tabc\n";
        assert_eq!(
            CookieJar::from_netscape(&format!("{good}garbage line\n")),
            CookieJar::default()
        );
        // domain_specified must agree with the leading dot (an assert in Python).
        assert_eq!(
            CookieJar::from_netscape(&format!("{good}tracker.example\tTRUE\t/\tFALSE\t0\tx\ty\n")),
            CookieJar::default()
        );
        assert_eq!(
            CookieJar::from_netscape(&format!(
                "{good}.tracker.example\tTRUE\t/\tFALSE\tsoon\tx\ty\n"
            )),
            CookieJar::default()
        );
    }

    #[test]
    fn from_netscape_empty_and_garbage() {
        assert_eq!(CookieJar::from_netscape(""), CookieJar::default());
        assert_eq!(
            CookieJar::from_netscape("garbage\nnot a cookie jar"),
            CookieJar::default()
        );
    }

    #[test]
    fn json_round_trip() {
        let j = jar(&[("bb_data", "abc")]);
        let s = serde_json::to_string(&j).unwrap();
        assert_eq!(s, r#"{"bb_data":"abc"}"#);
        assert_eq!(serde_json::from_str::<CookieJar>(&s).unwrap(), j);
    }
}
