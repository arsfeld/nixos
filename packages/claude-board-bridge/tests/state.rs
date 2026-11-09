use claude_board_bridge::protocol::{Event, EventKind, Session, State};
use claude_board_bridge::state::{Change, Registry};

fn ev(host: &str, session: &str, cwd: &str, event: EventKind, ts: i64) -> Event {
    Event {
        host: host.into(),
        session: session.into(),
        cwd: cwd.into(),
        event,
        ts,
    }
}

fn note(kind: &str) -> EventKind {
    EventKind::Notification { kind: kind.into() }
}

fn upserted(c: Option<Change>) -> Session {
    match c {
        Some(Change::Upsert(s)) => s,
        other => panic!("expected Upsert, got {other:?}"),
    }
}

const CWD: &str = "/home/arosenfeld/Code/nixos";

#[test]
fn session_start_creates_idle() {
    let mut r = Registry::new(21600);
    let s = upserted(r.apply(&ev("raider", "s1", CWD, EventKind::SessionStart, 100)));
    assert_eq!(s.state, State::Idle);
    assert_eq!(s.since, 100);
    assert_eq!(s.project, "nixos");
    assert_eq!(s.host, "raider");
    assert_eq!(s.session, "s1");
}

#[test]
fn prompt_submit_sets_working() {
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "s1", CWD, EventKind::SessionStart, 100));
    let s = upserted(r.apply(&ev("raider", "s1", CWD, EventKind::UserPromptSubmit, 110)));
    assert_eq!(s.state, State::Working);
    assert_eq!(s.since, 110);
}

#[test]
fn permission_notification_sets_waiting() {
    let mut r = Registry::new(21600);
    let s = upserted(r.apply(&ev("raider", "s1", CWD, note("permission_prompt"), 100)));
    assert_eq!(s.state, State::Waiting);
}

#[test]
fn idle_notification_sets_idle() {
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "s1", CWD, EventKind::Stop, 100));
    let s = upserted(r.apply(&ev("raider", "s1", CWD, note("idle_prompt"), 160)));
    assert_eq!(s.state, State::Idle);
    assert_eq!(s.since, 160);
}

#[test]
fn stop_sets_done() {
    let mut r = Registry::new(21600);
    let s = upserted(r.apply(&ev("raider", "s1", CWD, EventKind::Stop, 100)));
    assert_eq!(s.state, State::Done);
}

#[test]
fn stop_failure_sets_error() {
    let mut r = Registry::new(21600);
    let s = upserted(r.apply(&ev("raider", "s1", CWD, EventKind::StopFailure, 100)));
    assert_eq!(s.state, State::Error);
}

#[test]
fn session_end_removes() {
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "s1", CWD, EventKind::SessionStart, 100));
    let c = r.apply(&ev("raider", "s1", CWD, EventKind::SessionEnd, 200));
    assert_eq!(
        c,
        Some(Change::Remove {
            host: "raider".into(),
            session: "s1".into()
        })
    );
    assert!(r.snapshot().is_empty());
}

#[test]
fn session_end_for_unknown_session_changes_nothing() {
    let mut r = Registry::new(21600);
    assert_eq!(r.apply(&ev("raider", "nope", CWD, EventKind::SessionEnd, 1)), None);
}

#[test]
fn unknown_notification_kind_changes_nothing() {
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "s1", CWD, EventKind::UserPromptSubmit, 100));
    assert_eq!(r.apply(&ev("raider", "s1", CWD, note("auth_success"), 120)), None);
    assert_eq!(r.snapshot()[0].state, State::Working);
}

#[test]
fn state_change_updates_since_only_when_state_changes() {
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "s1", CWD, EventKind::UserPromptSubmit, 100));
    assert_eq!(r.apply(&ev("raider", "s1", CWD, EventKind::UserPromptSubmit, 200)), None);
    assert_eq!(r.snapshot()[0].since, 100);
}

#[test]
fn revived_session_is_not_duplicated() {
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "s1", CWD, EventKind::SessionStart, 100));
    r.apply(&ev("raider", "s1", CWD, EventKind::SessionEnd, 150));
    r.apply(&ev("raider", "s1", CWD, EventKind::SessionStart, 200));
    let snap = r.snapshot();
    assert_eq!(snap.len(), 1);
    assert_eq!(snap[0].state, State::Idle);
    assert_eq!(snap[0].since, 200);
}

