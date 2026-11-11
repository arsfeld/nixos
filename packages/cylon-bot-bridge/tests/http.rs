use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use cylon_bot_bridge::asks::{Answered, build_decision};
use cylon_bot_bridge::auth::Tokens;
use cylon_bot_bridge::http::{AppState, hook_router};
use cylon_bot_bridge::protocol::{BoardMsg, State};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tower::ServiceExt;

const HOST_TOKEN: &str = "host-token";

fn state(ask_timeout_ms: u64, fail_delay_ms: u64) -> AppState {
    AppState::new(
        Tokens { host: HOST_TOKEN.into(), device: "device-token".into() },
        Duration::from_millis(ask_timeout_ms),
        Duration::from_millis(fail_delay_ms),
        21600,
    )
}

fn req(path: &str, token: Option<&str>, body: Value) -> Request<Body> {
    let mut b = Request::builder().method("POST").uri(path).header("content-type", "application/json");
    if let Some(t) = token {
        b = b.header("authorization", format!("Bearer {t}"));
    }
    b.body(Body::from(body.to_string())).unwrap()
}

fn event(session: &str, kind: &str) -> Value {
    json!({"host":"raider","session":session,"cwd":"/home/arosenfeld/Code/nixos","event":kind,"ts":100})
}

fn colour() -> Value {
    json!({"questions":[{"question":"Which colour?","header":"Colour",
        "options":[{"label":"Red","description":""},{"label":"Blue","description":""}],"multiSelect":false}]})
}

fn ask_body(session: &str) -> Value {
    json!({"host":"raider","session":session,"cwd":"/home/arosenfeld/Code/nixos","tool_input":colour()})
}

async fn status_of(app: &Router, r: Request<Body>) -> StatusCode {
    app.clone().oneshot(r).await.unwrap().status()
}

async fn body_json(resp: axum::response::Response) -> Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

/// Wait for the next question on the broadcast channel, skipping other messages.
async fn next_question(rx: &mut tokio::sync::broadcast::Receiver<BoardMsg>) -> cylon_bot_bridge::asks::PendingAsk {
    loop {
        if let BoardMsg::Question { ask } = tokio::time::timeout(Duration::from_secs(2), rx.recv())
            .await
            .expect("question broadcast")
            .unwrap()
        {
            return ask;
        }
    }
}

async fn until_clear(rx: &mut tokio::sync::broadcast::Receiver<BoardMsg>) -> Vec<BoardMsg> {
    let mut seen = vec![];
    loop {
        let m = tokio::time::timeout(Duration::from_secs(2), rx.recv()).await.expect("clear broadcast").unwrap();
        let done = matches!(m, BoardMsg::QuestionClear { .. });
        seen.push(m);
        if done {
            return seen;
        }
    }
}

