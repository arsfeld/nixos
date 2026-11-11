use cylon_bot_bridge::feed::Feed;
use cylon_bot_bridge::protocol::FeedKind;

#[test]
fn n_is_per_session_and_starts_at_one() {
    let f = Feed::new();
    assert_eq!(f.append("h", "a", FeedKind::Prompt, "x", 1).n, 1);
    assert_eq!(f.append("h", "a", FeedKind::Tool, "y", 2).n, 2);
    assert_eq!(f.append("h", "b", FeedKind::Prompt, "x", 3).n, 1);
    assert_eq!(f.append("g", "a", FeedKind::Prompt, "x", 4).n, 1);
}

#[test]
fn buffer_keeps_only_the_newest_200() {
    let f = Feed::new();
    for i in 0..205 {
        f.append("h", "s", FeedKind::Tool, "t", i);
    }
    let h = f.history("h", "s", 500);
    assert_eq!(h.len(), 200);
    assert_eq!(h[0].n, 6);
}

#[test]
fn history_returns_newest_limit_oldest_first() {
    let f = Feed::new();
    for i in 0..205 {
        f.append("h", "s", FeedKind::Tool, "t", i);
    }
    let ns: Vec<u64> = f.history("h", "s", 50).iter().map(|e| e.n).collect();
    assert_eq!(ns, (156..=205).collect::<Vec<u64>>());
}

#[test]
fn drop_session_forgets_entries_and_restarts_numbering() {
    let f = Feed::new();
    f.append("h", "s", FeedKind::Prompt, "x", 1);
    f.append("h", "s", FeedKind::Prompt, "x", 2);
    f.drop_session("h", "s");
    assert!(f.history("h", "s", 10).is_empty());
    assert_eq!(f.append("h", "s", FeedKind::Prompt, "x", 3).n, 1);
}

#[test]
fn truncation_never_splits_a_character() {
    let f = Feed::new();
    let e = f.append("h", "s", FeedKind::Reply, &"é".repeat(5000), 1);
    assert!(e.text.len() <= 4096);
    assert_eq!(e.text.chars().last(), Some('é'));
    assert_eq!(f.history("h", "s", 1)[0].text, e.text);
}

#[test]
fn caps_per_kind() {
    let f = Feed::new();
    let long = "a".repeat(5000);
    assert_eq!(f.append("h", "s", FeedKind::Prompt, &long, 1).text.len(), 2048);
    assert_eq!(f.append("h", "s", FeedKind::Tool, &long, 1).text.len(), 1200);
    assert_eq!(f.append("h", "s", FeedKind::Result, &long, 1).text.len(), 16);
    assert_eq!(f.append("h", "s", FeedKind::Reply, &long, 1).text.len(), 4096);
}

#[test]
fn unknown_session_history_is_empty() {
    assert!(Feed::new().history("h", "nope", 10).is_empty());
}

#[test]
fn history_within_drops_the_oldest_until_the_json_fits() {
    let f = Feed::new();
    for i in 0..10 {
        f.append("h", "s", FeedKind::Reply, &"\"".repeat(100), i);
    }
    let one = serde_json::to_string(&f.history("h", "s", 1)[0]).unwrap().len() + 1;
    let ns: Vec<u64> = f.history_within("h", "s", 50, one * 3 + one / 2).iter().map(|e| e.n).collect();
    assert_eq!(ns, vec![8, 9, 10]);
    assert_eq!(f.history_within("h", "s", 2, usize::MAX).len(), 2);
    assert!(f.history_within("h", "s", 50, 10).is_empty());
}
