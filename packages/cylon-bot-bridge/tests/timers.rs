use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicI64, Ordering};

use cylon_bot_bridge::mcp::timers::tools;
use cylon_bot_bridge::mcp::ToolOutcome;
use cylon_bot_bridge::timers::*;
use serde_json::json;

fn ts(s: &str) -> i64 {
    s.parse::<jiff::Timestamp>().unwrap().as_second()
}

fn clock(at: &str) -> (Arc<AtomicI64>, Clock) {
    let t = Arc::new(AtomicI64::new(ts(at)));
    let c = t.clone();
    (t, Arc::new(move || c.load(Ordering::SeqCst)))
}

fn mem(at: &str) -> (Arc<AtomicI64>, Timers) {
    let (t, c) = clock(at);
    (t, Timers::open(None, c))
}

const NOW: &str = "2026-11-10T09:00:00-05:00";

fn dir() -> (PathBuf, PathBuf) {
    let mut b = [0u8; 6];
    getrandom::fill(&mut b).unwrap();
    let d = std::env::temp_dir().join(format!("timers-test-{}", b.iter().map(|x| format!("{x:02x}")).collect::<String>()));
    std::fs::create_dir_all(&d).unwrap();
    let f = d.join("timers.json");
    (d, f)
}

#[test]
fn set_in_seconds_reads_back_local_time() {
    let (_, t) = mem(NOW);
    let r = t.set("tea", When::In(600)).unwrap();
    assert_eq!(r.due, ts(NOW) + 600);
    assert!(r.id.starts_with("tmr_") && r.id.len() == 10);
    assert_eq!(when_words(r.due, ts(NOW)), "09:10 today");
}

#[test]
fn set_at_today_and_tomorrow_words() {
    let (_, t) = mem(NOW);
    let a = t.set("a", When::At("2026-11-10T18:42".into())).unwrap();
    assert_eq!(a.due, ts("2026-11-10T18:42:00-05:00"));
    assert_eq!(when_words(a.due, ts(NOW)), "18:42 today");
    let b = t.set("b", When::At("2026-11-11T09:00:00".into())).unwrap();
    assert_eq!(when_words(b.due, ts(NOW)), "09:00 tomorrow");
    let c = t.set("c", When::At("2026-11-13T09:00".into())).unwrap();
    assert_eq!(when_words(c.due, ts(NOW)), "09:00 on Friday 13 November");
}

#[test]
fn at_in_the_past_is_refused() {
    let (_, t) = mem(NOW);
    assert!(matches!(t.set("x", When::At("2026-11-10T08:59".into())), Err(TimerError::BadTime(_))));
    assert!(matches!(t.set("x", When::At("garbage".into())), Err(TimerError::BadTime(_))));
    assert!(matches!(t.set("x", When::In(0)), Err(TimerError::BadTime(_))));
}

#[test]
fn more_than_30_days_ahead_is_refused() {
    let (_, t) = mem(NOW);
    assert!(matches!(t.set("x", When::In(MAX_AHEAD_SECS as u64 + 1)), Err(TimerError::BadTime(_))));
    assert!(t.set("x", When::In(MAX_AHEAD_SECS as u64)).is_ok());
    assert!(matches!(t.set("x", When::At("2026-12-11T09:00".into())), Err(TimerError::BadTime(_))));
}

#[test]
fn both_or_neither_time_is_refused() {
    let (_, t) = mem(NOW);
    let tool = tools(Arc::new(t));
    let set = tool.iter().find(|x| x.def().name == "set_timer").unwrap();
    let r = futures_util::FutureExt::now_or_never(set.call(json!({"label":"x"}))).unwrap();
    assert!(matches!(r, ToolOutcome::Error(_)));
    let r = futures_util::FutureExt::now_or_never(set.call(json!({"label":"x","in_seconds":5,"at":"2026-11-10T10:00"}))).unwrap();
    assert!(matches!(r, ToolOutcome::Error(_)));
}

#[test]
fn spring_gap_time_is_refused() {
    let (_, t) = mem("2026-03-01T09:00:00-05:00");
    match t.set("x", When::At("2026-03-08T02:30".into())) {
        Err(TimerError::BadTime(m)) => assert!(m.contains("02:30"), "{m}"),
        o => panic!("{o:?}"),
    }
}