#[tokio::test]
async fn event_requires_host_token() {
    let app = hook_router(state(1000, 0));
    assert_eq!(status_of(&app, req("/v1/event", None, event("s1", "session_start"))).await, StatusCode::UNAUTHORIZED);
    assert_eq!(status_of(&app, req("/v1/event", Some("wrong"), event("s1", "session_start"))).await, StatusCode::UNAUTHORIZED);
    assert_eq!(status_of(&app, req("/v1/event", Some(HOST_TOKEN), event("s1", "session_start"))).await, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn device_token_does_not_authorise_hook_endpoints() {
    let app = hook_router(state(1000, 0));
    assert_eq!(status_of(&app, req("/v1/event", Some("device-token"), event("s1", "session_start"))).await, StatusCode::UNAUTHORIZED);
    assert_eq!(status_of(&app, req("/v1/ask", Some("device-token"), ask_body("s1"))).await, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn unauthenticated_malformed_body_is_still_401_not_a_parse_error() {
    let app = hook_router(state(1000, 0));
    let r = Request::builder().method("POST").uri("/v1/event").body(Body::from("{not json")).unwrap();
    assert_eq!(status_of(&app, r).await, StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn malformed_event_body_with_a_valid_token_is_a_client_error() {
    let app = hook_router(state(1000, 0));
    let r = Request::builder()
        .method("POST")
        .uri("/v1/event")
        .header("authorization", format!("Bearer {HOST_TOKEN}"))
        .body(Body::from("{not json"))
        .unwrap();
    assert_eq!(status_of(&app, r).await, StatusCode::BAD_REQUEST);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn failed_auth_is_delayed_and_valid_requests_stay_fast() {
    let app = hook_router(state(1000, 300));
    let mut bad = vec![];
    for _ in 0..20 {
        let app = app.clone();
        bad.push(tokio::spawn(async move {
            let t = Instant::now();
            let s = status_of(&app, req("/v1/event", Some("nope"), event("s1", "session_start"))).await;
            (s, t.elapsed())
        }));
    }
    let t = Instant::now();
    assert_eq!(status_of(&app, req("/v1/event", Some(HOST_TOKEN), event("s2", "session_start"))).await, StatusCode::NO_CONTENT);
    assert!(t.elapsed() < Duration::from_millis(150), "valid request took {:?}", t.elapsed());
    for h in bad {
        let (s, took) = h.await.unwrap();
        assert_eq!(s, StatusCode::UNAUTHORIZED);
        assert!(took >= Duration::from_millis(300), "bad auth answered in {took:?}");
    }
}

#[tokio::test]
async fn event_updates_registry_and_broadcasts_upsert_then_remove() {
    let st = state(1000, 0);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    assert_eq!(status_of(&app, req("/v1/event", Some(HOST_TOKEN), event("s1", "user_prompt_submit"))).await, StatusCode::NO_CONTENT);
    match rx.recv().await.unwrap() {
        BoardMsg::Upsert { session } => {
            assert_eq!(session.state, State::Working);
            assert_eq!(session.project, "nixos");
        }
        other => panic!("expected upsert, got {other:?}"),
    }
    assert_eq!(st.registry.lock().unwrap().snapshot().len(), 1);
    status_of(&app, req("/v1/event", Some(HOST_TOKEN), event("s1", "session_end"))).await;
    assert!(matches!(rx.recv().await.unwrap(), BoardMsg::Remove { .. }));
}

#[tokio::test]
async fn ask_with_no_board_connected_returns_204_immediately() {
    let st = state(5000, 0);
    let app = hook_router(st.clone());
    let t = Instant::now();
    assert_eq!(status_of(&app, req("/v1/ask", Some(HOST_TOKEN), ask_body("s1"))).await, StatusCode::NO_CONTENT);
    assert!(t.elapsed() < Duration::from_millis(500));
    assert!(st.asks.pending().is_empty());
}

#[tokio::test]
async fn ask_returns_decision_when_answered_and_marks_session_working_again() {
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let pending = {
        let app = app.clone();
        tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), ask_body("s1"))).await.unwrap() })
    };
    let ask = next_question(&mut rx).await;
    assert_eq!(ask.project, "nixos");
    assert_eq!(st.registry.lock().unwrap().snapshot()[0].state, State::Waiting);
    let answers = std::collections::BTreeMap::from([("Which colour?".to_string(), "Blue".to_string())]);
    st.asks.answer(&ask.id, Answered::Answers(answers.clone())).unwrap();
    let resp = pending.await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(body_json(resp).await, build_decision(&colour(), &answers));
    let msgs = until_clear(&mut rx).await;
    assert!(matches!(msgs.last(), Some(BoardMsg::QuestionClear { id }) if *id == ask.id));
    assert_eq!(st.registry.lock().unwrap().snapshot()[0].state, State::Working);
}

#[tokio::test]
async fn ask_declined_returns_204_and_leaves_the_session_waiting() {
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let pending = {
        let app = app.clone();
        tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), ask_body("s1"))).await.unwrap() })
    };
    let ask = next_question(&mut rx).await;
    st.asks.answer(&ask.id, Answered::Declined).unwrap();
    assert_eq!(pending.await.unwrap().status(), StatusCode::NO_CONTENT);
    until_clear(&mut rx).await;
    assert_eq!(st.registry.lock().unwrap().snapshot()[0].state, State::Waiting);
}

