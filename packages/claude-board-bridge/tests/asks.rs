use std::collections::BTreeMap;

use claude_board_bridge::asks::{build_approval_decision, build_decision, Answered, AnswerError, AskId, Asks};
use serde_json::{json, Value};

fn colour() -> Value {
    json!({"questions":[{"question":"Which colour?","header":"Colour",
        "options":[{"label":"Red","description":"Pick red"},{"label":"Blue","description":"Pick blue"}],
        "multiSelect":false}]})
}

fn answers(k: &str, v: &str) -> Answered {
    Answered::Answers(BTreeMap::from([(k.to_string(), v.to_string())]))
}

#[tokio::test]
async fn answer_resolves_the_waiting_receiver() {
    let asks = Asks::new();
    let (id, rx) = asks.register("raider", "s1", "nixos", colour());
    asks.answer(&id, answers("Which colour?", "Blue")).unwrap();
    assert_eq!(rx.await.unwrap(), answers("Which colour?", "Blue"));
}

#[tokio::test]
async fn second_answer_with_same_id_is_unknown() {
    let asks = Asks::new();
    let (id, _rx) = asks.register("raider", "s1", "nixos", colour());
    asks.answer(&id, answers("Which colour?", "Red")).unwrap();
    assert_eq!(asks.answer(&id, answers("Which colour?", "Blue")), Err(AnswerError::Unknown));
}

#[tokio::test]
async fn unknown_id_is_unknown() {
    let asks = Asks::new();
    assert_eq!(asks.answer(&AskId("nope".into()), Answered::Declined), Err(AnswerError::Unknown));
}

#[tokio::test]
async fn two_asks_same_session_do_not_cross() {
    let asks = Asks::new();
    let (id1, rx1) = asks.register("raider", "s1", "nixos", colour());
    let (id2, rx2) = asks.register("raider", "s1", "nixos", colour());
    assert_ne!(id1, id2);
    asks.answer(&id2, answers("Which colour?", "Blue")).unwrap();
    asks.answer(&id1, answers("Which colour?", "Red")).unwrap();
    assert_eq!(rx1.await.unwrap(), answers("Which colour?", "Red"));
    assert_eq!(rx2.await.unwrap(), answers("Which colour?", "Blue"));
}

#[tokio::test]
async fn cancel_makes_id_unknown_and_closes_the_receiver() {
    let asks = Asks::new();
    let (id, rx) = asks.register("raider", "s1", "nixos", colour());
    asks.cancel(&id);
    assert_eq!(asks.answer(&id, Answered::Declined), Err(AnswerError::Unknown));
    assert!(rx.await.is_err());
}

#[tokio::test]
async fn cancel_session_cancels_only_that_session() {
    let asks = Asks::new();
    let (a, _ra) = asks.register("raider", "s1", "nixos", colour());
    let (b, _rb) = asks.register("raider", "s2", "nixos", colour());
    let (c, _rc) = asks.register("basestar", "s1", "nixos", colour());
    let cancelled = asks.cancel_session("raider", "s1");
    assert_eq!(cancelled, vec![a]);
    assert_eq!(asks.pending().len(), 2);
    assert!(asks.answer(&b, Answered::Declined).is_ok());
    assert!(asks.answer(&c, Answered::Declined).is_ok());
}

#[tokio::test]
async fn answer_after_the_hook_gave_up_is_unknown() {
    let asks = Asks::new();
    let (id, rx) = asks.register("raider", "s1", "nixos", colour());
    drop(rx);
    assert_eq!(asks.answer(&id, Answered::Declined), Err(AnswerError::Unknown));
}

#[tokio::test]
async fn pending_lists_questions_in_registration_order_with_unique_hex_ids() {
    let asks = Asks::new();
    let (a, _ra) = asks.register("raider", "s1", "nixos", colour());
    let (b, _rb) = asks.register("galactica", "s9", "plab", colour());
    let p = asks.pending();
    assert_eq!(p.iter().map(|x| x.id.clone()).collect::<Vec<_>>(), vec![a.clone(), b]);
    assert_eq!(p[0].host, "raider");
    assert_eq!(p[0].project, "nixos");
    assert_eq!(p[0].questions[0].question, "Which colour?");
    assert_eq!(p[0].questions[0].options[1].label, "Blue");
    assert!(!p[0].questions[0].multi_select);
    assert_eq!(a.0.len(), 32);
    assert!(a.0.chars().all(|c| c.is_ascii_hexdigit()));
}

