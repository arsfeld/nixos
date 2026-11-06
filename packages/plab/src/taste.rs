//! The taste profile: what recent views say about what to suggest next. Pure: the views
//! come from Stash's play history and plab's stream log (`assistant::context`).

use std::collections::HashMap;

use serde::Serialize;

/// A view's weight halves every this many days.
pub const HALF_LIFE_DAYS: f64 = 30.0;
/// Studios, performers and tags kept, each.
pub const TOP: usize = 15;
/// Recent views written into the prompt.
pub const RECENT_LINES: usize = 20;

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Named {
    pub name: String,
    /// Stash's id, when the view came from Stash.
    pub id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct View {
    pub at: i64,
    pub title: String,
    pub studio: Option<Named>,
    pub performers: Vec<Named>,
    pub tags: Vec<String>,
    pub o_count: u32,
    /// Stash's rating100.
    pub rating: Option<u32>,
    /// From plab's stream log rather than Stash.
    pub streamed: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Weighted {
    pub name: String,
    #[serde(skip)]
    pub id: Option<String>,
    pub weight: f64,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize)]
pub struct Profile {
    pub studios: Vec<Weighted>,
    pub performers: Vec<Weighted>,
    pub tags: Vec<Weighted>,
    pub recent: Vec<String>,
}

/// Decay by age, boosted by o-count (×1.5 each) and rating (rating100 / 60; unrated ×1).
pub fn weight(v: &View, now: i64) -> f64 {
    let age_days = (now - v.at).max(0) as f64 / 86400.0;
    let decay = 0.5f64.powf(age_days / HALF_LIFE_DAYS);
    let o = 1.0 + 0.5 * f64::from(v.o_count);
    let r = v.rating.map_or(1.0, |r| f64::from(r) / 60.0);
    decay * o * r
}

fn add(map: &mut HashMap<String, Weighted>, name: &str, id: Option<&str>, w: f64) {
    let e = map.entry(name.to_lowercase()).or_insert_with(|| Weighted {
        name: name.to_string(),
        id: None,
        weight: 0.0,
    });
    e.weight += w;
    if e.id.is_none() {
        e.id = id.map(str::to_owned);
    }
}

fn top(map: HashMap<String, Weighted>) -> Vec<Weighted> {
    let mut v: Vec<Weighted> = map.into_values().collect();
    v.sort_by(|a, b| {
        b.weight
            .total_cmp(&a.weight)
            .then_with(|| a.name.cmp(&b.name))
    });
    v.truncate(TOP);
    v
}

/// `ts` as a UTC `YYYY-MM-DD`; empty when out of range.
pub fn ymd(ts: i64) -> String {
    chrono::DateTime::from_timestamp(ts, 0)
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_default()
}

fn line(v: &View) -> String {
    let mut parts = vec![ymd(v.at), v.title.clone()];
    if let Some(s) = &v.studio {
        parts.push(s.name.clone());
    }
    if !v.performers.is_empty() {
        let names: Vec<&str> = v.performers.iter().map(|p| p.name.as_str()).collect();
        parts.push(names.join(", "));
    }
    if v.streamed {
        parts.push("streamed".into());
    }
    parts.join(" · ")
}

/// The `n` newest views as one line each.
pub fn recent(views: &[View], n: usize) -> Vec<String> {
    let mut sorted: Vec<&View> = views.iter().collect();
    sorted.sort_by_key(|v| std::cmp::Reverse(v.at));
    sorted.into_iter().take(n).map(line).collect()
}

pub fn profile(views: &[View], now: i64) -> Profile {
    let (mut studios, mut performers, mut tags) = (HashMap::new(), HashMap::new(), HashMap::new());
    for v in views {
        let w = weight(v, now);
        if let Some(s) = &v.studio {
            add(&mut studios, &s.name, s.id.as_deref(), w);
        }
        for p in &v.performers {
            add(&mut performers, &p.name, p.id.as_deref(), w);
        }
        for t in &v.tags {
            add(&mut tags, t, None, w);
        }
    }
    Profile {
        studios: top(studios),
        performers: top(performers),
        tags: top(tags),
        recent: recent(views, RECENT_LINES),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DAY: i64 = 86400;

    fn named(n: &str) -> Named {
        Named {
            name: n.into(),
            id: Some(format!("id-{n}")),
        }
    }

    fn view(at: i64, studio: &str, performers: &[&str]) -> View {
        View {
            at,
            title: format!("Scene at {at}"),
            studio: Some(named(studio)),
            performers: performers.iter().map(|p| named(p)).collect(),
            ..View::default()
        }
    }

    #[test]
    fn weight_halves_every_thirty_days() {
        let now = 100 * DAY;
        let fresh = weight(&view(now, "A", &[]), now);
        let old = weight(&view(now - 30 * DAY, "A", &[]), now);
        assert!((fresh - 1.0).abs() < 1e-9);
        assert!((old - 0.5).abs() < 1e-9);
    }

    #[test]
    fn o_count_and_rating_boost() {
        let now = 0;
        let mut v = view(0, "A", &[]);
        v.o_count = 2;
        assert!((weight(&v, now) - 2.0).abs() < 1e-9);
        v.rating = Some(90);
        assert!((weight(&v, now) - 3.0).abs() < 1e-9);
    }

    #[test]
    fn profile_merges_case_insensitively_and_sorts() {
        let now = 0;
        let views = vec![
            view(0, "Studio A", &["Performer B"]),
            view(0, "studio a", &["Performer C"]),
            view(0, "Studio D", &["Performer B"]),
        ];
        let p = profile(&views, now);
        assert_eq!(p.studios[0].name, "Studio A");
        assert!((p.studios[0].weight - 2.0).abs() < 1e-9);
        assert_eq!(p.studios[0].id.as_deref(), Some("id-Studio A"));
        assert_eq!(p.performers[0].name, "Performer B");
        assert_eq!(p.performers.len(), 2);
    }

    #[test]
    fn profile_caps_each_list() {
        let views: Vec<View> = (0..20).map(|i| view(0, &format!("S{i}"), &[])).collect();
        assert_eq!(profile(&views, 0).studios.len(), TOP);
    }

    #[test]
    fn recent_lines_newest_first_and_mark_streams() {
        let mut a = view(DAY, "Studio A", &["Performer B", "Performer C"]);
        a.title = "Alpha".into();
        let b = View {
            at: 2 * DAY,
            title: "Beta".into(),
            streamed: true,
            ..View::default()
        };
        let lines = recent(&[a, b], 10);
        assert_eq!(lines[0], "1970-01-03 · Beta · streamed");
        assert_eq!(
            lines[1],
            "1970-01-02 · Alpha · Studio A · Performer B, Performer C"
        );
        assert_eq!(profile(&[], 0).recent.len(), 0);
    }
}