#[tokio::test]
async fn ask_times_out_with_204_and_broadcasts_question_clear() {
    let st = state(150, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let t = Instant::now();
    let status = status_of(&app, req("/v1/ask", Some(HOST_TOKEN), ask_body("s1"))).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(t.elapsed() >= Duration::from_millis(150));
    let msgs = until_clear(&mut rx).await;
    assert!(msgs.iter().any(|m| matches!(m, BoardMsg::Question { .. })));
    assert!(st.asks.pending().is_empty());
}

#[tokio::test]
async fn a_later_event_for_the_session_clears_its_pending_ask() {
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let pending = {
        let app = app.clone();
        tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), ask_body("s1"))).await.unwrap() })
    };
    let ask = next_question(&mut rx).await;
    // The user answered in the terminal: Claude carries on and finishes.
    status_of(&app, req("/v1/event", Some(HOST_TOKEN), event("s1", "stop"))).await;
    assert_eq!(pending.await.unwrap().status(), StatusCode::NO_CONTENT);
    let msgs = until_clear(&mut rx).await;
    assert!(msgs.iter().any(|m| matches!(m, BoardMsg::QuestionClear { id } if *id == ask.id)));
    assert!(st.asks.pending().is_empty());
}

#[tokio::test]
async fn a_notification_during_a_pending_ask_changes_nothing() {
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let pending = {
        let app = app.clone();
        tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), ask_body("s1"))).await.unwrap() })
    };
    let ask = next_question(&mut rx).await;
    let idle = json!({"host":"raider","session":"s1","cwd":"/x","event":"notification","kind":"idle_prompt","ts":170});
    status_of(&app, req("/v1/event", Some(HOST_TOKEN), idle)).await;
    assert_eq!(st.registry.lock().unwrap().snapshot()[0].state, State::Waiting);
    assert_eq!(st.asks.pending().len(), 1);
    st.asks.answer(&ask.id, Answered::Declined).unwrap();
    pending.await.unwrap();
}

#[tokio::test]
async fn two_concurrent_asks_get_their_own_answers() {
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let spawn_ask = |session: &'static str| {
        let app = app.clone();
        tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), ask_body(session))).await.unwrap() })
    };
    let a = spawn_ask("same-project-a");
    let b = spawn_ask("same-project-b");
    let q1 = next_question(&mut rx).await;
    let q2 = next_question(&mut rx).await;
    let pick = |label: &str| Answered::Answers(std::collections::BTreeMap::from([("Which colour?".to_string(), label.to_string())]));
    // Answer in the opposite order to arrival.
    st.asks.answer(&q2.id, pick(if q2.session == "same-project-a" { "Red" } else { "Blue" })).unwrap();
    st.asks.answer(&q1.id, pick(if q1.session == "same-project-a" { "Red" } else { "Blue" })).unwrap();
    let got = |resp: Value| resp["hookSpecificOutput"]["decision"]["updatedInput"]["answers"]["Which colour?"].clone();
    assert_eq!(got(body_json(a.await.unwrap()).await), "Red");
    assert_eq!(got(body_json(b.await.unwrap()).await), "Blue");
}

#[tokio::test]
async fn ask_whose_hook_disconnects_is_cleared_from_the_board() {
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let pending = {
        let app = app.clone();
        tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), ask_body("s1"))).await })
    };
    let ask = next_question(&mut rx).await;
    pending.abort(); // the hook process was killed: the connection closes
    let msgs = until_clear(&mut rx).await;
    assert!(matches!(msgs.last(), Some(BoardMsg::QuestionClear { id }) if *id == ask.id));
    assert!(st.asks.pending().is_empty());
}

fn approval_body(session: &str) -> Value {
    json!({"host":"raider","session":session,"cwd":"/home/arosenfeld/Code/nixos",
        "tool_name":"Bash","summary":"ls -la","tool_input":{"command":"ls -la"}})
}

/// Hold a Bash approval, answer it with `a`, return the HTTP response.
async fn approve_with(a: Answered) -> axum::response::Response {
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let pending = {
        let app = app.clone();
        tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), approval_body("s1"))).await.unwrap() })
    };
    let ask = next_question(&mut rx).await;
    assert_eq!(ask.questions[0].question, "Bash: ls -la");
    st.asks.answer(&ask.id, a).unwrap();
    pending.await.unwrap()
}

fn label(l: &str) -> Answered {
    Answered::Answers(std::collections::BTreeMap::from([("Bash: ls -la".to_string(), l.to_string())]))
}

#[tokio::test]
async fn bash_approval_allow_returns_allow_decision() {
    let resp = approve_with(label("Allow")).await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        body_json(resp).await,
        json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}})
    );
}

#[tokio::test]
async fn bash_approval_deny_returns_deny_with_message() {
    let resp = approve_with(label("Deny")).await;
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        body_json(resp).await,
        json!({"hookSpecificOutput":{"hookEventName":"PermissionRequest",
            "decision":{"behavior":"deny","message":"Denied from the board"}}})
    );
}