#[test]
fn build_decision_preserves_questions_and_adds_answers() {
    let input = colour();
    let a = BTreeMap::from([("Which colour?".to_string(), "Blue".to_string())]);
    let d = build_decision(&input, &a);
    let mut updated = input.clone();
    updated["answers"] = json!({"Which colour?": "Blue"});
    assert_eq!(
        d,
        json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest",
            "decision":{"behavior":"allow","updatedInput":updated}}})
    );
}

#[tokio::test]
async fn unicode_and_long_question_text_round_trips_byte_exact() {
    let long = "x".repeat(5000);
    for text in ["🎨 Cuál es tu color? e\u{0301}\u{200d}🙂".to_string(), long] {
        let input = json!({"questions":[{"question":text,"header":"H",
            "options":[{"label":"Α β ✓","description":""},{"label":"b","description":""}],"multiSelect":false}]});
        let asks = Asks::new();
        let (_id, _rx) = asks.register("raider", "s1", "nixos", input.clone());
        assert_eq!(asks.pending()[0].questions[0].question, text);
        let a = BTreeMap::from([(text.clone(), "Α β ✓".to_string())]);
        let wire = serde_json::to_string(&build_decision(&input, &a)).unwrap();
        let back: Value = serde_json::from_str(&wire).unwrap();
        let key = back["hookSpecificOutput"]["decision"]["updatedInput"]["answers"]
            .as_object()
            .unwrap()
            .keys()
            .next()
            .unwrap()
            .clone();
        assert_eq!(key.as_bytes(), text.as_bytes());
    }
}

#[test]
fn multi_select_answer_is_passed_through_as_given() {
    let input = json!({"questions":[{"question":"Pick","header":"H",
        "options":[{"label":"A","description":""},{"label":"B","description":""}],"multiSelect":true}]});
    let a = BTreeMap::from([("Pick".to_string(), "A,B".to_string())]);
    let d = build_decision(&input, &a);
    assert_eq!(d["hookSpecificOutput"]["decision"]["updatedInput"]["answers"]["Pick"], "A,B");
}

#[tokio::test]
async fn approval_ask_has_allow_and_deny_options() {
    let asks = Asks::new();
    let long = "x".repeat(600);
    let (id, _rx) = asks.register_approval("raider", "s1", "nixos", "Bash", &long);
    let p = asks.pending();
    assert_eq!(p.len(), 1);
    assert_eq!(p[0].id, id);
    let q = &p[0].questions;
    assert_eq!(q.len(), 1);
    assert!(q[0].question.starts_with("Bash: xxx"));
    assert!(q[0].question.len() <= 500);
    assert_eq!(q[0].header.as_deref(), Some("Approve"));
    assert!(!q[0].multi_select);
    let labels: Vec<&str> = q[0].options.iter().map(|o| o.label.as_str()).collect();
    assert_eq!(labels, ["Allow", "Deny"]);
    assert!(q[0].options.iter().all(|o| o.description.is_none()));
}

#[tokio::test]
async fn approval_question_is_cut_on_a_char_boundary() {
    let asks = Asks::new();
    let (_id, _rx) = asks.register_approval("raider", "s1", "nixos", "Bash", &"é".repeat(400));
    assert!(asks.pending()[0].questions[0].question.len() <= 500);
}

fn one(v: &str) -> BTreeMap<String, String> {
    BTreeMap::from([("Bash: ls".to_string(), v.to_string())])
}

#[test]
fn approval_decision_allow_and_deny_match_the_hook_output() {
    assert_eq!(
        build_approval_decision(&one("Allow")),
        Some(json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}))
    );
    assert_eq!(
        build_approval_decision(&one("Deny")),
        Some(json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest",
            "decision":{"behavior":"deny","message":"Denied from the board"}}}))
    );
}

#[test]
fn approval_decision_for_any_other_label_is_none() {
    for l in ["allow", "Maybe", "", "Allow, Deny", " Allow"] {
        assert_eq!(build_approval_decision(&one(l)), None, "{l:?}");
    }
    assert_eq!(build_approval_decision(&BTreeMap::new()), None);
}
