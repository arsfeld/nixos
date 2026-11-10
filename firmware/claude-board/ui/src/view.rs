//! Pure logic behind the screens: where each arc of the rim goes, what a row says, which mood the avatar
//! is in. No Slint event loop and no clock of its own, so it is tested on the host.

use claude_board_proto::{fit, FeedEntry, FeedKind as ProtoKind, Model, Session, State};

use crate::rim::{arc_segment, arc_segment_at};
use crate::{FeedKind, RimSegment, SessionRow, SessionState};

/// At most this many arcs; further sessions share the last one.
pub const MAX_RIM_SEGMENTS: usize = 12;
const GAP_DEG: f32 = 6.0;

/// One arc of the rim, in degrees clockwise from the top.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RimSeg {
    pub start_deg: f32,
    pub end_deg: f32,
    pub state: State,
}

fn arc_count(sessions: usize) -> usize {
    sessions.min(MAX_RIM_SEGMENTS)
}

/// The arcs for `sessions`, which arrive waiting first (the model sorts them). With more than 12, the
/// first 11 get their own arc and the last stands for the rest: waiting if any of them waits, else idle.
pub fn rim_segments(sessions: &[Session]) -> Vec<RimSeg> {
    let arcs = arc_count(sessions.len());
    if arcs == 0 {
        return Vec::new();
    }
    let own = if sessions.len() > MAX_RIM_SEGMENTS { arcs - 1 } else { arcs };
    let span = 360.0 / arcs as f32;
    (0..arcs)
        .map(|i| {
            let state = if i < own {
                sessions[i].state
            } else if sessions[own..].iter().any(|s| s.state == State::Waiting) {
                State::Waiting
            } else {
                State::Idle
            };
            RimSeg { start_deg: i as f32 * span + GAP_DEG / 2.0, end_deg: (i + 1) as f32 * span - GAP_DEG / 2.0, state }
        })
        .collect()
}

/// Which arc a tap at `deg` (clockwise from the top; negative wraps) landed on.
pub fn arc_index_at(deg: f32, sessions: usize) -> Option<usize> {
    let arcs = arc_count(sessions);
    if arcs == 0 {
        return None;
    }
    let span = 360.0 / arcs as f32;
    Some(((deg.rem_euclid(360.0) / span) as usize).min(arcs - 1))
}

pub fn session_state(s: State) -> SessionState {
    match s {
        State::Working => SessionState::Working,
        State::Waiting => SessionState::Waiting,
        State::Done => SessionState::Done,
        State::Error => SessionState::Error,
        State::Idle => SessionState::Idle,
    }
}

/// `deg` (clockwise from the top, any turn) as -180 to 180.
fn signed_deg(deg: f32) -> f32 {
    let d = deg.rem_euclid(360.0);
    if d > 180.0 {
        d - 360.0
    } else {
        d
    }
}

/// The commands on the menu that a swipe down from the top edge opens, left to right on the rim.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Volume,
    Link,
    Purge,
}

/// Each command's arc, in degrees from the top (negative is left); the gaps between them are 4 degrees.
const COMMAND_ARCS: [(Command, f32, f32); 3] =
    [(Command::Volume, -64.0, -24.0), (Command::Link, -20.0, 20.0), (Command::Purge, 24.0, 64.0)];
/// Session arcs whose midpoint is this close to the top make way for the menu.
const MENU_HALF_SPAN_DEG: f32 = 64.0;
/// The command arcs sit just inside the session arcs, 50 px thick.
const COMMAND_RADIUS: f32 = 200.0;
const COMMAND_HALF_STROKE: f32 = 26.0;

/// Which command a tap at `deg` landed on while the menu is open.
pub fn command_at(deg: f32) -> Option<Command> {
    let d = signed_deg(deg);
    COMMAND_ARCS.iter().find(|(_, start, end)| (*start..=*end).contains(&d)).map(|(c, _, _)| *c)
}

