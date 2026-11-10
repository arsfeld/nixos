use std::collections::BTreeMap;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::http::{Request, StatusCode};
use claude_board_bridge::app;
use claude_board_bridge::asks::{Answered, build_decision};
use claude_board_bridge::auth::Tokens;
use claude_board_bridge::http::AppState;
use futures::{SinkExt, StreamExt};
use http_body_util::BodyExt;
use serde_json::{Value, json};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::{Error as WsError, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async};
use tower::ServiceExt;

type Ws = WebSocketStream<MaybeTlsStream<TcpStream>>;

const HOST_TOKEN: &str = "host-token";
const DEVICE_TOKEN: &str = "device-token";

fn state(ask_timeout_ms: u64) -> AppState {
    AppState::new(
        Tokens { host: HOST_TOKEN.into(), device: DEVICE_TOKEN.into() },
        Duration::from_millis(ask_timeout_ms),
        Duration::from_millis(0),
        21600,
    )
}

async fn serve(st: AppState) -> std::net::SocketAddr {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let router = app(st);
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    addr
}

async fn try_connect(addr: std::net::SocketAddr, token: Option<&str>) -> Result<Ws, WsError> {
    let mut r = format!("ws://{addr}/v1/board").into_client_request().unwrap();
    if let Some(t) = token {
        r.headers_mut().insert("authorization", format!("Bearer {t}").parse().unwrap());
    }
    connect_async(r).await.map(|(ws, _)| ws)
}

/// Connects and consumes the greeting, so tests see the state snapshot first.
async fn connect(addr: std::net::SocketAddr) -> Ws {
    let mut ws = try_connect(addr, Some(DEVICE_TOKEN)).await.unwrap();
    assert_eq!(next_json(&mut ws).await["t"], "hello");
    ws
}

/// Next JSON text frame, skipping pings.
async fn next_json(ws: &mut Ws) -> Value {
    loop {
        let m = tokio::time::timeout(Duration::from_secs(3), ws.next()).await.expect("frame").unwrap().unwrap();
        if let Message::Text(t) = m {
            return serde_json::from_str(t.as_str()).unwrap();
        }
    }
}

async fn next_of(ws: &mut Ws, tag: &str) -> Value {
    loop {
        let v = next_json(ws).await;
        if v["t"] == tag {
            return v;
        }
    }
}

fn post(path: &str, body: Value) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(path)
        .header("authorization", format!("Bearer {HOST_TOKEN}"))
        .body(Body::from(body.to_string()))
        .unwrap()
}

fn event(session: &str, kind: &str) -> Value {
    json!({"host":"raider","session":session,"cwd":"/home/arosenfeld/Code/nixos","event":kind,"ts":100})
}

fn colour() -> Value {
    json!({"questions":[{"question":"Which colour?","header":"Colour",
        "options":[{"label":"Red","description":""},{"label":"Blue","description":""}],"multiSelect":false}]})
}

fn ask_req(session: &str) -> Request<Body> {
    post("/v1/ask", json!({"host":"raider","session":session,"cwd":"/home/arosenfeld/Code/nixos","tool_input":colour()}))
}

async fn wait_boards(st: &AppState, n: usize) {
    for _ in 0..100 {
        if st.board_connected.load(Ordering::SeqCst) == n {
            return;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("board_connected never became {n}");
}

#[tokio::test]
async fn connect_without_or_with_wrong_device_token_is_rejected() {
    let addr = serve(state(1000)).await;
    for tok in [None, Some("wrong")] {
        match try_connect(addr, tok).await {
            Err(WsError::Http(resp)) => assert_eq!(resp.status(), StatusCode::UNAUTHORIZED),
            other => panic!("expected 401, got {:?}", other.map(|_| "connected")),
        }
    }
}

#[tokio::test]
async fn host_token_cannot_open_the_board_socket() {
    let addr = serve(state(1000)).await;
    match try_connect(addr, Some(HOST_TOKEN)).await {
        Err(WsError::Http(resp)) => assert_eq!(resp.status(), StatusCode::UNAUTHORIZED),
        other => panic!("expected 401, got {:?}", other.map(|_| "connected")),
    }
}

#[tokio::test]
async fn server_pings_idle_connection() {
    let st = state(1000).with_ping_every(Duration::from_millis(100));
    let addr = serve(st).await;
    let mut ws = connect(addr).await;
    let _state = next_json(&mut ws).await;
    let got = tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if let Some(Ok(Message::Ping(_))) = ws.next().await {
                return true;
            }
        }
    })
    .await;
    assert_eq!(got, Ok(true));
}

