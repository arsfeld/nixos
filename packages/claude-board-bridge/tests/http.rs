use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use claude_board_bridge::asks::{Answered, build_decision};
use claude_board_bridge::auth::Tokens;
use claude_board_bridge::http::{AppState, hook_router};
use claude_board_bridge::protocol::{BoardMsg, State};
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
async fn next_question(rx: &mut tokio::sync::broadcast::Receiver<BoardMsg>) -> claude_board_bridge::asks::PendingAsk {
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