/// The menu's three arcs, in `Command` order. Purge carries the error state: the screen draws it with a red edge.
pub fn command_segments() -> Vec<RimSegment> {
    COMMAND_ARCS
        .iter()
        .map(|(c, start, end)| {
            let state = if *c == Command::Purge { SessionState::Error } else { SessionState::Idle };
            arc_segment_at(*start, *end, COMMAND_RADIUS, COMMAND_HALF_STROKE, state)
        })
        .collect()
}

/// The rim as the two models the Slint ring takes: arcs that stay still, and arcs that pulse (waiting). While the
/// menu is open, the arcs at the top are left out to make room for it.
pub fn rim_models(sessions: &[Session], menu_open: bool) -> (Vec<RimSegment>, Vec<RimSegment>) {
    let (mut still, mut pulsing) = (Vec::new(), Vec::new());
    for a in rim_segments(sessions) {
        if menu_open && signed_deg((a.start_deg + a.end_deg) / 2.0).abs() <= MENU_HALF_SPAN_DEG {
            continue;
        }
        let seg = arc_segment(a.start_deg, a.end_deg, session_state(a.state));
        if a.state == State::Waiting {
            pulsing.push(seg);
        } else {
            still.push(seg);
        }
    }
    (still, pulsing)
}

/// "--" while the clock is not set, else the time since `since` in its largest unit.
pub fn fmt_ago(now: Option<i64>, since: i64) -> String {
    let Some(now) = now.filter(|n| crate::link::clock_is_set(*n)) else {
        return "--".into();
    };
    let d = now.saturating_sub(since).max(0);
    match d {
        0..=59 => format!("{d}s"),
        60..=3599 => format!("{}m", d / 60),
        3600..=86399 => format!("{}h", d / 3600),
        _ => format!("{}d", d / 86400),
    }
}

/// How many of the link page's four arcs a Wi-Fi signal of `rssi` dBm lights: at least -55, -67, -75, -85.
pub fn signal_bars(rssi: i32) -> i32 {
    [-55, -67, -75, -85].iter().filter(|&&t| rssi >= t).count() as i32
}

/// Time since boot in its two largest units: "42s", "7m", "3h 12m", "2d 4h".
pub fn fmt_uptime(secs: u64) -> String {
    match secs {
        0..=59 => format!("{secs}s"),
        60..=3599 => format!("{}m", secs / 60),
        3600..=86399 => format!("{}h {}m", secs / 3600, secs % 3600 / 60),
        _ => format!("{}d {}h", secs / 86400, secs % 86400 / 3600),
    }
}

/// The mood of the avatar for what the sessions are doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PresenceKind {
    Idle,
    Thinking,
    Alert,
}

pub fn presence_for(m: &Model) -> PresenceKind {
    if m.waiting_count() > 0 || m.current_ask().is_some() {
        PresenceKind::Alert
    } else if m.sessions().iter().any(|s| s.state == State::Working) {
        PresenceKind::Thinking
    } else {
        PresenceKind::Idle
    }
}

/// `s`, cut to at most `max_bytes` on a character boundary with "..." if anything was cut.
pub fn shorten(s: &str, max_bytes: usize) -> String {
    let n = fit(s, max_bytes);
    if n == s.len() {
        s.to_owned()
    } else {
        format!("{}...", &s[..n])
    }
}

pub fn session_rows(sessions: &[Session], now: Option<i64>) -> Vec<SessionRow> {
    sessions
        .iter()
        .map(|s| SessionRow {
            host: shorten(&s.host, 24).into(),
            initial: s.project.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default().into(),
            project: shorten(&s.project, 40).into(),
            state: session_state(s.state),
            ago: fmt_ago(now, s.since).into(),
            waiting: s.state == State::Waiting,
        })
        .collect()
}

/// One row of the watched feed, before it becomes Slint's `FeedRow`.
#[derive(Debug, Clone, PartialEq)]
pub struct FeedRowData {
    pub kind: FeedKind,
    pub text: String,
    pub failed: bool,
}