#[test]
fn fall_overlap_takes_earlier_instant() {
    let (_, t) = mem("2026-10-25T09:00:00-04:00");
    let r = t.set("x", When::At("2026-11-01T01:30".into())).unwrap();
    assert_eq!(r.due, ts("2026-11-01T01:30:00-04:00"));
}

#[test]
fn twenty_first_timer_is_refused() {
    let (_, t) = mem(NOW);
    for i in 0..MAX_TIMERS {
        t.set(&format!("t{i}"), When::In(60)).unwrap();
    }
    assert!(matches!(t.set("one more", When::In(60)), Err(TimerError::Full)));
}

#[test]
fn empty_and_201_byte_labels_are_refused() {
    let (_, t) = mem(NOW);
    assert!(matches!(t.set("", When::In(60)), Err(TimerError::BadLabel)));
    assert!(matches!(t.set("   ", When::In(60)), Err(TimerError::BadLabel)));
    assert!(matches!(t.set(&"a".repeat(201), When::In(60)), Err(TimerError::BadLabel)));
    assert!(t.set(&"a".repeat(200), When::In(60)).is_ok());
}

#[test]
fn cancel_by_id_and_by_unique_label() {
    let (_, t) = mem(NOW);
    let a = t.set("Tea", When::In(60)).unwrap();
    let b = t.set("Laundry", When::In(120)).unwrap();
    assert_eq!(t.cancel(&a.id).unwrap(), a);
    assert_eq!(t.cancel("laundry").unwrap(), b);
    assert!(matches!(t.cancel("laundry"), Err(TimerError::NotFound)));
    assert!(t.list().is_empty());
}

#[test]
fn ambiguous_label_cancel_lists_candidates() {
    let (_, t) = mem(NOW);
    t.set("Tea", When::In(60)).unwrap();
    t.set("tea", When::In(120)).unwrap();
    match t.cancel("TEA") {
        Err(e @ TimerError::Ambiguous(_)) => {
            let TimerError::Ambiguous(c) = &e else { unreachable!() };
            assert_eq!(c.len(), 2);
            assert!(e.to_string().contains("Tea"));
        }
        o => panic!("{o:?}"),
    }
    assert_eq!(t.list().len(), 2);
}

#[test]
fn persists_across_reopen() {
    let (d, f) = dir();
    let (_, c) = clock(NOW);
    let t = Timers::open(Some(f.clone()), c.clone());
    let a = t.set("a", When::In(600)).unwrap();
    let b = t.set("b", When::In(60)).unwrap();
    drop(t);
    let t2 = Timers::open(Some(f.clone()), c);
    assert_eq!(t2.list(), vec![b, a]);
    assert!(!d.join("timers.json.tmp").exists());
    let raw: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&f).unwrap()).unwrap();
    assert_eq!(raw["version"], 1);
}

#[test]
fn corrupt_file_is_moved_aside_and_store_starts_empty() {
    let (d, f) = dir();
    std::fs::write(&f, "{not json").unwrap();
    let (_, c) = clock(NOW);
    let t = Timers::open(Some(f.clone()), c);
    assert!(t.list().is_empty());
    assert!(d.join("timers.json.bad").exists());
    assert!(!f.exists());
}

#[test]
fn claim_due_returns_and_removes_due_timers_once() {
    let (now, t) = mem(NOW);
    let a = t.set("a", When::In(60)).unwrap();
    t.set("b", When::In(600)).unwrap();
    assert_eq!(t.next_due(), Some(a.due));
    assert!(t.claim_due().is_empty());
    now.store(a.due + 5, Ordering::SeqCst);
    let got = t.claim_due();
    assert_eq!(got.len(), 1);
    assert_eq!(got[0].timer, a);
    assert_eq!(got[0].late_secs, 5);
    assert!(t.claim_due().is_empty());
    assert_eq!(t.list().len(), 1);
}