#[tokio::test]
async fn new_board_gets_state_snapshot_then_pending_questions() {
    let st = state(5000);
    let router = app(st.clone());
    router.clone().oneshot(post("/v1/event", event("s1", "user_prompt_submit"))).await.unwrap();
    let (id, _rx) = st.asks.register("raider", "s1", "nixos", colour());
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    let snap = next_json(&mut ws).await;
    assert_eq!(snap["t"], "state");
    assert_eq!(snap["sessions"][0]["session"], "s1");
    assert_eq!(snap["sessions"][0]["state"], "working");
    let q = next_json(&mut ws).await;
    assert_eq!(q["t"], "question");
    assert_eq!(q["id"], id.0);
    assert_eq!(q["host"], "raider");
    assert_eq!(q["project"], "nixos");
    assert_eq!(q["questions"][0]["question"], "Which colour?");
    assert_eq!(q["questions"][0]["options"][1]["label"], "Blue");
    assert_eq!(q["questions"][0]["multiSelect"], false);
}

#[tokio::test]
async fn event_is_pushed_as_upsert() {
    let st = state(1000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    next_json(&mut ws).await; // empty state
    app(st).oneshot(post("/v1/event", event("s9", "stop"))).await.unwrap();
    let up = next_of(&mut ws, "upsert").await;
    assert_eq!(up["session"]["session"], "s9");
    assert_eq!(up["session"]["state"], "done");
}

#[tokio::test]
async fn answer_over_websocket_completes_the_hook_request() {
    let st = state(5000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    wait_boards(&st, 1).await;
    let hook = {
        let router = app(st.clone());
        tokio::spawn(async move { router.oneshot(ask_req("s1")).await.unwrap() })
    };
    let q = next_of(&mut ws, "question").await;
    ws.send(Message::text(json!({"t":"answer","id":q["id"],"answers":{"Which colour?":"Blue"}}).to_string()))
        .await
        .unwrap();
    let resp = hook.await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    let body: Value = serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    let answers = BTreeMap::from([("Which colour?".to_string(), "Blue".to_string())]);
    assert_eq!(body, build_decision(&colour(), &answers));
    let clear = next_of(&mut ws, "question_clear").await;
    assert_eq!(clear["id"], q["id"]);
}

#[tokio::test]
async fn decline_returns_no_decision() {
    let st = state(5000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    wait_boards(&st, 1).await;
    let hook = {
        let router = app(st.clone());
        tokio::spawn(async move { router.oneshot(ask_req("s1")).await.unwrap() })
    };
    let q = next_of(&mut ws, "question").await;
    ws.send(Message::text(json!({"t":"decline","id":q["id"]}).to_string())).await.unwrap();
    assert_eq!(hook.await.unwrap().status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn board_disconnect_mid_ask_returns_204_at_timeout_and_clears() {
    let st = state(600);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    wait_boards(&st, 1).await;
    let t = Instant::now();
    let hook = {
        let router = app(st.clone());
        tokio::spawn(async move { router.oneshot(ask_req("s1")).await.unwrap() })
    };
    next_of(&mut ws, "question").await;
    drop(ws);
    let resp = tokio::time::timeout(Duration::from_secs(3), hook).await.expect("hook must not hang").unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert!(t.elapsed() >= Duration::from_millis(600));
    assert!(st.asks.pending().is_empty());
}

#[tokio::test]
async fn answer_for_unknown_id_and_garbage_are_ignored_and_the_connection_stays_open() {
    let st = state(1000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    next_json(&mut ws).await;
    ws.send(Message::text(json!({"t":"answer","id":"deadbeef","answers":{}}).to_string())).await.unwrap();
    ws.send(Message::text("not json at all")).await.unwrap();
    ws.send(Message::text(json!({"t":"something_else"}).to_string())).await.unwrap();
    app(st).oneshot(post("/v1/event", event("s2", "session_start"))).await.unwrap();
    assert_eq!(next_of(&mut ws, "upsert").await["session"]["session"], "s2");
}

#[tokio::test]
async fn board_count_drops_on_disconnect_so_asks_fall_through_at_once() {
    let st = state(5000);
    let addr = serve(st.clone()).await;
    let ws = connect(addr).await;
    wait_boards(&st, 1).await;
    drop(ws);
    wait_boards(&st, 0).await;
    let t = Instant::now();
    let resp = app(st).oneshot(ask_req("s1")).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert!(t.elapsed() < Duration::from_millis(500));
}

#[tokio::test]
async fn every_connected_board_sees_the_question_and_its_clear() {
    let st = state(5000);
    let addr = serve(st.clone()).await;
    let mut a = connect(addr).await;
    let mut b = connect(addr).await;
    wait_boards(&st, 2).await;
    let hook = {
        let router = app(st.clone());
        tokio::spawn(async move { router.oneshot(ask_req("s1")).await.unwrap() })
    };
    let qa = next_of(&mut a, "question").await;
    let qb = next_of(&mut b, "question").await;
    assert_eq!(qa["id"], qb["id"]);
    st.asks.answer(&claude_board_bridge::asks::AskId(qa["id"].as_str().unwrap().into()), Answered::Declined).unwrap();
    hook.await.unwrap();
    assert_eq!(next_of(&mut b, "question_clear").await["id"], qb["id"]);
}

#[tokio::test]
async fn new_board_is_greeted_with_the_protocol_version_before_the_state() {
    let addr = serve(state(1000)).await;
    let mut ws = try_connect(addr, Some(DEVICE_TOKEN)).await.unwrap();
    let hello = next_json(&mut ws).await;
    assert_eq!(hello, serde_json::json!({"t": "hello", "version": claude_board_proto::PROTOCOL_VERSION}));
    assert_eq!(next_json(&mut ws).await["t"], "state");
}

fn feed_post(session: &str, kind: &str, text: &str) -> Request<Body> {
    post("/v1/feed", json!({"host":"raider","session":session,"kind":kind,"text":text,"ts":5}))
}

async fn watch(ws: &mut Ws, session: &str) {
    ws.send(Message::text(json!({"t":"watch","host":"raider","session":session}).to_string())).await.unwrap();
}

/// Asserts no frame of the given tag arrives for a short while.
async fn quiet_of(ws: &mut Ws, tag: &str) {
    let r = tokio::time::timeout(Duration::from_millis(400), async {
        loop {
            if let Some(Ok(Message::Text(t))) = ws.next().await {
                let v: Value = serde_json::from_str(t.as_str()).unwrap();
                if v["t"] == tag {
                    return v;
                }
            }
        }
    })
    .await;
    assert!(r.is_err(), "unexpected {tag}: {r:?}");
}

#[tokio::test]
async fn feed_entry_is_not_sent_to_a_board_that_is_not_watching() {
    let st = state(1000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    wait_boards(&st, 1).await;
    app(st).oneshot(feed_post("s1", "tool", "Bash ls")).await.unwrap();
    quiet_of(&mut ws, "entry").await;
}

#[tokio::test]
async fn watch_replies_with_history_then_streams_entries() {
    let st = state(1000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    wait_boards(&st, 1).await;
    let router = app(st.clone());
    router.clone().oneshot(feed_post("s1", "prompt", "hello")).await.unwrap();
    router.clone().oneshot(feed_post("s1", "reply", "hi there")).await.unwrap();
    watch(&mut ws, "s1").await;
    let h = next_of(&mut ws, "history").await;
    assert_eq!(h["host"], "raider");
    assert_eq!(h["session"], "s1");
    assert_eq!(h["entries"].as_array().unwrap().len(), 2);
    assert_eq!(h["entries"][0]["text"], "hello");
    assert_eq!(h["entries"][1]["n"], 2);
    router.oneshot(feed_post("s1", "tool", "Bash ls")).await.unwrap();
    // Entries 1 and 2 may be replayed from the broadcast queue (the board dedupes by `n`).
    let e = loop {
        let e = next_of(&mut ws, "entry").await;
        if e["n"] == 3 {
            break e;
        }
    };
    assert_eq!(e["session"], "s1");
    assert_eq!(e["kind"], "tool");
    assert_eq!(e["text"], "Bash ls");
}

#[tokio::test]
async fn watch_other_session_receives_no_entries() {
    let st = state(1000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    wait_boards(&st, 1).await;
    watch(&mut ws, "s1").await;
    next_of(&mut ws, "history").await;
    app(st).oneshot(feed_post("s2", "tool", "x")).await.unwrap();
    quiet_of(&mut ws, "entry").await;
}

#[tokio::test]
async fn unwatch_stops_entries() {
    let st = state(1000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    wait_boards(&st, 1).await;
    watch(&mut ws, "s1").await;
    next_of(&mut ws, "history").await;
    ws.send(Message::text(json!({"t":"unwatch"}).to_string())).await.unwrap();
    // The unwatch is processed in order with a later watch of another session.
    watch(&mut ws, "s2").await;
    next_of(&mut ws, "history").await;
    app(st).oneshot(feed_post("s1", "tool", "x")).await.unwrap();
    quiet_of(&mut ws, "entry").await;
}

#[tokio::test]
async fn watch_unknown_session_gets_empty_history() {
    let st = state(1000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    watch(&mut ws, "nope").await;
    let h = next_of(&mut ws, "history").await;
    assert_eq!(h["entries"], json!([]));
}

#[tokio::test]
async fn lagged_socket_resends_history_for_its_watched_session() {
    let st = state(1000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    wait_boards(&st, 1).await;
    watch(&mut ws, "s1").await;
    next_of(&mut ws, "history").await;
    // Overflow the broadcast channel (256) faster than the socket drains it.
    for i in 0..600 {
        let e = st.feed.append("raider", "s1", claude_board_bridge::protocol::FeedKind::Tool, &format!("t{i}"), 1);
        let _ = st.tx.send(claude_board_bridge::protocol::BoardMsg::Entry {
            host: "raider".into(),
            session: "s1".into(),
            entry: e,
        });
    }
    let got = tokio::time::timeout(Duration::from_secs(3), async {
        let mut saw_state = false;
        loop {
            let v = next_json(&mut ws).await;
            if v["t"] == "state" {
                saw_state = true;
            }
            if v["t"] == "history" && saw_state {
                return v;
            }
        }
    })
    .await
    .expect("state snapshot then history after lag");
    assert_eq!(got["session"], "s1");
    assert_eq!(got["entries"].as_array().unwrap().len(), 50);
}

/// Next text frame as it arrived on the wire, skipping pings.
async fn next_raw_of(ws: &mut Ws, tag: &str) -> String {
    loop {
        let m = tokio::time::timeout(Duration::from_secs(3), ws.next()).await.expect("frame").unwrap().unwrap();
        if let Message::Text(t) = m {
            let v: Value = serde_json::from_str(t.as_str()).unwrap();
            if v["t"] == tag {
                return t.as_str().to_string();
            }
        }
    }
}

/// 4 KiB of reply text that grows when JSON-escaped (every other byte is a quote).
fn big_reply(i: usize) -> String {
    let mut s = format!("{i:04}");
    while s.len() < 4096 {
        s.push_str("x\"");
    }
    s.truncate(4096);
    s
}

/// The ns of a history frame's entries, which must be the newest, consecutive and in order.
fn assert_newest_in_order(frame: &Value, last: u64) -> usize {
    let ns: Vec<u64> = frame["entries"].as_array().unwrap().iter().map(|e| e["n"].as_u64().unwrap()).collect();
    assert!(!ns.is_empty(), "no entries at all");
    assert!(ns.len() <= 50, "{} entries", ns.len());
    let first = last + 1 - ns.len() as u64;
    assert_eq!(ns, (first..=last).collect::<Vec<u64>>(), "not the newest entries in order");
    ns.len()
}

#[tokio::test]
async fn watch_history_of_big_replies_fits_the_board_frame_limit() {
    let st = state(1000);
    for i in 0..200 {
        st.feed.append("raider", "s1", claude_board_bridge::protocol::FeedKind::Reply, &big_reply(i), 1);
    }
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    watch(&mut ws, "s1").await;
    let raw = next_raw_of(&mut ws, "history").await;
    assert!(raw.len() <= 48 * 1024, "history frame is {} bytes", raw.len());
    let n = assert_newest_in_order(&serde_json::from_str(&raw).unwrap(), 200);
    assert!(n >= 5, "only {n} entries fit");
}

#[tokio::test]
async fn lagged_history_of_big_replies_fits_the_board_frame_limit() {
    let st = state(1000);
    let addr = serve(st.clone()).await;
    let mut ws = connect(addr).await;
    wait_boards(&st, 1).await;
    watch(&mut ws, "s1").await;
    next_of(&mut ws, "history").await;
    for i in 0..600 {
        let e = st.feed.append("raider", "s1", claude_board_bridge::protocol::FeedKind::Reply, &big_reply(i), 1);
        let _ = st.tx.send(claude_board_bridge::protocol::BoardMsg::Entry {
            host: "raider".into(),
            session: "s1".into(),
            entry: e,
        });
    }
    let raw = tokio::time::timeout(Duration::from_secs(5), async {
        let mut saw_state = false;
        loop {
            let raw = next_raw_any(&mut ws).await;
            let v: Value = serde_json::from_str(&raw).unwrap();
            if v["t"] == "state" {
                saw_state = true;
            }
            if v["t"] == "history" && saw_state {
                return raw;
            }
        }
    })
    .await
    .expect("state snapshot then history after lag");
    assert!(raw.len() <= 48 * 1024, "history frame is {} bytes", raw.len());
    assert_newest_in_order(&serde_json::from_str(&raw).unwrap(), 600);
}

async fn next_raw_any(ws: &mut Ws) -> String {
    loop {
        let m = tokio::time::timeout(Duration::from_secs(3), ws.next()).await.expect("frame").unwrap().unwrap();
        if let Message::Text(t) = m {
            return t.as_str().to_string();
        }
    }
}
