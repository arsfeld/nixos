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
/// Avoided studios, performers and tags kept, each.
pub const AVOID_TOP: usize = 10;
/// Seconds of a scene watched (Stash's `play_duration`) that make a play a view.
pub const WATCHED_SECS: u32 = 120;
/// Under this many seconds, with no o-count and no rating, a play is a sample: tried and
/// abandoned.
pub const SAMPLED_SECS: u32 = 30;
/// A vote's weight, before decay: +1 adds it, −1 takes it away.
pub const VOTE: f64 = 2.0;
/// A sample's weight, before decay: a quarter of a −1.
pub const SAMPLE: f64 = -0.5;

/// What a Stash play says (design: 2026-11-26-plab-taste-feedback-design.md). Stash counts
/// a play the moment a scene starts, so only time watched tells a view from a sample.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Play {
    Watched,
    Sampled,
    Neither,
}

/// An o-count or a rating is a view however short the play; no duration from Stash counts
/// as a view too, as every play did before durations were read.
pub fn play(watched_secs: Option<u32>, o_count: u32, rating: Option<u32>) -> Play {
    match watched_secs {
        _ if o_count > 0 || rating.is_some() => Play::Watched,
        None => Play::Watched,
        Some(s) if s >= WATCHED_SECS => Play::Watched,
        Some(s) if s < SAMPLED_SECS => Play::Sampled,
        Some(_) => Play::Neither,
    }
}

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
    /// Stash's `play_duration`, in whole seconds; None for streams and when Stash has none.
    pub watched_secs: Option<u32>,
    /// The user's vote and when it was cast.
    pub vote: Option<(i8, i64)>,
    /// Here only because of its vote (not played within the lookback): `at` is the vote's
    /// time and the play counts for nothing.
    pub vote_only: bool,
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
    /// Terms whose net weight is negative: voted down or sampled and abandoned.
    pub avoid: Avoid,
    pub recent: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Default, Serialize)]
pub struct Avoid {
    pub studios: Vec<Weighted>,
    pub performers: Vec<Weighted>,
    pub tags: Vec<Weighted>,
}

fn decay(at: i64, now: i64) -> f64 {
    let age_days = (now - at).max(0) as f64 / 86400.0;
    0.5f64.powf(age_days / HALF_LIFE_DAYS)
}