#[test]
fn claim_past_grace_discards() {
    let (now, t) = mem(NOW);
    let a = t.set("a", When::In(60)).unwrap();
    now.store(a.due + REMINDER_GRACE_SECS + 1, Ordering::SeqCst);
    assert!(t.claim_due().is_empty());
    assert!(t.list().is_empty());
}

#[test]
fn subscribe_is_bumped_on_change() {
    let (_, t) = mem(NOW);
    let rx = t.subscribe();
    t.set("a", When::In(60)).unwrap();
    assert!(rx.has_changed().unwrap());
}

#[test]
fn spoken_text_on_time_and_late() {
    let timer = Timer { id: "tmr_000001".into(), label: "Tea".into(), due: ts("2026-11-10T18:42:00-05:00") };
    assert_eq!(spoken_reminder(&Due { timer: timer.clone(), late_secs: 59 }), "Reminder. Tea.");
    assert_eq!(spoken_reminder(&Due { timer, late_secs: 60 }), "This was due at 18:42. Tea.");
}

#[test]
fn rfc3339_local_has_offset() {
    assert_eq!(rfc3339_local(ts("2026-11-10T18:42:00-05:00")), "2026-11-10T18:42:00-05:00");
    assert_eq!(rfc3339_local(ts("2026-07-10T18:42:00-04:00")), "2026-07-10T18:42:00-04:00");
}

#[tokio::test]
async fn tool_set_timer_text() {
    let (_, t) = mem(NOW);
    let tl = tools(Arc::new(t));
    let set = tl.iter().find(|x| x.def().name == "set_timer").unwrap();
    match set.call(json!({"label":"Tea","in_seconds":600})).await {
        ToolOutcome::Text(s) => assert_eq!(s, "Timer set: Tea, fires at 09:10 today."),
        _ => panic!(),
    }
    let list = tl.iter().find(|x| x.def().name == "list_timers").unwrap();
    match list.call(json!({})).await {
        ToolOutcome::Text(s) => {
            assert!(s.ends_with("Tea: 09:10 today, in 10 minutes"), "{s}");
            assert!(s.starts_with("tmr_"));
        }
        _ => panic!(),
    }
    let cancel = tl.iter().find(|x| x.def().name == "cancel_timer").unwrap();
    assert!(matches!(cancel.call(json!({"id_or_label":"tea"})).await, ToolOutcome::Text(_)));
    assert!(matches!(cancel.call(json!({"id_or_label":"tea"})).await, ToolOutcome::Error(_)));
}

#[tokio::test]
async fn tool_list_timers_empty() {
    let (_, t) = mem(NOW);
    let tl = tools(Arc::new(t));
    let list = tl.iter().find(|x| x.def().name == "list_timers").unwrap();
    match list.call(json!({})).await {
        ToolOutcome::Text(s) => assert_eq!(s, "No timers."),
        _ => panic!(),
    }
}

#[test]
fn drop_expired_removes_only_timers_past_grace() {
    let (now, t) = mem(NOW);
    let old = t.set("old", When::In(60)).unwrap();
    let recent = t.set("recent", When::In(600)).unwrap();
    let future = t.set("future", When::In(3 * 3600)).unwrap();
    // `old` is past the grace, `recent` is due but within it, `future` is not due.
    now.store(old.due + REMINDER_GRACE_SECS + 1, Ordering::SeqCst);
    assert!(recent.due + REMINDER_GRACE_SECS >= t.now());
    assert_eq!(t.drop_expired(), 1);
    let ids: Vec<String> = t.list().into_iter().map(|x| x.id).collect();
    assert_eq!(ids, [recent.id, future.id]);
    assert_eq!(t.drop_expired(), 0);
}

#[test]
fn drop_expired_is_persisted() {
    let (d, f) = dir();
    let (now, c) = clock(NOW);
    let t = Timers::open(Some(f.clone()), c.clone());
    let old = t.set("old", When::In(60)).unwrap();
    now.store(old.due + REMINDER_GRACE_SECS + 1, Ordering::SeqCst);
    assert_eq!(t.drop_expired(), 1);
    assert!(Timers::open(Some(f), c).list().is_empty());
    let _ = std::fs::remove_dir_all(&d);
}
