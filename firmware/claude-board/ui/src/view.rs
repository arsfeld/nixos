//! Pure logic behind the screens: where each arc of the rim goes, what a row says, which mood the avatar
//! is in. No Slint event loop and no clock of its own, so it is tested on the host.

use claude_board_proto::{fit, Model, Session, State};

use crate::rim::arc_segment;
use crate::{RimSegment, SessionRow, SessionState};

/// At most this many arcs; further sessions share the last one.
pub const MAX_RIM_SEGMENTS: usize = 12;
const GAP_DEG: f32 = 6.0;
/// A clock before this (2025-01-01) has not been set by NTP yet.
const CLOCK_FLOOR: i64 = 1_735_689_600;

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

/// The rim as the two models the Slint ring takes: arcs that stay still, and arcs that pulse (waiting).
pub fn rim_models(sessions: &[Session]) -> (Vec<RimSegment>, Vec<RimSegment>) {
    let (mut still, mut pulsing) = (Vec::new(), Vec::new());
    for a in rim_segments(sessions) {
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
    let Some(now) = now.filter(|n| *n >= CLOCK_FLOOR) else {
        return "--".into();
    };
    let d = (now - since).max(0);
    match d {
        0..=59 => format!("{d}s"),
        60..=3599 => format!("{}m", d / 60),
        3600..=86399 => format!("{}h", d / 3600),
        _ => format!("{}d", d / 86400),
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
            project: shorten(&s.project, 40).into(),
            state: session_state(s.state),
            ago: fmt_ago(now, s.since).into(),
            waiting: s.state == State::Waiting,
        })
        .collect()
}


#[cfg(test)]
mod tests {
    use super::*;
    use claude_board_proto::{Model, Session, State};

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
        let (still, pulsing) = rim_models(&sessions(4, 1));
        assert_eq!((still.len(), pulsing.len()), (3, 1));
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
}