#[test]
fn event_for_unseen_session_creates_a_card() {
    let mut r = Registry::new(21600);
    r.apply(&ev("galactica", "late", CWD, EventKind::UserPromptSubmit, 100));
    assert_eq!(r.snapshot().len(), 1);
}

#[test]
fn same_session_id_on_two_hosts_is_two_cards() {
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "s1", CWD, EventKind::SessionStart, 100));
    r.apply(&ev("basestar", "s1", CWD, EventKind::SessionStart, 100));
    assert_eq!(r.snapshot().len(), 2);
}

#[test]
fn snapshot_sorts_waiting_first_then_newest() {
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "a", CWD, EventKind::UserPromptSubmit, 100));
    r.apply(&ev("raider", "b", CWD, note("permission_prompt"), 50));
    r.apply(&ev("raider", "c", CWD, EventKind::SessionStart, 300));
    let order: Vec<_> = r.snapshot().into_iter().map(|s| s.session).collect();
    assert_eq!(order, vec!["b", "c", "a"]);
}

#[test]
fn set_waiting_marks_the_session_waiting() {
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "s1", CWD, EventKind::UserPromptSubmit, 100));
    let s = upserted(r.set_waiting("raider", "s1", CWD, 120));
    assert_eq!(s.state, State::Waiting);
    assert_eq!(s.since, 120);
}

#[test]
fn expire_removes_cards_without_events_for_expire_secs() {
    let mut r = Registry::new(10);
    r.apply(&ev("raider", "s1", CWD, EventKind::SessionStart, 100));
    assert!(r.expire(105).is_empty());
    let gone = r.expire(111);
    assert_eq!(
        gone,
        vec![Change::Remove {
            host: "raider".into(),
            session: "s1".into()
        }]
    );
    assert!(r.snapshot().is_empty());
}

#[test]
fn a_repeated_event_keeps_the_card_alive() {
    let mut r = Registry::new(10);
    r.apply(&ev("raider", "s1", CWD, EventKind::UserPromptSubmit, 100));
    r.apply(&ev("raider", "s1", CWD, EventKind::UserPromptSubmit, 200));
    assert!(r.expire(205).is_empty());
    assert_eq!(r.expire(211).len(), 1);
}

#[test]
fn project_is_last_path_component() {
    let mut r = Registry::new(21600);
    let s = upserted(r.apply(&ev("raider", "a", "/home/x/proj/", EventKind::SessionStart, 1)));
    assert_eq!(s.project, "proj");
    let s = upserted(r.apply(&ev("raider", "b", "", EventKind::SessionStart, 1)));
    assert_eq!(s.project, "unknown");
}

#[test]
fn event_without_cwd_keeps_known_cwd() {
    // Real StopFailure payloads carry no cwd (see the hook findings doc).
    let mut r = Registry::new(21600);
    r.apply(&ev("raider", "s1", "/a/b", EventKind::SessionStart, 100));
    let s = upserted(r.apply(&ev("raider", "s1", "", EventKind::StopFailure, 110)));
    assert_eq!(s.cwd, "/a/b");
    assert_eq!(s.project, "b");
}

#[test]
fn event_json_matches_the_hook_contract() {
    let e: Event = serde_json::from_str(
        r#"{"host":"raider","session":"s","cwd":"/a","event":"notification","kind":"idle_prompt","ts":5}"#,
    )
    .unwrap();
    assert_eq!(e.event, EventKind::Notification { kind: "idle_prompt".into() });
    let e: Event =
        serde_json::from_str(r#"{"host":"h","session":"s","event":"session_start","ts":1}"#).unwrap();
    assert_eq!(e.event, EventKind::SessionStart);
    assert_eq!(e.cwd, "");
    let e: Event =
        serde_json::from_str(r#"{"host":"h","session":"s","event":"stop_failure","ts":1}"#).unwrap();
    assert_eq!(e.event, EventKind::StopFailure);
}

#[test]
fn session_json_uses_lowercase_state() {
    let mut r = Registry::new(21600);
    let s = upserted(r.apply(&ev("raider", "s1", CWD, note("permission_prompt"), 100)));
    let v = serde_json::to_value(&s).unwrap();
    assert_eq!(v["state"], "waiting");
    assert_eq!(v["project"], "nixos");
}