/// The rows a feed shows. A `failed` result marks the nearest preceding tool row not already marked; an `ok`
/// result and kinds this version does not know produce no row.
pub fn feed_rows(entries: &[FeedEntry]) -> Vec<FeedRowData> {
    let mut rows: Vec<FeedRowData> = Vec::new();
    for e in entries {
        let kind = match e.kind {
            ProtoKind::Prompt => FeedKind::Prompt,
            ProtoKind::Tool => FeedKind::Tool,
            ProtoKind::Reply => FeedKind::Reply,
            ProtoKind::Result => {
                if e.text == "failed" {
                    if let Some(r) = rows.iter_mut().rev().find(|r| r.kind == FeedKind::Tool && !r.failed) {
                        r.failed = true;
                    }
                }
                continue;
            }
            ProtoKind::Other => continue,
        };
        rows.push(FeedRowData { kind, text: e.text.clone(), failed: false });
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use claude_board_proto::{FeedEntry, FeedKind as K, Model, Session, State};

    fn entry(n: u64, kind: K, text: &str) -> FeedEntry {
        FeedEntry { n, ts: n as i64, kind, text: text.into() }
    }

    #[test]
    fn feed_rows_drops_ok_results() {
        let rows = feed_rows(&[entry(1, K::Tool, "Bash: ls"), entry(2, K::Result, "ok"), entry(3, K::Reply, "done")]);
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().all(|r| !r.failed));
    }

    #[test]
    fn feed_rows_marks_the_nearest_unmarked_tool_failed() {
        let t = |n, x: &str| entry(n, K::Tool, x);
        let r = |n| entry(n, K::Result, "failed");
        let rows = feed_rows(&[t(1, "a"), t(2, "b"), r(3)]);
        assert_eq!(rows.iter().map(|r| r.failed).collect::<Vec<_>>(), [false, true]);
        let rows = feed_rows(&[t(1, "a"), t(2, "b"), r(3), r(4)]);
        assert_eq!(rows.iter().map(|r| r.failed).collect::<Vec<_>>(), [true, true]);
    }

    #[test]
    fn feed_rows_ignores_unknown_kinds() {
        let rows = feed_rows(&[entry(1, K::Other, "?"), entry(2, K::Prompt, "hi")]);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].text, "hi");
    }

    fn session(n: usize, state: State, since: i64) -> Session {
        Session { host: "raider".into(), session: format!("s{n}"), project: format!("p{n}"), cwd: String::new(), state, since }
    }

    /// `waiting` waiting sessions first (as the model sorts them), then idle ones, `n` in all.
    fn sessions(n: usize, waiting: usize) -> Vec<Session> {
        (0..n).map(|i| session(i, if i < waiting { State::Waiting } else { State::Idle }, 1_800_000_000 - i as i64)).collect()
    }

    #[test]
    fn rim_zero_sessions_is_empty() {
        assert!(rim_segments(&[]).is_empty());
    }

    #[test]
    fn rim_one_session_spans_354_degrees() {
        let r = rim_segments(&sessions(1, 0));
        assert_eq!(r.len(), 1);
        assert_eq!((r[0].start_deg, r[0].end_deg), (3.0, 357.0)); // a 6 degree gap
    }

    #[test]
    fn rim_four_sessions_are_equal_arcs_with_a_6_degree_gap() {
        let r = rim_segments(&sessions(4, 0));
        assert_eq!(r.len(), 4);
        for (i, a) in r.iter().enumerate() {
            assert_eq!((a.start_deg, a.end_deg), (i as f32 * 90.0 + 3.0, (i + 1) as f32 * 90.0 - 3.0));
        }
    }

    #[test]
    fn rim_twelve_sessions_get_twelve_arcs() {
        assert_eq!(rim_segments(&sessions(12, 0)).len(), 12);
    }

    #[test]
    fn rim_caps_at_12_arcs_and_keeps_every_waiting_session() {
        let r = rim_segments(&sessions(13, 2));
        assert_eq!(r.len(), MAX_RIM_SEGMENTS);
        assert_eq!(r.iter().filter(|a| a.state == State::Waiting).count(), 2);
        assert_eq!(r[0].state, State::Waiting);
        assert_eq!(r[1].state, State::Waiting);
        assert_eq!(r[11].state, State::Idle, "the last arc stands for the hidden sessions");
    }

    #[test]
    fn rim_aggregate_arc_turns_waiting_if_a_hidden_session_waits() {
        // 20 waiting sessions: 11 get their own arc and the aggregate must still say waiting.
        let r = rim_segments(&sessions(20, 20));
        assert_eq!(r.len(), MAX_RIM_SEGMENTS);
        assert!(r.iter().all(|a| a.state == State::Waiting));
    }

    #[test]
    fn rim_with_40_sessions_stays_at_12() {
        assert_eq!(rim_segments(&sessions(40, 0)).len(), MAX_RIM_SEGMENTS);
    }

    #[test]
    fn arc_index_at_maps_an_angle_to_its_arc() {
        assert_eq!(arc_index_at(10.0, 4), Some(0));
        assert_eq!(arc_index_at(100.0, 4), Some(1));
        assert_eq!(arc_index_at(359.0, 4), Some(3));
        assert_eq!(arc_index_at(-10.0, 4), Some(3)); // negative angles wrap
        assert_eq!(arc_index_at(10.0, 0), None);
        assert_eq!(arc_index_at(10.0, 40), Some(0)); // capped rim: 12 arcs of 30 degrees
        assert_eq!(arc_index_at(340.0, 40), Some(11));
    }

    #[test]
    fn rim_models_split_waiting_arcs_into_the_pulsing_model() {
        let (still, pulsing) = rim_models(&sessions(4, 1), false);
        assert_eq!((still.len(), pulsing.len()), (3, 1));
    }

    #[test]
    fn command_at_maps_the_three_menu_arcs() {
        assert_eq!(command_at(-44.0), Some(Command::Volume));
        assert_eq!(command_at(316.0), Some(Command::Volume)); // the same angle, unnormalised
        assert_eq!(command_at(0.0), Some(Command::Link));
        assert_eq!(command_at(44.0), Some(Command::Purge));
        assert_eq!(command_at(22.0), None); // the gap between Link and Purge
        assert_eq!(command_at(-22.0), None);
        assert_eq!(command_at(90.0), None);
        assert_eq!(command_at(180.0), None);
    }

    #[test]
    fn an_open_menu_hides_the_top_session_arcs() {
        // Four arcs, midpoints at 45, 135, 225 and 315 (-45) degrees.
        let (closed, _) = rim_models(&sessions(4, 0), false);
        let (open, _) = rim_models(&sessions(4, 0), true);
        assert_eq!(closed.len(), 4);
        assert_eq!(open.len(), 2);
        // What is left are the bottom arcs: their boxes lie in the lower half.
        assert!(open.iter().all(|s| s.y >= 233.0), "{open:?}");
        // Pulsing arcs are hidden the same way.
        let (_, pulsing) = rim_models(&sessions(1, 1), true);
        assert_eq!(pulsing.len(), 1, "one arc spans the whole ring: its midpoint is at the bottom");
        let (_, pulsing) = rim_models(&sessions(4, 4), true);
        assert_eq!(pulsing.len(), 2);
    }

    #[test]
    fn command_segments_have_tight_boxes_on_the_screen() {
        let segs = command_segments();
        assert_eq!(segs.len(), 3);
        for s in &segs {
            assert!(s.x >= 0.0 && s.y >= 0.0 && s.x + s.width <= 466.0 && s.y + s.height <= 466.0, "{s:?}");
            assert!(s.width < 200.0, "{s:?}");
            assert!(s.y + s.height < 233.0, "the menu sits in the top half: {s:?}");
        }
        assert!(segs[0].x + segs[0].width / 2.0 < 233.0 && segs[2].x + segs[2].width / 2.0 > 233.0, "Volume left, Purge right");
    }

    #[test]
    fn fmt_ago_clock_unset_is_dashes() {
        assert_eq!(fmt_ago(None, 1_800_000_000), "--");
        assert_eq!(fmt_ago(Some(100), 50), "--"); // a clock that has not reached 2025 is not set
    }

    #[test]
    fn fmt_ago_units() {
        let now = 1_800_000_000;
        assert_eq!(fmt_ago(Some(now), now - 59), "59s");
        assert_eq!(fmt_ago(Some(now), now - 60), "1m");
        assert_eq!(fmt_ago(Some(now), now - 3600), "1h");
        assert_eq!(fmt_ago(Some(now), now - 86400), "1d");
        assert_eq!(fmt_ago(Some(now), now - 86399), "23h");
    }

    #[test]
    fn fmt_ago_future_since_is_zero_seconds() {
        assert_eq!(fmt_ago(Some(1_800_000_000), 1_800_000_100), "0s");
    }

    fn model_with(states: &[State]) -> Model {
        let mut m = Model::new();
        let list: Vec<String> = states
            .iter()
            .enumerate()
            .map(|(i, s)| {
                let st = format!("{s:?}").to_lowercase();
                format!(r#"{{"host":"h","session":"s{i}","project":"p","cwd":"/","state":"{st}","since":{i}}}"#)
            })
            .collect();
        m.apply(&format!(r#"{{"t":"state","sessions":[{}]}}"#, list.join(",")));
        m
    }

    #[test]
    fn presence_alert_when_any_session_waiting() {
        assert_eq!(presence_for(&model_with(&[State::Working, State::Waiting, State::Idle])), PresenceKind::Alert);
    }

    #[test]
    fn presence_thinking_when_working_and_none_waiting() {
        assert_eq!(presence_for(&model_with(&[State::Working, State::Idle])), PresenceKind::Thinking);
    }

    #[test]
    fn presence_idle_otherwise() {
        assert_eq!(presence_for(&model_with(&[State::Done, State::Idle, State::Error])), PresenceKind::Idle);
        assert_eq!(presence_for(&Model::new()), PresenceKind::Idle);
    }

    #[test]
    fn session_rows_show_time_in_state_and_the_waiting_flag() {
        let rows = session_rows(&sessions(2, 1), Some(1_800_000_090));
        assert_eq!(rows.len(), 2);
        assert!(rows[0].waiting && !rows[1].waiting);
        assert_eq!(rows[0].ago.as_str(), "1m");
        assert_eq!(rows[0].project.as_str(), "p0");
        assert_eq!(rows[0].initial.as_str(), "P");
        let unset = session_rows(&sessions(1, 0), None);
        assert_eq!(unset[0].ago.as_str(), "--");
    }

    #[test]
    fn long_names_are_cut_on_a_character_boundary() {
        let s = shorten(&"🙂".repeat(90), 40);
        assert!(s.len() <= 40 + 3 && s.ends_with("..."));
        assert!(s.is_char_boundary(s.len() - 3));
        assert_eq!(shorten("short", 40), "short");
    }

    #[test]
    fn signal_bars_follow_the_rssi_thresholds() {
        let bars: Vec<i32> = [-50, -55, -56, -67, -75, -85, -86, -100].into_iter().map(signal_bars).collect();
        assert_eq!(bars, [4, 4, 3, 3, 2, 1, 0, 0]);
    }

    #[test]
    fn fmt_uptime_shows_the_two_largest_units() {
        assert_eq!(fmt_uptime(42), "42s");
        assert_eq!(fmt_uptime(420), "7m");
        assert_eq!(fmt_uptime(11_520), "3h 12m");
        assert_eq!(fmt_uptime(187_200), "2d 4h");
    }
}