#[tokio::test]
async fn approval_with_no_board_connected_is_204_immediately() {
    let st = state(5000, 0);
    let app = hook_router(st.clone());
    let t = Instant::now();
    assert_eq!(status_of(&app, req("/v1/ask", Some(HOST_TOKEN), approval_body("s1"))).await, StatusCode::NO_CONTENT);
    assert!(t.elapsed() < Duration::from_millis(500));
    assert!(st.asks.pending().is_empty());
}

#[tokio::test]
async fn approval_unknown_label_is_204() {
    assert_eq!(approve_with(label("allow")).await.status(), StatusCode::NO_CONTENT);
    assert_eq!(approve_with(label("Maybe")).await.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        approve_with(Answered::Answers(Default::default())).await.status(),
        StatusCode::NO_CONTENT
    );
}

#[tokio::test]
async fn approval_decline_is_204() {
    assert_eq!(approve_with(Answered::Declined).await.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn ask_user_question_without_tool_name_still_works() {
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let pending = {
        let app = app.clone();
        tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), ask_body("s1"))).await.unwrap() })
    };
    let ask = next_question(&mut rx).await;
    assert_eq!(ask.questions[0].question, "Which colour?");
    let answers = std::collections::BTreeMap::from([("Which colour?".to_string(), "Red".to_string())]);
    st.asks.answer(&ask.id, Answered::Answers(answers.clone())).unwrap();
    let resp = pending.await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(body_json(resp).await, build_decision(&colour(), &answers));
}

fn feed_body(session: &str, kind: &str, text: &str) -> Value {
    json!({"host":"raider","session":session,"kind":kind,"text":text,"ts":7})
}

#[tokio::test]
async fn feed_requires_the_host_token() {
    let app = hook_router(state(1000, 0));
    for tok in [None, Some("wrong"), Some("device-token")] {
        assert_eq!(status_of(&app, req("/v1/feed", tok, feed_body("s1", "tool", "x"))).await, StatusCode::UNAUTHORIZED);
    }
    assert_eq!(status_of(&app, req("/v1/feed", Some(HOST_TOKEN), feed_body("s1", "tool", "x"))).await, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn feed_bad_kind_is_400() {
    let st = state(1000, 0);
    let app = hook_router(st.clone());
    for kind in ["nonsense", "other"] {
        assert_eq!(status_of(&app, req("/v1/feed", Some(HOST_TOKEN), feed_body("s1", kind, "x"))).await, StatusCode::BAD_REQUEST);
    }
    assert_eq!(status_of(&app, req("/v1/feed", Some(HOST_TOKEN), json!({"host":"raider"}))).await, StatusCode::BAD_REQUEST);
    assert!(st.feed.history("raider", "s1", 50).is_empty());
}

#[tokio::test]
async fn feed_never_cancels_a_held_question() {
    let st = state(5000, 0);
    let _board = st.board_connected.fetch_add(1, Ordering::SeqCst);
    let app = hook_router(st.clone());
    let hook = {
        let app = app.clone();
        tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), ask_body("s1"))).await.unwrap() })
    };
    for _ in 0..100 {
        if !st.asks.pending().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(st.asks.pending().len(), 1);
    assert_eq!(status_of(&app, req("/v1/feed", Some(HOST_TOKEN), feed_body("s1", "tool", "Bash ls"))).await, StatusCode::NO_CONTENT);
    assert_eq!(st.asks.pending().len(), 1);
    assert_eq!(st.registry.lock().unwrap().snapshot().iter().filter(|s| s.session == "s1").count(), 1);
    hook.abort();
}

#[tokio::test]
async fn feed_does_not_touch_the_registry() {
    let st = state(1000, 0);
    let app = hook_router(st.clone());
    status_of(&app, req("/v1/feed", Some(HOST_TOKEN), feed_body("s1", "prompt", "hi"))).await;
    assert!(st.registry.lock().unwrap().snapshot().is_empty());
    assert_eq!(st.feed.history("raider", "s1", 50).len(), 1);
}