/// The play, then the vote, each decayed from its own time. A view decays by age, boosted
/// by o-count (×1.5 each) and rating (rating100 / 60; unrated ×1); a sample is `SAMPLE`; a
/// vote is ±`VOTE`. The sum can be negative.
pub fn weight(v: &View, now: i64) -> f64 {
    let watched = || {
        let o = 1.0 + 0.5 * f64::from(v.o_count);
        let r = v.rating.map_or(1.0, |r| f64::from(r) / 60.0);
        decay(v.at, now) * o * r
    };
    let played = if v.vote_only {
        0.0
    } else if v.streamed {
        watched()
    } else {
        match play(v.watched_secs, v.o_count, v.rating) {
            Play::Watched => watched(),
            Play::Sampled => SAMPLE * decay(v.at, now),
            Play::Neither => 0.0,
        }
    };
    let voted = v
        .vote
        .map_or(0.0, |(vote, at)| f64::from(vote) * VOTE * decay(at, now));
    played + voted
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

/// The positive terms, heaviest first, and the negative ones, most negative first.
fn split(map: HashMap<String, Weighted>) -> (Vec<Weighted>, Vec<Weighted>) {
    let (mut pos, mut neg): (Vec<Weighted>, Vec<Weighted>) = map
        .into_values()
        .filter(|w| w.weight != 0.0)
        .partition(|w| w.weight > 0.0);
    pos.sort_by(|a, b| {
        b.weight
            .total_cmp(&a.weight)
            .then_with(|| a.name.cmp(&b.name))
    });
    neg.sort_by(|a, b| {
        a.weight
            .total_cmp(&b.weight)
            .then_with(|| a.name.cmp(&b.name))
    });
    pos.truncate(TOP);
    neg.truncate(AVOID_TOP);
    (pos, neg)
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
    if let Some(secs) = v
        .watched_secs
        .filter(|&s| !v.vote_only && s >= WATCHED_SECS)
    {
        parts.push(format!("watched {} min", secs / 60));
    }
    match v.vote {
        Some((1, _)) => parts.push("+1".into()),
        Some((-1, _)) => parts.push("-1".into()),
        _ => {}
    }
    if v.streamed {
        parts.push("streamed".into());
    }
    parts.join(" · ")
}

/// Whether a view earns a line: watched, voted or streamed. Samples act through weights only.
fn shown(v: &View) -> bool {
    v.streamed
        || v.vote.is_some()
        || (!v.vote_only && play(v.watched_secs, v.o_count, v.rating) == Play::Watched)
}

/// The `n` newest views that were watched, voted or streamed, as one line each.
pub fn recent(views: &[View], n: usize) -> Vec<String> {
    let mut sorted: Vec<&View> = views.iter().filter(|v| shown(v)).collect();
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
    let (studios, avoid_studios) = split(studios);
    let (performers, avoid_performers) = split(performers);
    let (tags, avoid_tags) = split(tags);
    Profile {
        studios,
        performers,
        tags,
        avoid: Avoid {
            studios: avoid_studios,
            performers: avoid_performers,
            tags: avoid_tags,
        },
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

    fn at_now(secs: Option<u32>) -> View {
        View {
            watched_secs: secs,
            ..view(0, "A", &[])
        }
    }

    #[test]
    fn constants() {
        assert_eq!((WATCHED_SECS, SAMPLED_SECS, AVOID_TOP), (120, 30, 10));
        assert_eq!((VOTE, SAMPLE), (2.0, -0.5));
    }

    #[test]
    fn play_classifies() {
        assert_eq!(play(Some(120), 0, None), Play::Watched);
        assert_eq!(play(Some(10), 1, None), Play::Watched);
        assert_eq!(play(Some(10), 0, Some(80)), Play::Watched);
        assert_eq!(play(None, 0, None), Play::Watched);
        assert_eq!(play(Some(29), 0, None), Play::Sampled);
        assert_eq!(play(Some(30), 0, None), Play::Neither);
        assert_eq!(play(Some(119), 0, None), Play::Neither);
    }

    #[test]
    fn sampled_weighs_minus_half_and_dead_zone_zero() {
        assert!((weight(&at_now(Some(5)), 0) + 0.5).abs() < 1e-9);
        assert!(weight(&at_now(Some(60)), 0).abs() < 1e-9);
    }

    #[test]
    fn vote_adds_two_decayed_from_its_own_time() {
        let now = 100 * DAY;
        let mut v = view(now, "A", &[]);
        v.watched_secs = Some(600);
        v.o_count = 1;
        v.vote = Some((1, now));
        assert!((weight(&v, now) - 3.5).abs() < 1e-9);
        let only = View {
            vote: Some((-1, now - 30 * DAY)),
            vote_only: true,
            ..view(now - 30 * DAY, "A", &[])
        };
        assert!((weight(&only, now) + 1.0).abs() < 1e-9);
    }

    #[test]
    fn net_negative_terms_go_to_avoid_only() {
        let watched = view(0, "Studio A", &[]);
        let voted = View {
            vote: Some((-1, 0)),
            vote_only: true,
            ..view(0, "Studio A", &[])
        };
        let p = profile(&[watched, voted, view(0, "Studio B", &[])], 0);
        let names = |ws: &[Weighted]| ws.iter().map(|w| w.name.clone()).collect::<Vec<_>>();
        assert_eq!(names(&p.studios), ["Studio B"]);
        assert_eq!(names(&p.avoid.studios), ["Studio A"]);
        assert!((p.avoid.studios[0].weight + 1.0).abs() < 1e-9);
    }

    #[test]
    fn avoid_is_most_negative_first_and_capped() {
        let views: Vec<View> = (0..12)
            .flat_map(|i| {
                (0..=i).map(move |_| View {
                    watched_secs: Some(5),
                    ..view(0, &format!("S{i}"), &[])
                })
            })
            .collect();
        let p = profile(&views, 0);
        assert_eq!(p.avoid.studios.len(), AVOID_TOP);
        assert_eq!(p.avoid.studios[0].name, "S11");
        assert!(p.studios.is_empty());
    }

    #[test]
    fn recent_lines_mark_watch_time_and_votes_and_skip_samples() {
        let liked = View {
            title: "Liked".into(),
            watched_secs: Some(400),
            vote: Some((1, 3 * DAY)),
            ..view(3 * DAY, "Studio A", &[])
        };
        let disliked = View {
            title: "Disliked".into(),
            vote: Some((-1, 2 * DAY)),
            vote_only: true,
            ..view(2 * DAY, "Studio B", &[])
        };
        let sampled = View {
            title: "Sampled".into(),
            watched_secs: Some(5),
            ..view(4 * DAY, "Studio C", &[])
        };
        assert_eq!(
            recent(&[liked, disliked, sampled], 10),
            [
                "1970-01-04 · Liked · Studio A · watched 6 min · +1",
                "1970-01-03 · Disliked · Studio B · -1",
            ]
        );
    }
}