#[tokio::test]
async fn session_end_drops_the_feed() {
    let st = state(1000, 0);
    let app = hook_router(st.clone());
    status_of(&app, req("/v1/event", Some(HOST_TOKEN), event("s1", "user_prompt_submit"))).await;
    status_of(&app, req("/v1/feed", Some(HOST_TOKEN), feed_body("s1", "prompt", "hi"))).await;
    assert_eq!(st.feed.history("raider", "s1", 50).len(), 1);
    status_of(&app, req("/v1/event", Some(HOST_TOKEN), event("s1", "session_end"))).await;
    assert!(st.feed.history("raider", "s1", 50).is_empty());
}

#[tokio::test]
async fn oversized_feed_body_is_rejected() {
    let app = hook_router(state(1000, 0));
    let big = "x".repeat(70 * 1024);
    assert_eq!(status_of(&app, req("/v1/feed", Some(HOST_TOKEN), feed_body("s1", "reply", &big))).await, StatusCode::PAYLOAD_TOO_LARGE);
    let ok = "x".repeat(40 * 1024);
    assert_eq!(status_of(&app, req("/v1/feed", Some(HOST_TOKEN), feed_body("s1", "reply", &ok))).await, StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn sweep_drops_feeds_without_a_session_and_keeps_live_ones() {
    let st = state(1000, 0);
    let app = hook_router(st.clone());
    status_of(&app, req("/v1/event", Some(HOST_TOKEN), event("live", "user_prompt_submit"))).await;
    status_of(&app, req("/v1/feed", Some(HOST_TOKEN), feed_body("live", "prompt", "hi"))).await;
    status_of(&app, req("/v1/feed", Some(HOST_TOKEN), feed_body("orphan", "reply", "late"))).await;
    st.sweep(200);
    assert_eq!(st.feed.history("raider", "live", 50).len(), 1);
    assert!(st.feed.history("raider", "orphan", 50).is_empty());
}

fn approval_with(tool: &str, summary: &str) -> Value {
    json!({"host":"raider","session":"s1","cwd":"/home/arosenfeld/Code/nixos",
        "tool_name":tool,"summary":summary,"tool_input":{}})
}

/// The approval falls straight through: 204 at once, nothing held, nothing broadcast, the session untouched.
async fn falls_through(body: Value) {
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let t = Instant::now();
    assert_eq!(status_of(&app, req("/v1/ask", Some(HOST_TOKEN), body)).await, StatusCode::NO_CONTENT);
    assert!(t.elapsed() < Duration::from_millis(500), "held for {:?}", t.elapsed());
    assert!(st.asks.pending().is_empty());
    assert!(rx.try_recv().is_err(), "something was broadcast");
    assert!(st.registry.lock().unwrap().snapshot().is_empty(), "the session was marked waiting");
}

#[tokio::test]
async fn approval_with_an_empty_summary_falls_through_to_the_terminal() {
    falls_through(approval_with("Bash", "")).await;
    falls_through(approval_with("mcp__thing__do", "")).await;
}

#[tokio::test]
async fn approval_whose_text_does_not_fit_the_board_falls_through() {
    // "Bash: " + summary is one byte over the board's limit.
    let summary = "x".repeat(cylon_bot_proto::APPROVAL_TEXT_MAX - "Bash: ".len() + 1);
    falls_through(approval_with("Bash", &summary)).await;
}

#[tokio::test]
async fn approval_whose_text_exactly_fits_the_board_is_held() {
    let summary = "é".repeat((cylon_bot_proto::APPROVAL_TEXT_MAX - "Bash: ".len()) / 2);
    let summary = format!("{summary}{}", "x".repeat(cylon_bot_proto::APPROVAL_TEXT_MAX - "Bash: ".len() - summary.len()));
    let st = state(5000, 0);
    st.board_connected.store(1, Ordering::SeqCst);
    let mut rx = st.tx.subscribe();
    let app = hook_router(st.clone());
    let body = approval_with("Bash", &summary);
    let pending = tokio::spawn(async move { app.oneshot(req("/v1/ask", Some(HOST_TOKEN), body)).await.unwrap() });
    let ask = next_question(&mut rx).await;
    let text = format!("Bash: {summary}");
    assert_eq!(text.len(), cylon_bot_proto::APPROVAL_TEXT_MAX);
    assert_eq!(ask.questions[0].question, text);
    let answers = std::collections::BTreeMap::from([(text, "Allow".to_string())]);
    st.asks.answer(&ask.id, Answered::Answers(answers)).unwrap();
    assert_eq!(pending.await.unwrap().status(), StatusCode::OK);
}
